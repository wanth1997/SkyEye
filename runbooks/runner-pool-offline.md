# Runner Pool 告警處理（`Pool*`）

`prometheus/rules/runner-pool.yml` 目前全部為 shadow（`notification_mode: shadow`），只出現在 Prometheus、Grafana「主機 — Runner 池」與 `ALERTS` series，不會送 Telegram。升級流程見 [`trading-alert-promotion.md`](./trading-alert-promotion.md)。

> 本 repo 為公開倉庫，本文不記任何主機位址、SSH 別名、帳號或憑證。主機端操作請查 private 的 ai-workflow repo：`pool/docs/runbook-pc.md`（Windows PC，`pc`）與 `pool/docs/runbook-srv.md`（Ubuntu PC，`srv`）。

## Symptoms

| 告警 | 嚴重度 | `for` | 意義 |
|---|---|---|---|
| `PoolHostOffline` | High | 10m | 主機狀態 `updated_at` 超過 120s 未更新（exporter 正常） |
| `PoolHostStatusMissing` | High | 10m | `POOL_STATUS_<HOST>` variable 消失或從未寫入 |
| `PoolHostUnreadable` | Medium | 10m | 狀態 JSON 格式不符 v1，`pool-pick` 視為不可用 |
| `PoolHostHeld` | Medium | 5m | guard 用完自動恢復次數，停在 `held` 等人工處理 |
| `PoolHostPausedLong` | Low | 2h | `paused` 或 `draining` 超過 2 小時，可能忘了恢復 |
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
  --data-urlencode 'query=pool_status_exporter_read_errors_total > 0' | jq -c '.data.result'
```

- `PoolStatusExporterDown`：在 `monitoring-prod` 檢查 `sudo docker compose ps pool-status` 與 `sudo docker compose logs --tail=50 pool-status`。
- `PoolStatusUnreadable`：看 `pool_status_exporter_read_errors_total` 的 `reason`：
  - `token` / `http_401` / `http_403`：GitHub PAT 缺失、過期或被撤銷，照 [`docs/operations.md`](../docs/operations.md#runner-pool-github-pat-pool-statussecretsgithub_token) 輪替。
  - `config`：`POOL_HOSTS` 設定錯誤。
  - `http_5xx` / `timeout`：GitHub API 或 `monitoring-prod` 外連異常。

### 2. Windows PC（`server_id="pool-pc"`）

先看 Windows 層 exporter 是否仍在回報（分辨是整台 Windows 還是 WSL distro／`pool-agent`）：

```bash
curl -fsS --get http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=up{job="integrations/windows",server_id="wans-windows"}' | jq -c '.data.result'
```

- **`up == 1`**：Windows 本身還在跑 → 問題在 WSL2 distro `gh-runner`、`pool-agent`、`pool-guard` 或主機端 status token。
- **無資料或 `up == 0`**：Windows PC 關機、重開、休眠或斷網。
- **確認 `PoolHostBriefOffline` 是否真的重開過**：
  - 查 Windows 開機時間（`windows_system_boot_time_timestamp` 已確認保留於 `agents/alloy/windows/config.alloy.tmpl`，亦可見「主機 — Windows」的「開機至今」）：
    ```bash
    curl -fsS --get http://127.0.0.1:9090/api/v1/query \
      --data-urlencode 'query=time() - windows_system_boot_time_timestamp{server_id="wans-windows"}' | jq -c '.data.result'
    ```
  - 並於 WSL2 distro `gh-runner` 內跑 `uptime` 確認 distro 是否重啟。
- 主機端排查與恢復步驟見 ai-workflow repo 的 `pool/docs/runbook-pc.md`。

### 3. Ubuntu PC（`server_id="pool-srv"`）

1. 從操作機對 `srv` 測試 ping 與 SSH，分辨是整台卡死／斷網（ping 不通或 SSH 卡在 kex）還是 `pool-status.timer`／status token 失效（SSH 進得去）。
2. **確認 `PoolHostBriefOffline` 是否真的重開過**：SSH 進 `srv` 後查 `journalctl --list-boots` 與前次開機尾端日誌 `journalctl -b -1 -n 50`。
3. 主機端排查（k3s、ARC、`pool-status.timer`、`pool_srv.py check`）與恢復步驟見 ai-workflow repo 的 `pool/docs/runbook-srv.md`。

### 4. 其他告警速查

- **`PoolHostHeld` / `PoolGuardMemoryLow`**：`pc` 查 `pool-guard` 狀態與可用記憶體；`srv` 查節點 `free -m` 與 k3s pods。對應步驟見 ai-workflow repo 的 `pool/docs/runbook-pc.md` 或 `pool/docs/runbook-srv.md`。
- **`PoolQueueStuck`**：確認主機為 `accepting` 且有空 slot 但 runner 未啟動；依主機查 `pool-agent` 或 ARC controller／listener pod 日誌。
- **`PoolHostUnreadable` / `PoolHostStatusMissing`**：在主機執行狀態檢查，確認 writer 版本與 status token。
- **`PoolCacheTokenHits`**：立即通知 Wan 並依 ai-workflow repo 的 cache 安全流程檢視與清理。

## 計畫性維護：以 `server_id` 下 Alertmanager Silence

執行 `draining`、安裝升級或重開主機前，在 `monitoring-prod` 以 `server_id`（`pool-pc` 或 `pool-srv`）靜音單台主機，避免觸發 `PoolHostOffline`、`PoolHostPausedLong` 或 `PoolHostBriefOffline`：

```bash
cd /home/ubuntu/SkyEye

# 新增 silence（將 SERVER_ID 換成 pool-pc 或 pool-srv，視需要調整 duration）
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

# 維護提前完成時解除 silence
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
