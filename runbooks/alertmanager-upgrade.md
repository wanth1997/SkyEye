# Alertmanager 升級：v0.27.0 → v0.34.2（monitoring-prod）

這是換 Alertmanager image tag 的手動部署流程。`scripts/central-deploy` 會拒絕 `docker-compose.yml` 的改動，不會 pull，也不會 recreate container，所以這裡用手動 pull、`up -d`，最後用 `--manual-applied` 記錄。完成後，[`skyeye-watchdog.md`](./skyeye-watchdog.md) 第 2 步就算做完，第 4 步的版本檢查會印 `OK`。

為什麼要升：v0.27.0 的 `url_file` webhook 一收到非 2xx 回應就 nil pointer panic，Alertmanager 會整個退出（[prometheus/alertmanager#3800](https://github.com/prometheus/alertmanager/pull/3800)，v0.28.0 修正），所以 `deadman_url` 不能放。

## 會變的地方（2026-11-14 離線驗證過）

- **Log 改成 slog 格式：** `time=… level=ERROR source=… msg=… err="…"`，level 是大寫。Runbook 裡 grep 的字串（`read url_file`、`deadman-external`、`email`）都還在。
- **Metrics：** Dashboard 與 rule 用到的 `alertmanager_notifications_total`、`alertmanager_notifications_failed_total`、`alertmanager_silences`、`alertmanager_alerts`、`alertmanager_dispatcher_aggregation_groups`、`alertmanager_config_last_reload_successful` 都還在。`alertmanager_marked_alerts` 已移除，repo 沒有用到。
- **失敗原因：** `notifications_failed_total` 的 `reason` 多了 `authError`（401/403）、`rateLimited`（429）、`clientError`（其他 4xx）、`serverError`（5xx）。各值的意義見 [`skyeye-watchdog.md`](./skyeye-watchdog.md#5-確認-ping-有到) 第 5 步。`AlertmanagerNotifyFailures` 只依 `integration` 加總，不受影響。
- **CORS 預設關閉：** Alertmanager 不再回 `Access-Control-Allow-Origin: *`。Grafana datasource 是 `access: proxy`，由 Grafana server 端呼叫，不受影響。
- **Email 驗證更嚴格（0.31）：** 未修改的 `alertmanager.yml` 在 secrets 全空，以及只有 `tg_token` 兩種狀態下都能正常啟動，沒有 error。
- **Silences 與 nflog 格式：** 同一個 data dir 依序跑 0.27.0 → 0.34.2 → 0.27.0，silence 全部保留，已送過的告警沒有重送，所以可以直接退回舊 tag。
- Compose 只用 `--config.file`、`--storage.path`、`--web.external-url` 三個 flag，都沒有改。Image 一樣以 `nobody` 執行。

`tests/stack/test-deadman-switch.sh` 用釘住的版本，驗證 ping 端點依序回 404、503、200 時 Alertmanager 不會掛，換回 v0.27.0 時這個測試會失敗。

## 1. 時段與基準

- **時段：** 不要排在 UTC 18:15～19:30（備份與 Trading 時段）。
- **影響：** Recreate 時通知會延遲幾秒，不會遺失。Prometheus 會重送 firing 的告警，silences 與 nflog 存在 `alertmanager_data` volume。
- **前提：** 升級的 PR 已 merge 到 master，checkout 是乾淨的（`git status --short` 沒有輸出）。

先記錄基準，存到 checkout 外面：

```bash
cd /home/ubuntu/SkyEye
B=/home/ubuntu/am-upgrade-baseline.txt
{
  date -u
  sudo docker compose exec -T alertmanager alertmanager --version 2>&1 | head -n 1
  sudo docker compose exec -T alertmanager ls -l /alertmanager
  curl -fsS http://127.0.0.1:9093/metrics | grep -E '^alertmanager_(silences|alerts)\{'
  # Counter 依 integration 加總，不分 reason
  curl -fsS http://127.0.0.1:9093/metrics | awk '/^alertmanager_notifications_(failed_)?total\{/ {
    split($1, n, "{"); match($1, /integration="[^"]*"/); s[n[1] " " substr($1, RSTART, RLENGTH)] += $2 }
    END { for (k in s) print k, s[k] }' | sort
  # 過去 1 小時的失敗數，用 increase()，所以 recreate 造成的 counter 歸零不影響
  curl -fsS http://127.0.0.1:9090/api/v1/query --data-urlencode \
    'query=sum by (integration) (increase(alertmanager_notifications_failed_total[1h]))'
  echo
} | tee "$B"
```

預期：版本 `0.27.0`，`/alertmanager` 底下有 `nflog` 與 `silences`。`webhook` 的失敗數一直增加是正常的，因為 `deadman_url` 還沒放。記下 `telegram` 與 `email` 有沒有失敗；升級後拿來比較。

## 2. 先 pull image（獨立一步，在任何 dry-run 之前）

central-deploy 驗證時跑的 amtool／promtool `docker run` 沒有 `--pull=never`。Image 不在本機的話，任何跑到驗證這一步的 central-deploy（dry-run 或 `--manual-applied`）都會在驗證途中把它下載到主機上。所以一定要先在這一步明確 pull，之後所有 central-deploy 都只用本機已有的 image：

```bash
sudo docker pull prom/alertmanager:v0.34.2
sudo docker image inspect --format '{{index .RepoDigests 0}} user={{.Config.User}}' prom/alertmanager:v0.34.2
# 預期：prom/alertmanager@sha256:39d8bb3966c694a124428a3a88fbcffd40bd069129ecd47c059f8a3f17c55f3b user=nobody
sudo docker image inspect prom/alertmanager:v0.27.0 >/dev/null && echo "v0.27.0 still local (rollback)"
```

Digest 不同或 user 不是 `nobody`，就停下來。v0.27.0 要留在本機，退回時才不必下載。

## 3. Dry-run

```bash
scripts/central-deploy --dry-run
```

預期它會拒絕，並列出 `docker-compose.yml`（需要 recreate）。這代表這次要走手動流程，不是錯誤。如果它列出 `docker-compose.yml`、`*.md` 與 `tests/` 以外的路徑，就停下來，先確認那些改動是什麼。

## 4. 升級

```bash
cd /home/ubuntu/SkyEye
git fetch origin
git merge --ff-only <reviewed-sha>
grep -n 'image: prom/alertmanager' docker-compose.yml   # 預期 v0.34.2
sudo docker compose pull alertmanager                   # 第 2 步已經 pull 過，這裡不會再下載
sudo docker compose up -d --no-deps alertmanager
curl -fsS --retry 10 --retry-delay 1 --retry-connrefused http://127.0.0.1:9093/-/ready
scripts/central-deploy --manual-applied <reviewed-sha>
```

`--no-deps` 只 recreate Alertmanager。`--manual-applied` 會再驗證、reload 並記錄這個 commit。

## 5. 升級後檢查

```bash
cd /home/ubuntu/SkyEye
sudo docker compose exec -T alertmanager alertmanager --version 2>&1 | head -n 1   # version 0.34.2
sudo docker compose exec -T alertmanager ls -l /alertmanager                      # nflog、silences 都還在
curl -fsS http://127.0.0.1:9093/metrics | grep -E '^alertmanager_(silences|alerts)\{'
sudo docker compose logs --since 10m alertmanager | grep -E 'level=(ERROR|WARN)' | grep -v 'deadman-external'
```

- **Ready 與版本：** 版本是 `0.34.2`，`/-/ready` 回 OK。
- **Silences：** `alertmanager_silences{state="active"}` 和基準一樣。
- **nflog：** recreate 前已送過的 firing 告警，不會在 recreate 後重送到 Telegram（下一次重送照原本的 `repeat_interval`）。Log 裡除了 `deadman-external` 的 `read url_file` 以外，沒有 `ERROR`／`WARN`，特別是沒有 snapshot 或 load 錯誤。
- **Telegram 路徑：** 用 counter 和下一則真實通知證明，不需要另外發測試訊息。Counter 在 recreate 後從 0 開始。
  - `alertmanager_notifications_failed_total{integration="telegram"}` 維持 0。
  - 下一則真實通知送出後，`alertmanager_notifications_total{integration="telegram"}` 增加，Telegram 也收到那則訊息。
  - 約 15 分鐘後跑一次下面的 query，`telegram` 與 `email` 不應比基準多：

    ```bash
    curl -fsS http://127.0.0.1:9090/api/v1/query --data-urlencode \
      'query=sum by (integration) (increase(alertmanager_notifications_failed_total[15m]))'
    ```

  - **有疑慮時**（例如很久沒有真實通知），可以手動發一個測試告警。**這會送出一則真的 Telegram 訊息**，約 5 分鐘後自動 resolve：

    ```bash
    sudo docker compose exec -T alertmanager amtool --alertmanager.url=http://127.0.0.1:9093 \
      alert add alertname=SkyEyeAlertmanagerUpgradeCheck severity=Low --annotation=summary='Alertmanager upgrade check'
    ```

- **Grafana：** 打開 `SkyEye — Stack health`（`skyeye-stack-health`），🚨 Alertmanager 那一排的 panel 都有資料。Datasource 的檢查要經過 Grafana 的 proxy，這也是 datasource 頁面 Test 按鈕實際做的事。`/api/datasources/uid/alertmanager/health` 在 Grafana 11.2 對這個 datasource 一律回 `Plugin unavailable`，與 Alertmanager 版本無關，不要拿它判斷：

  ```bash
  { printf 'Authorization: Bearer '; cat /home/ubuntu/.config/skyeye/grafana-viewer-token; } | \
    curl -fsS -H @- http://127.0.0.1:3000/api/datasources/proxy/uid/alertmanager/api/v2/status | grep -o '"version":"[^"]*"'
  # 預期 "version":"0.34.2"
  ```

- **Secret 檢查：** 跑 [`skyeye-watchdog.md`](./skyeye-watchdog.md#4-放-secret) 第 4 步的版本檢查，要印 `OK`。

全部通過後，刪掉 `/home/ubuntu/am-upgrade-baseline.txt`，結果記在 work-log。

## 退回 v0.27.0

> **如果 `deadman_url` 已經放了，先把它拿掉，才能退回 v0.28.0 以下的版本。** 否則 ping 端點一回非 2xx，v0.27.0 就會 panic 退出，Telegram 與 email 全停。網址存在密碼管理器裡，所以直接刪：
>
> ```bash
> rm /home/ubuntu/SkyEye/alertmanager/secrets/deadman_url
> ```
>
> 同時在託管服務上 pause `skyeye-monitoring-prod` 這個 check，否則它會誤報 down。

前提是 silence 格式相容。2026-11-14 已經離線驗證：0.34.2 寫出的 silences 與 nflog，0.27.0 可以讀。不要在 0.34.2 上建立有多組 matcher 的 silence，0.27.0 無法表示這種 silence。

**1. 先在不改 checkout 的情況下切回舊 tag。** Override 檔放在 checkout 外面，checkout 保持乾淨，central-deploy 照常可用：

```bash
cd /home/ubuntu/SkyEye
cat >/home/ubuntu/am-rollback.yml <<'EOF'
services:
  alertmanager:
    image: prom/alertmanager:v0.27.0
EOF
sudo docker compose -f docker-compose.yml -f /home/ubuntu/am-rollback.yml up -d --no-deps alertmanager
curl -fsS --retry 10 --retry-delay 1 --retry-connrefused http://127.0.0.1:9093/-/ready
sudo docker compose exec -T alertmanager alertmanager --version 2>&1 | head -n 1   # version 0.27.0
```

Override 生效期間，**不要**跑不帶 `-f` 的 `docker compose up -d`，否則會換回 v0.34.2。Reload 不受影響，central-deploy 只發 HTTP reload，不會 recreate。

**2. 用 revert PR 把 Git 的 pin 改回去，再把 override 拿掉。** Revert PR merge 到 master 之後：

```bash
cd /home/ubuntu/SkyEye
git fetch origin
git merge --ff-only <revert-sha>
grep -n 'image: prom/alertmanager' docker-compose.yml          # 預期 v0.27.0
sudo docker compose up -d --no-deps --force-recreate alertmanager
rm /home/ubuntu/am-rollback.yml
sudo docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' \
  "$(sudo docker compose ps -q alertmanager)"                    # 只能有 docker-compose.yml
scripts/central-deploy --manual-applied <revert-sha>
```

`--force-recreate` 讓 container 改用 Git 裡的 compose 重建，不再帶著 override 的設定。最後一行 label 裡如果還看得到 `am-rollback.yml`，就是 override 還在使用中。

退回後，照 [`skyeye-watchdog.md`](./skyeye-watchdog.md) 的說明，第 4 步會印 `STOP`，`deadman_url` 不能再放。
