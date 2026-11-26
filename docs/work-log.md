# 工作記錄

<!--
新記錄追加在本註解下方（最新的在最前面）。每筆格式：

## YYYY-MM-DD HH:MM — 簡短標題

**改動摘要：** 一句話描述做了什麼

**修改的檔案：**
- `path/to/file` — 改了什麼

**原因/備註：** （選填，補充說明）

---
-->

## 2026-11-26 08:30 — scripts/trading-account：一個指令增減 Trading 策略帳號（WAN-954）

**改動摘要：** 已安裝的 Linux Trading 策略要新增或移除帳號（executor）時，改用 `scripts/trading-account add|remove|list`，1–2 分鐘完成，不需要 repo PR、review 或 `central-deploy`。做法是在主機鎖內原子替換 instance env 的 `TQ_EXECUTOR_MAP` 一行（probe unit 每次執行都重讀 `EnvironmentFile`），不 reload Alloy、不動任何共用檔，並用 timer 觸發的新快照驗證，失敗或中斷自動還原。

**修改的檔案：**
- `agents/alloy/trading/account-linux.sh` — 主機端 add／remove／list：持有 `/run/skyeye-alloy.lock`（與 setup／retire 同一把）、UTC 18:10–19:30 拒絕（預檢、寫入前與 rename 前各一次）、嚴格的 systemd 狀態查詢（failed timer／service 拒絕）、只允許改 `TQ_EXECUTOR_MAP` 一行（位元組比對、拒絕縮排／重複／export 等歧義賦值）、備份到 `/etc/skyeye-trading/account-backup/`、丟掉寫入後第一份快照再以第二份驗證 executor、訊號安全的冪等還原、`.prom` 讀取拒絕 symlink 且上限 4 MiB。
- `agents/alloy/trading/setup-linux.sh` — 新增 `account` 子命令轉給 `account-linux.sh`。
- `scripts/trading-account` — 本機入口：以一般 SSH 使用者上傳 3 個 helper 到 `/tmp` 私有目錄後 `sudo` 執行（有 TTY 時 `-t`），結束清理；`--local` 在主機上直接執行；`--dry-run`；SSH 中斷時回報結果未知並給出 `list` 確認指令。
- `agents/alloy/trading/README.md` — 新增「Add or remove an account (executor)」：指令、只適用 Linux lane、與 tnauqquant 的順序（新增：先 SkyEye 後 tnauqquant；移除：先 tnauqquant 後 SkyEye）、何時仍要走 `trading-target` 或共用 probe 更新流程。
- `AGENTS.md` — trading target 規則補上帳號增減用 `scripts/trading-account`。
- `tests/trading/test-trading-account.sh` — 拒絕條件、成功路徑、timer 狀態保留、在途 probe、時段跨越、訊號中斷、還原失敗、wrapper 與 SSH stub 等案例，約 56 秒。

**原因/備註：** 使用者要求加速帳號增減（11-26）。三輪 code review（R1 1B/10M/3m、R2 7M/2m、R3 4M）已處理；R2 C17（同 UID 程序改暫存腳本）判為威脅模型外，README 註明前提。

## 2026-11-26 05:10 — popdex-multi-accounts 雙帳號 probe 與合併面板（WAN-928）

**改動摘要：** 支援 Trading01 新 lane `popdex-multi-accounts`：在兩支 PopDEX 帳號（`popdex-main`、`popdex-rot2`）之間 random routing，將取代 `popdex-btc`。probe 支援同交易所多帳號的 `TQ_EXECUTOR_MAP`；總覽顯示合併 equity／績效，策略詳情新增各帳號明細；附 plan 與上線 runbook。

**修改的檔案：**
- `agents/alloy/trading/probe.sh` — 支援 `popdex-main=popdex,popdex-rot2=popdex` 這種寫法。只有 `HAS_SHARED_EXCHANGE=1` 時才輸出 4 個 per-executor metric（equity、real PnL、cycles、volume），label 只接受 map 內列出的帳號名。多帳號的部位只採用 settled 且 confirmed 的 coordinator_book。單帳號與雙交易所 lane 的輸出和原本逐字相同。
- `agents/alloy/trading/setup-linux.sh`、`linux-common.sh` — 驗證 `TQ_EXECUTOR_MAP` 格式。
- `agents/alloy/trading/deployment-linux-popdex-multi-accounts.env.example` — 新 lane 的 env 範例，預設 `TQ_STRATEGY_DISABLED=1`。
- `prometheus/rules/trading-targets.yml` — 用 `scripts/trading-target add` 加入 `trading01/popdex-multi-accounts`。
- `prometheus/rules/trading.yml`、`tests/trading.test.yml` — 新增 4 條 `trading_strategy_*_executor_*` recording rules。告警仍全部是 shadow（14 shadow、0 page）。
- `grafana/dashboards/Trading/trading-strategy-detail.json` — 新增 Row 5「各帳號明細 · 多帳號策略」表格，datasource UID 不變。
- `docs/plans/popdex-multi-accounts.md`、`docs/trading01-popdex-multi-accounts-onboarding.md`、`agents/alloy/trading/README.md` — plan、上線／切換／rollback 程序，以及雙帳號 map 的說明。
- `tests/trading/` — probe、等價（69 項逐字比對）、Linux setup、central config、dashboard 語意測試。

**原因/備註：**
- Wan：「合併這兩隻的 equity 跟績效，並統計在同一個面板上……只是變成有兩隻帳號。」（經 tnauqquant manager 轉述）
- 另開 strategy，不沿用 `popdex-btc` 的 series：manifest.strategy 必須等於 TQ_STRATEGY，而且混入舊 series 會讓 equity 失真。`popdex-btc` 分兩階段退場，歷史保留在 Prometheus/Loki。
- 啟停 `tnauqquant@*` 一律由 Wan／tnauqquant 執行，runbook 不含這類指令。
- merge 後、Trading01 probe 上線前，不跑 `central-deploy`。
- 這台 Mac 的 Docker 依 D47 重建 colima（2 CPU / 4G），只在跑驗證時開著。

---

## 2026-11-23 18:00 — 移除 TradingPnlTelemetryStale 告警；PROD02 套用一般 log scrub 與新版 setup.sh

**改動摘要：** 依 Wan 決定移除 shadow 告警 `TradingPnlTelemetryStale`（WAN-716）；另記錄 11-23 PROD02 主機 rollout 與 4 筆舊任務的上線查核。

**修改的檔案：**
- `prometheus/rules/trading.yml` — 移除 `TradingPnlTelemetryStale`；P&L recording rules 與其他 Trading 告警不變。
- `prometheus/rules/tests/trading.test.yml`、`prometheus/rules/tests/trading-clock-skew.test.yml` — 拿掉這條告警的斷言與專屬案例。
- `docs/trading01-popdex-02-onboarding.md`、`docs/trading-new-server-handoff.md`、`docs/trading-dashboard-health-readability-development-plan.md` — 註明 11-23 移除與原因。

**原因/備註：**
- P&L sample 只在 cycle 完成時更新。市場波動大、spread 寬時策略本來就進不了場，cycle 常超過 5 分鐘，這條告警在 trading01 三個策略與 macmini-m2 上反覆 flapping；程序本身都在跑。Wan：「這是很正常的，可以把它關閉掉。」
- 主機 rollout（無 repo 改動）：11-23 05:39Z 在 PROD02 以 master `b77a612` 的 `agents/alloy/setup.sh`（`PRODUCT=services` + `APP_METRICS_PRODUCT_MAP`）重跑 Alloy，套上 dcf1069／51e3ff2 的一般 log scrub 與 71bd462 的原子安裝。8090/8091/8092、2112 與主機 series 全數保留，C-4（重跑砍 8091/8092）已由 WAN-598 解決；原設定留在 `/etc/alloy/config.alloy.previous`。一般 pipeline 已知殘留 A30／A31／T19 與 msg 損失 A35，Wan 決定不追。
- 唯讀查核：PR #59／#61 的 Trading probe（05a6754）、probe 時間修正（ab2b1ad、851e995、c85ea03）與 Trading scrub 早已在 Trading01 與 Mac mini 上線。

---

## 2026-11-22 18:50 — 同步與精簡專案 Agent 文件

**改動摘要：** 移除 `AGENTS.md` 樣板 HTML 註解並補齊 `SkyEyeWatchdog` 與核心文件索引；將 `docs/project-brief.md` 與 `README.md` 同步至 PR #81（WAN-598）多產品監控現況。

**修改的檔案：**
- `AGENTS.md`：移除開頭樣板 HTML 註解、補註外部死人開關 `SkyEyeWatchdog`（`deadman-external`），並於索引補入 `docs/operations.md` 與 `runbooks/README.md`。
- `docs/project-brief.md`：更新至 PR #81（`a4ebd9f`，WAN-598）現況（Grafana 12.4.15、Cloudflare Access JWT、Alertmanager `2750`/`0640` secrets、Windows Alloy、`SkyEyeWatchdog`、`agents/alloy/setup.sh` 共用主機 per-target product 支援）。
- `README.md`：更新多產品架構圖、7 個 Compose services、9 個 Grafana dashboard 目錄、`loki/rules/fake/`、`agents/alloy/trading/`、`scripts/verify-all`、`runbooks/README.md`（19 份 runbooks）與 `docs/code-patterns/go.md`，並移除 Phase 1 的 `+ Gmail SMTP`。

---

## 2026-11-22 16:00 — 主機 dashboard 改用 server_id；setup.sh 支援共用主機的 per-target product

**改動摘要：** Prod02 的主機層 external_labels 將從 `product="ppclub"` 改成 `product="services"`（`server_id="PROD02"` 不變）。主機 dashboard 改以 `server_id` 選主機，新舊標籤都看得到 PROD02；總覽的產品數與離線產品數不把 services 算成產品。`agents/alloy/setup.sh` 新增 `APP_METRICS_PRODUCT_MAP` 與 `APP_METRICS_BEARER_TOKEN_<PRODUCT>`，讓共用主機的每個 app target 帶自己的 product 與 bearer；單一產品主機的輸出與之前逐位元組相同。新增 `--render-only PATH` 預覽，只寫已存在目錄裡的新檔、不覆蓋任何既有檔案。尚未在 Prod02 套用。

**修改的檔案：**
- `grafana/dashboards/Hosts/hosts-node-exporter.json`：`product` 變數換成 `server_id`，351 個 metric selector 都加上 `server_id="$server_id"`。
- `grafana/dashboards/Overview/overview-all.json`：資源面板與「各主機 CPU %」改用 `server_id`；產品數、離線產品數排除 services；Traffic Light 以 `server_id` 接回各產品。
- `prometheus/rules/tests/stack-health.test.yml`：PROD02 主機 series 改用 `product="services"`。
- `tests/grafana/test-host-dashboard-isolation.sh`：新增同名 instance 主機隔離與 services 排除的測試。
- `agents/alloy/setup.sh`：per-target product 對應、per-product bearer、地址與 token 驗證、跨產品重複地址拒絕、`--render-only`。
- `agents/alloy/README.md`、`docs/onboarding-new-product.md`、`docs/grafana-conventions.md`：共用主機用法、Prod02 範例（隱藏輸入 bearer、mktemp 預覽）、以 server_id 驗證。
- `tests/alloy/test-setup-atomic.sh`、`tests/alloy/test-alloy-versions.sh`：共用主機 render、冪等重跑、render-only 防護、乾淨環境。

**原因/備註：** Linear WAN-598（ZenIncome D68/D69 轉來）。manager 決定 D42（以 server_id 選主機）、D43（services 不算產品）。review 未採納：Traffic Light 在共用主機沒有任何 app scrape 時會空掉；IPv6 不同寫法的重複地址、無效 IPv6 拼字、尾端句點 FQDN、symlink 競態，都屬罕見邊界。

---

## 2026-11-19 15:02 — enyoung 錯誤率 panel 的 LogQL 400 修正；alertmanager secrets 權限改為 0640 group 65534

**改動摘要：** enyoung 日誌總覽的「5xx／4xx 錯誤率 (30m)」用了 LogQL 不支援的 `clamp_min`，Loki 回 400。改成 `(NUM or vector(0)) / (DEN > 0)`，分母只算 access log 行；有流量沒錯誤顯示 0，沒流量顯示 No data。Alertmanager secrets 的權限說明從 0644／0755 改成目錄 2750（setgid）、檔案 0640、group 65534，container 的 nobody 仍讀得到，其他帳號讀不到。主機尚未套用。

**修改的檔案：**
- `grafana/dashboards/enyoung/enyoung-logs-overview.json`：panel 11、12 的查詢，拿掉 `noValue: "0"`。
- `alertmanager/secrets/README.md`、`docs/operations.md`：新權限模型、一次性初始化（sudo chgrp 再 chmod 2750、轉換既有 secret）與 container 內 `test -r` 驗證。
- `runbooks/skyeye-watchdog.md`、`runbooks/trading-alert-promotion.md`、`README.md`：改為 `chmod 640`，暫存檔用 `mktemp`。

**原因/備註：** Linear WAN-491；WS-ACCESS P2-17。直接 0600 會讓 nobody 讀不到 Telegram token。

## 2026-11-19 12:59 — Trading probe：改為批次取 mtime 與 ACL，去掉逐檔外部程式呼叫

**改動摘要：** `probe.sh` 原本對 glob 比對到的每個 log 各跑多次 `stat`，`ensure-log-access.sh` 對每個檔案各跑一次 `getfacl` 和兩次 `grep`。現在改成用 `xargs -0` 一次 `stat` 全部檔案、一次 `getfacl` 加一個 awk 檢查全部檔案，只對缺權限的檔案跑 `setfacl`；`date` 種類只在啟動時判斷一次，有 `sha256sum` 就優先用它。輸出的 metrics 與舊版逐 byte 相同。以 73 個 log 的 robinhood 形狀測試資料量，每次執行外部程式呼叫從 565 降到 41，CPU 從約 1.44 秒降到 0.28 秒。尚未部署到 Trading01。

**修改的檔案：**
- `agents/alloy/trading/probe.sh`：批次 mtime（只受實際參數長度限制分批）；manifest 綁定的 log 在舊版相同的時間點重新取 mtime；log 比對用檔名加所在目錄；接受負數 epoch；config checksum 改由 stdin 讀入。
- `agents/alloy/trading/ensure-log-access.sh`：批次 `getfacl`／`setfacl`，`find` 失敗時一定回報錯誤。
- `tests/trading/test-probe-equivalence.sh`：新增 80 個歷史 log、執行中途建立／寫入／搬移 log、hard link、symlink、超過 ARG_MAX、5001 個路徑等情境，共 66 項逐 byte 等價檢查。
- `tests/trading/test-log-access.sh`：假 `getfacl`／`setfacl` 支援批次與呼叫計數，並只接受 `u:alloy:r--`。

**原因/備註：** Linear WAN-460 第二輪。不另存狀態、不改 unit 或 timer。經 Codex review 四輪後收下；剩一項測試在極小 ARG_MAX 主機上可能誤判的 minor，另開建議。

## 2026-11-19 18:38 — Trading probe：log 改為單次預先過濾掃描，並限制 unit 的 CPU

**改動摘要：** `probe.sh` 原本每 15 秒對當天 live-run log 全讀 7–8 次，改成只用一次 `grep -a -n -F` 預先過濾，再由單一 awk 掃描。輸出的 metrics 與舊版逐 byte 相同。合成的 popdex-02 全天 log（54 MiB）每次執行從 4.1 CPU 秒降到 0.28 秒。`skyeye-trading-probe@.service` 加上 `Nice=10`、`CPUWeight=20`、`CPUQuota=20%`。尚未部署到 Trading01。

**修改的檔案：**
- `agents/alloy/trading/probe.sh`：單次掃描；manifest 必須恰好是一個 JSON object；讀檔／解析失敗時保留上一份 `.prom`；排序用 `grep -n` 行號，不經浮點轉換。
- `agents/alloy/trading/skyeye-trading-probe@.service.tmpl`：CPU 優先度與每個 instance 的 quota。
- `tests/fixtures/tnauqquant/probe-baseline-reference.sh`、`tests/trading/test-probe-equivalence.sh`：把改動前的 probe 凍結成基準，44 項逐 byte 等價檢查（含錯誤保留、大行號、多 object manifest、標籤含分段標記）。
- `tests/trading/test-linux-setup.sh`：檢查 unit 的 Nice、CPUWeight、CPUQuota。
- `agents/alloy/trading/README.md`：CPU 限制、效能數字，以及共用 probe 的 rollout／rollback 流程。

**原因/備註：** Linear WAN-460。11-18 的量測中，4 個 probe 合計約佔單核 36%，把 Trading01（t3.large）的 CPU credit 燒光。本次不做帶狀態的增量讀取（D37），等 log 明顯變大再評估。經 Codex review 三輪後收下。

---

## 2026-11-19 17:15 — Grafana 11.2.0 → 12.4.15：repo 端升級與 upgrade／rollback runbook

**改動摘要：** `docker-compose.yml` 把 Grafana 釘到 `grafana/grafana:12.4.15@sha256:2894082f…`，關閉 plugin preinstall，並 opt in unified storage migration。新增離線 provisioning smoke test 與 `runbooks/grafana-upgrade.md`（包含彩排、升級與從 tar 備份還原的 rollback）。`scripts/central-deploy` 改用 v1beta1 annotations 驗證 migration 後的 dashboard。尚未部署到 monitoring-prod。

**修改的檔案：**
- `docker-compose.yml`：Grafana 12.4.15 digest pin、`GF_PLUGINS_PREINSTALL_DISABLED`、unified storage migration 設定。
- `grafana/provisioning/alerting/.gitkeep`、`grafana/provisioning/plugins/.gitkeep`：補齊 12.x 預期的 provisioning 目錄。
- `scripts/central-deploy`、`tests/trading/test-central-deploy.sh`：12.4 migration 後，dashboard 確認改看 v1beta1 annotations。
- `tests/grafana/test-provisioning.sh`：以 production 相同的唯讀 mount 起 12.4.15，檢查 datasource UID、10 個 dashboard 與 provisioning log。
- `runbooks/grafana-upgrade.md`、`runbooks/README.md`、`runbooks/alertmanager-upgrade.md`：升級／rollback 流程，共用的 shell 檢查函式在 `lib.sh`。
- `docs/project-brief.md`、`docs/operations.md`、`docs/grafana-conventions.md`、`monitoring-plan-v2.md`、`docs/plans/grafana-upgrade.md`：版本與流程更新，plan S1 標記完成。

**原因/備註：** Linear WAN-427（11-04 review L-01：11.2.0 已停止支援）。經 Codex review 三輪與 manager 檢查一輪後收下。部署是 plan S2（`SKYEYE-GRAFANA-UPGRADE-DEPLOY`），需使用者核准；12.x 會遷移 `grafana.db`，只換 image 無法降版，rollback 必須依 runbook 從升級前的 tar 備份還原。

---

## 2026-11-19 16:18 — cloudflared README：補 WAF 規則與目前的 Access token

**改動摘要：** `cloudflared/README.md` 補上 11-19 啟用的 WAF custom rule `skyeye-push-write-only`（push host 只放行寫入用的 POST），並把 push 的 Access policy 與 service token 表更新到現況。只改文件。

**修改的檔案：**
- `cloudflared/README.md`：push app 的三條 Service Auth policy；service token 現況表（只記名稱、用途、狀態）；WAF 規則的位置、expression、驗證與 rollback；強調不可刪除重建 `SkyEye Grafana` Access app。

**原因/備註：** Linear WAN-438。WAF 規則由 Wan 在 Cloudflare 套用，operator 於 07:38Z～08:07Z 驗證各來源持續寫入（WAN-430）。`skyeye-agent-push`（Not Seen Yet）與 `learnerllm-agent` 是之後可清理的候選。

---

## 2026-11-19 16:05 — Trading Linux examples：raw log glob 收緊為契約檔名

**改動摘要：** Linux Trading env example 的 `TQ_RAW_LOG_GLOB` 從寬鬆的 `*<stem>.raw.log` 改成契約檔名，避免 probe 選到名稱相似的其他 lane log；README 新增在既有主機上收緊 glob 的一次性程序。只 merge，Trading01 還沒套用。

**修改的檔案：**
- `agents/alloy/trading/deployment-linux-{robinhood,popdex,ourbit,mainnet}.env.example`：glob 改成契約檔名；`deployment-linux-popdex-02.env.example` 本來就是嚴格 glob，只調整說明。
- `tests/trading/test-linux-env-examples.sh`：檢查 glob 形狀與實際選到的檔案，不再比對註解字首。
- `agents/alloy/trading/README.md`：既有 lane 收緊 glob 的主機程序。兩條 lane 都通過 pre-check（manifest 綁定、24h 掉線、timer）才 add；add 後檢查 probe 時間戳至少相隔 15 秒前進、`log_binding_ok=1`，並在中央確認 Loki 收到 reload 之後的事件；每條 lane 各自回報 RESULT，失敗時後面的 lane 標 NOT_ATTEMPTED。

**原因/備註：** Linear WAN-355，Wan 11-19 要求處理（SKYEYE-POPDEX02 review 發現）。Codex review 三輪，最後 READY_WITH_MINOR；剩下的 C11（單行超過 64 KiB 時 Loki 驗證會誤報 unparseable_time）不修，log 行遠小於此，誤報也只會停下驗證，不會改到主機。Trading01 的 robinhood 與 popdex-btc 由 operator 依 README 另行套用，不碰策略。

---

## 2026-11-19 15:20 — Trading01：移除 lighter-mainnet-btc-canary，popdex-02 executor 改名

**改動摘要：** `lighter-mainnet-btc-canary` 已不再交易，從 Trading01 的監控 inventory 移除；popdex-02 的帳號由 `popdex-main` 改名為 `popdex-02`，SkyEye 的 executor 對應跟著改。只 merge，Trading01 與中央都還沒部署。

**修改的檔案：**
- `prometheus/rules/trading-targets.yml`：用 `scripts/trading-target remove --server trading01 --strategy lighter-mainnet-btc-canary` 移除該 row。
- `agents/alloy/trading/README.md`、`docs/project-brief.md`、`docs/trading-new-server-handoff.md`、`docs/trading01-popdex-rollout.md`：Trading01 剩三條 lane。mainnet env example 仍被 Linux setup 與 rollout 演練引用，保留。
- `agents/alloy/trading/deployment-linux-popdex-02.env.example`：預填 `TQ_EXECUTOR_MAP=popdex-02=popdex`；`popdex-btc` 仍是 `popdex-main`。
- `docs/trading01-popdex-02-onboarding.md`：記錄 executor 改名，更新 config 與 raw log 的核對步驟。

**原因/備註：** Wan 在 SkyEye manager 對話中要求（Linear WAN-419、WAN-422）。executor 不改的話，popdex-02 的 `exchange="popdex"` 成交量會漏計。Prometheus／Loki 的歷史資料不刪。上線由同一個 operator 在 Trading01 先 retire mainnet，再更新其餘 lane 的 probe（popdex-02 env 一併改 `TQ_EXECUTOR_MAP`），最後部署中央一次。

---

## 2026-11-19 14:30 — Trading 持倉：依 lane 標示幣別、平倉後即時顯示空倉

**改動摘要：** popdex-02 交易 ETH，持倉面板卻一律標 BTC；平倉成交後，面板要等下一個 signal 行才顯示空倉（popdex-02 最長 212 秒，lighter-robinhood-btc-canary 約 15 分）。這次把兩個問題一起修好。只 merge，Trading01 與中央都還沒部署。

**修改的檔案：**
- `agents/alloy/trading/probe.sh`：
  - 新增選填 `TQ_BASE_ASSET`（未定義時是 BTC；空字串和非 ASCII 大寫英數都拒絕）。兩個持倉 metric 多帶 `base_asset` label，名稱與 `# HELP` 文字不變，新舊 `.prom` 可以在同一個 collector 共存。
  - 把比最新 coordinator_book 行更新的 `msg=ui_warmup_async_ready reason=gross_flat_verified:*` 行（executor 必須在 map 內）當成空倉觀測。net 與 venue 兩條路徑都採用，所以雙交易所 lane 之後遇到只寫 net Flat 的 book 行，也不會把已平的兩腿還原。`close_position disposition=filled` 可能是部分平倉，不採用（D33）。
- `agents/alloy/trading/setup-linux.sh`、`linux-common.sh`：render 與 add 驗證 `TQ_BASE_ASSET`。env 檔裡必須是 literal 的 `TQ_BASE_ASSET=<值>`，值也要和 systemd 讀到的一致；`export …`、`$VAR` 這類寫法都拒絕。
- `prometheus/rules/trading.yml`：`trading_strategy_current_{,net_}position_btc` 保留 `base_asset`，舊 series 沒有這個 label 時記成 BTC。
- `grafana/dashboards/Trading/trading-strategy-detail.json`、`trading-strategy-fleet.json`：單位依 `base_asset` 逐列顯示，ETH 與 BTC 不共用一個單位，也不加總。
- `agents/alloy/trading/README.md`、`docs/trading01-popdex-02-onboarding.md`、`docs/trading-monitoring-development-plan.md`：寫明共用 probe 更新的 6 個步驟（全部 stop、逐 lane add、恢復 timer）與上線順序：先更新 host，確認 `base_asset="ETH"` 出現後才部署中央。中央先上的話，這段期間的歷史資料會錯標成 BTC。
- `deployment-linux-popdex-02.env.example`：`TQ_BASE_ASSET=ETH`。
- `tests/trading/`、`prometheus/rules/tests/trading.test.yml`、`tests/fixtures/tnauqquant/position-flat.raw.log`：補上 HELP 固定、asset 驗證、systemd 讀法、recording rule、dashboard 單位，以及平倉重播（單／雙交易所，時間在未來、缺少或無法解析）等測試。

**原因/備註：** 請求來源是 Wan 在 SkyEye manager 對話中的要求（Linear WAN-361、WAN-400）。平倉原因由 Trading01 唯讀蒐證查明：producer 成交後寫的那幾行沒有 position 欄位。producer 端的根本修正另外請 tnauqquant 處理（WAN-401，tnauqquant#374）；它部署之後，可以評估拿掉 gross_flat 的特殊處理。上線時也要把 popdex-02 host env 的 `TQ_STRATEGY_DISABLED` 改回 0，Wan 已同意。Code review 兩個任務各兩輪，第二輪 reviewer 改用 agy（WAN-410）。

---

## 2026-11-19 02:27 — Trading01 新 lane `popdex-02`（PopDEX ETH）納入監控

**改動摘要：** 新增 `trading01`／`popdex-02` 的 shadow inventory row、不含 credential 的 instance env 範例與 operator 上線程序。這次只 merge；主機端 `setup-linux.sh add` 與 `central-deploy` 還沒執行，lane 本身在 Wan 手動測一個 cycle 之前維持停用。

**修改的檔案：**
- `prometheus/rules/trading-targets.yml`：`scripts/trading-target add --server trading01 --strategy popdex-02` 產生的一筆 row，`notification_mode: shadow`。
- `agents/alloy/trading/deployment-linux-popdex-02.env.example`：新增。`TQ_STRATEGY_DISABLED=1`；`TQ_EXECUTABLE` 與 `TQ_EXECUTOR_MAP` 留空，由 operator 在 Trading01 唯讀核對後填入，原樣無法 render 或 `add`；`TQ_RAW_LOG_GLOB` 限定 `YYYYMMDD_HHMMSS_popdex_02_config.raw.log`，不會選到名稱相似的檔案。
- `docs/trading01-popdex-02-onboarding.md`：新增 operator 程序。Step 1 唯讀前置檢查（lane 的 service 與所有可能啟動它的 timer 都停用、Alloy 版本、共用 probe 檔案與 staging 相同、填入兩個空值），以及安裝前的中央基準；Step 2 host `add`（只 reload）；Step 3 中央確認 remote-write；Step 4 分成 dry run 與正式 `central-deploy`，並處理已套用的情況；Step 5 在 Wan 手動測試 cycle 後核對 binding、raw log、Loki、executor 成交額與數量單位。附 disabled 期間與改回 `0` 之後預期的 shadow 告警表。
- `tests/trading/test-linux-env-examples.sh`：新增 suite。每份 `deployment-linux-*.env.example` 都在 test root 內 render 並與其他 lane 一起 `alloy validate`，寫入前先驗證名稱與路徑；註明 `CONTRACT-NAMED LOGS ONLY` 的範例必須只選到自己的 log。
- `tests/trading/test-central-config.sh`：收集 exchange 名稱時略過空的 `TQ_EXECUTOR_MAP`。
- `agents/alloy/trading/README.md`：檔案表加上 `popdex-02`，Add/remove 一節指向新程序。

**原因/備註：** 請求來源是 Linear WAN-346（tnauqquant manager 轉述 Wan：「Sky Eye 新增新的監控」）。Code review 三輪，第三輪的修正只改 operator 文件，依 manager 代決 D29 不再開第四輪；程序裡的 systemd 與 Loki 命令只對 stub 跑過，第一次執行要有人看著。上線前已知的風險：Trading01 上的共用 `ensure-log-access.sh` 可能比 master 舊，`add` 會拒絕，Step 1 的 `cmp` 不符就 STOP；共用 probe 的數量欄位與 dashboard 的持倉單位寫死 BTC，ETH lane 的單位要在 Step 5 核對。另外四個 Linux 範例的寬鬆 raw log glob 另開建議卡 WAN-355。

---

## 2026-11-16 00:01 — Windows 主機監控（第一台 wans-windows）

**改動摘要：** SkyEye 新增 Windows 主機的正式支援：Alloy config 範本、PowerShell 安裝器與解除安裝器、5 條 shadow 告警、dashboard「主機 — Windows」與 runbook，並全部納入 `scripts/verify-all`。這次只 merge；尚未部署到 wans-windows，runner 也還沒安裝。

**修改的檔案：**
- `agents/alloy/windows/config.alloy.tmpl`、`config-runner-diag.alloy.tmpl`：windows exporter（cpu、logical_disk、memory、net、os、service、system、time）、Alloy 自身的 17 個推送指標、System／Application Event Log，以及選用的 `Runner_*.log`。Secret 以 `local.file`（`is_secret = true`）讀取，header 經 `convert.nonsensitive`。`windows_os_info` 自帶的 `product` 改名為 `os_product`；丟棄 18 個每核心明細與帶有序號、路徑、帳號、IP、MAC 的 info 指標。Log 只留 `job`、`channel`、`level`、`product`、`server_id` 五個標籤，離開主機前去識別化；profile 路徑與帳號名稱含空白時整段遮蔽。
- `agents/alloy/windows/install.ps1`、`uninstall.ps1`、`SkyEyeAlloy.ps1`：Check（預設，不改任何東西）／Install／Rollback。不提示、不以參數收憑證、不開 secret 檔。換 config 前先 validate 並在獨立 port 與暫存目錄實跑一次；換上後 120 秒 health gate，失敗自動換回。Health gate 以 `queue_highest_sent_timestamp_seconds` 與 Loki 收下 canary 為準；看到重試或非 2xx 之後，要再確實送達並連續 35 秒沒有失敗才通過。現行 config 的 `external_labels` 讀不出確定值時拒絕接手，包含 map 後面還接著 `.欄位`、索引或運算子的寫法。原本停止的服務在檢查失敗後會停回去。結果寫到 `C:\ProgramData\SkyEye\reports\`。
- `agents/alloy/alloy-versions.env`：`SKYEYE_ALLOY_WINDOWS_VERSIONS="1.18.1"`。
- `prometheus/rules/windows.yml`、`prometheus/rules/tests/windows.test.yml`：`WindowsHostStale`、`WindowsDiskLow`、`WindowsDiskCritical`、`WindowsClockSkew`、`AlloyAgentPushFailing`，全部 shadow。
- `prometheus/rules/stack-health.yml`、`prometheus/rules/tests/stack-health.test.yml`：`AllRemoteAgentsSilent` 不變（不計 Windows），補上「Windows agent 還在送不能掩蓋共用 token 失效」的測試。
- `grafana/dashboards/Hosts/hosts-windows.json`：uid `hosts-windows`。數值卡是 instant query，主機停止回報後顯示「無資料」；折線圖保留歷史。
- `tests/windows/`、`tests/fixtures/windows/`：installer（fake host，679 項）、config（validate、實跑、secret 變異、標籤契約）、scrub（Event Log 33 例、runner log 16 例，經真的 Loki）、central（shadow 路由、metric 白名單、dashboard 查詢，含「曾回報、現已停止」的主機）。
- `scripts/verify-all`、`tests/alloy/test-alloy-versions.sh`：`pwsh` 列為必要工具，Windows 範本納入 `alloy validate` 與版本矩陣。
- `runbooks/windows-host-onboarding.md`、`agents/alloy/windows/README.md`：新增。`runbooks/README.md`、`runbooks/all-remote-agents-silent.md`、`agents/alloy/README.md`、`docs/onboarding-new-product.md`、`docs/grafana-conventions.md`、`README.md`、`AGENTS.md`：更新。

**原因/備註：** `alloy validate` 會放過「secret 直接當 header」的 config，Alloy 啟動時才以 `secrets may not be converted into strings` 退出，所以測試與安裝器都實際跑一次。`prometheus_remote_storage_samples_total` 只算嘗試次數，端點壞掉照樣上升，不能當送達證明；重試計數暫時不動也不算恢復，因為兩次重試之間最長會等 30 秒。名稱的結尾看不出來時（例如帳號後面接一般文字），scrub 會多遮掉後面幾個字，不留半個名字。接手保護只讀現行 config 檔裡的 `external_labels`；用 relabel 規則或 `import.*` module 設定的標籤讀不到。Windows 專用的兩個 Alloy 元件在 macOS／Linux 上不做事，PowerShell 5.1 與真正的服務、registry、ACL、Event Log 呼叫也無法在 macOS 測，第一次實跑是主機上的 Check 模式。驗證機器新裝 pwsh 7.7.0（連帶 dotnet 11.0.100、icu4c@79）。`scripts/verify-all` rc=0（38 步、無 SKIP）；拿掉 `convert.nonsensitive`、改壞 scrub 規則或把 health gate 改回只看計數時，對應的套件會失敗。Dashboard 尚未在 Grafana 用真實資料看過。

---

## 2026-11-14 21:28 — Alertmanager 升到 v0.34.2

**改動摘要：** Alertmanager 從 `prom/alertmanager:v0.27.0` 升到 `v0.34.2`，修掉 `url_file` webhook 收到非 2xx 回應就 nil-pointer panic 的問題（upstream #3800，v0.28.0 起修正），這是放 `deadman_url` 的前提。新增升級與 rollback runbook，並補上回歸測試。這次只 merge，部署要照 runbook 手動 pull／recreate。

**修改的檔案：**
- `docker-compose.yml`：Alertmanager image 改為 `prom/alertmanager:v0.34.2`。
- `AGENTS.md`、`docs/project-brief.md`、`docs/trading-accumulated-pnl-development-plan.md`、`docs/trading-dashboard-health-readability-development-plan.md`：版本與驗證命令更新。
- `tests/stack/test-deadman-switch.sh`：ping 端點依序回 404、503、200，確認 Alertmanager 不會退出、失敗有計數、其他告警照常送到 `telegram-high`；另外用未修改的設定（secrets 為空、假 `tg_token`）完整啟動一次。
- `tests/trading/test-central-deploy.sh`：Alertmanager image 改從 compose 讀，不再寫死版本。
- `runbooks/alertmanager-upgrade.md`：新增。內容包括時段、baseline、強制先 pull、手動 recreate、部署後檢查，以及 rollback（降到 0.28.0 以下前要先移除 `deadman_url`）。
- `runbooks/skyeye-watchdog.md`、`runbooks/README.md`、`alertmanager/secrets/README.md`：第 2 步改連到升級 runbook，並更新 0.34 的 `reason` 對照表與 log 行為說明。

**原因/備註：** 同樣的回歸測試在 v0.27.0 上會失敗（panic 後 rc=1），在 v0.34.2 上通過。離線驗過以下幾點：0.27.0 → 0.34.2 → 0.27.0 往返後 silence 與 nflog 都保留；dashboard 與 rule 用到的 metrics 都還在；Grafana 的 datasource 是 `access: proxy`，不受 0.34.2 預設關閉 CORS 影響。`scripts/central-deploy` 不處理 image 變更，也沒有改；它的 amtool／promtool 驗證沒有 `--pull=never`，所以 runbook 規定部署前必須先 pull。Codex review R1 READY_WITH_MINOR，三個 MINOR 已修：200 案例的計數 baseline、log 可能含回應 body 裡的網址、重試 WARN 會去重。

---

## 2026-11-14 20:10 — monitoring-prod 的外部 dead man's switch（SkyEyeWatchdog）

**改動摘要：** 新增 `SkyEyeWatchdog`：只要 Prometheus 的 TSDB head 還在前進就一直 firing，Alertmanager 第一條 route 把它送到 `deadman-external` webhook（`url_file: /etc/alertmanager/secrets/deadman_url`），由外部 hosted check 在收不到 ping 時通知 Wan。另加 shadow 告警 `AllRemoteAgentsSilent`（所有遠端 agent 同時沒有 up）。這次只 merge／部署設定，secret 尚未放、外部帳號尚未開，所以不會送任何流量。

**修改的檔案：**
- `prometheus/rules/deadman.yml`：`SkyEyeWatchdog`（`time() - prometheus_tsdb_head_max_time/1000 < 120`，`severity: None`）。
- `alertmanager/alertmanager.yml`：第一條 route `alertname="SkyEyeWatchdog"` → `deadman-external`（`repeat_interval 5m`、`send_resolved: false`、`max_alerts: 1`）。
- `prometheus/rules/stack-health.yml`：`AlertmanagerNotifyFailures` 排除 `integration="webhook"`，避免 secret 未放時發 Telegram；新增 shadow `AllRemoteAgentsSilent`；`AlertmanagerDown` 指向外部 heartbeat。
- `scripts/central-deploy`：`alertmanager/secrets/deadman_url` 加入允許的本機檔案。
- `runbooks/skyeye-watchdog.md`、`runbooks/all-remote-agents-silent.md`：新增；`runbooks/README.md`、`alertmanager/secrets/README.md`、`docs/operations.md`、`README.md` 更新。
- `prometheus/rules/tests/deadman.test.yml`、`prometheus/rules/tests/stack-health.test.yml`、`tests/stack/test-deadman-switch.sh`（新增）、`tests/trading/test-central-deploy.sh`：rule、route 與沒有 secret 時的實機測試。

**原因/備註：** D15 A（11-14 重啟）：monitoring-prod 自己掛掉時目前沒人會發現。Codex review R1 一個 BLOCKER：釘住的 Alertmanager v0.27.0 用 `url_file` 的 webhook 收到非 2xx 回應會 nil-pointer panic 並退出（upstream #3800，v0.28.0 修正）。沒有 secret 時不會發 HTTP，所以現在部署是安全的；runbook 與 secrets README 加了硬性檢查：Alertmanager < 0.28.0 不得放 `deadman_url`。升級到 v0.34.2 另開任務（需手動 pull／recreate，central-deploy 不處理 image 變更）。Tunnel 探測也另開任務。R2 READY。

---

## 2026-11-14 20:30 — Rollout runbook 的 Loki 驗收修正

**改動摘要：** Trading01 與 Mac mini 兩份 rollout runbook 的 Loki 驗收改成：來源 log 取最後一個寫完的行；未遮蔽 ID 的檢查不再把空值（`order_id=""`）算成外洩，也只把完整的 `[ORDER_REF]` 當成已遮蔽，`[ORDER_REF]tq123` 這類殘留仍算外洩。

**修改的檔案：**
- `docs/trading01-popdex-rollout.md`：`log_evidence` 改成讀一次尾端、取最後一個完整的行；Robinhood 的 SINCE 改用 `loki-since`（切換後再加 1 秒）；`loki_accept` 換新的 regex。
- `docs/macmini-m2-alloy-rollout.md`：`loki_accept` 換同一個 regex；新增 2026-11-14 那次驗收的重驗步驟（`loki-since` 1794651500）。
- `tests/trading/test-trading01-popdex-rollout.sh`、`tests/trading/test-macmini-alloy-rollout.sh`：fake Loki 改用 query 內的 regex 實際比對，新增空值、殘留 ID、完整 marker 與最後一行的案例。

**原因/備註：** 11-14 Mac mini rollout 的 Loki 驗收唯一命中是空的 `order_id=""`，是檢查本身誤判。Trading01 的 `log_evidence` 固定取倒數第二行，可能把 LOKI-MISSING 判成 PENDING；11-14 Trading01 兩條都已 ACCEPTED，不受影響。新 regex 在真實遮蔽輸出（4 條 pipeline 各 909 行）命中 0，在 Loki 3.1.1 實測正確。Codex review 兩輪：R1 一個 MAJOR（只要開頭是 `[ORDER_REF]` 就放行），R2 READY。

---

## 2026-11-14 19:30 — Mac mini Alloy pin 與 setup-macos 上線 runbook

**改動摘要：** 新增 Mac mini（macmini-m2 / toobit-mexc-btc）的上線 runbook：Alloy 確認是 1.18.1 後 `brew pin`，再重跑 `setup-macos.sh` 換上新 probe 與 Trading log 遮蔽。每一步標明 READ-ONLY 或 CHANGE，附 STOP 條件、rollback R2／R3 與中央、Loki 驗收，並新增直接執行 runbook 原文的演練測試。這次只 merge，主機尚未執行。

**修改的檔案：**
- `docs/macmini-m2-alloy-rollout.md`：新增。SSH session 能否管理 `gui/<uid>` 與 brew services 的 gate（不行就由 Wan 在 console 執行 CHANGE 與 rollback）；所有 CHANGE 與 rollback 都避開 UTC 18:05–19:30；啟動輸入 freshness、render 比對、tnauqquant census 前後必須相同；Loki 驗收從 installer 成功且 Alloy ready 之後開始算；P&L history 前後比對（KEPT／CHANGED／UNVERIFIED）。
- `tests/trading/test-macmini-alloy-rollout.sh`：新增，取 runbook 的 helpers 與 Phase 區塊原文，在 brew／launchctl／tmux／Loki shim 沙盒內演練，177 checks。
- `agents/alloy/README.md`、`agents/alloy/trading/README.md`：補上 macOS pin 說明與 runbook 連結。

**原因/備註：** Wan 同意所有主機升 Alloy，但不能動交易程式（D28 A）。Mac mini 已是 1.18.1，tap 已到 1.21.x，所以只 pin 不移動版本；其他版本 STOP，不 downgrade。Codex review 三輪：R1 有 4 個 MAJOR（rollback 沒有時間與 session gate、Loki 起點太早、log 證據丟掉最後一行），R2 剩 2 個 MINOR，都已修正。真實的 launchd 與跨 SSH 的 brew services 行為只在 shim 演練過，第一次上線要有人看著。`docs/trading01-popdex-rollout.md` 的 `log_evidence` 有同樣丟掉最後一行的問題，另開任務修。

---

## 2026-11-14 16:55 — Trading installer 從任何工作目錄都能執行

**改動摘要：** `setup-linux.sh` 以 probe user／Alloy user 執行的 helper 一律從 `/` 啟動，root shell 停在 `/root` 時 `add` 不再無訊息失敗。`ensure-log-access.sh` 先 `cd /`，`find` 失敗時印出原因，不再只回 rc=1。

**修改的檔案：**
- `agents/alloy/trading/linux-common.sh`：新增 `run_as_user`，以 `/` 為工作目錄執行 `runuser`。
- `agents/alloy/trading/setup-linux.sh`：4 個 `runuser` 呼叫改用 `run_as_user`；`ensure-log-access.sh` 失敗時說明是哪一步。
- `agents/alloy/trading/ensure-log-access.sh`：開頭 `cd /`；保留 `find` 的 stderr，失敗時以 `listing configured raw logs with find failed (rc=N)` 結束。
- `docs/trading01-popdex-rollout.md`：註明較舊的 installer 需要先 `cd /`，11-14 的 rollout 就是這樣執行。
- `tests/trading/test-linux-setup.sh`、`tests/trading/test-log-access.sh`：模擬 GNU find 回不到原工作目錄的行為，測從無權進入的目錄執行 `add` 與 helper，以及 `find` 失敗時有錯誤訊息。

**原因/備註：** 11-14 Trading01 PopDEX rollout 的 Phase 3 `add` 回 rc=1 且沒有訊息。原因是 root shell 在 `/root`（mode 700），`runuser -u ubuntu` 的 `find` 列完檔案後回不到 `/root` 而 exit 1，錯誤又被 `2>/dev/null` 和 pipefail 吞掉。當次 rollout 以 `cd /` 繞過並完成。`ensure-log-access.sh` 也是 probe unit 的 ExecStartPre，`find` 失敗時現在會在 journal 留下原因。Codex review R1 READY。

---

## 2026-11-14 16:30 — Trading01 PopDEX 監控、Mainnet 停用設定與 Alloy 升級腳本

**改動摘要：** Trading01 新增 `popdex-btc` target，並寫好 Trading01 的上線 runbook：Alloy 1.16.0→1.16.3、共用 probe 換新、加上 PopDEX、Mainnet 停用設定，central-deploy 排在最後。probe 新增 `TQ_STRATEGY_DISABLED`，給刻意停用的 strategy 用：停用後不再顯示 ProcessDown，意外啟動時仍會觸發 `TradingUnexpectedProcess`。新增 Linux Alloy 升級腳本，會先驗證設定，失敗時自動還原。Trading log 另外遮蔽 client order ID。這次只 merge，主機 rollout 與中央部署依 runbook 另外進行。

**修改的檔案：**
- `agents/alloy/trading/probe.sh`、`setup-linux.sh`、`setup-macos.sh`：新增 `TQ_STRATEGY_DISABLED`（只接受 0/1，其他值 fail closed）。
- `agents/alloy/trading/deployment-linux-popdex.env.example`：新增 PopDEX instance env，不含 credential。`deployment-linux-mainnet.env.example` 設為 `TQ_STRATEGY_DISABLED=1`。
- `agents/alloy/trading/config-linux.alloy.tmpl`、`config-macos.alloy.tmpl`：`[ORDER_REF]` 加上 `client_?id`，遮蔽 `ack_`／`bid_`／`ask_client_id` 與 `clientId`。
- `agents/alloy/upgrade-linux.sh`、`agents/alloy/install-common.sh`、`agents/alloy/README.md`：新增 apt Alloy 升級，`--to`／`--check`／`--rollback`。升級前用新 binary 驗證 live config，conffile hash 必須不變，接著做健康檢查並 hold。還原過設定就強制 restart。每次執行都有自己的 record。
- `prometheus/rules/trading-targets.yml`：以 `scripts/trading-target add` 新增 trading01/popdex-btc。
- `docs/trading01-popdex-rollout.md`：新增 Trading01 rollout runbook，每一步標明 READ-ONLY 或 CHANGE，附 STOP 條件與 rollback R2–R5。Loki 驗收必須在中央找到與來源端時間相同的行，空的 stream 不算通過。
- `agents/alloy/trading/README.md`、`docs/trading-new-server-handoff.md`：補上停用設定與 runbook 連結。
- `tests/alloy/test-upgrade-linux.sh`、`tests/trading/test-trading01-popdex-rollout.sh`：新增。另擴充 `test-probe`、`test-probe-safety`、`test-linux-setup`、`test-macos-setup`、`test-central-config`、`test-central-deploy`、scrub fixture 與 `trading.test.yml`。

**原因/備註：** Wan 透過 tnauqquant manager 要求把 PopDEX 接進 Grafana，並要求走正規升級。Trading01 的 Alloy 是 1.16.0，不在支援清單內，`add` 會拒絕執行。共用 probe 還是 09-13 的版本。Mainnet 11-07 是 graceful stop，沒有留下 done marker，所以只設 `TQ_POC_RUN_EXPECTED=0` 無效。Codex review 兩輪：R1 有 5 個 MAJOR，都在 rollback 路徑；R2 READY。Mac mini 不在這次範圍內，它的 Trading log 遮蔽要等下次重跑 installer 才生效。PROD02 與 Mac mini 的 Alloy 升級另開任務。

---

## 2026-11-07 22:30 — 安裝與部署強化（Codex review v2 剩餘項）

**改動摘要：** `central-deploy` 改讀 Prometheus 的即時值確認 reload，新增 `--expect`，dashboard UID 檢查改看 applied 之後的歷史，並加上並行鎖。主機 installer 只接受測過的 Alloy 版本、加上互斥鎖，Linux `add` 保留 probe timer 原本的狀態，macOS installer 改成先驗證再替換、失敗時還原。重建主機用的 AWS CLI 鎖定版本並在安裝前比對 sha256。這次只 merge，未部署，也未在任何主機重跑 installer。

**修改的檔案：**
- `scripts/central-deploy`：reload 結果改讀 `/metrics`，要求成功 timestamp 不早於這次 reload；新增 `--expect <sha>`；absent UID 從 applied 之後的歷史推導，touched dashboard 沿 first-parent 收集；deploy 與 `--dry-run` 取非阻塞鎖。
- `scripts/trading-target`：`add`／`remove` 對 inventory 目錄取鎖，`--lock-timeout` 預設 30 秒。
- `agents/alloy/alloy-versions.env`、`agents/alloy/install-common.sh`：新增。測過的版本是 Linux `1.16.3 1.18.1`、macOS `1.18.1`，apt pin 是 `1.18.1-1`。共用的版本 gate 與 perl flock 都在這裡。
- `agents/alloy/setup.sh`、`agents/alloy/uninstall.sh`：版本 gate 與 `/run/skyeye-alloy.lock`；新主機安裝後 `apt-mark hold alloy`；uninstall 先 unhold。
- `agents/alloy/trading/setup-linux.sh`、`agents/alloy/trading/retire-linux.sh`：版本 gate 與鎖。已安裝 instance 的 enabled 與 active 狀態分開保留，新增 `--enable-probe`。
- `agents/alloy/trading/setup-macos.sh`：檔案先 stage 並驗證；只替換有變更的檔案；只改 config 時 reload，改 env 時 restart；失敗時還原。`config.env`／`extra-args.txt` 被改過導致無法還原時，以 rc=3 回報 `rollback_incomplete`。
- `scripts/bootstrap-monitoring-ec2.sh`：AWS CLI 鎖定 2.39.3，用 `curl -fsSL --proto '=https'` 下載，sha256 相符才安裝。
- `scripts/verify-all`：`REQUIRED_TOOLS` 加入 `perl`。
- `tests/alloy/test-alloy-versions.sh`、`tests/trading/test-macos-setup.sh`、`tests/bootstrap/test-bootstrap-awscli.sh`：新增；另擴充 `test-central-deploy`、`test-trading-target`、`test-setup-atomic`、`test-linux-setup`。
- `README.md`、`agents/alloy/README.md`、`agents/alloy/trading/README.md`、`docs/trading-new-server-handoff.md`、`docs/trading-serverid-cutover-macmini-m2.md`、`docs/operations.md`：版本檢查、重跑方式、`--expect` 與 AWS CLI pin 的說明。

**原因/備註：** Trading01 與 PROD02 的確切 Alloy 版本未知，重跑任何 installer 前要先在主機唯讀跑 `alloy --version`，版本不在清單內就停下回報。Mac mini 第一次跑新版 `setup-macos.sh` 會重啟 Alloy 一次，因為還沒有 env 記錄。真實的 launchd、brew services、systemd 與 Alloy reload 都沒有實跑，第一次上線要有人看著。AWS CLI 簽章公鑰 2027-07-01 到期。Linux 鎖改放 `/run`，不放 `/run/lock`，因為 `/run/lock` 是 1777，任何使用者都能搶先建立鎖檔。

---

## 2026-11-07 20:10 — Grafana 改驗 Cloudflare Access JWT（P2-16）

**改動摘要：** Grafana 不再相信 `Cf-Access-Authenticated-User-Email` header，改成驗證 Cloudflare Access 簽發的 `Cf-Access-Jwt-Assertion`。新使用者預設 Viewer。這次只 merge，未部署。

**修改的檔案：**
- `docker-compose.yml`：grafana 關閉 auth proxy 並移除 whitelist。改用 JWT auth，簽章金鑰取自 `https://wanbrain.cloudflareaccess.com/cdn-cgi/access/certs`，並檢查 `aud` 與 `iss`。`cache_ttl=5m`、`skip_org_role_sync=true`，新使用者預設 Viewer（原本是 Admin）。
- `tests/grafana/test-access-jwt.sh`：新增測試。Grafana 跑在 `--network none` 的真實 11.2.0 container，使用 commit 進去的設定。測試涵蓋合法 token、偽造 header、錯誤的 aud／iss、過期、別的 key 簽的、`alg=none`、簽章金鑰連不到時的 fail closed、既有 Admin 保留，以及 Viewer service account 讀 dashboard。
- `scripts/verify-all`：`REQUIRED_TOOLS` 加入 `openssl`。
- `docs/operations.md`：新增 Grafana sign-in 一節，內容有部署順序（停 Grafana 後備份 DB）、Viewer token smoke check、rollback、被鎖在外面時的判讀與 break-glass。runbook 不送 email header。
- `cloudflared/README.md`：AUD 與 team domain 在哪裡找；一個 hostname 只能有一個不設 path 的 Access app。
- `monitoring-plan-v2.md`：§13.1 的 auth proxy 設計註記已被取代。

**原因/備註：** 本機用 11.2.0 加上 repo 的設定重現：主機上任何程序，或同一個 Docker network 的 container，送偽造的 email header 就能取得 Admin，冒用既有 email 會直接登入成那個帳號，包括 Server Admin。外部請求先被 Cloudflare Access 擋住。AUD 取自 `grafana.wanbrain.com` 的 Access 302 redirect，Wan 確認這個 hostname 只有一個 Access app。部署要重建 grafana container，須另外核准，Wan 要在瀏覽器旁確認登入。舊 auth proxy 自動建立的 Admin 帳號與 service account 不受影響，上線後需要盤點。Cloudflare 實際的 claim 格式與換 key 的節奏都是推論，沒有在 production 驗證。

---

## 2026-11-06 08:22 — 文件與現況同步

**改動摘要：** 修正文件與現況不一致的地方：告警實際路由、驗證命令、project brief 待辦、`node-exporter` 部署順序、還原流程與成本數字。只改文件，不影響線上。

**修改的檔案：**
- `AGENTS.md` — High 告警目前只送 Telegram、`scripts/verify-all` 是 merge gate、驗證命令補 `--entrypoint`
- `docs/project-brief.md` — 更新目前狀態與過期待辦
- `docs/operations.md`、`runbooks/disk-full.md`、`runbooks/README.md`、`docs/grafana-conventions.md` — 還原工具與 RTO 估計、`node-exporter` 部署與回滾順序、儲存量與成本數字、備份告警
- `docs/code-patterns/python-fastapi.md`、`docs/phase-2d-ppclub-business-counters.md` — 修正例外路徑 label 與外部 API 計時範例
- `docs/trading-serverid-cutover-macmini-m2.md` — 補執行紀錄與舊名資料清除
- `agents/alloy/trading/README.md`、`docs/trading-runtime-contract-agent-spec.md`、`docs/trading-monitoring-development-plan.md`、`docs/trading-accumulated-pnl-development-plan.md`、`runbooks/trading-critical-safety-state.md` — strategy 搬移要先 remove 再 add、safe marker phase、持倉順序

**原因/備註：** macmini-m2 cutover 時窗為 2026-11-01T13:31:29Z～15:31:29Z，Shadow 與 canary 證據要排除這段。文件裡的部署、回滾與還原指令都沒有在 monitoring-prod 或真實 S3 跑過，RTO 與成本數字是估計。PR #61 部署後，`docs/operations.md`、`runbooks/disk-full.md`、`docs/project-brief.md` 的「尚未部署」要更新，`runbooks/backup-failed.md` 也要改成新腳本行為。

---

## 2026-11-06 07:42 — 監控覆蓋、備份、log scrub、通知路由與部署驗證（10 項）

**改動摘要：** 合併 Codex review v2 與第三份 review 後續的 10 項工作：Stack health 訊號修正、Prometheus 世代備份與分階段還原、monitoring-prod 主機指標、Alloy log scrub 強化、paged 告警的休眠 email 路由、probe 時間處理、`setup.sh` 原子安裝、`central-deploy` 實際載入驗證與 `scripts/verify-all` 本機 merge gate。Trading 告警維持全 shadow，這次只 merge，未部署。

**修改的檔案：**
- `scripts/verify-all` — 新增本機 merge gate，自動探索 `tests/` 與 rule test
- `prometheus/rules/stack-health.yml`、`prometheus/rules/system.yml`、`grafana/dashboards/SkyEye/skyeye-stack-health.json`、`tests/stack/` — `PrometheusRuleEvalSlow` 改用存在的指標，新增 `PrometheusRuleIterationsMissed`，`SystemdUnitFailed` 改 shadow，修正 Panel 12、22、54
- `prometheus/rules/backup.yml`、`runbooks/backup-failed.md`、`runbooks/disk-full.md`、`docs/operations.md` — 4 條備份 shadow 告警與安全還原流程
- `scripts/backup-prometheus.sh`、`scripts/restore-prometheus.sh`、`tests/backup/` — 世代備份、`MANIFEST.json`、3 GiB 上限、staged 還原與自動 rollback
- `docker-compose.yml`、`prometheus/prometheus.yml`、`prometheus/rules/tests/monitoring-host.test.yml` — 新增 `node-exporter` 與 `monitoring-host` job
- `agents/alloy/config-logs.alloy.tmpl`、`agents/alloy/trading/config-linux.alloy.tmpl`、`agents/alloy/trading/config-macos.alloy.tmpl`、`tests/fixtures/scrub/`、`tests/trading/test-scrub-pipeline.sh` — 強化 scrub 規則，155 個案例在真實 Alloy 與 Loki 上實跑
- `alertmanager/alertmanager.yml`、`scripts/trading-target`、`runbooks/trading-alert-promotion.md` — paged High 的休眠 email 路由，`check-alert-modes` 限定 3 條 Trading 告警可設為 `page`，新增升級 runbook
- `agents/alloy/trading/probe.sh` — 未來或無法解析時間的事件不進入損益、曲線與成交量；今日完成週期改用 `TQ_TIMEZONE` 的 epoch 區間
- `agents/alloy/setup.sh`、`tests/alloy/test-setup-atomic.sh` — 寫入前完成檢查，暫存檔 `alloy validate` 後原子替換，失敗時還原舊設定
- `scripts/central-deploy`、`tests/trading/test-central-deploy.sh` — 確認 Prometheus、Loki ruler 與 Grafana 實際載入後才記錄 applied SHA

**原因/備註：** 部署要另外核准。`central-deploy` 上線前要先在 monitoring-prod 建 Grafana Viewer service account token，否則有 dashboard 變更或沒有 applied 紀錄的部署會在 fast-forward 前被擋下。`node-exporter` 要先 `docker compose up -d node-exporter` 再跑 `central-deploy`。`PrometheusBackupSignalMissing` 在新備份腳本上線前會以 shadow firing，Overview 的 Active alerts 會多 1。3 GiB 上限會刪最後一份受管 snapshot。Scrub 已知洩漏殘留 A30、A31、T19、X17、M02，以及 4 種 fail closed 丟掉 `msg` 的形式（X16、X23、A35、E15），rollout 前要先唯讀統計線上是否有這種行。C-4 修好前 PROD02 不可重跑 `setup.sh`，scrub rollout 也一樣。真實 S3、真實 systemd 與 Grafana 前端未驗證。

---

## 2026-11-06 07:35 — 同步已上線的 LinkCourt 付款告警

**改動摘要：** 把 Wan 在 linkcourt D111、D114 核准、11-03 直接加到 monitoring-prod 的三條付款告警原樣同步進 Git，補上 promtool 測試。規則內容與直接送 High 的行為都不變。

**修改的檔案：**
- `prometheus/rules/business.yml` — 與線上檔案逐位元相同，SHA-256 為 `728519d977d3aa2a1c1f1bb7f39a417464922d6e269bfe14a5374c519eb66daf`
- `prometheus/rules/tests/linkcourt-payment-alerts.test.yml` — 八組測試，涵蓋三條規則、缺失 metrics、counter 時窗與 result 過濾

**原因/備註：** 線上與 Git 不一致時 `central-deploy` 會拒絕部署，主機重建時這三條告警也會消失。依 SkyEye D20 A 同步，部署由 operator 另外執行。

---

## 2026-11-05 03:17 — Trading probe 與告警的假安全修正

**改動摘要：** 修正 Codex review v2 的八項 Trading finding（P2-07～P2-12、P2-22、P2-24）：probe 不再把矛盾的 safe marker、`ps` 失敗、wrapper 與未來時間當成正常，dashboard 顯示財務與持倉資料年齡，shadow 告警不再抑制已升級的告警。所有 Trading 告警維持 shadow，這次只 merge，未部署。

**修改的檔案：**
- `agents/alloy/trading/probe.sh` — safe marker 一致性檢查；`ps` 失敗或 listing 不完整時結束 probe；依實際執行檔與啟動時間判斷程序身分；解析多種 `-config` 寫法；舊 net 不再蓋過新 venue；拒收超前 120 秒以上的時間；新增 `tnauqquant_position_sample_timestamp_seconds`
- `prometheus/rules/trading.yml` — 新增持倉時間 recording rule 與 shadow alert `TradingSourceClockAhead`；三條 freshness rule 加 `abs()`
- `alertmanager/alertmanager.yml` — inhibit source 排除 `notification_mode="shadow"`
- `grafana/dashboards/Trading/trading-strategy-detail.json`、`trading-strategy-fleet.json` — 新增財務與持倉年齡，「資料更新」改「探針更新」，fleet 告警計數不再過濾 shadow
- `scripts/trading-target` — 拒絕同一 strategy 出現在兩台 server
- `runbooks/trading-telemetry-missing.md` — 新增 Source clock ahead 段落
- `tests/trading/`、`prometheus/rules/tests/trading-clock-skew.test.yml` — 新增 `test-probe-safety`、`test-alert-routing`、`test-dashboard-semantics`、`test-source-clock`，更新既有測試

**原因/備註：** tnauqquant 的 `reduce_only_complete` 的 phase 是 `startup`、`signal_loop`、`cycle`，不等於 reason，所以 marker 檢查只對 `max_cycles_complete` 要求相等。搬移 strategy 要先 remove 再 add。部署要另外核准：central 走 `scripts/central-deploy`，probe 要到 Trading01 與 Mac mini rollout 才生效。Grafana 前端與完整 probe 的 Linux 端到端尚未驗證。

---

## 2026-11-01 20:10 — Mac mini Trading `server_id` 更名為 `macmini-m2` 與 cutover runbook

**改動摘要：** 依 D14 將 Mac mini 的 Trading `server_id` 由 `tnauqquant-prod-1` 更名為 `macmini-m2`，同步更新中央 inventory、測試與文件，並新增 operator 用的 cutover runbook（先改 host agent、後以 `scripts/central-deploy` 部署中央 rules，Step 0／4 以 `origin/master == $MERGE` 閘門擋住未審閱的 commit）。

**修改的檔案：**
- `prometheus/rules/trading-targets.yml`、`prometheus/rules/tests/fixtures/trading-targets.yml` — Mac mini target 改為 `macmini-m2`（fixture 以 `scripts/trading-target` 重算）
- `prometheus/rules/tests/trading.test.yml`、`tests/trading/test-central-config.sh`、`tests/trading/test-pnl-history.sh` — 測試改用 `macmini-m2`
- `docs/trading-serverid-cutover-macmini-m2.md` — 新增 cutover 程序：2h silence、Step 4 經 `scripts/central-deploy`、`if/else` SHA 閘門、merge 凍結、Rollback A／B、舊名歷史查詢
- `runbooks/trading-critical-safety-state.md`、`runbooks/trading-process-down.md`、`runbooks/trading-telemetry-missing.md` — 查詢範例改為 `macmini-m2`
- `agents/alloy/trading/deployment.env.example`、`agents/alloy/trading/README.md`、`docs/trading-new-server-handoff.md`、`docs/project-brief.md`、`docs/trading-monitoring-development-plan.md` — 範例、現況與 D14 決策

**原因/備註：** 使用者 D14 決定真正改 label（不用 Grafana display mapping），D1 核准 cutover，Mac mini 的 Step 2 由使用者本人執行。Code review R1 C1（promtool／amtool 的 `docker run` 補 `--entrypoint`）與 R2 C3（SHA 閘門改為 `if/else`，不符時不呼叫 `central-deploy`）已修正。舊名只保留在 cutover runbook 與歷史紀錄中。這個 PR merge 後不會自動生效，中央部署照 runbook 在 cutover 時窗內執行；cutover 起訖時間記錄在 operator 報告，隨下一次 SkyEye 修改補進 work-log。

---

## 2026-11-01 02:20 — Trading 監控目標一鍵新增／移除與中央部署指令

**改動摘要：** 新增 `scripts/trading-target`（inventory add/remove/check/render-test）、`setup-linux.sh add` 與 `retire`（主機端一步安裝／退役，預設只 reload Alloy）、`scripts/central-deploy`（monitoring-prod 拉取已 merge 的設定，驗證後 reload，記錄最後成功套用的 commit）。

**修改的檔案：**
- `scripts/trading-target` — 管理 `prometheus/rules/trading-targets.yml` 並重算測試 fixture
- `scripts/central-deploy` — fetch／ff、promtool/amtool 驗證、reload Prometheus／Alertmanager；失敗後重跑即重試；拒絕需重建 container 的變更（含手動 `git pull` 帶進來的）與載入路徑中未追蹤的檔案（只允許 `alertmanager/secrets/tg_token`）；`--manual-applied SHA` 在手動重建後確認套用
- `agents/alloy/trading/setup-linux.sh`、`retire-linux.sh`、`linux-common.sh` — add/retire 交易式安裝與 rollback；未帶 `--restart-alloy` 時 rollback 絕不重啟 Alloy；retire 先停 probe 再封存 metrics；env 引號值 add 與 retire 一致解碼
- `prometheus/rules/tests/fixtures/trading-targets.yml`、`prometheus/rules/tests/trading.test.yml` — inventory 測試 fixture
- `tests/trading/test-trading-target.sh`、`test-linux-setup.sh`、`test-central-deploy.sh`、`test-central-config.sh` — 新指令與回歸測試
- `agents/alloy/trading/README.md`、`README.md`、`AGENTS.md`、`docs/trading-new-server-handoff.md`、`docs/project-brief.md` — 操作說明

**原因/備註：** 使用者要求新增或移除監控目標只需一個指令。Code review 三輪：R1 C1–C5、R2 C7 皆已修正並有回歸測試，R3 READY。主機與中央行為以本機 Git fixture 與 systemd／Docker／curl stub 驗證，尚未在 monitoring-prod 或 Trading 主機實際執行；`central-deploy` 首次實跑沒有套用紀錄，會各 reload Prometheus 與 Alertmanager 一次。

---

## 2026-10-31 14:40 — 恢復 Trading01 Lighter Mainnet 監控名單

**改動摘要：** 在中央 Trading inventory 加回 `trading01` / `lighter-mainnet-btc-canary`（shadow），讓使用者以新帳號 765446 重啟 Mainnet lane 前先在 Grafana 看到該策略。

**修改的檔案：**
- `prometheus/rules/trading-targets.yml` — 新增 Mainnet `trading_target_info` stanza（內容與 PR #45 退役前相同）
- `prometheus/rules/tests/trading.test.yml` — healthy 與 telemetry-missing 測試納入 Mainnet；新增「lane 停止且 run_expected=0 時 11 條 Trading 告警皆不觸發」測試
- `tests/trading/test-central-config.sh` — inventory 數量 2→3，加入 Mainnet identity 與 stanza 檢查
- `docs/project-brief.md` — 現況改為 Mainnet 已恢復監控

**原因/備註：** 所有 Trading 告警仍為 `notification_mode: shadow`（路由到 `shadow-null`），不會發出通知。部署順序：先在 Trading01 安裝 Mainnet probe，再於 monitoring-prod pull 並 reload Prometheus。本 PR 未改 dashboards、alertmanager 或 agents。依使用者指示，此例行 inventory 變更未另做 code review。

---

## 2026-10-29 03:20 — 專案文件與主分支程式狀態對帳

**改動摘要：** 修正過期的未完成／未發布標籤，將程式實作、歷史驗證、合併／tag 與 production 部署證據分開。

**修改的檔案：**
- `docs/documentation-status-audit-20261029.md` — 更新狀態與證據界線
- `docs/project-brief.md` — 更新狀態與證據界線
- `docs/superpowers/plans/2026-09-13-trading-log-order-refresh.md` — 更新狀態與證據界線
- `docs/superpowers/plans/2026-09-13-trading-mobile-summary.md` — 更新狀態與證據界線
- `docs/trading-monitoring-development-plan.md` — 更新狀態與證據界線
- `docs/trading-runtime-contract-agent-spec.md` — 更新狀態與證據界線

**原因/備註：** 基準 `f5bb183e344d08ed00269cabd3065d86a6c0221c`；靜態核對文件、主分支程式／tests 與既有證據；本次未重跑全部 runtime 驗收。PR 的 required CI 結果另留於 PR。 所有變更限文件，未部署、未操作真實帳號。

---

## 2026-10-27 — Trading probe timer 開機後不會啟動

**改動摘要：** `skyeye-trading-probe@.timer` 移除 `Persistent=true`，主機重開機後 probe 會在開機約 5 秒後自動開始、之後每 15 秒執行。

**修改的檔案：**
- `agents/alloy/trading/skyeye-trading-probe@.timer.tmpl` — 刪除 `Persistent=true`，註解說明原因。
- `tests/trading/test-linux-setup.sh` — 斷言 timer 保留 `OnBootSec=5s` 且不含 `Persistent=`。

**原因/備註：** Trading01 於 2026-10-27 換規格重開機後，timer `active` 但 `NextElapseUSecMonotonic=infinity`，probe 一次都沒跑，SkyEye 誤報 `TradingProcessDown`／`TradingTelemetryMissing`，手動 `systemctl start` 該 service 後恢復。`Persistent=` 只對 `OnCalendar=` 有意義；有它時 systemd 會從 stamp 讀回上次開機的觸發時間，timer 啟動時若已過了 `OnBootSec=5s`，就把這個一次性觸發視為已觸發而丟棄，service 本次開機又沒跑過，`OnUnitActiveSec=` 沒有基準，整個 timer 停擺。已在 Staging01 用兩個臨時 timer（帶舊 stamp、目標 service 未曾執行）重現：有 `Persistent=true` 的下一次觸發為 `infinity`、service 未執行；沒有的立即觸發並排程下一次。驗證：`tests/trading/test-linux-setup.sh`（ripgrep 14.1.1）通過。Timer 模板沒有 placeholder，部署時依共用檔案規則先 `disable --now` 所有 probe timer，安裝新模板到 `/etc/systemd/system/skyeye-trading-probe@.timer`、`daemon-reload`，再 `enable --now` 並手動 start 一次 service。

---

## 2026-10-27 — 所有容器加上 Docker log rotation

**改動摘要：** `docker-compose.yml` 新增 `x-logging` anchor（json-file，`max-size: 50m`、`max-file: 5`），套用到全部 6 個 service，每個容器 stdout log 上限 250 MB。

**修改的檔案：**
- `docker-compose.yml` — 新增 `x-logging: &default-logging`，每個 service 加 `logging: *default-logging`。
- `runbooks/disk-full.md` — Docker bloat 的成因補充：容器 log 已有上限，若仍有巨大 `*-json.log` 代表容器在上限之前建立，需 `docker compose up -d` 重建。

**原因/備註：** monitoring-prod 根磁碟 30 GB 用到 77%，其中 `skyeye-loki-1` 的 json-file log 單檔 14.4 GB（2026-05 建立後未輪替，Loki 以 info 級別記錄每筆 query）；主機沒有 `/etc/docker/daemon.json`，Docker 預設不輪替。Log 設定只在容器重建時生效，部署要 `git pull` 後 `sudo docker compose up -d`，舊容器連同舊 log 一起移除。重建時各服務中斷數秒，Alloy remote-write／Loki push 會重送。

---

## 2026-10-27 — cloudflared 升級至 2026.10.3（Cloudflare eMudhra 憑證通知）

**改動摘要：** 中央 tunnel `skyeye-monitoring-prod` 的 cloudflared image 由 `2024.10.0` 升到 `2026.10.3`，並在 operations playbook 新增 cloudflared 升級／驗證／回滾流程。

**修改的檔案：**
- `docker-compose.yml` — `cloudflare/cloudflared:2024.10.0` → `2026.10.3`，其他 image 不變。
- `docs/operations.md` — 新增「Upgrade cloudflared」：`git pull`、`docker compose pull cloudflared`、`up -d`（`restart` 不會換 image）、版本與 tunnel Healthy／Grafana 檢查、回滾。

**原因/備註：** Cloudflare 2026-10 通知：2026.10.2 以前的 cloudflared 仍信任使用弱私鑰的 eMudhra（emSign）中繼憑證，Docker 部署需 pull 並重建 2026.10.3。選 2026.10.3（2026-10-21 發布、通知指名版本），不用 2026-10-26 才發布的 2026.10.4。ingress origin 全是 `http://`（grafana／prometheus／loki），新版較嚴格的 origin 憑證驗證不影響。2024.10.0 → 2026.10.3 唯一相關變更是 2026.4.0 起 `edge-ip-version` 預設由 `4` 改 `auto`；若升級後 tunnel 無法註冊，在 `cloudflared/config.yml` 加 `edge-ip-version: 4`。2026.10.3 有 linux/arm64 image。工作站無 Docker，`docker compose config --quiet` 與實際執行新版確認版本號留待 monitoring-prod 部署時執行；單一 replica，重建時連線中斷數秒，Alloy 會重送。

---

## 2026-10-14 — UnhandledException 跨 instance 加總

**改動摘要：** `UnhandledException` 改為 `sum without (instance, service)` 後再比較門檻，LinkCourt 改成兩個 API instance 後，分散在兩個 instance 的例外仍會觸發告警（同一 path／exc_type）。

**修改的檔案：**
- `prometheus/rules/app.yml` — expr 加總跨 instance，註解說明原因。
- `prometheus/rules/tests/unhandled-exception.test.yml`（新）— 兩個 instance 各 2 次會觸發；合計 3 次不觸發；labels 與 annotation 不變。

**原因/備註：** PPClub 後端並行計畫 S3b（PPClub PR #425）。其他 LinkCourt 規則原本就以 `sum by` 聚合，`SchedulerNoHeartbeat` 已於 SkyEye #50 改為 `max by`。驗證：SkyEye 主機以 `prom/prometheus:v2.54.1` 的 promtool 執行 `check rules` 與所有 rule test 檔。

---

## 2026-10-14 — SchedulerNoHeartbeat 跨 instance 取最新值

**改動摘要：** `SchedulerNoHeartbeat` 改為 `max by (product, server_id, exported_job)` 取各 instance 中最新的 heartbeat，讓 LinkCourt 拆出排程 process 後，不跑 job 的 process 不會誤報，任一 job 在所有 instance 都停一小時才告警。

**修改的檔案：**
- `prometheus/rules/deadman.yml` — expr 加上 `max by`，註解說明多 process 的情況。
- `prometheus/rules/tests/deadman.test.yml` — 新增：一個 instance 停、另一個持續更新時不告警；所有 instance 都停一小時後告警（labels 與 annotations 不變）。
- `runbooks/scheduler-dead.md` — Symptoms 改為新 expr，補上 :8090／:8091 兩個 instance 的說明。

**原因/備註：** LinkCourt 後端並行計畫 S2.8（PPClub PR #409）：排程拆成 `linkcourt-scheduler.service`（:8091）前，deadman 告警要能跨 instance 聚合。單一 process 時結果與舊規則相同。驗證：在 SkyEye 主機以 `prom/prometheus:v2.54.1` 的 promtool 執行 `check rules`（deadman、app）與四個 rule test 檔皆 SUCCESS；把 expr 改回舊規則時，新測試的第一個案例會失敗（:8090 的舊值觸發告警）。Prod02 Alloy 新增 :8091 抓取目標要等 production 切換時一起做（提前加會讓 `BackendDown` 因目標不存在而觸發）。

---

## 2026-10-13 — Trading probe config 路徑與 P&L history build-time 競態

**改動摘要：** 把 macOS trading 範本與 handoff 文件的 `TQ_CONFIG_PATH` 改為 tnauqquant 已改名的 `config/toobit-mexc.yaml`，並讓 `pnl-history.sh` 在掃完 raw logs 後重新取樣 build time，避免掃描期間剛完成的 cycle 被判為未來事件。

**修改的檔案：**
- `agents/alloy/trading/deployment.env.example`、`docs/trading-new-server-handoff.md` — `toobit-mexc.conf` → `toobit-mexc.yaml`。
- `agents/alloy/trading/pnl-history.sh` — 未設定 `TQ_PNL_HISTORY_NOW_SECONDS` 時，掃描後重新取 `date +%s` 作為 build time；lock stale 判斷仍使用起始時間。
- `tests/trading/test-pnl-history.sh` — 新增以 `date` shim 重現「build 起始早於 cycle、掃描後晚於 cycle」的回歸案例。

**原因/備註：** 2026-10-13 02:02 tnauqquant config 改名後，本機 probe 因 `config not found` 每分鐘失敗、不再產生 metrics；已就地修正 `/opt/homebrew/etc/alloy/config.env`（備份 `config.env.bak-20261013`），probe 恢復且所有 identity/binding 指標為 1。P&L history 的錯誤與 10/11 18:19:48 cycle 完成、18:19:51 錯誤寫入對齊，屬同一分鐘內自動恢復的競態，但會漏一次 build 並留下錯誤 log。驗證：`tests/trading/*.sh` 全數通過；以 origin/master 舊版 builder 執行新案例會重現 `future cycle timestamp exceeds build time`。

---

## 2026-10-13 — LinkCourt 401／429 暴增 shadow 告警

**改動摘要：** 新增 LinkCourt backend 401 總量、單一 handler 401 與單一 handler 429 暴增告警，沿用付款告警的 `product="ppclub"` selector、`severity=Medium` 與 shadow routing，並補 runbook 與 rule unit tests。

**修改的檔案：**
- `prometheus/rules/app.yml` — 新增 `LinkCourt401Surge`（15m > 500，for 10m）、`LinkCourt401SurgeByHandler`（每 handler 15m > 300，for 10m）、`LinkCourt429Surge`（每 handler 15m > 30，for 5m）。
- `prometheus/rules/tests/linkcourt-auth-surge-alerts.test.yml` — 以目前 slots 爬蟲節奏（每輪約 3 分鐘內 168 次 401、每 32 分鐘一輪）證明不觸發，並涵蓋單一 handler、分散 handler、429 與其他 product 隔離。
- `runbooks/linkcourt-auth-surge.md`、`runbooks/README.md`、`README.md` — 新增處置步驟（Prod02 `request_complete` 來源欄位、Cloudflare 規則）與 inventory。

**原因/備註：** 爬蟲 401 雖然日均僅約每 15 分鐘 50–80 次，但集中在每輪約 3 分鐘內，單一 15m 視窗峰值約 168，因此 per-handler 門檻不能用 150。門檻高於峰值；Cloudflare 擋下爬蟲後應於 canary review 依新基線下修。依專案規則先走 `notification_mode=shadow`，未部署 production。驗證：本機以官方 checksum 驗證過的 Prometheus 2.54.1 `promtool` 執行 `check rules`（7 檔皆 SUCCESS）與三個 rule test 檔（皆 SUCCESS）；mutation 檢查確認 per-handler 門檻改為 150 時 baseline 測試會失敗（峰值 168）。本機無 Docker，未跑 `docker compose config`／`amtool`（本次未改 compose 與 Alertmanager）。

---

## 2026-10-08 — 移除 Trading01 Ourbit Spot 監控

**改動摘要：** 依 operator 指示關閉 `trading01/ourbit-spot` 監控：移出中央 target inventory，停用該 lane 的 SkyEye probe timer，封存專用 env、Alloy fragment 與 textfile 並 reload Alloy。Robinhood、共用 collector、其他產品與歷史資料保留。

**修改的檔案：**
- `prometheus/rules/trading-targets.yml` — 移除 Ourbit target，inventory-based alerts／fleet 不再包含它。
- `prometheus/rules/tests/trading.test.yml`、`tests/trading/test-central-config.sh` — 剩一個 Trading01 target；保留 Ourbit 輸入 series 以證明退役後不再產生 telemetry-missing alert。
- `docs/project-brief.md` — 更新監控名單。

**原因/備註：** 沿用 2026-09-22 Mainnet 退役流程：中央規則先更新並 reload，再停用單一 probe、封存到 `/etc/skyeye-trading/retired/ourbit-spot-20261008/` 並 reload Alloy；不修改 shared collector、不重啟交易、不刪歷史時序或 Loki logs。驗證：central-config、incident taxonomy、dashboard JSON 本機通過；SkyEye host 上以 Prometheus 2.54.1 image 執行 `promtool check config`／`check rules`／兩個 rule test 檔皆 SUCCESS。`deployment-linux-ourbit.env.example` 保留。

---

## 2026-09-22 — 納入 Trading01 Ourbit Spot 監控

**改動摘要：** 將既有 Ourbit Spot 程序加入中央 inventory 與 Grafana 動態策略列表，透過獨立唯讀 probe／Loki fragment 採集，不改交易設定或重啟交易。

**修改的檔案：**
- `prometheus/rules/trading-targets.yml`、rule fixtures、central-config check — 加入 `trading01/ourbit-spot`，沿用 shadow 告警。
- `agents/alloy/trading/deployment-linux-ourbit.env.example` — 綁定 `ourbit-spot-btc` instance、專用 binary、config、manifest、raw-log glob 與 executor mapping；不含 credentials。
- `docs/project-brief.md` — 更新目前監控名單。

**原因/備註：** 使用既有 Linux installer 的 `--no-start` 安裝新 lane，驗證後 reload Alloy 並啟動 Ourbit probe timer。共用 collector 與 Robinhood 保持既有設定，已退役 Mainnet 不重新加入。central-config／dashboard JSON、Prometheus 2.54.1 config／rule tests、Compose、Alertmanager 與 combined Alloy config 驗證通過。Trading01 probe 首次執行 exit 0，process count、runtime contract、process／strategy／log binding 均為 1，已輸出 P&L 與 equity；共用設定與 Robinhood checksum 不變。

---

## 2026-09-22 — 移除 Trading01 Lighter Mainnet 監控

**改動摘要：** Mainnet 策略已停止且取消自動啟動，依 operator 指示移出中央 target inventory，停用該 lane 的 SkyEye probe timer/service，封存專用 env、Loki fragment 與 textfile。Robinhood、共用 collector、其他產品與歷史資料保留。

**修改的檔案：**
- `prometheus/rules/trading-targets.yml` — 移除 Mainnet target，讓 inventory-based alerts／fleet 不再包含它。
- `grafana/dashboards/Trading/trading-strategy-detail.json` — 策略選單使用即時 inventory query result，避免保留的歷史 series 讓已退役策略持續出現在選單。
- `tests/trading/test-central-config.sh`、Prometheus rule fixtures — 更新剩餘兩個 active targets，確認 Mainnet 不再有 telemetry-missing alert。
- `docs/project-brief.md` — 記錄退役範圍。

**原因/備註：** 中央規則先更新，再停止單一 probe、封存 metrics 並 reload Alloy；不修改 shared collector、不重啟交易、不刪歷史時序或 Loki logs。central-config／incident taxonomy、全部 dashboard JSON、Prometheus 2.54.1 config／rule tests、Compose 與 Alertmanager config 驗證通過；部署後另查 Prometheus 即時 inventory 與 Robinhood telemetry。

---

## 2026-09-14 14:46 — 統一 Trading 風控正常狀態配色

**改動摘要：** 策略詳情與策略總覽的風控回報「未回報停機」改為綠色，與其他正常狀態一致；「已觸發停機」維持紅色。

**修改的檔案：**

- `grafana/dashboards/Trading/trading-strategy-detail.json` — v8：risk=0 mapping 改綠色
- `grafana/dashboards/Trading/trading-strategy-fleet.json` — v4：相同風控 mapping 同步改綠色
- `docs/work-log.md` — 記錄驗證與部署範圍

**原因/備註：** central-config 與所有 dashboard JSON 檢查通過；semantic diff 確認兩份 JSON 各僅變更一個 color 與 version。摘要其他正常／事故狀態已分別為綠／紅，queries、未知／缺資料與 risk 指標語意不變。本機無 Docker/promtool；中央 production 的 Compose、Prometheus config/rules、Alertmanager config 以現有容器唯讀驗證。依使用者授權合併後以檔案 provisioning 部署，並核對 Grafana 實際載入的 model 與健康狀態；本次無可用 browser session，視覺像素未驗收。

---

## 2026-09-13 18:28 — 放大手機監控摘要並保留十項完整狀態

**改動摘要：** 將過矮的合併摘要改為較寬鬆的自動多列排列，固定 14px 標籤／20px 狀態數值，避免手機自動縮字。

**修改的檔案：**

- `grafana/dashboards/Trading/trading-strategy-detail.json` — v7：摘要高度 3→10 grid units，關閉 label/value 並排；後續 panels 下移七格，最近日誌仍在關鍵事件上方
- `tests/trading/test-central-config.sh` — 更新摘要高度、字級與自動排列契約
- `docs/superpowers/plans/2026-09-13-trading-mobile-summary.md` — 記錄手機重現、原生 Grafana 預覽與驗收

**原因/備註：** Grafana 11.2 的 Stat auto grid 在 390px 手機預覽把舊標籤縮到 4.3125px、數值縮到 10.2667px。使用同版本、僅綁 loopback 的隔離 Grafana 與 synthetic datasource frames，以既有 Chromium／Playwright 驗證 320／360／390／430／1280px：十個狀態在正常、重複程序、停機與四位數事故情境均無文字越界與 page errors；主文字為 14／20px，原生 K 後綴為 16px。8 格高候選在 320px 仍有風控文字越界，因此採 10 格高，桌面也會使用增加後的摘要高度。所有查詢、欄名、mappings、thresholds 與其他 panel 內容均未變；central-config、所有 dashboard JSON、semantic diff 與 diff check 通過。本機無 Docker/promtool，本次未修改 rules。使用者已確認 20–30 秒刷新等待恢復，依指示停止該項排查，未把恢復歸因於本次 UI 調整。

---

## 2026-09-13 17:59 — 交換 Trading 日誌順序並量測刷新延遲

**改動摘要：** 將最新策略日誌放到關鍵執行事件上方；針對手動刷新轉圈進行正式查詢延遲排查。

**修改的檔案：**

- `grafana/dashboards/Trading/trading-strategy-detail.json` — v6：日誌 id 12 移至 y=21，事件 id 13 移至 y=29；保留各自高度、100 行上限、查詢、時間範圍與 15s refresh
- `docs/superpowers/plans/2026-09-13-trading-log-order-refresh.md` — 記錄版面修改、診斷結果與部署驗證計畫
- `docs/work-log.md` — 記錄實測與尚未定位的瀏覽器端延遲

**原因/備註：** 三策略共 36 個 panel/datasource 請求耗時 0.004–0.212 秒；近 30m 約 3,000 次 datasource requests 全部 HTTP 200、histogram 均在 0.25 秒內，p99 約 0.088 秒，Loki range p99 約 0.049 秒。主機資源低負载，近期 Grafana error／slow request 與 Cloudflared error 未見異常；未登入的公開入口 redirect 實測 0.40 秒，不能推論已登入瀏覽器端的時間。沒有可用 browser session，仍需使用者轉圈當下的面板與 Network timing 才能定位，未宣稱慢速已修復，也未猜測調整查詢／刷新間隔。Central-config、所有 dashboard JSON 與 diff check 通過；semantic diff 證明各 panel 除兩個日誌 y 座標以外完全一致。本機沒有 Docker/promtool，本次未更動 rules 或 runtime。

---

## 2026-09-13 17:09 — 部署 Trading 摘要欄名與週期可讀性修正

**改動摘要：** 合併 PR #40，中央 checkout fast-forward 至 `6b8e927`，Grafana 自動載入策略詳情 v5。

**修改的檔案：**

- `grafana/dashboards/Trading/trading-strategy-detail.json` — production 與 Git 的 SHA-256 均為 `a65aefdd3391813d6872167f96cadbf59fc99999918126b6819778c3c2b6d3d0`；Grafana DB panels 與 provisioning source 完全一致
- `docs/work-log.md` — 記錄部署與正式資料驗證

**原因/備註：** 三個策略共 39 個摘要／週期／餘額 datasource queries 無錯誤；每個策略皆有十個 numeric 狀態，週期與餘額結果和相同時間的直接 Prometheus query 一致。兩個 Lighter 策略週期／餘額均有數字；Toobit/MEXC 的週期與餘額來源缺資料，部署前採樣與 offset query 已確認缺值，保留既有等待提示。再以部署後 Grafana model、實際 frames 與 upstream v11.2.0 converter 驗證十項正式顯示名稱、事故 thresholds，以及週期全寬兩列／16px labels／24px values。Grafana DB healthy；probe／Prometheus／Loki rules／Compose checksums 未變，三個中央 container start time 未變，未操作 Trading process。Central-config、dashboard JSON、diff check 通過；本機沒有 Docker/promtool，本次未改 rules；browser session 不可用，未做像素級驗收。

---

## 2026-09-13 17:00 — 修正 Trading 摘要預設欄名並放大週期資訊

**改動摘要：** 將監控摘要固定為十項具名狀態，消除 Value／G／H／I／J 預設欄名；最近完成週期改為上下兩列並放大字體。

**修改的檔案：**

- `grafana/dashboards/Trading/trading-strategy-detail.json` — v5：summary 以 refId 固定中文 displayName 並保留 mappings／thresholds；週期面板改為 7 格寬、16px label／24px value，完整時間格式保留
- `tests/trading/test-central-config.sh` — 更新 refId 命名、字級、排列與無重疊版面契約
- `docs/work-log.md` — 記錄 Grafana 11.2 frontend 轉換根因與驗證

**原因/備註：** 正式 API 已回傳正確中文 alias，但 Grafana 11.2 的 Loki `makeTableFrames` 會重建 instant numeric fields 為 `Value #G` 等名稱並丟棄 displayNameFromDS。使用實際正式回應與 upstream v11.2.0 converter 重現四項預設名稱，候選設定十項 numeric displays 的中文名稱全部正確、數值與事故 thresholds 保持一致。保留 numeric-only reduction，避免 Time 欄被顯示為多餘 stat。週期面板原本左右分欄會壓縮長時間字串，改用兩個全寬橫列；餘額讓出兩格寬度，查詢與其他 panels 內容不變。Central-config、全部 dashboard JSON 與 diff check 通過；browser session 不可用，未聲稱完成像素級畫面驗收。此修正只更新 Grafana JSON，不需變更或 reload probe、Prometheus/Loki rules 或 Trading process。

---

## 2026-09-13 16:24 — 合併 Trading 狀態列並新增目前餘額

**改動摘要：** 將策略詳情的四項執行事故併入緊湊監控摘要，損益組成保留實現損益／現金損益／返佣，新增目前策略的單一總餘額。

**修改的檔案：**

- `grafana/dashboards/Trading/trading-strategy-detail.json` — v4：第一列新增目前餘額，十項狀態合併到三格高的 Mixed stat panel，移除顯示的風控損益
- `agents/alloy/trading/probe.sh`、`prometheus/rules/trading.yml` — 將最新穩定 `pnl_status.equity_now` 輸出為 inventory-scoped 總權益；producer 已加總所有 executor，不在 Grafana 二次加總
- `tests/trading/test-probe.sh`、`test-central-config.sh`、`prometheus/rules/tests/trading.test.yml` — 驗證單／雙交易所、零值、缺值、無效值、unstable sample、inventory 隔離、mixed datasource 與版面
- `docs/superpowers/specs/2026-09-13-trading-dashboard-summary-balance-design.md`、`docs/superpowers/plans/2026-09-13-trading-dashboard-summary-balance.md`、`docs/project-brief.md` — 記錄設計、執行計畫與最新介面

**原因/備註：** 餘額為最近穩定快照的總帳戶權益（USDT），並非即時可用保證金；缺資料時顯示等待。Probe regression 先確認新指標缺失而失敗，再通過所有案例；central-config、log-pipeline（含 Alloy validate／plutil）、全部 dashboard JSON 與 diff check 通過。使用 SkyEye 隔離暫存檔執行候選 Compose config、Prometheus 2.54.1 config／rule unit tests（41 條 Trading rules）成功，既有 Alertmanager 0.27 config 檢查成功。三個 production targets 的 12 個候選 Loki 事故查詢皆回傳單一數字；在 macmini-m2 與 Trading01 以候選 probe 讀取三個策略的實際 manifest-bound logs、輸出到獨立暫存 textfile，各取得一筆有效餘額。未部署或 reload 正式服務、未更動 Trading process；本次無可用 browser session，尚未做實際畫面驗收。

---

## 2026-09-04 02:55 — 新增 Trading01 雙 Lighter process 監控

**改動摘要：** 將 Linux Trading probe 與 Loki source 改為 per-strategy instance，共用單一 textfile collector，並新增可回復的 singleton migration 及 Mainnet shadow inventory。

**修改的檔案：**

- `agents/alloy/trading/` — 新增兩份 credential-free env 範例、`skyeye-trading-probe@` units、獨立 metrics basename、shared metrics/per-strategy Loki fragments 與 exact-file rollback record
- `tests/trading/test-probe.sh`、`tests/trading/test-linux-setup.sh` — 證明兩個 output 共存、sibling preservation、legacy timer disable、validation failure rollback 與 shared-update quiescence
- `prometheus/rules/trading-targets.yml`、`prometheus/rules/tests/trading.test.yml` — 新增 `trading01/lighter-mainnet-btc-canary` shadow target，quote 為 USDT 且不宣告 history capability
- `AGENTS.md`、`docs/project-brief.md`、`docs/trading-new-server-handoff.md` — 記錄同 server 雙策略監控與 Mainnet 不由監控安裝器啟動的契約

**原因/備註：** 本次尚未部署或 reload production。Herdr code review 後另修正 per-instance binary 的 before/after process census、要求 test-root 使用 root 內非 symlink 的 fake `systemctl`，並覆蓋 `--no-start` inertness、started install／restart rollback；central test 也會在 Docker 或 native promtool 可用時實際執行 rule tests。全部 Trading shell regressions、ShellCheck、native Alloy combined-config validation、dashboard JSON 與 YAML parse 均通過；本機沒有 Docker/promtool/amtool，因此 Prometheus container checks 仍留待 publication gate。

---

## 2026-09-01 19:33 — 部署 Trading incident observability 並修復 Linux log ACL

**改動摘要：** 合併並部署 PR #34 的 incident-first dashboards、shadow rules 與 execution identifier scrub；production canary 另發現 Trading01 新 raw logs 的 mode-`0600` ACL 缺口，先恢復 ingest，再以 PR #35 加入持續修補 named Alloy read ACL 的 helper。

**修改的檔案：**

- `agents/alloy/trading/config-*.alloy.tmpl` — macmini-m2 與 Trading01 已載入 execution identifier scrub；兩端 Alloy ready，未 scrubbed identifiers 為 0，Loki 實際收到 `[EXECUTION_REF]`
- `prometheus/rules/trading.yml`、`loki/rules/fake/tnauqquant.yml` — monitoring-prod fast-forward 到 PR #34 merge commit `478ac74`，Prometheus 以 lifecycle API reload，Loki ruler 自動載入；新規則 health 為 ok 且仍為 shadow
- `grafana/dashboards/Trading/` — provisioning 將 detail／fleet 更新為 v3，並從 Grafana DB 刪除 `Trading · 即時營運`
- `agents/alloy/trading/ensure-log-access.sh`、`setup-linux.sh`、`skyeye-trading-probe.service.tmpl` — PR #35 merge commit `c236698`；每次 Linux probe 前只對設定 glob 內缺少有效權限的 raw logs 補 named `alloy:r--` ACL
- `docs/work-log.md` — 記錄 PR #34／#35 production rollout、ACL 根因與 canary

**原因/備註：** PR #34 rollout 時，Trading01 Alloy restart 揭露新 run logs 雖有 directory traverse ACL，檔案本身仍為 `0600`，導致 Loki 至少一小時沒有該主機 logs。即時 remediation 只改 29 個設定檔案的 ACL、未改內容，中央隨即在兩分鐘窗收到 11 筆 logs；永久 helper 已以 `--no-start` 部署，29/29 可讀且 ExecStartPre 成功，沒有再次重啟 Alloy。最終兩個策略的 process/runtime contract/runtime binding/config snapshot 均為 1，probe age 約 14–27 秒；近兩分鐘未 scrubbed execution identifiers 為 0、10 分鐘 `[EXECUTION_REF]` 為 4，6 小時事故 query 正確找到 `tnauqquant-prod-1` 的 18 筆事件。Grafana、Loki、Prometheus 自 merge 起 error 皆為 0，rule evaluation failures 為 0；唯一 active Trading alert 仍是部署前既有的 `TradingPnlTelemetryStale` shadow。兩臺 Trading process count 部署前後皆為 1，交易 config／manifest checksum 未變，未啟停或修改 Trading process；Trading01 checkout 既有的 `docs/code-patterns/go.md` 未提交修改保持原狀。

---

## 2026-09-01 19:03 — 移除 Trading 即時營運 dashboard

**改動摘要：** 依 owner 指示刪除 provisioned `Trading · 即時營運` dashboard，Trading Grafana 介面只保留通用的策略詳情與策略總覽。

**修改的檔案：**

- `grafana/dashboards/Trading/tnauqquant-trading-overview.json` — 從 Git provisioning source 刪除；provider 的 `disableDeletion=false` 會在後續部署時同步移除 Grafana DB dashboard
- `tests/trading/test-central-config.sh` — 改為明確要求該檔案與 UID/title 均不存在，並繼續驗證 detail/fleet、rules 與 layout contracts
- `docs/grafana-conventions.md`、`docs/project-brief.md` — 從現行 dashboard inventory 與專案狀態移除即時營運頁面

**原因/備註：** Prometheus/Loki rules、Alloy scrub、P&L history metrics、Trading 策略詳情與策略總覽不受影響。此次只更新 PR，未直接操作或重載 production Grafana。

---

## 2026-09-01 18:09 — 實作 Trading incident-first dashboard 與 shadow rules

**改動摘要：** 將三張 Trading dashboard 改為事故優先，新增高信心 execution incident taxonomy、runtime-contract-missing Prometheus 告警與 execution identifier source-side scrub，並以去識別化 fixture 固定正常 unresolved 與事故事件的邊界。

**修改的檔案：**

- `grafana/dashboards/Trading/` — 頂端新增近 15 分鐘 Loki 事故狀態、6 小時關鍵事件，並拆分 Runtime Contract、執行綁定與 Config 快照；fleet 分開顯示 Prometheus shadow 與 Loki execution incidents
- `loki/rules/fake/tnauqquant.yml`、`prometheus/rules/trading.yml` — 新增 `TradingExecutionIncident`、`TradingRuntimeContractMissing` 與分離後的 recording rules；generic Loki fallback 支援 `ERROR+N`／`FATAL+N` 並排除專用 taxonomy
- `agents/alloy/trading/` — macOS/Linux 在 Loki sink 前 scrub `grant_id`、`mutation_id`、`mutations`、`account` 為 `[EXECUTION_REF]`
- `tests/fixtures/tnauqquant/`、`tests/trading/`、`prometheus/rules/tests/trading.test.yml` — 新增完全 synthetic 的 incident fixture/checksum、taxonomy、scrub、rule、dashboard datasource/layout contracts
- `runbooks/trading-critical-safety-state.md`、`docs/project-brief.md` — 記錄 execution reconciliation、runtime contract 與 rollout 語意

**原因/備註：** 正常的 `disposition=unresolved ui_submission_status=accepted` 不會單獨觸發事故；只有 allowlist 中的 fence stalled、人工復原、single-legged shutdown 與 unresolved fence preservation 會進入專用事件。所有新舊 Trading alerts 仍為 `notification_mode=shadow`，本次只建立 Git PR，未部署、reload 或重啟 production。完整 Trading regression、Prometheus 2.54.1 rules/unit tests、Loki 3.1.1 dry-run lint、Alloy validate、launchd plist、dashboard JSON/layout 與 Alertmanager 0.27 config 驗證皆通過。

---

## 2026-09-01 17:39 — 評估 Trading 成交確認異常監控缺口

**改動摘要：** 唯讀比對 `tnauqquant-prod-1` 異常 run、中央 Loki／Prometheus／Alertmanager 與 production Grafana 設定，確認資料已完整送達但嚴重事件未被 dashboard 凸顯，且所有 Trading 告警仍由 shadow route 丟棄通知。

**修改的檔案：**

- `docs/work-log.md` — 記錄本次事故訊號、監控缺口與建議 rollout 邊界

**原因/備註：** `20260901_112459_toobit-mexc` 在 16:24 後進入 reconcile／fence recovery，產生 14 筆 `coordinator_fence_stalled`、167 筆 fenced-signal skipped，結束時保留 unresolved fence 與 single-legged portfolio；17:17 新 run 再因 `mexcui_recovery_required` 拒絕啟動。Loki 收到 22 筆 `ERROR` 與 1 筆 `ERROR+4`，但 generic rule 只匹配前者且所有規則仍為 shadow；主要 dashboard 僅顯示未篩選的最新五筆 log，fleet 的 shadow alert count 又只讀 Prometheus `ALERTS`，看不到 Loki ruler alerts。建議另案實作 incident-first banner、critical event timeline、Alertmanager/Loki visibility、特定高信心 message taxonomy、runtime-contract-missing alert 與 source-side correlation ID scrub，經 fixture、shadow 與 canary 後才升級通知。本次未修改或重啟 Alloy、Trading、Grafana、Loki、Prometheus 或 Alertmanager。

---

## 2026-08-28 17:19 — 部署 PnL-first Trading dashboards 與 history health

**改動摘要：** 合併 PR #32，將繁中 PnL-first Trading dashboards、180 秒 telemetry freshness、history-capability shadow alert 與無假零點的 accumulated PnL builder 部署到 production。

**修改的檔案：**

- `agents/alloy/trading/pnl-history.sh` — 在 `tnauqquant-prod-1` 先 render／validate，再只替換獨立 history script；未重載 Alloy、probe 或 trading process
- `prometheus/rules/trading*.yml` — monitoring-prod fast-forward 到 merge commit `a6e636f`，通過 promtool 後以 lifecycle API reload，未重啟 Prometheus
- `grafana/dashboards/Trading/` — 既有 provider 無重啟載入 `Trading · 即時營運` v15、`Trading · 策略詳情` v2 與 `Trading · 策略總覽` v2
- `docs/work-log.md` — 記錄 PR #32、來源端與中央端 production canary

**原因/備註：** History LaunchAgent 連續三輪 exit 0、stderr 0，中央收到 49 組對齊的 value/timestamp points、最新 accumulated Real PnL `1827.7101 USDT`、43 筆 legacy skipped records，且 `node_textfile_scrape_error=0`。Grafana provisioning error 與最近 10 分鐘 error 均為 0，Prometheus rule evaluation failures 為 0；Grafana 與 Prometheus container start time 均未改變。Fleet canary 為 2 個 targets、stale 0、process mismatch 0；當下 2 個 active shadow alerts 皆來自 `tnauqquant-prod-1` 的既有 `risk_halt` 狀態（`TradingCriticalSafetyState`、`TradingRiskStopped`），新 `TradingTelemetryMissing` 與 `TradingPnlHistoryUnavailable` 均 inactive。部署前後 matching trading process 都是 0，未啟停、signal、attach 或修改 trading process。

---

## 2026-08-28 15:53 — Trading dashboard PnL-first 與健康狀態可讀性

**改動摘要：** 將三個 Trading dashboards 改為繁中、PnL-first 版面，正常健康訊號收進緊湊摘要；同時修正凍結 telemetry 偵測、history capability 告警與歷史 coverage 起點語意。

**修改的檔案：**

- `grafana/dashboards/Trading/` — 即時營運、策略詳情與策略總覽重新排序、縮小狀態區塊、加入 exact process 語意與每策略 shadow alert 數
- `agents/alloy/trading/pnl-history.sh` — 輸出最新 bounded accumulated value，且第一筆 authoritative event 前不補零
- `prometheus/rules/trading*.yml` — inventory 加入 history capability，telemetry freshness 統一為 180 秒，新增 history unavailable Medium shadow alert
- `tests/trading/`、`prometheus/rules/tests/trading.test.yml` — 固定 dashboard contracts、history coverage 與 absent/frozen/invalid alert cases
- `docs/`、`runbooks/` — 同步 dashboard、metric、alert 與 recovery contract

**原因/備註：** Fleet 的健康基準由 owner 核准為 monitored strategies=2（中性）、stale=0、process mismatch=0、shadow alerts=0；異常從 1 起標色。此次完成 Git 內實作與隔離驗證，不部署、不重啟 Grafana、Alloy 或 trading process。

---

## 2026-08-28 00:02 — 部署跨 round accumulated Real P&L 並完成 Grafana canary

**改動摘要：** 合併 PR #30，將獨立的 macOS P&L history LaunchAgent 部署到 `tnauqquant-prod-1`，並讓中央 Grafana provisioning 載入 30 天跨 run／跨日 accumulated Real P&L Timeseries 與 coverage panel。

**修改的檔案：**

- `agents/alloy/trading/` — production 私有 `config.env` 補入 30 日 cache／point bounds；先 render 與 `--no-start` 驗證，再單獨 bootstrap `com.wanbrain.skyeye-trading-pnl-history`
- `grafana/dashboards/Trading/tnauqquant-trading-overview.json` — monitoring-prod fast-forward 到 merge commit `ed9d774`，由既有 provider 無重啟載入 dashboard version 14
- `docs/work-log.md` — 記錄 source-host、Prometheus、Grafana 與日界線 canary

**原因/備註：** History job 連續 6 次 exit 0、stderr 0 行，cache／metrics 權限為 `0700`／`0600`，中央 `node_textfile_scrape_error=0`。首次日內輸出為 84 組對齊且時間單調的 value/timestamp points；跨過 Asia/Taipei 零點後自動收斂為 30 個 daily-boundary points，最後一點位於 `2026-08-28 00:00:00`，並承接前一日相同 accumulated Real P&L `2154.2912 USDT`。Cache 當時保留 386 個 authoritative cycles，另揭露 43 筆 legacy skipped records；第一筆完整 contract event 為 `2026-08-07 11:00:44`。Alloy PID 維持 `72385`、Grafana container start time維持 `2026-08-27T12:00:36Z`，既有 probe run start 保持 `1787816200`，未啟停或修改 trading process。Prometheus／Alertmanager config、所有 dashboard JSON 均通過 production container 驗證；Grafana 近 20 分鐘 error 與 provisioning error 均為 0。外部固定 URL 已正確導向 Cloudflare Access。

---

## 2026-08-27 20:13 — 納管 Trading01 並建立多策略 Trading dashboards

**改動摘要：** 將 Trading01 的單交易所 Lighter／Robinhood 策略接入既有 SkyEye，新增跨 server 的策略 inventory、recording rules、shadow alerts、fleet／detail dashboards，並修復 Linux probe textfile 目錄權限問題後完成 production 驗收。

**修改的檔案：**

- `agents/alloy/trading/` — 泛化 executor mapping、單／雙交易所 metrics、source-side correlation ID scrub，新增 Linux Alloy coexistence fragment、systemd installer 與可存取的 `/var/lib/skyeye-trading/textfile` 預設值
- `prometheus/rules/trading-targets.yml`、`prometheus/rules/trading.yml`、`prometheus/rules/tests/trading.test.yml` — 新增 Trading01 inventory、27 條多策略 recording rules、9 條 generic shadow alerts 與 rule tests
- `loki/rules/fake/tnauqquant.yml` — 將 Trading log alerts 泛化為 product／environment selectors 並維持 shadow routing
- `grafana/dashboards/Trading/trading-strategy-fleet.json`、`grafana/dashboards/Trading/trading-strategy-detail.json` — 新增每策略一列的 fleet dashboard 與 server／strategy detail dashboard
- `tests/trading/` — 固定單交易所 probe、Linux 共存部署、scrub、dashboard 與中央規則 contract
- `docs/`、`agents/alloy/trading/README.md` — 記錄跨 server contract、部署手冊、設計／implementation plan 與 production 驗收
- `docs/work-log.md` — 記錄 PR #27、hotfix PR #28 與端到端 rollout 結果

**原因/備註：** PR #27（`a69bce2`）與 textfile hotfix PR #28（`521ffba`）已合併部署。Trading01 Alloy 1.16 與既有 ZenIncome pipeline 共存，兩條 ZenIncome `up` 仍為 `1`；probe timer 與 oneshot service 正常，metrics file 為 `ubuntu:alloy` mode `0640`。中央收到 current-run Real P&L `1.4083 USDT`、195 cycles、Lighter volume `68,610.97 USD`、net position `0 BTC`，Loki 已收到 logs；實體 repo path、order/client/attempt/reservation IDs 均為 0 命中，scrub placeholders 有命中。Grafana 11.2 database health 為 ok，兩個 dashboard UID 均已 provision，啟動後 error 為 0；本次 session 沒有可用的 in-app browser，未能截取正式畫面。Trading01 本來就沒有 `quant` PID，但 manifest 仍標示 running，因此 `TradingProcessDown` 正確 firing 且 `notification_mode=shadow`；未修改／重啟 trading process，tmux pane PID、config 與 manifest checksum 均維持不變。

---

## 2026-08-27 19:06 — 建立跨 round 的 30 天 accumulated Real P&L

**改動摘要：** 新增與 15 秒 safety probe 隔離的每分鐘歷史 builder，以 per-run cache 加總 authoritative completed-cycle delta，並將 Grafana 主圖改成跨 run、跨日連續的真實時間階梯圖。

**修改的檔案：**

- `agents/alloy/trading/pnl-history.sh`、`com.wanbrain.skyeye-trading-pnl-history.plist.tmpl` — 只重掃變更過的 raw logs，保留輪替後摘要，以 atomic bounded metrics 輸出 history value、timestamp 與 coverage
- `agents/alloy/trading/setup-macos.sh`、`deployment.env.example`、`README.md` — 安裝、驗證並說明獨立 60 秒 launchd job 與 mode-`0700` cache
- `grafana/dashboards/Trading/tnauqquant-trading-overview.json` — 以 `point` join P&L／timestamp，轉為 Timeseries `stepAfter`，新增 build age、coverage start 與 skipped legacy 顯示
- `tests/trading/test-pnl-history.sh`、`test-log-pipeline.sh`、`test-central-config.sh` — 固定跨 round／跨日基線、去重、cache reuse、rotation retention、conflict/bound fail-closed 與 dashboard contract
- `docs/trading-accumulated-pnl-development-plan.md`、Trading contract 文件與 `project-brief.md` — 記錄 owner 決議、資料語意與部署界線

**原因/備註：** `real_pnl_usdt` 是 session cumulative，跨 round 不能直接相加；history 只加總 rebate-adjusted `cycle_real_pnl_usdt`。舊 completed-looking record 缺 `cycle_id` 或 delta 時不猜測，改由 coverage start 與 skipped count 明示。以正式 raw-log glob、隔離 temp cache 做唯讀 smoke test時，首次掃描 67 個約 33.8 MB logs 為 5.71 秒，第二次全 cache 命中為 0.82 秒；辨識 382 個 authoritative cycles、排除 43 個 legacy records。Herdr code review 另發現 hard kill／reboot 殘留 lock 可能永久卡住 job，已補上 10 分鐘 stale-lock recovery、fresh-lock mutual exclusion 測試，並將 Prometheus metric families 改為 canonical grouped output。這次只完成 Git 中的實作與驗證，不部署、不操作真實 trading process。

---

## 2026-08-12 16:20 — Config drift 時保留 Trading P&L telemetry

**改動摘要：** 將 runtime manifest 的 config snapshot 比對改為獨立可觀測信號；目前執行中的 PID、executable、instance 與 log binding 仍有效時，即使 config 檔案在 run 中被改動，probe 仍持續輸出該 run 的 P&L、cycle、position 與 log telemetry。

**修改的檔案：**

- `agents/alloy/trading/probe.sh` — 從 manifest validity gate 拆出 config hash 比對，新增 `tnauqquant_config_snapshot_match`
- `tests/trading/test-probe.sh` — 新增 config drift fixture，確認 drift 時 P&L 與 bound log telemetry 不會消失
- `prometheus/rules/trading.yml` — 將 config snapshot drift 納入 production binding shadow alert
- `prometheus/rules/tests/trading.test.yml` — 固定 config drift 的 alert contract
- `runbooks/trading-critical-safety-state.md` — 補充 config drift 判讀與處理方式
- `docs/trading-monitoring-development-plan.md` — 更新 runtime identity/binding 指標與狀態表
- `docs/project-brief.md` — 記錄 config drift 不解除 current-run log binding 的架構決策
- `docs/work-log.md` — 記錄 P&L `Err` 根因、修復與 production 驗收

**原因/備註：** 目前 run 的 config 檔於 `2026-08-12 15:54:58` 被改動，SHA-256 因而與啟動時 immutable manifest snapshot 不同；舊 probe 將整份 manifest 判為無效，停止輸出 cycle P&L，Grafana XY 因沒有資料而顯示 `Err`。PR #25（`5f62497`）已部署；Grafana datasource 驗收回傳 Cycle 1–18，最新累積 P&L 為 `282.889`，dashboard provisioning version 仍為 13，Grafana 近 10 分鐘無 error。`tnauqquant_config_snapshot_match=0` 正確保留為 shadow binding alert，沒有覆寫 manifest 或 config。Trading PID 仍為 `11834`、啟動時間仍是 `2026-08-12 03:13:47`，未修改或重啟 Trading process。

---

## 2026-08-12 13:56 — 將 Trading P&L 圖調整為 X=Cycle、Y=P&L

**改動摘要：** 依 owner 更正交換 P&L XY 圖的欄位順序，改為 X 軸 Cycle、Y 軸累積 Real P&L。

**修改的檔案：**

- `grafana/dashboards/Trading/tnauqquant-trading-overview.json` — 將 transformed table 固定為 Cycle 第一、P&L 第二，並同步更新 dashboard 與 panel 說明
- `tests/trading/test-central-config.sh` — 固定 X=Cycle、Y=P&L 的 field order 與軸語意 contract
- `docs/work-log.md` — 記錄軸向更正與 production 驗收

**原因/備註：** PR #23（`e307888`）已部署，Grafana provisioning database 為 version 13，production JSON 的 field order 為 `cycle=0`、`Value=1`，並依 Cycle 升冪連線。Grafana 近 10 分鐘 error 為 0；Trading PID 仍為 `11834`、啟動時間仍是 `2026-08-12 03:13:47`，未修改或重啟 Trading process。

---

## 2026-08-12 13:53 — 修正 Trading P&L 的 Prometheus table 欄位流程

**改動摘要：** 讓 Grafana XY 直接使用 Prometheus table 已合併完成的 `Value` 與 `cycle` 欄位，移除會丟失 cycle 的重複 Reduce。

**修改的檔案：**

- `grafana/dashboards/Trading/tnauqquant-trading-overview.json` — 將 P&L transformation 收斂為 Organize、Convert field type、Sort；把 `Value` 改名為累積 Real P&L、把 `cycle` 轉為數字並依 cycle 排序
- `tests/trading/test-central-config.sh` — 固定 Prometheus table 的 `Value`／`cycle` input contract，並禁止重新加入多餘的 Reduce
- `docs/work-log.md` — 記錄 Grafana 11.2 browser-side result transformer 根因與 production 驗收

**原因/備註：** Grafana Prometheus `format: table` 會先在瀏覽器端把 backend multi-frames 合成含 `Time`、labels、`Value` 的單一 table；先前再次 Reduce 會把欄位壓成 reducer rows，使 `cycle` 消失，XY 因只剩一個 numeric field 而顯示內建 `Err`。PR #21（`0e4468d`）已部署，Grafana provisioning database 為 version 12，正式 table 重建結果包含 Cycle 1–8，最新累積 P&L 為 `154.4897`。Grafana 近 10 分鐘 error 為 0；Trading PID 仍為 `11834`、啟動時間仍是 `2026-08-12 03:13:47`，probe error lines 為 0，未修改或重啟 Trading process。

---

## 2026-08-12 13:36 — 修復 Grafana 11 Trading XY 與標示持倉方向

**改動摘要：** 將 Trading P&L 面板改為 Grafana 11.2 XY Chart v2 與單一 reduced DataFrame，並以文字及顏色清楚標示兩間交易所的 LONG／SHORT／FLAT 持倉。

**修改的檔案：**

- `grafana/dashboards/Trading/tnauqquant-trading-overview.json` — 移除 legacy XY options，改用 v2 series schema；以 Reduce series-to-rows 產生依 cycle 排序的 P&L XY 資料；positions 保留 signed BTC 數字並加入綠色 LONG、紅色 SHORT、灰色 FLAT 與依正負著色的 NET
- `tests/trading/test-central-config.sh` — 固定 Grafana 11.2 options、reduced DataFrame、auto XY mapping、side-specific queries 與方向色彩 contract
- `docs/work-log.md` — 記錄 mobile Safari 錯誤根因、hotfix 與 production 安全驗收

**原因/備註：** PR #18（`89f5c09`）修復 legacy `name` 字串使 XY v2 在 mobile Safari 呼叫 `.split()` 崩潰的問題；PR #19（`2539ad3`）再修復 manual series 無匹配資料時元件只顯示 `Err` 的問題。Grafana provisioning database 已更新為 version 11，P&L query 回傳 Cycle 1–7；正式 position snapshot 為 Toobit LONG `1.262 BTC`、MEXC SHORT `1.262 BTC`。過去 15 分鐘 Grafana error 為 0，Trading PID 仍為 `11834`、啟動時間仍是 `2026-08-12 03:13:47`，probe exit code 與 error lines 均為 0；未修改或重啟 Trading process。

---

## 2026-08-12 13:04 — 修復 Trading XY P&L DataFrame 合併

**改動摘要：** 修正 Grafana instant table 將每個 cycle 拆成獨立 DataFrame，導致 XY panel 只讀 frame 0、無法呈現完整折線的問題。

**修改的檔案：**

- `grafana/dashboards/Trading/tnauqquant-trading-overview.json` — 依序使用 Labels to fields、Merge、Organize、Convert field type 與 Sort，把 `cycle` label 和 P&L 合併成單一有序 XY table
- `tests/trading/test-central-config.sh` — 固定五段 transformation、來源 metric 欄位改名、Cycle 數值轉換與排序 contract
- `docs/work-log.md` — 記錄 production 根因、修正與安全驗收

**原因/備註：** PR #16（`03baf58`）已合併部署，Grafana provisioning database 為 version 9，正式 panel 設定為 `labelsToFields → merge → organize → convertFieldType → sortBy`，X=`Cumulative Real P&L`、Y=`Cycle`。Production 已收到 Cycle 1–7，累積 P&L 依序為 `82.4097`、`52.0618`、`48.6446`、`47.1045`、`9.3863`、`64.3121`、`88.0269`；Grafana recent error 為 0。Trading PID 部署前後皆為 `11834`，啟動時間與 config／manifest／probe checksum 未變，probe error 為 0。本次 session 無可用的 in-app browser，畫面由使用者重新整理後驗收。

---

## 2026-08-12 12:31 — Trading XY P&L 與雙交易所 Volume

**改動摘要：** 將 current-run completed-cycle P&L 改為真正的 Grafana XY 折線圖，並新增 Toobit／MEXC 分別累積的 current-run 成交額。

**修改的檔案：**

- `agents/alloy/trading/probe.sh` — 從 manifest-bound current log 的實際 `trade_status` 記錄，依 `executor` 加總 `volume_usd` 並輸出 bounded exchange metric
- `grafana/dashboards/Trading/tnauqquant-trading-overview.json` — 使用 native `xychart` 以 X=累積 Real P&L、Y=Cycle 顯示連線與資料點，新增雙交易所 Volume stat panel，保留 positions、recent logs 與底部 status
- `tests/trading/test-probe.sh`、`tests/trading/test-central-config.sh` — 固定成交紀錄篩選、雙交易所 volume、XY 軸向、transform 與 dashboard layout contract
- `docs/project-brief.md`、`docs/work-log.md` — 更新 Trading dashboard 現況與本次部署驗收紀錄

**原因/備註：** PR #14（`2e82a91`）已合併部署，Grafana provisioning database 為 version 8。Production XY 點為 `(82.4097, 1)`、`(52.0618, 2)`、`(48.6446, 3)`、`(47.1045, 4)`、`(9.3863, 5)`，Prometheus 收到 Toobit `1,201,012.98 USD` 與 MEXC `1,200,952.65 USD`；Volume 僅加總有 `volume_usd` 的 Toobit／MEXC `trade_status`，排除 skipped signal、settlement-only 與未知 executor。Trading PID 部署前後皆為 `11834`，啟動時間與 config／manifest checksum 未變，probe error 與 Grafana recent error 均為 0。In-app browser 本次仍無可用 browser session，實際畫面需由使用者重新整理後驗收。

---

## 2026-08-12 12:11 — Trading cycle P&L、recent logs 與 process status

**改動摘要：** 將 Trading dashboard 收斂為 current-run cycle 累積 Real P&L 橫向圖、signed positions、最新五行 log、log freshness 與 RUNNING／SHUTDOWN 狀態，並修正 macOS UTC `Z` 時間解析。

**修改的檔案：**

- `agents/alloy/trading/probe.sh` — 從 current manifest 綁定 log 去重輸出每個 completed cycle 的累積 Real P&L，並以 UTC 正確解析 `Z` timestamp
- `grafana/dashboards/Trading/tnauqquant-trading-overview.json` — 以 Y=cycle、X=cumulative Real P&L 的 horizontal bar gauge 呈現，合併三個 signed position 數值，新增最新五行 log 與底部 process status
- `tests/trading/test-probe.sh`、`tests/trading/test-central-config.sh` — 固定 cycle 去重、UTC epoch、bar gauge 軸向、status mapping 與 production selector contract
- `docs/project-brief.md`、`docs/work-log.md` — 更新 Trading dashboard production 現況與部署紀錄

**原因/備註：** PR #11（`9382287`）與 PR #12（`a243aeb`）已合併部署，Grafana provisioning database 為 version 7。舊的 `182.8703` Max 來自前一個 run，且 UTC `Z` 曾因本機時區被算早 8 小時；新圖直接取 current log 的 completed cycles，production 值為 Cycle 1 `82.4097`、Cycle 2 `52.0618`、Cycle 3 `48.6446`。Status 為 RUNNING，最新 log 查詢回 5 行，最終 position 為 Toobit `+0.1519 BTC`、MEXC `-0.1519 BTC`、NET `0 BTC`。部署前後 Trading PID 皆為 `11834`，啟動時間、config 與 manifest checksum 未變，probe error 與 Grafana recent error 皆為 0；entry price 仍因沒有兩交易所確認的 average fill 欄位而不顯示。本次 session 無可用的 in-app browser，畫面驗收由使用者端完成。

---

## 2026-08-12 11:32 — 修復 Trading stat 數值未顯示

**改動摘要：** 將四張 Trading stat panels 的無效 Grafana color mode `fixedColor` 修正為 `fixed`，恢復 Cycle、Log Update、Toobit 與 MEXC 數值呈現。

**修改的檔案：**
- `grafana/dashboards/Trading/tnauqquant-trading-overview.json` — 修正四張 stat panels 的 fixed color mode
- `tests/trading/test-central-config.sh` — 新增 Grafana 合法 color mode 與 fixed color contract

**原因/備註：** PR #9 於 `1516913` 合併並部署；Grafana provisioning database 已更新為 version 5。Production 7 個 panel queries 均各回傳一個 series：Real P&L `48.6446`、最後 cycle `-3.4173`、今日 cycles `3`、Toobit `long 2.084 BTC`、MEXC `short 2.084 BTC`。Trading PID 仍為 `11834`，probe error log 為 0；未修改或重啟 Trading process 與 Mac probe。

---

## 2026-08-12 11:20 — 精簡 Trading live dashboard

**改動摘要：** 新增 manifest-bound 雙交易所持倉與最後 completed cycle P&L 指標，並將 production Trading dashboard 精簡為六個即時 stat panels。

**修改的檔案：**
- `agents/alloy/trading/probe.sh` — 從最新 coordinator portfolio snapshot 輸出 Toobit/MEXC 持倉與方向，並輸出最新 `cycle_real_pnl_usdt`
- `grafana/dashboards/Trading/tnauqquant-trading-overview.json` — 僅保留 Real P&L、最後 cycle ΔP&L、今日 cycles、最新 log 更新與兩間交易所持倉
- `tests/trading/test-probe.sh`、`tests/trading/test-central-config.sh` — 固定 bounded labels、欄位來源與六 panel dashboard contract

**原因/備註：** PR #7 於 `95f7701` 合併並部署。Production Prometheus 已收到 Real P&L `52.0618`、最後 cycle `-30.3479`、今日 cycles `2`、Toobit `short 0.103 BTC` 與 MEXC `long 0.103 BTC`；7 個 panel queries 均各回傳一個 series，probe age 約 17 秒，過去一小時未 scrubbed repo path 命中為 0。部署前後 Trading PID 均為 `11834`，strategy config、manifest 與 sidecar identity checksum 完全不變，probe error log 為 0 行。Log 沒有權威 fill／entry price 欄位，因此未將訊號 `mid` 冒充進場價；本次 session 無可用的 in-app browser，未能截取實際 dashboard 畫面。

---

## 2026-08-11 20:41 — 部署 Trading production monitoring

**改動摘要：** 將 manifest-bound macOS Alloy/probe、production Trading rules 與 Grafana dashboard 部署到 `tnauqquant-prod-1`，完成 Cloudflare Access、Prometheus remote write、Loki push 與 shadow alert 端到端 canary。

**修改的檔案：**
- `agents/alloy/trading/` — 安裝 Alloy 1.18.1、15 秒 read-only probe、source scrub 與 production host contract
- `prometheus/rules/trading-targets.yml`、`prometheus/rules/trading.yml` — 切換為 `production` / `tnauqquant-prod-1` / `toobit-mexc-btc` 並維持 shadow
- `loki/rules/fake/tnauqquant.yml` — 切換 production log selectors 並維持 shadow
- `grafana/dashboards/Trading/tnauqquant-trading-overview.json` — 新增 current-run PNL、今日 completed cycles、最後完成時間、run identity 與跨 run 分佈
- `tests/trading/`、`prometheus/rules/tests/trading.test.yml` — 固定 runtime contract、跨重啟去重、cardinality、production target 與 alert 行為
- `docs/project-brief.md`、`docs/work-log.md` — 記錄 production rollout 與後續 canary/rotation 工作

**原因/備註：** PR #5 於 `93706c4` 合併並部署。Prometheus 2.54.1 rules/tests、Loki 3.1.1 rules、Alertmanager、Grafana provisioning、Alloy validate、launchd 與 Cloudflare push 均驗證通過；中央已收到 current run `20260811_121739_toobit-mexc`、Real PNL `182.8703` 與今日 19 個 completed cycles，未 scrubbed repo path 命中為 0。Trading 在安裝前 `20:23:16` 已以 `normal_or_context_cancelled` 退出，安裝前後 matching PID 均為 0，config、manifest、log metadata 與 sidecar identity 完全不變；`TradingProcessDown` 因 stale-running manifest 正確 firing，但由 `notification_mode=shadow` 路由至 `shadow-null`，未送 Telegram。

---

## 2026-08-01 19:45 — 保存 live monitoring 設定並整合付款 shadow 告警

**改動摘要：** 將 production checkout 內 21 個既有 live-only 修改做成可追溯快照，合併到含付款失敗告警的最新 master，保留 Trading／ZenIncome runtime 設定與付款 shadow routing。

**修改的檔案：**
- `alertmanager/alertmanager.yml` — 保留 production Telegram、Trading inhibit 與 shadow-null routing
- `prometheus/rules/` — 納管 production 的 business、deadman 與 Trading rules，並保留付款建立／編號失敗規則
- `loki/rules/fake/` — 納管既有 Trading 與 ZenIncome ruler rules
- `grafana/dashboards/` — 納管 production 現行 Overview、Trading 與 ZenIncome dashboard
- `README.md`、`docs/operations.md`、`runbooks/` — 將現行通知操作說明由已停用的 Gmail 修正為 Telegram
- `docs/project-brief.md` — 更新 Trading、ZenIncome 與付款告警現況
- `docs/work-log.md` — 合併既有 production migration 紀錄並記錄本次保存工作

**原因/備註：** 先以 production `ba83c3a` 為基準逐檔 SHA-256 保存，再三方整合 `origin/master`。`docker compose config`、Prometheus 7 個 rule files、付款 rule tests、Alertmanager、dashboard JSON、shell/YAML 靜態檢查均通過；Loki runtime API 顯示 4 條既有 ruler alerts health 皆為 `ok`。

---

## 2026-08-01 17:57 — 付款建立與編號失敗 shadow 告警

**改動摘要：** 新增低流量付款建立 5xx 與付款編號容量／重試耗盡告警，以 shadow routing 先行觀察，並補齊可執行的規則測試與 production runbook。

**修改的檔案：**
- `prometheus/rules/app.yml` — 新增付款端點 warning/critical 與編號產生失敗規則
- `prometheus/rules/tests/payment-order-alerts.test.yml` — 固定 1、2–4、5 次錯誤及 capacity/exhausted 邊界
- `alertmanager/alertmanager.yml` — 新增優先匹配的 shadow-null route，避免未 canary 的新告警直接通知
- `runbooks/high-5xx.md` — 更新為現行 LinkCourt systemd、PostgreSQL 與 release 架構的排障流程
- `runbooks/README.md` — 登錄三條新告警及 shadow 狀態
- `docs/work-log.md` — 記錄本次監控改動

**原因/備註：** `promtool check rules`、`promtool test rules` 與 `amtool check-config` 均以 production 同版本容器驗證通過。告警部署後只評估、不通知；需完成 production canary review 後另案移除 `notification_mode: shadow`。

---

## 2026-07-17 14:27 — 核准核心決策並新增 Trading agent spec

**改動摘要：** 記錄 owner 對 launch mode、primary PNL、target IDs、Trading repo 修改與 operator-only access 的選擇，並新增可直接交給 tnauqquant agent 的 self-contained runtime contract implementation spec。

**修改的檔案：**
- `docs/trading-monitoring-development-plan.md` — 寫入五項核准決策並連結 Trading handoff spec
- `docs/trading-runtime-contract-agent-spec.md` — 定義 scope、schema、TQ/quant/engine 修改、TDD steps、驗證與跨 repo 交付
- `docs/project-brief.md` — 記錄 owner 決策與下一步文件
- `AGENTS.md` — 加入 Trading handoff spec 索引
- `docs/work-log.md` — 記錄本次決策與文件更新

**原因/備註：** Spec 明確禁止修改策略、下單、PNL 計算或執行 live process；watchdog legacy marker 保持相容。

---

## 2026-07-17 14:02 — Trading monitoring 規格與跨 server 計畫

**改動摘要：** 建立可供審核的 Trading monitoring 設計與 implementation roadmap，涵蓋 development POC、新 server deployment contract、Grafana PNL/狀態/Error dashboard，以及 SkyEye/tnauqquant repo 分工。

**修改的檔案：**
- `docs/trading-monitoring-development-plan.md` — 新增完整設計、state model、dashboard spec、驗收與 migration 步驟
- `AGENTS.md` — 補上 SkyEye 專案架構、驗證命令與專案規則
- `CLAUDE.md` — 指向專案單一指令來源 `AGENTS.md`
- `docs/project-brief.md` — 補上現況、技術決策與 Trading monitoring 方向
- `docs/work-log.md` — 記錄本次文件工作

**原因/備註：** 本輪只建立與整理文件，未實作或部署任何監控程式。

---

## 2026-05-16 - PROD01 to PROD02 monitoring migration

### Summary

Migrated PPClub production monitoring from the old production host
(`PROD01`, previously seen in SkyEye as `server_id="ppclub-prod"`) to the new
production host (`server_id="PROD02"`).

This was an agent-side migration only. The central SkyEye stack
(Prometheus, Loki, Grafana, Alertmanager, Cloudflared) was not moved or
reconfigured.

### PROD02 setup

The Alloy agent was installed and started on PROD02 using the existing SkyEye
agent installer.

Effective PROD02 labels and sources:

- Metrics `product="ppclub"`, `server_id="PROD02"`.
- Host metrics via Alloy unix exporter.
- App metrics from `localhost:8090/metrics`.
- Journald logs:
  - `ppclub-backend.service` and `caddy.service` mapped to `product="ppclub"`.
  - `enyoung-menu.service` mapped to `product="enyoung"`.

PROD02 local validation reported:

- `alloy.service` active and running since `2026-05-15 18:35:09 UTC`.
- `http://localhost:8090/metrics` returned HTTP 200.
- `ppclub-backend.service` and `caddy.service` had recent logs.
- `enyoung-menu.service` existed and was active, but had no recent logs; this
  explained why central Loki had no fresh `product="enyoung"` entries from
  PROD02 during validation.
- Prometheus remote write had `failed=0`, `pending=0`; historical retry count
  did not increase during a 30 second comparison.
- Loki pushes continued to return HTTP 204 and sent-entry counters increased.

### Central verification

Central Prometheus and Loki were queried from the SkyEye host.

Prometheus showed only PROD02 as active for the PPClub production path:

```promql
count by (product, server_id, job, instance) (
  up{server_id=~"PROD01|ppclub-prod|PROD02"}
)
```

Result at `2026-05-16 08:31:57 UTC`:

- `product="ppclub"`, `server_id="PROD02"`, `job="integrations/unix"`,
  `instance="ip-172-31-11-182"`: `1`
- `product="ppclub"`, `server_id="PROD02"`, `job="ppclub-backend"`,
  `instance="localhost:8090"`: `1`

No active `up` series remained for `server_id="PROD01"` or
`server_id="ppclub-prod"`.

Loki verification:

```logql
count_over_time({server_id="PROD02"}[10m])
```

Result at `2026-05-16 08:31:57 UTC`:

- `job="journald"`, `product="ppclub"`, `server_id="PROD02"`: 418 log lines.

Checks for old host labels:

```logql
count_over_time({server_id="PROD01"}[30m])
count_over_time({server_id="ppclub-prod"}[30m])
```

Both returned no recent entries during final validation.

Alert verification:

```promql
ALERTS{alertstate="firing"}
```

Only the intentional `DailyHeartbeat` low-severity alert was firing. No PROD02
migration-related alerts were active.

### PROD01 retirement

After PROD02 was verified as the active monitoring source, Alloy was stopped
and disabled on PROD01:

```bash
sudo systemctl stop alloy
sudo systemctl disable alloy
```

The operator then uninstalled Alloy from PROD01. Old Prometheus and Loki data
was not manually deleted; it will age out under the normal 30 day retention.

### Notes

- `server_id="ppclub-prod"` may still appear in label value lists until
  retention expires. This is historical data and does not mean PROD01 is still
  sending metrics or logs.
- `server_id="PROD02"` is now the production host identity for PPClub host and
  app metrics.
- If `enyoung-menu.service` begins producing logs on PROD02, they should appear
  under `product="enyoung"`, `server_id="PROD02"`.
