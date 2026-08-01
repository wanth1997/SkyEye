# SkyEye

## 目標

提供一套無公開 ingestion port 的集中式監控平台，讓多臺產品主機能將 metrics 與已 scrub 的 logs 安全送到中央端，在 Grafana 統一查看，並由 Alertmanager 將需要處理的事件送到 Telegram。

## 架構 / 技術棧

- 中央端：Docker Compose、Prometheus 2.54、Loki 3.1、Grafana 11.2、Alertmanager 0.27、Blackbox Exporter、Cloudflare Tunnel。
- 遠端主機：Grafana Alloy；metrics 經 Prometheus remote write，logs 經 Loki push API。
- 儲存：Prometheus TSDB 與 Grafana SQLite 位於 EBS，Loki chunks 位於 S3。
- 存取：Grafana 經 Cloudflare Access；agent 使用 Cloudflare Access Service Token。
- 設定與 dashboard 全部以 Git 管理，Grafana dashboard 使用檔案 provisioning。

## 目前狀態

- 中央監控棧、Cloudflare ingress、Telegram routing、host/app/business rules 與多個產品 dashboard 已投入使用。
- Linux/Ubuntu Alloy installer 已支援 journald、node metrics 與 application `/metrics`。
- Development Trading POC 的 dashboard、Prometheus/Loki shadow rules 與 runbook 已納入 Git；target 固定為 `tnauqquant-dev-mac`，尚未升級為 production paging。
- ZenIncome 的 Loki log alerts、dashboard 與唯讀 Bitfinex 診斷腳本已納入 Git；既有 production 規則狀態需由 operator 持續觀察。
- LinkCourt 付款建立 5xx 與訂單編號 capacity/exhausted 告警已進入 shadow routing，等待 production canary review 後再決定是否升級通知。

## 重要決策

- 遠端 agent 採 Alloy 主動 push，不讓中央端直接連入產品主機。
- Grafana datasource UID 固定，dashboard JSON 是唯一持久來源。
- Loki 使用單一 `fake` tenant，以低 cardinality labels 區隔產品；高 cardinality 欄位只在 query time parse。
- Trading 第一版以 log-derived PNL、外部 process probe 與 error logs 為核心；authoritative position/risk metrics 留給後續原生 `/metrics`。
- Development POC 可先只改 SkyEye；production-safe migration 仍要求 Trading repo 提供 run manifest 與可驗證 done marker。
- Owner 已核准：TQ human foreground launch、`real_pnl_usdt` primary PNL、development/production target IDs、Trading runtime contract 修改，以及 operator-only Grafana access。
- 新增告警一律先帶 `notification_mode="shadow"`，通過 canary review 後才可移除 shadow routing。

## 待辦 / 下一步

- 審核 `docs/trading-monitoring-development-plan.md` 與可轉交 Trading agent 的 `docs/trading-runtime-contract-agent-spec.md`。
- 完成 macOS Alloy 與 trading probe 的端到端 development canary，確認 POC dashboard 與 shadow rules 的實際訊號品質。
- 由 Trading repo owner 實作 runtime contract，完成後在新 server 套用 deployment contract。
- 驗證 Cloudflare allowlist、為 trading host 建立可獨立撤銷的 service token，再開放 production paging。
- 觀察 LinkCourt 付款 shadow 告警，完成 canary review 後另案決定是否啟用通知。
