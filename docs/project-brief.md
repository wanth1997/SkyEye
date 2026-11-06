# SkyEye

## 目標

提供一套無公開 ingestion port 的集中式監控平台，讓多臺產品主機能將 metrics 與已 scrub 的 logs 安全送到中央端，在 Grafana 統一查看，並由 Alertmanager 將需要處理的事件送到 Telegram。

## 架構 / 技術棧

- 中央端：Docker Compose、Prometheus 2.54、Loki 3.1、Grafana 11.2、Alertmanager 0.27、Blackbox Exporter、Node Exporter 1.12（`monitoring-host` job）、Cloudflare Tunnel。
- 遠端主機：Grafana Alloy；metrics 經 Prometheus remote write，logs 經 Loki push API。
- 儲存：Prometheus TSDB 與 Grafana SQLite 位於 EBS，Loki chunks 位於 S3。
- 存取：Grafana 經 Cloudflare Access；agent 使用 Cloudflare Access Service Token。
- 設定與 dashboard 全部以 Git 管理，Grafana dashboard 使用檔案 provisioning。

## 目前狀態

- 部署（2026-11-06）：production 最後 applied 的是 `76199576c50b`（2026-11-05 23:31Z）。master `bd63d1a5`（PR #61）已 merge，`scripts/verify-all` 通過，但還沒部署：Stack health 修正、4 條備份 shadow 告警、`node-exporter`、新版備份與還原腳本、休眠 email 路由、`central-deploy` 載入驗證。部署順序見 `docs/operations.md`。主機端的 log scrub、probe 與 `setup.sh` 修正不在中央部署內，要各自 rollout。
- 通知：High 目前只送 Telegram。休眠的 `email-high` 路由只收 `notification_mode="page"`，目前沒有這種告警，SMTP 也還沒設定，所以不會寄信。
- 備份：到 2026-11-03 為止連續 59 天上傳成功，但沒有任何備份實際還原過。新版腳本只在本機 Colima 演練過，其中 `aws` 是 fake，真實 S3 未驗證。
- Mac mini `server_id` 更名已於 2026-11-01 完成。時窗 13:31:29Z–15:31:29Z 排除於 Trading shadow/canary 證據之外，紀錄見 `docs/trading-serverid-cutover-macmini-m2.md`。
- 中央監控棧、Cloudflare ingress、Telegram routing、host/app/business rules 與多個產品 dashboard 已投入使用。
- Linux/Ubuntu Alloy installer 已支援 journald、node metrics 與 application `/metrics`。
- Trading inventory 已包含 `macmini-m2` / `toobit-mexc-btc`，以及 `trading01` 上的 `lighter-robinhood-btc-canary` 與 `lighter-mainnet-btc-canary`。Mainnet 曾於 2026-09-22 退役，2026-10-31 以 shadow inventory 恢復監控，供使用者以新帳號 765446 重啟該 lane 前先在 Grafana 確認；`ourbit-spot`（runtime instance `ourbit-spot-btc`，2026-10-08）依 operator 指示退役並移出監控名單；既有歷史資料保留，`deployment-linux-*.env.example` 保留供日後重新納入。portable read-only probe 支援雙交易所與單交易所 executor mapping；Linux 以 per-strategy systemd probe、env、metrics output 與 Loki fragment 共用單一 textfile collector，並與既有 ZenIncome Alloy pipeline 共存。Grafana 只保留可選 server/strategy 的 detail dashboard 與每策略一列的 fleet dashboard；Prometheus/Loki rules 與 alerts 均以 shadow rollout 管理。
- `macmini-m2`（production Mac mini）在 macOS Alloy 與 read-only probe 之外，另有隔離的每分鐘 P&L history builder，以變更偵測與 per-run cache 合併 authoritative completed-cycle delta；其 accumulated metrics 繼續保留，但不再提供專用的「Trading · 即時營運」dashboard。detail／fleet 採繁中版面：detail 第一列顯示損益、週期與目前餘額，下方單一監控摘要合併近 15 分鐘的四項事故與六項運行狀態；runtime contract、執行 identity binding 與 config snapshot drift 仍獨立判讀，關鍵事件與完整 scrubbed log 分層。餘額使用目前 run 最新穩定快照的 equity_now，已包含該策略所有交易所帳戶的總權益。fleet 繼續揭露 Prometheus shadow alerts 與獨立的 Loki execution incident count。
- ZenIncome 的 Loki log alerts、dashboard 與唯讀 Bitfinex 診斷腳本已納入 Git；既有 production 規則狀態需由 operator 持續觀察。
- LinkCourt 付款建立 5xx 與訂單編號 capacity/exhausted 告警已進入 shadow routing，等待 production canary review 後再決定是否升級通知。另有三條 LinkCourt 付款告警（`LinkcourtPaymentGuardHeld`、`LinkcourtPaymentNotifyUnknownOrder`、`LinkcourtInvoiceBeforeCutoff`）2026-11-03 直接上線，已同步進 `prometheus/rules/business.yml`，直接送 High。

## 重要決策

- 遠端 agent 採 Alloy 主動 push，不讓中央端直接連入產品主機。
- Grafana datasource UID 固定，dashboard JSON 是唯一持久來源。
- Loki 使用單一 `fake` tenant，以低 cardinality labels 區隔產品；高 cardinality 欄位只在 query time parse。
- Trading 歷史 P&L 只加總完整 `time`、`cycle_id`、`cycle_real_pnl_usdt` contract 的 stable completed-cycle 事件；舊資料缺欄位時不由 session cumulative P&L 反推，避免無聲低估，改由 coverage 指標明示。
- Trading telemetry alert 由中央 inventory 判斷 timestamp 缺失或凍結超過 180 秒；只有標記 `history_capable="true"` 的 target 會套用獨立的 PnL history unavailable Medium shadow alert。
- Production probe 強制使用 Trading repo 的 run manifest 與可驗證 done marker，缺少 contract 時 fail closed，不以最新 mtime 猜測 current run。
- Running manifest 的 PID、executable、instance 與 log binding 有效時，磁碟 config drift 只以 `config_snapshot_match=0` 揭露並維持 shadow binding alert，不解除既有 run 的 P&L/log 可觀測性，也不改寫 manifest 快照。
- Trading execution incident 使用高信心 `msg` allowlist，不以 `disposition=unresolved ui_submission_status=accepted` 單獨判定異常；同一 allowlist 從 generic ERROR-family rule 排除，避免日後 promotion 後重複 paging。`ERROR+N`／`FATAL+N` 仍由 generic fallback 涵蓋。
- Trading log 在來源端額外 scrub `grant_id`、`mutation_id`、`mutations` 與 `account`，且這些 execution identifiers 永不升為 Loki labels。
- Trading 原始 `tnauqquant_*` metrics 維持穩定，中央以 `trading_target_info` inventory 與 `trading_strategy_*` recording rules 提供多策略介面；alert 不再 hard-code server/strategy。
- Linux 已有 Alloy 的主機使用 config directory 加入共享 `trading-metrics.alloy` 與 per-strategy `trading-<strategy>.alloy`，重用既有 `central` receivers；singleton 遷移會先 disable 舊 probe timer、備份精確舊檔與 metrics output，且不覆寫其他產品 pipeline、不新增 ingestion port。
- Linux Trading probe timer 會在每次執行前，僅對 `TQ_RAW_LOG_GLOB` 命中的 mode-`0600` raw logs 補上 named `alloy:r--` ACL；不更改檔案內容、owner/group，也不將 Alloy 加入產品使用者群組。
- Current-run P&L 只能在同一策略列中呈現；不同 run 起始時間沒有共同 accounting window，因此 fleet 不顯示加總損益。
- Owner 已核准：TQ human foreground launch、`real_pnl_usdt` primary PNL、development/production target IDs、Trading runtime contract 修改，以及 operator-only Grafana access。
- 新增告警一律先帶 `notification_mode="shadow"`，通過 canary review 後才可移除 shadow routing。
- 2026-10-31（D14）production Mac mini 的 `server_id` 真正更名為 `macmini-m2`，不以 Grafana display mapping 處理；Dashboard 不加雙名過渡查詢。Cutover 程序見 `docs/trading-serverid-cutover-macmini-m2.md`。原本決定舊資料留到 retention 到期，2026-11-02 改為刪除 Prometheus 的舊名資料；Loki 舊 streams 仍留到 720h retention 到期，日期早於 2026-11-02 的 S3 備份也還含舊名資料。
- 2026-11-05 決定 High 告警補上 email 當第二條路徑，先用休眠路由，真實 canary 通過後才啟用。同日決定中央部署後，先把 `TradingCriticalSafetyState`、`TradingProcessDown`、`TradingRiskStopped` 升級為 `page`，source 先升，真實 canary 要另外核准。

## 待辦 / 下一步

- 部署 master `bd63d1a5` 到 monitoring-prod（等核准），然後確認第一次 19:00 UTC 備份，並對線上世代跑 `fetch`、`verify`，量出實際讀取時間。
- 新版 probe rollout 到 Trading01 與 Mac mini，時段待指定。Mainnet strategy 不得由這個流程啟動。
- 填 SMTP、跑真實 canary，再升級三條 Trading 告警，流程見 `runbooks/trading-alert-promotion.md`。
- log scrub 主機 rollout 要另外核准。`agents/alloy/setup.sh` 目前會砍掉 PROD02 的 8091、8092 scrape，修好之前不得在 PROD02 重跑。
- 依 `prometheus/rules/trading-targets.yml` 的三個 active targets（`toobit-mexc-btc`、`lighter-robinhood-btc-canary`、`lighter-mainnet-btc-canary`）觀察 shadow alerts。
- 設定 Cloudflare service token 到期通知，並在到期前完成可獨立回復的 rotation。
- 觀察 LinkCourt 付款 shadow 告警，完成 canary review 後另案決定是否啟用通知。
