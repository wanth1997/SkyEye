# Grafana 升級：11.2.0 → 12.4.15（monitoring-prod）

`scripts/central-deploy` 會拒絕 `docker-compose.yml` 與 `grafana/provisioning/*` 改動，不會 pull、recreate 或碰 volume，因此採手動備份、彩排、`up -d`，全部檢查通過後才以 `--manual-applied` 記錄。

## 會變的地方（2026-11-19 本機驗證過）

- **Angular 移除與停用預裝 plugin：** 10 個 repo dashboard（331 panel）全為 React panel；`GF_PLUGINS_PREINSTALL_DISABLED=true` 停用 4 個自動下載的 Drilldown app（Explore → Metrics 不再出現，核心 Explore 不變）。
- **Unified storage 搬遷：** 官方 opt-in 將 folders／dashboards 搬進同一個 `grafana.db`（mode 5）並建 `unified-search/` bleve index。**不可只降 image tag**，退回一律還原升級前備份。既有 dashboard 搬遷後在檔案改寫前，legacy `meta.provisionedExternalId` 為空，改由 v1beta1 annotation 核對（`scripts/central-deploy` 已支援）。
- **UI、Auth 與停機：** Scenes UI、新 table／logs panel，匯出為 **Export → Export as code → Download file**（classic JSON，schemaVersion 42）。Cloudflare Access JWT 與 breakglass CLI 不變；本機閒置記憶體約 66 → 127 MiB。停機期間僅 Grafana UI 中斷，監控收集與告警照常。

## 0. 載入共用檢查函式（先執行一次；重開 shell 只要 `source /home/ubuntu/grafana-pre-12-backup/lib.sh`）

```bash
cd /home/ubuntu/SkyEye
BAK=/home/ubuntu/grafana-pre-12-backup
IMG='grafana/grafana:12.4.15@sha256:2894082f6cf7081aefdc1389265c04000812309208c190d75e8c65f7a30e4b7e'
install -d -m 700 "$BAK"
cat >"$BAK/lib.sh" <<'EOF'
BAK=/home/ubuntu/grafana-pre-12-backup
IMG='grafana/grafana:12.4.15@sha256:2894082f6cf7081aefdc1389265c04000812309208c190d75e8c65f7a30e4b7e'
stop() { printf 'STOP: %s\n' "$*" >&2; return 1; }
gv() { # gv PATH [CONTAINER_ID]
  local t; t=$(cat /home/ubuntu/.config/skyeye/grafana-viewer-token) || { stop "cannot read grafana-viewer-token"; return 1; }
  if [ -n "${2:-}" ]; then printf 'header = "Authorization: Bearer %s"\n' "$t" | sudo docker exec -i "$2" curl --config - -fsS --max-time 10 "http://127.0.0.1:3000$1" || return 1
  else printf 'header = "Authorization: Bearer %s"\n' "$t" | curl --config - -fsS --max-time 10 "http://127.0.0.1:3000$1" || return 1; fi
}
grafana_stopped() { # C1: 先確認 docker compose ps 成功，再確認無執行中 container
  local ids
  ids=$(sudo docker compose ps -q --status running grafana) || { stop "docker compose ps failed"; return 1; }
  [ -z "$ids" ] || { stop "grafana still running ($ids)"; return 1; }
}
wait_health() { # C9: wait_health WANT_VER [CID] [DEADLINE=120] — 每輪算一次剩餘秒數，只驗證 curl rc=0
  local want="$1" cid="${2:-}" deadline="${3:-120}" rem out rc
  local end=$((SECONDS + deadline))
  while :; do
    rem=$((end - SECONDS))
    [ "$rem" -gt 0 ] || break
    [ "$rem" -gt 5 ] && rem=5
    rc=0
    if [ -n "$cid" ]; then out=$(sudo docker exec "$cid" curl -fsS --max-time "$rem" http://127.0.0.1:3000/api/health 2>/dev/null) || rc=$?
    else out=$(curl -fsS --max-time "$rem" http://127.0.0.1:3000/api/health 2>/dev/null) || rc=$?; fi
    if [ "$rc" -eq 0 ] && [ -n "$out" ] && jq -e --arg v "$want" '.database == "ok" and .version == $v' >/dev/null 2>&1 <<<"$out"; then
      printf '%s\n' "$out"; return 0
    fi
    [ "$((end - SECONDS))" -gt 0 ] || break
    sleep 1
  done
  stop "Grafana $want health timeout (${deadline}s)"; return 1
}
check_logs() { # C4: check_logs NAME [CID] [EXPECT_MIG] — 先落檔再直接 grep，不經管線
  local log="$BAK/$1.log" cid="${2:-}" mig="${3:-}"
  if [ -n "$cid" ]; then sudo docker logs "$cid" >"$log" 2>&1 || { stop "docker logs $cid failed"; return 1; }
  else sudo docker compose logs --since 10m grafana >"$log" 2>&1 || { stop "docker compose logs failed"; return 1; }; fi
  if grep -qE 'level=error|Failed to authenticate request' "$log"; then
    grep -m 10 -E 'level=error|Failed to authenticate request' "$log" >&2 || true
    stop "error found in $log"; return 1
  fi
  if [ -n "$mig" ]; then
    grep -qE '(msg="Migration successfully executed".*id="folders and dashboards migration"|id="folders and dashboards migration".*msg="Migration successfully executed")' "$log" \
      && grep -qF 'msg="Unified storage migrations completed successfully"' "$log" \
      || { stop "unified storage migration missing in $log"; return 1; }
  fi
}
compare_uids() { # C5: compare_uids NAME [CID] — 逐 UID 比對 + 核對 repo folderTitle
  local f="$BAK/$1-search.json" u="$BAK/$1-uids.txt"
  gv '/api/search?type=dash-db&limit=5000' "${2:-}" >"$f" || { stop "search API failed"; return 1; }
  jq -r '.[].uid' "$f" | LC_ALL=C sort -u >"$u" || { stop "$1 invalid search JSON"; return 1; }
  diff -u "$BAK/pre-uids.txt" "$u" || { stop "$1 UID set differs"; return 1; }
  python3 -I -c '
import json, sys
want = dict(line.rstrip("\n").split("\t") for line in open(sys.argv[1]))
got = {d["uid"]: d.get("folderTitle", "") for d in json.load(open(sys.argv[2]))}
bad = [f"{u}: got={got.get(u)!r} want={f!r}" for u, f in want.items() if got.get(u) != f]
if bad: sys.exit("STOP: folder mismatch: " + "; ".join(bad))
' "$BAK/repo-dashboards.tsv" "$f" || return 1
  rm -f "$f" "$u"
}
EOF
source /home/ubuntu/grafana-pre-12-backup/lib.sh
```

## 1. 時段、鎖定目標 SHA、Compose diff 與基準（停機前）

避開 UTC 18:15～19:30；確認 Wan 在瀏覽器旁並已記下使用者／service account 清單、自己的 user id、Admin 角色與 star。輸入一次核准 SHA（`<approved-sha>`）：

```bash
TARGET=<approved-sha>
(
  set -euo pipefail; cd /home/ubuntu/SkyEye; source /home/ubuntu/grafana-pre-12-backup/lib.sh
  [ -z "$(git status --short)" ] || stop "checkout is dirty"
  git fetch origin
  TARGET_FULL=$(git rev-parse --verify "${TARGET}^{commit}") || stop "invalid TARGET"
  APPLIED=$(cat .git/skyeye-central-deploy.applied) || stop "missing applied SHA — ask manager for base"
  [[ "$APPLIED" =~ ^[0-9a-f]{40}$ ]] || stop "invalid applied SHA format ($APPLIED) — ask manager for base"
  git rev-parse --verify "${APPLIED}^{commit}" >/dev/null || stop "unknown applied SHA ($APPLIED) — ask manager for base"
  if OUT=$(scripts/central-deploy --dry-run --expect "$TARGET_FULL" 2>&1); then stop "expected dry-run refusal"; fi
  printf '%s\n' "$OUT"
  grep -q 'need a service recreate or a manual decision' <<<"$OUT" || stop "unexpected dry-run error"
  git diff "$APPLIED..$TARGET_FULL" -- docker-compose.yml
  VOL=$(sudo docker inspect "$(sudo docker compose ps -q grafana)" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/grafana"}}{{.Name}}{{end}}{{end}}')
  MNT=$(sudo docker volume inspect "$VOL" --format '{{.Mountpoint}}')
  [ -n "$VOL" ] && [ -n "$MNT" ] || stop "cannot resolve grafana_data volume"
  (umask 077 && printf 'VOL=%q\nMNT=%q\nTARGET=%q\nAPPLIED=%q\n' "$VOL" "$MNT" "$TARGET_FULL" "$APPLIED" >"$BAK/volume.env")
  curl -fsS --max-time 5 http://127.0.0.1:3000/api/health | jq -e '.database == "ok" and .version == "11.2.0"' >/dev/null || stop "expected running Grafana 11.2.0"
  TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
  git archive "$TARGET_FULL" grafana/dashboards | tar -x -C "$TMPD"
  find "$TMPD/grafana/dashboards" -type f -name '*.json' -print0 | xargs -0 python3 -I -c \
    'import json,os,sys; [print(json.load(open(p,encoding="utf-8"))["uid"]+"\t"+os.path.basename(os.path.dirname(p))) for p in sorted(sys.argv[1:])]' | LC_ALL=C sort >"$BAK/repo-dashboards.tsv"
  gv '/api/search?type=dash-db&limit=5000' | jq -r '.[].uid' | LC_ALL=C sort -u >"$BAK/pre-uids.txt"
  MISSING=$(comm -23 <(cut -f1 "$BAK/repo-dashboards.tsv") "$BAK/pre-uids.txt")
  [ -z "$MISSING" ] || stop "pre-upgrade Viewer misses repo UIDs: $MISSING"
  printf 'Step 1 OK: target=%s applied=%s vol=%s visible=%d\n' "${TARGET_FULL:0:12}" "${APPLIED:0:12}" "$VOL" "$(wc -l <"$BAK/pre-uids.txt")"
)
```

**人工核對：** 確認 dry-run 拒絕路徑僅為 `docker-compose.yml` 與 `grafana/provisioning/{alerting,plugins}/.gitkeep`，且 `APPLIED..TARGET` 的 `docker-compose.yml` diff **只改動 `grafana` service**；否則 **STOP 並詢問 manager**。

## 2. Pull image 並核對 digest，接著量測整個 volume 空間（停機前）

依 DONE 實測（舊 DB 1.88 MB、tar 2.6 MB、遷移後 DB 3.21 MB + index + annotation 2–3× 重寫），以整個 volume `VOL_BYTES` 核算：備份 FS 需 `4×`（`1×` tar + `3×` 彩排複本與成長，下限 64 MiB）；`/var/lib/docker` 需 `3×`（下限 64 MiB）；同 FS 加總 **`7×`（下限 128 MiB）**。

```bash
(
  set -euo pipefail; cd /home/ubuntu/SkyEye; source /home/ubuntu/grafana-pre-12-backup/lib.sh; source "$BAK/volume.env"
  sudo docker pull "$IMG"
  GOT=$(sudo docker image inspect --format '{{index .RepoDigests 0}} user={{.Config.User}}' "$IMG")
  [ "$GOT" = 'grafana/grafana@sha256:2894082f6cf7081aefdc1389265c04000812309208c190d75e8c65f7a30e4b7e user=472' ] || stop "unexpected image: $GOT"
  sudo docker image inspect grafana/grafana:11.2.0 >/dev/null || stop "11.2.0 missing locally (do not prune)"
  VOL_BYTES=$(sudo du -sb "$MNT" | awk '{print $1}')
  read -r BAK_A BAK_FS < <(df -B1 --output=avail,target "$BAK" | tail -n 1)
  read -r DKR_A DKR_FS < <(df -B1 --output=avail,target /var/lib/docker | tail -n 1)
  python3 -I -c '
import sys; v, ba, bf, da, df = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5]; M = 1024*1024
if bf == df:
    need = max(v*7, 128*M); assert ba >= need, f"STOP: shared {bf} avail={ba} < need={need} (7x vol={v})"
else:
    nb, nd = max(v*4, 64*M), max(v*3, 64*M); assert ba >= nb and da >= nd, f"STOP: disk bak={ba}/{nb} docker={da}/{nd}"
print(f"Step 2 OK: image verified, vol={v} bytes")
' "$VOL_BYTES" "$BAK_A" "$BAK_FS" "$DKR_A" "$DKR_FS"
)
```

## 3. 停 Grafana、備份 volume、用目標樹做無網路彩排

```bash
(
  set -euo pipefail; cd /home/ubuntu/SkyEye; source /home/ubuntu/grafana-pre-12-backup/lib.sh; source "$BAK/volume.env"
  CID=""
  trap '[ -z "$CID" ] || sudo docker rm -f "$CID" >/dev/null 2>&1 || true; sudo rm -rf "$BAK/rehearsal-data" "$BAK/rehearsal-tree" "$BAK/rehearsal-search.json" "$BAK/rehearsal-uids.txt"' EXIT
  sudo docker compose stop grafana; grafana_stopped
  sudo tar --numeric-owner -cpf "$BAK/grafana_data.tar" -C "$MNT" .
  sudo chmod 600 "$BAK/grafana_data.tar"
  sudo rm -rf "$BAK/rehearsal-data" "$BAK/rehearsal-tree"
  sudo mkdir -p "$BAK/rehearsal-data" && mkdir -p "$BAK/rehearsal-tree"
  sudo tar --numeric-owner -xpf "$BAK/grafana_data.tar" -C "$BAK/rehearsal-data"
  git archive "$TARGET" grafana/provisioning grafana/dashboards | tar -x -C "$BAK/rehearsal-tree"
  chmod -R a+rX "$BAK/rehearsal-tree"
  CID=$(sudo docker run -d --pull never --network none \
    -e GF_PLUGINS_PREINSTALL_DISABLED=true -e GF_PLUGINS_PUBLIC_KEY_RETRIEVAL_DISABLED=true \
    -e GF_UNIFIED_STORAGE_FOLDERS_FOLDER_GRAFANA_APP_ENABLEMIGRATION=true \
    -e GF_UNIFIED_STORAGE_DASHBOARDS_DASHBOARD_GRAFANA_APP_ENABLEMIGRATION=true \
    -e GF_ANALYTICS_REPORTING_ENABLED=false -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    -e GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false -e GF_NEWS_NEWS_FEED_ENABLED=false \
    -v "$BAK/rehearsal-data:/var/lib/grafana" \
    -v "$BAK/rehearsal-tree/grafana/provisioning:/etc/grafana/provisioning:ro" \
    -v "$BAK/rehearsal-tree/grafana/dashboards:/var/lib/grafana/dashboards:ro" "$IMG")
  wait_health 12.4.15 "$CID" || { sudo docker logs --tail 60 "$CID" >&2; stop "rehearsal health timeout"; }
  sleep 2
  check_logs rehearsal "$CID" 1
  compare_uids rehearsal "$CID"
  echo "Rehearsal OK"
)
```

**復原點（彩排失敗）：** 此步驟**只要非零退出**（不論印出 `STOP` 或任何命令失敗），就執行 `sudo docker compose start grafana` 啟回原 11.2.0 並中止升級（checkout 與正式 volume 皆未更動）。

## 4. 升級

```bash
(
  set -euo pipefail; cd /home/ubuntu/SkyEye; source /home/ubuntu/grafana-pre-12-backup/lib.sh; source "$BAK/volume.env"
  git merge --ff-only "$TARGET"
  grep -q "image: $IMG" docker-compose.yml || stop "unexpected grafana image in docker-compose.yml"
  sudo docker compose up -d --no-deps grafana
  wait_health 12.4.15 || { sudo docker compose logs --tail 80 grafana >&2; stop "health timeout — run ## 退回 11.2.0"; }
)
```

## 5. 升級後檢查（全部通過才進第 6 步）

```bash
(
  set -euo pipefail; cd /home/ubuntu/SkyEye; source /home/ubuntu/grafana-pre-12-backup/lib.sh
  compare_uids post-upgrade
  gv /api/dashboards/uid/overview-all | jq -e '.dashboard.uid == "overview-all"' >/dev/null || stop "overview-all read failed"
  gv /apis/dashboard.grafana.app/v1beta1/namespaces/default/dashboards/overview-all | \
    jq -e '.metadata.annotations["grafana.app/managedBy"] == "classic-file-provisioning" and (.metadata.annotations["grafana.app/sourcePath"] == "Overview/overview-all.json" or .metadata.annotations["grafana.app/sourcePath"] == "/var/lib/grafana/dashboards/Overview/overview-all.json")' >/dev/null || stop "v1beta1 source annotation mismatch"
  AM_WANT=$(awk '$1=="image:" && $2 ~ /^prom\/alertmanager:v/ { sub(/^.*:v/, "", $2); sub(/@.*/, "", $2); print $2; exit }' docker-compose.yml)
  AM_GOT=$(gv /api/datasources/proxy/uid/alertmanager/api/v2/status | jq -er '.versionInfo.version')
  [ -n "$AM_WANT" ] && [ "$AM_GOT" = "$AM_WANT" ] || stop "Alertmanager version got=${AM_GOT:-empty} want=${AM_WANT:-empty}"
  check_logs post-upgrade
  sudo docker stats --no-stream --format '{{.Name}} mem={{.MemUsage}}' "$(sudo docker compose ps -q grafana)"
  echo "Post-upgrade API & log checks OK (Alertmanager=$AM_GOT)"
)
```

**人工檢查（Wan，任一項失敗即 STOP 並執行 `## 退回 11.2.0`）：** (1) 新分頁開 `https://grafana.wanbrain.com`，無 Grafana 登入頁，Profile user id／Admin／star 與基準一致；(2) 逐一開 10 個 repo dashboard，無 `Panel plugin not found` 或版面錯誤，新 logs／table panel 正常；(3) Explore 分別查 `Prometheus` 與 `Loki`（含 label 選單），並看 Alerting 畫面。

## 6. 記錄部署（僅在第 5 步自動與人工檢查全部通過後執行）

```bash
( set -euo pipefail; cd /home/ubuntu/SkyEye; source /home/ubuntu/grafana-pre-12-backup/volume.env; scripts/central-deploy --manual-applied "$TARGET" )
```

穩定後再依需清理 `$BAK`（保留期間維持 mode 700／600）。

## 退回 11.2.0

> **不可只降 image tag**（升級後新寫入資料會遺失）；**不可用 `docker cp` 還原 `grafana.db`**（會變 root 所有導致 uid 472 `permission denied`）。
> **復原點：** 在開始清除正式 volume（`find "$MNT" -mindepth 1 -delete`）之前，任何失敗都會中止且不動正式 volume、不啟動 11.2.0。**一旦開始清除 volume，後續任何失敗都維持停機（不可啟動 11.2.0），並直接從已驗證的 `$BAK/grafana_data.tar` 重新執行完整還原。**

**1. 確認停機、獨立解壓驗證備份（存在、uid 472、`PRAGMA integrity_check=ok`），通過才切換 volume 並啟動 11.2.0：**

```bash
(
  set -euo pipefail; cd /home/ubuntu/SkyEye; source /home/ubuntu/grafana-pre-12-backup/lib.sh
  [ -r "$BAK/volume.env" ] || stop "missing $BAK/volume.env"
  source "$BAK/volume.env"
  [ -n "$VOL" ] && [ -n "$MNT" ] || stop "empty VOL/MNT"
  [ "$(sudo docker volume inspect "$VOL" --format '{{.Mountpoint}}')" = "$MNT" ] || stop "mountpoint mismatch"
  sudo docker compose stop grafana; grafana_stopped
  sudo test -r "$BAK/grafana_data.tar" || stop "backup tar unreadable"
  STAGE="$BAK/rollback-stage"; trap 'sudo rm -rf "$STAGE"' EXIT
  sudo rm -rf "$STAGE" && sudo mkdir -p "$STAGE"
  sudo tar --numeric-owner -xpf "$BAK/grafana_data.tar" -C "$STAGE" || stop "tar extract failed"
  sudo test -s "$STAGE/grafana.db" || stop "grafana.db missing or empty"
  DB_UID=$(sudo stat -c '%u' "$STAGE/grafana.db"); [ "$DB_UID" = "472" ] || stop "staged grafana.db uid=$DB_UID (want 472)"
  sudo python3 -I -c 'import sqlite3,sys; r=[x[0] for x in sqlite3.connect(f"file:{sys.argv[1]}?mode=ro",uri=True).execute("PRAGMA integrity_check")]; assert r==["ok"],r' "$STAGE/grafana.db" || stop "PRAGMA integrity_check failed"

  # 驗證通過才切換 volume 內容（此行後失敗請維持停機並重跑完整還原）
  sudo find "$MNT" -mindepth 1 -delete || { stop "volume clear failed — Grafana stays stopped; redo the full restore from the verified tar"; exit 1; }
  sudo cp -a "$STAGE/." "$MNT/" || { stop "backup copy failed — Grafana stays stopped; redo the full restore from the verified tar"; exit 1; }
  sudo rm -rf "$STAGE" || { stop "stage cleanup failed — Grafana stays stopped; redo the full restore from the verified tar"; exit 1; }
  sudo test -s "$MNT/grafana.db" || { stop "restored grafana.db missing or empty — Grafana stays stopped; redo the full restore from the verified tar"; exit 1; }
  [ "$(sudo stat -c '%u' "$MNT/grafana.db")" = "472" ] || { stop "restored grafana.db uid mismatch — Grafana stays stopped; redo the full restore from the verified tar"; exit 1; }

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
  if ! wait_health 11.2.0; then
    sudo docker compose -f docker-compose.yml -f /home/ubuntu/gf-rollback.yml logs --tail 80 grafana >"$BAK/rollback-failed.log" 2>&1 || true
    cat "$BAK/rollback-failed.log" >&2 || true
    sudo docker compose -f docker-compose.yml -f /home/ubuntu/gf-rollback.yml stop grafana || true
    grafana_stopped || { stop "rollback 11.2.0 health failed and grafana could not be confirmed stopped; check $BAK/rollback-failed.log"; exit 1; }
    stop "rollback 11.2.0 health failed — log saved to $BAK/rollback-failed.log; Grafana is stopped, redo the full restore from the verified tar"
    exit 1
  fi
)
```

請 Wan 重新驗證登入與主要 dashboard。Override 生效期間勿跑不帶 `-f` 的 `docker compose up -d`。

**2. Revert PR merge 後移除 override 並記錄：**

```bash
(
  set -euo pipefail; cd /home/ubuntu/SkyEye; source /home/ubuntu/grafana-pre-12-backup/lib.sh
  git fetch origin && git merge --ff-only <revert-sha>
  grep -q 'image: grafana/grafana:11.2.0' docker-compose.yml || stop "compose not reverted"
  sudo docker compose up -d --no-deps --force-recreate grafana
  rm /home/ubuntu/gf-rollback.yml
  CFG=$(sudo docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$(sudo docker compose ps -q grafana)")
  [ "$CFG" = "/home/ubuntu/SkyEye/docker-compose.yml" ] || stop "unexpected config_files=$CFG"
  scripts/central-deploy --manual-applied <revert-sha>
)
```
