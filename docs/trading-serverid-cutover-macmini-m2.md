# Trading Mac mini server_id cutover: `tnauqquant-prod-1` → `macmini-m2`

> **決策：** 2026-10-31 使用者決策 D14 — 真正更名 label，不使用 Grafana display mapping。Trading01 維持 `trading01`。
>
> **本文件是 operator 程序，repo 變更 merge 後不會自動生效。** 舊 ID 只保留在本文件中，供 cutover、rollback 與查詢歷史使用。

## 執行前必讀

- **Step 2 必須在 production Mac mini 上、以 Trading 使用者執行**（repo root `/Users/wan/projects/tnauqquant` 的那臺 host）。開發機連不到這臺 host，所以 Step 2 要由使用者本人執行，或由使用者提供可用的 SSH 目標後代為執行。
- **Cutover 時窗之前，monitoring-prod 不得 `git pull` 這次 merge。** 提前 pull 再 reload（或 Prometheus 重啟）會在 host agent 改名前就把中央 inventory 改成 `macmini-m2`，導致舊名資料不再被 recording rules 收錄，新名也同時觸發 `TradingTelemetryMissing`。若 master 在此之前另有需要部署的變更，只能部署到這次 merge 之前的 commit。
- 所有 Trading 告警目前都是 `notification_mode="shadow"`（送往 `shadow-null`），cutover 不會發出 Telegram／email。Step 1 的 silence 是安全網，避免 cutover 前已有告警被 promote 成正式通知。
- 順序固定為**先 host agent、後中央 rules**，兩步間隔目標 ≤ 5 分鐘。這段時間舊名會短暫出現 shadow `TradingTelemetryMissing`，新名在 inventory 更新前不會被評估。
- Cutover 時窗（UTC 起訖）必須記錄，並從 Trading shadow/canary 證據中排除。此更名不改任何告警 expression、threshold、`for`、severity 或 routing，所以不需要新一輪 shadow/canary；Step 5 的前後比對就是新 identity 的 smoke check。

## 變數

| 名稱 | 說明 |
|---|---|
| `MERGE` | 此更名 PR 在 master 的 merge commit SHA |
| `OLD` | Step 0 時 monitoring-prod 已部署的 HEAD |
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
git fetch origin
git merge-base --is-ancestor "$OLD" "$MERGE" && echo OK-ancestor
git diff --stat "$OLD" "$MERGE"     # 只應出現此更名 PR 的檔案；若有其他未部署變更，先確認可一起上線

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

```bash
cd /home/ubuntu/SkyEye
git merge --ff-only "$MERGE" && git rev-parse HEAD       # 必須等於 $MERGE
sudo docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" prom/prometheus:v2.54.1 \
  promtool check config /etc/prometheus/prometheus.yml
curl -fsS -X POST http://127.0.0.1:9090/-/reload
sleep 70
targets | tee "$CUT/post-targets.json"
diff "$CUT/expected-targets.json" "$CUT/post-targets.json" && echo TARGETS-OK
q 'tnauqquant_target_info' | jq -S '[.[].metric | del(.__name__)] | sort' > "$CUT/post-legacy-targets.json"
jq -S 'map(if .server_id == "tnauqquant-prod-1" then .server_id = "macmini-m2" else . end) | sort' \
  "$CUT/pre-legacy-targets.json" | diff - "$CUT/post-legacy-targets.json" && echo LEGACY-OK
```

預期的 inventory 等於 **cutover 前的集合，只把 `tnauqquant-prod-1` 換成 `macmini-m2`**，其他 target（包括可能已存在的 `trading01/lighter-mainnet-btc-canary`）都要原樣保留。不要拿固定筆數比對。

Loki rules、Grafana dashboards 與 Alertmanager config 沒有變更，不需重啟。

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

## 歷史資料

- 更名前的 Prometheus raw／recorded series 與 Loki streams 留在 `server_id="tnauqquant-prod-1"`，直到 30 天 retention 到期，不做改寫或複製。
- Dashboard 不加雙名過渡查詢。Prometheus panel 全是 instant query；週期走勢與 P&L history 由 host 每輪重新輸出，所以不會中斷。受影響的只有 Explore 中跨 cutover 的時間序列，以及 cutover 當日未被重讀補回的 log。
- 查詢更名前資料，在 Explore 使用舊 label，例如：
  - `trading_strategy_current_real_pnl_usdt{server_id="tnauqquant-prod-1",strategy="toobit-mexc-btc"}`
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

**B — 中央已部署（Step 4 後）**：先做 A，再在 monitoring-prod 執行：

```bash
cd /home/ubuntu/SkyEye
git checkout "$(cat "$CUT/old-head")" -- prometheus/rules/trading-targets.yml
curl -fsS -X POST http://127.0.0.1:9090/-/reload
sleep 70
targets | diff "$CUT/pre-targets.json" - && echo ROLLBACK-OK
```

接著以 revert PR 讓 master 與部署一致。revert merge 之前，monitoring-prod 不得 `git pull`，因為 `prometheus/rules/trading-targets.yml` 目前是 local modification。

Rollback 同樣會觸發一次 positions 重讀，log 會以原始時間戳補進舊 label，不影響正確性。最後依 Step 6 處理 silence 與 cutover 記錄。
