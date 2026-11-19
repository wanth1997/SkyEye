# grafana-upgrade：中央 Grafana 從 11.2.0 升到 12.4.15

- Linear: WAN-427
- Request: grafana-upgrade-20261119
- 狀態: 草稿（2026-11-19），等 PLAN_APPROVED

## 目標

11-04 Codex review 的 L-01（`ops/SKYEYE-RV-LOWCONF-20261104/verdicts.md`）：中央 Grafana 跑的 `grafana/grafana:11.2.0` 已經沒有支援。這次要升到 12.x 最新、發布滿 7 天的 patch，pin 確切 tag，把新 major 需要的改動做完，讓部署後 production 的行為不變，並寫好部署與 rollback 程序。部署是 S2，要使用者另外核准。

## 不做

- 不部署、不重啟、不 SSH 到 monitoring-prod，也不在上面跑任何東西。
- 不動 Cloudflare、Access、WAF（P1-01 另案處理）。
- 不改 Grafana 使用者（id3、id4 要不要降級由使用者決定），不改 datasource UID，不新增或重新設計 dashboard。
- 不升級 Prometheus、Loki、Alertmanager、Alloy。
- 不升到 13.x。13.3.1 已經發布，但這次範圍只到 12.x。
- 不改 `docs/work-log.md`。

## 做法要點

### 目標版本：`grafana/grafana:12.4.15`

Pin 成 `grafana/grafana:12.4.15@sha256:2894082f6cf7081aefdc1389265c04000812309208c190d75e8c65f7a30e4b7e`，tag 加 digest，跟 `node-exporter` 的寫法一樣，確保部署的就是這裡測過的那個 image。

| 證據 | 值 |
|---|---|
| Docker Hub `tag_last_pushed` | 2026-11-10T17:25:07Z（到 2026-11-19 已 9 天，符合 7 天規則） |
| GitHub release `v12.4.15` | published 2026-11-10T20:47:14Z，`prerelease=false` |
| 是不是 12.x 最新 | Docker Hub 上 12.x 最大的 tag 就是 12.4.15。12.3 最後一版是 12.3.11（2026-08-18）。12.4 是 Grafana 12 的最後一個 minor，patch 支援到 2027-05-24（grafana.com「When to upgrade」） |
| Release notes | 只有 security 修正：CVE-2026-102589、-106472、-106475、-107365、-107509、-111000、-81843、-82014，外加 moment-timezone 更新。11-04 的候選 12.4.14 沒有這些修正（例如 Prometheus datasource SSRF CVE-2026-106472），所以改用 12.4.15 |
| Digest | index digest `sha256:2894082f…7e4b7e`，本機 pull 後的 `RepoDigests` 一樣。含 amd64、arm64、arm；monitoring-prod 是 t4g（arm64） |
| Image | Alpine 3.24.3（11.2.0 是 3.19），一樣 uid 472、gid 0、`/run.sh`，`GF_PATHS_*` 相同，`curl` 和 `wget` 都在，沒有 `sqlite3`（11.2.0 也沒有） |

11.2.0 沒有修正的 CVE 裡，下面這些在 SkyEye 的設定下，Viewer 或任何已登入的人就能觸發：

- CVE-2026-42129、CVE-2026-10601：Loki datasource 的 path traversal。
- CVE-2026-9703：經 datasource proxy 改 Loki ruler。SkyEye 的 ruler 是唯讀掛載的 local store，實際影響應該有限，但沒有驗證。
- CVE-2026-106472：Prometheus datasource SSRF。
- CVE-2025-3454：Alertmanager／Prometheus proxy bypass。
- CVE-2026-88858、CVE-2026-28379：讓 server crash。
- CVE-2025-4123：XSS。

### `docker-compose.yml` 的改動

grafana service 只改這幾行，其餘不動：

```yaml
image: grafana/grafana:12.4.15@sha256:2894082f6cf7081aefdc1389265c04000812309208c190d75e8c65f7a30e4b7e
environment:
  # 12.x 啟動時會從 grafana.com 下載並自動更新 4 個 Drilldown app；11.2 一個都不裝
  - GF_PLUGINS_PREINSTALL_DISABLED=true
  # Grafana 官方文件的 opt-in：不論數量，folders 與 dashboards 一律搬進 unified storage
  - GF_UNIFIED_STORAGE_FOLDERS_FOLDER_GRAFANA_APP_ENABLEMIGRATION=true
  - GF_UNIFIED_STORAGE_DASHBOARDS_DASHBOARD_GRAFANA_APP_ENABLEMIGRATION=true
```

Unified storage 的 opt-in 為什麼要設：

- 12.4 只在 DB 裡的 dashboard 與 folder 都不超過 10 個時，才會自動搬進 unified storage。這個 breaking change 列在 What's new in 12.4。
- Repo 剛好 10 個 dashboard、7 個 folder。所以 prod 走哪條路，要看 DB 裡的實際數量。
- 測試永遠從空 DB 起跑，檢查時數量是 0，所以一定會搬。
- 本機實測：11.2.0 寫入 11 個 dashboard 後，12.4.15 預設跳過搬遷（`count=11 threshold=10`，`Migration is disabled in config, skipping`）。同一份資料加上這兩個 env 就照樣搬遷，11 個 dashboard 都正常提供。
- 設了之後，prod 和測試固定走同一條路。13.0 本來就會讓所有 instance 都搬遷。

### 11.2 → 12.4 會碰到本 repo 的改動

證據有兩個來源：

- 本機實測：11.2.0 與 12.4.15 在無網路下跑 repo 的 provisioning 與 dashboards，加上兩版 `conf/defaults.ini` 的逐 key diff。
- 研究整理：官方 What's new、upgrade guide、CHANGELOG 的 breaking changes，以及 security advisories（12.4.15 tag 的 source 只拿來補文件沒寫的地方）。

| 改動 | 對本 repo | 處理 |
|---|---|---|
| **Angular 全面移除**（12.0）。`security.angular_support_enabled` 與 `autoMigrate*` toggle 都刪了；`graph`、`table-old` 不在 panel registry 裡 | 10 個 dashboard、331 個 panel 物件只用到 `timeseries` 167、`stat` 74、`row` 53、`gauge` 13、`table` 9、`logs` 7、`bargauge` 6、`state-timeline` 1、`xychart` 1，12.4.15 的 registry 全都有。沒有 `graph`、`singlestat`、`table-old`、`worldmap` 等舊 panel。沒有 `GF_INSTALL_PLUGINS`，也沒有任何外部 plugin | Dashboard JSON 不用遷移。新測試把「每個 panel type 都在釘住版本的 registry 裡」變成 gate |
| **Plugin preinstall**（11.3 起；12.0～12.4 預設 4 個）。啟動時從 grafana.com 下載到 `/var/lib/grafana/plugins`（在 `grafana_data` volume 裡），並且 `preinstall_auto_update=true`。Image 裡沒有內建這些 app | 會讓 production 每次啟動都下載並執行沒有 pin 的程式碼。本機 log 看得到 4 個 app 的安裝嘗試 | `GF_PLUGINS_PREINSTALL_DISABLED=true`（見待決問題 Q1）。代價：11.2 內建的 Explore → Metrics（`exploreMetrics`）在 12.x 改成 Metrics Drilldown app，關掉 preinstall 就沒有這個畫面。核心 Explore 不受影響 |
| **Folders／dashboards 自動搬進 unified storage**（12.4.0 breaking）。搬遷成功後改成只寫 unified storage（mode 5），用 bleve index 搜尋，資料表仍在同一個 `grafana.db` | 失敗時 dualwrite service 起不來，從 source 看 Grafana 等於起不來。搬遷後的改動不會寫回 legacy 表，所以 image 直接降版不安全 | 設上面的 opt-in，讓行為固定。Runbook 先在備份的複本上彩排一次，確認搬遷成功，才動正式的 volume |
| **Dashboard API 改走 app platform**（12.2 起 `kubernetesDashboards` 預設開啟） | `/api/search` 與 `/api/dashboards/uid/<uid>` 還在，10 個 dashboard 回傳的 JSON 扣掉 `id`、`version` 後和檔案完全相同。但實測從 11.2 搬遷到 12.4.15 的既有 dashboard，在檔案未改寫前 `meta.provisionedExternalId` 會是空字串，只有 v1beta1 資源保有 `grafana.app/managedBy=classic-file-provisioning` 與 `grafana.app/sourcePath=<Folder>/<file>.json` | 修改 `scripts/central-deploy`，在 `provisionedExternalId` 為空時嚴格核對 v1beta1 的 `managedBy` 與 `sourcePath`（其他值仍失敗），並補測試。新測試固定全新 DB 的 contract |
| **後端 schema migration** 到 42（v40 把 `refresh` 正規化成字串、v41 刪 `timepicker.time_options`、v42 在 `hideFrom.viz=true` 時補 `hideFrom.tooltip=true`），只在 UI 載入或讀 v1+ API 時執行 | 10 個 dashboard 的 v2beta1 轉換全部 `status.conversion.failed=false`。legacy API 不改寫存的 JSON。在 12.4 UI export 出來的 JSON 會是 schemaVersion 42 | 不改 JSON 的 `schemaVersion`。新測試檢查每個 dashboard 都能轉換。`docs/grafana-conventions.md` 註明 export 的 JSON 會有這些差異 |
| **新 logs panel**（12.3 GA，預設開啟）、**新 table**（12.2 GA） | 7 個 `logs` 與 9 個 `table` panel 會換成新實作。Logs 用到的 options：`showTime`、`showLabels`、`showCommonLabels`、`wrapLogMessage`、`prettifyLogMessage`、`enableLogDetails`、`dedupStrategy`、`sortOrder` | 不另外關 toggle（關掉的 toggle 下次升級就會被移除）。用瀏覽器檢查實際畫面 |
| **Scenes 版 dashboard UI**（11.3 起預設開啟） | 畫面與 Export 流程換了位置 | 依本機 12.4.15 的實際操作，更新 `docs/grafana-conventions.md` 與 `docs/operations.md` 裡的 Export 說明（要存成 classic JSON，不要存 v2 resource） |
| **Loki query builder 改用 `/labels?query=`**（11.5 breaking） | Loki 版本低於 3.1.0 才會出問題，SkyEye 跑 3.1.1 | 本機接釘住版本的 Loki 3.1.1 驗證 label 清單 |
| **Annotation 表全表重寫**（12.0～12.3 的 upgrade guide） | 需要 annotation 表 2～3 倍的可用磁碟。SkyEye 沒有 Grafana alerting，annotation 應該很少 | Runbook 前置檢查記錄 `grafana.db` 大小與 `df` |
| **RBAC 只存 action sets**（12.3） | 降回 11.2 又不還原 DB 的話，需要額外 toggle | 只在 rollback 不還原 DB 時才有影響；本計畫一律還原 |
| **JWT 改用 go-jose v4**（12.3）：簽章演算法改成固定 allowlist（含 RS256），`aud` 改成 `AnyAudience` 比對 | Cloudflare Access 用 RS256，單一 `aud` 字串時結果相同 | 已在 12.4.15 跑 JWT 測試（見下面 Auth）。部署後由 owner 實際登入一次 |
| Datasource UID 格式檢查（12.0，`failWrongDSUID`） | `prometheus`、`loki`、`alertmanager` 都合格。三個 datasource 在兩個版本的 `uid`、`type`、`url`、`isDefault`、`jsonData`（含 Loki 的 `maxLines`）完全一樣 | 不用處理 |
| `/api/dashboards/home` deprecated（12.4） | `default_home_dashboard_path` 在 12.4.15 仍然有效 | 新測試確認首頁是 `overview-all` |
| `users.editors_can_admin`、`viewers_can_edit` 刪除；`/api/auth/keys` 移除（12.1）；匿名使用者強制 Viewer（12.0）；plugin 程序不再拿到所有 host env（12.4） | 都沒用到：只用 service account token，匿名關閉，也沒有 backend plugin | 不用處理 |
| `unified_alerting.max_attempts` 1 → 3、`deleted_rule_retention` | 沒有 Grafana-managed alert rule，告警全在 Prometheus/Alertmanager | 不用處理 |
| 新的 brute-force 登入保護 key | 只作用在 login form 與 basic auth，兩者都關著 | 不用處理 |
| `paths.permitted_provisioning_paths`（12.4 新增） | 只限制 Git Sync 的 local repository，不影響 file provisioning：12.4.15 照樣從 `/var/lib/grafana/dashboards` 載入 10 個 dashboard | 不用處理 |
| 記憶體 | 閒置時 11.2.0 是 66 MiB，12.4.15 是 127 MiB（本機、無使用者）。monitoring-prod 是 4 GB | 部署後用 `docker stats` 記錄 |
| Breakglass CLI | `grafana cli admin reset-admin-password --password-from-stdin` 在 12.4.15 還在。`grafana cli user-manager` 從 11.5 起移除，repo 沒有用到 | `docs/operations.md` 不用改 |

使用者資料表的 migration：小寫化在 11.2 已經跑過，11.2 之後新增的 user／service account migration 遇到衝突也不會失敗（官方文件沒寫，這是看 source 得出的）。研究筆記附在 report。

### Auth：逐 key 比對

`docker-compose.yml` 的每個 `GF_*` 在 12.4.15 的 `defaults.ini` 都還在，section 與預設值都和 11.2.0 一樣：

- `security.admin_password`
- `server.root_url`、`server.serve_from_sub_path`
- `auth.disable_login_form`、`auth.basic.enabled`、`auth.proxy.enabled`
- `auth.jwt.{enabled, header_name, email_claim, username_claim, jwk_set_url, expect_claims, cache_ttl, auto_sign_up, skip_org_role_sync}`
- `users.{allow_sign_up, auto_assign_org_role}`
- `dashboards.default_home_dashboard_path`
- `auth.anonymous.enabled`
- `snapshots.external_enabled`

測試檢查的 `url_login`、`enable_login_token`、`allow_assign_grafana_admin`、`role_attribute_path` 也一樣。

`[auth.jwt]` 多了 `org_mapping`、`org_attribute_path`（只在 `skip_org_role_sync=false` 時才作用）、`jwk_set_bearer_token_file`、`tls_client_ca`、`tls_skip_verify_insecure`，預設都是空或 false。使用者查找的順序沒變：先用 `user_auth` 的 module 加 `sub`，再用 email，再用 login。所以 auth 設定不用改。

在 scratch 複本把 image 換成 12.4.15、auth 設定不動，跑 `tests/grafana/test-access-jwt.sh`：40 項全過。涵蓋：

- 合法 token 登入，新帳號是 Viewer。
- 既有 admin 用 email 對到同一個帳號，並保留 server admin。
- 在 Grafana 改的角色不會被覆蓋。
- 偽造的 `Cf-Access-Authenticated-User-Email` 被拒。
- 錯的 aud／iss、過期、別的 key 簽的、`alg=none` 都拒絕。
- Key set 連不到時 fail closed。
- Viewer service account 讀得到 dashboard 與 `provisionedExternalId`。

### Provisioning

- Datasource provisioning 檔不改，UID 不變。
- Dashboard provider（file、`foldersFromFilesStructure`、`allowUiUpdates`、輪詢 60 秒）不改。12.4.15 照樣把 10 個 dashboard 放進對應目錄名稱的 folder，dashboard UID 不變。
- 沒有 alerting provisioning，也不新增。

### `scripts/central-deploy` 與升級前備份

`central-deploy` 把 `docker-compose.yml` 歸類成需要 recreate 的路徑，會直接拒絕：不 pull、不 recreate，也不碰 volume。所以這次跟 Alertmanager 升級（`runbooks/alertmanager-upgrade.md`）和 JWT 切換（`docs/operations.md`）一樣走手動流程，最後用 `--manual-applied` 記錄。`central-deploy` 不用擴充，備份寫成 runbook 裡可以直接複製貼上的步驟。

這個 commit 不改任何 dashboard JSON，所以 `--manual-applied` 不會讀 Grafana。Runbook 要自己用 Viewer service account 檢查 `/api/search` 與 `provisionedExternalId`。

備份與還原：

- Grafana 停止後，用 `sudo tar --numeric-owner -cpf` 從 `docker volume inspect` 得到的 mountpoint 備份整個 `grafana_data` volume。`grafana.db` 在裡面，12.x 可能新增的 `unified-search/` 等檔案也一併涵蓋。備份放在 checkout 外面的 mode 700 目錄，檔案 mode 600（裡面有 token hash）。
- 不能用 `docker compose cp` 還原：複製進 container 的檔案會變成 root 所有，以 uid 472 執行的 Grafana 打不開 mode 600 的 db。本機彩排會實際驗證這點。
- 停機時間：只有 Grafana UI 會停，從 stop 到 12.4.15 的 `/api/health` 回 ok 為止，包含備份與彩排。Prometheus、Loki、Alertmanager、Telegram 與 ingestion 都照常運作，Grafana 本身沒有告警規則。

Rollback（runbook 的「退回 11.2.0」）：

1. Stop Grafana。
2. 清空 volume 內容，還原 tar。
3. 用 checkout 外面的 override 檔（`image: grafana/grafana:11.2.0`，並拿掉 12.x 專用的 env）執行 `up -d --no-deps grafana`，checkout 保持乾淨。
4. 做登入與 dashboard 檢查。
5. 開 revert PR，merge 後 `--force-recreate`，再跑 `--manual-applied`。

升級後才寫入的資料（新帳號、star、UI 改動、新 service account）會遺失，runbook 會寫清楚。11.2.0 image 要留在主機上，不能 prune。

### Runbook：`runbooks/grafana-upgrade.md`

照 `alertmanager-upgrade.md` 的結構寫，200 行以內：

1. 會變的地方
2. 時段與基準：避開 UTC 18:15～19:30；Wan 記下使用者與 service account 清單和自己的 user id；記錄 volume 名稱與 mountpoint、`grafana.db` 大小與 `df`（至少要有 db 的 3 倍）
3. 先 pull 並核對 digest：主機的 `grafana/grafana:11.2.0` 要留著
4. `central-deploy --dry-run`：預期因為 `docker-compose.yml` 而拒絕
5. 停 Grafana、備份 volume，再用備份的複本跑一次無網路的 12.4.15 彩排：
   - health 正常
   - log 有 `folders and dashboards migration` 成功，沒有 `level=error`
   - 10 個 dashboard 都在

   彩排跑完就刪掉複本。不通過就 `start` 原本的 container，到此為止。
6. `git merge --ff-only` 後 `up -d --no-deps grafana`
7. 升級後檢查：
   - Wan 經 Cloudflare Access 以 owner 身分登入，不出現 Grafana 登入頁，user id、Admin 角色、star 都和之前一樣
   - 10 個 dashboard 逐一打開
   - Explore 分別查 Prometheus 與 Loki
   - Alertmanager datasource：proxy 呼叫 `/api/v2/status`，並看 Alerting 畫面
   - Viewer service account 讀得到 dashboard
   - Log 沒有 `level=error` 與 `Failed to authenticate request`
   - `docker stats` 記錄記憶體
   - `scripts/central-deploy --manual-applied`
8. 退回 11.2.0（上面的 rollback）

另外在 `runbooks/README.md` 的 Procedures 加一行。

### 文件

- `docs/project-brief.md` 技術棧那行：Grafana 11.2 → 12.4。
- `monitoring-plan-v2.md:346` 歷史範例裡的 `grafana/grafana:latest`：照該處已有的「已被取代」註記方式，加一行「現行 pin 見 `docker-compose.yml`」。
- `docs/grafana-conventions.md:78`、`docs/operations.md:621`：依 12.4.15 的實際 Export 流程更新，並註明 export 出來的 JSON 是 schemaVersion 42。
- `tests/trading/test-central-deploy.sh:636` 的註解「pinned Grafana 11.2.0 was seen to rewrite or keep」：新測試在 12.4.15 驗過 refresh 的處理方式後改成 12.4.15。如果行為不一樣，就同時修 `central-deploy` 的 `check_refresh`，並跑這支測試。
- `runbooks/alertmanager-upgrade.md:114` 提到「Grafana 11.2 的 datasource health 一律回 Plugin unavailable」：依 12.4.15 的實測決定是否補一句。
- `docs/trading-monitoring-development-plan.md` 與 `docs/superpowers/plans/*` 是歷史計畫，不改。

### 新測試：`tests/grafana/test-provisioning.sh`

照 `test-access-jwt.sh` 的模式寫：image 與 env 從 `docker-compose.yml` 讀，用 `--network none`、不 pull、檔案用 `docker cp`、dummy 密碼、不碰 production。內容就是 ACCEPTANCE 要的 smoke test，讓之後每次 `verify-all` 都會跑：

- `/api/health` 的 `database=ok`，版本等於 pin。
- Log 檢查：
  - 沒有任何 `level=error`。測試裡關掉 `public_key_retrieval`，因為沒有網路一定會產生這行。
  - 沒有 `plugin.backgroundinstaller`，證明 compose 的 preinstall 設定有生效。
  - 有 unified storage 的 `folders and dashboards migration` 成功。
- `/api/search` 列出的 UID 剛好就是 repo 的 10 個，每個都在它目錄名稱的 folder。
- 每個 `/api/dashboards/uid/<uid>` 扣掉 `id`、`version` 後等於檔案，`provisionedExternalId` 等於相對路徑。比對方式和 `central-deploy` 的 `comparable()` 相同。
- 每個 dashboard 的 v2beta1 轉換都沒有失敗。
- 每個 JSON 用到的 panel type 都在 `/api/frontend/settings` 的 `.panels` 裡，而且不是 deprecated 或 angular。
- 三個 datasource 的 `uid`、`type`、`url`、`isDefault` 和 provisioning 檔一致。
- `/api/dashboards/home` 是 `overview-all`。
- `central-deploy` 的 refresh 規則（`GRAFANA_MIN_REFRESH_SECONDS=5`）：在測試自己的 folder 放合成 dashboard，確認拒絕的值會被 Grafana 改寫、接受的值保持原樣。

`verify-all` 會自動找到這個 suite，大約多花 20～30 秒。

## 步驟

- [x] S1 `SKYEYE-GRAFANA-UPGRADE-20261119` WAN-427 — Grafana 12.4.15 pin、provisioning 測試、升級 runbook 與文件
  files: docker-compose.yml, grafana/provisioning/alerting/.gitkeep, grafana/provisioning/plugins/.gitkeep, scripts/central-deploy, tests/grafana/test-provisioning.sh, tests/trading/test-central-deploy.sh, runbooks/grafana-upgrade.md, runbooks/README.md, runbooks/alertmanager-upgrade.md, docs/project-brief.md, docs/grafana-conventions.md, docs/operations.md, monitoring-plan-v2.md, docs/plans/grafana-upgrade.md
  狀態: 已完成，待 review 與 publish

- [ ] S2 `SKYEYE-GRAFANA-UPGRADE-DEPLOY` WAN-427 — 依 runbooks/grafana-upgrade.md 把 Grafana 12.4.15 部署到 monitoring-prod
  after: S1 (merged)
  kind: deploy（要使用者核准，Wan 要在瀏覽器旁）
  狀態: 未開始

## 已定的決策

- 2026-11-19 manager（dispatch）：目標是 12.x 最新、發布滿 7 天的 patch，pin 確切 tag。Rollback 是停 Grafana、還原升級前的備份、啟動 11.2.0，不直接把 image 降版。
- 2026-11-19 D36（Q1）：設 `GF_PLUGINS_PREINSTALL_DISABLED=true`，維持不預裝 plugin、只跑 pin 住的程式碼。
- 2026-11-19 D36（Q2）：保留 `tests/grafana/test-provisioning.sh` 在 repo 裡，由 `scripts/verify-all` 自動執行。
- 2026-11-19 D36（Q3）：設官方 unified-storage opt-in（`GF_UNIFIED_STORAGE_FOLDERS_FOLDER_GRAFANA_APP_ENABLEMIGRATION=true` 與 `GF_UNIFIED_STORAGE_DASHBOARDS_DASHBOARD_GRAFANA_APP_ENABLEMIGRATION=true`），讓 prod 與測試固定走同一條搬遷路徑。

## 待決問題

（無）

## 驗證

```bash
# 靜態
find grafana/dashboards -name '*.json' -exec jq empty {} +
docker compose config --quiet

# 受影響的 suite，最後一個 commit 上用同一個 lock 一起跑
hm.py lock -- sh -c 'tests/grafana/test-provisioning.sh && tests/grafana/test-access-jwt.sh &&
  tests/trading/test-central-config.sh && tests/trading/test-dashboard-semantics.sh &&
  tests/stack/test-stack-health-signals.sh && tests/windows/test-windows-central.sh'
# 只有 central-deploy 的 check_refresh 跟著改時，才加跑 tests/trading/test-central-deploy.sh
```

會讀 `docker-compose.yml` 的其他 suite（`test-alert-routing`、`test-source-clock`、`test-scrub-pipeline`、`test-windows-scrub`、`tests/windows/lib.sh`）只讀 Prometheus、Alertmanager、Loki、Alloy 的 image 那幾行，這次的改動影響不到，留給 publish 時的 `verify-all` 跑。

只記在 report、不 commit 的本機檢查（scratch，無網路或 `--internal` network，dummy 值，跑完刪掉 container 與 volume）：

1. **瀏覽器 render**：用已安裝的 Playwright Chromium 逐一打開 10 個 dashboard，不能有 `Panel plugin not found`、migration 錯誤或 page error；同時確認新 logs／table panel 與 Export 流程。
2. **Datasource 來回**：12.4.15 加上釘住的 Prometheus v2.54.1、Loki 3.1.1、Alertmanager v0.34.2（dummy config），放在 `--internal` network。測 PromQL 與 LogQL 的 `/api/ds/query`、Loki label 名稱、Alertmanager 經 proxy 呼叫 `/api/v2/status`，以及三個 datasource 的 health。
3. **升級與 rollback 彩排**，用 named volume 模擬 `grafana_data`：
   - 用 JWT 測試的方式在 11.2.0 寫入資料：token 登入建立的 viewer 與 admin、改過的角色、star、Viewer service account token。
   - 用 compose 的設定切到 12.4.15：id、角色、star 不變，token 登入與 service account 都正常，unified storage 搬遷成功；記錄 migration 時間與 db 大小。
   - 順便記錄只把 image 換回 11.2.0 時會發生什麼。
   - 用 runbook 的 tar 指令還原後啟動 11.2.0，資料與升級前相同。也實際驗證 `docker cp` 還原會有權限問題。

## 接續

- 現況：S1 已實作並完成本機驗證（含 Playwright render、datasource 來回與 11.2.0 → 12.4.15 → tar 還原彩排，結果記於 report），尚未部署。
- 下一步：S1 review 與 publish merge 到 `master` 後，取得使用者核准並在 Wan 於瀏覽器旁時執行 S2（依 `runbooks/grafana-upgrade.md`）。
- 即時狀態：有 manager 時看 `hm.py goals grafana-upgrade`；沒有 manager 時看各步驟的勾選與 `狀態:` 行，以及標頭的 Linear 卡 WAN-427。
