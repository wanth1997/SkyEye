# Trading01 新增 `popdex-multi-accounts` 監控與 `popdex-btc` 切換（operator 程序）

> **來源：** Linear WAN-928（SkyEye task `POPDEX-MULTI-20261126`）。Trading01 新增 tnauqquant lane `popdex-multi-accounts`（PopDEX，`BTC_USDT_PERP`，`routing.mode: random` 輪替 `popdex-main` 與 `popdex-rot2` 兩支帳號，不互相對沖），切換上線後將取代 `popdex-btc`。設計計畫見 [docs/plans/popdex-multi-accounts.md](plans/popdex-multi-accounts.md)。
>
> **本文件是 operator 程序，repo 變更 merge 後不會自動生效。**
>
> - 通用的 add／remove 與共用 probe 更新規則見 [agents/alloy/trading/README.md](../agents/alloy/trading/README.md)。
> - 硬性限制、staging、central-deploy 判讀與 R5 沿用 [Trading01 PopDEX rollout](trading01-popdex-rollout.md)（以下稱「rollout 文件」）。
> - **本次變更修改了共用 `probe.sh`**，因此 Step 2 必須先暫停並停用 Trading01 上所有既有 `skyeye-trading-probe@*` timer／service，才能讓 `setup-linux.sh add` 更新共用 `probe.sh` 並安裝新 lane。本次**不**升級 Alloy、**不**動其他 lane 的設定檔內容。
> - **狀態：** repo 已就緒，尚未在 Trading01 或 monitoring-prod 執行；等待 tnauqquant manager 通知切換時窗後再派 operator 執行。

## Lane 事實與待核對的值

來自 tnauqquant 側確認（D4）並已預填於 `agents/alloy/trading/deployment-linux-popdex-multi-accounts.env.example`：

| 項目 | 值 |
|---|---|
| systemd instance | `tnauqquant@popdex-multi-accounts.service` |
| config | `/home/ubuntu/tnauqquant/config/popdex_multi_accounts_config.yaml` |
| `instance_id` | `popdex-multi-accounts` |
| lane env（**禁止讀取**） | `/home/ubuntu/tnauqquant/.env.popdex-multi-accounts` |
| executors | `popdex-main`（沿用 `popdex-btc` 帳號）、`popdex-rot2`（新帳號），於 `TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex` |
| run-state | `/home/ubuntu/tnauqquant/run-state/popdex-multi-accounts/` |
| raw log | `/home/ubuntu/tnauqquant/logs/live-runs/<YYYYMMDD_HHMMSS>_popdex_multi_accounts_config.raw.log`（嚴格 contract glob） |
| textfile | `tnauqquant-popdex-multi-accounts.prom` |
| 預填 `TQ_EXECUTABLE` | `/home/ubuntu/tnauqquant/bin/popdex-multi-accounts`（Step 1 **必須**依主機 `manager.env` 核對實際路徑） |
| 安裝時狀態 | `TQ_STRATEGY_DISABLED=1`：lane 安裝後保持停用，等 Wan 完成手動 canary cycle 並決定切換時才改為 `0` |

**operator 必須在 Trading01 唯讀核對的值：**

| 值 | 怎麼核對 | 填錯的後果 |
|---|---|---|
| `TQ_EXECUTABLE` | 唯讀查 `/etc/tnauqquant/instances/popdex-multi-accounts/manager.env` 的 `TNAUQ_EXPECTED_BIN` 一行，確認是**可執行一般檔案**（`test -f && test -x`，非目錄、非共用 launcher `/usr/local/sbin/tnauqquant-service`）。可能是 `/home/ubuntu/tnauqquant/bin/popdex-multi-accounts` 或 `/home/ubuntu/tnauqquant/bin/popdex-multi-accounts/quant`，以主機 `TNAUQ_EXPECTED_BIN` 與 Step 5 manifest `.executable` 為準。 | 填成目錄或錯路徑：`process_count 0`、測試 cycle 不會出現 `TradingUnexpectedProcess`、出現 `TradingRunBindingInvalid`。填成共用 launcher：`setup-linux.sh` 不重複檢查直接拒絕。 |
| `TQ_EXECUTOR_MAP` | 預填 `popdex-main=popdex,popdex-rot2=popdex`。Step 1 唯讀核對 `popdex_multi_accounts_config.yaml` 中 `routing.accounts[].name` 剛好為這兩支且 `routing.mode: random`；Step 5 用 raw log 的 `equity_usdt_by_executor`、`volume_usd_by_executor`、`cycle_executor` 核對。 | 未在 `TQ_EXECUTOR_MAP` allowlist 內的 executor 會被 probe 丟棄：合併成交額漏計，且 per-executor 餘額／損益／週期分項不輸出或漏計。 |
| `TQ_INSTANCE_ID` | 預填 `popdex-multi-accounts`，Step 1 核對 config 的 `instance_id:`（與其他 lane 不重複），Step 5 核對 manifest `.instance_id`。 | `strategy_identity_ok 0`；出現 `TradingRunBindingInvalid`。 |

## 硬性限制

rollout 文件「執行前必讀」的硬性限制全部適用：

- **不得 start、stop、restart、enable 或 disable 任何 `tnauqquant@*` service 或 timer，不得修改 tnauqquant 的 config、env、run-state 或程式。** 本文件對 `tnauqquant@*` 一律只做唯讀檢查；`tnauqquant@popdex-btc` 的停用與 `tnauqquant@popdex-multi-accounts` 的啟動皆由 Wan／tnauqquant 側執行。
- **順序固定為先 host、後中央。** 本 PR 已透過 `scripts/trading-target add` 加入 `popdex-multi-accounts` inventory row；**PR merge 之後、Step 3 確認 `popdex-multi-accounts` 已在 remote-write 之前，monitoring-prod 不得執行 `scripts/central-deploy`（包括為了其他變更）**，否則中央會為尚未安裝 probe 的目標觸發 `TradingTelemetryMissing`（shadow）。
- **時間：** 每個 `[CHANGE]` 步驟（含 `central-deploy` dry-run 與正式部署）避開 UTC 18:15–19:30（18:30Z Trading01 每日重啟、19:00Z monitoring-prod 備份）。
- **Alloy 只 reload。** 絕不使用 `--restart-alloy`；`add` 要求它就是 STOP。
- **禁止讀取憑證檔：** 不得印出或複製 `popdex_multi_accounts_config.yaml` 全文，也不得開啟 `/home/ubuntu/tnauqquant/.env.popdex-multi-accounts` 或 `manager.env` 中 `TNAUQ_ENV_FILE` 指向的檔案。`manager.env` 只用 `grep '^TNAUQ_EXPECTED_BIN='` 取那一行。
- **中止規則：** 若在 Step 3 通過前 STOP，下一次 `central-deploy` 之前由 manager 先執行 `scripts/trading-target remove --server trading01 --strategy popdex-multi-accounts` 開 PR 並 merge，master 不留沒有 probe 的 row。

## Step 0 — Staging

照 rollout 文件 Phase 0 將含本次變更的 master commit（`MERGE` 完整 SHA）stage 到 Trading01 的 `/home/ubuntu/skyeye-staging/popdex-$M7`。在 operator 本機先確認：

```bash
git cat-file -e "$MERGE:agents/alloy/trading/deployment-linux-popdex-multi-accounts.env.example" && echo MERGE-HAS-POPDEX-MULTI
```

## Step 1 — 唯讀前置檢查與基準 `[READ-ONLY]`

**Trading01 與 monitoring-prod 兩邊全部通過才進 Step 2；任一項不符就 STOP。**

### Trading01（root shell）

```bash
sudo -i
MERGE=<完整 SHA>; M7=${MERGE:0:7}
STAGE=/home/ubuntu/skyeye-staging/popdex-$M7
SETUP="$STAGE/agents/alloy/trading/setup-linux.sh"
WORK=/root/skyeye-popdex-multi-$(date -u +%Y%m%dT%H%M%SZ); install -d -m 700 "$WORK"
declare -p MERGE M7 STAGE SETUP WORK >"$WORK/vars"

date -u +%H:%M                                           # 不在 18:15–19:30
alloy --version | head -n 1                              # v1.16.3 或 v1.18.1（須在 alloy-versions.env 清單內）
systemctl is-active alloy                                # active
systemctl show -p CanReload --value alloy                # yes
grep -cxF 'CONFIG_FILE="/etc/alloy"' /etc/default/alloy  # 1
test ! -e /etc/skyeye-trading/instances/popdex-multi-accounts.env && echo NOT-INSTALLED-YET
```

記錄所有既有 `skyeye-trading-probe@*` 的 timer 狀態並備份既有 env（Step 2 更新共用 `probe.sh` 與 rollback 需要）：

```bash
date +%s >"$WORK/start-epoch"
for env in /etc/skyeye-trading/instances/*.env; do
  s="$(basename "$env" .env)"; e=disabled; a=inactive
  systemctl is-enabled --quiet "skyeye-trading-probe@$s.timer" && e=enabled
  systemctl is-active --quiet "skyeye-trading-probe@$s.timer" && a=active
  printf '%s %s %s\n' "$s" "$e" "$a"
  install -m 600 "$env" "$WORK/$s.env"
done | tee "$WORK/timers.before"
```

唯讀確認新 lane 尚未啟動、timer 未啟用：

```bash
systemctl is-active tnauqquant@popdex-multi-accounts.service  | tee "$WORK/lane.active"     # inactive
systemctl is-enabled tnauqquant@popdex-multi-accounts.service | tee "$WORK/lane.enabled"    # disabled、masked 或 static
pgrep -a -f 'popdex_multi_accounts_config' | tee "$WORK/lane.processes"                     # 沒有輸出
systemctl list-unit-files --type=timer --no-legend >"$WORK/timer-files" && [ -s "$WORK/timer-files" ] && echo TIMER-FILES-READ
systemctl list-units --type=timer --all --no-legend --plain >"$WORK/timer-units" && [ -s "$WORK/timer-units" ] && echo TIMER-UNITS-READ
{ awk '{ print $1 }' "$WORK/timer-files" | sed 's/@[.]timer$/@popdex-multi-accounts.timer/'; awk '{ print $1 }' "$WORK/timer-units"; } |
  sort -u | while read -r t; do
    printf '%s triggers=%s enabled=%s active=%s\n' "$t" "$(systemctl show -p Triggers --value "$t")" \
      "$(systemctl is-enabled "$t" 2>&1)" "$(systemctl is-active "$t")"
  done | tee "$WORK/timers"
```

任何啟動 `tnauqquant@popdex-multi-accounts.service` 的 timer 若非 `inactive` 且 `disabled`/`masked`/`static`：**STOP，回報 Wan**。

唯讀核對路徑、`TQ_INSTANCE_ID`、`TQ_EXECUTABLE` 與 `routing.accounts[].name`：

```bash
CFG=/home/ubuntu/tnauqquant/config/popdex_multi_accounts_config.yaml
LANE_ENV=/etc/tnauqquant/instances/popdex-multi-accounts/manager.env
ls -ld /home/ubuntu/tnauqquant "$CFG" /home/ubuntu/tnauqquant/logs/live-runs
ls -ld /home/ubuntu/tnauqquant/run-state/popdex-multi-accounts 2>&1 | tee "$WORK/run-state.before"
grep -nE '^[[:space:]]*instance_id:' "$CFG" | tee "$WORK/config-instance-id"
grep -nE '^[[:space:]]*(mode:|-[[:space:]]*name:)' "$CFG" | tee "$WORK/config-routing-names"
systemctl show -p ExecStart --value tnauqquant@popdex-multi-accounts.service | tee "$WORK/execstart"
grep -c '^TNAUQ_EXPECTED_BIN=' "$LANE_ENV"                                       # 1
grep '^TNAUQ_EXPECTED_BIN=' "$LANE_ENV" | tee "$WORK/expected-bin"               # 只取這一行，不開其他 env
QUANT="$(sed -n 's/^TNAUQ_EXPECTED_BIN=//p' "$WORK/expected-bin" | tr -d "\"'")"; echo "$QUANT"
test -f "$QUANT" && test -x "$QUANT" && echo QUANT-EXECUTABLE-FILE
grep -HE '^TQ_(EXECUTABLE|INSTANCE_ID)=' /etc/skyeye-trading/instances/*.env | tee "$WORK/sibling-identities"
```

- `QUANT-EXECUTABLE-FILE` 必須印出（確認是一般可執行檔，不是目錄也不是 `/usr/local/sbin/tnauqquant-service`），且不可與 `sibling-identities` 任一 `TQ_EXECUTABLE` 重複。
- `config-instance-id` 須剛好一行、等於 `popdex-multi-accounts` 且不與其他 lane 重複。
- `config-routing-names` 須確認 `mode: "random"` 與兩支 account `popdex-main`、`popdex-rot2`。任一不符即調整 env（不改 config）或 STOP 回報 tnauqquant manager。

準備 `$WORK/popdex-multi-accounts.env` 並離線 render 驗證（只寫 `$WORK`）：

```bash
install -m 600 "$STAGE/agents/alloy/trading/deployment-linux-popdex-multi-accounts.env.example" \
  "$WORK/popdex-multi-accounts.env"
# 若主機 $QUANT 與預填值不同，更新 TQ_EXECUTABLE=$QUANT。
# 若 config 的 instance_id 或兩支 executor 名稱與預填值不同，對齊調整（不要改 config）。
diff "$STAGE/agents/alloy/trading/deployment-linux-popdex-multi-accounts.env.example" "$WORK/popdex-multi-accounts.env" || true
grep -c '^TQ_STRATEGY_DISABLED=1$' "$WORK/popdex-multi-accounts.env"              # 1
"$SETUP" --render-only "$WORK/render" --env-file "$WORK/popdex-multi-accounts.env" </dev/null || echo "STOP: render"
grep -c 'strategy *= *"popdex-multi-accounts"' "$WORK/render/trading-popdex-multi-accounts.alloy"   # >= 1
```

### monitoring-prod（ubuntu）：安裝前基準

```bash
M7=<同上>; MERGE=<完整 SHA>
CUT="$HOME/popdex-multi-onboarding-$M7"; install -d -m 700 "$CUT"
declare -p M7 MERGE CUT >"$CUT/vars"
cd /home/ubuntu/SkyEye
cat >"$CUT/helpers.sh" <<'EOF'
q() { curl -fsS --get http://127.0.0.1:9090/api/v1/query --data-urlencode "query=$1" | jq -c '.data.result'; }
targets() { q 'trading_target_info' | jq -S '[.[].metric | del(.__name__)] | sort'; }
probe_ages() { q 'abs(time() - tnauqquant_probe_timestamp_seconds{product="tnauqquant",environment="production",server_id="trading01"})' \
  | jq -c '[.[] | {strategy: .metric.strategy, age: (.value[1] | tonumber | floor)}] | sort_by(.strategy)'; }
t01_alerts() { q 'ALERTS{product="tnauqquant",server_id="trading01",alertstate="firing"}' \
  | jq -c '[.[].metric | {alertname, strategy}] | sort'; }
EOF
. "$CUT/helpers.sh"

git rev-parse HEAD | tee "$CUT/old-head"
scripts/central-deploy --status 2>&1 | tee "$CUT/central-status-pre.log"
targets | tee "$CUT/pre-targets.json"
jq -e 'map(select(.strategy == "popdex-multi-accounts")) | length == 0' "$CUT/pre-targets.json"   # true
probe_ages | tee "$CUT/probe-ages.pre.json"     # 既有 lane 全部 age < 60，沒有 popdex-multi-accounts
t01_alerts | tee "$CUT/t01-alerts.pre.json"
```

## Step 2 — Host：更新共用 `probe.sh` 並加入 `popdex-multi-accounts` `[CHANGE Trading01]`

前提：Step 1 兩邊全部通過、不在 UTC 18:15–19:30。因為本次改動了共用 `probe.sh`，必須先停止並停用全部既有 `skyeye-trading-probe@*`（此期間不碰任何 `tnauqquant@*`）：

```bash
date -u +%H:%M                                           # 不在 18:15–19:30

# 2a. 暫停並停用全部既有 probe timer/service
while read -r s _ _ <&3; do
  systemctl disable --now "skyeye-trading-probe@$s.timer"
  systemctl stop "skyeye-trading-probe@$s.service"
done 3<"$WORK/timers.before"
systemctl is-active --quiet 'skyeye-trading-probe@*' && echo "STOP: a probe is still active"
systemctl is-enabled --quiet 'skyeye-trading-probe@*.timer' && echo "STOP: a probe timer is still enabled"
```

任何 `STOP` 就停下並依 `$WORK/timers.before` 還原 timer，不要進 2b。

```bash
# 2b. 用新 checkout 重裝所有既有 lane（第一筆會更新共用 probe.sh 並 reload Alloy）
while read -r s e a <&3; do
  flag=; [ "$e $a" = "enabled active" ] && flag=--enable-probe
  "$SETUP" add --env-file "$WORK/$s.env" $flag </dev/null 2>&1 | tee "$WORK/add-$s.out"
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "STOP: add $s failed"; break; }
  grep -q '^Alloy action: restart' "$WORK/add-$s.out" && { echo "STOP: unexpected restart"; break; }
done 3<"$WORK/timers.before"

# 2c. 還原任何非 enabled active 的既有 timer 並比對
while read -r s e a <&3; do
  if [ "$e $a" = "enabled inactive" ]; then systemctl enable "skyeye-trading-probe@$s.timer"; fi
  if [ "$e $a" = "disabled active" ]; then systemctl start "skyeye-trading-probe@$s.timer"; fi
done 3<"$WORK/timers.before"
while read -r s _ _ <&3; do
  e=disabled; a=inactive
  systemctl is-enabled --quiet "skyeye-trading-probe@$s.timer" && e=enabled
  systemctl is-active --quiet "skyeye-trading-probe@$s.timer" && a=active
  printf '%s %s %s\n' "$s" "$e" "$a"
done 3<"$WORK/timers.before" | tee "$WORK/timers.after"
diff "$WORK/timers.before" "$WORK/timers.after" && echo TIMERS-RESTORED

# 2d. 安裝新 lane popdex-multi-accounts（TQ_STRATEGY_DISABLED=1，自動啟用並跑一次 probe）
"$SETUP" add --env-file "$WORK/popdex-multi-accounts.env" </dev/null 2>&1 | tee "$WORK/add-popdex-multi-accounts.out"
echo "rc=${PIPESTATUS[0]}"
```

檢查（等 30 秒讓所有 probe 至少跑完兩次）：

```bash
sleep 30
start=$(cat "$WORK/start-epoch")
systemctl is-active alloy                                # active
systemctl is-enabled skyeye-trading-probe@popdex-multi-accounts.timer
systemctl is-active  skyeye-trading-probe@popdex-multi-accounts.timer
for f in /var/lib/skyeye-trading/textfile/tnauqquant-*.prom; do
  printf '%s %s\n' "$f" "$([ "$(stat -c %Y "$f")" -gt "$start" ] && echo NEW || echo OLD)"
done
grep -E '^tnauqquant_(probe_timestamp_seconds|run_expected|process_count|runtime_contract_available)[{]' \
  /var/lib/skyeye-trading/textfile/tnauqquant-popdex-multi-accounts.prom | sed 's/[{].*[}]//'
# 確認既有單帳號 lane 的 .prom 沒有多出 per-executor series
grep -l 'executor_' /var/lib/skyeye-trading/textfile/tnauqquant-*.prom || echo NO-UNEXPECTED-EXECUTOR-SERIES
# 確認新 lane 仍與 Step 1 相同（未被啟動）
systemctl is-active tnauqquant@popdex-multi-accounts.service
systemctl is-enabled tnauqquant@popdex-multi-accounts.service
```

預期：`run_expected 0`、`process_count 0`、每個啟用中的 `.prom` 皆為 `NEW`，且既有單帳號 lane 皆未出現 `*_executor_*` metrics。

## Step 3 — 中央檢查：`popdex-multi-accounts` 已在 remote-write（monitoring-prod）`[READ-ONLY]`

Step 2 完成後 2 分鐘內：

```bash
probe_ages | tee "$CUT/probe-ages.post-add.json"
jq -n -c --slurpfile pre "$CUT/probe-ages.pre.json" --slurpfile post "$CUT/probe-ages.post-add.json" '{
  siblings_same: (($pre[0] | map(.strategy)) == ($post[0] | map(select(.strategy != "popdex-multi-accounts") | .strategy))),
  all_fresh: ($post[0] | all(.age < 60)),
  popdex_multi: ($post[0] | any(.strategy == "popdex-multi-accounts"))}'
q 'tnauqquant_run_expected{server_id="trading01",strategy="popdex-multi-accounts"}' | jq -c '[.[].value[1]]'   # ["0"]
```

必須輸出 `{"siblings_same":true,"all_fresh":true,"popdex_multi":true}` 才進 Step 4。

## Step 4 — 中央部署：`scripts/central-deploy`（monitoring-prod）`[CHANGE monitoring-prod]`

前提：Step 3 已通過、不在 UTC 18:15–19:30。本次同時部署 `trading-targets.yml` 新 row、`trading.yml` 4 條新 recording rules 與 `trading-strategy-detail.json` 新分項面板。

```bash
cd /home/ubuntu/SkyEye
date -u +%H:%M                                           # 不在 18:15–19:30
scripts/central-deploy --dry-run --expect "${MERGE:?set MERGE first}" 2>&1 | tee "$CUT/central-deploy-dry-run.log"
```

最後一行是 `Dry run: validation passed` 且 `probe_ages` 全部 `< 60` 後執行正式部署：

```bash
scripts/central-deploy --expect "$MERGE" 2>&1 | tee "$CUT/central-deploy.log"; echo "rc=${PIPESTATUS[0]}"
```

部署後檢查：

```bash
[ "$(git rev-parse HEAD)" = "$MERGE" ] && echo HEAD-IS-MERGE
sleep 70
jq -S '. + [{"environment":"production","notification_mode":"shadow","product":"tnauqquant","quote_currency":"USDT","server_id":"trading01","strategy":"popdex-multi-accounts"}] | unique' \
  "$CUT/pre-targets.json" >"$CUT/expected-targets.json"
targets | tee "$CUT/post-targets.json"
diff "$CUT/expected-targets.json" "$CUT/post-targets.json" && echo TARGETS-OK
q 'trading_target_info{server_id="trading01"} unless on (product, environment, server_id, strategy) (abs(time() - tnauqquant_probe_timestamp_seconds{product="tnauqquant",environment="production"}) < 60)'   # []
t01_alerts | tee "$CUT/t01-alerts.post-deploy.json"
```

## Step 5 — Wan 手動 Canary Cycle 後的唯讀核對 `[READ-ONLY]`

Wan 手動跑完 canary cycle（`max_cycles=1` 或 2 輪確認雙帳號輪替）後、正式切換前，在 Trading01（root，`. "$WORK/vars"`）核對：

```bash
ENVF=/etc/skyeye-trading/instances/popdex-multi-accounts.env
MAN=/home/ubuntu/tnauqquant/run-state/popdex-multi-accounts/current.json
DONE=/home/ubuntu/tnauqquant/run-state/popdex-multi-accounts/current.done.json
PROM=/var/lib/skyeye-trading/textfile/tnauqquant-popdex-multi-accounts.prom
test -f "$MAN" && echo MANIFEST-PRESENT
jq -r '.executable, .instance_id, .strategy, .log_path' "$MAN"
grep -E '^TQ_(EXECUTABLE|INSTANCE_ID|STRATEGY|EXECUTOR_MAP|RAW_LOG_GLOB)=' "$ENVF"

LOG="$(jq -r '.log_path' "$MAN")"; RUN_ID="$(jq -r '.run_id' "$MAN")"
[ "$(basename "$LOG")" = "$RUN_ID.raw.log" ] &&
  compgen -G "$(sed -n 's/^TQ_RAW_LOG_GLOB=//p' "$ENVF" | tail -n 1)" | grep -qxF "$LOG" &&
  echo "LOG-MATCHES-GLOB run_id=$RUN_ID"
```

`LOG-MATCHES-GLOB` 通過後核對 raw log 與 `.prom` 合併／分項數值：

```bash
grep -E 'msg=initial_equity_recorded' "$LOG" | tail -n 1 | grep -oE '(equity_usdt|equity_usdt_by_executor)=[^[:space:]]+'
PNL="$(awk '{ m = s = ""; for (i = 1; i <= NF; i++) { e = index($i, "="); if (!e) continue
    k = substr($i, 1, e - 1); v = substr($i, e + 1); gsub(/^"|"$/, "", v); if (k == "msg") m = v; if (k == "stable") s = v }
  if (m == "pnl_status" && s == "true") last = $0 } END { if (last != "") print last }' "$LOG")"
grep -oE '(^|[[:space:]])(time|equity_now|real_pnl_usdt|equity_usdt_by_executor|volume_usd_by_executor|cycle_executor|cycles_completed)=[^[:space:]]+' <<<"$PNL"
grep -E '^tnauqquant_(process_identity_ok|strategy_identity_ok|config_snapshot_match|log_binding_ok|marker_binding_ok|current_equity_usdt|current_real_pnl_usdt|current_cycles_completed|current_run_exchange_volume_usd|current_position_btc|current_net_position_btc|current_executor_|current_run_executor_)[{]' "$PROM"
```

確認項目：
1. 五個 binding 值（`process_identity_ok`、`strategy_identity_ok`、`config_snapshot_match`、`log_binding_ok`、`marker_binding_ok`）皆為 `1`。
2. 合併指標：`tnauqquant_current_equity_usdt` 等於 `equity_now`、`tnauqquant_current_run_exchange_volume_usd{exchange="popdex"}` 等於兩支帳號成交額總和、`tnauqquant_current_position_btc` 與 `tnauqquant_current_net_position_btc` 帶 `base_asset="BTC"` 與 `exchange="popdex"`。
3. 分項指標：`tnauqquant_current_executor_equity_usdt`、`tnauqquant_current_executor_real_pnl_usdt`、`tnauqquant_current_executor_cycles_completed`、`tnauqquant_current_run_executor_volume_usd` 僅帶 `executor="popdex-main"` 與 `executor="popdex-rot2"`（且 `sum(executor_volume) == exchange_volume`）。
4. monitoring-prod 查 Loki 確認此 `run_id` 有 log 進入，並在 Grafana `Trading · 策略詳情`（`server_id=trading01`, `strategy=popdex-multi-accounts`）確認上方合併 KPI 與下方「各帳號明細 · 多帳號策略」表格皆正確顯示。

## Step 6 — `popdex-btc` 兩階段切換與歷史資料延續

**重要分工：** 停用 `tnauqquant@popdex-btc` 與啟動／啟用 `tnauqquant@popdex-multi-accounts` **一律由 Wan／tnauqquant 側操作**；本節只調整 SkyEye 的 probe env 與中央 inventory，**絕不操作任何 `tnauqquant@*` unit**。

### Stage 1：切換當下（建議觀察 24–72 小時）`[CHANGE Trading01]`

順序嚴格遵守（不在 UTC 18:15–19:30）：

1. **Wan／tnauqquant 側**：停止並 disable `tnauqquant@popdex-btc`（service 與 timer），確認平倉且無殘留程序。
2. **SkyEye operator（Trading01）**：唯讀確認 `popdex-btc` 已無執行程序，再將 `popdex-btc` 的 SkyEye env 設為 `TQ_STRATEGY_DISABLED=1`（**暫不 retire**）：

   ```bash
   systemctl is-active tnauqquant@popdex-btc.service    # inactive（唯讀確認）
   install -m 600 /etc/skyeye-trading/instances/popdex-btc.env "$WORK/popdex-btc.disable.env"
   if grep -q '^TQ_STRATEGY_DISABLED=' "$WORK/popdex-btc.disable.env"; then
     sed -i 's/^TQ_STRATEGY_DISABLED=.*/TQ_STRATEGY_DISABLED=1/' "$WORK/popdex-btc.disable.env"
   else
     printf 'TQ_STRATEGY_DISABLED=1\n' >>"$WORK/popdex-btc.disable.env"
   fi
   diff /etc/skyeye-trading/instances/popdex-btc.env "$WORK/popdex-btc.disable.env"
   "$SETUP" add --env-file "$WORK/popdex-btc.disable.env" </dev/null 2>&1 | tee "$WORK/add-popdex-btc.disable.out"
   echo "rc=${PIPESTATUS[0]}"
   ```

   **Stage 1 保留 `popdex-btc` probe 的目的**：
   - `popdex-btc` 停著時不觸發 `TradingProcessDown`；
   - 若 `popdex-btc` 被意外重啟（忘關 timer 或誤操作），SkyEye 會立即觸發 `TradingUnexpectedProcess`（shadow），主動保護共用的 `popdex-main` 帳號不被兩條 lane 同時下單；
   - 過渡期間 `$strategy` 下拉選單仍可直接對照 `popdex-btc`，且若需退回只需把 `TQ_STRATEGY_DISABLED` 改回 `0`。

3. **SkyEye operator（Trading01）**：把 `popdex-multi-accounts` 的 `TQ_STRATEGY_DISABLED` 改為 `0`（在 Wan 正式啟動新 lane **之前**執行）：

   ```bash
   install -m 600 /etc/skyeye-trading/instances/popdex-multi-accounts.env "$WORK/popdex-multi-accounts.enable.env"
   sed -i 's/^TQ_STRATEGY_DISABLED=1$/TQ_STRATEGY_DISABLED=0/' "$WORK/popdex-multi-accounts.enable.env"
   diff /etc/skyeye-trading/instances/popdex-multi-accounts.env "$WORK/popdex-multi-accounts.enable.env"
   "$SETUP" add --env-file "$WORK/popdex-multi-accounts.enable.env" </dev/null 2>&1 | tee "$WORK/add-popdex-multi-accounts.enable.out"
   echo "rc=${PIPESTATUS[0]}"
   ```

4. **Wan／tnauqquant 側**：啟用並啟動 `tnauqquant@popdex-multi-accounts`。

### Stage 2：穩定觀察後正式退場 `popdex-btc`（另案 S3）

確認 `popdex-multi-accounts` 穩定運行且不再回退至 `popdex-btc` 後，依標準 Remove 順序（**先中央、後 host**，避免 `TradingTelemetryMissing`）：

1. **Repo**：`scripts/trading-target remove --server trading01 --strategy popdex-btc` → 跑 `tests/trading/test-central-config.sh` → PR & merge。
2. **Central（monitoring-prod）**：`scripts/central-deploy`。
3. **Host（Trading01，root）**：`sudo "$SETUP" retire --strategy popdex-btc </dev/null`。

### 歷史資料延續說明

- `scripts/trading-target remove` 與 `setup-linux.sh retire` **都不會刪除 Prometheus TSDB 或 Loki 中的歷史資料**。
- 退場後 `popdex-btc` 不再出現在 `Trading · 策略總覽` 與 `$strategy` 預設下拉清單（總覽表只留新的合併 BTC 策略 `popdex-multi-accounts`）；歷史資料在 retention 期內仍可於 Grafana Explore 以 `strategy="popdex-btc"` 查詢，或直接開 `/d/trading-strategy-detail/trading-strategy-detail?var-server_id=trading01&var-strategy=popdex-btc` 搭配舊時間區間檢視。

## Rollback

- **Host 共用 `probe.sh` 更新失敗或既有 lane 異常**：
  1. 停止並停用全部 `skyeye-trading-probe@*.timer` 與 `.service`（不碰 `tnauqquant@*`）。
  2. 用前版 `origin/master` checkout 的 `setup-linux.sh` 依 `$WORK/timers.before` 重跑既有 lane 的 `add`（或由第一筆 `add` 印出的 rollback record 還原 `/usr/local/libexec/skyeye-trading/probe.sh` 並 `systemctl daemon-reload`）。
  3. 執行 `sudo "$SETUP" retire --strategy popdex-multi-accounts </dev/null`。
  4. 依 `$WORK/timers.before` 還原所有既有 timer 狀態並確認 `probe_ages < 60`。
- **Central 部署失敗**：若 `$CUT/old-head` 不含 `popdex-multi-accounts` row，依 rollout 文件 R5 還原 checkout 與 reload Prometheus；若已 merge 且需移除新目標，依 README Remove 走 `scripts/trading-target remove` PR 與 `central-deploy`。
- **切換後需退回 `popdex-btc`（Stage 1 期間）**：
  1. Wan／tnauqquant 側停止並 disable `tnauqquant@popdex-multi-accounts`。
  2. SkyEye operator 將 `popdex-multi-accounts.env` 改回 `TQ_STRATEGY_DISABLED=1` 並跑 `setup-linux.sh add`。
  3. SkyEye operator 將 `popdex-btc.env` 改回 `TQ_STRATEGY_DISABLED=0`（還原 `$WORK/popdex-btc.env`）並跑 `setup-linux.sh add`。
  4. Wan／tnauqquant 側重新啟用並啟動 `tnauqquant@popdex-btc`。

## 執行紀錄

| 項目 | 時間（UTC） | 結果／record |
|---|---|---|
| Step 0 staging | | `MERGE`、`STAGE` |
| Step 1 前置檢查與基準 | | `WORK`、`CUT`、Alloy 版本、核對後的 `TQ_EXECUTABLE`／`TQ_INSTANCE_ID`／`TQ_EXECUTOR_MAP` |
| Step 2 host probe 更新 + add | | `timers.before` == `timers.after`、Rollback record、`rc` |
| Step 3 中央檢查 | | `siblings_same`、`all_fresh`、`popdex_multi` |
| Step 4 central-deploy | | applied SHA、`TARGETS-OK`、Grafana 載入結果 |
| Step 5 canary 核對 | | 五項 binding、`run_id`、Loki、合併與分項 `.prom` 對帳 |
| Step 6 Stage 1 切換 | | `popdex-btc` `TQ_STRATEGY_DISABLED=1`、`popdex-multi-accounts` `TQ_STRATEGY_DISABLED=0` |
| Step 6 Stage 2 退場（S3） | | `trading-target remove` PR、`central-deploy`、`retire` record |
