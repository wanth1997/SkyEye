# Trading01 新增 `popdex-multi-accounts` 監控與 `popdex-btc` 切換（operator 程序）

> **來源：** Linear WAN-928（SkyEye task `POPDEX-MULTI-20261126`）。Trading01 新增 tnauqquant lane `popdex-multi-accounts`（PopDEX，`BTC_USDT_PERP`，`routing.mode: random` 輪替 `popdex-main` 與 `popdex-rot2` 兩支帳號，不互相對沖），切換上線後將取代 `popdex-btc`。設計計畫見 [docs/plans/popdex-multi-accounts.md](plans/popdex-multi-accounts.md)。
>
> **本文件是 operator 程序，repo 變更 merge 後不會自動生效。**
>
> - 通用的 add／remove 與共用 probe 更新規則見 [agents/alloy/trading/README.md](../agents/alloy/trading/README.md)。
> - 硬性限制、staging 與 central-deploy 判讀沿用 [Trading01 PopDEX rollout](trading01-popdex-rollout.md)（以下稱「rollout 文件」）；本次 Rollback 見文末專屬章節（**不得**套用舊 rollout 的 R5）。
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
| 預填 `TQ_EXECUTABLE` | `/home/ubuntu/tnauqquant/bin/popdex-multi-accounts/quant`（Step 1 **必須**依主機 `manager.env` 核對實際路徑） |
| 安裝時狀態 | `TQ_STRATEGY_DISABLED=1`：lane 安裝後保持停用，等 Step 5a 停用 `popdex-btc` 並完成 Step 5b–5c canary 驗收後，於 Step 6 Stage 1 切換前才改為 `0` |

**operator 必須在 Trading01 唯讀核對的值：**

| 值 | 怎麼核對 | 填錯的後果 |
|---|---|---|
| `TQ_EXECUTABLE` | 預期為 `/home/ubuntu/tnauqquant/bin/popdex-multi-accounts/quant`，以主機 `TNAUQ_EXPECTED_BIN` 與 Step 5 manifest `.executable` 為準。Step 1 只核對路徑，首次安裝時 binary 可能尚未產生。第一次啟動後，Step 5c 必須確認該路徑是可執行的一般檔案。 | 填成目錄或錯路徑可能導致 `process_count 0`、測試 cycle 未出現 `TradingUnexpectedProcess`，或出現 `TradingRunBindingInvalid`。共用 launcher 路徑不得使用。 |
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
EXPECTED_BIN_COUNT="$(grep -c '^TNAUQ_EXPECTED_BIN=' "$LANE_ENV")"
printf 'TNAUQ_EXPECTED_BIN count=%s\n' "$EXPECTED_BIN_COUNT"                     # 1
grep '^TNAUQ_EXPECTED_BIN=' "$LANE_ENV" | tee "$WORK/expected-bin"               # 只取這一行，不開其他 env
QUANT="$(sed -n 's/^TNAUQ_EXPECTED_BIN=//p' "$WORK/expected-bin" | tr -d "\"'")"; echo "$QUANT"
grep -HE '^TQ_(EXECUTABLE|INSTANCE_ID)=' /etc/skyeye-trading/instances/*.env | tee "$WORK/sibling-identities"
sibling_status=("${PIPESTATUS[@]}")

if [[ "${sibling_status[*]}" != "0 0" ]]; then
  echo "STOP: could not record sibling identities"
elif [[ "$EXPECTED_BIN_COUNT" != 1 || "$QUANT" != /* || -d "$QUANT" ||
      "$QUANT" == /usr/local/sbin/tnauqquant-service ]] ||
   sed -n 's/^[^:]*:TQ_EXECUTABLE=//p' "$WORK/sibling-identities" |
     tr -d "\"'" | grep -qxF -- "$QUANT"; then
  echo "STOP: invalid or duplicate TNAUQ_EXPECTED_BIN"
else
  echo QUANT-PATH-OK
fi
```

- 必須看到 `QUANT-PATH-OK`，並確認 `sibling-identities` 完整讀取。路徑須為絕對路徑、排除目錄與共用 launcher，且不可與任一 sibling 的 `TQ_EXECUTABLE` 重複。若檔案已存在，可順便確認為可執行的一般檔案。新 lane 第一次啟動前允許檔案尚未產生。
- `config-instance-id` 須剛好一行、等於 `popdex-multi-accounts` 且不與其他 lane 重複。
- `config-routing-names` 須確認 `mode: "random"` 與兩支 account `popdex-main`、`popdex-rot2`。任一不符即調整 env（不改 config）或 STOP 回報 tnauqquant manager。

準備 `$WORK/popdex-multi-accounts.env` 並離線 render 驗證（只寫 `$WORK`）：

```bash
install -m 600 "$STAGE/agents/alloy/trading/deployment-linux-popdex-multi-accounts.env.example" \
  "$WORK/popdex-multi-accounts.env"
# 若主機 $QUANT 與預填值不同，更新 TQ_EXECUTABLE=$QUANT。
# 若 config 的 instance_id 或兩支 executor 名稱與預填值不同，對齊調整（不要改 config）。
diff "$STAGE/agents/alloy/trading/deployment-linux-popdex-multi-accounts.env.example" "$WORK/popdex-multi-accounts.env" || true
grep -c '^TQ_EXECUTABLE=' "$WORK/popdex-multi-accounts.env"                     # 1
grep -xF "TQ_EXECUTABLE=$QUANT" "$WORK/popdex-multi-accounts.env"                # 印出相符的設定
grep -c '^TQ_STRATEGY_DISABLED=1$' "$WORK/popdex-multi-accounts.env"              # 1
"$SETUP" --render-only "$WORK/render" --env-file "$WORK/popdex-multi-accounts.env" </dev/null || echo "STOP: render"
grep -c 'strategy *= *"popdex-multi-accounts"' "$WORK/render/trading-popdex-multi-accounts.alloy"   # >= 1
```

`TQ_EXECUTABLE` 必須唯一且等於 Step 1 取出的 `TNAUQ_EXPECTED_BIN`，否則 STOP。

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
rm -f "$WORK/timers-restored.ok"
step2b_ok=1
while read -r s e a <&3; do
  flag=; [ "$e $a" = "enabled active" ] && flag=--enable-probe
  "$SETUP" add --env-file "$WORK/$s.env" $flag </dev/null 2>&1 | tee "$WORK/add-$s.out"
  if [ "${PIPESTATUS[0]}" != 0 ]; then
    echo "STOP: add $s failed — abort Step 2 and run Host Rollback"
    step2b_ok=0
    break
  fi
  if grep -q '^Alloy action: restart' "$WORK/add-$s.out"; then
    echo "STOP: unexpected Alloy restart on $s — abort Step 2 and run Host Rollback"
    step2b_ok=0
    break
  fi
done 3<"$WORK/timers.before"

# 2c. 僅在 2b 全部成功時還原非 enabled active 的既有 timer 並比對前後狀態
if [ "$step2b_ok" = 1 ]; then
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
  if diff "$WORK/timers.before" "$WORK/timers.after"; then
    touch "$WORK/timers-restored.ok"
    echo TIMERS-RESTORED
  else
    echo "STOP: timer state mismatch — abort Step 2 and run Host Rollback"
  fi
fi
```

**閘門（必看）：** 必須明確看到 `TIMERS-RESTORED` 且完全沒有任何 `STOP:` 訊息，才可進入下方 2d。若 2b 任一 `add` 失敗、出現 `Alloy action: restart`，或 2c 的 timer 前後比對失敗，**立刻結束 Step 2 並進入文末「Rollback — Host 共用 `probe.sh` 更新失敗或既有 lane 異常」，絕不執行 2d**。

```bash
# 2d. 僅在明確確認 TIMERS-RESTORED 後安裝新 lane popdex-multi-accounts（TQ_STRATEGY_DISABLED=1）
if [ -f "$WORK/timers-restored.ok" ]; then
  "$SETUP" add --env-file "$WORK/popdex-multi-accounts.env" </dev/null 2>&1 | tee "$WORK/add-popdex-multi-accounts.out"
  rc="${PIPESTATUS[0]}"
  echo "rc=$rc"
  if [ "$rc" != 0 ] || grep -q '^Alloy action: restart' "$WORK/add-popdex-multi-accounts.out"; then
    echo "STOP: add popdex-multi-accounts failed or requested restart — run Host Rollback"
  fi
else
  echo "STOP: TIMERS-RESTORED not confirmed; aborting 2d — run Host Rollback"
fi
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

## Step 5 — 帳號交接前置（`popdex-btc` 停用）與 Canary 驗收

**為何必須在第一次 canary 之前完成 `popdex-btc` 交接：** `popdex-multi-accounts` 與 `popdex-btc` 共用 `popdex-main` 帳號；依 tnauqquant `routing-rotation.md`，新 process 啟動時會對**所有設定帳號**撤單並平倉（`FlattenOnStart`）。即使 canary 第一筆 signal 抽到 `popdex-rot2`，只要 `popdex-btc` 仍在運行或可被 timer 重啟，新 process 啟動就會撤掉或平掉 `popdex-btc` 的委託與持倉；且 `TradingUnexpectedProcess` 有 2 分鐘等待時間並走 shadow 路由，無法替代事前交接。

**重要分工：** 停用 `tnauqquant@popdex-btc`、執行 canary 與啟動／啟用 `tnauqquant@popdex-multi-accounts` **一律由 Wan／tnauqquant 側操作**；本節只做唯讀核對與調整 SkyEye 的 probe env，**絕不操作任何 `tnauqquant@*` unit**。

### 5a. 帳號交接前置（首次 canary 之前，必做）`[CHANGE Trading01]`

不在 UTC 18:15–19:30，嚴格依序執行：

1. **Wan／tnauqquant 側**：確認 `popdex-btc` 已平倉、已停止 `tnauqquant@popdex-btc.service`，且所有可能啟動或重啟它的 timer（含任何每日重啟 timer）皆已停用／不會再拉起 `popdex-btc`，確認完成後通知 SkyEye operator。
2. **SkyEye operator（Trading01，root，`. "$WORK/vars"`）唯讀核對 `popdex-btc` 程序、持倉與 timer**：

   ```bash
   date -u +%H:%M                                           # 不在 18:15–19:30
   systemctl is-active tnauqquant@popdex-btc.service  | tee "$WORK/popdex-btc.active"    # inactive
   systemctl is-enabled tnauqquant@popdex-btc.service | tee "$WORK/popdex-btc.enabled"   # disabled、masked 或 static
   pgrep -a -f 'popdex_btc' | tee "$WORK/popdex-btc.processes"                           # 沒有輸出
   systemctl list-unit-files --type=timer --no-legend >"$WORK/btc-timer-files" && [ -s "$WORK/btc-timer-files" ] && echo BTC-TIMER-FILES-READ
   systemctl list-units --type=timer --all --no-legend --plain >"$WORK/btc-timer-units" && [ -s "$WORK/btc-timer-units" ] && echo BTC-TIMER-UNITS-READ
   { awk '{ print $1 }' "$WORK/btc-timer-files" | sed 's/@[.]timer$/@popdex-btc.timer/'; awk '{ print $1 }' "$WORK/btc-timer-units"; } |
     sort -u | while read -r t; do
       printf '%s triggers=%s enabled=%s active=%s\n' "$t" "$(systemctl show -p Triggers --value "$t")" \
         "$(systemctl is-enabled "$t" 2>&1)" "$(systemctl is-active "$t")"
     done | tee "$WORK/popdex-btc-timers"
   grep -E '^tnauqquant_(process_count|current_position_btc|current_net_position_btc|done_marker)[{]' \
     /var/lib/skyeye-trading/textfile/tnauqquant-popdex-btc.prom
   ```

   - 必須確認：`popdex-btc.active` 為 `inactive`、`popdex-btc.enabled` 為 `disabled`/`masked`/`static`、`popdex-btc.processes` 為空、`popdex-btc-timers` 中**沒有任何** active 或 enabled timer 會觸發 `tnauqquant@popdex-btc.service`（包含任何會重啟 `popdex-btc` 的每日排程 timer），且 `tnauqquant-popdex-btc.prom` 的 `process_count` 為 `0`、持倉已平倉。
   - **任一項未通過即 STOP，通知 Wan 處理，絕不進入 5b canary。**

3. **SkyEye operator（Trading01）為 `popdex-btc` 加上 `TQ_STRATEGY_DISABLED=1`（Stage 1 保護前置，暫不 retire）**：

   ```bash
   install -m 600 /etc/skyeye-trading/instances/popdex-btc.env "$WORK/popdex-btc.disable.env"
   if grep -q '^TQ_STRATEGY_DISABLED=' "$WORK/popdex-btc.disable.env"; then
     sed -i 's/^TQ_STRATEGY_DISABLED=.*/TQ_STRATEGY_DISABLED=1/' "$WORK/popdex-btc.disable.env"
   else
     printf 'TQ_STRATEGY_DISABLED=1\n' >>"$WORK/popdex-btc.disable.env"
   fi
   diff /etc/skyeye-trading/instances/popdex-btc.env "$WORK/popdex-btc.disable.env"
   "$SETUP" add --env-file "$WORK/popdex-btc.disable.env" </dev/null 2>&1 | tee "$WORK/add-popdex-btc.disable.out"
   rc="${PIPESTATUS[0]}"; echo "rc=$rc"
   if [ "$rc" != 0 ] || grep -q '^Alloy action: restart' "$WORK/add-popdex-btc.disable.out"; then
     echo "STOP: add popdex-btc disable failed or requested restart"
   fi
   sleep 20
   grep -E '^tnauqquant_(process_count|run_expected)[{]' /var/lib/skyeye-trading/textfile/tnauqquant-popdex-btc.prom
   ```

   預期：`rc=0`、無 `Alloy action: restart`、`popdex-btc` 的 `process_count 0` 與 `run_expected 0`。

   **過渡期保留 `popdex-btc` probe 的目的**：
   - `popdex-btc` 停著時不觸發 `TradingProcessDown`；
   - 若 `popdex-btc` 被意外重啟（忘關 timer 或誤操作），條件持續 2 分鐘後 SkyEye 會進入 firing 觸發 `TradingUnexpectedProcess`（shadow）提醒；
   - 過渡期間 `$strategy` 下拉選單仍可直接對照 `popdex-btc`，且若 canary 失敗或上線後需退回，可依文末「退回 `popdex-btc`」程序確認新 lane 已平倉、停止且所有排程停用後再交還帳號。

### 5b. 記錄 Canary 視窗基準並請 Wan 執行 Canary Cycle `[READ-ONLY]`

確認 5a 全部通過後，**每次請 Wan 執行 canary（包含重試）之前**，先在 Trading01（root，`. "$WORK/vars"`）記錄既有 `run_id`（若有）與當下時間，避免舊 manifest／marker 被誤當成本次結果：

```bash
MAN=/home/ubuntu/tnauqquant/run-state/popdex-multi-accounts/current.json
date +%s >"$WORK/canary-window-start"
if [ -f "$MAN" ]; then jq -r '.run_id // ""' "$MAN"; else printf ''; fi >"$WORK/canary-prev-run-id"
printf 'window_start=%s prev_run_id=%s\n' "$(cat "$WORK/canary-window-start")" "$(cat "$WORK/canary-prev-run-id")"
```

記錄完成後，通知 **Wan／tnauqquant 側**執行手動 canary cycle（`max_cycles=1` 或 2 輪確認雙帳號輪替；此時 `popdex-multi-accounts.env` 維持 `TQ_STRATEGY_DISABLED=1`），等待 canary 結束後進入 5c。

### 5c. Canary 終態與指標唯讀核對 `[READ-ONLY]`

Canary 結束後、Step 6 正式啟用前，在 Trading01（root，`. "$WORK/vars"`）核對本次執行的 binary、歸屬、終態與指標。此時 binary 必須已產生且為可執行的一般檔案：

```bash
ENVF=/etc/skyeye-trading/instances/popdex-multi-accounts.env
MAN=/home/ubuntu/tnauqquant/run-state/popdex-multi-accounts/current.json
DONE=/home/ubuntu/tnauqquant/run-state/popdex-multi-accounts/current.done.json
PROM=/var/lib/skyeye-trading/textfile/tnauqquant-popdex-multi-accounts.prom
WINDOW_START="$(cat "$WORK/canary-window-start")"
PREV_RUN_ID="$(cat "$WORK/canary-prev-run-id")"
QUANT="$(sed -n 's/^TNAUQ_EXPECTED_BIN=//p' "$WORK/expected-bin" | tr -d "\"'")"

test -f "$QUANT" && test -x "$QUANT" && echo QUANT-EXECUTABLE-FILE
test -f "$MAN" && echo MANIFEST-PRESENT
jq -r '.executable, .instance_id, .strategy, .log_path, .process_started_at' "$MAN"
grep -E '^TQ_(EXECUTABLE|INSTANCE_ID|STRATEGY|EXECUTOR_MAP|RAW_LOG_GLOB)=' "$ENVF"
[[ "$(grep -c '^TQ_EXECUTABLE=' "$ENVF")" == 1 ]] &&
  grep -qxF "TQ_EXECUTABLE=$QUANT" "$ENVF" &&
  jq -e --arg quant "$QUANT" '.executable == $quant' "$MAN" &&
  echo QUANT-EXECUTABLE-MATCH

RUN_ID="$(jq -r '.run_id // ""' "$MAN")"
STARTED_AT="$(jq -r '.process_started_at // ""' "$MAN")"
STARTED_EPOCH="$( [ -n "$STARTED_AT" ] && date -u -d "$STARTED_AT" +%s || printf '' )"
[ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] && [ "$RUN_ID" != "$PREV_RUN_ID" ] &&
  [ -n "$STARTED_EPOCH" ] && [ "$STARTED_EPOCH" -ge "$WINDOW_START" ] &&
  echo "NEW-CANARY-RUN run_id=$RUN_ID started=$STARTED_AT (prev=${PREV_RUN_ID:-none})"
printf '%s\n' "$RUN_ID" >"$WORK/canary-run-id"

LOG="$(jq -r '.log_path' "$MAN")"
[ -f "$LOG" ] && [ "$(basename "$LOG")" = "$RUN_ID.raw.log" ] &&
  compgen -G "$(sed -n 's/^TQ_RAW_LOG_GLOB=//p' "$ENVF" | tail -n 1)" | grep -qxF "$LOG" &&
  echo "LOG-MATCHES-GLOB run_id=$RUN_ID"
grep -F "tnauqquant_current_run_info{" "$PROM" | grep -qF "run_id=\"$RUN_ID\"} 1" &&
  echo "PROBE-RUN-INFO-MATCHES run_id=$RUN_ID"

# 核對本次 canary 成功終態（marker 存在、run_id 相符、completed_at 落於本次視窗內、reason/phase 為 max_cycles_complete、已平倉、無 error）
test -f "$DONE" && echo DONE-MARKER-PRESENT
COMPLETED_AT="$(jq -r '.completed_at // ""' "$DONE")"
COMPLETED_EPOCH="$( [ -n "$COMPLETED_AT" ] && date -u -d "$COMPLETED_AT" +%s || printf '' )"
[ -n "$STARTED_EPOCH" ] && [ -n "$COMPLETED_EPOCH" ] &&
  [ "$COMPLETED_EPOCH" -ge "$STARTED_EPOCH" ] && [ "$COMPLETED_EPOCH" -ge "$WINDOW_START" ] &&
jq -e --arg rid "$RUN_ID" '
  def magnitude: if . < 0 then -. else . end;
  .run_id == $rid and
  .strategy == "popdex-multi-accounts" and
  .reason == "max_cycles_complete" and
  .phase == "max_cycles_complete" and
  ((.error // "") == "") and
  .dust_tolerance_btc >= 0 and
  (.long_btc | magnitude) <= .dust_tolerance_btc and
  (.short_btc | magnitude) <= .dust_tolerance_btc and
  (.net_btc | magnitude) <= .dust_tolerance_btc
' "$DONE" && echo CANARY-TERMINAL-OK
```

`QUANT-EXECUTABLE-FILE`、`QUANT-EXECUTABLE-MATCH`、`NEW-CANARY-RUN`、`LOG-MATCHES-GLOB`、`PROBE-RUN-INFO-MATCHES` 與 `CANARY-TERMINAL-OK` 全部通過後，核對 raw log 合併值、依 `cycle_executor` 去重加總的各帳號損益／週期數（含 0 週期帳號）與 `.prom` 四個完整分項指標。任一項失敗即 STOP 並通知 Wan：

```bash
grep -E 'msg=initial_equity_recorded' "$LOG" | tail -n 1 | grep -oE '(equity_usdt|equity_usdt_by_executor)=[^[:space:]]+'
PNL="$(awk '{ m = s = ""; for (i = 1; i <= NF; i++) { e = index($i, "="); if (!e) continue
    k = substr($i, 1, e - 1); v = substr($i, e + 1); gsub(/^"|"$/, "", v); if (k == "msg") m = v; if (k == "stable") s = v }
  if (m == "pnl_status" && s == "true") last = $0 } END { if (last != "") print last }' "$LOG")"
grep -oE '(^|[[:space:]])(time|equity_now|real_pnl_usdt|equity_usdt_by_executor|volume_usd_by_executor|cycles_completed|risk_stopped)=[^[:space:]]+' <<<"$PNL"

# 從本次 bound log 取出所有 stable 且已完成的週期，依週期去重後按 allowlist 內 cycle_executor 加總損益與計數（含 0 週期帳號）
EXEC_MAP="$(sed -n 's/^TQ_EXECUTOR_MAP=//p' "$ENVF" | tail -n 1)"
awk -v mapping="$EXEC_MAP" '
  function fmt(v, s) {
    s = sprintf("%.10f", v + 0)
    sub(/0+$/, "", s); sub(/[.]$/, "", s)
    return (s == "" || s == "-0") ? "0" : s
  }
  BEGIN {
    n = split(mapping, a, ",")
    for (i = 1; i <= n; i++) {
      eq = index(a[i], "=")
      if (eq > 1) { ex = substr(a[i], 1, eq - 1); allow[ex] = 1; order[++cnt] = ex }
    }
  }
  {
    msg = stable = done = sc = cc = ce = crp = ""
    saw_ce = saw_crp = 0
    for (i = 1; i <= NF; i++) {
      eq = index($i, "="); if (!eq) continue
      k = substr($i, 1, eq - 1); v = substr($i, eq + 1); gsub(/^"|"$/, "", v)
      if (k == "msg") msg = v
      else if (k == "stable") stable = v
      else if (k == "cycle_completed") done = v
      else if (k == "session_cycle") sc = v
      else if (k == "cycles_completed") cc = v
      else if (k == "cycle_executor" && !saw_ce) { ce = v; saw_ce = 1 }
      else if (k == "cycle_real_pnl_usdt" && !saw_crp) { crp = v; saw_crp = 1 }
    }
    if (msg == "pnl_status" && stable == "true" && done == "true") {
      cy = (sc != "" ? sc : cc)
      if (cy ~ /^[0-9]+$/) {
        if (!(cy in seen)) { seen[cy] = 1; cy_order[++cy_cnt] = cy }
        cy_exec[cy] = ce; cy_pnl[cy] = crp
      }
    }
  }
  END {
    for (i = 1; i <= cy_cnt; i++) {
      ex = cy_exec[cy_order[i]]
      if (ex in allow) { cycles[ex]++; pnl[ex] += cy_pnl[cy_order[i]] }
    }
    for (i = 1; i <= cnt; i++) {
      ex = order[i]
      printf "expected executor=%s cycles=%d real_pnl_usdt=%s\n", ex, cycles[ex] + 0, fmt(pnl[ex])
    }
  }
' "$LOG"

grep -E '^tnauqquant_(current_run_info|process_count|run_expected|risk_stopped|done_marker|process_identity_ok|strategy_identity_ok|config_snapshot_match|log_binding_ok|marker_binding_ok|current_equity_usdt|current_real_pnl_usdt|current_cycles_completed|current_run_exchange_volume_usd|current_position_btc|current_net_position_btc|current_executor_equity_usdt|current_executor_real_pnl_usdt|current_executor_cycles_completed|current_run_executor_volume_usd)[{]' "$PROM"
```

驗收條件（**全部通過才可進入 Step 6；任一項失敗立刻 STOP 並把結果交回 Wan**）：
1. **Canary 歸屬與成功終態**：
   - `QUANT-EXECUTABLE-FILE` 與 `QUANT-EXECUTABLE-MATCH` 都必須印出。Step 1 記錄的 `TNAUQ_EXPECTED_BIN`、已安裝的 `TQ_EXECUTABLE` 與本次 manifest `.executable` 須一致，且指向可執行的一般檔案。
   - `NEW-CANARY-RUN`、`LOG-MATCHES-GLOB`、`PROBE-RUN-INFO-MATCHES`、`DONE-MARKER-PRESENT` 與 `CANARY-TERMINAL-OK` 全部印出（確認 manifest、`current.done.json`、bound raw log 與 probe 的 `tnauqquant_current_run_info` 全屬本次視窗內的新 `run_id`，`reason="max_cycles_complete"` 且已平倉）；
   - `.prom` 顯示 `tnauqquant_done_marker{...,reason="max_cycles_complete"} 1`、`tnauqquant_process_count 0`、`tnauqquant_risk_stopped 0`；
   - 五個 binding 值（`process_identity_ok`、`strategy_identity_ok`、`config_snapshot_match`、`log_binding_ok`、`marker_binding_ok`）皆為 `1`；
   - monitoring-prod 的 `t01_alerts` 與 Loki 均無 `popdex-multi-accounts` 未解決之風控或錯誤事件（`TradingCriticalSafetyState`、`TradingRiskStopped`、`TradingExecutionIncident`、`TradingCriticalLogEvent`、`TradingCriticalWarnEvent`）。
2. **合併指標**：
   - `tnauqquant_current_equity_usdt` 等於 raw log 的 `equity_now`；
   - `tnauqquant_current_run_exchange_volume_usd{...,exchange="popdex"}` 等於兩支帳號成交額總和；
   - **交易所持倉**：`tnauqquant_current_position_btc` 帶 `base_asset="BTC"`、`exchange="popdex"` 與 `side="flat"`（平倉值為 `0` 或 `0.00000000`）；
   - **策略淨持倉**：`tnauqquant_current_net_position_btc` **僅帶 `base_asset="BTC"`**（不帶 `exchange` label），平倉值為 `0`。
3. **四個 per-executor 分項指標**（分別核對 `executor="popdex-main"` 與 `executor="popdex-rot2"` 兩支帳號，含零週期帳號，且不可出現 allowlist 以外的 `executor` label）：
   - `tnauqquant_current_executor_equity_usdt`：`popdex-main` 與 `popdex-rot2` 各對應 `equity_usdt_by_executor`；
   - `tnauqquant_current_executor_real_pnl_usdt`：`popdex-main` 與 `popdex-rot2` 各與上方 `expected executor=... real_pnl_usdt=...` 一致；
   - `tnauqquant_current_executor_cycles_completed`：`popdex-main` 與 `popdex-rot2` 各與上方 `expected executor=... cycles=...` 一致；
   - `tnauqquant_current_run_executor_volume_usd`：`popdex-main` 與 `popdex-rot2` 各對應成交額，且兩者加總等於 `tnauqquant_current_run_exchange_volume_usd{exchange="popdex"}`。
4. **Loki 與 Grafana**：monitoring-prod 查 Loki 確認此 `run_id` 有 log 進入，並在 Grafana `Trading · 策略詳情`（`server_id=trading01`, `strategy=popdex-multi-accounts`）確認上方合併 KPI 與下方「各帳號明細 · 多帳號策略」表格皆正確顯示。

## Step 6 — 正式切換（Stage 1 啟用與簽收）與 Stage 2 `popdex-btc` 退場

**重要分工：** 啟動／啟用 `tnauqquant@popdex-multi-accounts` **一律由 Wan／tnauqquant 側操作**；SkyEye operator 只調整 SkyEye 的 probe env、唯讀簽收與執行中央 inventory 變更，**絕不操作任何 `tnauqquant@*` unit**。

### Stage 1：正式啟用 `popdex-multi-accounts` 與簽收（觀察 24–72 小時）`[CHANGE Trading01]`

順序嚴格遵守（不在 UTC 18:15–19:30）：

1. **前置確認**：Step 5c canary 全部通過，且 `popdex-btc` 維持停用（Step 5a 已將 `popdex-btc.env` 設為 `TQ_STRATEGY_DISABLED=1`，`tnauqquant@popdex-btc.service` 為 `inactive`）。
2. **SkyEye operator（Trading01）**：把 `popdex-multi-accounts` 的 `TQ_STRATEGY_DISABLED` 改為 `0`（在 Wan 正式啟動新 lane **之前**執行）：

   ```bash
   install -m 600 /etc/skyeye-trading/instances/popdex-multi-accounts.env "$WORK/popdex-multi-accounts.enable.env"
   sed -i 's/^TQ_STRATEGY_DISABLED=1$/TQ_STRATEGY_DISABLED=0/' "$WORK/popdex-multi-accounts.enable.env"
   diff /etc/skyeye-trading/instances/popdex-multi-accounts.env "$WORK/popdex-multi-accounts.enable.env"
   "$SETUP" add --env-file "$WORK/popdex-multi-accounts.enable.env" </dev/null 2>&1 | tee "$WORK/add-popdex-multi-accounts.enable.out"
   echo "rc=${PIPESTATUS[0]}"
   ```

3. **Wan／tnauqquant 側**：啟用並啟動 `tnauqquant@popdex-multi-accounts`（及對應排程 timer，若有），完成後通知 SkyEye operator。
4. **SkyEye operator（Trading01 + monitoring-prod）Stage 1 簽收唯讀驗證 `[READ-ONLY]`**：

   接到 Wan 已啟動通知後等 30 秒讓 probe 刷新，**必須完成以下全部確認才可簽收 Stage 1**（若正式程序啟動失敗而未寫出新 manifest，canary 留下的有效 `current.done.json` 會讓 probe 持續輸出 `run_expected 0`，`TradingProcessDown` 不會觸發且面板會停在 canary 數據）：

   Trading01（root，`. "$WORK/vars"`）：

   ```bash
   sleep 30
   CANARY_RUN_ID="$(cat "$WORK/canary-run-id")"
   NEW_RUN_ID="$(jq -r '.run_id' /home/ubuntu/tnauqquant/run-state/popdex-multi-accounts/current.json)"
   [ -n "$CANARY_RUN_ID" ] && [ -n "$NEW_RUN_ID" ] && [ "$NEW_RUN_ID" != "null" ] &&
     [ "$NEW_RUN_ID" != "$CANARY_RUN_ID" ] && echo "NEW-PROD-RUN-ID=$NEW_RUN_ID (canary=$CANARY_RUN_ID)"
   PROM=/var/lib/skyeye-trading/textfile/tnauqquant-popdex-multi-accounts.prom
   OLD_PROM=/var/lib/skyeye-trading/textfile/tnauqquant-popdex-btc.prom
   grep -E '^tnauqquant_(current_run_info|process_count|run_expected|runtime_contract_available|process_identity_ok|strategy_identity_ok|config_snapshot_match|log_binding_ok|marker_binding_ok|risk_stopped|done_marker)[{]' "$PROM"
   grep -E '^tnauqquant_(process_count|run_expected)[{]' "$OLD_PROM"
   systemctl is-active tnauqquant@popdex-btc.service   # 仍為 inactive（唯讀確認）
   ```

   monitoring-prod（ubuntu，`. "$CUT/vars"; . "$CUT/helpers.sh"`）：

   ```bash
   probe_ages | tee "$CUT/probe-ages.stage1.json"
   q 'trading_strategy_process_count{server_id="trading01",strategy=~"popdex-multi-accounts|popdex-btc"}'
   q 'trading_strategy_run_expected{server_id="trading01",strategy=~"popdex-multi-accounts|popdex-btc"}'
   q 'trading_strategy_binding_ok{server_id="trading01",strategy="popdex-multi-accounts"}'
   t01_alerts | tee "$CUT/t01-alerts.stage1.json"
   ```

   簽收條件（全部通過才可簽收 Stage 1；任一項不符立即回報 Wan 排查，不得簽收）：
   - `NEW-PROD-RUN-ID=...` 印出，新 `run_id` **不同於** `$CANARY_RUN_ID`，且 `tnauqquant_current_run_info` 的 `run_id` 等於 `NEW_RUN_ID`；
   - 新 lane `popdex-multi-accounts`：`process_count 1`、`run_expected 1`、五項 binding（`process_identity_ok`、`strategy_identity_ok`、`config_snapshot_match`、`log_binding_ok`、`marker_binding_ok`）皆為 `1`、`risk_stopped 0`、無 `tnauqquant_done_marker`；
   - 舊 lane `popdex-btc`：`process_count 0`、`run_expected 0`、`tnauqquant@popdex-btc.service` 為 `inactive`；
   - monitoring-prod：`probe_ages` 全部 `< 60`，Prometheus 的 `trading_strategy_process_count`（新 lane `1`、舊 lane `0`）、`trading_strategy_run_expected`（新 lane `1`、舊 lane `0`）、`trading_strategy_binding_ok`（新 lane `1`）全數相符。

### Stage 2：穩定觀察後正式退場 `popdex-btc`（另案 S3）

確認 `popdex-multi-accounts` 穩定運行且不再回退至 `popdex-btc` 後，依標準 Remove 順序（**先中央、後 host**，避免 `TradingTelemetryMissing`）：

1. **Repo**：`scripts/trading-target remove --server trading01 --strategy popdex-btc` → 跑 `tests/trading/test-central-config.sh` → PR & merge。
2. **Central（monitoring-prod）**：`scripts/central-deploy`。
3. **Host（Trading01，root）**：`sudo "$SETUP" retire --strategy popdex-btc </dev/null`。

### 歷史資料延續說明

- `scripts/trading-target remove` 與 `setup-linux.sh retire` **都不會刪除 Prometheus TSDB 或 Loki 中的歷史資料**。
- 退場後 `popdex-btc` 不再出現在 `Trading · 策略總覽` 與 `$strategy` 預設下拉清單（總覽表只留新的合併 BTC 策略 `popdex-multi-accounts`）；歷史資料在 retention 期內仍可於 Grafana Explore 以 `strategy="popdex-btc"` 查詢，或直接開 `/d/trading-strategy-detail/trading-strategy-detail?var-server_id=trading01&var-strategy=popdex-btc` 搭配舊時間區間檢視。

## Rollback

### Host：共用 `probe.sh` 更新失敗或既有 lane 異常（Trading01）

1. 停止並停用全部 `skyeye-trading-probe@*.timer` 與 `.service`（不碰 `tnauqquant@*`）。
2. 用前版 `origin/master` checkout 的 `setup-linux.sh` 依 `$WORK/timers.before` 重跑既有 lane 的 `add`（或由第一筆 `add` 印出的 rollback record 還原 `/usr/local/libexec/skyeye-trading/probe.sh` 並 `systemctl daemon-reload`）。
3. 若 `popdex-multi-accounts` 已安裝，執行 `sudo "$SETUP" retire --strategy popdex-multi-accounts </dev/null`。
4. 依 `$WORK/timers.before` 還原所有既有 timer 狀態後，重新讀取每支 lane 的 timer 狀態寫成 `$WORK/timers.rollback`，與 `$WORK/timers.before` 比對並要求退出碼為 `0`，同時確認 monitoring-prod `probe_ages < 60`：

   ```bash
   while read -r s _ _ <&3; do
     e=disabled; a=inactive
     systemctl is-enabled --quiet "skyeye-trading-probe@$s.timer" && e=enabled
     systemctl is-active --quiet "skyeye-trading-probe@$s.timer" && a=active
     printf '%s %s %s\n' "$s" "$e" "$a"
   done 3<"$WORK/timers.before" | tee "$WORK/timers.rollback"
   diff "$WORK/timers.before" "$WORK/timers.rollback" && echo TIMERS-ROLLBACK-OK
   ```

### Central：`popdex-multi-accounts` 中央退回（monitoring-prod）

依 [docs/operations.md](operations.md) 與 `scripts/central-deploy` 標準流程退回：**不得**套用舊 rollout 的 R5（目標為 `popdex-btc`）、**不對 merge commit 執行 `git revert`**（雙 parent merge 需指定 mainline 且可能連帶撤回同批其他變更），也**不**手動改寫 monitoring-prod 現場檔案。

1. **Repo（manager）**：開一個**只撤回 WAN-928 變更**的 revert PR（保留 `popdex-btc` 與同批其他變更）：
   - 執行 `scripts/trading-target remove --server trading01 --strategy popdex-multi-accounts` 移除新 target；
   - 若 rules 或 dashboard 有問題，針對性還原 `prometheus/rules/trading.yml`（4 條 `trading_strategy_*_executor_*` recording rules）、`prometheus/rules/tests/trading.test.yml` 與 `grafana/dashboards/Trading/trading-strategy-detail.json`；同一個 revert PR 要一併撤回 `tests/trading/test-central-config.sh` 與 `tests/trading/test-dashboard-semantics.sh` 裡依賴「各帳號明細 · 多帳號策略」面板或四條 executor rules 的 WAN-928 斷言（其他測試保留）；
   - 核對 PR diff 保留 `popdex-btc` 及同批其他變更、通過 `scripts/verify-all` 後 merge，提供完整 SHA `REVERT_SHA`。
2. **Central（monitoring-prod，避開 UTC 18:15–19:30）**：以標準 `scripts/central-deploy` 驗證並部署 `REVERT_SHA`（`central-deploy` 本身會驗證 Prometheus/Loki 規則、derived inventory test 與 Grafana dashboard 讀回比對）：

   ```bash
   cd /home/ubuntu/SkyEye
   . "$CUT/vars"; . "$CUT/helpers.sh"
   REVERT_SHA=<manager 提供的完整 SHA>
   scripts/central-deploy --dry-run --expect "$REVERT_SHA" 2>&1 | tee "$CUT/revert-dry-run.log"
   ```

   確認最後一行是 `Dry run: validation passed` 後執行正式部署：

   ```bash
   scripts/central-deploy --expect "$REVERT_SHA" 2>&1 | tee "$CUT/revert-deploy.log"; echo "rc=${PIPESTATUS[0]}"
   ```

3. **部署後驗收**：確認 `central-deploy` 本身 `rc=0` 且輸出 `central-deploy: done; applied <REVERT_SHA 前 12 碼>` 後，等 70 秒補驗三項（`popdex-btc` target 仍在、rule health 正常、dashboard UID 讀得到）：

   ```bash
   sleep 70
   # 1) popdex-multi-accounts 已移除且 popdex-btc 的 target 仍在
   targets | tee "$CUT/revert-targets.json"
   jq -e 'map(select(.server_id == "trading01" and .strategy == "popdex-multi-accounts")) | length == 0' "$CUT/revert-targets.json"   # true
   jq -e 'map(select(.server_id == "trading01" and .strategy == "popdex-btc")) | length == 1' "$CUT/revert-targets.json"              # true
   # 2) Prometheus trading-strategy-recording 群組 rule health 正常
   curl -fsS http://127.0.0.1:9090/api/v1/rules | jq -e '
     (.data.groups[] | select(.name == "trading-strategy-recording")) as $g |
     ($g.rules | length > 0) and ($g.rules | map(.health == "ok") | all)
   ' && echo RULE-HEALTH-OK
   # 3) Grafana trading-strategy-detail dashboard UID 讀得到（token 經 stdin 傳遞）
   TOKEN_FILE="${SKYEYE_GRAFANA_TOKEN_FILE:-/home/ubuntu/.config/skyeye/grafana-viewer-token}"
   printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\r\n' <"$TOKEN_FILE")" |
     curl -fsS -K - http://127.0.0.1:3000/api/dashboards/uid/trading-strategy-detail |
     jq -e '.dashboard.uid == "trading-strategy-detail"' && echo DASHBOARD-UID-OK
   ```

4. **Host（選做，一律排在「退回 `popdex-btc`」帳號交還簽收之後）**：中央退回全部通過，且（若涉及退回 `popdex-btc`）已完成下方「退回 `popdex-btc`」帳號交還簽收後，才於 Trading01（root）執行 `sudo "$SETUP" retire --strategy popdex-multi-accounts </dev/null`（保持 `popdex-btc` probe 不動）。

### 退回 `popdex-btc`（Step 5c canary 失敗或 Step 6 Stage 1 觀察期間）

**帳號交還前置條件（必做）：** 兩條 lane 共用 `popdex-main`，且具名排程 `tnauqquant-daily-restart@popdex-multi-accounts.timer` 會觸發 helper service 重新拉起已停止的主服務。**必須先確認新 lane 已平倉、已停止且所有重啟排程皆已停用，才可將帳號交還 `popdex-btc`。**

1. **Wan／tnauqquant 側**：確認 `popdex-multi-accounts` 已平倉（若本次 run 從未產生 settled 部位，一併提供兩支帳號當下平倉證據，例如交易所 UI 或 tnauqquant 唯讀 rehearsal 輸出）、已停止並 disable `tnauqquant@popdex-multi-accounts.service`，而且**所有重啟排程與啟動來源皆已停用**（包括具名的 `tnauqquant-daily-restart@popdex-multi-accounts.timer` 與任何其他會啟動新 lane 的 timer），完成後通知 SkyEye operator。
2. **SkyEye operator（Trading01，root，`. "$WORK/vars"`）唯讀核對新 lane 的 timer、程序與持倉**：

   ```bash
   systemctl is-active  tnauqquant@popdex-multi-accounts.service                     # inactive
   systemctl is-enabled tnauqquant@popdex-multi-accounts.service                     # disabled、masked 或 static
   systemctl is-active  tnauqquant-daily-restart@popdex-multi-accounts.timer 2>&1    # inactive
   systemctl is-enabled tnauqquant-daily-restart@popdex-multi-accounts.timer 2>&1    # disabled、masked、static 或 not-found
   pgrep -a -f 'popdex_multi_accounts_config'                                        # 沒有輸出
   systemctl list-unit-files --type=timer --no-legend >"$WORK/multi-timer-files" && [ -s "$WORK/multi-timer-files" ] && echo MULTI-TIMER-FILES-READ
   systemctl list-units --type=timer --all --no-legend --plain >"$WORK/multi-timer-units" && [ -s "$WORK/multi-timer-units" ] && echo MULTI-TIMER-UNITS-READ
   { awk '{ print $1 }' "$WORK/multi-timer-files" | sed 's/@[.]timer$/@popdex-multi-accounts.timer/'; awk '{ print $1 }' "$WORK/multi-timer-units"; } |
     sort -u | while read -r t; do
       printf '%s triggers=%s enabled=%s active=%s\n' "$t" \
         "$(systemctl show -p Triggers --value "$t")" \
         "$(systemctl is-enabled "$t" 2>&1)" "$(systemctl is-active "$t")"
     done | tee "$WORK/popdex-multi-rollback-timers"
   grep -E '^tnauqquant_(process_count|current_position_btc|current_net_position_btc)[{]' \
     /var/lib/skyeye-trading/textfile/tnauqquant-popdex-multi-accounts.prom
   ```

   必須同時滿足程序、排程、平倉三項前置條件（缺任何一項證據即 **STOP，通知 Wan 處理，絕不把帳號交還 `popdex-btc`**）：
   - **程序**：`tnauqquant@popdex-multi-accounts.service` 為 `inactive` 且非 `enabled`、無殘留程序、`.prom` 的 `process_count` 為 `0`。
   - **排程**：`MULTI-TIMER-FILES-READ` 與 `MULTI-TIMER-UNITS-READ` 皆印出（任一份清單讀不到就停止交接）；`tnauqquant-daily-restart@popdex-multi-accounts.timer` 與 `$WORK/popdex-multi-rollback-timers` 中任何其他可啟動新 lane 的 timer 皆為 `inactive` 且非 `enabled`（`disabled`/`masked`/`static`/`not-found`）。
   - **平倉**：若 `.prom` 有 settled 部位樣本，須為平倉（`side="flat"`、`net_position_btc 0`）；若本次 run 從來沒產生 settled 部位，平倉證據改採 Wan 提供的兩支帳號當下持倉確認（例如交易所 UI 或 tnauqquant 的唯讀 rehearsal 輸出），SkyEye 不要求 `.prom` 有部位樣本。

3. **SkyEye operator（Trading01）**：將 `popdex-multi-accounts.env` 改回 `TQ_STRATEGY_DISABLED=1` 並跑 `"$SETUP" add`，再將 `popdex-btc.env` 還原為 `TQ_STRATEGY_DISABLED=0`（或還原 `$WORK/popdex-btc.env`）並跑 `"$SETUP" add`。
4. **Wan／tnauqquant 側**：確認步驟 2–3 完成後，重新啟用並啟動 `tnauqquant@popdex-btc`（及原 timer）；SkyEye operator 唯讀核對 `popdex-btc` 恢復 `process_count 1`、`run_expected 1` 且 `popdex-multi-accounts` 為 `process_count 0`、`run_expected 0`。

## 執行紀錄

| 項目 | 時間（UTC） | 結果／record |
|---|---|---|
| Step 0 staging | | `MERGE`、`STAGE` |
| Step 1 前置檢查與基準 | | `WORK`、`CUT`、Alloy 版本、核對後的 `TQ_EXECUTABLE`／`TQ_INSTANCE_ID`／`TQ_EXECUTOR_MAP` |
| Step 2 host probe 更新 + add | | `TIMERS-RESTORED`、Rollback record、`rc` |
| Step 3 中央檢查 | | `siblings_same`、`all_fresh`、`popdex_multi` |
| Step 4 central-deploy | | applied SHA、`TARGETS-OK`、Grafana 載入結果 |
| Step 5a 帳號交接前置 | | Wan 停用 `popdex-btc`、唯讀核對程序與 timer、`popdex-btc` `TQ_STRATEGY_DISABLED=1` |
| Step 5b–5c canary 核對 | | `QUANT-EXECUTABLE-FILE`、`QUANT-EXECUTABLE-MATCH`、`CANARY-TERMINAL-OK`、`CANARY_RUN_ID`、五項 binding、合併與四項 per-executor `.prom` 對帳、Loki／Grafana |
| Step 6 Stage 1 啟用與簽收 | | `popdex-multi-accounts` `TQ_STRATEGY_DISABLED=0`、新 `NEW_RUN_ID != CANARY_RUN_ID`、新 lane `process_count=1/run_expected=1`、舊 lane `process_count=0` |
| Step 6 Stage 2 退場（S3） | | `trading-target remove` PR、`central-deploy`、`retire` record |
