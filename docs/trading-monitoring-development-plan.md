# Trading Monitoring Development and Server Onboarding Plan

> **狀態：** Core decisions approved; implementation pending
>
> **日期：** 2026-07-17
>
> **For agentic workers:** 本文件核准後，SkyEye 與 tnauqquant 必須各自在獨立 worktree／branch 執行。SkyEye Track 可先完成 development POC；production migration 必須等 Trading Runtime Contract 驗收通過。

**Goal:** 先在目前 development Mac 將 tnauqquant 的 PNL、運行狀況與 Error logs 接入 SkyEye 並在 Grafana 驗證，再以明確、可攜的 deployment contract 將同一套監控部署到新的 trading server。

**Architecture:** Development POC 由 macOS Grafana Alloy 讀取現有 raw log，搭配唯讀 probe 將 process/run state 寫成 Prometheus textfile metrics，再經 Cloudflare Tunnel 推送到中央 Loki 與 Prometheus。Production 版本沿用相同 SkyEye agent，但由 tnauqquant 提供 run manifest 與結構化 done marker，使 process、config、log 與 run identity 能可靠綁定。

**Tech Stack:** Grafana Alloy、Loki/LogQL、Prometheus/PromQL、Grafana 11、Alertmanager、Cloudflare Access、macOS Homebrew/launchd、POSIX shell。

## Global Constraints

- 第一個驗收環境是目前 development Mac；確認 Grafana 端到端可見後才部署新 server。
- Grafana 的核心畫面只有三個主題：PNL、當前運行狀況、Errors。
- PNL 與運行狀況必須是獨立 panel／row；Error 必須有獨立 panel／row。
- Development POC 不得中斷或操控真實 trading process；probe 只能讀取狀態。
- 新 trading target 一律先以 `notification_mode="shadow"` 註冊，canary 通過後才改成 `page`。
- Secrets 只能存在來源主機的 Homebrew Alloy `config.env` 或既有 secret store，不能寫入 Git 或 render 進 Git-managed template。
- 本機絕對路徑、order ID、client action ID、原始錯誤全文不得成為 Loki labels。
- Log timestamp 允許 Alloy 對重複 timestamp 加 1ns 保序；驗收比較事件時間與順序，不要求 bit-for-bit timestamp 相同。
- Log fixture 必須去識別化並固定 checksum；不能把持續寫入的 live file 當成 deterministic test input。

---

## 1. Executive Decision

### 1.0 Approved owner decisions

| Decision | Approved choice |
|---|---|
| Production launch mode | `scripts/tq live run --human` + tmux + foreground + no auto-restart |
| Primary Grafana PNL | 最新 `stable=true` 的 `real_pnl_usdt`；cash/rebate/risk PNL 作輔助 |
| Target identity | 暫時使用 `tnauqquant-dev-mac`；production 使用 `tnauqquant-prod-1`；production 驗收後 retire development target |
| Trading repo changes | 接受最小 runtime contract 修改，由獨立 tnauqquant agent 實作；不得修改策略、下單或 PNL 計算 |
| Grafana access | Trading PNL 與 raw error logs 只允許明確核准的 operator email 存取 |

### 1.1 是否只需要修改 SkyEye？

答案分成兩個階段：

| 階段 | SkyEye 修改 | tnauqquant 修改 | 可達成結果 |
|---|---:|---:|---|
| Development POC | 必須 | 不必 | Grafana 看見 PNL、運行狀況、Errors；驗證 Alloy、Loki、Prometheus 與 dashboard 資料流 |
| Production-safe migration | 必須 | 必須 | 精確辨識 run、正常結束、risk halt、duplicate process、stale marker 與 log binding |

因此，**我們可以先只在 SkyEye 開工並完成視覺與 ingestion POC，但正式搬到新 server 前，Trading repo 仍需要另一個 agent 實作 runtime contract。**

### 1.2 三種方案比較

| 方案 | 優點 | 限制 | 決策 |
|---|---|---|---|
| A. SkyEye-only heuristic probe | 最快看見 Grafana 結果，不碰 trading code | 無法可靠區分 safe completion、stale marker 與相似 process | 僅用於 development POC |
| B. SkyEye + Trading runtime contract | 可攜、可驗證、能安全 alert | 需要兩個 repo 協作 | **Production 採用** |
| C. Trading 先做完整原生 `/metrics` | current risk/position 最權威 | 範圍大，延後 PNL dashboard 上線 | 後續 enhancement，不阻擋第一版 |

### 1.3 正式執行模式

第一版正式 contract 採：

```text
scripts/tq live run --human + tmux + foreground + no auto-restart
```

watchdog 目前擁有另一套 PID、done marker、daily log 與 auto-restart 語意，而且未共用 `tq` 的完整 preflight。除非未來先重構成共用 launcher contract，否則不作為這個策略的正式執行模式。

---

## 2. Current Evidence and Assumptions

### 2.1 Development source

```text
Trading repo:
/Users/tinghsu/projects/tnauqquant

Observed sample log:
/Users/tinghsu/projects/tnauqquant/logs/live-runs/20260717_024506_mexc_toobit_btc_config.raw.log

Development config:
/Users/tinghsu/projects/tnauqquant/config/mexc_toobit_btc_config.yaml
```

Sample log 是 Go slog **logfmt**，不是 JSON；目前 config 使用 `logging.format: text`。每行已有 `time`、`level`、`msg` 與 key/value fields，因此 Alloy 可以穩定 parse。

已確認的核心事件：

- `msg=pnl_status`：包含 `real_pnl_usdt`、`cash_pnl_usdt`、`rebate_usdt`、`risk_pnl_usdt`、`cycles_completed`、`risk_stopped`。
- `msg=equity_snapshot`：包含 equity 與本 cycle PNL delta。
- `level=ERROR msg=entry_tactic_failed`：包含 tactic、latency 與 error context。
- Sample 會持續增長，且有大量相同 timestamp 的相鄰事件，因此測試必須使用固定 fixture。

### 2.2 Runtime gaps

- Config 目前有 `max_cycles: 50`，正常完成後 engine 會自動停止。
- `scripts/tq live run --human` 會產生 `logs/live-runs/*.raw.log`，但不設定 `TQ_DONE_MARKER`、不產生 PID/run manifest。
- watchdog 才會建立 PID/done marker，但 log 與 restart contract 不同。
- `TQ_DONE_MARKER` 未設定時，engine 的 marker write 會回報成功但實際不產生檔案。
- `risk_halt` 可寫入 marker，但 process 不一定立刻退出；它是 critical safety state，不一定是 terminal process state。

---

## 3. Target Architecture and Data Flow

```text
tnauqquant foreground process
  ├─ stdout/stderr ──> *.raw.log
  │                     └─ Alloy file source
  │                         └─ logfmt parse + scrub + relabel
  │                             └─ Cloudflare Access ──> Loki
  │
  └─ process/config/run state
                        └─ read-only trading probe every 15s
                            └─ atomic *.prom textfile
                                └─ Alloy unix textfile collector
                                    └─ Cloudflare Access ──> Prometheus

Loki + Prometheus
  ├─ Grafana: PNL / Run Status / Errors
  ├─ Prometheus rules: process and telemetry state
  └─ Loki rules: ERROR/FATAL log events
        └─ Alertmanager shadow route
              └─ after promotion: Telegram + email
```

Alloy 的 `prometheus.exporter.unix` textfile collector 支援所有作業系統，可讀指定目錄的 `*.prom`；這讓 probe 不需要常駐 HTTP server，也不需要增加 Python/npm dependency。參考：[Grafana Alloy unix exporter](https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.exporter.unix/)。

---

## 4. Portable Server Deployment Contract

### 4.1 Stable labels

Development 與 production 使用相同 schema，只改值：

| Label | Development value | New server value | 規則 |
|---|---|---|---|
| `product` | `tnauqquant` | `tnauqquant` | 永遠固定 |
| `environment` | `development` | `production` | 只允許這兩個值 |
| `server_id` | `tnauqquant-dev-mac` | `tnauqquant-prod-1` | 人工指定、不可由 hostname 自動漂移 |
| `strategy` | `mexc-toobit-btc` | `mexc-toobit-btc` | 穩定 monitoring slug |
| `run_id` | raw-log basename 移除 `.raw.log` | manifest 指定值 | 一個 run 一個 Loki stream |

`strategy` 是監控識別；Trading config 中的 `instance_id` 是 runtime identity。兩者必須在 deployment contract 中明確映射，probe 需輸出 `tnauqquant_strategy_identity_ok`，不能假設名稱天然相同。

### 4.2 Source-host configuration

SkyEye 提供 `agents/alloy/trading/deployment.env.example`，新 server agent 複製成 Homebrew Alloy 的 `config.env`。實際檔案權限固定為 `0600`。

| Variable | Development value | 說明 |
|---|---|---|
| `TQ_PRODUCT` | `tnauqquant` | Loki/Prometheus product label |
| `TQ_ENVIRONMENT` | `development` | development 或 production |
| `TQ_SERVER_ID` | `tnauqquant-dev-mac` | target inventory key |
| `TQ_STRATEGY` | `mexc-toobit-btc` | monitoring slug |
| `TQ_REPO_ROOT` | `/Users/tinghsu/projects/tnauqquant` | 唯一 server-specific repo root |
| `TQ_CONFIG_PATH` | `/Users/tinghsu/projects/tnauqquant/config/mexc_toobit_btc_config.yaml` | canonical config identity |
| `TQ_RAW_LOG_GLOB` | `/Users/tinghsu/projects/tnauqquant/logs/live-runs/*.raw.log` | Alloy local-only absolute glob |
| `TQ_RUN_MANIFEST` | `/Users/tinghsu/projects/tnauqquant/run-state/mexc-toobit-btc/current.json` | Production contract；POC 缺少時輸出 identity unavailable |
| `TQ_DONE_MARKER` | `/Users/tinghsu/projects/tnauqquant/run-state/mexc-toobit-btc/current.done.json` | Production contract |
| `TQ_POC_RUN_EXPECTED` | `1` | 僅供 development heuristic；production 從 manifest/state machine 導出 |
| `TQ_TEXTFILE_DIR` | `/opt/homebrew/var/lib/alloy/textfile` | Probe atomic output directory；Intel Mac 由 `brew --prefix` 導出 |
| `LOKI_PUSH_URL` | `https://loki-push.wanbrain.com/loki/api/v1/push` | 既有 ingress |
| `PROM_PUSH_URL` | `https://prom-push.wanbrain.com/api/v1/write` | 既有 ingress |
| `CF_ACCESS_CLIENT_ID` | 僅存在 secret env | Trading host 專用 service token |
| `CF_ACCESS_CLIENT_SECRET` | 僅存在 secret env | 不得寫入 repo、log 或 handoff report |

macOS Homebrew Alloy 官方環境檔位置是 `$(brew --prefix)/etc/alloy/config.env`。參考：[Configure Grafana Alloy on macOS](https://grafana.com/docs/alloy/latest/configure/macos/)。

### 4.3 Central target inventory

從 development 第一版就建立中央 inventory metric，不依賴來源 agent 自報 target 存在：

```promql
tnauqquant_target_info{
  environment="development",
  server_id="tnauqquant-dev-mac",
  strategy="mexc-toobit-btc",
  notification_mode="shadow"
} 1
```

新 server 加入時新增 production target，先標 `shadow`。Canary 完成後以 Git change 改成 `page`。Development server 退役時，先改為 `retired` 並停用對應 rules，再移除 inventory。

### 4.4 New server agent handoff report

新 server agent 在修改前必須回報下列非敏感資料：

```bash
sw_vers
uname -m
brew --prefix
alloy --version
git -C "$TQ_REPO_ROOT" rev-parse HEAD
realpath "$TQ_REPO_ROOT"
realpath "$TQ_CONFIG_PATH"
shasum -a 256 "$TQ_CONFIG_PATH"
ls -ld "$(dirname "$TQ_RAW_LOG_GLOB")" "$(dirname "$TQ_RUN_MANIFEST")"
```

Handoff report 不得包含 Cloudflare client secret、exchange credentials、wallet/account IDs 或 raw order payloads。

### 4.5 Access review

Trading logs 進入中央端以前，SkyEye operator 必須從 Cloudflare Zero Trust 實際設定確認 Grafana email allowlist，不能只依賴 repo README。Owner 已決定只有明確核准的 operator email 可以存取 Trading PNL 與 raw error logs。現在 Grafana 對自動建立的使用者指派 Admin，且 Loki 是單一 tenant；如果 allowlist 含有其他使用者，必須先完成 org/datasource access isolation。單靠 Grafana folder permission 不能隔離同一 Loki datasource 的 raw logs。

Development 與 production trading host 分別使用可獨立撤銷的 service token。Token 只允許 `prom-push` 與 `loki-push` Access applications，不授權 Grafana UI 或其他產品 endpoints。

---

## 5. Log Ingestion Contract

### 5.1 Alloy source behavior

```alloy
tail_from_end           = false
on_positions_file_error = "restart_from_end"

file_match {
  enabled           = true
  sync_period       = "10s"
  ignore_older_than = "24h"
}
```

語意：新發現且沒有 position 的檔案從頭讀；單一 positions entry 損壞時從檔尾恢復，降低重複資料風險。參考：[loki.source.file](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.file/)。

Timestamp contract：

```alloy
stage.timestamp {
  source                        = "time"
  format                        = "RFC3339Nano"
  action_on_failure             = "skip"
  action_on_duplicate_timestamp = "fudge"
}
```

### 5.2 Parse, scrub and labels

Pipeline 順序固定：

1. 讀取完整文字行。
2. `stage.logfmt` 解析 `time`、`level`、`msg` 與數值欄位。
3. `stage.replace` scrub email、token、絕對 repo path 與已知敏感值。
4. 從 `filename` basename 產生 `run_id`。
5. 移除 `filename` label。
6. 只保留低 cardinality labels。

允許的 Loki labels：

```text
product, environment, server_id, strategy, run_id, level
```

以下欄位只能 query-time parse：

```text
msg, err, order_id, client_action_id, tactic, executor,
cycles_completed, real_pnl_usdt, cash_pnl_usdt, rebate_usdt,
risk_pnl_usdt, process_latency_ms
```

Stream budget 固定為每個 strategy 每 30 天少於 200 個 run streams。超出時先檢查 run rotation/launcher 行為，不自動丟棄最新 run。

### 5.3 Fixture contract

- 從 sample 擷取 `pnl_status`、`equity_snapshot`、INFO/WARN、三筆相鄰 ERROR、重複 timestamp 與 malformed line。
- 所有 account/exchange identifier、路徑、金額以 deterministic fake values 取代。
- Fixture 保留 scrub 後的完整文字行，不宣稱保留未修改原文。
- `tests/fixtures/tnauqquant/trading.raw.log.sha256` 記錄 checksum。

---

## 6. Probe and Runtime State Contract

### 6.1 Development heuristic mode

在 Trading runtime contract 尚未合併前，probe：

- 以 executable command line + exact config path 計算 `process_count`。
- 以最新符合 glob 的 raw log 作為 current log candidate。
- 以 process start time、log mtime 與 config basename 作 best-effort binding。
- `process_identity_ok` 只表示 heuristic command/config match；另輸出 `runtime_contract_available=0`，不得把 heuristic identity 當成 production contract。
- `marker_binding_ok=0` 在 heuristic mode 代表不可驗證；BindingInvalid alert 必須以 `runtime_contract_available=1` 為前提。
- `run_expected` 暫時由 `TQ_POC_RUN_EXPECTED=1` 提供，因此 max-cycles safe completion 仍可能在 shadow mode 顯示 Down；這是 POC 已知限制，也是 production migration 必須修改 Trading repo 的原因。
- Development dashboard 可以顯示結果，但 production paging gate 不允許通過。

### 6.2 Production manifest

Trading repo 應由實際 quant process atomic write：

```json
{
  "schema_version": 1,
  "run_id": "20260717_024506_mexc_toobit_btc_config",
  "strategy": "mexc-toobit-btc",
  "instance_id": "mexc-toobit-btc-live",
  "pid": 12345,
  "process_started_at": "2026-07-17T02:45:06.000+08:00",
  "executable": "/srv/tnauqquant/bin/quant",
  "config_path": "/srv/tnauqquant/config/mexc_toobit_btc_config.yaml",
  "config_sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "log_path": "/srv/tnauqquant/logs/live-runs/20260717_024506_mexc_toobit_btc_config.raw.log",
  "done_marker_path": "/srv/tnauqquant/run-state/mexc-toobit-btc/current.done.json",
  "state": "running"
}
```

Example 中的 `/srv/tnauqquant` 只示範新 server 可使用不同 root；central labels 與 dashboard 不得保存這個絕對路徑。

### 6.3 Production done marker

```json
{
  "schema_version": 1,
  "run_id": "20260717_024506_mexc_toobit_btc_config",
  "strategy": "mexc-toobit-btc",
  "pid": 12345,
  "config_sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "reason": "max_cycles_complete",
  "completed_at": "2026-07-17T16:20:00.000+08:00"
}
```

允許的 `reason`：

| reason | 分類 | ProcessDown 行為 |
|---|---|---|
| `max_cycles_complete` | safe completion | 抑制 ProcessDown |
| `reduce_only_complete` | safe completion | 抑制 ProcessDown |
| `risk_halt` | critical safety state | 觸發 High；process 可仍存在 |
| `max_cycles_drain_failed` | critical safety state | 觸發 High |
| 其他值 | `unknown` | 觸發 High |

Marker 只有在 `run_id`、PID、config hash 與 manifest 相符時才能影響 alert state。Stale marker 必須被 archive，不能無聲覆蓋或套用到新 run。

### 6.4 Probe metrics

| Metric | Type | 說明 |
|---|---|---|
| `tnauqquant_process_count` | gauge | exact strategy/config process 數量 |
| `tnauqquant_run_expected` | gauge | 1=預期運行，0=disabled/safe complete |
| `tnauqquant_runtime_contract_available` | gauge | 0=development heuristic，1=manifest/marker v1 可用 |
| `tnauqquant_process_identity_ok` | gauge | heuristic=command/config match；contract=process/manifest match |
| `tnauqquant_strategy_identity_ok` | gauge | monitoring slug 與 config instance 是否相符 |
| `tnauqquant_log_binding_ok` | gauge | current log 是否屬於 current run |
| `tnauqquant_marker_binding_ok` | gauge | marker 是否屬於 current run |
| `tnauqquant_done_marker{reason="..."}` | gauge | allowlisted marker reason；最多一個 reason=1 |
| `tnauqquant_sidecar_up` | gauge | sidecar process 是否存在 |
| `tnauqquant_sidecar_identity_ok` | gauge | sidecar binary/version/runtime identity 是否正確 |
| `tnauqquant_probe_timestamp_seconds` | gauge | 本次 probe 完成時間 |
| `tnauqquant_log_mtime_seconds` | gauge | current log 最後修改時間 |

所有 metrics 都帶 `product`、`environment`、`server_id`、`strategy`；不帶 PID、path、run ID 等高 churn labels。

### 6.5 Runtime state and alerts

| 條件 | Dashboard state | Alert |
|---|---|---|
| `process_count=1` 且 identity/binding 正確 | Running | 無 |
| `process_count>1` | Duplicate | `TradingDuplicateProcess`, High |
| `run_expected=0` 且 process 存在超過 2m | Unexpected | `TradingUnexpectedProcess`, High |
| `run_expected=1`、process 不存在、無當輪 safe reason | Down | `TradingProcessDown`, High |
| 當輪 safe reason 且 process 不存在 | Completed | 無 ProcessDown |
| reason=`risk_halt`/`max_cycles_drain_failed`/`unknown` | Critical | `TradingCriticalSafetyState`, High |
| contract available=1 且 manifest/log/marker identity 不一致 | Binding invalid | `TradingRunBindingInvalid`, High |
| inventory target 缺少 probe series 超過 3m | Telemetry missing | `TradingTelemetryMissing`, High |

Telemetry missing 必須從中央 inventory 檢查，不依賴同一 agent 的 `run_expected`。Prometheus 的 `absent_over_time()` 專門用於偵測指定 series 消失；多 target 版本以 inventory `unless` probe series 實作。參考：[Prometheus query functions](https://prometheus.io/docs/prometheus/latest/querying/functions/#absent_over_time)。

---

## 7. Grafana Dashboard Specification

Dashboard identity：

```text
Folder: Trading
Title:  Trading — tnauqquant overview
UID:    tnauqquant-trading-overview
Tags:   layer:business, product:tnauqquant, provisioned
Default range: Last 24 hours
Variables: $environment → $server_id → $strategy → $run_id
```

### 7.1 Layout

```text
┌─────────────────────────────────────────────────────────────┐
│ PNL                                                         │
│ [Current Real PNL] [Risk PNL] [Cash PNL] [Rebate]           │
│ [Real PNL trend...........................................]  │
│ [Latest PNL sample time] [PNL data age] [Cycles completed]   │
├─────────────────────────────────────────────────────────────┤
│ CURRENT RUN STATUS                                          │
│ [Running (heuristic) / Running / Completed / Critical / ...]│
│ [Process count] [Run expected] [Log age] [Identity status]   │
├─────────────────────────────────────────────────────────────┤
│ ERRORS                                                      │
│ [Errors in selected range] [Latest error time + msg]         │
│ [Error/Fatal log table: time | level | msg | err | run_id]  │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 PNL panels

Primary PNL 定義為最新 `stable=true` 的 `pnl_status.real_pnl_usdt`。這個欄位是 engine 對外呈現的已計算結果；`cash_pnl_usdt`、`rebate_usdt` 與 `risk_pnl_usdt` 作為解釋與風險對照。若最新 `pnl_status` 是 `stable=false`，dashboard 保留上一筆 stable PNL，但 PNL data age 繼續增加並顯示 sample unstable，不能把不穩定值冒充 current。

| Panel | Source | 行為 |
|---|---|---|
| Current Real PNL | Loki `msg=pnl_status`, `stable=true`，unwrap `real_pnl_usdt` | >=0 綠、<0 紅、無近期 stable 樣本顯示 No data |
| Risk PNL | unwrap `risk_pnl_usdt` | 顯示 engine risk basis 的最新值 |
| Cash PNL | unwrap `cash_pnl_usdt` | 顯示未含 rebate 的現金損益 |
| Rebate | unwrap `rebate_usdt` | 解釋 cash 與 real PNL 差異 |
| Real PNL trend | latest value over time | 不對不同 run 自動累加；由 `$run_id` 篩選 |
| PNL data age | latest `pnl_status` event timestamp | 防止把舊 PNL 當成 current |
| Cycles completed | unwrap `cycles_completed` | 最新 cycle count |

`position` 不納入 v1 核心 dashboard。若未來顯示 log-derived position，必須標示 `last reported` 與 age；authoritative current exposure 留給原生 `/metrics`。

### 7.3 Run status panels

Status panel 優先順序固定：

```text
Telemetry Missing
  > Duplicate
  > Critical Safety State
  > Binding Invalid
  > Unexpected
  > Down
  > Completed
  > Running
```

較危險狀態必須覆蓋較普通狀態，避免 duplicate process 同時被顯示成 healthy running。

當 `runtime_contract_available=0` 且 heuristic 找到單一 process 時，顯示 `Running (heuristic)`，並以中性色標示「不具 production paging 資格」；不能顯示成完整綠色 `Running`。

### 7.4 Error panels

- `Errors in selected range` 計算 `level=ERROR|FATAL` 的事件數。
- `Latest error` 顯示 event time、`msg` 與 scrub 後 `err`。
- Log table 只顯示 ERROR/FATAL，依新到舊排序。
- 沒有 Error 時 count 明確顯示 `0`，table 顯示空狀態，不以 No data 冒充零錯誤。
- `msg` 與 raw `err` 不升成 labels；只在 query time parse。

### 7.5 Additional indicators retained

使用者指定範圍外，只保留直接影響 PNL 可相信程度的四項：

- PNL data age。
- cycles completed。
- process count／duplicate detection。
- telemetry/identity binding status。

Latency、host CPU/RAM、position、order volume 與 exchange detail 不進 v1 主畫面；需要 troubleshooting 時再放 secondary dashboard。

---

## 8. Error Alerting and Shadow Routing

### 8.1 Error taxonomy

- Specific critical message 使用專用 rule，例如 runtime halt、unhedged、emergency exit。
- Generic safety-net rule 捕捉所有未被專用 rule 涵蓋的 ERROR/FATAL。
- Critical WARN 必須逐項 allowlist，不能把所有 WARN 送 Telegram。
- Generic rule 排除專用 message，避免同一事件通知兩次。
- 三筆一秒內相同錯誤由 Alertmanager grouping 合成一個 notification，不把 raw error text 放入 grouping labels。

### 8.2 Routing

Alertmanager 最前方新增：

```text
notification_mode=shadow → shadow-null receiver → stop routing
```

每個新 target 的 Prometheus 與 Loki rules 都先加 `notification_mode="shadow"`。Promotion 是一個可 review 的 Git change：

```text
shadow → page
```

`page` 沿用既有 High receiver，所以 ERROR/FATAL 最終會進 Telegram，並由既有 email receiver 備援。Development 期間不建立新的 Telegram bot 或 receiver。

第一版不建立 rule generator：每個 target 的 Prometheus/Loki rule stanza 使用精確 `environment/server_id/strategy` selector，並與 `trading-targets.yml` 的 inventory entry 同一個 commit 新增或升級，確保 Loki rules 也有明確的 shadow/page 狀態。

---

## 9. Repository Ownership and File Plan

### 9.1 SkyEye Track — 由本 repo agent 實作

**Create:**

```text
agents/alloy/trading/config-macos.alloy.tmpl
agents/alloy/trading/deployment.env.example
agents/alloy/trading/setup-macos.sh
agents/alloy/trading/probe.sh
agents/alloy/trading/com.wanbrain.skyeye-trading-probe.plist.tmpl
agents/alloy/trading/README.md
tests/fixtures/tnauqquant/trading.raw.log
tests/fixtures/tnauqquant/trading.raw.log.sha256
tests/trading/test-probe.sh
tests/trading/test-log-pipeline.sh
prometheus/rules/trading-targets.yml
prometheus/rules/trading.yml
prometheus/rules/tests/trading.test.yml
loki/rules/fake/tnauqquant.yml
grafana/dashboards/Trading/tnauqquant-trading-overview.json
runbooks/trading-process-down.md
runbooks/trading-critical-safety-state.md
runbooks/trading-telemetry-missing.md
```

**Modify:**

```text
docker-compose.yml
alertmanager/alertmanager.yml
agents/alloy/README.md
docs/onboarding-new-product.md
docs/grafana-conventions.md
runbooks/README.md
README.md
```

`loki/loki-config.yml` 已有 local ruler directory 與 Alertmanager URL，預設不修改。Compose 只需把 `./loki/rules` 唯讀 mount 到 `/loki/rules`；若實際 Loki validation 證明還缺參數，才以獨立 commit 修改 config。

### 9.2 Trading Track — 交由另一個 tnauqquant agent 實作

可直接貼給該 agent 的完整獨立規格：[`trading-runtime-contract-agent-spec.md`](./trading-runtime-contract-agent-spec.md)。

**Modify:**

```text
scripts/tq
cmd/quant/main.go
engine/engine.go
engine/engine_test.go
```

**Responsibilities:**

1. Launcher 產生 `run_id`、canonical log path、manifest path 與 done marker path。
2. Quant process 寫 actual PID/start time 與 config hash，不從 shell pipeline 猜 PID。
3. Marker 寫入必須 atomic，且包含 run binding fields。
4. Manifest 保持 immutable `state=running`；safe/critical outcome 由 bound marker 表達，SkyEye probe 依 marker precedence 導出 `run_expected`。
5. 新 run 遇到未 archive 的舊 marker 時 fail closed，要求 operator 明確處理。
6. 保留 `tq live run --human` 的 signal/preflight 行為。
7. 不在此工作順便改 JSON logging 或實作完整 `/metrics`。

### 9.3 Cross-repo interface test

Trading agent 完成後交付兩份 fixture：

```text
run-manifest.v1.json
done-marker.v1.json
```

SkyEye probe tests 以這兩份 schema fixture 驗證。兩個 repo 對 `schema_version=1`、reason allowlist、strategy slug 與 config hash encoding 必須完全一致。

---

## 10. Implementation Roadmap

### Task 1: Approved contract and dashboard semantics

**Owner gate:** SkyEye owner

- [x] 確認 production runtime 是 `tq live run --human` + tmux + no auto-restart。
- [x] 確認 dashboard primary PNL 使用最新 `stable=true` 的 `real_pnl_usdt`。
- [x] 確認 development target ID 使用 `tnauqquant-dev-mac`，production target ID 使用 `tnauqquant-prod-1`。
- [x] 確認 production migration 接受 Trading repo 的最小 runtime contract 改動。
- [x] 確認 Trading PNL 與 raw error logs 僅限明確核准的 operator email。
- [ ] SkyEye operator 從 Cloudflare Zero Trust 實際確認 live allowlist；若有非核准使用者，先完成 datasource access isolation。

**Deliverable:** Core decisions 已核准；完成 live Cloudflare allowlist verification 後才 ingest Trading data。

### Task 2: Build deterministic fixtures and macOS probe tests

**Repo:** SkyEye

- [ ] 建立 scrubbed raw-log fixture 與 checksum。
- [ ] 建立 manifest/marker v1 fixtures。
- [ ] 先寫 probe tests：0/1/2 processes、safe completion、risk halt、unknown marker、stale marker、log binding mismatch。
- [ ] 執行 tests，確認在 probe 尚未存在時失敗。
- [ ] 實作唯讀 probe 與 atomic textfile output。
- [ ] 重跑 tests，確認全部通過。
- [ ] 以 `bash -n`、`shellcheck` 與 fixture checksum 驗證。

**Deliverable:** 不需要真實 trading process 也能 deterministically 驗證 state machine。

### Task 3: Build macOS Alloy deployment

**Repo:** SkyEye

- [ ] 實作參數化 `config-macos.alloy.tmpl`，包含 file tail、logfmt、timestamp、scrub、run_id relabel、textfile collector、remote write/push。
- [ ] 實作 `setup-macos.sh`，從 `brew --prefix` 導出路徑，檢查 config.env 權限並安裝 probe launchd job。
- [ ] Installer 在任何變更前驗證必要 path 與 env，且不把 secret 印到 stdout。
- [ ] 執行 `alloy fmt`、`alloy validate`、`plutil -lint`。
- [ ] 在 development Mac 以 fixture dry-run，確認 scrub 後才送出。

**Deliverable:** 同一份 template 只改 env values 就能部署另一臺 macOS server。

### Task 4: Add central inventory, rules and shadow route

**Repo:** SkyEye

- [ ] 先新增 `shadow-null` receiver 與最前方 shadow route。
- [ ] 用 `amtool check-config` 驗證 routing。
- [ ] 新增 development target inventory。
- [ ] 先寫 `promtool test rules` cases：down、duplicate、unexpected、safe completion、critical reason、telemetry absent、binding invalid。
- [ ] 新增 Prometheus rules，跑到所有 unit tests 通過。
- [ ] 新增 Loki ERROR/FATAL rules，generic rule 排除 specific message taxonomy。
- [ ] 新增 Loki rules readonly mount，執行 `lokitool rules lint` 與 `docker compose config --quiet`。

**Deliverable:** Alerts 在中央正確 firing，但 `notification_mode=shadow` 不會送 Telegram/email。

### Task 5: Build and verify Grafana dashboard

**Repo:** SkyEye

- [ ] 建立固定 UID 的 dashboard JSON。
- [ ] 實作 PNL、Run Status、Errors 三個獨立區塊。
- [ ] 實作 variable chain `$environment → $server_id → $strategy → $run_id`。
- [ ] 以 fixture-backed Loki/Prometheus data 驗證正值、負值、No data、Completed、Critical、Duplicate 與零 Errors。
- [ ] 執行 `jq empty`，重啟 Grafana provisioning，確認 60 秒後 dashboard 仍存在且 datasource UID 正確。

**Deliverable:** Development Grafana URL 可直接看到最新 PNL、可靠的 data age、run state 與 error table。

### Task 6: Development end-to-end canary

**Environment:** `tnauqquant-dev-mac`

- [ ] 使用 development 專用 Cloudflare service token；確認 token 只允許 prom/loki push endpoints。
- [ ] 啟動 Alloy 與 probe，不重啟、不 signal 真實 trading process。
- [ ] Loki 查詢在 30 秒內出現當前 raw log，且不含 `/Users/tinghsu` 絕對路徑。
- [ ] Prometheus 查詢在 30 秒內出現 probe metrics。
- [ ] Grafana Current Real PNL 與 raw log 中最新 `stable=true` 的 `pnl_status.real_pnl_usdt` 一致。
- [ ] Grafana 顯示最新 sample time 與 age，避免舊值冒充 current。
- [ ] 用 dummy process/fixture 模擬 down、duplicate、safe completion、risk halt、probe outage 與 ERROR burst。
- [ ] 確認 shadow alerts firing、沒有外部通知、同一 ERROR burst 不重複 firing 多個 generic/specific alerts。
- [ ] 保存 query screenshot、rule test output 與 Alloy validation output 作為驗收證據。

**Deliverable:** Owner 在 Grafana 確認 development POC，核准進入新 server migration。

### Task 7: Trading runtime contract in parallel

**Repo:** tnauqquant

- [ ] 從最新 `origin/master` 建立獨立 worktree，先處理目前主工作樹既有變更，不能直接覆蓋。
- [ ] 先寫 engine/launcher tests，再實作 manifest 與 marker v1。
- [ ] 驗證 max cycles、reduce-only、risk halt、drain failure、signal shutdown 與 stale marker。
- [ ] 交付 schema fixtures 與 canonical launch runbook。

**Deliverable:** SkyEye probe 在 production mode 能讓所有 identity/binding metrics 等於 1。

### Task 8: New server onboarding

**Owner:** New server agent + SkyEye operator

- [ ] 新 server agent 提交 4.4 節 handoff report。
- [ ] 安裝與 development 驗證相同的 Alloy version；任何 package version 必須在安裝時確認發布超過 7 天並記錄版本。
- [ ] 依新路徑填入 deployment env；不得修改 central queries 來配合路徑。
- [ ] 中央新增 `tnauqquant-prod-1` inventory，狀態為 shadow。
- [ ] 使用 Trading canonical launcher 啟動一個受控 run。
- [ ] 重做 Task 6 的 Loki、Prometheus、Grafana 與 canary 驗收。
- [ ] 觀察至少一個完整實際 trading cycle。
- [ ] Owner 核准後將 production target 從 shadow 改為 page。
- [ ] Development target 若不再使用，依 retired 流程移除，不留下 stale alerts。

**Deliverable:** 新 server path 可以不同，但 dashboard、rules、labels 與 run semantics 完全相同。

### Task 9: Documentation and operational closeout

**Repo:** SkyEye

- [ ] 更新一般 onboarding 文件，明示 trading 是需要專用 rules/runtime contract 的例外。
- [ ] 更新 runbook inventory 與 Grafana dashboard inventory。
- [ ] 記錄 service token rotation/revocation 與 server retirement 步驟。
- [ ] 完成所有驗證命令後才把 target promotion commit 合併。

**Deliverable:** 另一個 agent 不需要讀本次對話，只讀 repo 文件即可重建接入流程。

---

## 11. Verification Matrix

### 11.1 Static validation

```bash
bash -n agents/alloy/trading/setup-macos.sh
bash -n agents/alloy/trading/probe.sh
shellcheck agents/alloy/trading/setup-macos.sh agents/alloy/trading/probe.sh
plutil -lint rendered/com.wanbrain.skyeye-trading-probe.plist
alloy fmt rendered/config.alloy
alloy validate rendered/config.alloy
amtool check-config alertmanager/alertmanager.yml
promtool check config prometheus/prometheus.yml
promtool check rules prometheus/rules/trading-targets.yml prometheus/rules/trading.yml
promtool test rules prometheus/rules/tests/trading.test.yml
lokitool rules lint loki/rules/fake/tnauqquant.yml
docker compose config --quiet
find grafana/dashboards -name '*.json' -exec jq empty {} +
```

Prometheus rule unit tests 的官方格式參考：[Unit testing rules](https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/)。

### 11.2 End-to-end acceptance

| Test | Expected result |
|---|---|
| Current PNL | Grafana 值等於最新 `stable=true` 的 `pnl_status.real_pnl_usdt` |
| PNL freshness | Latest sample time/age 正確；舊資料不標成 current |
| Normal running | `process_count=1`，status=Running |
| Development heuristic | `runtime_contract_available=0`，status=Running (heuristic) |
| Duplicate process | status=Duplicate，僅一個 High alert instance |
| Safe max-cycles completion | status=Completed，不觸發 ProcessDown |
| Risk halt | status=Critical，不論 process 是否仍存在都觸發 High |
| Probe stopped | 中央 inventory 於 3m 後觸發 TelemetryMissing |
| Alloy/network stopped | logs/metrics 停止；telemetry alert 不依賴 agent 自報 |
| Error burst | Error count 正確，table 有三筆，通知被 grouping，不雙重 page |
| Path privacy | Loki labels/lines 不含 development user absolute path |
| New server path | 只改 deployment env；中央 dashboard/query 不修改 |

---

## 12. Go/No-Go Gates

### Development POC is complete when

- PNL、Run Status、Errors 三個區塊在 Grafana 都有可驗證資料。
- Latest PNL 與 raw log 最新 `stable=true` 的 `pnl_status` 一致。
- Error logs 可查詢，PII/path scrub 已驗證。
- Probe/Alloy restart 後不重送大量舊 logs，且 positions corruption 行為符合 contract。
- 所有 alerts 仍在 shadow；canary 結果符合 state table。

### New server may enter shadow when

- Trading runtime contract 已合併並產生 valid manifest/marker。
- Probe 回報 `tnauqquant_runtime_contract_available=1`。
- New server handoff report 完整，路徑與權限驗證通過。
- Dedicated service token 已建立且可獨立撤銷。
- Central target inventory 已註冊 production server。

### Production paging may be enabled when

- Production canary 全部通過。
- 已觀察至少一個完整實際 trading cycle。
- Safe completion 沒有 ProcessDown false positive。
- Duplicate、risk halt、unknown marker 與 telemetry outage 都能準確 firing。
- Owner 明確核准 shadow → page 的 Git change。

---

## 13. Deferred Scope

以下項目不阻擋第一版，另立計畫：

- Trading 原生 `/metrics` 與 authoritative current exposure。
- JSON logging migration。
- Watchdog auto-restart 與共用 launcher 重構。
- Host CPU/RAM/disk secondary dashboard。
- Latency、volume、position 與 exchange-specific deep-dive dashboard。
- 多 strategy 自動產生 inventory/rules 的 generator。

這些項目不能被順便塞進第一版 PNL monitoring branch。
