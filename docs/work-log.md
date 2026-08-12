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
