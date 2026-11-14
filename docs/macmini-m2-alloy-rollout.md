# Mac mini（`macmini-m2`）rollout：Alloy 版本鎖定與重跑 `setup-macos.sh`

> **來源：** 2026-11-14 Wan 核准所有主機升級 Alloy（D28 A），硬性規則是只改 SkyEye 監控，絕不碰 Mac mini 上的交易程式。SkyEye task `SKYEYE-ALLOY-MACMINI-20261114`，manager PLAN_APPROVED（D1 A：已是 1.18.1 就不移動版本，只 `brew pin`；D4 rehearsal 測試；D5 預設由 operator agent 經 SSH 執行，先過 session gate）。
>
> **本文件是 operator 程序，repo 變更 merge 後不會自動生效。** `tests/trading/test-macmini-alloy-rollout.sh` 在假的 Mac mini 上演練這份文件：直接執行兩份 `helpers.sh` 的原文，包括 session gate、時間檢查、render 比對、Phase 3 的 `setup-macos.sh`、R3（成功之後退回、`rc=3` 之後恢復，以及拒絕執行的情況）、tnauqquant census 前後比對，還有 `log_evidence`／`loki_accept`。
>
> **狀態：** 尚未執行。

## 這次會改什麼

| Phase | 標記 | 內容 |
|---|---|---|
| 0 | `[CHANGE Mac mini]`（只新增 staging 目錄） | 把 `MERGE` 的 `agents/alloy` 複製到 Mac mini |
| 1 | `[READ-ONLY]`，另建 `$WORK`／`$CUT` 紀錄目錄 | session gate、Alloy 版本、檔案 hash、render 比對、新 probe 試跑、tnauqquant census、中央基準 |
| 2 | `[CHANGE Mac mini]` | `brew pin grafana/grafana/alloy`（不移動版本、不碰 service） |
| 3 | `[CHANGE Mac mini]` | 重跑 `setup-macos.sh`：換上新的 probe、P&L history 與 `config.alloy`，**Alloy restart 一次** |
| 4 | `[READ-ONLY]` | 中央 metrics、告警與 Loki 驗收 |
| 5 | `[READ-ONLY]` | 最終核對、tnauqquant census 必須完全相同、紀錄 |

Mac mini 上會變動的只有：

- Homebrew 的 pin 紀錄（`$(brew --prefix)/var/homebrew/pinned/alloy`）。
- `$(brew --prefix)/etc/alloy/config.alloy`。
- `$(brew --prefix)/libexec/skyeye-trading/{probe.sh,pnl-history.sh}`。
- `~/Library/LaunchAgents/com.wanbrain.skyeye-trading-{probe,pnl-history}.plist`，只有內容不同時才換。
- `$(brew --prefix)/var/skyeye-trading/`：installer 的 lock、`installed-env.sha256` 與 rollback record。
- probe 與 history 的輸出。

`config.env`、`extra-args.txt` 與 Alloy 的版本都不變，每個 Phase 都會核對 hash 與版本。

`setup-macos.sh` 在這臺 Mac mini 上沒有 `installed-env.sha256`（這個紀錄 2026-11-07 才加進 installer，之後沒有在這臺重跑過），所以第一次執行一定是 `Alloy action: restart`，Alloy 會重啟一次。新的 Trading log 遮蔽（`client_?id` → `[ORDER_REF]`）要等 `config.alloy` 換掉、Alloy 重啟之後才生效，在那之前寫進 Loki 的行不在本次驗收範圍內。

`prometheus/rules/trading-targets.yml` 不變（Mac mini 只有 `macmini-m2 / toobit-mexc-btc` 一個 target），所以**本文件不執行 `scripts/central-deploy`**。

## Alloy 版本：為什麼只 pin

- `agents/alloy/alloy-versions.env` 列的 macOS 版本只有 `1.18.1`。Mac mini 的 Alloy 在 2026-08-11 以 1.18.1 安裝（work-log「部署 Trading production monitoring」）。
- grafana tap 的 `alloy.rb` 之後陸續升到 1.19.0、1.20.x、1.21.x（2026-10-28 是 1.21.3）。Homebrew 沒有 `--to`，`brew upgrade grafana/grafana/alloy` 只會裝 tap 當下的版本，也就是一個沒有測過的版本。所以本文件不跑 `brew upgrade`，改用 `brew pin`，讓之後任何人跑 `brew upgrade`（包括不帶參數的全部升級）都不會動到 Alloy。這等同 Linux 上的 `apt-mark hold`。`brew pin` 不改 keg、不碰 service，`brew unpin` 就能還原（R2）。
- **Phase 1 讀到的版本不是 1.18.1，就 STOP，回報版本。** 本文件不 downgrade（Alloy data 目錄裡的 WAL 與 positions 能不能給舊版讀，沒有測過），也沒有 macOS 版的升級腳本。後續做法是另開 SkyEye 任務：依 [Alloy versions](../agents/alloy/README.md#alloy-versions) 測過 Mac mini 實際安裝的版本，把它加進 `SKYEYE_ALLOY_MACOS_VERSIONS` 並 merge，再把本文件的版本檢查改成那個版本，從 Phase 0 重來。這段期間主機上的 Alloy 不動。

## 執行前必讀

**預設執行者**是經 SSH 登入 Mac mini 的 operator agent，帳號是 Trading 使用者（`TQ_REPO_ROOT` 所在家目錄的擁有者）。Phase 1 的 session gate 證明這個 SSH session 能管理該使用者的 launchd `gui/` domain 與 `brew services`。**gate 失敗時，operator 只做唯讀的部分，Phase 2–3 由 Wan 在 Mac mini 的實體畫面（console 登入同一個帳號、在 Terminal 執行）照本文件操作。** 原因：從 SSH 執行、而 `/dev/console` 不屬於這個帳號時，`brew services` 會改用 `user/<uid>` domain，與 `setup-macos.sh` 使用的 `gui/<uid>` 不一致，restart 會落在另一個 domain。

**Wan 必須事先同意或聯絡得到：**

1. Phase 3 讓 Mac mini 的 Alloy restart 一次。Trading 的 log 與 metrics 推送會中斷到 Alloy ready（通常幾秒，最多 60 秒）。probe 與 P&L history 的 launchd job 不受影響（plist 有變更時，那個 job 會 bootout 再 bootstrap，前後幾秒）。
2. Phase 3 的 `setup-macos.sh` 以 exit 3 結束時（見 Phase 3），operator 會照 R3 處理，並通知 Wan 與 manager。

**硬性限制：**

- **不得 start、stop、restart、kill、signal、attach、編輯任何 tnauqquant 的 launchd job、tmux session／pane、程序、config、`.env`、run-state 或 log。** 本文件只讀取它們（`launchctl list`、`tmux list-panes`、`pgrep -lf`、`shasum`、`tail`）。只有下面這些會變動：`homebrew.mxcl.alloy`（只透過 `brew services restart` 與 `setup-macos.sh`）、`com.wanbrain.skyeye-trading-probe`、`com.wanbrain.skyeye-trading-pnl-history`，以及上面列出的 SkyEye 檔案。
- **census 找到本文件沒有預期的 tnauqquant 程序、tmux session 或 launchd job 時，只記錄，絕不碰它。** Phase 5 的 census 必須與 Phase 1 完全相同。
- **時間：** Phase 2 與 Phase 3 開始前都要跑 `outside_window`。它在 UTC 18:05–19:30 一律拒絕：18:15–19:30 是 tnauqquant 的每日重啟時窗，前面再留 10 分鐘，讓一次 CHANGE 不會跨進去。
- 不印出 `config.env` 全文（內含 Cloudflare service token），只取 hash 與指定的非機密 key。
- Mac mini 與 monitoring-prod 各只能有一位 operator 執行本文件，一次一位。換手時把 `$WORK`／`$CUT` 路徑與執行紀錄交給下一位，下一位從 `$WORK/vars` 繼續，不重做已完成的 Phase。
- **不加 Alertmanager silence。** 所有 Trading 告警都是 `notification_mode="shadow"`，不會發 Telegram。
- Mac mini 的命令一律在 `/bin/bash` 裡執行（macOS 預設的 zsh 不行；helpers 是照 bash 3.2 寫的）。monitoring-prod 的命令以 `ubuntu` 在 `/home/ubuntu/SkyEye` 執行。

**預期會看到的 shadow 告警（不是失敗）：**

- Alloy restart 那幾秒 remote-write 會中斷，但遠低於 `TradingTelemetryMissing` 的 180 秒，所以不應該出現這個告警。出現的話就是失敗（見 Phase 4）。
- 新的 probe 帶有 11-05 之後的修正（今日 cycle 的時區、未來事件、`TQ_STRATEGY_DISABLED`），可能報出舊版沒有報出來的真實狀態。這種差異記錄下來交給 tnauqquant manager，不 rollback。
- `TradingRunBindingInvalid` 不看 `run_expected`。Phase 1 就已經 firing 的，記錄即可。

把 Phase 3 開始到 Phase 5 結束的 UTC 時窗寫進執行紀錄，並從 `macmini-m2` 的 Trading shadow／canary 證據中排除。

## 變數

| 名稱 | 說明 |
|---|---|
| `MERGE` | 含本文件的 master commit 完整 SHA（PR merge 後由 manager 提供） |
| `M7` | `MERGE` 前 7 碼 |
| `MAC` | Mac mini 的 SSH 目標，由 Wan 或 manager 提供（repo 沒有記錄），以 Trading 使用者登入 |
| `BREW_BIN` | Mac mini 的 brew 執行檔。Apple Silicon 預設 `/opt/homebrew/bin/brew`，Phase 1 核對 |
| `STAGE` | Mac mini 上的 staging：`$HOME/skyeye-staging/macmini-$M7` |
| `WORK` | Mac mini 上的紀錄目錄：`$HOME/skyeye-macmini-<UTC>`，mode 700。只放 hash、render 輸出與指令輸出，不放 `config.env` |
| `CUT` | monitoring-prod 上的紀錄目錄：`$HOME/macmini-rollout-$M7`，mode 700 |
| `RECORD` | Phase 3 的 `setup-macos.sh` 留下的 rollback record 目錄 |

**由 operator 在 Phase 1 唯讀核對的主機值**：這些值 repo 只有預期值（`agents/alloy/trading/deployment.env.example`、`docs/trading-new-server-handoff.md`），以 live `config.env` 為準。

| Key | repo 的預期值 | 不符時 |
|---|---|---|
| `TQ_PRODUCT` | `tnauqquant` | STOP |
| `TQ_ENVIRONMENT` | `production` | STOP |
| `TQ_SERVER_ID` | `macmini-m2` | STOP |
| `TQ_STRATEGY` | `toobit-mexc-btc` | STOP |
| `TQ_INSTANCE_ID` | `mexc-toobit-btc-initiator-hedge` | 記錄，交給 manager 判斷 |
| `TQ_REPO_ROOT` | `/Users/wan/projects/tnauqquant` | 記錄；它必須是 SSH 帳號的家目錄底下 |
| `TQ_TEXTFILE_DIR`、`TQ_TMUX_PATH`、`TQ_SIDECAR_SESSION` | example 的值 | 記錄 |
| `TQ_STRATEGY_DISABLED` | 空白或 `0` | `1` 時記錄：表示 operator 刻意停用 |

tnauqquant 在 Mac mini 上的跑法，依 repo 是 `scripts/tq live run --human` 跑在 operator 的 tmux 裡，前景執行、不自動重啟，sidecar 跑在 tmux session `goexchange-sidecar`（`TQ_SIDECAR_SESSION`）。**repo 沒有記錄任何 tnauqquant launchd job。** census 列出的 launchd label 都由 operator 記入執行紀錄，不在本文件寫死。

## Phase 0 — Staging（operator 機器 → Mac mini）

operator 機器，在 SkyEye checkout 內：

```bash
MERGE=<完整 SHA>; M7=${MERGE:0:7}; MAC=<SSH 目標>
git fetch origin
git merge-base --is-ancestor "$MERGE" origin/master && echo MERGE-ON-MASTER
git cat-file -e "$MERGE:docs/macmini-m2-alloy-rollout.md" && echo MERGE-HAS-RUNBOOK
OUT=$(mktemp -d)
git archive --format=tar --prefix="macmini-$M7/" "$MERGE" agents/alloy >"$OUT/skyeye-alloy-$M7.tar"
shasum -a 256 "$OUT/skyeye-alloy-$M7.tar"                      # 記下 TAR_SHA
git show "$MERGE:agents/alloy/trading/probe.sh" | shasum -a 256   # 記下 PROBE_SHA
scp "$OUT/skyeye-alloy-$M7.tar" "$MAC:skyeye-alloy-$M7.tar"
```

`MERGE-ON-MASTER` 與 `MERGE-HAS-RUNBOOK` 都要印出，否則停下，向 manager 確認 `MERGE`。

`[CHANGE Mac mini]`（只新增 staging），`ssh "$MAC"` 之後：

```bash
/bin/bash
M7=<同上>; TAR_SHA=<上面記下的 TAR_SHA>; PROBE_SHA=<上面記下的 PROBE_SHA>
S="$HOME/skyeye-staging/macmini-$M7"
if [ -e "$S" ]; then
  echo "STOP: $S already exists"
elif [ "$(shasum -a 256 "$HOME/skyeye-alloy-$M7.tar" | cut -c1-64)" != "$TAR_SHA" ]; then
  echo "STOP: $HOME/skyeye-alloy-$M7.tar does not match TAR_SHA"
else
  mkdir -p "$HOME/skyeye-staging" &&
    tar -x -f "$HOME/skyeye-alloy-$M7.tar" -C "$HOME/skyeye-staging" &&
    chmod -R go-w "$S" &&
    [ "$(shasum -a 256 "$S/agents/alloy/trading/probe.sh" | cut -c1-64)" = "$PROBE_SHA" ] &&
    rm -f "$HOME/skyeye-alloy-$M7.tar" && echo STAGED
fi
```

整段一起貼上執行。結果：

- `STAGED`：完成。
- `STOP: … already exists`：什麼都沒寫入。不覆蓋，改用新的 `MERGE`，或請 manager 確認舊目錄的來源。
- `STOP: … does not match TAR_SHA`：什麼都沒寫入。從 operator 機器重新 `scp`，再跑一次。
- 沒有 `STAGED` 也沒有 `STOP:`：解壓或 `probe.sh` 檢查失敗，`$S` 可能已部分建立。停下，把輸出交給 manager，不要使用 `$S`。

## Phase 1 — 前置檢查 `[READ-ONLY]`

這個 Phase 只讀取，唯一的寫入是 `$WORK`、`$CUT` 紀錄、`--render-only` 輸出與 probe 試跑的輸出（都在 `$WORK` 內）。**任何一項標成 STOP 的不符，就不進 Phase 2。** STOP 時主機沒有任何變更。

### Mac mini

開 bash、載入 brew 環境，建立紀錄目錄與 helper：

```bash
/bin/bash
BREW_BIN=/opt/homebrew/bin/brew                     # 不存在時用 `command -v brew` 找到的路徑，並記入執行紀錄
eval "$("$BREW_BIN" shellenv)"
MERGE=<完整 SHA>; M7=${MERGE:0:7}
STAGE="$HOME/skyeye-staging/macmini-$M7"
WORK="$HOME/skyeye-macmini-$(date -u +%Y%m%dT%H%M%SZ)"; install -d -m 700 "$WORK"
declare -p BREW_BIN MERGE M7 STAGE WORK >"$WORK/vars"
cat >"$WORK/helpers.sh" <<'EOF'
# SkyEye 在 Mac mini 上的路徑，全部由 brew --prefix 與 $HOME 推出
BP="$(brew --prefix)"
ETC="$BP/etc/alloy"
ENV_FILE="$ETC/config.env"
EXTRA_ARGS="$ETC/extra-args.txt"
LIBEXEC="$BP/libexec/skyeye-trading"
STATE="$BP/var/skyeye-trading"
LA="$HOME/Library/LaunchAgents"
SETUP="$STAGE/agents/alloy/trading/setup-macos.sh"
FORMULA=grafana/grafana/alloy
ALLOY_LABEL=homebrew.mxcl.alloy
PROBE_LABEL=com.wanbrain.skyeye-trading-probe
HISTORY_LABEL=com.wanbrain.skyeye-trading-pnl-history
DOMAIN="gui/$(id -u)"
CONSOLE=/dev/console   # 在 Mac mini 上一定是 /dev/console；只有 rehearsal 測試會把它換掉
# config.env 裡一個非機密 key 的字面值（不 source、不印出其他行）
env_value() {
  sed -nE "s/^(export[[:space:]]+)?$1=//p" "$ENV_FILE" | tail -n 1 |
    sed -E "s/^'(.*)'\$/\\1/; s/^\"(.*)\"\$/\\1/"
}
# UTC 18:05–19:30 拒絕：18:15–19:30 是 tnauqquant 每日重啟，前面留 10 分鐘
outside_window() {
  local t
  t="$(date -u +%H%M)"
  if [ "$t" -ge 1805 ] && [ "$t" -lt 1930 ]; then
    echo "STOP: it is $t UTC; no CHANGE between 18:05 and 19:30 UTC (tnauqquant daily restart 18:15-19:30)"
    return 1
  fi
  echo "CLOCK-OK $t UTC"
}
# 證明這個 session 能管理使用者的 gui/ launchd domain 與 brew services
session_gate() {
  local rc=0 me owner
  me="$(id -u)"
  owner="$(stat -f %u "$CONSOLE")"
  if [ "$owner" = "$me" ]; then
    echo CONSOLE-OWNER
  else
    echo "STOP: $CONSOLE belongs to uid $owner, not $me; brew services would use user/$me instead of $DOMAIN"
    rc=1
  fi
  if launchctl print "$DOMAIN" >/dev/null 2>&1; then
    echo GUI-DOMAIN
  else
    echo "STOP: launchctl print $DOMAIN failed"
    rc=1
  fi
  if launchctl print "$DOMAIN/$ALLOY_LABEL" >/dev/null 2>&1; then
    echo ALLOY-IN-GUI-DOMAIN
  else
    echo "STOP: $ALLOY_LABEL is not loaded in $DOMAIN"
    rc=1
  fi
  if ! brew services info "$FORMULA" --json >"$WORK/brew-services.json" 2>"$WORK/brew-services.err"; then
    echo "STOP: brew services info $FORMULA --json failed"
    rc=1
  elif grep -q 'instead of gui' "$WORK/brew-services.err"; then
    echo "STOP: brew services uses the user/* domain in this session"
    rc=1
  elif [ "$(plutil -extract 0.loaded raw -o - "$WORK/brew-services.json" 2>/dev/null)" != true ] ||
    [ "$(plutil -extract 0.running raw -o - "$WORK/brew-services.json" 2>/dev/null)" != true ] ||
    [ "$(plutil -extract 0.file raw -o - "$WORK/brew-services.json" 2>/dev/null)" != "$LA/$ALLOY_LABEL.plist" ]; then
    echo "STOP: brew services does not report $ALLOY_LABEL loaded and running from $LA"
    rc=1
  else
    echo BREW-SERVICES-OK
  fi
  return "$rc"
}
alloy_pinned() {
  brew info --json=v2 "$FORMULA" | plutil -extract formulae.0.pinned raw -o - -
}
alloy_pid() {
  launchctl print "$DOMAIN/$ALLOY_LABEL" 2>/dev/null | awk '$1 == "pid" && $2 == "=" { print $3; exit }'
}
# Alloy 啟動之後 config.env 與 extra-args.txt 都沒被改過，restart 才不會套用沒人測過的內容
start_inputs_fresh() {
  local pid started f m rc=0
  pid="$(alloy_pid)"
  if [ -z "$pid" ]; then
    echo "STOP: no Alloy pid in $DOMAIN/$ALLOY_LABEL"
    return 1
  fi
  started="$(LC_ALL=C ps -o lstart= -p "$pid" | tr -s ' ' | sed 's/^ //; s/ $//')"
  started="$(LC_ALL=C date -j -f '%a %b %d %T %Y' "$started" +%s 2>/dev/null)"
  if [ -z "$started" ]; then
    echo "STOP: cannot read when Alloy pid $pid started"
    return 1
  fi
  for f in "$ENV_FILE" "$EXTRA_ARGS"; do
    [ -e "$f" ] || continue
    m="$(stat -f %m "$f")"
    if [ "$m" -ge "$started" ]; then
      echo "STOP: $f changed at $m, not before Alloy pid $pid started at $started"
      rc=1
    fi
  done
  [ "$rc" -ne 0 ] || echo "START-INPUTS-FRESH pid=$pid started=$started"
  return "$rc"
}
# Alloy 的 ready 位址：與 setup-macos.sh 相同，讀 extra-args.txt，預設 127.0.0.1:12345
ready_url() {
  local args="" listen host
  if [ -f "$EXTRA_ARGS" ]; then args="$(tr '\n' ' ' <"$EXTRA_ARGS")"; fi
  listen="$(printf '%s\n' "$args" | sed -nE 's/.*--server[.]http[.]listen-addr[= ]+([^ ]+).*/\1/p')"
  [ -n "$listen" ] || listen=127.0.0.1:12345
  host="${listen%:*}"
  case "$host" in "" | 0.0.0.0 | "[::]") host=127.0.0.1 ;; esac
  printf 'http://%s:%s/-/ready\n' "$host" "${listen##*:}"
}
# 連續兩次 ready（間隔 2 秒）才算，最多等 60 秒
wait_ready() {
  local i=0
  while [ "$i" -lt 60 ]; do
    if curl -fsS -m 5 -o /dev/null "$(ready_url)" 2>/dev/null; then
      sleep 2
      if curl -fsS -m 5 -o /dev/null "$(ready_url)" 2>/dev/null; then return 0; fi
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}
jobs_state() {
  local label
  for label in "$ALLOY_LABEL" "$PROBE_LABEL" "$HISTORY_LABEL"; do
    if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
      echo "$label loaded"
    else
      echo "$label not-loaded"
    fi
  done
}
etc_files() {
  find "$ETC" -maxdepth 1 -type f | LC_ALL=C sort
}
hash_etc() {
  local f
  etc_files | while IFS= read -r f; do shasum -a 256 "$f"; done
}
# setup-macos.sh 寫入的五個檔案（不存在的不列出）
hash_skyeye() {
  local f
  for f in "$LIBEXEC/probe.sh" "$LIBEXEC/pnl-history.sh" "$ETC/config.alloy" \
    "$LA/$PROBE_LABEL.plist" "$LA/$HISTORY_LABEL.plist"; do
    if [ -f "$f" ]; then shasum -a 256 "$f"; fi
  done
}
# config.alloy 以外的 $ETC 檔案（config.env、extra-args.txt 等）的 hash
hash_inputs() {
  hash_etc | awk -v skip="$ETC/config.alloy" '$2 != skip'
}
# 那些檔案與 Phase 1 相同，也沒有多出或少掉檔案
inputs_same() {
  shasum -a 256 -c --quiet "$WORK/etc-inputs.before" >/dev/null 2>&1 &&
    etc_files | cmp -s - "$WORK/etc-list.before"
}
# Phase 3 的前提：時間、session、啟動輸入，以及 Phase 1 之後沒有人改過檔案
phase3_ready() {
  outside_window || return 1
  if ! session_gate >"$WORK/session-gate.phase3"; then
    cat "$WORK/session-gate.phase3"
    echo "STOP: the session gate failed"
    return 1
  fi
  echo SESSION-OK
  start_inputs_fresh || return 1
  if ! shasum -a 256 -c --quiet "$WORK/etc.before" >/dev/null 2>&1 ||
    ! etc_files | cmp -s - "$WORK/etc-list.before"; then
    echo "STOP: a file in $ETC changed since Phase 1"
    return 1
  fi
  echo ETC-AS-PHASE1
  if ! hash_skyeye | cmp -s - "$WORK/skyeye.before"; then
    echo "STOP: a file setup-macos.sh installs changed since Phase 1"
    return 1
  fi
  echo SKYEYE-AS-PHASE1
}
record_dirs() {
  ls -1d "$STATE"/install-backup/*/ 2>/dev/null | sed 's#/$##' | LC_ALL=C sort
}
# Phase 1 之後才出現的最新一個 setup record
new_record() {
  record_dirs | comm -13 "$WORK/records.before" - | tail -n 1
}
# render 新版到 $WORK/render，逐一和 live 檔案比對。label 或 path 會變就 STOP
render_compare() {
  local r="$WORK/render" f label
  rm -rf "$r"
  if ! "$SETUP" --render-only "$r" </dev/null >"$WORK/render.out" 2>&1; then
    cat "$WORK/render.out"
    echo "STOP: setup-macos.sh --render-only failed"
    return 1
  fi
  if ! alloy validate "$r/config.alloy" >"$WORK/render-validate.out" 2>&1; then
    cat "$WORK/render-validate.out"
    echo "STOP: the installed Alloy rejects the new config.alloy"
    return 1
  fi
  for f in probe.sh pnl-history.sh; do
    if cmp -s "$r/$f" "$LIBEXEC/$f"; then echo "SAME $f"; else echo "CHANGED $f"; fi
  done
  diff -u "$ETC/config.alloy" "$r/config.alloy" >"$WORK/config.diff"
  if [ -s "$WORK/config.diff" ]; then echo "CHANGED config.alloy"; else echo "SAME config.alloy"; fi
  if grep -E '^[-+][[:space:]]*(__path__|product|environment|server_id|strategy)[[:space:]]*=' "$WORK/config.diff"; then
    echo "STOP: the new config.alloy changes a Loki label or the log path"
    return 1
  fi
  for label in "$PROBE_LABEL" "$HISTORY_LABEL"; do
    sed -e "s#$r/probe.sh#$LIBEXEC/probe.sh#g" -e "s#$r/pnl-history.sh#$LIBEXEC/pnl-history.sh#g" \
      -e "s#$r#$BP/var/log/alloy#g" "$r/$label.plist" >"$WORK/$label.plist.expected"
    if cmp -s "$WORK/$label.plist.expected" "$LA/$label.plist"; then
      echo "SAME $label.plist"
    else
      echo "CHANGED $label.plist"
    fi
  done
}
# probe 輸出的關鍵值：metric 值。參數是 textfile 目錄，預設為 live 目錄
textfile_values() {
  local dir="${1:-$(env_value TQ_TEXTFILE_DIR)}"
  awk '/^tnauqquant_(probe_timestamp_seconds|run_expected|process_count|runtime_contract_available|process_identity_ok|strategy_identity_ok|config_snapshot_match|log_binding_ok|marker_binding_ok)[{ ]/ {
      name = $0; sub(/[{ ].*/, "", name); print name, $NF
    }' "$dir/tnauqquant.prom"
}
# tnauqquant 的 launchd job、tmux pane、程序與 config／run-state hash（只讀）
tnauqquant_census() {
  local root tmux_bin f
  root="$(env_value TQ_REPO_ROOT)"
  tmux_bin="$(env_value TQ_TMUX_PATH)"
  [ -n "$tmux_bin" ] || tmux_bin=tmux
  echo "## launchd"
  launchctl list | awk 'NR > 1 { print $3, $1 }' | grep -iE 'tnauq|quant|sidecar|goexchange' |
    grep -v '^com[.]wanbrain[.]skyeye-' | LC_ALL=C sort
  echo "## tmux"
  "$tmux_bin" list-panes -a -F '#{session_name} #{pane_pid} #{pane_current_command}' 2>/dev/null | LC_ALL=C sort
  echo "## processes"
  pgrep -lf -- "$root" | LC_ALL=C sort
  echo "## files"
  for f in "$(env_value TQ_CONFIG_PATH)" "$(env_value TQ_RUN_MANIFEST)" "$(env_value TQ_DONE_MARKER)"; do
    if [ -f "$f" ]; then shasum -a 256 "$f"; else echo "absent $f"; fi
  done
}
# RFC3339（小數秒可有可無，Z 或 ±HH:MM）轉成 epoch 奈秒
rfc3339_ns() {
  perl -MTime::Local=timegm -e '
    $ARGV[0] =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)$/ or exit 1;
    my ($frac, $zone) = ($7, $8);
    my $s = timegm($6, $5, $4, $3, $2 - 1, $1);
    if ($zone ne "Z") {
      my ($sign, $h, $m) = $zone =~ /^([+-])(\d\d):(\d\d)$/;
      $s -= ($sign eq "+" ? 1 : -1) * ($h * 3600 + $m * 60);
    }
    $frac = substr((defined $frac ? $frac : "") . "000000000", 0, 9);
    printf "%d%s\n", $s, $frac;' "$1"
}
# 來源端 log 證據（只讀）：最新的 raw log 取倒數第二行（一定已經寫完整），
# 它的 time= 不早於 SINCE（epoch 秒）時印出事件時間（epoch ns），否則印 none。
# 輸出是一行要原樣貼到 monitoring-prod 執行的：loki_accept STRATEGY EPOCH_NS|none SINCE
log_evidence() {
  local s="$1" since="$2" glob minutes f t ns=none
  if [ "$s" != "$(env_value TQ_STRATEGY)" ]; then
    echo "STOP: $s is not this host's TQ_STRATEGY"
    return 1
  fi
  glob="$(env_value TQ_RAW_LOG_GLOB)"
  minutes=$(( ($(date +%s) - since) / 60 + 1 ))
  f="$(find "${glob%/*}" -maxdepth 1 -type f -name "${glob##*/}" -mmin "-$minutes" -exec ls -1t {} + 2>/dev/null | head -n 1)"
  if [ -n "$f" ]; then
    t="$(tail -n 2 "$f" | head -n 1 | grep -oE '(^|[[:space:]])time=[^[:space:]]+' | head -n 1 |
      sed -E 's/^[[:space:]]*time=//; s/"//g')"
    if [ -n "$t" ] && ns="$(rfc3339_ns "$t")" && [ -n "$ns" ] &&
      [ "$(( ns / 1000000000 ))" -ge "$since" ]; then
      :
    else
      ns=none
    fi
  fi
  printf 'loki_accept %s %s %s\n' "$s" "$ns" "$since"
}
# R3：照 setup record 還原 SkyEye 的檔案，restart Alloy，兩個 job 回到 Phase 1 的狀態。
# 每一步失敗都印出 STOP 並回傳 1，之後的步驟不會執行。
r3_rollback() {
  local record="$1" path label state
  date -u +%FT%TZ >"$WORK/r3-start"
  if [ -z "$record" ] || [ ! -f "$record/present.list" ] || [ ! -f "$record/absent.list" ] ||
    [ ! -f "$record/transaction.meta" ]; then
    echo "STOP: incomplete record '$record'; nothing was restored"
    return 1
  fi
  grep '^status=' "$record/transaction.meta" | tail -n 1
  if ! inputs_same; then
    echo "STOP: a file in $ETC other than config.alloy differs from Phase 1; nothing was restored"
    return 1
  fi
  while IFS= read -r path <&3; do
    [ -z "$path" ] || rm -f -- "$path" || { echo "STOP: cannot remove $path"; return 1; }
  done 3<"$record/absent.list"
  while IFS= read -r path <&3; do
    [ -n "$path" ] || continue
    cp -p "$record/previous/${path#/}" "$path" || { echo "STOP: cannot restore $path from $record"; return 1; }
  done 3<"$record/present.list"
  echo "restored $record"
  if ! shasum -a 256 -c --quiet "$WORK/skyeye.before"; then
    echo "STOP: the restored files differ from Phase 1"
    return 1
  fi
  echo FILES-AS-PHASE1
  if ! alloy validate "$ETC" >"$WORK/r3-validate.out" 2>&1; then
    cat "$WORK/r3-validate.out"
    echo "STOP: alloy validate rejects the restored $ETC; Alloy was not restarted"
    return 1
  fi
  brew services restart "$FORMULA" || { echo "STOP: brew services restart $FORMULA failed"; return 1; }
  wait_ready || { echo "STOP: Alloy is not ready at $(ready_url) after the restart"; return 1; }
  echo ALLOY-RESTARTED
  while read -r label state <&3; do
    [ "$label" != "$ALLOY_LABEL" ] || continue
    launchctl bootout "$DOMAIN/$label" >/dev/null 2>&1 || true
    if [ "$state" = loaded ]; then
      { launchctl bootstrap "$DOMAIN" "$LA/$label.plist" && launchctl enable "$DOMAIN/$label" &&
        launchctl print "$DOMAIN/$label" >/dev/null 2>&1; } ||
        { echo "STOP: cannot load $label"; return 1; }
    fi
  done 3<"$WORK/jobs.before"
  if ! jobs_state | cmp -s - "$WORK/jobs.before"; then
    echo "STOP: the launchd jobs differ from Phase 1"
    return 1
  fi
  echo JOBS-AS-PHASE1
}
EOF
. "$WORK/helpers.sh"
date -u +%FT%TZ | tee "$WORK/phase1-start"
```

`BREW_BIN` 不存在時：`command -v brew` 找到的路徑記入執行紀錄後再用。找不到 brew 就 STOP。

斷線重連時：`/bin/bash`，`WORK=$(ls -d "$HOME"/skyeye-macmini-* | tail -n 1); . "$WORK/vars"; eval "$("$BREW_BIN" shellenv)"; . "$WORK/helpers.sh"`。

**Session gate（D5）：**

```bash
session_gate | tee "$WORK/session-gate"; echo "rc=${PIPESTATUS[0]}"
```

預期四行 `CONSOLE-OWNER`、`GUI-DOMAIN`、`ALLOY-IN-GUI-DOMAIN`、`BREW-SERVICES-OK`，然後 `rc=0`。這四項分別證明：

- `/dev/console` 屬於這個帳號：`brew services` 會用 `gui/<uid>`，而不是 `user/<uid>`。
- `launchctl print gui/<uid>` 成功：這個 session 看得到使用者的 GUI domain。
- `homebrew.mxcl.alloy` 載入在那個 domain。
- `brew services info grafana/grafana/alloy --json` 回報 loaded、running，plist 在 `~/Library/LaunchAgents`，而且沒有印出 `using user/* instead of gui/*`。

任何一行是 `STOP:`：**operator 留在唯讀**，照常跑完 Phase 1 其餘的唯讀檢查，把結果交給 manager。Phase 2–3 由 Wan 在 Mac mini 的實體畫面上（同一個帳號登入 console，在 Terminal 執行 `/bin/bash`）從「斷線重連」那一行接手，先重跑 `session_gate`，必須是 `rc=0`。

**Alloy 版本：**

```bash
command -v alloy brew                                       # $(brew --prefix)/bin/alloy 與 $(brew --prefix)/bin/brew
alloy --version | head -n 1 | tee "$WORK/alloy-version.before"   # alloy, version v1.18.1 (…)
brew list --versions "$FORMULA" | tee "$WORK/brew-versions.before"   # alloy 1.18.1
alloy_pinned | tee "$WORK/pinned.before"                    # true 或 false，都可以
brew --version | head -n 1 | tee "$WORK/brew-version"
```

- `alloy --version` 不是 `v1.18.1`，或 `brew list --versions` 不是剛好一行 `alloy 1.18.1`（例如列出兩個版本）：**STOP**，回報這兩行輸出。後續做法見[Alloy 版本：為什麼只 pin](#alloy-版本為什麼只-pin)，不 upgrade，也不 downgrade。
- `command -v alloy` 不在 `$(brew --prefix)/bin`：STOP，因為 `setup-macos.sh` 的版本檢查讀的是 PATH 上的 `alloy`。

**Alloy 服務與啟動輸入：**

```bash
jobs_state | tee "$WORK/jobs.before"                        # 三行都是 loaded
alloy_pid | tee "$WORK/alloy-pid.before"
ready_url | tee "$WORK/ready-url"; curl -fsS "$(ready_url)"; echo     # 成功
start_inputs_fresh | tee "$WORK/start-inputs"; echo "rc=${PIPESTATUS[0]}"   # START-INPUTS-FRESH …，rc=0
if [ -e "$STATE/installed-env.sha256" ]; then echo ENV-RECORD-PRESENT; else echo NO-ENV-RECORD; fi | tee "$WORK/env-record.before"
record_dirs >"$WORK/records.before"; wc -l <"$WORK/records.before"
stat -f '%Lp' "$ENV_FILE"                                   # 600
```

- `jobs.before` 不是三行 `loaded`：STOP。本文件只涵蓋三個 job 都在跑的狀態。
- ready 失敗：STOP，Alloy 已經有問題，先查明。
- `start_inputs_fresh` 印出 `STOP:`：有人在 Alloy 這次啟動之後改了 `config.env` 或 `extra-args.txt`，Phase 3 的 restart 會套用沒有人驗證過的內容。STOP，交給 manager，不要自己改回。
- `NO-ENV-RECORD` 是預期的，Phase 3 會 restart。`ENV-RECORD-PRESENT` 表示新版 installer 已經在這臺跑過，Phase 3 會改成 reload 或不動 Alloy，兩種都可以，記錄下來。

**檔案基準：**

```bash
etc_files | tee "$WORK/etc-list.before"                     # config.alloy、config.env、extra-args.txt
hash_etc >"$WORK/etc.before"
hash_inputs >"$WORK/etc-inputs.before"
hash_skyeye | tee "$WORK/skyeye.before"                     # 五行：probe.sh、pnl-history.sh、config.alloy、兩個 plist
find "$ETC" -maxdepth 1 -name '*.alloy' ! -name config.alloy   # 必須沒有輸出
```

- `etc-list.before` 有上面三個以外的檔案（例如 Homebrew 寫出的 `*.default`）：記錄。它們不會被 Alloy 載入，hash 會一起核對。
- 有 `config.alloy` 以外的 `*.alloy`：STOP。Mac mini 的 Alloy 依紀錄只跑 Trading pipeline，多出來的 pipeline 會被 Phase 3 的 restart 中斷，也會被一起驗證，交給 manager 判斷。
- `skyeye.before` 不是五行：STOP（舊安裝不完整，不是本文件涵蓋的狀態）。

**config.env 的非機密 key（不印全文）：**

```bash
for k in TQ_PRODUCT TQ_ENVIRONMENT TQ_SERVER_ID TQ_STRATEGY TQ_INSTANCE_ID TQ_REPO_ROOT TQ_TEXTFILE_DIR \
  TQ_TMUX_PATH TQ_SIDECAR_SESSION TQ_STRATEGY_DISABLED; do
  printf '%s=%s\n' "$k" "$(env_value "$k")"
done | tee "$WORK/env-keys.before"
```

逐一對照[變數](#變數)那張表的預期值與處理方式。

**Render 比對與新 probe 試跑（只寫 `$WORK`）：**

```bash
render_compare | tee "$WORK/render-compare"; echo "rc=${PIPESTATUS[0]}"
```

預期：`CHANGED probe.sh`、`CHANGED pnl-history.sh`、`CHANGED config.alloy`，兩個 plist 是 `SAME` 或 `CHANGED`，最後 `rc=0`。

- 任何 `STOP:`：STOP。`--render-only` 失敗通常是 live `config.env` 缺少新版要求的 key（例如 `TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES`），或值不合法。`setup-macos.sh` 會以同樣原因拒絕。本文件不補值，交給 operator 與 manager。
- `SAME probe.sh`：Mac mini 已經是這個版本的 probe，和盤點不符，記錄後交給 manager 確認再繼續。
- `CHANGED <label>.plist`：Phase 3 會 bootout 再 bootstrap 那個 job（前後幾秒）。`SAME` 時不碰它。
- `$WORK/config.diff` 是 Phase 3 會套用的 scrub 更新。label 與 log path 不能變（不變時 Alloy 保留 positions，不會重讀 log）。

```bash
install -d -m 700 "$WORK/probe-try"
( set -a; . "$ENV_FILE"; set +a; TQ_TEXTFILE_DIR="$WORK/probe-try"; export TQ_TEXTFILE_DIR
  exec /bin/bash "$STAGE/agents/alloy/trading/probe.sh" ) >"$WORK/probe-try.out" 2>&1; echo "rc=$?"
textfile_values | tee "$WORK/textfile.before"
textfile_values "$WORK/probe-try" | tee "$WORK/textfile.try"
diff "$WORK/textfile.before" "$WORK/textfile.try"
```

新 probe 只讀取 Trading 的檔案與程序表，輸出寫在 `$WORK/probe-try`，不碰 live textfile。

- `rc` 不是 0：STOP，把 `$WORK/probe-try.out` 交給 manager。
- `probe_timestamp_seconds` 本來就會不同。其他值不同時**不 STOP**：記錄下來，交給 tnauqquant manager（新版 probe 可能報出舊版沒報出來的真實狀態）。

**tnauqquant census（只讀，Phase 5 會再比一次）：**

```bash
tnauqquant_census | tee "$WORK/tnauqquant.before"
```

四段分別是 `## launchd`（label 與 PID）、`## tmux`（session、pane PID、pane 正在執行的命令）、`## processes`（命令列含 `TQ_REPO_ROOT` 的程序）、`## files`（Trading config、`current.json`、`current.done.json` 的 hash）。

- 依 repo 預期的是：`goexchange-sidecar`（`TQ_SIDECAR_SESSION`）的 tmux session、跑 `scripts/tq live run --human` 的 pane，以及策略在跑時一個以 `TQ_CONFIG_PATH` 啟動的 `quant` 程序。`## launchd` 沒有預期的 label。
- **census 找到任何本文件沒有預期的 tnauqquant 程序、tmux session 或 launchd job：只記入執行紀錄，絕不碰它，照常繼續。** 本文件沒有任何命令作用於它們。
- 策略有沒有在跑只記錄（`textfile.before` 的 `process_count`），不影響後續。

### monitoring-prod（ubuntu）

```bash
M7=<同上>; MERGE=<完整 SHA>
CUT="$HOME/macmini-rollout-$M7"; install -d -m 700 "$CUT"
declare -p M7 MERGE CUT >"$CUT/vars"
cd /home/ubuntu/SkyEye
cat >"$CUT/helpers.sh" <<'EOF'
q() { curl -fsS --get http://127.0.0.1:9090/api/v1/query --data-urlencode "query=$1" | jq -c '.data.result'; }
lq() { curl -fsS --get http://127.0.0.1:3100/loki/api/v1/query --data-urlencode "query=$1" | jq -c '.data.result'; }
targets() { q 'trading_target_info' | jq -S '[.[].metric | del(.__name__)] | sort'; }
mac_ages() {
  { q 'time() - tnauqquant_probe_timestamp_seconds{product="tnauqquant",server_id="macmini-m2"}' |
      jq -c '{probe: [.[] | {strategy: .metric.strategy, age: (.value[1] | tonumber | floor)}]}'
    q 'time() - tnauqquant_pnl_history_build_timestamp_seconds{product="tnauqquant",server_id="macmini-m2"}' |
      jq -c '{history: [.[] | {strategy: .metric.strategy, age: (.value[1] | tonumber | floor)}]}'
  } | jq -s -c 'add'
}
mac_alerts() { q 'ALERTS{product="tnauqquant",server_id="macmini-m2",alertstate="firing"}' \
  | jq -c '[.[].metric | {alertname, strategy}] | sort'; }
mac_history_valid() { q 'tnauqquant_pnl_history_valid{product="tnauqquant",server_id="macmini-m2"}' | jq -c '[.[].value[1]]'; }
# Mac mini 的 log_evidence 印出的那一行：loki_accept STRATEGY EPOCH_NS|none SINCE。
# 先要求 Loki 在該 strategy 的 stream 裡有時間戳剛好是 EPOCH_NS 的行（Alloy 用 log 的 time=
# 當時間戳），找到之後 label 與 scrub 檢查才算數。空的 stream 永遠不會印出 LOKI-ACCEPTED。
loki_accept() {
  local s="$1" ns="$2" since="$3" sel found labels unscrubbed
  local re='(?i)(order_?id|client_?action_?id|client_?id)=[^\[]'
  sel="{product=\"tnauqquant\",server_id=\"macmini-m2\",strategy=\"$s\"}"
  if [ "$ns" = none ]; then
    echo "LOKI-PENDING $s: no source log event since $since"
    return 2
  fi
  found="$(curl -fsS --get http://127.0.0.1:3100/loki/api/v1/query_range --data-urlencode "query=$sel" \
      --data-urlencode "start=$((ns - 1000000000))" --data-urlencode "end=$((ns + 1000000000))" \
      --data-urlencode 'limit=5000' --data-urlencode 'direction=forward' |
    jq -r --arg ns "$ns" '[.data.result[].values[] | select(.[0] == $ns)] | length')"
  case "$found" in
    '' | *[!0-9]*) echo "LOKI-ERROR $s: the query_range call failed"; return 1 ;;
    0) echo "LOKI-MISSING $s: no line at the source event time $ns"; return 1 ;;
  esac
  labels="$(curl -fsS --get http://127.0.0.1:3100/loki/api/v1/series --data-urlencode "match[]=$sel" \
      --data-urlencode "start=$since" |
    jq -c '([.data[] | keys[]] | unique) - ["environment","level","product","run_id","server_id","strategy","service_name"]')"
  [ -n "$labels" ] || { echo "LOKI-ERROR $s: the series call failed"; return 1; }
  [ "$labels" = '[]' ] || { echo "LOKI-LABELS $s: unexpected labels $labels"; return 1; }
  unscrubbed="$(lq "sum(count_over_time($sel |~ \`$re\` [$(( $(date +%s) - since ))s]))")"
  [ -n "$unscrubbed" ] || { echo "LOKI-ERROR $s: the scrub query failed"; return 1; }
  [ "$unscrubbed" = '[]' ] || { echo "LOKI-UNSCRUBBED $s: $unscrubbed"; return 1; }
  echo "LOKI-ACCEPTED $s: the line at $ns is in Loki; labels and scrub checked since $since"
}
EOF
. "$CUT/helpers.sh"

git rev-parse HEAD | tee "$CUT/deployed-head"
scripts/central-deploy --status 2>&1 | tee "$CUT/central-status-pre.log"   # Prometheus last reload successful: 1
git fetch origin
git diff --quiet HEAD "$MERGE" -- prometheus/rules/trading-targets.yml && echo INVENTORY-SAME
targets | tee "$CUT/pre-targets.json"
jq -e 'map(select(.server_id == "macmini-m2") | .strategy) == ["toobit-mexc-btc"]' "$CUT/pre-targets.json"   # true
mac_ages | tee "$CUT/ages.pre.json"                  # probe 一筆 age < 60；history 一筆 age < 120
mac_history_valid | tee "$CUT/history-valid.pre.json"
mac_alerts | tee "$CUT/alerts.pre.json"
```

斷線重連時：`CUT="$HOME/macmini-rollout-<M7>"; . "$CUT/vars"; . "$CUT/helpers.sh"; cd /home/ubuntu/SkyEye`。

`git fetch` 只更新 remote ref，不移動 checkout，也不 reload 任何東西。

- 沒有 `INVENTORY-SAME`：`MERGE` 的 Trading inventory 和 monitoring-prod 已部署的不同。這不在本文件的範圍內（本文件不跑 `central-deploy`），STOP，交給 manager。
- `jq` 印出 `false`：中央的 `macmini-m2` target 和預期不同，STOP。
- `ages.pre.json` 不符：既有 probe 或 history 已經有問題，STOP，先查明。
- `alerts.pre.json` 非空：記錄（例如已在 firing 的 `TradingRunBindingInvalid`），Phase 4 拿來比對。

Phase 1 全部通過才進 Phase 2。

## Phase 2 — `brew pin` `[CHANGE Mac mini]`

```bash
if outside_window; then
  date -u +%FT%TZ | tee "$WORK/phase2-start"
  if [ "$(cat "$WORK/pinned.before")" = true ]; then echo ALREADY-PINNED; else brew pin "$FORMULA"; fi
fi
alloy_pinned                                               # true
brew list --versions "$FORMULA" | cmp - "$WORK/brew-versions.before" && echo VERSIONS-SAME
alloy_pid | cmp - "$WORK/alloy-pid.before" && echo ALLOY-PID-SAME
```

`outside_window` 印出 `STOP:` 時，`if` 裡面的命令都不會執行，等到 19:30 UTC 之後從這個區塊重來。`alloy_pinned` 必須是 `true`，`VERSIONS-SAME` 與 `ALLOY-PID-SAME` 都要印出：pin 不改 keg，也不碰 service。不符時執行 [R2](#r2--撤銷-pin)，然後 STOP。

## Phase 3 — 重跑 `setup-macos.sh` `[CHANGE Mac mini]`

```bash
if phase3_ready; then
  date +%s >"$WORK/phase3-epoch"; date -u +%FT%TZ | tee "$WORK/phase3-start"
  "$SETUP" </dev/null 2>&1 | tee "$WORK/setup.out"; echo "rc=${PIPESTATUS[0]}" | tee -a "$WORK/setup.out"
  RECORD="$(new_record)"; declare -p RECORD >>"$WORK/vars"; echo "RECORD=$RECORD"
  [ -z "$RECORD" ] || grep -E '^(alloy_action|start_inputs|status)=' "$RECORD/transaction.meta"
fi
```

`phase3_ready` 依序印出 `CLOCK-OK`、`SESSION-OK`、`START-INPUTS-FRESH`、`ETC-AS-PHASE1`、`SKYEYE-AS-PHASE1`，全部通過才執行 `setup-macos.sh`。任何一項是 `STOP:`，`if` 裡面什麼都不會執行：可能是時間不對、session 不對，或 Phase 1 之後有人改過檔案。STOP，主機沒有變更。

`setup-macos.sh` 先 stage 並驗證每個檔案（`bash -n`、`plutil -lint`、`alloy fmt`，以及把 staged `config.alloy` 與 `$ETC` 其他 `*.alloy` 一起跑 `alloy validate`），之後只替換有變動的檔案、restart Alloy、重新 bootstrap plist 有變動的 job。成功時的輸出（中間夾有 `brew services restart` 的 `Successfully stopped/started` 訊息）：

```
Validating the staged files
Alloy action: restart (no record of the config.env and extra-args.txt Alloy started with)
Rollback record: <brew-prefix>/var/skyeye-trading/install-backup/<UTC>-<pid>
Alloy: 1.18.1
Probe launchd label: com.wanbrain.skyeye-trading-probe
P&L history launchd label: com.wanbrain.skyeye-trading-pnl-history
Alloy config: <brew-prefix>/etc/alloy/config.alloy
Probe metrics: …/tnauqquant.prom
P&L history metrics: …/tnauqquant-pnl-history.prom
rc=0
```

`ENV-RECORD-PRESENT` 時，`Alloy action:` 會是 `reload (config.alloy changed; its environment did not)`，也是成功。`transaction.meta` 的 `status=committed`。

依 `rc` 判斷：

- **`rc=0`**：繼續下面的檢查。
- **`rc=1`，且訊息含 `nothing was changed` 或 `Nothing was changed`**：在替換任何檔案之前就拒絕了（版本、驗證、lock 被占用、job 狀態不符等）。`RECORD` 應為空。執行 `hash_skyeye | cmp - "$WORK/skyeye.before" && echo SKYEYE-AS-PHASE1` 確認，然後 STOP，把訊息交給 manager。
- **`rc=1`，且有 `install failed; files, Alloy and both launchd jobs are back to their state before this run`**：只會在 `ENV-RECORD-PRESENT` 時發生，installer 已經自己還原。確認 `SKYEYE-AS-PHASE1`、`jobs_state | cmp - "$WORK/jobs.before"`，ready 成功，然後 STOP。
- **`rc=3`，有 `CRITICAL: rollback_incomplete`**：這次 run 已經 restart Alloy 才失敗，installer 把自己的檔案放回、又 restart 了一次，但它沒有 `config.env` 的紀錄，所以一律回報還原未完成。`start_inputs_fresh` 與 `ETC-AS-PHASE1` 已經證明 `config.env`／`extra-args.txt` 就是 Alloy 原本啟動時的內容，所以人工恢復只剩 [R3](#r3--退回-phase-3)。**通知 Wan 與 manager**，馬上執行 R3（`RECORD` 是上面印出的那個 record，`status=rollback_incomplete`），然後 STOP。

Mac mini 檢查（`rc=0` 之後立即）：

```bash
inputs_same && echo ETC-INPUTS-SAME
for f in probe.sh pnl-history.sh; do cmp "$STAGE/agents/alloy/trading/$f" "$LIBEXEC/$f" || echo "STOP: $f"; done
cmp "$STAGE/agents/alloy/trading/config-macos.alloy.tmpl" "$ETC/config.alloy" && echo CONFIG-CURRENT
jobs_state | cmp - "$WORK/jobs.before" && echo JOBS-AS-PHASE1
curl -fsS "$(ready_url)"; echo                               # 成功
alloy_pid | tee "$WORK/alloy-pid.after"                      # 和 alloy-pid.before 不同（restart 過）
test -s "$STATE/installed-env.sha256" && echo ENV-RECORDED
alloy --version | head -n 1                                  # v1.18.1
tail -n 300 "$BP/var/log/alloy.err.log" | grep -E 'level=(error|warn)' | tail -n 20 | tee "$WORK/alloy-log.after"
sleep 30; textfile_values | tee "$WORK/textfile.after"
echo "now=$(date +%s)"
```

- `ETC-INPUTS-SAME`、`CONFIG-CURRENT`、`JOBS-AS-PHASE1`、`ENV-RECORDED` 都要印出，不能有 `STOP:`，ready 要成功。任何一項不符：執行 R3，然後 STOP。
- `textfile.after` 的 `tnauqquant_probe_timestamp_seconds` 必須在 `now` 的 60 秒內，否則執行 R3，然後 STOP。
- 其他 textfile 值和 `textfile.before` 不同時**不 rollback**：與 Phase 1 試跑的差異一致時，就是新 probe 報出的真實狀態。記錄下來，交給 tnauqquant manager。
- `alloy-log.after` 的 warn／error 只做紀錄，判斷以 Phase 4 為準。

## Phase 4 — 中央與 Loki 驗收 `[READ-ONLY]`

**monitoring-prod（Phase 3 之後 2–5 分鐘內）：**

```bash
mac_ages | tee "$CUT/ages.post.json"                       # probe < 60，history < 120
q 'trading_target_info unless on (product, environment, server_id, strategy) (time() - trading_strategy_probe_timestamp_seconds < 180)'   # []
mac_history_valid | tee "$CUT/history-valid.post.json"; diff "$CUT/history-valid.pre.json" "$CUT/history-valid.post.json" && echo HISTORY-VALID-SAME
mac_alerts | tee "$CUT/alerts.post.json"; diff "$CUT/alerts.pre.json" "$CUT/alerts.post.json" && echo ALERTS-SAME
```

- 5 分鐘內 `mac_ages` 仍不符，或 `unless` 查詢不是 `[]`：執行 R3，然後 STOP。
- 出現 `TradingTelemetryMissing`：執行 R3，然後 STOP。
- 沒有 `HISTORY-VALID-SAME`：`1` 變成 `0` 時執行 R3，然後 STOP；其他差異記錄下來交給 manager。
- 其他新告警（例如新 probe 報出的 `TradingProcessDown`、`TradingRunBindingInvalid`）：**不 rollback**，記錄下來交給 tnauqquant manager 判讀。

**Loki（Mac mini 先取證據）：**

```bash
log_evidence toobit-mexc-btc "$(cat "$WORK/phase3-epoch")" | tee "$WORK/loki-evidence.phase4"
```

≥ 60 秒後，把那一行 `loki_accept …`（例：`loki_accept toobit-mexc-btc 1763107262345000000 1763107200`）原樣貼到 monitoring-prod 執行。`log_evidence` 取的是來源 raw log 裡一個已經寫完的事件，`loki_accept` 要求 Loki 有同一個時間戳的行，之後才檢查 label 與 scrub，所以沒有收到任何 log 時不會通過。`SINCE` 是 Phase 3 開始的時間，因此 scrub 檢查只看新的 `config.alloy` 生效之後的行。

- `LOKI-ACCEPTED`：通過。
- `LOKI-PENDING`、`LOKI-MISSING` 或 `LOKI-ERROR`：等 2 分鐘，在 Mac mini 重跑上面那一行 `log_evidence`，≥ 60 秒後再貼一次，最多共三次。
  - 三次後仍是 `LOKI-MISSING`：log 有寫出，卻沒有進 Loki，是這次 rollout 造成的退步。執行 R3，然後 STOP。
  - 三次後仍是 `LOKI-PENDING`：Phase 3 之後策略沒有寫出新的 log 行（例如策略沒在跑），不是 Alloy 的問題。Loki 驗收記為 **PENDING**，照常繼續，依下面的後續驗收處理。
  - 三次後仍是 `LOKI-ERROR`：中央的 Loki 查詢失敗。STOP，把輸出交給 manager。
- `LOKI-LABELS` 或 `LOKI-UNSCRUBBED`：STOP，把輸出交給 manager。不要 R3：舊的 `config.alloy` 遮蔽得更少。

**PENDING 的後續驗收：** tnauqquant manager 回報策略已經執行並寫出 raw log 之後 24 小時內，由 SkyEye operator 做一次，結果補進 `docs/work-log.md`：

1. Mac mini：`/bin/bash`，`WORK=$(ls -d "$HOME"/skyeye-macmini-* | tail -n 1); . "$WORK/vars"; eval "$("$BREW_BIN" shellenv)"; . "$WORK/helpers.sh"`，執行 `log_evidence toobit-mexc-btc "$(cat "$WORK/phase3-epoch")"`。
2. ≥ 60 秒後在 monitoring-prod：`CUT="$HOME/macmini-rollout-<M7>"; . "$CUT/helpers.sh"`，貼上那一行。
3. `LOKI-ACCEPTED` 才結案。仍是 `LOKI-PENDING`，就等策略下一次執行再做。其他結果交給 manager。

## Phase 5 — 最終核對與收尾 `[READ-ONLY]`

Phase 4 之後 ≥ 10 分鐘。Mac mini：

```bash
tnauqquant_census | tee "$WORK/tnauqquant.after"
diff "$WORK/tnauqquant.before" "$WORK/tnauqquant.after" && echo TNAUQQUANT-SAME
jobs_state | cmp - "$WORK/jobs.before" && echo JOBS-FINAL
inputs_same && echo ETC-INPUTS-FINAL
alloy --version | head -n 1; alloy_pinned; brew list --versions "$FORMULA"   # v1.18.1、true、alloy 1.18.1
date -u +%FT%TZ | tee "$WORK/phase5-end"
```

**`TNAUQQUANT-SAME` 必須印出。** 沒有印出時，差異只可能來自 tnauqquant 自己的生命週期（例如策略跑完 `max_cycles` 自己結束、新的一輪寫出新的 manifest），因為本文件沒有任何命令作用於 tnauqquant。rollout 回報為**未完成**：把 diff 存成 `$WORK/tnauqquant.diff` 交給 manager 與 tnauqquant manager。不要 rollback（R3 只動 SkyEye，改變不了 tnauqquant），也不要碰任何 tnauqquant 的東西。

monitoring-prod：

```bash
mac_ages                                                   # probe < 60，history < 120
mac_alerts | tee "$CUT/alerts.final.json"                  # 與 Phase 4 判讀過的一致
```

Grafana：

- 「Trading · 策略總覽」（`https://grafana.wanbrain.com/d/trading-strategy-fleet`）的 `macmini-m2 / toobit-mexc-btc` 那一列有值，其他列不變。
- 「Trading · 策略詳情」（`https://grafana.wanbrain.com/d/trading-strategy-detail?var-server_id=macmini-m2&var-strategy=toobit-mexc-btc`）各 panel 有值，30 日累積 Real P&L 曲線沒有斷掉。

收尾：

- 把執行紀錄（下表）與 shadow 排除時窗（`phase3-start` 到 `phase5-end`）寫進 `docs/work-log.md`。
- `$WORK`、`$STAGE` 保留 7 天供 rollback，之後 `rm -rf "$WORK" "$STAGE"`。`$RECORD` 保留到下一次重跑 installer。
- 回報 manager 與 tnauqquant manager：Alloy 版本與 pin、probe 值有沒有變化、Loki 驗收結果（ACCEPTED／PENDING／FAILED）、census 是否完全相同。

## Rollback

| 失敗位置 | 動作 |
|---|---|
| Phase 1 | 沒有變更，STOP |
| Phase 2 檢查不符 | R2，然後 STOP |
| Phase 3 `rc=1` | installer 沒有改任何東西，或已自行還原；確認後 STOP |
| Phase 3 `rc=3` | R3，然後 STOP |
| Phase 3 `rc=0` 之後檢查失敗、Phase 4 的 R3 條件 | R3，然後 STOP |
| 要撤銷整個 rollout | R3，再 R2 |

### R2 — 撤銷 pin

```bash
if [ "$(cat "$WORK/pinned.before")" = false ]; then brew unpin "$FORMULA"; fi
alloy_pinned | cmp - "$WORK/pinned.before" && echo PIN-AS-PHASE1
```

Phase 1 時本來就已經 pin 的，維持 pin。`brew unpin` 只刪除 pin 紀錄，不碰 keg 與 service。

### R3 — 退回 Phase 3

把 Mac mini 還原成 Phase 2 結束時的狀態：Phase 3 前的 probe、P&L history、`config.alloy` 與 plist，Alloy 在這些檔案上重新啟動，兩個 SkyEye job 回到 `jobs.before` 的狀態。步驟寫在 Phase 1 的 `helpers.sh`（`r3_rollback`），`tests/trading/test-macmini-alloy-rollout.sh` 執行的就是同一段程式：

1. record 必須有 `present.list`、`absent.list` 與 `transaction.meta`。
2. `inputs_same`：`config.alloy` 以外的 `$ETC` 檔案（`config.env`、`extra-args.txt`…）必須與 Phase 1 相同，也沒有多出檔案。不符就停，一個檔案都沒還原，因為 restart 會套用沒人驗證過的內容。
3. 照 record 刪除 `absent.list` 的檔案、從 `previous/` 複製回 `present.list` 的檔案，然後要求五個 SkyEye 檔案與 `skyeye.before` 完全相同。
4. `alloy validate "$ETC"` 通過才 `brew services restart grafana/grafana/alloy`，並等連續兩次 ready。
5. probe 與 history job 依 `jobs.before` 重新 bootout／bootstrap／enable，最後狀態必須與 `jobs.before` 相同。

```bash
r3_rollback "$RECORD" 2>&1 | tee "$WORK/r3.log"; echo "rc=${PIPESTATUS[0]}"
```

成功時依序印出 `status=committed`（`rc=3` 之後是 `status=rollback_incomplete`）、`restored <RECORD>`、`FILES-AS-PHASE1`、`ALLOY-RESTARTED`、`JOBS-AS-PHASE1`、`rc=0`。接著：

```bash
hash_skyeye | cmp - "$WORK/skyeye.before" && echo SKYEYE-RESTORED
inputs_same && echo ETC-INPUTS-SAME
curl -fsS "$(ready_url)"; echo
```

monitoring-prod：`mac_ages` 回到 probe < 60、history < 120，`mac_alerts` 沒有 `TradingTelemetryMissing`。

`rc` 不是 0 時，`r3.log` 最後一行的 `STOP:` 說明停在哪裡。停手，執行 `jobs_state | tee "$WORK/jobs.r3-stop"`，把 `$WORK` 交給 manager 與 Wan：

- `STOP: incomplete record …` 或 `STOP: a file in … differs from Phase 1 …`：**一個檔案都沒還原**，Alloy 與 job 沒有被碰。等 manager 判斷。
- 其他 `STOP:`（檔案還原、`alloy validate`、restart、ready 或 job 載入失敗）：檔案已部分或全部還原。**不要重跑**，等 manager 判斷。

R3 不刪除 Phase 3 寫入的 `installed-env.sha256`。它記錄的是沒有變過的 `config.env`／`extra-args.txt`，下一次 installer 會因此改用 reload 而不是 restart。

## 執行紀錄

| 項目 | 時間（UTC） | 結果／record |
|---|---|---|
| Phase 0 staging | | `MERGE`、`TAR_SHA`、`PROBE_SHA`、`STAGE` |
| Phase 1 前置檢查 | | `WORK`、`CUT`、執行者（SSH operator 或 Wan 在 console）、`session-gate`、Alloy 版本、`pinned.before`、`env-keys.before` 與預期不同的地方、`render-compare`、census 裡本文件沒有預期的項目 |
| Phase 2 pin | | `ALREADY-PINNED` 或 pin 的時間 |
| Phase 3 setup-macos.sh | | `rc`、`RECORD`、`Alloy action`、`alloy-pid.before` → `alloy-pid.after`、textfile 差異 |
| Phase 4 中央與 Loki | | `ages.post.json`、告警差異、`loki_accept` 結果 |
| Phase 5 最終核對 | | `TNAUQQUANT-SAME`、Grafana 畫面、Loki 驗收：ACCEPTED／PENDING／FAILED |
| PENDING 後續驗收 | | `loki_accept` 的那一行與結果 |

Shadow／canary 證據要排除：`macmini-m2` 的 `phase3-start` – `phase5-end`。
