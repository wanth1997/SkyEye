# Grafana 升級：11.2.0 → 12.4.15（monitoring-prod）

這是換中央 Grafana image 與新增 12.x 環境變數的手動部署流程。`scripts/central-deploy` 會拒絕 `docker-compose.yml` 與 `grafana/provisioning/*` 的改動，不會 pull、不 recreate，也不會碰 volume，所以這裡用手動備份、彩排、`up -d`，全部檢查通過後才用 `--manual-applied` 記錄。

## 會變的地方（2026-11-19 本機驗證過）

- **Angular 移除：** 10 個 repo dashboard（331 個 panel）皆為 React panel，無外部 plugin，JSON 不用遷移。
- **停用預裝 plugin：** `GF_PLUGINS_PREINSTALL_DISABLED=true` 停用 12.x 預設下載與更新的 4 個 Drilldown app（Explore → Metrics 不再出現，核心 Explore 不受影響）。
- **Unified storage 搬遷：** 以官方 opt-in（`GF_UNIFIED_STORAGE_*_ENABLEMIGRATION=true`）固定將 folders 與 dashboards 搬進同一個 `grafana.db` 的 unified storage（mode 5）並建立 `unified-search/` bleve index。**不可只降 image tag**，退回一律還原升級前備份。
- **既有 dashboard 的 `provisionedExternalId`：** 從 11.2.0 搬遷的 dashboard 在檔案內容尚未改寫前，`/api/dashboards/uid/<uid>` 的 `meta.provisionedExternalId` 會是空字串（log 出現 `Failed to create ProvisionedExternalId` warn），v1beta1 資源保有 `grafana.app/managedBy=classic-file-provisioning` 與 `grafana.app/sourcePath`。`scripts/central-deploy` 已補上此嚴格核對；檔案變更重載後 legacy 欄位即恢復。
- **UI 與匯出：** Scenes UI 與新 table／logs panel；匯出 JSON 路徑為 **Export → Export as code → Download file**（classic JSON，schemaVersion 42）。
- **Auth、CLI 與停機：** Cloudflare Access JWT 設定不變；breakglass `grafana cli admin reset-admin-password` 仍在；本機閒置記憶體約 66 → 127 MiB（主機 4 GB）。停機期間只有 Grafana UI 中斷，Prometheus、Loki、Alertmanager、Telegram 與遠端 ingestion 不受影響。

## 1. 時段、目標 SHA 檢查與基準（停機前）

- **時段：** 避開 UTC 18:15～19:30（備份與 Trading 時段）。
- **前提：** 升級 PR 已 merge 到 `master`，checkout 乾淨，Wan 在瀏覽器旁可即時驗證登入。先請 Wan 記下目前使用者與 service account 清單、自己的 user id、Admin 角色與已加星號 dashboard。

將 `<approved-sha>` 換成核准部署的完整或 12 碼 SHA。下列任一檢查失敗即印 `STOP` 並中止（不進下一步）：

```bash
cd /home/ubuntu/SkyEye
TARGET=<approved-sha>
BAK=/home/ubuntu/grafana-pre-12-backup
(
  set -euo pipefail
  [ -z "$(git status --short)" ] || { echo "STOP: checkout is dirty"; exit 1; }
  git fetch origin
  TARGET_FULL=$(git rev-parse --verify "${TARGET}^{commit}")
  APPLIED=$(cat .git/skyeye-central-deploy.applied 2>/dev/null || true)

  # C7: --dry-run --expect 只能因本案檔案拒絕；docker-compose.yml diff 只能動到 grafana service
  if OUT=$(scripts/central-deploy --dry-run --expect "$TARGET_FULL" 2>&1); then
    echo "STOP: expected central-deploy --dry-run to refuse compose/provisioning changes"; exit 1
  fi
  printf '%s\n' "$OUT"
  printf '%s\n' "$OUT" | grep -q 'need a service recreate or a manual decision' \
    || { echo "STOP: dry-run failed for an unexpected reason (check --expect / origin/master)"; exit 1; }
  printf '=== diff HEAD..TARGET docker-compose.yml ===\n'
  git diff "HEAD..$TARGET_FULL" -- docker-compose.yml
  if [ -n "$APPLIED" ] && [ "$APPLIED" != "$(git rev-parse HEAD)" ]; then
    printf '=== diff APPLIED..TARGET docker-compose.yml ===\n'
    git diff "$APPLIED..$TARGET_FULL" -- docker-compose.yml
  fi
)
```

**人工核對（C7）：** 確認 `--dry-run` 列出的手動路徑只有 `docker-compose.yml`、`grafana/provisioning/alerting/.gitkeep`、`grafana/provisioning/plugins/.gitkeep`，且上述 `docker-compose.yml` diff **只改動 `grafana` service**。若動到其他 service，**STOP 並回報 manager**（不可繼續，避免 `--manual-applied` 誤登記未套用的改動）。

通過後，記錄 `VOL`／`MNT` 與 Viewer 可見 UID 基準（C1、C5）：

```bash
cd /home/ubuntu/SkyEye
TARGET=<approved-sha>
BAK=/home/ubuntu/grafana-pre-12-backup
(
  set -euo pipefail
  install -d -m 700 "$BAK"
  VOL=$(sudo docker inspect "$(sudo docker compose ps -q grafana)" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/grafana"}}{{.Name}}{{end}}{{end}}')
  MNT=$(sudo docker volume inspect "$VOL" --format '{{.Mountpoint}}')
  [ -n "$VOL" ] && [ -n "$MNT" ] || { echo "STOP: cannot resolve grafana_data volume"; exit 1; }
  (umask 077 && printf 'VOL=%q\nMNT=%q\nTARGET=%q\n' "$VOL" "$MNT" "$(git rev-parse --verify "${TARGET}^{commit}")" >"$BAK/volume.env")

  curl -fsS http://127.0.0.1:3000/api/health | jq -e '.database == "ok" and .version == "11.2.0"' >/dev/null \
    || { echo "STOP: expected running Grafana 11.2.0"; exit 1; }

  # 產出目標 commit 的 repo dashboard UID→Folder 清單，並抓停機前 Viewer 可見 UID
  TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
  git archive "$TARGET" grafana/dashboards | tar -x -C "$TMPD"
  find "$TMPD/grafana/dashboards" -type f -name '*.json' -print0 | xargs -0 python3 -I -c '
import json, os, sys
rows = []
for p in sys.argv[1:]:
    d = json.load(open(p, encoding="utf-8"))
    rows.append((d["uid"], os.path.basename(os.path.dirname(p))))
for uid, folder in sorted(rows):
    print(f"{uid}\t{folder}")
' >"$BAK/repo-dashboards.tsv"
  printf 'header = "Authorization: Bearer %s"\n' "$(cat /home/ubuntu/.config/skyeye/grafana-viewer-token)" | \
    curl --config - -fsS 'http://127.0.0.1:3000/api/search?type=dash-db&limit=5000' | \
    jq -r '.[].uid' | LC_ALL=C sort -u >"$BAK/pre-uids.txt"
  MISSING=$(comm -23 <(cut -f1 "$BAK/repo-dashboards.tsv") "$BAK/pre-uids.txt")
  [ -z "$MISSING" ] || { echo "STOP: pre-upgrade Viewer misses repo UIDs: $MISSING"; exit 1; }
  printf 'Baseline OK: vol=%s repo=%d visible=%d\n' "$VOL" "$(wc -l <"$BAK/repo-dashboards.tsv")" "$(wc -l <"$BAK/pre-uids.txt")"
)
```

## 2. 先 pull image 並核對 digest

```bash
IMG='grafana/grafana:12.4.15@sha256:2894082f6cf7081aefdc1389265c04000812309208c190d75e8c65f7a30e4b7e'
(
  set -euo pipefail
  sudo docker pull "$IMG"
  GOT=$(sudo docker image inspect --format '{{index .RepoDigests 0}} user={{.Config.User}}' "$IMG")
  [ "$GOT" = 'grafana/grafana@sha256:2894082f6cf7081aefdc1389265c04000812309208c190d75e8c65f7a30e4b7e user=472' ] \
    || { echo "STOP: unexpected image metadata: $GOT"; exit 1; }
  sudo docker image inspect grafana/grafana:11.2.0 >/dev/null \
    || { echo "STOP: grafana/grafana:11.2.0 missing locally (needed for rollback)"; exit 1; }
  echo "Image OK: $GOT"
)
```

`grafana/grafana:11.2.0` 必須留在本機（不可 prune），退回時才不必下載。

## 3. Pull 後、停機前檢查磁碟空間（C6）

依 DONE 實測比例（舊 DB 1.88 MB、整個 volume tar 2.6 MB、遷移後 DB 3.21 MB 加 bleve index，外加 Grafana 文件要求的 annotation 重寫 2–3× 空間），以**整個 volume 大小 `VOL_BYTES`** 核算：備份檔案系統需 `4×`（`1×` tar + `3×` 彩排解壓與遷移成長，下限 64 MiB）；`/var/lib/docker` 需 `3×`（正式遷移成長，下限 64 MiB）；若兩者同一個檔案系統則加總為 **`7×`（下限 128 MiB）**。

```bash
BAK=/home/ubuntu/grafana-pre-12-backup
(
  set -euo pipefail
  source "$BAK/volume.env"
  VOL_BYTES=$(sudo du -sb "$MNT" | awk '{print $1}')
  read -r BAK_AVAIL BAK_FS < <(df -B1 --output=avail,target "$BAK" | tail -n 1)
  read -r DKR_AVAIL DKR_FS < <(df -B1 --output=avail,target /var/lib/docker | tail -n 1)
  python3 -I - "$VOL_BYTES" "$BAK_AVAIL" "$BAK_FS" "$DKR_AVAIL" "$DKR_FS" <<'PY'
import sys
vol, bak_a, bak_fs, dkr_a, dkr_fs = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5]
MiB = 1024 * 1024
if bak_fs == dkr_fs:
    need = max(vol * 7, 128 * MiB)
    if bak_a < need:
        sys.exit(f"STOP: shared fs {bak_fs} avail={bak_a} < need={need} (7x vol={vol})")
    print(f"Disk OK (shared {bak_fs}): vol={vol} avail={bak_a} >= need={need}")
else:
    need_bak, need_dkr = max(vol * 4, 64 * MiB), max(vol * 3, 64 * MiB)
    if bak_a < need_bak or dkr_a < need_dkr:
        sys.exit(f"STOP: insufficient disk (bak {bak_a}/{need_bak}, docker {dkr_a}/{need_dkr})")
    print(f"Disk OK: vol={vol} bak_avail={bak_a} dkr_avail={dkr_a}")
PY
)
```

## 4. 停 Grafana、備份 volume、用目標樹做無網路彩排

```bash
cd /home/ubuntu/SkyEye
BAK=/home/ubuntu/grafana-pre-12-backup
IMG='grafana/grafana:12.4.15@sha256:2894082f6cf7081aefdc1389265c04000812309208c190d75e8c65f7a30e4b7e'
(
  set -euo pipefail
  source "$BAK/volume.env"
  CID=""
  cleanup() { [ -z "$CID" ] || sudo docker rm -f "$CID" >/dev/null 2>&1 || true; sudo rm -rf "$BAK/rehearsal-data" "$BAK/rehearsal-tree" "$BAK/rehearsal-search.json"; }
  trap cleanup EXIT

  sudo docker compose stop grafana
  [ -z "$(sudo docker compose ps -q --status running grafana)" ] || { echo "STOP: grafana still running"; exit 1; }
  sudo tar --numeric-owner -cpf "$BAK/grafana_data.tar" -C "$MNT" .
  sudo chmod 600 "$BAK/grafana_data.tar"    # 含 token hash，勿放進 checkout

  # 用 TARGET 的 provisioning/dashboards 樹與備份複本彩排（與 production 掛載一致，不動正式 volume 與 checkout）
  sudo rm -rf "$BAK/rehearsal-data" "$BAK/rehearsal-tree"
  sudo mkdir -p "$BAK/rehearsal-data" && mkdir -p "$BAK/rehearsal-tree"
  sudo tar --numeric-owner -xpf "$BAK/grafana_data.tar" -C "$BAK/rehearsal-data"
  git archive "$TARGET" grafana/provisioning grafana/dashboards | tar -x -C "$BAK/rehearsal-tree"
  chmod -R a+rX "$BAK/rehearsal-tree"

  CID=$(sudo docker run -d --pull never --network none \
    -e GF_PLUGINS_PREINSTALL_DISABLED=true \
    -e GF_PLUGINS_PUBLIC_KEY_RETRIEVAL_DISABLED=true \
    -e GF_UNIFIED_STORAGE_FOLDERS_FOLDER_GRAFANA_APP_ENABLEMIGRATION=true \
    -e GF_UNIFIED_STORAGE_DASHBOARDS_DASHBOARD_GRAFANA_APP_ENABLEMIGRATION=true \
    -e GF_ANALYTICS_REPORTING_ENABLED=false \
    -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    -e GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false \
    -e GF_NEWS_NEWS_FEED_ENABLED=false \
    -v "$BAK/rehearsal-data:/var/lib/grafana" \
    -v "$BAK/rehearsal-tree/grafana/provisioning:/etc/grafana/provisioning:ro" \
    -v "$BAK/rehearsal-tree/grafana/dashboards:/var/lib/grafana/dashboards:ro" \
    "$IMG")

  OK=0
  for _ in $(seq 1 120); do
    if sudo docker exec "$CID" curl -fsS http://127.0.0.1:3000/api/health 2>/dev/null | \
      jq -e '.database == "ok" and .version == "12.4.15"' >/dev/null 2>&1; then OK=1; break; fi
    sleep 1
  done
  [ "$OK" -eq 1 ] || { sudo docker logs --tail 60 "$CID"; echo "STOP: rehearsal health timeout"; exit 1; }
  sleep 2
  LOGS=$(sudo docker logs "$CID" 2>&1)
  if printf '%s\n' "$LOGS" | grep -q 'level=error'; then
    printf '%s\n' "$LOGS" | grep 'level=error'; echo "STOP: level=error in rehearsal logs"; exit 1
  fi
  printf '%s\n' "$LOGS" | grep -q 'id="folders and dashboards migration"' \
    && printf '%s\n' "$LOGS" | grep -q 'Unified storage migrations completed successfully' \
    || { echo "STOP: unified storage migration did not complete in rehearsal"; exit 1; }

  # C5: 逐 UID 比對停機前清單，並核對每個 repo dashboard 的 folderTitle
  printf 'header = "Authorization: Bearer %s"\n' "$(cat /home/ubuntu/.config/skyeye/grafana-viewer-token)" | \
    sudo docker exec -i "$CID" curl --config - -fsS 'http://127.0.0.1:3000/api/search?type=dash-db&limit=5000' >"$BAK/rehearsal-search.json"
  diff -u "$BAK/pre-uids.txt" <(jq -r '.[].uid' "$BAK/rehearsal-search.json" | LC_ALL=C sort -u) \
    || { echo "STOP: rehearsal UID set differs from pre-upgrade"; exit 1; }
  python3 -I - "$BAK/repo-dashboards.tsv" "$BAK/rehearsal-search.json" <<'PY'
import json, sys
want = dict(line.rstrip("\n").split("\t") for line in open(sys.argv[1]))
got = {d["uid"]: d.get("folderTitle", "") for d in json.load(open(sys.argv[2]))}
bad = [f"{u}: got={got.get(u)!r} want={f!r}" for u, f in want.items() if got.get(u) != f]
if bad: sys.exit("STOP: rehearsal folder mismatch: " + "; ".join(bad))
PY
  rm -f "$BAK/rehearsal-search.json"
  echo "Rehearsal OK"
)
```

**彩排若印出 `STOP`：** 執行 `sudo docker compose start grafana` 恢復原本的 11.2.0 並到此為止（checkout 與正式 volume 皆未更動）。

## 5. 升級

```bash
cd /home/ubuntu/SkyEye
BAK=/home/ubuntu/grafana-pre-12-backup
(
  set -euo pipefail
  source "$BAK/volume.env"
  git merge --ff-only "$TARGET"
  grep -q 'image: grafana/grafana:12.4.15@sha256:2894082f6cf7081aefdc1389265c04000812309208c190d75e8c65f7a30e4b7e' docker-compose.yml \
    || { echo "STOP: unexpected grafana image in docker-compose.yml"; exit 1; }
  sudo docker compose up -d --no-deps grafana

  OK=0
  for _ in $(seq 1 120); do
    if curl -fsS http://127.0.0.1:3000/api/health 2>/dev/null | \
      jq -e '.database == "ok" and .version == "12.4.15"' >/dev/null 2>&1; then OK=1; break; fi
    sleep 1
  done
  if [ "$OK" -ne 1 ]; then
    sudo docker compose logs --tail 80 grafana
    echo "STOP: Grafana 12.4.15 health timeout (120s) — run ## 退回 11.2.0"
    exit 1
  fi
  curl -fsS http://127.0.0.1:3000/api/health; echo
)
```

## 6. 升級後檢查（全部通過才進第 7 步）

**6a. 自動檢查（任一項失敗即 `STOP`，不要進第 7 步，必要時執行 `## 退回 11.2.0`）：**

```bash
cd /home/ubuntu/SkyEye
BAK=/home/ubuntu/grafana-pre-12-backup
(
  set -euo pipefail
  gv() {
    printf 'header = "Authorization: Bearer %s"\n' "$(cat /home/ubuntu/.config/skyeye/grafana-viewer-token)" |
      curl --config - -fsS "http://127.0.0.1:3000$1"
  }
  gv '/api/search?type=dash-db&limit=5000' >"$BAK/post-search.json"
  diff -u "$BAK/pre-uids.txt" <(jq -r '.[].uid' "$BAK/post-search.json" | LC_ALL=C sort -u) \
    || { echo "STOP: post-upgrade UID set differs from pre-upgrade"; exit 1; }
  python3 -I - "$BAK/repo-dashboards.tsv" "$BAK/post-search.json" <<'PY'
import json, sys
want = dict(line.rstrip("\n").split("\t") for line in open(sys.argv[1]))
got = {d["uid"]: d.get("folderTitle", "") for d in json.load(open(sys.argv[2]))}
bad = [f"{u}: got={got.get(u)!r} want={f!r}" for u, f in want.items() if got.get(u) != f]
if bad: sys.exit("STOP: post-upgrade folder mismatch: " + "; ".join(bad))
PY
  rm -f "$BAK/post-search.json"
  gv /api/dashboards/uid/overview-all | jq -e '.dashboard.uid == "overview-all"' >/dev/null \
    || { echo "STOP: overview-all read failed"; exit 1; }
  gv /apis/dashboard.grafana.app/v1beta1/namespaces/default/dashboards/overview-all | \
    jq -e '.metadata.annotations["grafana.app/managedBy"] == "classic-file-provisioning" and (.metadata.annotations["grafana.app/sourcePath"] == "Overview/overview-all.json" or .metadata.annotations["grafana.app/sourcePath"] == "/var/lib/grafana/dashboards/Overview/overview-all.json")' >/dev/null \
    || { echo "STOP: overview-all v1beta1 source annotation mismatch"; exit 1; }
  AM_VER=$(gv /api/datasources/proxy/uid/alertmanager/api/v2/status | jq -er '.versionInfo.version')
  [ -n "$AM_VER" ] || { echo "STOP: Alertmanager proxy returned empty version"; exit 1; }
  if sudo docker compose logs --since 10m grafana | grep -qE 'level=error|Failed to authenticate request'; then
    sudo docker compose logs --since 10m grafana | grep -E 'level=error|Failed to authenticate request'
    echo "STOP: error found in grafana logs"
    exit 1
  fi
  sudo docker stats --no-stream --format '{{.Name}} mem={{.MemUsage}}' "$(sudo docker compose ps -q grafana)"
  echo "Post-upgrade API & log checks OK (Alertmanager=$AM_VER)"
)
```

**6b. 人工檢查（Wan，任一項失敗即 `STOP` 並執行 `## 退回 11.2.0`）：**

1. 新分頁開 `https://grafana.wanbrain.com`：無 Grafana 登入頁，Profile 的 user id、Admin 角色與已加星號 dashboard 與基準一致。
2. 逐一打開 10 個 repo dashboard：無 `Panel plugin not found` 或版面錯誤，新 logs／table panel 顯示正常。
3. Explore 分別查 `Prometheus` 與 `Loki`（含 Loki label 選單），並確認 Alerting 畫面正常。

## 7. 記錄部署（僅在第 6a 與 6b 全部通過後執行）

```bash
cd /home/ubuntu/SkyEye
BAK=/home/ubuntu/grafana-pre-12-backup
(
  set -euo pipefail
  source "$BAK/volume.env"
  scripts/central-deploy --manual-applied "$TARGET"
)
```

觀察穩定後再決定何時清理 `$BAK`（保留期間維持 mode 700／600，內含 token hash）。

## 退回 11.2.0

> **不可只降 image tag：** unified storage 與 RBAC schema 已搬遷，必須還原升級前的 `grafana_data` 備份。**升級後才寫入的資料（新帳號、star、UI 改動、新 service account）會遺失。**
>
> **不可用 `docker cp` 還原 `grafana.db`：** 複製進 container 會變成 `root` 所有，uid 472 的 Grafana 會報 `permission denied`。

**1. 確認 Grafana 停止、先在獨立目錄解開並驗證備份（存在、uid 472、`PRAGMA integrity_check=ok`），全部通過才切換 volume 並啟動 11.2.0（任一步失敗立刻中止，不動正式 volume、不啟動 11.2.0）：**

```bash
cd /home/ubuntu/SkyEye
BAK=/home/ubuntu/grafana-pre-12-backup
(
  set -euo pipefail
  [ -r "$BAK/volume.env" ] || { echo "STOP: missing $BAK/volume.env"; exit 1; }
  source "$BAK/volume.env"
  [ -n "$VOL" ] && [ -n "$MNT" ] || { echo "STOP: empty VOL/MNT in volume.env"; exit 1; }
  LIVE_MNT=$(sudo docker volume inspect "$VOL" --format '{{.Mountpoint}}')
  [ "$LIVE_MNT" = "$MNT" ] || { echo "STOP: volume mountpoint mismatch ($LIVE_MNT != $MNT)"; exit 1; }

  # 即使 12.x container 已退出仍可安全執行；確認完全停止
  sudo docker compose stop grafana
  [ -z "$(sudo docker compose ps -q --status running grafana)" ] || { echo "STOP: grafana is still running"; exit 1; }

  # 先解到獨立目錄並完整驗證，此時正式 volume 尚未更動
  sudo test -r "$BAK/grafana_data.tar" || { echo "STOP: backup tar unreadable"; exit 1; }
  STAGE="$BAK/rollback-stage"
  trap 'sudo rm -rf "$STAGE"' EXIT
  sudo rm -rf "$STAGE" && sudo mkdir -p "$STAGE"
  sudo tar --numeric-owner -xpf "$BAK/grafana_data.tar" -C "$STAGE" || { echo "STOP: tar extract failed"; exit 1; }
  sudo test -s "$STAGE/grafana.db" || { echo "STOP: grafana.db missing or empty in backup"; exit 1; }
  DB_UID=$(sudo stat -c '%u' "$STAGE/grafana.db")
  [ "$DB_UID" = "472" ] || { echo "STOP: staged grafana.db uid=$DB_UID (want 472)"; exit 1; }
  sudo python3 -I -c '
import sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
rows = [r[0] for r in con.execute("PRAGMA integrity_check")]
assert rows == ["ok"], rows
print("staged grafana.db integrity_check=ok")
' "$STAGE/grafana.db" || { echo "STOP: staged grafana.db failed PRAGMA integrity_check"; exit 1; }

  # 驗證通過才切換 volume 內容
  sudo find "$MNT" -mindepth 1 -delete
  sudo cp -a "$STAGE/." "$MNT/"
  sudo rm -rf "$STAGE"
  sudo test -s "$MNT/grafana.db" && [ "$(sudo stat -c '%u' "$MNT/grafana.db")" = "472" ] \
    || { echo "STOP: restored grafana.db check failed"; exit 1; }

  cat >/home/ubuntu/gf-rollback.yml <<'EOF'
services:
  grafana:
    image: grafana/grafana:11.2.0
    environment:
      GF_PLUGINS_PREINSTALL_DISABLED: null
      GF_UNIFIED_STORAGE_FOLDERS_FOLDER_GRAFANA_APP_ENABLEMIGRATION: null
      GF_UNIFIED_STORAGE_DASHBOARDS_DASHBOARD_GRAFANA_APP_ENABLEMIGRATION: null
EOF
  sudo docker compose -f docker-compose.yml -f /home/ubuntu/gf-rollback.yml up -d --no-deps grafana

  OK=0
  for _ in $(seq 1 120); do
    if curl -fsS http://127.0.0.1:3000/api/health 2>/dev/null | \
      jq -e '.database == "ok" and .version == "11.2.0"' >/dev/null 2>&1; then OK=1; break; fi
    sleep 1
  done
  if [ "$OK" -ne 1 ]; then
    sudo docker compose logs --tail 80 grafana
    echo "STOP: rollback Grafana 11.2.0 health timeout (120s)"
    exit 1
  fi
  curl -fsS http://127.0.0.1:3000/api/health; echo
)
```

請 Wan 重新驗證 Cloudflare Access 登入與主要 dashboard。Override 生效期間**不要**跑不帶 `-f` 的 `docker compose up -d`。

**2. 開 revert PR，merge 後移掉 override 並記錄：**

```bash
cd /home/ubuntu/SkyEye
(
  set -euo pipefail
  git fetch origin
  git merge --ff-only <revert-sha>
  grep -q 'image: grafana/grafana:11.2.0' docker-compose.yml || { echo "STOP: compose not reverted"; exit 1; }
  sudo docker compose up -d --no-deps --force-recreate grafana
  rm /home/ubuntu/gf-rollback.yml
  CFG=$(sudo docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$(sudo docker compose ps -q grafana)")
  [ "$CFG" = "/home/ubuntu/SkyEye/docker-compose.yml" ] || { echo "STOP: unexpected config_files=$CFG"; exit 1; }
  scripts/central-deploy --manual-applied <revert-sha>
)
```
