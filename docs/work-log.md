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
