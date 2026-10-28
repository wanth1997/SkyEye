# 文件與程式碼對帳（2026-10-29）

基準：`origin/master` 的 `f5bb183e344d08ed00269cabd3065d86a6c0221c`。盤點版本控制內 43 份文字文件；本頁記錄需更正的狀態與仍缺的證據。

程式與測試檔存在只證明已實作；歷史驗證僅對其日期與版本有效。PR 合併、tag、mock／fixture 測試皆不等於目前 production 已部署。這次僅改文件，未進行部署或真實帳號操作。

| 文件落差 | 更正與證據 | 仍待證明 |
|---|---|---|
| brief 下一步仍要求部署三 targets／雙策略 | `prometheus/rules/trading-targets.yml` 只有兩個 active targets，brief 亦記 Mainnet／Ourbit 退役 | 目前 probe、中央 provisioning 與服務版本 |
| 建置與 9 月 UI plan 留空 checkbox | probe、tests、fleet/detail JSON 已在 master，標為歷史施工清單 | Access allowlist、canary→paging、瀏覽器與新 rollout |

10-27 Docker log rotation／cloudflared 與 probe timer 變更的 work-log 有明確待部署操作；本次沒有執行，不提升為已部署。

## 本次驗證

靜態核對文件、主分支程式／tests 與既有證據；本次未重跑全部 runtime 驗收。PR 的 required CI 結果另留於 PR。

所有變更限於 Markdown；已檢查 `git diff --check`、新增相對連結與證據路徑。未新增套件或修改程式；靜態對帳不等於 production runtime 驗證。
