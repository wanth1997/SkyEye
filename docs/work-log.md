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
