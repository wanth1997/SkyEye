# Runner Pool 告警處理（`Pool*`）

`prometheus/rules/runner-pool.yml` 目前全部為 shadow（`notification_mode: shadow`），只出現在 Prometheus、Grafana「主機 — Runner 池」與 `ALERTS` series，不會送 Telegram。升級流程見 [`trading-alert-promotion.md`](./trading-alert-promotion.md)。

> 本 repo 為公開倉庫，本文不記任何主機位址、SSH 別名、帳號或憑證。主機端操作請查 private 的 ai-workflow repo：`pool/docs/runbook-win.md`（Windows PC，`win`）與 `pool/docs/runbook-ubuntu.md`（Ubuntu PC，`ubuntu`）。

## Symptoms

| 告警 | 嚴重度 | `for` | 意義 |
|---|---|---|---|
| `PoolHostOffline` | High | 10m | 主機狀態 `updated_at` 超過 120s 未更新（exporter 正常） |
| `PoolHostStatusMissing` | High | 10m | `POOL_STATUS_<HOST>` variable 消失或從未寫入 |
| `PoolHostUnreadable` | Medium | 10m | 狀態 JSON 格式不符 v1，`pool-pick` 視為不可用 |
| `PoolHostHeld` | Medium | 5m | guard 用完自動恢復次數，停在 `held` 等人工處理 |
| `PoolHostPausedLong` | Low | 2h | 持續 `paused` 或 `draining`（停止收件，切換狀態不重計）超過 2 小時，可能忘了恢復 |
| `PoolGuardMemoryLow` | Medium | 10m | 可用記憶體低於主機門檻（預設 2,500 MiB） |
| `PoolQueueStuck` | Medium | 15m | `accepting` 且有空 slot，但仍有 job 排隊未開工 |
| `PoolCacheTokenHits` | Medium | 0m | 每日 cache 掃描發現疑似 token 字串，需立刻處理 |
| `PoolStatusUnreadable` | Medium | 5m | **非主機故障**：`pool-status` exporter 讀不到 GitHub variables |
| `PoolStatusExporterDown` | Medium | 10m | **非主機故障**：`pool-status` exporter 停了或未被 scrape |
| `PoolHostBriefOffline` | Medium | 0m | 主機中斷 > 2 分鐘後自行恢復（可能自動重開過），24h 靜音送出；約 30 分鐘後自動 resolved 屬正常現象。代價：`PoolHostOffline` firing 後約 32 分鐘內的第二次短暫中斷不會另外通知 |

## 判斷順序

### 1. 先排除 exporter／GitHub 問題

先看 Grafana「主機 — Runner 池」或直接在 `monitoring-prod` 查詢：

```bash
curl -fsS --get http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=up{job="pool-status"}' | jq -c '.data.result'
curl -fsS --get http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=time() - pool_status_exporter_read_timestamp_seconds' | jq -c '.data.result'
curl -fsS --get http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=increase(pool_status_exporter_read_errors_total[15m]) > 0' | jq -c '.data.result'
```

- `PoolStatusExporterDown`：在 `monitoring-prod` 檢查 `sudo docker compose ps pool-status` 與 `sudo docker compose logs --tail=50 pool-status`。
- `PoolStatusUnreadable`：看近 15 分鐘 `pool_status_exporter_read_errors_total` 增加的 `reason`：
  - `token` / `http_401` / `http_403`：GitHub PAT 缺失、過期、權限不足或被撤銷，照 [`docs/operations.md`](../docs/operations.md#runner-pool-github-pat-pool-statussecretsgithub_token) 輪替或確認 org approval。
  - `config`：`POOL_HOSTS` 設定缺失或格式錯誤。
  - `http_404`：目標 repo（`wanwanlabs/self-hosted-runner`）或 API 路徑不存在，或 PAT 未授權該 repo（private repo 無權限時 GitHub 常回 404）；檢查 PAT scope 與 exporter 設定。
  - `http_5xx`（僅 HTTP 500–599）/ `timeout`：GitHub API 異常或 `monitoring-prod` 外連逾時。
  - `json`：GitHub API 回傳非預期或損壞的 JSON，查 exporter log 確認回應異常。
  - **以上 `increase(...[15m])` 皆無增加但 `read_timestamp` 停住**：可能原因為未分類的 HTTP 回應（401/403/404/500–599 以外的狀態碼，如 429 或其他 4xx）或 poll 例外（exporter 不為此遞增 `read_errors_total`，只讓成功時間停住）；查 `sudo docker compose logs --tail=50 pool-status`，同時檢查 log 中的 HTTP 狀態碼與 poll 例外。

### 2. Windows PC（`server_id="pool-win"`）

`wans-windows` 經 Alloy remote_write 主動推送，停止推送後 5 分鐘內單看 `up` 仍會停在舊值 `1`。必須同時檢查樣本值與新鮮度 `time() - timestamp(up{...})`（分辨整台 Windows 還是 WSL distro／`pool-agent`）：

```bash
curl -fsS --get http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=up{job="integrations/windows",server_id="wans-windows"}' | jq -c '.data.result'
curl -fsS --get http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=time() - timestamp(up{job="integrations/windows",server_id="wans-windows"})' | jq -c '.data.result'
```

- **新鮮的 `1`**（`up == 1` 且樣本年齡 `<= 120` 秒）：Windows 與 Alloy 仍在推送 → 問題在 WSL2 distro `gh-runner`、`pool-agent`、`pool-guard` 或主機端 status token。
- **新鮮的 `0`**（`up == 0` 且樣本年齡 `<= 120` 秒）：Windows 活著且 Alloy 在推送，但 Windows 端 `windows_exporter` scrape 失敗 → 查 Windows 端 Alloy／exporter，同時確認 distro 狀態。
- **陳舊（樣本年齡 `> 120` 秒）或缺樣（回傳 `[]`）**：Windows PC 已停止回報（關機、重開、休眠、斷網，或 Windows 端 Alloy 停了／token 失效）。
- **調查已恢復事件（如 `PoolHostBriefOffline` 或已自動恢復的 `PoolHostOffline`）**：
  - 主機恢復後「現在」的 `up` 會回到新鮮的 `1`，不可只看現在值。請對照**中斷當時**的時間點（替換 `<INCIDENT_ISO>`，或看 Grafana「主機 — Windows」對應區間）與 Windows 開機時間（`windows_system_boot_time_timestamp` 已確認保留於 `agents/alloy/windows/config.alloy.tmpl`）：
    ```bash
    # 中斷當時的 Windows 層樣本新鮮度（回傳 [] 或 > 120 代表當時 Windows 亦停止推送）
    curl -fsS --get http://127.0.0.1:9090/api/v1/query \
      --data-urlencode 'time=<INCIDENT_ISO>' \
      --data-urlencode 'query=time() - timestamp(up{job="integrations/windows",server_id="wans-windows"})' | jq -c '.data.result'
    # 查 Windows 最近一次開機時間（Unix 秒）與距今時間，比對是否落在中斷區間內
    curl -fsS --get http://127.0.0.1:9090/api/v1/query \
      --data-urlencode 'query=windows_system_boot_time_timestamp{server_id="wans-windows"}' | jq -c '.data.result'
    curl -fsS --get http://127.0.0.1:9090/api/v1/query \
      --data-urlencode 'query=time() - windows_system_boot_time_timestamp{server_id="wans-windows"}' | jq -c '.data.result'
    ```
  - 並於 WSL2 distro `gh-runner` 內跑 `uptime` 確認是整台 Windows 重開還是僅 distro／agent 重啟。
- 主機端排查與恢復步驟見 ai-workflow repo 的 `pool/docs/runbook-win.md`。

### 3. Ubuntu PC（`server_id="pool-ubuntu"`）

1. 從操作機對 `ubuntu` 測試 ping 與 SSH，分辨是整台卡死／斷網（ping 不通或 SSH 卡在 kex）還是 `pool-status.timer`／status token 失效（SSH 進得去）。
2. **確認 `PoolHostBriefOffline` 是否真的重開過**：SSH 進 `ubuntu` 後查 `journalctl --list-boots` 與前次開機尾端日誌 `journalctl -b -1 -n 50`。
3. 主機端排查（k3s、ARC、`pool-status.timer`、`pool_ubuntu.py check`）與恢復步驟見 ai-workflow repo 的 `pool/docs/runbook-ubuntu.md`。

### 4. 其他告警速查

- **`PoolHostHeld` / `PoolGuardMemoryLow`**：`win` 查 `pool-guard` 狀態與可用記憶體；`ubuntu` 查節點 `free -m` 與 k3s pods。對應步驟見 ai-workflow repo 的 `pool/docs/runbook-win.md` 或 `pool/docs/runbook-ubuntu.md`。
- **`PoolQueueStuck`**：確認主機為 `accepting` 且有空 slot 但 runner 未啟動；依主機查 `pool-agent` 或 ARC controller／listener pod 日誌。
- **`PoolHostUnreadable` / `PoolHostStatusMissing`**：在主機執行狀態檢查，確認 writer 版本與 status token。
- **`PoolCacheTokenHits`**：立即通知 Wan 並依 ai-workflow repo 的 cache 安全流程檢視與清理。

## 計畫性維護：以 `server_id` 下 Alertmanager Silence

執行 `draining`、安裝升級或重開主機前，在 `monitoring-prod` 以 `server_id`（`pool-win` 或 `pool-ubuntu`）靜音單台主機，避免觸發 `PoolHostOffline`、`PoolHostPausedLong` 或 `PoolHostBriefOffline`。

**時間設定**：`--duration` 請在**預計恢復時間之後再多預留約 35 分鐘**（`PoolHostBriefOffline` 會在恢復後持續約 30 分鐘才隨視窗過去自動清除）。提前解除 silence 前，務必先確認該 `server_id` 的相關告警都已清除，避免一解除就立刻送出尚未過視窗的 `PoolHostBriefOffline`。

```bash
cd /home/ubuntu/SkyEye

# 新增 silence（將 SERVER_ID 換成 pool-win 或 pool-ubuntu；duration = 預計維護時間 + 恢復後 35m 緩衝）
sudo docker compose exec -T alertmanager amtool silence add \
  --alertmanager.url=http://127.0.0.1:9093 \
  --duration=2h \
  --author=operator \
  --comment="planned maintenance" \
  'product="runner-pool"' 'server_id="SERVER_ID"'

# 檢視目前啟用中的 runner-pool silence
sudo docker compose exec -T alertmanager amtool silence query \
  --alertmanager.url=http://127.0.0.1:9093 \
  'product="runner-pool"'

# 維護提前完成時：先確認該 server_id 已無任何 pending/firing 告警（回傳 []），再解除 silence
curl -fsS --get http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=ALERTS{product="runner-pool",server_id="SERVER_ID"}' | jq -c '.data.result'
sudo docker compose exec -T alertmanager amtool silence expire \
  --alertmanager.url=http://127.0.0.1:9093 <SILENCE_ID>
```

## Verify recovery

```bash
curl -fsS --get http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=time() - pool_status_updated_timestamp_seconds' | jq -c '.data.result'
curl -fsS --get http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=ALERTS{product="runner-pool",alertstate="firing"}' | jq -c '.data.result'
```

所有預期主機的狀態年齡回到 `< 120` 秒、`pool_status_readable == 1`、`pool_status_state{state="accepting"} == 1` 即恢復正常。
