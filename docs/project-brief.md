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
- Trading inventory 已包含 `tnauqquant-prod-1` / `toobit-mexc-btc` 與 `trading01` / `lighter-robinhood-btc-canary`；portable read-only probe 同時支援雙交易所與單交易所 executor mapping，Linux Alloy 以 directory fragment 共存於既有 ZenIncome pipeline。既有 dashboard 保留，另有可選 server/strategy 的 detail dashboard 與每策略一列的 fleet dashboard；Prometheus/Loki rules 與 alerts 均以 shadow rollout 管理。
- `tnauqquant-prod-1` 在 macOS Alloy 與 read-only probe 之外，另有隔離的每分鐘 P&L history builder，以變更偵測與 per-run cache 合併 authoritative completed-cycle delta。Trading dashboards 已改為繁中、PnL-first 版面：30 天跨 run／跨日 accumulated Real PnL 佔主視覺，正常的 process、binding、risk、telemetry 與 history 狀態收進緊湊摘要；fleet 另外揭露每策略 shadow alert 數。歷史資料在第一筆 authoritative event 前不補零，避免把尚無 coverage 誤畫成零損益。
- ZenIncome 的 Loki log alerts、dashboard 與唯讀 Bitfinex 診斷腳本已納入 Git；既有 production 規則狀態需由 operator 持續觀察。
- LinkCourt 付款建立 5xx 與訂單編號 capacity/exhausted 告警已進入 shadow routing，等待 production canary review 後再決定是否升級通知。

## 重要決策

- 遠端 agent 採 Alloy 主動 push，不讓中央端直接連入產品主機。
- Grafana datasource UID 固定，dashboard JSON 是唯一持久來源。
- Loki 使用單一 `fake` tenant，以低 cardinality labels 區隔產品；高 cardinality 欄位只在 query time parse。
- Trading 歷史 P&L 只加總完整 `time`、`cycle_id`、`cycle_real_pnl_usdt` contract 的 stable completed-cycle 事件；舊資料缺欄位時不由 session cumulative P&L 反推，避免無聲低估，改由 coverage 指標明示。
- Trading telemetry alert 由中央 inventory 判斷 timestamp 缺失或凍結超過 180 秒；只有標記 `history_capable="true"` 的 target 會套用獨立的 PnL history unavailable Medium shadow alert。
- Production probe 強制使用 Trading repo 的 run manifest 與可驗證 done marker，缺少 contract 時 fail closed，不以最新 mtime 猜測 current run。
- Running manifest 的 PID、executable、instance 與 log binding 有效時，磁碟 config drift 只以 `config_snapshot_match=0` 揭露並維持 shadow binding alert，不解除既有 run 的 P&L/log 可觀測性，也不改寫 manifest 快照。
- Trading 原始 `tnauqquant_*` metrics 維持穩定，中央以 `trading_target_info` inventory 與 `trading_strategy_*` recording rules 提供多策略介面；alert 不再 hard-code server/strategy。
- Linux 已有 Alloy 的主機使用 config directory 加入 `trading.alloy` fragment，重用既有 `central` receivers；不覆寫其他產品 pipeline，也不新增 ingestion port。
- Current-run P&L 只能在同一策略列中呈現；不同 run 起始時間沒有共同 accounting window，因此 fleet 不顯示加總損益。
- Owner 已核准：TQ human foreground launch、`real_pnl_usdt` primary PNL、development/production target IDs、Trading runtime contract 修改，以及 operator-only Grafana access。
- 新增告警一律先帶 `notification_mode="shadow"`，通過 canary review 後才可移除 shadow routing。

## 待辦 / 下一步

- 觀察兩個 Trading production targets 的 shadow alerts、Linux coexistence 與 fleet/detail dashboard 訊號品質，完成 canary review 後另案決定是否啟用通知。
- 設定 Cloudflare service token 到期通知，並在到期前完成可獨立回復的 rotation。
- 觀察 LinkCourt 付款 shadow 告警，完成 canary review 後另案決定是否啟用通知。
