# Trading 日誌順序與刷新延遲 Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task in this dedicated worktree.

**Goal:** 將最新策略日誌排在關鍵執行事件上方，找出手動刷新轉圈過久的原因並修正可重現的瓶頸。

**Architecture:** Dashboard JSON 仍由 Git provisioning；先量測正式 Grafana 各 panel/datasource 請求，再將慢請求拆到 Loki/Prometheus 邊界，候選查詢須與原查詢於固定時間取得相同結果。

**Tech Stack:** Grafana 11.2、Loki 3.1、Prometheus 2.54、JSON、shell、Python standard library。

## Global Constraints

- Datasource UID 維持 prometheus／loki；保留去識別化與策略隔離。
- 保留既有 panel 內容、高度及事故 6h／15m 時窗。
- 僅依實測修正查詢；不以縮短自動刷新間隔掩蓋慢請求。
- 不操作 Trading process、不變更告警通知 routing。

## Task 1: 量測與版面修改

**Files:** `grafana/dashboards/Trading/trading-strategy-detail.json`、`tests/trading/test-central-config.sh`。

- [x] 以正式 model 及既有 operator datasource API 量測每個 panel 的延遲、response bytes 與 rows；最多兩個同時請求，不輸出 log 內容或 credentials。
- [x] 讀取 Loki query stats 與近 30m 正式 HTTP histograms：36 個 panel/datasource requests 為 0.004–0.212 秒；Loki range p99 約 0.049 秒，Grafana datasource p99 約 0.088 秒，當期所有查詢落在 0.25 秒內且 HTTP 200。
- [x] 把 id 12 設為 y=21、h=8，id 13 設為 y=29、h=7，依 gridPos 排列 JSON panels；dashboard version 增為 6。
- [x] 未發現後端查詢瓶頸，因此本次保留查詢與 15s 刷新設定。外部未登入頁的 Access redirect 為 0.40 秒，只能驗證該路徑；沒有可用 browser session，無法代替使用者已登入頁的 Network／render trace。已詢問轉圈面板與秒數，瀏覽器端原因仍待定位。
- [x] 執行 `bash tests/trading/test-central-config.sh`、`find grafana/dashboards -name '*.json' -exec jq empty {} +`、`git diff --check`；使用既有版面檢查確認無重疊，另以 JSON semantic diff 確認所有 panel 只有 id 12/13 的 y 座標變動。

## Task 2: 發布與驗證

**Files:** `docs/work-log.md`。

- [ ] 記錄量測結果、修改與限制，提交專用 branch，fetch／rebase 後 push 並建立 master PR。
- [ ] 依本 session 的部署授權合併；確認實際 Git ancestry，中央 clean checkout fast-forward 精確 merge commit。
- [ ] 驗證 Grafana provisioned panels、最新日誌／關鍵事件順序，並用相同請求重新量測刷新；若無 browser session，明確保留瀏覽器端驗證限制。
- [ ] 保留部署證據，移除乾淨且已合併的本 task worktree。
