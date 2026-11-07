# Trading Mac mini server_id cutover: `tnauqquant-prod-1` → `macmini-m2`

> **決策：** 2026-10-31 使用者決策 D14 — 真正更名 label，不使用 Grafana display mapping。Trading01 維持 `trading01`。
>
> **本文件是 operator 程序，repo 變更 merge 後不會自動生效。** 舊 ID 只保留在本文件中，供 cutover、rollback 與查詢歷史使用。
>
> **狀態：** 已於 2026-11-01 完成，見[執行紀錄](#執行紀錄)。

## 執行前必讀

- **Step 2 必須在 production Mac mini 上、以 Trading 使用者執行**（repo root `/Users/wan/projects/tnauqquant` 的那臺 host）。開發機連不到這臺 host，所以 Step 2 要由使用者本人執行，或由使用者提供可用的 SSH 目標後代為執行。
- **Cutover 時窗之前，monitoring-prod 不得 `git pull`，也不得執行 `scripts/central-deploy`。** 提前部署（或 Prometheus 重啟）會在 host agent 改名前就把中央 inventory 改成 `macmini-m2`，導致舊名資料不再被 recording rules 收錄，新名也同時觸發 `TradingTelemetryMissing`。
- `scripts/central-deploy` 一律部署 `origin/master` 的最新 commit，無法指定 SHA。所以這個 PR 一旦 merge，**任何中央部署（即使是為了其他無關變更）都會把改名一起上線**。這個 PR 應在 cutover 時窗開始時才 merge；merge 後到 Step 4 完成前，不得部署其他變更，也不得 merge 其他 PR 到 master：central-deploy 會自己 fetch 並部署當下 master 的最新 commit，Step 4 的 SHA 閘門擋不住閘門通過後幾秒內才進來的 commit。
- 所有 Trading 告警目前都是 `notification_mode="shadow"`（送往 `shadow-null`），cutover 不會發出 Telegram／email。Step 1 的 silence 是安全網，避免 cutover 前已有告警被 promote 成正式通知。
- 順序固定為**先 host agent、後中央 rules**，兩步間隔目標 ≤ 5 分鐘。這段時間舊名會短暫出現 shadow `TradingTelemetryMissing`，新名在 inventory 更新前不會被評估。
- Cutover 時窗（UTC 起訖）必須記錄，並從 Trading shadow/canary 證據中排除。此更名不改任何告警 expression、threshold、`for`、severity 或 routing，所以不需要新一輪 shadow/canary；Step 5 的前後比對就是新 identity 的 smoke check。

## 變數

| 名稱 | 說明 |
|---|---|
| `MERGE` | 此更名 PR 在 master 的 merge commit 完整 SHA，Step 0 前先設定；Step 0 與 Step 4 以 `central-deploy --expect "$MERGE"` 確保只在 `origin/master` 仍等於它時才驗證或部署 |
| `OLD` | Step 0 時 monitoring-prod 已部署的 HEAD（Rollback B 由它還原 inventory 檔案） |
| `CUT` | monitoring-prod 上保存 cutover 證據的目錄，例如 `$HOME/serverid-cutover-20261031` |

monitoring-prod 上的共用 helper：

```bash
q() { curl -fsS --get http://127.0.0.1:9090/api/v1/query --data-urlencode "query=$1" | jq -c '.data.result'; }
targets() { q 'trading_target_info' | jq -S '[.[].metric | del(.__name__)] | sort'; }
```

## Step 0 — 唯讀前置檢查

monitoring-prod：

```bash
CUT="$HOME/serverid-cutover-20261031"; mkdir -p "$CUT"
cd /home/ubuntu/SkyEye
OLD=$(git rev-parse HEAD); echo "$OLD" | tee "$CUT/old-head"
# 只驗證、不移動 checkout、不 reload：在暫時 worktree 跑 promtool check config、全部 rule tests
# 與衍生的 Trading inventory test，並列出將被部署的 commits（只應是此更名 PR）。
# --expect：fetch 後 origin/master 不等於 MERGE 就在驗證前結束，印出
# `--expect names … but origin/master is …`；此時不要開始 Step 1
scripts/central-deploy --dry-run --expect "${MERGE:?set MERGE first}" 2>&1 | tee "$CUT/central-deploy-dry-run.log"
scripts/central-deploy --status | tee "$CUT/central-status-pre.log"

# 必須為 []；若舊名有任何 firing 告警，先處理事件、延後 cutover
q 'ALERTS{product="tnauqquant",server_id="tnauqquant-prod-1",alertstate="firing"}'

# 前後比對基準。inventory 不寫死筆數；可能已包含其他 task 加入的 target（例如 trading01/lighter-mainnet-btc-canary）
targets | tee "$CUT/pre-targets.json"
jq -S 'map(if .server_id == "tnauqquant-prod-1" then .server_id = "macmini-m2" else . end) | sort' \
  "$CUT/pre-targets.json" | tee "$CUT/expected-targets.json"
q 'tnauqquant_target_info' | jq -S '[.[].metric | del(.__name__)] | sort' > "$CUT/pre-legacy-targets.json"
q 'count by (__name__) ({__name__=~"trading_strategy_.+",server_id="tnauqquant-prod-1"})' \
  | jq -S 'map({(.metric.__name__): .value[1]}) | add' | tee "$CUT/pre-counts.json"
```

`expected-targets.json` 必須只把 `tnauqquant-prod-1` 換成 `macmini-m2`，其他 target 原樣保留。

dry run 印出 `--expect names … but origin/master is …` 時不要進入 Step 1。這個區塊其餘命令都是唯讀，照樣執行，用 `--dry-run` 列出的 commits 確認 merge 後多出什麼。核准人同意它們一起上線，才把 `MERGE` 設為新的 `origin/master` 完整 SHA 並重跑 Step 0；否則延後 cutover。

`--dry-run` 必須以 `Dry run: validation passed` 結束。若它拒絕部署（dirty tree、checkout 不在 master、loaded config paths 內有 untracked 檔案、需要 container recreate 的路徑、dashboard 或 Loki rule 驗證失敗、Grafana token 缺失或無效），先在 cutover 時窗外排除原因，不要改用手動 `git pull`。Grafana token 的建立步驟見 [README](../README.md#one-time-setup-for-scriptscentral-deploy)；monitoring-prod 沒有 applied 紀錄時，這次部署也需要 token。

也檢查 Alertmanager silences（`http://127.0.0.1:9093/#/silences`）：記下 matcher 含 `server_id="tnauqquant-prod-1"` 的 silence，Step 6 再處理。

production Mac mini（唯讀）：

```bash
ENV_FILE="$(brew --prefix)/etc/alloy/config.env"
grep -cE '^(export )?TQ_SERVER_ID=tnauqquant-prod-1$' "$ENV_FILE"   # 必須為 1
stat -f '%Lp' "$ENV_FILE"                                           # 必須為 600
launchctl print "gui/$(id -u)/com.wanbrain.skyeye-trading-probe" >/dev/null && echo probe-loaded
launchctl print "gui/$(id -u)/com.wanbrain.skyeye-trading-pnl-history" >/dev/null && echo history-loaded
curl -fsS http://127.0.0.1:12345/-/ready
```

不要印出 `config.env` 全文（內含 Cloudflare service token）。

## Step 1 — Silence（monitoring-prod）

```bash
date -u +%FT%TZ | tee "$CUT/cutover-start"
sudo docker compose -f /home/ubuntu/SkyEye/docker-compose.yml exec -T alertmanager \
  amtool silence add --alertmanager.url=http://127.0.0.1:9093 --duration=2h \
  --author=operator \
  --comment="D14 server_id rename cutover tnauqquant-prod-1 -> macmini-m2" \
  'product="tnauqquant"' 'server_id=~"tnauqquant-prod-1|macmini-m2"' | tee "$CUT/silence-id"
```

## Step 2 — Host agent 改名（production Mac mini，Trading 使用者）

```bash
ENV_FILE="$(brew --prefix)/etc/alloy/config.env"
cp -p "$ENV_FILE" "$ENV_FILE.bak-20261031"
sed -i '' -E 's/^(export )?TQ_SERVER_ID=tnauqquant-prod-1$/\1TQ_SERVER_ID=macmini-m2/' "$ENV_FILE"
grep -cE '^(export )?TQ_SERVER_ID=macmini-m2$' "$ENV_FILE"          # 必須為 1
grep -cE '^(export )?TQ_SERVER_ID=' "$ENV_FILE"                     # 必須為 1
stat -f '%Lp' "$ENV_FILE"                                           # 必須為 600

brew services restart grafana/grafana/alloy
launchctl kickstart -k "gui/$(id -u)/com.wanbrain.skyeye-trading-probe"
launchctl kickstart -k "gui/$(id -u)/com.wanbrain.skyeye-trading-pnl-history"
sleep 20
curl -fsS http://127.0.0.1:12345/-/ready

TF="$(brew --prefix)/var/lib/alloy/trading-textfile"
grep -ho 'server_id="[^"]*"' "$TF"/*.prom | sort | uniq -c            # 只能出現 macmini-m2
tail -n 50 "$(brew --prefix)/var/log/alloy/trading-probe.err.log"
tail -n 50 "$(brew --prefix)/var/log/alloy/trading-pnl-history.err.log"
```

- launchd plist 不含 server_id，probe 與 history 每輪都會重新 `source` config.env，所以**不重新 render plist，也不重跑 `setup-macos.sh`**（避免連帶更換已部署的 probe／history 腳本版本）。
- 不觸碰 Trading 程序、tmux 或 sidecar。
- P&L history cache 不以 server_id 為 key，30 日累積點會立即以新 label 輸出。
- 預期 Alloy `loki.source.file` 的 positions 以檔案路徑加 labels 為 key：24 小時內有更新的 raw log 會從頭重讀，並以 log 內的原始時間戳補進 `macmini-m2` stream。這屬預期行為，Step 5 會記錄補入範圍。

## Step 3 — 確認新 raw series 抵達中央（monitoring-prod，≤ 2 分鐘）

```bash
q 'time() - tnauqquant_probe_timestamp_seconds{product="tnauqquant",server_id="macmini-m2"}'            # 值 < 60
q 'time() - tnauqquant_pnl_history_build_timestamp_seconds{product="tnauqquant",server_id="macmini-m2"}' # 值 < 120
q 'tnauqquant_probe_timestamp_seconds{product="tnauqquant",server_id="tnauqquant-prod-1"}'              # 數分鐘內變為 []
```

Step 3 失敗時，中央尚未變更，執行 **Rollback A**。

## Step 4 — 部署中央 rules（monitoring-prod）

`--expect "$MERGE"` 讓 central-deploy 在 fetch 之後先比對：`origin/master` 不等於 `MERGE` 時，在任何驗證、移動 checkout 或 reload 之前就結束（`MERGE` 未設定時 shell 直接拒絕執行）。

```bash
cd /home/ubuntu/SkyEye
# central-deploy 先在暫時 worktree 用 --entrypoint /bin/promtool 跑 check config、rule tests
# 與衍生的 inventory test；全部通過才 fast-forward 並 reload，任一失敗就不移動 checkout、不 reload
scripts/central-deploy --expect "${MERGE:?set MERGE first}" 2>&1 | tee "$CUT/central-deploy.log"; echo "rc=${PIPESTATUS[0]}"
```

依 `central-deploy.log` 判斷結果：

- **`--expect names … but origin/master is …`**：central-deploy 在驗證前就結束，中央沒有任何變更。用 `git log --oneline "$MERGE..origin/master"` 與 `scripts/central-deploy --dry-run` 重新審閱多出的 commit。核准人同意它們一起上線，才把 `MERGE` 設為新的 `origin/master` 完整 SHA 並重跑這個區塊；不同意，或無法在 Step 1 的 silence 到期前完成審閱，執行 **Rollback A**。
- **`rc=0` 且最後一行是 `central-deploy: done; applied <12 碼 SHA>`**：成功，接著跑下面的部署後檢查。
- **在 `Checkout fast-forwarded` 之前失敗**（promtool check、rule test、inventory test、dashboard 或 Loki rule 驗證、Grafana token 或前置檢查失敗）：中央沒有任何變更，Prometheus 仍是舊 inventory。不要重試或手動 reload，執行 **Rollback A**。
- **在 `Checkout fast-forwarded` 之後失敗**（`Prometheus rejected the reload` 或 `unsuccessful config reload`）：磁碟已是新版，Prometheus 未套用。不要重啟 Prometheus，也不要照 central-deploy 提示的 `git reset --hard`；執行 **Rollback B**，再執行 **Rollback A**。
- **訊息含 `is published but not loaded`**（只有 monitoring-prod 沒有 applied 紀錄時才會在這次 cutover 出現）：Prometheus 已通過 reload 檢查，改名已生效，但 Loki 或 Grafana 未確認載入，applied 紀錄沒有寫入。不要執行 Rollback，也不要照提示 `git reset --hard`。排除訊息指出的原因後重跑這個區塊，直到 `rc=0`，再跑部署後檢查。
- **訊息同時含 `if that is a UI edit`**：沒有 applied 紀錄時，central-deploy 會比對每一個 dashboard，所以在 UI 改過、沒有 export 回 Git 的 dashboard 會擋住紀錄，訊息會指名 uid，而且沒有略過的旗標。處理方式同上一項，不要 Rollback。修改不用保留，就在 Grafana 的 dashboard settings → Versions 還原成 Git 的版本，再重跑這個區塊。要保留，就 export 回 Git 並 merge，核准後依 `STOP:` 那一項把 `MERGE` 改成新的 SHA，再重跑這個區塊。

部署後檢查（只在成功時執行）：

```bash
[ "$(git rev-parse HEAD)" = "$MERGE" ] && echo HEAD-IS-MERGE
scripts/central-deploy --status | tee "$CUT/central-status-post.log"   # Prometheus last reload successful: 1
sleep 70
targets | tee "$CUT/post-targets.json"
diff "$CUT/expected-targets.json" "$CUT/post-targets.json" && echo TARGETS-OK
q 'tnauqquant_target_info' | jq -S '[.[].metric | del(.__name__)] | sort' > "$CUT/post-legacy-targets.json"
jq -S 'map(if .server_id == "tnauqquant-prod-1" then .server_id = "macmini-m2" else . end) | sort' \
  "$CUT/pre-legacy-targets.json" | diff - "$CUT/post-legacy-targets.json" && echo LEGACY-OK
```

`--expect` 是在 central-deploy 自己 fetch 之後比對，所以成功時 HEAD 必定是 `MERGE`。沒有印出 `HEAD-IS-MERGE` 表示 checkout 被別人移動過：停下，用 `git log --oneline "$MERGE..HEAD" | tee "$CUT/extra-commits.log"` 記錄並交核准人審閱，再決定是否繼續比對 inventory。

預期的 inventory 等於 **cutover 前的集合，只把 `tnauqquant-prod-1` 換成 `macmini-m2`**，其他 target（包括可能已存在的 `trading01/lighter-mainnet-btc-canary`）都要原樣保留。不要拿固定筆數比對。

Loki rules、Grafana dashboards 與 Alertmanager config 沒有變更。若 monitoring-prod 從未用 central-deploy 成功部署過（沒有 `.git/skyeye-central-deploy.applied`），它會另外跑 `amtool check-config`、reload Alertmanager，並確認 Loki 與 Grafana 已載入現有內容；config 未變，silence 不受影響。

## Step 5 — 驗證（Step 4 後 ≥ 5 分鐘）

```bash
q 'count by (__name__) ({__name__=~"trading_strategy_.+",server_id="macmini-m2"})' \
  | jq -S 'map({(.metric.__name__): .value[1]}) | add' | tee "$CUT/post-counts.json"
diff <(jq -S keys "$CUT/pre-counts.json") <(jq -S keys "$CUT/post-counts.json") && echo NAMES-OK   # 必須同一組 metric
diff "$CUT/pre-counts.json" "$CUT/post-counts.json" && echo COUNTS-OK                             # 數量差異見下方說明
q 'count by (__name__) ({__name__=~"trading_strategy_.+",server_id="tnauqquant-prod-1"})'   # []
q 'ALERTS{product="tnauqquant",server_id=~"tnauqquant-prod-1|macmini-m2"}'                  # []
q 'tnauqquant_pnl_history_valid{product="tnauqquant",server_id="macmini-m2"}'               # 1
q 'trading_target_info unless on (product, environment, server_id, strategy) (time() - trading_strategy_probe_timestamp_seconds < 180)'  # []
```

`pre-counts.json` 與 `post-counts.json` 若因 cycle、exchange 或 point 數量自然變動而有差異，只接受同一組 metric 名稱下的數量差異，並記錄原因；缺少任何 metric 名稱都算失敗。

Grafana Explore（datasource `loki`）：

- `{product="tnauqquant",environment="production",server_id="macmini-m2"}` 有新的 log 行，`run_id` 與 `level` labels 正常。
- `sum(count_over_time({product="tnauqquant",server_id="macmini-m2"}[24h]))` 記錄 positions 重讀補入的範圍。
- Loki ruler 在 `macmini-m2` 上沒有新的 Trading 告警。

Grafana dashboards：

- **Trading fleet** 列出 `macmini-m2 / toobit-mexc-btc`，其他 target 不變。
- **Trading detail** 選 `macmini-m2` 後各 panel 有值，「本輪實現損益 · 週期走勢」顯示完整的本輪曲線。
- `server_id` 下拉選單在當日時間範圍內可能仍出現 `tnauqquant-prod-1`，選它只會得到空值，隔日自然消失。

## Step 6 — 收尾

- 觀察 30 分鐘沒有 `ALERTS` 後，提前 expire Step 1 的 silence：
  `sudo docker compose -f /home/ubuntu/SkyEye/docker-compose.yml exec -T alertmanager amtool silence expire --alertmanager.url=http://127.0.0.1:9093 "$(cat "$CUT/silence-id")"`
- Step 0 記下的舊名 silences 改寫為 `server_id="macmini-m2"` 或 expire。
- 執行 `date -u +%FT%TZ | tee "$CUT/cutover-end"`，把 cutover 起訖寫進 work-log，並註明這段時間排除於 shadow/canary 證據之外。
- 新設定穩定 ≥ 24 小時後，刪除 Mac mini 上的 `config.env.bak-20261031`。
- 通知 operator 更新含 `var-server_id=tnauqquant-prod-1` 的 Grafana bookmark 或分享連結。

## 執行紀錄

**Shadow/canary 證據要排除 2026-11-01T13:31:29Z – 2026-11-01T15:31:29Z。** 結束時間取 Step 1 silence 到期的時間。

| 項目 | 時間（UTC，2026-11-01） | 結果 |
|---|---|---|
| Step 1 silence | 13:31:29 – 15:31:29 | 2 小時，自然到期，沒有延長 |
| Step 2 host 改名 | 14:54:53 | textfile 只剩 `server_id="macmini-m2"` |
| Step 3 新 series 抵達中央 | 14:55:03 | 通過 |
| Step 4 central-deploy | 14:55:25 | applied `256ea5c8656e`（PR #58），`HEAD-IS-MERGE`、`TARGETS-OK`、`LEGACY-OK` 都通過，沒有多出的 commit |
| Step 5 驗證 | 15:00:34 | 通過。metric 名稱由 17 個變 29 個，多的 12 個 P&L metric 來自 14:07:45 的 run 重啟，沒有缺少。Grafana 畫面未檢查 |

- Step 2 到 Step 4 間隔約 32 秒，低於 5 分鐘的目標。
- Loki 從 13:30:05Z 起補入 `macmini-m2` stream，當時 24 小時計數 229。
- Cutover 開始時沒有舊名 silence，不需要改寫。
- 觀察期間 `TradingRunBindingInvalid`（`macmini-m2` / `toobit-mexc-btc`，shadow）於 15:31:44Z 開始 firing。Manager 判定這是 Trading 端狀態，與更名無關：程序約 15:02Z 停止，之後 `config_snapshot_match=0`，而這條 rule 不看 inventory。

## 歷史資料

- 更名前的 Prometheus 資料已在 2026-11-02 03:26Z 刪除。範圍是 `{server_id="tnauqquant-prod-1"}` 的全部 series，所以舊 label 查不到東西，跨 cutover 的 Prometheus 查詢只會回傳 `macmini-m2`。這推翻了原本「留到 30 天 retention 到期」的做法。
- 日期早於 2026-11-02 的 S3 備份還含舊名資料，還原這些備份會把它帶回來。
- Loki 沒有刪除。262 個舊名 streams 留到 720h retention 到期，要用舊 label 查：
  - `{product="tnauqquant",environment="production",server_id="tnauqquant-prod-1"}`
- Dashboard 不加雙名過渡查詢。Prometheus panel 全是 instant query；週期走勢與 P&L history 由 host 每輪重新輸出，所以不會中斷。
  - `{product="tnauqquant",environment="production",server_id="tnauqquant-prod-1"}`
  - 跨 cutover 查看：`trading_strategy_current_real_pnl_usdt{server_id=~"tnauqquant-prod-1|macmini-m2",strategy="toobit-mexc-btc"}`

## Rollback

**A — 中央尚未變更（Step 4 前）**，在 production Mac mini 上執行：

```bash
ENV_FILE="$(brew --prefix)/etc/alloy/config.env"
cp -p "$ENV_FILE.bak-20261031" "$ENV_FILE"
grep -cE '^(export )?TQ_SERVER_ID=tnauqquant-prod-1$' "$ENV_FILE"   # 必須為 1
brew services restart grafana/grafana/alloy
launchctl kickstart -k "gui/$(id -u)/com.wanbrain.skyeye-trading-probe"
launchctl kickstart -k "gui/$(id -u)/com.wanbrain.skyeye-trading-pnl-history"
grep -ho 'server_id="[^"]*"' "$(brew --prefix)/var/lib/alloy/trading-textfile"/*.prom | sort | uniq -c   # 只剩 tnauqquant-prod-1
```

**B — 中央已部署，或 Step 4 在 fast-forward 之後失敗**：先做 A，再在 monitoring-prod 執行：

```bash
cd /home/ubuntu/SkyEye
git checkout "$(cat "$CUT/old-head")" -- prometheus/rules/trading-targets.yml
# 與 Step 4 相同的閘門：promtool check 成功才 reload
sudo docker run --rm --entrypoint promtool -v "$PWD/prometheus:/etc/prometheus:ro" \
  prom/prometheus:v2.54.1 check config /etc/prometheus/prometheus.yml \
  && curl -fsS -X POST http://127.0.0.1:9090/-/reload && echo RELOADED
sleep 70
targets | diff "$CUT/pre-targets.json" - && echo ROLLBACK-OK
```

- 這裡不用 `scripts/central-deploy`：它只能部署到 `origin/master` 的最新 commit，而那仍包含改名。
- 也不用它提示的 `git reset --hard`：那會讓 checkout 落後 master，下一次 `scripts/central-deploy` 會直接把改名部署回來。
- 改用單檔還原：`prometheus/rules/trading-targets.yml` 成為 local modification 後，`scripts/central-deploy` 會因 dirty tree 拒絕部署，直到 revert 完成。

接著以 revert PR 讓 master 回到舊 inventory。revert merge 後，在 monitoring-prod 執行 `git checkout -- prometheus/rules/trading-targets.yml && scripts/central-deploy`，讓 checkout 與 applied 記錄回到 revert commit。

Rollback 同樣會觸發一次 positions 重讀，log 會以原始時間戳補進舊 label，不影響正確性。最後依 Step 6 處理 silence 與 cutover 記錄。
