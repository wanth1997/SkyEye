# Trading01 PopDEX rollout：Alloy 升級、共用 probe 更新與 `popdex-btc`

> **來源：** 2026-11-14 Wan 透過 tnauqquant manager 提出：「幫我把 Lighter Robinhood 在 Grafana 上面也新增，就是 Popdex 這個交易所」，並要求「正規地去做升級」。SkyEye task `SKYEYE-POPDEX-20261114`，manager PLAN_APPROVED（D1 `TQ_STRATEGY_DISABLED`、D2 Alloy 1.16.3、D3 `upgrade-linux.sh`、D5 先 host 後中央）。
>
> **本文件是 operator 程序，repo 變更 merge 後不會自動生效。** Phase 2–4 已由 `tests/trading/test-trading01-popdex-rollout.sh` 在假的 Trading01 上演練（含 Phase 3/4 rollback 逐 byte 還原），`upgrade-linux.sh` 由 `tests/alloy/test-upgrade-linux.sh` 覆蓋。
>
> **狀態：** 尚未執行。

## 這次會改什麼

| Phase | 標記 | 內容 |
|---|---|---|
| 0 | `[CHANGE Trading01]`（只新增 staging 目錄） | 把 `MERGE` 的 `agents/alloy` 複製到 Trading01 |
| 1 | `[READ-ONLY]`，另建 `$WORK`／`$CUT` 紀錄目錄 | Trading01 與 monitoring-prod 前置檢查與基準值 |
| 2 | `[CHANGE Trading01]` | Alloy 1.16.0 → `$ALLOY_TO`（預設 1.16.3），**restart 一次，會中斷 ZenIncome 與 Trading 的 Alloy pipeline** |
| 3 | `[CHANGE Trading01]` | 停兩個既有 probe timer、安裝新版共用 probe 與 `popdex-btc`、重新 add 兩個既有 strategy 並恢復 timer |
| 4 | `[CHANGE Trading01]` | Mainnet probe env 加上 `TQ_STRATEGY_DISABLED=1` |
| 5 | `[CHANGE monitoring-prod]` | `scripts/central-deploy` 讓 `popdex-btc` inventory row 上線 |
| 6 | `[READ-ONLY]` | 最終核對、紀錄 |

Trading01 上會變動的只有：`alloy` package 與 hold、`/etc/alloy/trading-*.alloy`、`/etc/default/alloy`（內容不變，會被重寫一次）、`/etc/skyeye-trading/`、`/usr/local/libexec/skyeye-trading/`、`/etc/systemd/system/skyeye-trading-probe@.{service,timer}` 與其 wants link、`/var/lib/skyeye-trading/textfile/`、`/var/lib/skyeye-alloy/upgrade/`，以及 `ensure-log-access.sh` 為 PopDEX raw log 加上 `alloy` 使用者的唯讀 ACL（與 Robinhood 相同的做法）。ZenIncome 的 `/etc/alloy/config.alloy` 與不會被載入的 `trading.alloy.pre-pr34.*` 不得改變，每個 Phase 都會核對 hash。

## 執行前必讀

**Wan 必須事先決定或在場：**

1. 核准時窗：Phase 2 讓 Alloy restart 一次（ZenIncome 的 log 與 metrics 會中斷到 Alloy ready，通常數秒、最多 60 秒），Phase 3 讓 Robinhood 與 Mainnet 的 probe 停 1–3 分鐘。
2. 確認 `ALLOY_TO`：`1.16.3`（預設，與目前 1.16.0 同一個 minor）或 `1.18.1`。
3. 同意 Phase 4 的語意：Mainnet 設成 `TQ_STRATEGY_DISABLED=1` 後，有人啟動 Mainnet 會出現 shadow `TradingUnexpectedProcess`，直到用 `add` 把它改回 `0`。
4. 提供 Trading01 的 SSH 目標（下稱 `T01`）。
5. Phase 2 期間要聯絡得到：`upgrade-linux.sh` exit 3（自動還原未完成）時，ZenIncome 可能停擺，要 Wan 決定後續。

**硬性限制：**

- **不得 start、stop、restart、enable 或 disable 任何 `tnauqquant@*` service 或 timer，不得修改 tnauqquant 的 config、env、run-state 或程式。** 本文件只讀取它們。`setup-linux.sh` 只操作 `skyeye-trading-probe@*` 與 `alloy`，從不啟動交易程序。
- 不碰 Mac mini（`macmini-m2`）。
- Trading01 與 monitoring-prod 各只能有一位 operator 執行本文件，一次一位。換手時把 `$WORK`／`$CUT` 路徑與執行紀錄交給下一位，下一位從 `$WORK/vars` 繼續，不重做已完成的 Phase。
- **時間：** Phase 2 到 Phase 5 全部避開 UTC 18:15–19:30（18:30Z 是 Trading01 tnauqquant 的每日重啟 timer，19:00Z 是 monitoring-prod 的備份 cron）。`scripts/central-deploy` 在任何情況下都不得在 UTC 18:30–19:30 執行。
- **順序固定為先 host、後中央（D5）。** 這個 PR merge 之後，monitoring-prod **不得**執行 `scripts/central-deploy`（包括為了其他變更），直到 Phase 3 的中央檢查確認 `popdex-btc` 已在 remote-write。`central-deploy` 一律部署 `origin/master` 最新 commit，提前部署會讓 `popdex-btc` 進 inventory 卻沒有資料，出現 shadow `TradingTelemetryMissing`。若提前部署已經發生，記下時間，該段 `popdex-btc` 告警排除於 shadow 證據之外，照常繼續。
- PR 在 rollout 時窗開始時才 merge。從 merge 到 Phase 5 完成，不 merge 其他 PR 到 master，Phase 5 的 `--expect "$MERGE"` 才會通過。
- **中止規則：** 只要 rollout 在 Phase 3 中央檢查通過前停下（任何 STOP 或 rollback），下一次 `central-deploy` 之前，manager 先依 [README 的 Remove 第 1 步](../agents/alloy/trading/README.md#add-or-remove-a-trading-target)用 `scripts/trading-target remove --server trading01 --strategy popdex-btc` 開 PR 並 merge，master 不留沒有 probe 的 row。下次 rollout 再用 `scripts/trading-target add` 加回。
- Trading01 的 `/home/ubuntu/skyeye-agent` 是舊的 SkyEye checkout（2026-11-14 盤點時落後 master 81 個 commit，並有本機修改 `docs/code-patterns/go.md`）。**本次保留原狀：不 pull、不 reset、不執行其中任何腳本。** 之後的 operator 也不要用它安裝或升級，一律照 Phase 0 另建 staging。`/home/ubuntu/skyeye-staging/` 內較舊的 staging 目錄同樣不動。
- **不加 Alertmanager silence。** 所有 Trading 告警都是 `notification_mode="shadow"`，不會發 Telegram。ZenIncome 告警照常通知，它們是 Alloy 重啟出問題時的真實訊號。
- 不要印出 `/etc/alloy/config.alloy` 或 `/etc/default/alloy` 全文，前者含 Cloudflare service token。本文件只取 hash 與指定的單行設定。
- Trading01 的命令都在 `sudo -i` 開的 root bash 內執行；monitoring-prod 的命令以 `ubuntu` 在 `/home/ubuntu/SkyEye` 執行。

**預期會看到的 shadow 告警（不是失敗）：**

- Phase 1：Mainnet（`lighter-mainnet-btc-canary`）的 `TradingProcessDown`。原因是 11-07 以 `systemctl stop` 停下時沒有 done marker，留下的 `current.json` 讓 probe 判定 `run_expected=1`。Phase 4 修正。
- Phase 3：Robinhood 與 Mainnet 的 probe 停超過 180 秒時，會短暫出現 `TradingTelemetryMissing`。
- Phase 5：PopDEX lane 當下沒有在跑時，`popdex-btc` 會出現 `TradingProcessDown` 與 `TradingRuntimeContractMissing`，直到 lane 啟動（env 是 `TQ_POC_RUN_EXPECTED=1`、`TQ_REQUIRE_RUNTIME_CONTRACT=1`）。
- 已知殘留：`TradingRunBindingInvalid` 不看 `run_expected`。Mainnet 的 config 在 manifest 之後被改過時，Phase 4 之後它仍可能 firing，記錄即可。

把 Phase 2 開始到 Phase 6 結束的 UTC 時窗寫進執行紀錄，並從 `trading01` 的 Trading shadow／canary 證據中排除。

## 變數

| 名稱 | 說明 |
|---|---|
| `MERGE` | 含本次變更的 master commit 完整 SHA（PR merge 後由 manager 提供） |
| `M7` | `MERGE` 前 7 碼 |
| `T01` | Trading01 的 SSH 目標，由 Wan 提供 |
| `ALLOY_TO` | `1.16.3`（預設）或 Wan 核准的 `1.18.1` |
| `STAGE` | Trading01 上的 staging：`/home/ubuntu/skyeye-staging/popdex-$M7`，root 擁有 |
| `WORK` | Trading01 上的紀錄目錄：`/root/skyeye-popdex-<UTC>`，mode 700。內含 instance env 複本（不含中央憑證） |
| `CUT` | monitoring-prod 上的紀錄目錄：`$HOME/popdex-rollout-$M7`，mode 700 |
| `UPGRADE_RECORD` | Phase 2 的 `upgrade-linux.sh` 印出的 record 目錄 |

## Phase 0 — Staging（operator 機器 → Trading01）

operator 機器，在 SkyEye checkout 內：

```bash
MERGE=<完整 SHA>; M7=${MERGE:0:7}
git fetch origin
[ "$(git rev-parse origin/master)" = "$MERGE" ] && echo MASTER-IS-MERGE
git cat-file -e "$MERGE:docs/trading01-popdex-rollout.md" && git cat-file -e "$MERGE:agents/alloy/upgrade-linux.sh" && echo MERGE-HAS-ROLLOUT
OUT=$(mktemp -d)
git archive --format=tar --prefix="popdex-$M7/" "$MERGE" agents/alloy >"$OUT/skyeye-alloy-$M7.tar"
shasum -a 256 "$OUT/skyeye-alloy-$M7.tar"                      # 記下 TAR_SHA
git show "$MERGE:agents/alloy/trading/probe.sh" | shasum -a 256   # 記下 PROBE_SHA
scp "$OUT/skyeye-alloy-$M7.tar" "$T01:/tmp/skyeye-alloy-$M7.tar"
```

`MASTER-IS-MERGE` 與 `MERGE-HAS-ROLLOUT` 都要印出，否則停下，向 manager 確認 `MERGE`。

`[CHANGE Trading01]`（只新增 staging），以 `ubuntu` 登入 Trading01：

```bash
M7=<同上>
sha256sum /tmp/skyeye-alloy-$M7.tar                              # 必須等於 TAR_SHA
mkdir -p /home/ubuntu/skyeye-staging
test ! -e /home/ubuntu/skyeye-staging/popdex-$M7 && echo STAGE-FREE
tar -x -f /tmp/skyeye-alloy-$M7.tar -C /home/ubuntu/skyeye-staging
sudo chown -R root:root /home/ubuntu/skyeye-staging/popdex-$M7
sha256sum /home/ubuntu/skyeye-staging/popdex-$M7/agents/alloy/trading/probe.sh   # 必須等於 PROBE_SHA
rm -f /tmp/skyeye-alloy-$M7.tar
```

`STAGE-FREE` 沒印出表示目錄已存在：停下，不覆蓋，改用新的 `MERGE` 或請 manager 確認舊目錄的來源。staging 改成 root 擁有，root 執行的腳本就不能被一般使用者改動。

## Phase 1 — 前置檢查

這個 Phase 只讀取，唯一的寫入是 `$WORK`、`$CUT` 紀錄與 `--render-only` 輸出（在 `$WORK` 內）。**任何一項不符就 STOP，不進 Phase 2。** STOP 時 host 沒有變更，依[中止規則](#執行前必讀)處理 inventory。

### Trading01（root）

開 root shell 並建立紀錄目錄與 helper：

```bash
sudo -i
MERGE=<完整 SHA>; M7=${MERGE:0:7}; ALLOY_TO=1.16.3      # 或 Wan 核准的 1.18.1
STAGE=/home/ubuntu/skyeye-staging/popdex-$M7
WORK=/root/skyeye-popdex-$(date -u +%Y%m%dT%H%M%SZ); install -d -m 700 "$WORK"
declare -p MERGE M7 ALLOY_TO STAGE WORK >"$WORK/vars"
cat >"$WORK/helpers.sh" <<'EOF'
SETUP="$STAGE/agents/alloy/trading/setup-linux.sh"
UPGRADE="$STAGE/agents/alloy/upgrade-linux.sh"
HOST_ROOT=""   # 在 Trading01 上一定是空字串；只有 rehearsal 測試會把它換成測試根目錄
INSTANCES="$HOST_ROOT/etc/skyeye-trading/instances"
TEXTFILE="$HOST_ROOT/var/lib/skyeye-trading/textfile"
ALLOY_ETC="$HOST_ROOT/etc/alloy"
SYSTEMD_ETC="$HOST_ROOT/etc/systemd/system"
# 每個已安裝 instance 一行：strategy enabled|disabled active|inactive
record_timer_states() {
  local env_path strategy unit enabled active
  for env_path in "$INSTANCES"/*.env; do
    strategy="$(basename "$env_path" .env)"
    unit="skyeye-trading-probe@$strategy.timer"
    enabled=disabled
    active=inactive
    if systemctl is-enabled --quiet "$unit"; then enabled=enabled; fi
    if systemctl is-active --quiet "$unit"; then active=active; fi
    printf '%s %s %s\n' "$strategy" "$enabled" "$active"
  done
}
# 每個 probe 輸出檔的關鍵值：檔名 metric 值
textfile_values() {
  local f
  for f in "$TEXTFILE"/tnauqquant-*.prom; do
    awk -v s="$(basename "$f" .prom)" '
      /^tnauqquant_(probe_timestamp_seconds|run_expected|process_count|runtime_contract_available|process_identity_ok|strategy_identity_ok|config_snapshot_match|log_binding_ok|marker_binding_ok)[{]/ {
        name = $0; sub(/[{].*/, "", name); print s, name, $NF
      }' "$f"
  done
}
# tnauqquant 的 unit 與程序（只讀）
tnauqquant_state() {
  systemctl list-units --all --no-legend --plain 'tnauqquant*' | awk '{print $1, $2, $3, $4}'
  systemctl list-unit-files --no-legend 'tnauqquant*' | awk '{print $1, $2}'
  pgrep -a -f '/home/ubuntu/tnauqquant/bin/' || true
}
# R3 用：每個 templated probe instance，包括已經 retire 的 popdex-btc
probe_strategies() {
  local env_path
  {
    for env_path in "$INSTANCES"/*.env; do
      [ -e "$env_path" ] && basename "$env_path" .env
    done
    awk '{ print $1 }' "$WORK/timers.before"
    echo popdex-btc
  } | LC_ALL=C sort -u
}
# 停止並 disable 每個 templated probe，再確認每個 timer 都 disabled + inactive、
# service 都 inactive，也沒有任何 skyeye-trading-probe@ 的 wants link。全部做到才回傳 0
stop_all_probes() {
  local s link rc=0
  for s in $(probe_strategies); do
    systemctl disable --now "skyeye-trading-probe@$s.timer" || rc=1
    systemctl stop "skyeye-trading-probe@$s.service" || rc=1
  done
  for s in $(probe_strategies); do
    if systemctl is-enabled --quiet "skyeye-trading-probe@$s.timer" ||
      systemctl is-active --quiet "skyeye-trading-probe@$s.timer" ||
      systemctl is-active --quiet "skyeye-trading-probe@$s.service"; then
      echo "still enabled or active: skyeye-trading-probe@$s"
      rc=1
    fi
  done
  if systemctl is-active --quiet 'skyeye-trading-probe@*.service' ||
    systemctl is-active --quiet 'skyeye-trading-probe@*.timer' ||
    systemctl is-enabled --quiet 'skyeye-trading-probe@*.timer'; then
    echo "a templated probe is still enabled or active"
    rc=1
  fi
  for link in "$SYSTEMD_ETC"/timers.target.wants/skyeye-trading-probe@*.timer; do
    if [ -e "$link" ] || [ -L "$link" ]; then
      echo "still enabled: $link"
      rc=1
    fi
  done
  return "$rc"
}
# R3：Phase 3/4 完整退回。每一步失敗都印出 STOP 並回傳 1，之後的步驟不會執行。
# 共用檔案只在 stop_all_probes 確認全部 probe 停止並 disabled 之後才還原。
r3_rollback() {
  local rc record path s e a
  date -u +%FT%TZ >"$WORK/r3-start"
  if [ -f "$INSTANCES/popdex-btc.env" ]; then
    "$SETUP" retire --strategy popdex-btc </dev/null >"$WORK/retire-popdex-btc.out" 2>&1
    rc=$?
    cat "$WORK/retire-popdex-btc.out"
    if [ "$rc" -ne 0 ]; then
      echo "STOP: retire popdex-btc exited $rc; R3 changed nothing else"
      return 1
    fi
  fi
  if ! stop_all_probes; then
    echo "STOP: a templated probe is still enabled or active; no shared file was restored"
    return 1
  fi
  echo PROBES-STOPPED
  # 最新的 record 先還原；先確認每個 record 都完整，才開始動檔案
  awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) if (line[i] != "") print line[i] }' \
    "$WORK/records.list" >"$WORK/records.reverse"
  while IFS= read -r record <&3; do
    if [ ! -f "$record/absent.list" ] || [ ! -f "$record/present.list" ]; then
      echo "STOP: incomplete record $record; no shared file was restored"
      return 1
    fi
  done 3<"$WORK/records.reverse"
  while IFS= read -r record <&3; do
    while IFS= read -r path <&4; do
      [ -z "$path" ] || rm -f -- "$path" || { echo "STOP: cannot remove $path"; return 1; }
    done 4<"$record/absent.list"
    while IFS= read -r path <&4; do
      [ -n "$path" ] || continue
      { rm -f -- "$path" && mkdir -p "$(dirname "$path")" &&
        cp -a "$record/previous/${path#"$HOST_ROOT"/}" "$path"; } ||
        { echo "STOP: cannot restore $path from $record"; return 1; }
    done 4<"$record/present.list"
    echo "restored $record"
  done 3<"$WORK/records.reverse"
  systemctl daemon-reload || { echo "STOP: systemctl daemon-reload failed"; return 1; }
  { alloy validate "$ALLOY_ETC" && systemctl reload alloy; } ||
    { echo "STOP: the restored Alloy config was not reloaded"; return 1; }
  echo ALLOY-RELOADED
  while read -r s e a <&3; do
    [ "$e $a" != "enabled active" ] || systemctl enable --now "skyeye-trading-probe@$s.timer" ||
      { echo "STOP: cannot enable skyeye-trading-probe@$s.timer"; return 1; }
  done 3<"$WORK/timers.before"
  echo TIMERS-ENABLED
}
EOF
. "$WORK/helpers.sh"
date -u +%FT%TZ | tee "$WORK/phase1-start"
```

斷線重連時：`sudo -i`，`WORK=$(ls -d /root/skyeye-popdex-* | tail -n 1); . "$WORK/vars"; . "$WORK/helpers.sh"`。

**Alloy：**

```bash
alloy --version | head -n 1                              # alloy, version v1.16.0 …
dpkg-query -W -f='${Status} ${Version}\n' alloy          # install ok installed 1.16.0-1 或 hold ok installed 1.16.0-1
apt-mark showhold alloy | tee "$WORK/hold.before"        # 空白或 alloy，都可以
systemctl is-active alloy                                # active
systemctl show -p MainPID --value alloy | tee "$WORK/alloy-pid.before"
systemctl show -p CanReload --value alloy                # yes
grep -cxF 'CONFIG_FILE="/etc/alloy"' /etc/default/alloy  # 1
grep -c '^CONFIG_FILE=' /etc/default/alloy               # 1
grep -E '^(CUSTOM_ARGS|RESTART_ON_UPGRADE)=' /etc/default/alloy | tee "$WORK/alloy-defaults.before"
apt-cache policy alloy | tee "$WORK/apt-policy.before"   # 版本表必須列出 $ALLOY_TO-1 與 1.16.0-1
df -h /var/lib /tmp                                      # 兩者可用空間都要 ≥ 1G
```

- `apt-cache policy` 沒有列出 `$ALLOY_TO-1`：`[CHANGE Trading01]`（只更新 apt 套件清單）執行一次 `apt-get update`，再看一次；仍沒有就 STOP。沒有列出 `1.16.0-1` 就 STOP：失敗時無法退回。
- `CanReload` 不是 `yes`、`CONFIG_FILE` 不是剛好一行 `CONFIG_FILE="/etc/alloy"`：STOP（Phase 3 的 `add` 會要求 restart）。

```bash
"$UPGRADE" --to "$ALLOY_TO" --check 2>&1 | tee "$WORK/upgrade-check.log"; echo "rc=${PIPESTATUS[0]}"
READY_URL=$(sed -n 's/.*; ready check: //p' "$WORK/upgrade-check.log" | tail -n 1)
METRICS_URL="${READY_URL%/-/ready}/metrics"
declare -p READY_URL METRICS_URL >>"$WORK/vars"
curl -fsS "$READY_URL"; echo                             # 成功（HTTP 200）
curl -fsS "$METRICS_URL" | grep -E '^alloy_component_controller_running_components\{' | sort | tee "$WORK/components.before"
```

`--check` 只在 `/tmp` 下載與驗證，結束時刪掉，不改任何東西。預期：

```
Downloading alloy 1.16.3-1 and, for a rollback, alloy 1.16.0-1
…apt-get download 的輸出…
Check passed, nothing was changed: alloy 1.16.0-1 -> 1.16.3-1; Alloy active=1 enabled=1 held=<0|1>; restart: yes, interrupts every Alloy pipeline once; ready check: http://127.0.0.1:12345/-/ready
rc=0
```

apt 以 root 下載時印出的 `Download is performed unsandboxed as root…` 是正常的 notice。`ALLOY_TO=1.18.1` 時版本換成 `1.18.1-1`。其他結果：

- `SkyEye Alloy upgrade: refused, nothing was changed: apt offers no alloy …`：執行 `apt-get update` 後重跑一次；仍拒絕就 STOP。
- 其他 `refused, nothing was changed: …`（包括 `Alloy … rejects the live configuration`）：STOP，把訊息交給 manager。
- `Already at Alloy …`：Trading01 已不是 1.16.0，和盤點不符，STOP。

**檔案與 probe 基準：**

```bash
find /etc/alloy -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum | tee "$WORK/alloy-files.before"
sha256sum /etc/default/alloy | tee -a "$WORK/alloy-files.before"
ls /etc/alloy                                             # config.alloy、trading-metrics.alloy、兩個 trading-<strategy>.alloy、trading.alloy.pre-pr34.*
sha256sum /usr/local/libexec/skyeye-trading/* /etc/systemd/system/skyeye-trading-probe@.service \
  /etc/systemd/system/skyeye-trading-probe@.timer | tee "$WORK/shared-files.before"   # probe.sh 預期 8239ebe9…（SkyEye 5803549），僅供紀錄
sha256sum "$INSTANCES"/*.env | tee "$WORK/instances.before"
test ! -e "$INSTANCES/popdex-btc.env" && echo NO-POPDEX-YET
ls -d /etc/alloy/trading.alloy /etc/skyeye-trading/config.env /etc/systemd/system/skyeye-trading-probe.service \
  /etc/systemd/system/skyeye-trading-probe.timer /etc/systemd/system/timers.target.wants/skyeye-trading-probe.timer \
  "$TEXTFILE/tnauqquant.prom" 2>/dev/null                 # 必須沒有輸出（舊 singleton）
ls /etc/systemd/system | grep -E '^skyeye-trading-probe@.+\.(service|timer)$'   # 必須沒有輸出
```

**Probe timer 狀態（之後的還原一律以這個檔案為準，不憑記憶）：**

```bash
record_timer_states | tee "$WORK/timers.before"
printf 'lighter-mainnet-btc-canary enabled active\nlighter-robinhood-btc-canary enabled active\n' \
  | cmp - "$WORK/timers.before" && echo TIMERS-AS-EXPECTED
```

沒有印出 `TIMERS-AS-EXPECTED` 就 STOP：本文件只涵蓋兩個 timer 都 enabled + active 的狀態。

**Instance env：**

```bash
grep -HE '^(TQ_SERVER_ID|TQ_STRATEGY|TQ_INSTANCE_ID|TQ_POC_RUN_EXPECTED|TQ_STRATEGY_DISABLED|TQ_TEXTFILE_DIR|TQ_TEXTFILE_NAME|TQ_EXECUTOR_MAP)=' \
  "$INSTANCES"/*.env | tee "$WORK/instance-keys.before"
for s in lighter-mainnet-btc-canary lighter-robinhood-btc-canary; do
  install -m 600 "$INSTANCES/$s.env" "$WORK/$s.env"
done
install -m 600 "$STAGE/agents/alloy/trading/deployment-linux-popdex.env.example" "$WORK/popdex-btc.env"
```

兩個 env 都必須是 `TQ_SERVER_ID=trading01` 與 `TQ_TEXTFILE_DIR=/var/lib/skyeye-trading/textfile`，否則 STOP。記下 Mainnet 是否已有 `TQ_STRATEGY_DISABLED`（預期沒有）。`popdex-btc.env` 直接使用 example，不修改。

**PopDEX 路徑與 tnauqquant 狀態（只讀）：**

```bash
ls -ld /home/ubuntu/tnauqquant /home/ubuntu/tnauqquant/config/popdex_btc_config.yaml /home/ubuntu/tnauqquant/logs/live-runs
test -x /home/ubuntu/tnauqquant/bin/popdex-btc/quant && echo EXEC-OK
grep -nE '^[[:space:]]*instance_id:' /home/ubuntu/tnauqquant/config/popdex_btc_config.yaml   # 值為 popdex-btc
ls -1t /home/ubuntu/tnauqquant/logs/live-runs/*popdex_btc_config.raw.log | head -n 3
ls -l /home/ubuntu/tnauqquant/run-state/popdex-btc/ 2>&1 | tee "$WORK/popdex-run-state.before"
systemctl is-active tnauqquant@popdex-btc.service | tee "$WORK/popdex-lane.before"
textfile_values | tee "$WORK/textfile.before"
tnauqquant_state | tee "$WORK/tnauqquant.before"
```

- 路徑缺少、`EXEC-OK` 沒印出、`instance_id` 不是 `popdex-btc`：STOP，交給 tnauqquant manager。
- `textfile.before` 預期 Mainnet `run_expected 1`、`process_count 0`。PopDEX lane 是否在跑只記錄，不影響後續。

**Render（只寫 `$WORK`）：**

```bash
for s in popdex-btc lighter-robinhood-btc-canary lighter-mainnet-btc-canary; do
  "$SETUP" --render-only "$WORK/render-$s" --env-file "$WORK/$s.env" </dev/null || echo "STOP: render $s"
done
grep -c 'strategy *= *"popdex-btc"' "$WORK/render-popdex-btc/trading-popdex-btc.alloy"   # ≥ 1
for s in lighter-robinhood-btc-canary lighter-mainnet-btc-canary; do
  diff -u "/etc/alloy/trading-$s.alloy" "$WORK/render-$s/trading-$s.alloy" >"$WORK/fragment-$s.diff"
  grep -E '^[-+][[:space:]]*(__path__|product|environment|server_id|strategy)[[:space:]]*=' "$WORK/fragment-$s.diff"   # 必須沒有輸出
done
```

每次 render 印出 `Rendered Linux trading artifacts under …`。任何 `STOP: render` 就 STOP：`add` 會以同樣原因拒絕。`fragment-*.diff` 是 Phase 3 會套用的 scrub 更新；target labels 與路徑不能變（不變時 Alloy 保留 log positions，不會重讀）。

### monitoring-prod（ubuntu）

```bash
M7=<同上>; MERGE=<完整 SHA>
CUT="$HOME/popdex-rollout-$M7"; install -d -m 700 "$CUT"
cd /home/ubuntu/SkyEye
q() { curl -fsS --get http://127.0.0.1:9090/api/v1/query --data-urlencode "query=$1" | jq -c '.data.result'; }
lq() { curl -fsS --get http://127.0.0.1:3100/loki/api/v1/query --data-urlencode "query=$1" | jq -c '.data.result'; }
targets() { q 'trading_target_info' | jq -S '[.[].metric | del(.__name__)] | sort'; }
probe_ages() { q 'time() - tnauqquant_probe_timestamp_seconds{product="tnauqquant",server_id="trading01"}' \
  | jq -c '[.[] | {strategy: .metric.strategy, age: (.value[1] | tonumber | floor)}] | sort_by(.strategy)'; }
zen_up() { q 'up{product="zenincome"}' | jq -S '[.[] | {metric: (.metric | del(.__name__)), up: .value[1]}] | sort'; }
zen_age() { q 'max(time() - timestamp(up{product="zenincome"}))'; }
zen_logs15() { lq 'sum(count_over_time({product="zenincome"}[15m]))' | jq -r '.[0].value[1] // "0"'; }
zen_alerts() {
  { q 'ALERTS{product="zenincome",alertstate="firing"}' | jq -c '[.[].metric.alertname]'
    curl -fsS --get http://127.0.0.1:9093/api/v2/alerts --data-urlencode 'filter=product="zenincome"' \
      --data-urlencode 'silenced=false' | jq -c '[.[].labels.alertname]'; } | jq -s -c 'add | unique'; }
t01_alerts() { q 'ALERTS{product="tnauqquant",server_id="trading01",alertstate="firing"}' \
  | jq -c '[.[].metric | {alertname, strategy}] | sort'; }

git rev-parse HEAD | tee "$CUT/old-head"
scripts/central-deploy --status 2>&1 | tee "$CUT/central-status-pre.log"   # Prometheus last reload successful: 1
targets | tee "$CUT/pre-targets.json"
jq -e 'map(select(.strategy == "popdex-btc")) | length == 0' "$CUT/pre-targets.json"   # true
probe_ages | tee "$CUT/probe-ages.pre.json"          # Mainnet 與 Robinhood 兩筆，age < 60
zen_up | tee "$CUT/zenincome-up.pre.json"
zen_age | tee "$CUT/zenincome-age.pre.json"          # 有值時 < 120
zen_logs15 | tee "$CUT/zenincome-logs15.pre"
zen_alerts | tee "$CUT/zenincome-alerts.pre.json"
t01_alerts | tee "$CUT/t01-alerts.pre.json"          # 預期含 Mainnet 的 TradingProcessDown
```

斷線重連時，重新設定 `M7`、`MERGE`、`CUT`，`cd /home/ubuntu/SkyEye`，再貼上上面的函式定義。

- `pre-targets.json` 已有 `popdex-btc`（`jq` 印出 `false`）：中央已提前部署，記下時間（見執行前必讀），照常繼續。
- `probe_ages` 不是兩筆 age < 60：既有 probe 已有問題，STOP，先查明。
- `zenincome-up.pre.json` 是 `[]` **而且** `zenincome-logs15.pre` 是 `0`：Phase 2 後無法驗證 ZenIncome，STOP。
- `zenincome-alerts.pre.json` 非空：ZenIncome 已在告警，STOP，先處理事件。

Phase 1 全部通過才進 Phase 2。

## Phase 2 — Alloy 升級 `[CHANGE Trading01]`

時間不在 UTC 18:15–19:30，Wan 聯絡得到。Trading01 root shell：

```bash
date +%s >"$WORK/phase2-epoch"; date -u +%FT%TZ | tee "$WORK/phase2-start"
"$UPGRADE" --to "$ALLOY_TO" 2>&1 | tee "$WORK/upgrade.log"; echo "rc=${PIPESTATUS[0]}" | tee -a "$WORK/upgrade.log"
UPGRADE_RECORD=$(sed -n 's/^Record: //p' "$WORK/upgrade.log" | tail -n 1); declare -p UPGRADE_RECORD >>"$WORK/vars"
```

成功時的輸出（中間夾有 `apt-get download` 與 dpkg 的 `Unpacking alloy (1.16.3-1) over (1.16.0-1)`、`Setting up alloy (1.16.3-1)`）：

```
Downloading alloy 1.16.3-1 and, for a rollback, alloy 1.16.0-1
Moving alloy 1.16.0-1 -> 1.16.3-1; Alloy active=1 enabled=1 held=<0|1>; restart: yes, interrupts every Alloy pipeline once; ready check: http://127.0.0.1:12345/-/ready
Restarting Alloy; every Alloy pipeline pauses until it is ready
Done: alloy 1.16.3-1 is installed and held; Alloy is as it was (active=1).
Record: /var/lib/skyeye-alloy/upgrade/<UTC>-<pid>
Roll back with: sudo /home/ubuntu/skyeye-staging/popdex-<M7>/agents/alloy/upgrade-linux.sh --rollback /var/lib/skyeye-alloy/upgrade/<UTC>-<pid>
rc=0
```

`RESTART_ON_UPGRADE=true` 時，`Restarting Alloy…` 那一行會換成 `The package scripts already restarted Alloy (MainPID A -> B); not restarting it again`，也是成功。

依 `rc` 判斷：

- **`rc=0`**：繼續下面的檢查。
- **`rc=1` 且有 `refused, nothing was changed`**：沒有任何變更。STOP，依中止規則處理。
- **`rc=1` 且有 `rolling back to alloy 1.16.0-1` 與 `rolled back; alloy 1.16.0-1 is installed and Alloy is as it was. Record: …`**：腳本已自動還原。仍跑下面的 ZenIncome 中央檢查確認恢復，然後 STOP，依中止規則處理。
- **`rc=3`，輸出有 `CRITICAL: rollback_incomplete`**：還原沒有完成，Alloy 與 ZenIncome 可能停擺。**立刻停手，通知 Wan 與 manager**，依 [R2-CRITICAL](#r2-critical--upgrade-linuxsh-exit-3) 處理。不進 Phase 3。

Trading01 檢查（`rc=0` 後立即）：

```bash
alloy --version | head -n 1                              # alloy, version v1.16.3 …（ALLOY_TO）
dpkg-query -W -f='${Status} ${Version}\n' alloy          # hold ok installed 1.16.3-1
apt-mark showhold alloy                                  # alloy
systemctl is-active alloy                                # active
curl -fsS "$READY_URL"; echo                             # 成功
curl -fsS "$METRICS_URL" | grep -E '^alloy_component_controller_running_components\{' | sort >"$WORK/components.after-upgrade"
diff "$WORK/components.before" "$WORK/components.after-upgrade" && echo COMPONENTS-SAME
sha256sum -c --quiet "$WORK/alloy-files.before" && echo ALLOY-FILES-SAME
journalctl -u alloy --since "@$(cat "$WORK/phase2-epoch")" --no-pager | grep -E 'level=(error|warn)' | tail -n 20 | tee "$WORK/alloy-journal.after-upgrade"
```

`COMPONENTS-SAME` 與 `ALLOY-FILES-SAME` 都必須印出。journal 的 warn／error 只做紀錄，判斷以中央檢查為準。

monitoring-prod 檢查（Trading01 `Done:` 之後 ≥ 6 分鐘）：

```bash
probe_ages                                               # 兩筆，age < 60
zen_up | tee "$CUT/zenincome-up.post-upgrade.json"
diff "$CUT/zenincome-up.pre.json" "$CUT/zenincome-up.post-upgrade.json" && echo ZEN-UP-SAME
zen_age                                                  # 有值時 < 120
zen_alerts                                               # 必須是 []
```

`Done:` 之後 ≥ 16 分鐘，且 `zenincome-logs15.pre` 大於 0 時：

```bash
zen_logs15                                               # > 0
```

也在 Grafana 打開「ZenIncome — 日誌總覽」（uid `zenincome-logs-overview`），確認重啟之後有新的 log。

**Phase 2 的任何一項檢查失敗**（版本、hold、ready、`COMPONENTS-SAME`、`ALLOY-FILES-SAME`、`probe_ages`、`ZEN-UP-SAME`、`zen_age`、`zen_alerts`、`zen_logs15`）：**STOP，先執行 [R2](#r2--alloy-退回phase-2)，再依中止規則處理。** ZenIncome 檢查失敗時不得進 Phase 3。

## Phase 3 — 共用 probe 更新與加入 `popdex-btc` `[CHANGE Trading01]`

`setup-linux.sh` 只在所有 `skyeye-trading-probe@*` 都停止且 disabled 時才改寫共用檔案，所以先停兩個既有 timer，完成後依 `$WORK/timers.before` 恢復。

```bash
date +%s >"$WORK/phase3-epoch"; date -u +%FT%TZ | tee "$WORK/phase3-start"
: >"$WORK/records.list"
while read -r s _ _ <&3; do
  systemctl disable --now "skyeye-trading-probe@$s.timer"
  systemctl stop "skyeye-trading-probe@$s.service"
done 3<"$WORK/timers.before"
record_timer_states                                      # 兩行都是 disabled inactive
```

**加入 `popdex-btc`：**

```bash
"$SETUP" add --env-file "$WORK/popdex-btc.env" </dev/null 2>&1 | tee "$WORK/add-popdex-btc.out"; rc=${PIPESTATUS[0]}; echo "rc=$rc"
[ "$rc" = 0 ] && sed -n 's/^Rollback record: //p' "$WORK/add-popdex-btc.out" | tail -n 1 >>"$WORK/records.list"
```

預期：

```
Alloy action: reload. Re-evaluates these fragments; unchanged pipelines keep running: …
Validating the combined Alloy configuration before installation
Installed Linux trading monitoring fragment: /etc/alloy/trading-popdex-btc.alloy
Rollback record: /etc/skyeye-trading/install-backup/<UTC>-popdex-btc-<pid>
Probe metrics: /var/lib/skyeye-trading/textfile/tnauqquant-popdex-btc.prom
Alloy reload done; probe timer enabled: skyeye-trading-probe@popdex-btc.timer
Next: add the central inventory row (…), merge, then run scripts/central-deploy on monitoring-prod
rc=0
```

最後一行 `Next:` 不用理會：inventory row 已在 `MERGE`，中央部署是 Phase 5。輸出不能有 `Alloy action: restart`。`rc` 不是 0：執行 [R3a](#r3a--popdex-btc-add-失敗)，然後 STOP。

**重新 add 兩個既有 strategy 並恢復 timer：**

```bash
while read -r s e a <&3; do
  [ "$e $a" = "enabled active" ] || { echo "STOP: $s was $e $a"; break; }
  "$SETUP" add --env-file "$WORK/$s.env" --enable-probe </dev/null 2>&1 | tee "$WORK/add-$s.out"; rc=${PIPESTATUS[0]}; echo "rc=$rc"
  [ "$rc" = 0 ] || { echo "STOP: add $s failed"; break; }
  sed -n 's/^Rollback record: //p' "$WORK/add-$s.out" | tail -n 1 >>"$WORK/records.list"
done 3<"$WORK/timers.before"
date +%s >"$WORK/siblings-back-epoch"
echo "probe gap: $(( $(cat "$WORK/siblings-back-epoch") - $(cat "$WORK/phase3-epoch") )) s" | tee "$WORK/probe-gap"
cat "$WORK/records.list"                                 # 三行 record 路徑
```

每個 strategy 預期 `Alloy action: reload…`、`Installed Linux trading monitoring fragment: /etc/alloy/trading-<s>.alloy`、`Rollback record: …`、`Probe metrics: …`、`Alloy reload done; probe timer enabled: skyeye-trading-probe@<s>.timer`、`rc=0`。印出任何 `STOP:`：失敗的那次 `add` 已自行還原它自己的檔案，接著執行 [R3](#r3--phase-34-完整退回)，然後 STOP。

`probe gap` 超過 180 秒時，兩個既有 strategy 會短暫出現 shadow `TradingTelemetryMissing`，記入執行紀錄即可。

**Trading01 檢查：**

```bash
record_timer_states | tee "$WORK/timers.after-phase3"
# 預期三行：lighter-mainnet-btc-canary enabled active / lighter-robinhood-btc-canary enabled active / popdex-btc enabled active
cmp "$STAGE/agents/alloy/trading/probe.sh" /usr/local/libexec/skyeye-trading/probe.sh && echo PROBE-CURRENT
grep -E ' /etc/(default/alloy|alloy/config\.alloy|alloy/trading\.alloy\.pre-pr34\..*)$' "$WORK/alloy-files.before" \
  | sha256sum -c -                                       # 每行 OK：ZenIncome base、/etc/default/alloy 與舊備份都沒變
ls -l "$TEXTFILE"                                         # 三個 tnauqquant-<strategy>.prom
sleep 30; textfile_values | tee "$WORK/textfile.after-phase3"
systemctl is-active alloy; curl -fsS "$READY_URL"; echo
```

- 三個 textfile 的 `tnauqquant_probe_timestamp_seconds` 都必須在 `date +%s` 的 60 秒內。不符（某個 probe 沒有產出新資料）：執行 R3，然後 STOP。
- Mainnet 此時仍是 `run_expected 1`。Robinhood 的 `run_expected`、`process_count`、binding 值和 `textfile.before` 不同時，**不 rollback**：新版 probe 帶有 11-05 的修正，差異可能是舊版沒報出來的真實狀態。記錄並交給 tnauqquant manager。
- PopDEX lane 在跑時，`popdex-btc` 預期 `runtime_contract_available 1`、`process_count 1`。

**monitoring-prod 檢查（Phase 3 完成後 2 分鐘內）：**

```bash
probe_ages | tee "$CUT/probe-ages.post-phase3.json"   # 三筆（含 popdex-btc），age 都 < 60
zen_up | diff "$CUT/zenincome-up.pre.json" - && echo ZEN-UP-SAME
zen_alerts                                             # []
q 'tnauqquant_current_run_exchange_volume_usd{server_id="trading01",strategy="popdex-btc"}' | jq -c '[.[].metric.exchange] | unique'
```

- `probe_ages` 三筆都 < 60 就是 **D5 的條件：`popdex-btc` 已在 remote-write，Phase 5 才可以執行。** 2 分鐘內做不到：執行 R3，然後 STOP。
- `ZEN-UP-SAME` 沒印出或 `zen_alerts` 非空：執行 R3，然後 STOP。
- exchange 預期 `["popdex"]`。lane 還沒有 P&L snapshot 時是 `[]`，Phase 6 再看。

Alloy 會從頭讀取 24 小時內更新過的 PopDEX raw log（`tail_from_end = false`、`ignore_older_than = "24h"`）。若 journal 出現 Loki 400 `entry too far behind`，那是早於 Loki 168h 拒收時窗的行，不算失敗。

## Phase 4 — Mainnet 標成停用 `[CHANGE Trading01]`

Mainnet lane 自 2026-11-07 起刻意停用。只改 SkyEye 的 probe env，不碰 tnauqquant。不加 `--enable-probe`，timer 維持 Phase 3 恢復後的狀態。

```bash
install -m 600 "$INSTANCES/lighter-mainnet-btc-canary.env" "$WORK/lighter-mainnet-btc-canary.installed.env"
grep -v '^TQ_STRATEGY_DISABLED=' "$WORK/lighter-mainnet-btc-canary.installed.env" >"$WORK/lighter-mainnet-btc-canary.phase4.env"
printf 'TQ_STRATEGY_DISABLED=1\n' >>"$WORK/lighter-mainnet-btc-canary.phase4.env"
chmod 600 "$WORK/lighter-mainnet-btc-canary.phase4.env"
diff "$WORK/lighter-mainnet-btc-canary.installed.env" "$WORK/lighter-mainnet-btc-canary.phase4.env"   # 只多一行 TQ_STRATEGY_DISABLED=1
"$SETUP" add --env-file "$WORK/lighter-mainnet-btc-canary.phase4.env" </dev/null 2>&1 | tee "$WORK/add-lighter-mainnet-btc-canary.phase4.out"; rc=${PIPESTATUS[0]}; echo "rc=$rc"
[ "$rc" = 0 ] && sed -n 's/^Rollback record: //p' "$WORK/add-lighter-mainnet-btc-canary.phase4.out" | tail -n 1 >>"$WORK/records.list"
```

預期：

```
Alloy action: reload. Re-evaluates these fragments; unchanged pipelines keep running: …
Validating the combined Alloy configuration before installation
Updating installed instance in place; pausing its probe timer: skyeye-trading-probe@lighter-mainnet-btc-canary.timer
Installed Linux trading monitoring fragment: /etc/alloy/trading-lighter-mainnet-btc-canary.alloy
Rollback record: /etc/skyeye-trading/install-backup/<UTC>-lighter-mainnet-btc-canary-<pid>
Probe metrics: /var/lib/skyeye-trading/textfile/tnauqquant-lighter-mainnet-btc-canary.prom
Alloy reload done; probe timer enabled: skyeye-trading-probe@lighter-mainnet-btc-canary.timer
Next: …
rc=0
```

Phase 1 時 Mainnet env 已有 `TQ_STRATEGY_DISABLED=1` 的話，預期改為 `Already installed and running: lighter-mainnet-btc-canary (no changes; Alloy untouched)`，也是成功（不會新增 record）。

`rc` 不是 0：`add` 已自行還原 env 與 timer 狀態。確認 `cmp "$INSTANCES/lighter-mainnet-btc-canary.env" "$WORK/lighter-mainnet-btc-canary.installed.env"` 相同、`record_timer_states` 等於 `timers.after-phase3`，記下失敗訊息，**跳過 Phase 4 繼續 Phase 5**（Mainnet 維持原本的 shadow ProcessDown）。

檢查：

```bash
record_timer_states | cmp - "$WORK/timers.after-phase3" && echo TIMERS-UNCHANGED
sleep 30; textfile_values | grep '^tnauqquant-lighter-mainnet-btc-canary '   # run_expected 0、process_count 0
```

monitoring-prod，Phase 4 完成後 ≥ 3 分鐘：

```bash
t01_alerts | tee "$CUT/t01-alerts.post-phase4.json"   # 不再有 Mainnet 的 TradingProcessDown
```

- Mainnet 出現 `TradingUnexpectedProcess`：Mainnet 程序正在跑。**不要碰它**，立刻通知 Wan 與 tnauqquant manager。
- Mainnet 只剩 `TradingRunBindingInvalid`：已知殘留，記錄。
- 5 分鐘後仍有 Mainnet 的 `TradingProcessDown`：textfile 已是 `run_expected 0` 就再等 2 分鐘；textfile 仍是 `1` 就執行 [R4](#r4--只撤銷-phase-4)，記錄，繼續 Phase 5。

## Phase 5 — 中央 inventory `[CHANGE monitoring-prod]`

前提，全部成立才執行：

1. Phase 3 的 monitoring-prod 檢查已通過（`popdex-btc` 的 `probe_ages` < 60）。
2. 現在不在 UTC 18:30–19:30（`date -u +%H:%M`）。
3. monitoring-prod 上沒有其他 operator。

```bash
cd /home/ubuntu/SkyEye
date -u +%H:%M
probe_ages                                               # popdex-btc 仍 < 60
scripts/central-deploy --dry-run --expect "${MERGE:?set MERGE first}" 2>&1 | tee "$CUT/central-deploy-dry-run.log"
```

dry run 先印出 `Deploying <old> -> <MERGE 前 12 碼>` 與將部署的 commits，最後一行必須是 `Dry run: validation passed; checkout left at … and nothing reloaded (would reload: Prometheus=1 …)`。

- `--expect names …, but origin/master is …; nothing moved`：master 在 merge 之後又多了 commit。STOP Phase 5，把 `git log --oneline "$MERGE..origin/master"` 交給 manager。manager 審閱並同意它們一起上線後，把 `MERGE` 設為新的 `origin/master` 完整 SHA 重跑這個區塊。
- 其他拒絕（dirty tree、untracked 檔案、需要 container recreate、dashboard／Loki rule 驗證、Grafana token）：STOP Phase 5，不改用 `git pull`。Host 端維持 Phase 4 後的狀態（`popdex-btc` 有資料但不在 inventory，不會觸發告警），排除原因後在下一個時窗重跑 Phase 5。

dry run 通過後：

```bash
scripts/central-deploy --expect "$MERGE" 2>&1 | tee "$CUT/central-deploy.log"; echo "rc=${PIPESTATUS[0]}"
```

依 `central-deploy.log` 判斷：

- **`rc=0` 且最後一行是 `central-deploy: done; applied <12 碼 SHA>`**：成功，跑部署後檢查。
- **在 `Checkout fast-forwarded` 之前失敗**：中央沒有變更。STOP Phase 5，處理方式同 dry run 的其他拒絕。
- **在 `Checkout fast-forwarded` 之後失敗**（`Prometheus rejected the reload`、`did not confirm this reload`）：不要重啟 Prometheus，也不要照提示 `git reset --hard`。執行 [R5](#r5--中央-inventory-退回)。
- **訊息含 `is published but not loaded`**：Prometheus 已套用，Loki 或 Grafana 未確認載入。不 rollback，也不 `git reset --hard`。排除訊息指出的原因後重跑上面那一行直到 `rc=0`。訊息同時含 `if that is a UI edit` 時，依 [server_id cutover 文件 Step 4](trading-serverid-cutover-macmini-m2.md#step-4--部署中央-rulesmonitoring-prod) 的同名項目處理。

部署後檢查：

```bash
[ "$(git rev-parse HEAD)" = "$MERGE" ] && echo HEAD-IS-MERGE
scripts/central-deploy --status | tee "$CUT/central-status-post.log"   # Prometheus last reload successful: 1
sleep 70
jq -S '. + [{"environment":"production","notification_mode":"shadow","product":"tnauqquant","quote_currency":"USDT","server_id":"trading01","strategy":"popdex-btc"}] | unique' \
  "$CUT/pre-targets.json" >"$CUT/expected-targets.json"
targets | tee "$CUT/post-targets.json"
diff "$CUT/expected-targets.json" "$CUT/post-targets.json" && echo TARGETS-OK
q 'trading_target_info unless on (product, environment, server_id, strategy) (time() - trading_strategy_probe_timestamp_seconds < 180)'   # []
t01_alerts | tee "$CUT/t01-alerts.post-phase5.json"
```

- `HEAD-IS-MERGE` 沒印出：checkout 被移動過，停下，把 `git log --oneline "$MERGE..HEAD"` 交給 manager。
- `TARGETS-OK` 沒印出，或 `unless` 查詢不是 `[]`：執行 R5。
- `t01-alerts.post-phase5.json` 裡 `popdex-btc` 的告警：lane 沒在跑時的 `TradingProcessDown`／`TradingRuntimeContractMissing` 是預期的（見執行前必讀），記錄。其他 `popdex-btc` 告警交給 manager 判讀，不 rollback。

## Phase 6 — 最終核對與收尾 `[READ-ONLY]`

Phase 5 之後 ≥ 10 分鐘。monitoring-prod：

```bash
t01_alerts | tee "$CUT/t01-alerts.final.json"   # 沒有 Mainnet TradingProcessDown；Robinhood 與 Phase 1 相同
probe_ages                                       # 三筆 < 60
zen_up | diff "$CUT/zenincome-up.pre.json" - && echo ZEN-UP-SAME
zen_alerts                                       # []
q 'tnauqquant_current_run_exchange_volume_usd{server_id="trading01",strategy="popdex-btc"}' | jq -c '[.[].metric.exchange] | unique'   # ["popdex"]（lane 有 snapshot 後）
curl -fsS --get http://127.0.0.1:3100/loki/api/v1/series \
  --data-urlencode 'match[]={product="tnauqquant",server_id="trading01",strategy="popdex-btc"}' \
  --data-urlencode "start=$(( $(date +%s) - 86400 ))" \
  | jq -c '([.data[] | keys[]] | unique) - ["environment","level","product","run_id","server_id","strategy","service_name"]'   # []
lq 'sum(count_over_time({product="tnauqquant",server_id="trading01",strategy=~"popdex-btc|lighter-robinhood-btc-canary"} |~ `(?i)(order_?id|client_?action_?id|client_?id)=[^\[]` [10m]))'   # []
```

- Loki label 只能有那六個（Loki 自動加的 `service_name` 除外）。多出其他 label：交給 manager，屬於 scrub contract 問題。
- 最後一個查詢必須是 `[]`：Phase 3 之後進 Loki 的行沒有明文 order／client ID。非 `[]` 時交給 manager；Robinhood 在 Phase 3 之前進 Loki 的舊行不在 10 分鐘視窗內，不受影響，也不在這次刪除範圍。

Grafana：

- 「Trading · 策略總覽」（`https://grafana.wanbrain.com/d/trading-strategy-fleet`）出現 `popdex-btc` 一列，其他列不變。
- 「Trading · 策略詳情」（`https://grafana.wanbrain.com/d/trading-strategy-detail?var-server_id=trading01&var-strategy=popdex-btc`）的持倉與成交量 panel 以 `popdex` 為 exchange。
- 「ZenIncome — 日誌總覽」持續有新 log。

Trading01 root shell：

```bash
record_timer_states | cmp - "$WORK/timers.after-phase3" && echo TIMERS-FINAL
alloy --version | head -n 1; apt-mark showhold alloy
grep -E ' /etc/(alloy/config\.alloy|alloy/trading\.alloy\.pre-pr34\..*)$' "$WORK/alloy-files.before" | sha256sum -c -
tnauqquant_state | tee "$WORK/tnauqquant.after"
diff "$WORK/tnauqquant.before" "$WORK/tnauqquant.after" && echo TNAUQQUANT-SAME
date -u +%FT%TZ | tee "$WORK/phase6-end"
```

`TNAUQQUANT-SAME` 沒印出時，差異只可能來自 tnauqquant 自己的生命週期（例如 PopDEX 達到 `max_cycles` 後結束），因為本文件沒有任何命令作用於 `tnauqquant*` unit。把 `journalctl -u 'tnauqquant@*' --since "@$(cat "$WORK/phase2-epoch")" --no-pager | tail -n 50` 存到 `$WORK/tnauqquant-journal.txt`，交給 tnauqquant manager，不做 rollback。

收尾：

- 把執行紀錄（下表）與 shadow 排除時窗（`phase2-start` 到 `phase6-end`）寫進 `docs/work-log.md`。
- `$WORK`、`$STAGE` 保留 7 天供 rollback，之後 `rm -rf "$WORK" "$STAGE"`。`$UPGRADE_RECORD`（含兩個 deb，不含 conffile 複本）保留到下一次 Alloy 版本移動。`/home/ubuntu/skyeye-agent` 與較舊的 staging 目錄不動。
- 回報 tnauqquant manager：fleet dashboard 已列出 `popdex-btc`、Mainnet 預期已修正，以及 Robinhood 的值是否有變化。

## Rollback

| 失敗位置 | 動作 |
|---|---|
| Phase 1 | 沒有變更，依中止規則處理 |
| Phase 2 `rc=1` | 腳本已自動還原，確認 ZenIncome 後依中止規則處理 |
| Phase 2 `rc=0` 但檢查失敗 | R2，然後依中止規則處理 |
| Phase 2 `rc=3` | R2-CRITICAL |
| Phase 3 `popdex-btc` add 失敗 | R3a，然後依中止規則處理 |
| Phase 3 其他失敗 | R3，然後依中止規則處理 |
| Phase 4 | `add` 自行還原；要撤銷已完成的 Phase 4 用 R4 |
| Phase 5 fast-forward 之後失敗，或部署後檢查失敗 | R5 |

### R2 — Alloy 退回（Phase 2）

只在 Phase 3 開始之前使用。Phase 3 開始之後要退回 Alloy，先做完 R3（還原舊 fragment），再做 R2。

```bash
"$UPGRADE" --rollback "$UPGRADE_RECORD" 2>&1 | tee "$WORK/upgrade-rollback.log"; echo "rc=${PIPESTATUS[0]}"
```

預期 `Moving alloy 1.16.3-1 -> 1.16.0-1; …`、`Restarting Alloy; …`（或 package scripts 已 restart 的那一行）、`Done: alloy 1.16.0-1 is installed again (held=<Phase 1 的 hold 狀態>); Alloy is as it was (active=1).`、`rc=0`。接著重跑 Phase 2 的 Trading01 檢查（版本應為 v1.16.0）與 monitoring-prod 的 ZenIncome 檢查。`rc=3` 時改走 R2-CRITICAL。

### R2-CRITICAL — `upgrade-linux.sh` exit 3

停手，通知 Wan 與 manager。輸出會指出 `CRITICAL: the config files from before this run are in <R>/conffiles; the packages are in <R>/debs.`。在 Wan 同意下，以 root 執行：

```bash
R=<CRITICAL 訊息中的 record 目錄>
dpkg-query -W alloy; alloy --version | head -n 1; systemctl status alloy --no-pager | head -n 5
grep -E '^(from_deb|was_held|was_active)=' "$R/upgrade.meta"
DEBIAN_FRONTEND=noninteractive dpkg --force-confold -i "$R"/debs/alloy_1.16.0-1_*.deb
cmp "$R/conffiles/default-alloy" /etc/default/alloy && diff -r "$R/conffiles/etc-alloy" /etc/alloy && echo CONFIG-MATCHES-RECORD
```

`CONFIG-MATCHES-RECORD` 沒印出時，把現況移開再還原：`mv /etc/default/alloy "$R/manual-default-alloy"; mv /etc/alloy "$R/manual-etc-alloy"; cp -a "$R/conffiles/default-alloy" /etc/default/alloy; cp -a "$R/conffiles/etc-alloy" /etc/alloy`。然後：

```bash
systemctl daemon-reload
apt-mark hold alloy        # upgrade.meta 的 was_held=1 時；was_held=0 時改用 apt-mark unhold alloy
systemctl restart alloy
curl -fsS "$READY_URL"; echo
```

再跑 Phase 2 的 ZenIncome 中央檢查。`$R/conffiles` 含 Cloudflare 憑證，恢復後 `rm -rf "$R/conffiles"`。

### R3a — `popdex-btc` add 失敗

`add` 失敗時會印出 `installation failed; restoring recorded files` 並自行還原；在任何變更之前就拒絕的情況（例如 `installed Alloy … is not tested`、`shared probe artifacts changed while …`）則沒有改任何東西。

```bash
grep -F 'Remaining recovery action: sudo systemctl reload alloy' "$WORK/add-popdex-btc.out" && systemctl reload alloy
while read -r s e a <&3; do
  [ "$e $a" = "enabled active" ] && systemctl enable --now "skyeye-trading-probe@$s.timer"
done 3<"$WORK/timers.before"
record_timer_states | diff "$WORK/timers.before" - && echo TIMERS-RESTORED
sha256sum -c --quiet "$WORK/shared-files.before" && echo SHARED-RESTORED
test ! -e "$INSTANCES/popdex-btc.env" && echo NO-POPDEX
```

三個 `…RESTORED`／`NO-POPDEX` 都要印出。沒有的話執行 R3。

### R3 — Phase 3/4 完整退回

把 Trading01 還原成 Phase 2 結束時的狀態：舊的共用 probe、舊的 fragment 與 env、timer 依 `$WORK/timers.before`。步驟寫在 Phase 1 的 `helpers.sh`（`r3_rollback`），`tests/trading/test-trading01-popdex-rollout.sh` 執行的就是同一段程式：

1. `popdex-btc` 有安裝時先 `retire`。exit code 不是 0 就停，R3 沒有改任何其他東西。
2. `stop_all_probes`：停止並 disable **每一個** templated probe（已安裝的 env、`timers.before` 列出的、`popdex-btc`），再逐一確認 timer disabled + inactive、service inactive，也沒有殘留的 wants link。有任何一個做不到就停，共用檔案一個都沒還原。
3. 確認 `records.list` 的每個 record 都完整，再由新到舊還原檔案。
4. `daemon-reload`、`alloy validate` + `reload`，依 `timers.before` 恢復 timer。

```bash
r3_rollback 2>&1 | tee "$WORK/r3.log"; echo "rc=${PIPESTATUS[0]}"
```

成功時依序印出 retire 的輸出（`popdex-btc` 有安裝時）、`PROBES-STOPPED`、每個 record 一行 `restored /etc/skyeye-trading/install-backup/…`、`ALLOY-RELOADED`、`TIMERS-ENABLED`、`rc=0`。retire 預期 `Validating the Alloy configuration without trading-popdex-btc.alloy`、`Retired Linux trading monitoring instance: popdex-btc`、`Rollback record: /etc/skyeye-trading/retired/popdex-btc-<UTC>`，`popdex-btc` 的 env、fragment 與 textfile 移到該目錄。

`rc=0` 之後核對：

```bash
record_timer_states | diff "$WORK/timers.before" - && echo TIMERS-RESTORED
sha256sum -c --quiet "$WORK/shared-files.before" && echo SHARED-RESTORED
sha256sum -c --quiet "$WORK/instances.before" && echo INSTANCES-RESTORED
sha256sum -c --quiet "$WORK/alloy-files.before" && echo ALLOY-FILES-RESTORED
test ! -e /etc/alloy/trading-popdex-btc.alloy && echo NO-POPDEX-FRAGMENT
```

五行都必須印出，否則停手，把 `$WORK` 交給 manager。

`rc` 不是 0 時，`r3.log` 最後一行 `STOP:` 說明停在哪裡。停手，執行 `record_timer_states | tee "$WORK/timers.r3-stop"`，把 `$WORK` 交給 manager：

- `STOP: retire popdex-btc exited …`：Trading01 維持 Phase 3/4 完成後的狀態，三個 probe 照常執行。
- `STOP: a templated probe is still enabled or active …`（前面的 `still enabled or active: …` 指出是哪一個）或 `STOP: incomplete record …`：**共用檔案一個都沒還原。** `timers.r3-stop` 顯示哪些 probe 已經停下，停下的 probe 會出現 shadow `TradingTelemetryMissing`。排除原因並經 manager 同意後，從頭重跑上面的 `r3_rollback` 區塊；到這一步為止的動作重跑是安全的（`popdex-btc` 已 retire 時會跳過）。
- 其他 `STOP:`（檔案還原、`daemon-reload`、Alloy reload 或 timer 恢復失敗）：檔案已部分或全部還原，**不要重跑**，等 manager 判斷。

monitoring-prod：`probe_ages` 回到兩筆 < 60，`zen_up | diff "$CUT/zenincome-up.pre.json" -` 相同。中央已經部署 `popdex-btc` row 時（Phase 5 之後才 R3），先做 R5 再做 R3。

### R4 — 只撤銷 Phase 4

```bash
"$SETUP" add --env-file "$WORK/lighter-mainnet-btc-canary.installed.env" </dev/null 2>&1 | tee "$WORK/r4-add.out"; echo "rc=${PIPESTATUS[0]}"
record_timer_states | cmp - "$WORK/timers.after-phase3" && echo TIMERS-UNCHANGED
sleep 30; textfile_values | grep '^tnauqquant-lighter-mainnet-btc-canary '   # run_expected 回到 1
```

Mainnet 的 shadow `TradingProcessDown` 會回來。Wan 日後重新啟用 Mainnet 時，也是用這個方式把 env 改回沒有 `TQ_STRATEGY_DISABLED=1`（或設成 `0`），在那之前它會顯示 shadow `TradingUnexpectedProcess`。

### R5 — 中央 inventory 退回

monitoring-prod：

```bash
cd /home/ubuntu/SkyEye
git checkout "$(cat "$CUT/old-head")" -- prometheus/rules/trading-targets.yml
sudo docker run --rm --entrypoint promtool -v "$PWD/prometheus:/etc/prometheus:ro" \
  prom/prometheus:v2.54.1 check config /etc/prometheus/prometheus.yml \
  && curl -fsS -X POST http://127.0.0.1:9090/-/reload && echo RELOADED
sleep 70
targets | diff "$CUT/pre-targets.json" - && echo ROLLBACK-OK
```

- 不用 `scripts/central-deploy`：它只能部署 `origin/master` 最新 commit，那仍含 `popdex-btc`。也不用它提示的 `git reset --hard`：checkout 會落後 master，下一次部署會把 row 帶回來。單檔還原後 checkout 是 dirty，`central-deploy` 會拒絕部署，直到下一步完成。
- 接著由 manager 用 `scripts/trading-target remove --server trading01 --strategy popdex-btc` 開 PR 並 merge，然後在 monitoring-prod 執行 `git checkout -- prometheus/rules/trading-targets.yml && scripts/central-deploy`（同樣避開 UTC 18:30–19:30）。
- Host 端不必跟著退：沒有 inventory row 時 `popdex-btc` 的 raw series 不會觸發告警。要完全移除時，在 remove PR 部署之後執行 `"$SETUP" retire --strategy popdex-btc`（README 的 Remove 順序：先中央、後 host）。

## 執行紀錄

| 項目 | 時間（UTC） | 結果／record |
|---|---|---|
| Phase 0 staging | | `MERGE`、`TAR_SHA`、`PROBE_SHA`、`STAGE` |
| Phase 1 前置檢查 | | `WORK`、`CUT`、`ALLOY_TO`、Mainnet／PopDEX lane 狀態 |
| Phase 2 Alloy 升級 | | `UPGRADE_RECORD`、ZenIncome 檢查結果 |
| Phase 3 probe 停止 → 恢復 | | `probe gap` 秒數、`records.list` 三行 |
| Phase 4 Mainnet | | record、`ProcessDown` 消失時間 |
| Phase 5 central-deploy | | applied SHA、`TARGETS-OK`、`HEAD-IS-MERGE` |
| Phase 6 最終核對 | | `TNAUQQUANT-SAME`、Grafana 畫面 |

Shadow／canary 證據要排除：`trading01` 的 `phase2-start` – `phase6-end`。
