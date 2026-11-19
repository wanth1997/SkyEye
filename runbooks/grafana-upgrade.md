# Grafana 升級：11.2.0 → 12.4.15（monitoring-prod）

這是換中央 Grafana image 與新增 12.x 環境變數的手動部署流程。`scripts/central-deploy` 會拒絕 `docker-compose.yml` 的改動，不會 pull、不 recreate，也不會碰 volume，所以這裡用手動備份、彩排、`up -d`，最後用 `--manual-applied` 記錄。

為什麼要升：`grafana/grafana:11.2.0` 已無支援，缺少多項 Viewer 或已登入使用者可觸發的 CVE 修正（Loki／Prometheus datasource path traversal 與 SSRF、Live crash、XSS 等）。`12.4.15` 為 12.x 最新 patch，支援至 2027-05-24，並以 digest pin 住。

## 會變的地方（2026-11-19 本機驗證過）

- **Angular 移除：** 10 個 dashboard（331 個 panel）皆為 React panel，無外部 plugin，JSON 不用遷移。
- **停用預裝 plugin：** `GF_PLUGINS_PREINSTALL_DISABLED=true` 停用 12.x 啟動時自動下載與更新的 4 個 Drilldown app。11.2 內建的 Explore → Metrics 不再出現，核心 Explore 不受影響。
- **Unified storage 搬遷：** 以官方 opt-in（`GF_UNIFIED_STORAGE_*_ENABLEMIGRATION=true`）固定將 folders 與 dashboards 搬進同一個 `grafana.db` 的 unified storage（mode 5）並建立 `unified-search/` bleve index。**不可只把 image 降回 11.2.0**，退回一律還原升級前備份。
- **既有 dashboard 的 `provisionedExternalId`：** 從 11.2.0 搬遷過來的 dashboard 在檔案內容尚未變動前，`/api/dashboards/uid/<uid>` 的 `meta.provisionedExternalId` 會是空字串（Grafana log 會出現 `Failed to create ProvisionedExternalId` warn），但 v1beta1 資源的 `grafana.app/managedBy=classic-file-provisioning` 與 `grafana.app/sourcePath` 正常；日後任一 dashboard JSON 變更重載後即自動恢復。
- **UI 與匯出：** 改為 Scenes UI 與新 table／logs panel。匯出 JSON 路徑為 **Export → Export as code → Download file**（classic JSON，schemaVersion 42）。
- **Auth 與 CLI：** Cloudflare Access JWT 設定完全不變；breakglass `grafana cli admin reset-admin-password --password-from-stdin` 仍在。
- **記憶體與停機：** 本機閒置約 66 → 127 MiB（主機 4 GB）。停機期間只有 Grafana UI 中斷（停機、備份、彩排到 12.4.15 health ok）；Prometheus、Loki、Alertmanager、Telegram 與遠端 ingestion 不受影響。

## 1. 時段與基準

- **時段：** 避開 UTC 18:15～19:30（備份與 Trading 時段）。
- **前提：** 升級 PR 已 merge 到 `master`，checkout 乾淨（`git status --short` 無輸出），Wan 在瀏覽器旁可即時驗證登入。
- **先記下 UI 基準（Wan）：** 記下目前使用者清單、service account 清單，以及自己的 user id、Admin 角色與已加星號的 dashboard。

記錄主機基準到 checkout 外面（mode 700 目錄）：

```bash
cd /home/ubuntu/SkyEye
BAK=/home/ubuntu/grafana-pre-12-backup
install -d -m 700 "$BAK"
VOL=$(sudo docker inspect "$(sudo docker compose ps -q grafana)" \
  --format '{{range .Mounts}}{{if eq .Destination "/var/lib/grafana"}}{{.Name}}{{end}}{{end}}')
MNT=$(sudo docker volume inspect "$VOL" --format '{{.Mountpoint}}')
{
  date -u
  curl -fsS http://127.0.0.1:3000/api/health; echo
  printf 'volume=%s mountpoint=%s\n' "$VOL" "$MNT"
  sudo ls -lh "$MNT/grafana.db"
  df -h /var/lib/docker "$BAK"
} | tee "$BAK/baseline.txt"
```

預期：版本 `11.2.0`，`/var/lib/docker` 與 `$BAK` 可用空間至少為 `grafana.db` 的 3 倍（annotation 全表重寫與備份用）。

## 2. 先 pull image 並核對 digest

```bash
IMG='grafana/grafana:12.4.15@sha256:2894082f6cf7081aefdc1389265c04000812309208c190d75e8c65f7a30e4b7e'
sudo docker pull "$IMG"
sudo docker image inspect --format '{{index .RepoDigests 0}} user={{.Config.User}}' "$IMG"
# 預期：grafana/grafana@sha256:2894082f6cf7081aefdc1389265c04000812309208c190d75e8c65f7a30e4b7e user=472
sudo docker image inspect grafana/grafana:11.2.0 >/dev/null && echo "11.2.0 still local (rollback)"
```

Digest 不符或 user 不是 `472` 就停下。`grafana/grafana:11.2.0` 必須留在本機（不可 prune），退回時才不必下載。

## 3. Dry-run

```bash
scripts/central-deploy --dry-run
```

預期因 `docker-compose.yml`（需 recreate）被拒絕。若列出預期以外的檔案，先停下確認。

## 4. 停 Grafana、備份 volume、用複本無網路彩排

```bash
cd /home/ubuntu/SkyEye
sudo docker compose stop grafana
sudo tar --numeric-owner -cpf "$BAK/grafana_data.tar" -C "$MNT" .
sudo chmod 600 "$BAK/grafana_data.tar"    # 含 token hash，勿放進 checkout
ls -lh "$BAK/grafana_data.tar"

# 用備份複本跑一次無網路 12.4.15 彩排（不動正式 volume 與 checkout）
REHEARSE="$BAK/rehearsal-data"
sudo rm -rf "$REHEARSE" && sudo mkdir -p "$REHEARSE"
sudo tar --numeric-owner -xpf "$BAK/grafana_data.tar" -C "$REHEARSE"
CID=$(sudo docker run -d --pull never --network none \
  -e GF_PLUGINS_PREINSTALL_DISABLED=true \
  -e GF_PLUGINS_PUBLIC_KEY_RETRIEVAL_DISABLED=true \
  -e GF_UNIFIED_STORAGE_FOLDERS_FOLDER_GRAFANA_APP_ENABLEMIGRATION=true \
  -e GF_UNIFIED_STORAGE_DASHBOARDS_DASHBOARD_GRAFANA_APP_ENABLEMIGRATION=true \
  -e GF_ANALYTICS_REPORTING_ENABLED=false \
  -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
  -e GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false \
  -e GF_NEWS_NEWS_FEED_ENABLED=false \
  -v "$REHEARSE:/var/lib/grafana" \
  -v "$PWD/grafana/provisioning:/etc/grafana/provisioning:ro" \
  -v "$PWD/grafana/dashboards:/var/lib/grafana/dashboards:ro" \
  "$IMG")
for _ in $(seq 1 120); do
  sudo docker exec "$CID" curl -fsS -o /dev/null http://127.0.0.1:3000/api/health 2>/dev/null && break
  sleep 0.5
done
sudo docker exec "$CID" curl -fsS http://127.0.0.1:3000/api/health; echo
sudo docker logs "$CID" 2>&1 | grep -E 'folders and dashboards migration|Unified storage migrations completed|level=error'
printf 'header = "Authorization: Bearer %s"\n' "$(cat /home/ubuntu/.config/skyeye/grafana-viewer-token)" | \
  sudo docker exec -i "$CID" curl --config - -fsS 'http://127.0.0.1:3000/api/search?type=dash-db&limit=5000' | jq 'length'
sudo docker rm -f "$CID" >/dev/null && sudo rm -rf "$REHEARSE"
```

預期：`database: "ok"`、`version: "12.4.15"`；log 有 `Migration successfully executed`（`folders and dashboards migration`）與 `Unified storage migrations completed successfully`，且**沒有** `level=error`；dashboard 數量為 `10`。

**彩排若有任何失敗：** 執行 `sudo docker compose start grafana` 恢復 11.2.0 並到此為止（checkout 與正式 volume 皆未更動）。

## 5. 升級

```bash
cd /home/ubuntu/SkyEye
git fetch origin
git merge --ff-only <reviewed-sha>
grep -n 'image: grafana/grafana' docker-compose.yml   # 預期 12.4.15@sha256:2894082f...
sudo docker compose up -d --no-deps grafana
until curl -fsS -o /dev/null http://127.0.0.1:3000/api/health; do sleep 1; done
curl -fsS http://127.0.0.1:3000/api/health; echo
```

## 6. 升級後檢查

1. **Cloudflare Access 登入（Wan）：** 新分頁打開 `https://grafana.wanbrain.com`，不出現 Grafana 登入頁；Profile 的 user id、Admin 角色與已加星號 dashboard 與基準一致。
2. **10 個 dashboard：** 逐一開啟，確認沒有 `Panel plugin not found` 或版面異常，並確認新 logs／table panel 顯示正常。
3. **Explore：** 分別切到 `Prometheus` 與 `Loki` datasource 各跑一次查詢（含 Loki label 選單），並看 Alerting 畫面。
4. **API、Alertmanager proxy、log 與記憶體：**

```bash
cd /home/ubuntu/SkyEye
gv() {
  printf 'header = "Authorization: Bearer %s"\n' "$(cat /home/ubuntu/.config/skyeye/grafana-viewer-token)" |
    curl --config - -fsS "http://127.0.0.1:3000$1"
}
gv '/api/search?type=dash-db&limit=5000' | jq 'length'                                  # 預期 10
gv /api/dashboards/uid/overview-all | jq -r '.dashboard.uid'                            # 預期 overview-all
gv /apis/dashboard.grafana.app/v1beta1/namespaces/default/dashboards/overview-all | \
  jq -r '.metadata.annotations | "\(.["grafana.app/managedBy"]) \(.["grafana.app/sourcePath"])"'
# 預期：classic-file-provisioning Overview/overview-all.json（既有搬遷 dashboard 的 legacy provisionedExternalId 會是空字串，屬已知行為）
gv /api/datasources/proxy/uid/alertmanager/api/v2/status | jq -r '.versionInfo.version' # 預期 0.34.2
sudo docker compose logs --since 10m grafana | grep -E 'level=error|Failed to authenticate request' || echo "no errors"
sudo docker stats --no-stream --format '{{.Name}} mem={{.MemUsage}}' "$(sudo docker compose ps -q grafana)"
scripts/central-deploy --manual-applied <reviewed-sha>
```

這個 commit 未改 dashboard JSON，`--manual-applied` 不會讀 Grafana，以上面的 `gv` 檢查為準。觀察穩定後再依需清理 `$BAK`（保留期間維持 mode 700／600）。

## 退回 11.2.0

> **不可只降 image tag：** unified storage 與 RBAC schema 已搬遷，必須還原升級前的整個 `grafana_data` 備份。**升級後才寫入的資料（新帳號、star、UI 改動、新 service account）會遺失。**
>
> **不可用 `docker cp` 還原 `grafana.db`：** 複製進 container 會變成 `root` 所有，以 uid 472 執行的 Grafana 會報 `permission denied` 無法啟動。

**1. 停止 Grafana、還原備份，再用 checkout 外的 override 啟動 11.2.0：**

```bash
cd /home/ubuntu/SkyEye
BAK=/home/ubuntu/grafana-pre-12-backup
VOL=$(sudo docker inspect "$(sudo docker compose ps -q grafana)" \
  --format '{{range .Mounts}}{{if eq .Destination "/var/lib/grafana"}}{{.Name}}{{end}}{{end}}')
MNT=$(sudo docker volume inspect "$VOL" --format '{{.Mountpoint}}')
sudo docker compose stop grafana
sudo find "$MNT" -mindepth 1 -delete
sudo tar --numeric-owner -xpf "$BAK/grafana_data.tar" -C "$MNT"

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
until curl -fsS -o /dev/null http://127.0.0.1:3000/api/health; do sleep 1; done
curl -fsS http://127.0.0.1:3000/api/health; echo   # 預期 version 11.2.0
```

請 Wan 重新驗證 Cloudflare Access 登入與主要 dashboard。Override 生效期間**不要**跑不帶 `-f` 的 `docker compose up -d`。

**2. 開 revert PR，merge 後移掉 override 並記錄：**

```bash
cd /home/ubuntu/SkyEye
git fetch origin
git merge --ff-only <revert-sha>
grep -n 'image: grafana/grafana' docker-compose.yml   # 預期 11.2.0
sudo docker compose up -d --no-deps --force-recreate grafana
rm /home/ubuntu/gf-rollback.yml
sudo docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' \
  "$(sudo docker compose ps -q grafana)"              # 只能有 docker-compose.yml
scripts/central-deploy --manual-applied <revert-sha>
```
