# popdex-multi-accounts：Trading01 雙帳號 PopDEX BTC 輪替監控

- Linear: WAN-928
- Request: popdex-multi-accounts-20261126
- 狀態: S1 實作完成並通過非 Docker 驗證（2026-11-26）；Docker／promtool 檢查 PENDING（待主機恢復 Docker 後補跑）

## 目標

為 Trading01 上新的 tnauqquant lane `popdex-multi-accounts` 建立 SkyEye 監控（Linear WAN-928）。該 lane 以 `routing.mode: random` 在兩支 PopDEX 帳號（executor `popdex-main` 沿用 `popdex-btc` 既有帳號、`popdex-rot2` 為新帳號）之間輪替：每筆 signal 預選其中一支進場，平倉在同一支做 reduce-only，兩支互不對沖；切換上線後將取代 `popdex-btc`。

Wan 的原話：
> 「新的我希望它能合併這兩隻一起做計算，也就是合併這兩隻的 equity 跟績效，並統計在同一個面板上（可能都還是叫 BTC 之類的），只是變成有兩隻帳號。」

本次完成三件事：
1. 擴充共用 `agents/alloy/trading/probe.sh`（及 `setup-linux.sh` 驗證），支援同一交易所對應多支 executor 的 `TQ_EXECUTOR_MAP` 格式，確保單帳號既有 lane（含 `popdex-btc`、`popdex-02`、`lighter-robinhood-btc-canary`）與雙交易所 lane（`toobit-mexc-btc`）的行為與 `.prom` 輸出維持不變。
2. 以「合併為主、各帳號分項為輔」呈現雙帳號合併 equity、PnL、週期、成交額與淨持倉，並在 `Trading · 策略詳情` 補上各帳號分項明細（低基數 `executor` label）。
3. 提出並文件化 `popdex-btc` 切換策略、歷史資料延續方案、Trading01 host rollout／`central-deploy` 與 rollback 程序。

## 不做

- 不修改 tnauqquant 的 repo、config、env 或 binary，也不在 Trading01 上啟動、停止、重啟或 enable/disable 任何 `tnauqquant@*` service/timer。
- 不在本次任務執行 Trading01 host rollout 或 monitoring-prod `scripts/central-deploy`（待 tnauqquant manager 通知切換時間後另派 operator 執行 S2）。
- 不把任何 Trading 告警從 `shadow` 升級成 `page`，不改 Alertmanager 路由。
- 不重構其他 lane 的面板，不改動既有 Grafana datasource UID（`prometheus`、`loki`、`alertmanager`）。
- 不修改 `prometheus/rules/tests/fixtures/trading-targets.yml`（rule 語意 fixture）或 `docs/work-log.md`。
- 不在本次移除 `prometheus/rules/trading-targets.yml` 中的 `popdex-btc` row（切換穩定後才走 S3 退場）。

## 做法要點

### 1. `TQ_EXECUTOR_MAP` 格式與向後相容性

沿用既有逗號分隔 `<executor>=<exchange>` 語法，允許不同 executor 映射到同一個 `exchange`：

```text
TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex
```

為何不另造新分隔符（例如 `popdex-main+popdex-rot2=popdex`）或新環境變數：
- 完全相容既有單帳號（`popdex-main=popdex`、`popdex-02=popdex`、`lighter-robinhood-main=lighter`）與雙交易所（`toobit-main=toobit,mexc-ui=mexc`）寫法，並自然支援未來 N 帳號輪替。
- `agents/alloy/trading/linux-common.sh` 的 `installed_env_value` 原生接受 `,` 與 `=`，systemd `EnvironmentFile=` 與 bash `source` 讀取結果完全一致。
- `tests/trading/test-central-config.sh` 已用 `tr ',' '\n' | sed -E 's/^[^=]*=//'` 抽取 exchange 名稱，無需修改解析語法。
- `probe.sh` 既有驗證已逐項檢查 `valid_label_value` 且禁止重複 `executor_name`（兩支不同 executor 映射到同一個 `exchange_name` 本就合法）。

在 `probe.sh` 中由 `TQ_EXECUTOR_MAP` 直接推導三個拓撲旗標（不新增 env 變數）：
- `UNIQUE_EXCHANGE_COUNT`：去重後的 mapped exchange 數量。
- `HAS_SHARED_EXCHANGE`：若任一 exchange 對應 ≥2 個合法 executor 則為 `1`，否則為 `0`。
- `SINGLE_EXCHANGE_VALID`：當 `UNIQUE_EXCHANGE_COUNT == 1` 且 `EXECUTOR_MAP_SIZE == ${#executor_entries[@]}`（排除尾端逗號空欄位）時為 `1`，否則為 `0`。

相容性矩陣：

| 範例 `TQ_EXECUTOR_MAP` | `EXECUTOR_MAP_SIZE` | `UNIQUE_EXCHANGE_COUNT` | `HAS_SHARED_EXCHANGE` | `SINGLE_EXCHANGE_VALID` | 行為 |
|---|---:|---:|---:|---:|---|
| `popdex-main=popdex`（單帳號） | 1 | 1 | 0 | 1 | 與既有版本 byte-for-byte 完全相同 |
| `popdex-02=popdex`（ETH 單帳號） | 1 | 1 | 0 | 1 | 與既有版本 byte-for-byte 完全相同 |
| `toobit-main=toobit,mexc-ui=mexc`（雙交易所） | 2 | 2 | 0 | 0 | 與既有版本 byte-for-byte 完全相同 |
| `x=venue,`（`test-probe-equivalence.sh` Scenario 20） | 2 | 1（含空欄為 2） | 0 | 0 | 保留既有等價行為，byte-for-byte 相同 |
| `popdex-main=popdex,popdex-rot2=popdex`（同交易所雙帳號） | 2 | 1 | 1 | 1 | 合併指標走單交易所語意，並輸出 4 個低基數 per-executor 分項 metrics |

同步在 `linux-common.sh` / `setup-linux.sh` 補上 `TQ_EXECUTOR_MAP` 嚴格格式驗證（literal assignment、至少一項、無空欄位／尾端逗號、左右皆符合 `valid_label_value`、不可重複 executor），在 `--render-only` 與 `add` 寫檔前 fail closed；`probe.sh` 維持既有檢查以保 Scenario 20 等價測試。

### 2. tnauqquant raw log 資料來源確認（唯讀檢核）

依 `/Users/tinghsu/projects/tnauqquant/docs/decisions/routing-rotation.md` 及 tnauqquant 原始碼確認實際欄位格式：

| Raw log `msg` | 實際欄位與格式 | 語意與邊界 |
|---|---|---|
| `initial_equity_recorded` | `equity_usdt=10000.00`、`equity_usdt_by_executor=popdex-main:5000.00,popdex-rot2:5000.00` | 啟動時查詢所有 executor 的 `GetEquity`；任一失敗即回錯不寫出，故必為全帳號完整快照。 |
| `pnl_status`（`stable=true`） | `equity_now`（producer 先加總全帳號後依 text logger 規則取至多兩位小數寫出）、`equity_usdt_by_executor=name:%.2f,...`（各帳號各自四捨五入至兩位小數）、`volume_usd_by_executor=name:%.2f,...`、`real_pnl_usdt`、`cash_pnl_usdt`、`rebate_usdt`、`risk_pnl_usdt`、`cycles_completed`、`session_cycle`、`cycle_id`、`cycle_completed`、`cycle_real_pnl_usdt`、`cycle_executor=<name>`、`risk_stopped` | 單一 `RiskManager` 已合併全帳號（R12）；R4 規定每次結帳必須讀到全帳號完整 equity（最多重試 3 次，否則在發布 `pnl_status` 前返回、寫出 `ERROR msg=required_accounting_retry_exhausted` 並請求 `accounting_publication_failed` risk stop），絕不發布缺帳號的 `stable=true` 快照。R10 規定 `cycle_executor` 標示該輪結帳帳號（`random` 下即 confirmed carrier）。 |
| `trade_status` | `executor=<name>`、`volume_usd=...`；`state=settled` 且 `settlement=confirmed`（含 `phase=entry`、`phase=carrier_exit`、`phase=startup_neutralization`、`phase=protective_recovery`）另帶依 coordinator 版本排序的 `portfolio_projection=coordinator_book`、`net_side`、`net_qty_btc`（進場時帶 `initiator_venue`／`initiator_side`／`initiator_qty_btc`，非對沖 `random` lane 不帶 `carrier_venue`） | `volume_usd` 作為 `volume_usd_by_executor` 缺省時的 fallback；只有 `msg=trade_status`、`state=settled`、`settlement=confirmed` 的 `coordinator_book` 為同交易所多帳號 lane 的權威持倉來源，診斷快照（例如 `coordinated_signal_skipped`）一律不採用。 |
| `ui_warmup_async_ready` | `executor=<name>`、`reason=gross_flat_verified:...` | 單帳號與雙交易所既有 lane 維持原行為；同交易所多帳號 lane（`HAS_SHARED_EXCHANGE == 1`）**不**採用此非同步事件清零持倉，避免前一輪某支帳號延遲完成的 warmup 蓋掉另一支帳號的新開倉部位。 |
| `coordinated_dispatch_result` | 帶 `executor=<name>`（註：`cycle_executor` 實作在 `pnl_status`／`equity_snapshot`／`pnl_settle_equity_sample`） | 含 `no_fill`、`no_submit`、`unresolved` 嘗試，不作為 PnL／成交量權威來源；probe 不掃描此事件以維持單次 pass 效能與精準語意。 |

### 3. Probe 合併與分項計算方式（Equity 加總、PnL 不重複計算、持倉修正）

#### 3.1 既有合併 Metrics（維持原名、原 `# HELP`、無重複計算）

1. **合併總權益 `tnauqquant_current_equity_usdt`**
   - 優先採最新 trusted `pnl_status`（`stable=true`）中由 producer 先加總全帳號後寫出的 `equity_now`（text raw log 依 `textLogFloatDecimals` 取至多兩位小數；`probe.sh` 原樣保留收到的精度，不做截斷或重算）。各帳號分項 `equity_usdt_by_executor` 為個別四捨五入至兩位小數，「先加總再取兩位」與「各帳號取兩位再相加」可能相差 ±0.01 USDT，故合併總權益一律直接採用 `equity_now`，**不**由分項反算加總，避免捨入誤差或漏計未映射帳號。
   - **啟動初期（尚無任何 `pnl_status stable=true` 時）**：僅在 `HAS_SHARED_EXCHANGE == 1` 且整個 bound log 尚未出現任何 `pnl_status stable=true` 行（`CURRENT_PNL_LINE == ""`）時，若存在時間可信的 `initial_equity_recorded` 且 `equity_usdt` 為合法數字，則輸出該初始總權益（以及初始各帳號權益），讓啟動後、首輪尚未完成前即可在面板看到兩支帳號合併與分項餘額。
   - **Fail-closed 不變量**：一旦 log 出現任何 `pnl_status stable=true`（即使其時間在未來，或缺少／無效 `equity_now`），立即停止採用 `initial_equity_recorded`，絕不回退舊餘額（完全維持 `test-probe.sh` 的「missing and invalid equity never reuse an earlier total」語意）。
2. **合併績效（`real_pnl_usdt`、`cash_pnl_usdt`、`rebate_usdt`、`risk_pnl_usdt`、`last_cycle_real_pnl_usdt`、`cycle_cumulative_real_pnl_usdt`、`current_cycles_completed`、`completed_cycles_today`）**
   - 直接沿用 `pnl_status`（`stable=true`）的策略級合併欄位。`cycle_cumulative_real_pnl_usdt` 與 `completed_cycles_today` 維持既有去重鍵（`cycle` 與 `run_id:cycle_id`），跨帳號不加總、不重複計算。
3. **合併成交額 `tnauqquant_current_run_exchange_volume_usd{exchange="popdex"}`**
   - 既有 `scan_manifest_log` 已將每個 mapped executor 的 `volume_usd_by_executor`（缺省時 fallback 為 `trade_status` 的 `volume_usd`）累加至 `executor_exchange[executor]`。因此 `popdex-main=popdex,popdex-rot2=popdex` 自動產出單一 `exchange="popdex"` series，值等於 `popdex-main + popdex-rot2`，零重複計算。
4. **合併持倉 `tnauqquant_current_position_btc` & `tnauqquant_current_net_position_btc`（關鍵修正）**
   - **現行缺陷**：既有 `probe.sh` 用 `mapping_count > 1`（`is_gross_flat`）與 `executor_map_size == 1`（由 `NET_POSITION_SNAPSHOT` 寫入 `CURRENT_POSITION_SERIES`）區分單／雙交易所。當 `TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex` 時，`EXECUTOR_MAP_SIZE == 2`，而 `routing.mode: random` 非對沖開倉時 `coordinator_book` 只有 `initiator_venue` 與 `net_side`/`net_qty_btc`、沒有 `carrier_venue`。此外，tnauqquant 的 `ui_warmup_async_ready`（`gross_flat_verified:`）是各 executor 非同步執行，若上一輪平倉帳號的 warmup 晚於另一支帳號的新開倉完成，沿用 `is_gross_flat` 會誤將已確認的持倉覆寫為 `flat 0`。
   - **修正方式**：
     - `scan_manifest_log` 在 `has_shared_exchange == 1` 時停用 `is_gross_flat`（不讓非同步 `ui_warmup_async_ready` 清零持倉），並在快速解析路徑與一般解析路徑皆只接受依 coordinator 版本順序發布的 `msg=trade_status`、`state=settled`、`settlement=confirmed` 之 `portfolio_projection=coordinator_book` 快照，拒絕診斷快照（例如 `coordinated_signal_skipped`）覆寫持倉。
     - 兩腿 `coordinator_book` 分支的同交易所排除條件 `executor_exchange[initiator_venue] != executor_exchange[carrier_venue]` 僅限於 `has_shared_exchange == 1`（確保單帳號 `has_shared_exchange == 0` 維持與 baseline 逐位元組等價）；所有 `mapped_executor`／`executor_exchange` 查詢一律使用不建立鍵的 `in` membership 檢查，避免未映射 executor 污染 allowlist。
     - shell 層改用 `[[ "$SINGLE_EXCHANGE_VALID" -eq 1 ]]` 決定是否由 `NET_POSITION_SNAPSHOT` 產出單一 `exchange="popdex"` 的 `CURRENT_POSITION_SERIES`。
     - 既有單帳號（`popdex-main=popdex`）、雙交易所（`toobit-main=toobit,mexc-ui=mexc`）與 Scenario 20（`x=venue,`）結果完全不變；`# HELP` 文字維持 byte-identical（受 `assert_position_help_pinned` 保護）。

#### 3.2 新增 4 個低基數 Per-Executor 分項 Metrics（僅 `HAS_SHARED_EXCHANGE == 1` 輸出）

所有新增 metrics 的 labels 嚴格限定為：
`product`, `environment`, `server_id`, `strategy`, `exchange`, `executor`
其中 `exchange` 與 `executor` 皆來自 `TQ_EXECUTOR_MAP` allowlist（已通過 `valid_label_value`），基數等於帳號數（本 lane 為 2：`popdex-main`、`popdex-rot2`）。絕不從 raw log 動態引入未映射字串、訂單 ID、client action ID、attempt ID、run ID 或本機路徑。

| Metric（gauge） | 來源與計算規則 | 防重複／Fail-Closed 保護 |
|---|---|---|
| `tnauqquant_current_executor_equity_usdt` | 最新 trusted `pnl_status`（`stable=true`）的 `equity_usdt_by_executor`（格式 `exec:val,...`）；若尚無任何 `pnl_status stable=true` 則取最新 trusted `initial_equity_recorded` 的 `equity_usdt_by_executor`。 | 若 winning 快照缺少 `equity_usdt_by_executor`、任一 mapped executor 數值非法或未出現、或最新 `pnl_status` 時間在未來，則完全不輸出（不回退舊快照）；未在 `TQ_EXECUTOR_MAP` 內的 executor 忽略。 |
| `tnauqquant_current_run_executor_volume_usd` | 與 `tnauqquant_current_run_exchange_volume_usd` 同步：優先取最新 trusted `pnl_status`（`stable=true`）的 `volume_usd_by_executor`；缺省時 fallback 為 trusted `trade_status` 依 `executor` 累加的 `volume_usd`。依 `TQ_EXECUTOR_MAP` 順序為每個 mapped executor 輸出（未成交者為 `0`）。 | 數學不變量：`sum by (exchange) (executor_volume) == exchange_volume`，絕不重複計入同時存在於 snapshot 與 `trade_status` 的成交額。 |
| `tnauqquant_current_executor_real_pnl_usdt` | 僅在 `CURRENT_PNL_VALID == 1` 且至少有一筆 trusted 完成週期帶有 mapped `cycle_executor` 時輸出：先將所有 trusted `pnl_status`（`stable=true`、`cycle_completed=true`）依既有 `cycle` 鍵（`session_cycle != "" ? session_cycle : cycles_completed`）去重（同 cycle 重複行覆寫不累加），再對合法數值的 `cycle_real_pnl_usdt` 依 `cycle_executor` 加總；未輪到的 mapped executor 補 `0`。 | (1) 同 cycle 重複 `pnl_status` 只計一次；(2) `cycle_real_pnl_usdt` 含 rebate 與手續費調整，與 `real_pnl_usdt` 同口徑（避免 `%.2f` equity 差值精度損失及漏計 rebate）；(3) 若某筆週期缺 `cycle_executor`（例如舊版或特殊復原）不猜測歸屬，面板註記以合併 `本輪實現損益` 為最終權威。 |
| `tnauqquant_current_executor_cycles_completed` | 與 `tnauqquant_current_executor_real_pnl_usdt` 相同去重後之 cycle 表，依 mapped `cycle_executor` 計數；未輪到的 mapped executor 補 `0`。 | 便於直接核對 `routing.mode: random`（N=2 嚴格交替）在兩支帳號間的成交分配是否均衡。 |

效能與等價測試影響：
- `HAS_SHARED_EXCHANGE == 0` 時，`grep_fixed_lines` 參數與輸出區塊完全不變，既有與新增的 `test-probe-equivalence.sh` 情境（共 69 項，含單帳號同 venue `coordinator_book` 等價案例）100% byte-for-byte 等價。
- `HAS_SHARED_EXCHANGE == 1` 時僅在既有單次 `grep -a -n -F` 多一個 `-e initial_equity_recorded`（每個 run 只有 1 行），並在同一支 `awk` 內完成解析，零額外檔案掃描、零額外 subprocess fork，維持在 `CPUQuota=20%` 預算內。
- 4 個新 metric 名稱皆全新，與舊版 `.prom` 檔案並存於同一 textfile collector 時不會產生 `# HELP` 衝突。

### 4. `popdex-multi-accounts` Linux Env Example（隔離規格）

新增 `agents/alloy/trading/deployment-linux-popdex-multi-accounts.env.example`（不更動既有的 `deployment-linux-popdex.env.example`）：
- `TQ_STRATEGY=popdex-multi-accounts`、`TQ_INSTANCE_ID=popdex-multi-accounts`（已向 tnauqquant 側確認，Step 1 依主機 config YAML 再次核對）
- `TQ_EXECUTABLE=/home/ubuntu/tnauqquant/bin/popdex-multi-accounts/quant`（WAN-946 修正預填值）。Step 1 只從 `manager.env` 取唯一的 `TNAUQ_EXPECTED_BIN`，核對路徑並排除目錄、共用 launcher 與 sibling 的執行檔。首次啟動前允許 binary 尚未產生。Step 5c 必須確認為可執行的一般檔案且等於 manifest `.executable`。不得讀取 `/home/ubuntu/tnauqquant/.env.popdex-multi-accounts`。
- `TQ_CONFIG_PATH=/home/ubuntu/tnauqquant/config/popdex_multi_accounts_config.yaml`（已向 tnauqquant 側確認）
- `TQ_RAW_LOG_GLOB=/home/ubuntu/tnauqquant/logs/live-runs/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]_popdex_multi_accounts_config.raw.log`（嚴格 contract 檔名 glob，通過 `test-linux-env-examples.sh` 隔離與相似度測試）
- `TQ_RUN_MANIFEST=/home/ubuntu/tnauqquant/run-state/popdex-multi-accounts/current.json`
- `TQ_DONE_MARKER=/home/ubuntu/tnauqquant/run-state/popdex-multi-accounts/current.done.json`
- `TQ_TEXTFILE_NAME=tnauqquant-popdex-multi-accounts.prom`、`TQ_TEXTFILE_MODE=640`
- `TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex`
- `TQ_STRATEGY_DISABLED=1`（附註 `setup-linux.sh add` 與 `TradingUnexpectedProcess` 說明；等 Wan 完成手動 canary cycle 並決定切換啟用前才改為 `0`）
- `TQ_SIDECAR_REQUIRED=0`、省略 `TQ_BASE_ASSET`（BTC lane 預設 `BTC`）、不含任何 credential 字樣（無 secret/token/password/private）
- 對應獨立 systemd instance `skyeye-trading-probe@popdex-multi-accounts.{service,timer}`、mode-`0600` `/etc/skyeye-trading/instances/popdex-multi-accounts.env`、獨立 Alloy fragment `/etc/alloy/trading-popdex-multi-accounts.alloy`。

### 5. Prometheus Rules 與 Shadow 告警影響

- **`prometheus/rules/trading.yml`**：在 `trading-strategy-recording` 群組新增 4 條通用 recording rules（以 `and on (product, environment, server_id, strategy) trading_target_info` 限縮至已登錄 production 策略，保留 `exchange`、`executor` label，不寫死任何策略／伺服器／帳號名稱）：
  - `trading_strategy_current_executor_equity_usdt`
  - `trading_strategy_current_executor_real_pnl_usdt`
  - `trading_strategy_current_executor_cycles_completed`
  - `trading_strategy_current_run_executor_volume_usd`
- **既有告警影響**：
  - 所有 11 條 Prometheus alerts 與 3 條 Loki alerts（`loki/rules/fake/tnauqquant.yml`）均維持 `notification_mode: shadow`，不新增、不改寫、不升級任何告警。
  - `popdex-multi-accounts` 為單一 OS process 管兩支帳號，因此 `TradingDuplicateProcess`、`TradingProcessDown`、`TradingUnexpectedProcess`、`TradingRuntimeContractMissing`、`TradingRunBindingInvalid`、`TradingTelemetryMissing`、`TradingSourceClockAhead` 均直接適用。
  - R4 閒置帳號 equity 讀取失敗重試（15/30/60s）期間只發 `WARN`，不誤觸告警；3 次重試用完時，tnauqquant 會在發布 `pnl_status` 之前直接返回、寫出 `level=ERROR msg=required_accounting_retry_exhausted` 並請求 `accounting_publication_failed` risk stop。既有 shadow 告警的捕捉條件分工如下：
    - **`TradingCriticalLogEvent`（Loki shadow，`loki/rules/fake/tnauqquant.yml`，第一時間捕捉）**：匹配 `level=~"ERROR([+][0-9]+)?|FATAL([+][0-9]+)?"` 且排除 `TradingExecutionIncident` 的 5 個 msg；`required_accounting_retry_exhausted` 不在排除清單內，會在 1 分鐘視窗內立即由 `TradingCriticalLogEvent` 接住。
    - **`TradingRiskStopped`（Prometheus shadow）**：需等 probe 讀到後續一筆帶 `risk_stopped=true` 的 `pnl_status`（`stable=true`）將 `tnauqquant_risk_stopped` 設為 `1` 才會觸發；若 equity snapshot 持續失敗導致在發布 `pnl_status` 前即返回，此告警不會觸發。
    - **`TradingCriticalSafetyState`（Prometheus shadow）**：需等 tnauqquant 寫出與 manifest 綁定的 `current.done.json`（`reason="risk_halt"` 或 `unknown`）才會觸發；若因仍有未完成的必要 accounting job 而延後或無法寫出 terminal marker，此告警可能延後或不觸發（程序結束後若無 done marker，改由 `TradingProcessDown` 於 2 分鐘後觸發）。
    - 因此確認 accounting 重試耗盡造成的 risk stop 時，應優先以 Loki `TradingCriticalLogEvent`（及 raw log `required_accounting_retry_exhausted`）為準，而非單獨等待兩條 Prometheus 告警。
- **Inventory (`prometheus/rules/trading-targets.yml`)**：
  - 只用 `scripts/trading-target add --server trading01 --strategy popdex-multi-accounts --quote USDT` 操作（詳見待決問題 D1 決定是否於本 PR 執行或延後至 rollout PR），絕不手改，也不改 `prometheus/rules/tests/fixtures/trading-targets.yml`。
- **Rule 測試 (`prometheus/rules/tests/trading.test.yml`)**：新增針對 4 條 `trading_strategy_*_executor_*` recording rules 的 promtool test（使用既有 fixture target，驗證 inventory scoping、排除未登錄/development series、保留 `exchange`/`executor` labels 且不觸發意外告警）。

### 6. Grafana Dashboard 改動（合併為主、分項為輔）

- **Datasource UID**：固定維持 `prometheus`、`loki`、`-- Mixed --`，不更動。
- **`grafana/dashboards/Trading/trading-strategy-fleet.json`（Trading · 策略總覽）**：
  - 不更動結構（維持 3 個 panel）。`popdex-multi-accounts` 自動以單一合併列顯示：合併 `本輪實現損益`、`最近週期損益`、`完成週期`、`本輪成交額`（來自 `exchange_volume_usd`，無重複計算）、`淨部位` + `單位`（`BTC`）、程序／綁定／風控／探針狀態。
- **`grafana/dashboards/Trading/trading-strategy-detail.json`（Trading · 策略詳情）**：
  - **合併主面板（Rows 1–4，維持原位與既有 11 個 panel 標題）**：
    - `目前餘額`（Panel 14）、`本輪實現損益`（Panel 4）、`最近完成週期`（Panel 11）、`已完成週期`（Panel 5）、`監控摘要`（Panel 1）、`本輪實現損益 · 週期走勢`（Panel 7）、`目前持倉 · 多空方向`（Panel 8，顯示 `popdex · 多/空/空倉 · BTC` 與 `淨部位 · BTC`）、`損益組成`（Panel 9）、`本輪成交額 · 依交易所`（Panel 10，顯示 `popdex · 成交額`）全部呈現雙帳號合併總計。
    - 微調 Panel 14（`目前餘額`）description，說明多帳號與雙交易所已合併加總，各帳號分項見下方明細表。
  - **新增次要分項面板（Row 5，`y=28, h=6, w=24`, `id: 15`, `type: "table"`）**：
    - 標題：`各帳號明細 · 多帳號策略`
    - 欄位（以 `joinByField` outer join on `executor` + `organize`，沿用 Fleet 表格模式，不寫死任何交易所或帳號名稱）：
      1. `帳號`（`executor`）
      2. `交易所`（`exchange`）
      3. `目前餘額`（`trading_strategy_current_executor_equity_usdt`，`suffix: USDT`，2 位小數）
      4. `歸屬實現損益`（`trading_strategy_current_executor_real_pnl_usdt`，`suffix: USDT`，4 位小數，紅/灰/綠門檻，`noValue: "等待完成週期"`）
      5. `完成週期`（`trading_strategy_current_executor_cycles_completed`，整數，`noValue: "0"`）
      6. `本輪成交額`（`trading_strategy_current_run_executor_volume_usd`，`currencyUSD`，2 位小數）
    - 說明文字註明：僅同交易所多帳號策略顯示；歸屬實現損益依 `cycle_executor` 加總已完成週期，總損益與總餘額仍以上方合併面板為準；單帳號策略此表無資料屬正常。
  - 將既有兩塊 Logs 面板下移 6 格保持無重疊：`最新策略日誌 · 已去識別`（`y=34, h=8`）、`關鍵執行事件 · 近 6 小時`（`y=42, h=7`）。
- 同步更新 `tests/trading/test-central-config.sh`（面板數 11 → 12 並驗證新面板契約與無字面 exchange/executor）與 `tests/trading/test-dashboard-semantics.sh`（補雙帳號 PromQL 語意測試，驗證合併與分項數值一致性）。

### 7. `popdex-btc` 切換與歷史資料延續建議

**建議方案：在 SkyEye 另建獨立 `strategy="popdex-multi-accounts"`，並以「兩階段停用／退場」處理 `popdex-btc`（不把 `popdex-btc` probe 重指到新 instance）。**

理由：
1. **Runtime contract 硬性約束**：`probe.sh` 強制驗證 `manifest.strategy == TQ_STRATEGY`。新 lane 的 systemd instance 為 `tnauqquant@popdex-multi-accounts`，其 `current.json` 寫出 `strategy: "popdex-multi-accounts"`；若將 `popdex-btc` 的 probe 重指過去，會導致 `MANIFEST_VALID=0`、持續觸發 `TradingRunBindingInvalid` 且完全無法輸出損益與餘額。
2. **資金規模與策略型態不連續**：`popdex-btc` 為單帳號 `sequential`，`popdex-multi-accounts` 為雙帳號 `random`（權益約 2 倍、共用風控上限）。強行併入同一個 `strategy="popdex-btc"` time series 會使歷史權益曲線出現 2 倍跳階、Loki 日誌混雜兩種路由架構，反而不利事後檢視績效與排錯。
3. **共用 `popdex-main` 帳號的切換安全（最重要）**：`popdex-multi-accounts` 沿用 `popdex-btc` 的 `popdex-main` 帳號（`routing-rotation.md` 要求帳號為單一 process 專用，且新 process 啟動時會對所有設定帳號撤單平倉）。**帳號交接必須發生在第一次 canary 之前**，並以兩階段退場在過渡期主動防呆：
   - **Stage 1（首次 canary 前停用 `popdex-btc` → canary 通過後正式啟用新 lane → 觀察穩定 24–72 小時）**：在首次 canary 啟動前，先由 Wan／tnauqquant 側確認 `popdex-btc` 已平倉、已停止且沒有任何 timer 會將它重啟，再由 SkyEye operator 唯讀核對程序與 timer 並以 `setup-linux.sh add` 將 `/etc/skyeye-trading/instances/popdex-btc.env` 改為 `TQ_STRATEGY_DISABLED=1`（暫不 retire）。此時停著的 `popdex-btc` 不會誤報 `TradingProcessDown`，若被意外重啟（如忘關 timer 或誤操作），條件持續 2 分鐘後才會進入 firing 觸發 `TradingUnexpectedProcess`（shadow），因此不能取代帳號交接前的程序與 timer 核對；若 canary 失敗或上線後需緊急退回 `popdex-btc`，交還帳號前同樣必須先由 Wan 確認新 lane 已平倉、已停止且所有重啟排程（含具名 `tnauqquant-daily-restart@popdex-multi-accounts.timer` 及其他啟動來源）已停用，並由 SkyEye 唯讀核對 timer、持倉與 `process_count=0`，才把 `TQ_STRATEGY_DISABLED` 改回並請 Wan 重啟 `tnauqquant@popdex-btc`。
   - **Stage 2（新 lane 穩定運行、確認不再回退）**：依標準 Remove 順序（先中央、後 host）正式退場 `popdex-btc`：
     1. Repo：`scripts/trading-target remove --server trading01 --strategy popdex-btc` → PR & merge
     2. Central：`scripts/central-deploy`
     3. Host：`sudo agents/alloy/trading/setup-linux.sh retire --strategy popdex-btc`
4. **歷史資料延續**：
   - Trading01 各 lane 目前皆無 `pnl-history.sh`（僅 `macmini-m2` 有 `history_capable="true"`），`Trading · 策略詳情` 的損益與週期曲線本來就只呈現 current run，不跨重啟累計。
   - `scripts/trading-target remove` 與 `setup-linux.sh retire` **皆不刪除 Prometheus TSDB 與 Loki 歷史資料**。Stage 1 期間可在 `$strategy` 下拉選單直接回切 `popdex-btc` 對照；Stage 2 退場後，在 retention 期間仍可於 Grafana Explore 查詢 `strategy="popdex-btc"`（指標與日誌），或直接以網址參數 `?var-server_id=trading01&var-strategy=popdex-btc` 搭配舊時間區間檢視。
   - 面板呈現滿足 Wan 需求：在 `Trading · 策略總覽` 與 `Trading · 策略詳情` 裡，`popdex-multi-accounts` 就是單一合併 BTC 策略視圖（顯示合併總餘額、合併損益、合併週期、合併成交額、合併 BTC 部位，下方附雙帳號分項），退場 `popdex-btc` 後總覽表中只留這條 BTC PopDEX lane。

### 8. Host Rollout、Central Deploy 與 Rollback 程序

完整可複製貼上的 operator 程序將寫入新文件 `docs/trading01-popdex-multi-accounts-onboarding.md`（比照 `docs/trading01-popdex-02-onboarding.md`），並在 `agents/alloy/trading/README.md` 補上索引與雙帳號 `TQ_EXECUTOR_MAP` 說明。

**關鍵限制**：
- 不得碰任何 `tnauqquant@*` service/timer 或讀取憑證檔（`TNAUQ_ENV_FILE`）。
- 避開 UTC 18:15–19:30（18:30Z Trading01 每日重啟、19:00Z monitoring-prod 備份）。
- **因為本次修改了共用 `probe.sh`**，Trading01 更新共用 probe 時必須依 `agents/alloy/trading/README.md`（「Probe CPU limits and shared probe rollout」）先停止並停用全部 `skyeye-trading-probe@*` service/timer，否則 `setup-linux.sh add` 會因 `shared probe artifacts changed` 拒絕。
- **順序固定為先 host、後中央**；Alloy 只允許 `reload`，出現 `--restart-alloy` 一律 STOP。

**Rollout 摘要步驟（S2，由 operator 依通知執行）**：
1. **Step 0 Staging**：將含本次變更的 master commit（`MERGE`）stage 至 Trading01，確認 `deployment-linux-popdex-multi-accounts.env.example` 存在。
2. **Step 1 唯讀前置檢查與基準**：
   - Trading01：檢查 UTC 時窗、`alloy --version` 在清單內、`CanReload=yes`、`CONFIG_FILE="/etc/alloy"`；記錄所有既有 `skyeye-trading-probe@*.timer` 狀態並備份 `/etc/skyeye-trading/instances/*.env`；確認 `tnauqquant@popdex-multi-accounts` 為 inactive/disabled；唯讀查 `manager.env` 的 `TNAUQ_EXPECTED_BIN`、config YAML 的 `instance_id:` 與 `routing.accounts[].name`（確認為 `popdex-main`、`popdex-rot2`）、填好 `$WORK/popdex-multi-accounts.env`（維持 `TQ_STRATEGY_DISABLED=1`）並執行 `--render-only` 驗證。
   - monitoring-prod：記錄 `old-head`、`pre-targets.json`、`probe-ages.pre.json`、`t01-alerts.pre.json`。
3. **Step 2 Trading01 更新共用 `probe.sh` 並安裝 `popdex-multi-accounts`**：
   - 停用並停止所有既有 `skyeye-trading-probe@*.timer` 與 `.service`，確認無一殘留 active/enabled。
   - 依序對既有 lane 重跑 `setup-linux.sh add --env-file "$WORK/$s.env"`（原 `enabled active` 者加 `--enable-probe`；首次 `add` 會替換共用 `probe.sh` 並 reload Alloy）；任一筆 `add` 失敗或出現 `Alloy action: restart` 立即中止並進入 Host Rollback。
   - 還原並比對既有 timer 狀態（`diff timers.before timers.after` 為空且明確印出 `TIMERS-RESTORED`）；失敗即中止並進入 Host Rollback。
   - 只有在明確確認 `TIMERS-RESTORED` 之後，才執行 `setup-linux.sh add --env-file "$WORK/popdex-multi-accounts.env"` 安裝新 lane（自動啟用 `skyeye-trading-probe@popdex-multi-accounts.timer` 並跑一次 probe，Alloy 只 reload）；等 30 秒確認所有 `.prom` 更新、`tnauqquant-popdex-multi-accounts.prom` 有 `run_expected 0`、`process_count 0`，且既有單帳號 lane 的 `.prom` 未出現任何 `*_executor_*` series。
4. **Step 3 monitoring-prod 唯讀驗證 remote-write**：確認既有 lane 與 `popdex-multi-accounts` 全部 `age < 60s`。
5. **Step 4 monitoring-prod 中央部署**：`scripts/central-deploy --dry-run --expect "$MERGE"` 通過後執行 `scripts/central-deploy --expect "$MERGE"`，確認 `trading_target_info`、4 條新 recording rules 與 Grafana `trading-strategy-detail` 載入成功，且 `TradingTelemetryMissing` 為空。
6. **Step 5 帳號交接前置（`popdex-btc` 停用）→ Wan 手動 Canary Cycle → 終態與指標唯讀核對**：
   - **5a（首次 canary 之前必做）**：Wan／tnauqquant 側將 `popdex-btc` 平倉、停止並 disable `tnauqquant@popdex-btc` 與所有可能重啟它的 timer 後，SkyEye operator 唯讀核對程序與 timer 狀態，並將 `popdex-btc.env` 設為 `TQ_STRATEGY_DISABLED=1` 跑 `setup-linux.sh add`（Stage 1 保護前置）。
   - **5b**：確認 5a 通過後，每次請 Wan 執行 canary 前先記錄舊 `run_id` 與視窗起始時間，再由 Wan／tnauqquant 側手動執行 canary cycle（`max_cycles=1` 或 2 輪確認雙帳號輪替）。
   - **5c**：唯讀核對新 `run_id` 與啟動時間落於本次視窗內且 manifest、`current.done.json`、raw log 與 probe `current_run_info` 全屬本次執行、成功終態（`reason == "max_cycles_complete"`、已平倉、`process_count=0`、`risk_stopped=0`、五項 binding 全 `1`、無未解決風控／錯誤告警）、從 bound log 依週期去重並按 `cycle_executor` 加總損益與計數（含零週期帳號）逐帳號對照 `.prom`、合併指標（含交易所持倉 `exchange`/`base_asset` 與策略淨持倉 `base_asset`）、Loki 與 Grafana 面板。任一失敗即停止並交回 Wan。
7. **Step 6 正式切換（Stage 1 啟用與簽收）**：
   - SkyEye operator 將 `popdex-multi-accounts.env` 改為 `TQ_STRATEGY_DISABLED=0` 並執行 `setup-linux.sh add`。
   - Wan／tnauqquant 側啟用並啟動 `tnauqquant@popdex-multi-accounts` 後通知 SkyEye operator。
   - **Stage 1 簽收唯讀核對**：確認新 `run_id` 不同於 `$CANARY_RUN_ID`、新 lane `process_count=1`、`run_expected=1`、五項 binding 全 `1`、`risk_stopped=0`、無殘留 done marker，且舊 lane `popdex-btc` 的 `process_count=0`、`run_expected=0`，全部符合才簽收 Stage 1。
8. **Stage 2 退場 `popdex-btc`（S3，穩定觀察後另案執行）**：`scripts/trading-target remove --server trading01 --strategy popdex-btc` → PR/merge → `scripts/central-deploy` → Trading01 `sudo setup-linux.sh retire --strategy popdex-btc`。

**Rollback**：
- **Host 共用 probe 更新失敗／異常**：停用並停止所有 `skyeye-trading-probe@*` → 用前版 `origin/master` checkout 對既有 lane 重跑 `setup-linux.sh add`（或依 rollback record 還原 `probe.sh`）→ `setup-linux.sh retire --strategy popdex-multi-accounts` → 依 `timers.before` 還原所有 timer，重讀 timer 狀態為 `timers.rollback` 並以 `diff timers.before timers.rollback` 確認退出碼為 `0`。
- **Central 部署異常（依 `docs/operations.md` 標準 revert PR + `central-deploy`，不沿用舊 rollout R5、不對 merge commit 執行 `git revert`、不手動改寫現場檔案）**：
  - Manager 開一個只撤回 WAN-928 變更的 revert PR（用 `scripts/trading-target remove --server trading01 --strategy popdex-multi-accounts` 移除新 target，並針對性還原 `prometheus/rules/trading.yml`／`trading.test.yml` 與 `grafana/dashboards/Trading/trading-strategy-detail.json`，同一個 revert PR 一併撤回 `tests/trading/test-central-config.sh` 與 `tests/trading/test-dashboard-semantics.sh` 裡依賴「各帳號明細 · 多帳號策略」面板或四條 executor rules 的 WAN-928 斷言，其他測試與 `popdex-btc` 及同批其他變更保留），通過 `scripts/verify-all` 後 merge。
  - monitoring-prod 跑 `scripts/central-deploy --dry-run --expect "$REVERT_SHA"` 與 `scripts/central-deploy --expect "$REVERT_SHA"`；驗收看 `central-deploy` 本身檢查加上三項：`trading01` 的 `popdex-btc` target 仍在（且 `popdex-multi-accounts` 已移除）、Prometheus `trading-strategy-recording` rule health 正常、Grafana `trading-strategy-detail` dashboard UID 讀得到；選用的 Trading01 `retire --strategy popdex-multi-accounts` 一律排在帳號交還簽收之後。
- **Canary 失敗或切換後需回退至 `popdex-btc`（Stage 1 期間）**：帳號交還前必須滿足程序、排程、平倉三項前置條件：先由 Wan／tnauqquant 側確認新 lane 已平倉（若本次 run 從未產生 settled 部位，改提供兩支帳號當下持倉確認，例如交易所 UI 或 tnauqquant 唯讀 rehearsal 輸出）、已停止且所有重啟排程皆已停用（包含具名 `tnauqquant-daily-restart@popdex-multi-accounts.timer` 與其他啟動來源）→ SkyEye operator 唯讀核對具名 daily-restart timer 與兩份非空 timer 清單、程序（`process_count=0`）及平倉證據（缺任何一項證據即停止交接）→ 將 `popdex-multi-accounts.env` 改回 `TQ_STRATEGY_DISABLED=1` 並 `add` → 將 `popdex-btc.env` 改回 `TQ_STRATEGY_DISABLED=0` 並 `add` → Wan／tnauqquant 側重新啟用並啟動 `tnauqquant@popdex-btc`。全程不丟失歷史資料。

## 步驟

- [x] S1 `POPDEX-MULTI-20261126` WAN-928 — 實作雙帳號 `TQ_EXECUTOR_MAP` probe、env example、recording rules、Grafana 分項面板、測試與 onboarding 文件
  files: agents/alloy/trading/probe.sh, agents/alloy/trading/linux-common.sh, agents/alloy/trading/setup-linux.sh, agents/alloy/trading/deployment-linux-popdex-multi-accounts.env.example, agents/alloy/trading/README.md, prometheus/rules/trading.yml, prometheus/rules/trading-targets.yml, prometheus/rules/tests/trading.test.yml, grafana/dashboards/Trading/trading-strategy-detail.json, docs/trading01-popdex-multi-accounts-onboarding.md, tests/trading/test-probe.sh, tests/trading/test-probe-equivalence.sh, tests/trading/test-linux-setup.sh, tests/trading/test-central-config.sh, tests/trading/test-dashboard-semantics.sh, docs/plans/popdex-multi-accounts.md
  狀態: 已完成實作與非 Docker 驗證；Docker／promtool 項目 PENDING（待本機 Docker 恢復後補跑）

- [ ] S2 `POPDEX-MULTI-DEPLOY` WAN-928 — 依 `docs/trading01-popdex-multi-accounts-onboarding.md` 執行 Trading01 host rollout、monitoring-prod `central-deploy`、canary 核對與 Stage 1 切換
  after: S1 (merged)
  kind: deploy（等 tnauqquant manager 通知切換時間後另派 operator）
  狀態: 未開始

- [x] S3 `POPDEX-BTC-RETIRE` WAN-928 — 新 lane 穩定觀察後，依先中央後 host 順序移除 `popdex-btc` inventory 與 retire host probe
  after: S2 (accepted)
  kind: deploy（確認不回退後由 operator 執行）
  狀態: repo 步驟完成，待 central-deploy 與 host retire

## 已定的決策

- 2026-11-26 Wan / manager（dispatch）：`popdex-multi-accounts` 採 `routing.mode: random` 輪替 `popdex-main`（沿用 `popdex-btc`）與 `popdex-rot2`（新帳號），兩支不對沖；面板上合併兩支帳號的 equity 與績效於同一 BTC 視圖，預設「合併為主、各帳號分項為輔」；所有告警維持 `shadow`。
- 2026-11-26 worker（設計）：`TQ_EXECUTOR_MAP` 沿用逗號分隔 `<executor>=<exchange>`（`popdex-main=popdex,popdex-rot2=popdex`），不新增語法或 env 變數；4 個 per-executor 分項 metrics 僅在 `HAS_SHARED_EXCHANGE == 1` 時輸出，嚴格以 `TQ_EXECUTOR_MAP` allowlist 過濾非 allowlist executor，確保既有單帳號與雙交易所 lane 的 `.prom` 輸出 byte-for-byte 不變。
- 2026-11-26 manager（PLAN_APPROVED，D1）：本 PR 一併執行 `scripts/trading-target add --server trading01 --strategy popdex-multi-accounts --quote USDT`；merge 後至 Trading01 probe 上線前不得執行 `central-deploy`，已寫入 `docs/trading01-popdex-multi-accounts-onboarding.md`。
- 2026-11-26 manager（PLAN_APPROVED，D2）：核准於 `Trading · 策略詳情` Row 5 新增 `各帳號明細 · 多帳號策略` 表格（合併為主、分項為輔）。
- 2026-11-26 manager（PLAN_APPROVED，D3）：核准另建 `strategy="popdex-multi-accounts"` 並以兩階段退場 `popdex-btc`；停用 `tnauqquant@popdex-btc` 與啟動新 lane 一律由 Wan／tnauqquant 側執行，SkyEye 文件不含任何啟停 `tnauqquant@*` 指令。
- 2026-11-26 manager（PLAN_APPROVED，D4）：已向 tnauqquant 側確認 config 為 `config/popdex_multi_accounts_config.yaml`、`instance_id: "popdex-multi-accounts"`、executors 為 `popdex-main`／`popdex-rot2`、lane env 為 `/home/ubuntu/tnauqquant/.env.popdex-multi-accounts`（禁止讀取）、`TQ_EXECUTABLE` 預填 `/home/ubuntu/tnauqquant/bin/popdex-multi-accounts` 並由 operator 於上線 Step 1 核對 `manager.env`。
- 2026-11-26（WAN-946）：D4 記錄的預填路徑已修正為 `/home/ubuntu/tnauqquant/bin/popdex-multi-accounts/quant`，binary 驗收移至首次啟動後的 Step 5c。

## 待決問題

（無；D1–D4 已於 2026-11-26 `PLAN_APPROVED` 拍板。）

## 驗證

```bash
# 靜態與語法檢查
bash -n agents/alloy/trading/probe.sh agents/alloy/trading/setup-linux.sh agents/alloy/trading/linux-common.sh
find grafana/dashboards -name '*.json' -exec jq empty {} +
scripts/trading-target check

# 受影響的 suite，最後一個 commit 上用同一個 lock 一起跑
/Users/tinghsu/.claude/skills/herdr-manager/scripts/hm.py lock -- sh -c '
  tests/trading/test-probe.sh &&
  tests/trading/test-probe-safety.sh &&
  tests/trading/test-probe-equivalence.sh &&
  tests/trading/test-linux-setup.sh &&
  tests/trading/test-linux-env-examples.sh &&
  tests/trading/test-trading-target.sh &&
  tests/trading/test-central-config.sh &&
  tests/trading/test-dashboard-semantics.sh &&
  docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint sh \
    prom/prometheus:v2.54.1 -c "promtool test rules /etc/prometheus/rules/tests/*.yml"
'
```

完整 `scripts/verify-all` 由 publish 階段統一執行。

## 接續

- S2 上線使用 WAN-946 修正後的 onboarding 文件與 env example。Step 1 核對路徑，Step 5c 驗證 binary 後才進入 Step 6。
- 現況：S1 已於 `feat/WAN-928-popdex-multi` 實作並完成 Review R1／R2 全部接受項修正與 commit（含 probe、setup-linux、env example、target inventory、recording rules、Grafana 分項面板、回歸測試與 `docs/trading01-popdex-multi-accounts-onboarding.md`）。非 Docker 套件（`test-probe.sh`、`test-probe-safety.sh`、`test-probe-equivalence.sh` 69/69、`test-linux-setup.sh`、`test-linux-env-examples.sh`、`test-trading-target.sh` 非 promtool 段、`test-central-config.sh` 非 promtool 段、`bash -n`、`shellcheck -x`、`jq empty`、`scripts/trading-target check`）全數通過；Docker／promtool 檢查（`promtool test rules`、`test-central-config.sh` promtool 段、`test-dashboard-semantics.sh`、`test-trading-target.sh` derived promtool 子檢查）因本機無 Docker 標記為 PENDING。
- S3 repo 步驟完成，待 review 與 merge。之後由 operator 先執行 `central-deploy`，再到 Trading01 執行 `popdex-btc` 的 host retire。
- 即時狀態：有 manager 時看 `hm.py goals popdex-multi-accounts`；沒有 manager 時看各步驟的勾選與 `狀態:` 行，以及標頭的 Linear 卡 WAN-928。
