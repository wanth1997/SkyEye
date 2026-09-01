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
