#!/usr/bin/env bash
#
# Rehearses the Mac mini rollout (docs/macmini-m2-alloy-rollout.md) on a fake
# Mac mini: Alloy 1.18.1 under a fake Homebrew prefix, the Trading monitoring
# installed by an older copy of setup-macos.sh (older probe and config, no env
# record), and a tnauqquant census with an unexpected launchd job. The host env
# comes from the checked-in deployment.env.example with only its paths moved
# into the sandbox.
#
# The runbook's Mac mini helpers.sh and monitoring-prod helpers.sh are taken
# from the runbook as written; only CONSOLE is pointed at a sandbox file. The
# Phase 0 staging block, the Phase 2 and Phase 3 `if` blocks, the Phase 4
# log_evidence line and the Phase 5 HISTORY-KEPT line are also run as written
# there. Phase 3 runs this checkout's setup-macos.sh. One fake Loki answers
# from a store of lines and honours each query's time range, so the Loki
# acceptance start is checked against lines the old Alloy shipped mid-install. Everything runs under /bin/bash with
# PATH=<sandbox>/bin only: brew, launchctl, curl, ps, tmux and pgrep are shims
# that keep their state in files, so no real service, launchd job or trading
# process is reachable. `alloy fmt` and `alloy validate` run the real binary.
#
# VERBOSE=1 also prints every check that passed.

# The single-quoted scripts are expanded on the fake Mac mini, not here.
# shellcheck disable=SC2016

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_DIR="$REPO_ROOT/agents/alloy"
RUNBOOK="$REPO_ROOT/docs/macmini-m2-alloy-rollout.md"
EXAMPLE="$AGENT_DIR/trading/deployment.env.example"
VERBOSE="${VERBOSE:-0}"
RUN_BASH=/bin/bash
PROBE_LABEL=com.wanbrain.skyeye-trading-probe
HISTORY_LABEL=com.wanbrain.skyeye-trading-pnl-history
STRATEGY=toobit-mexc-btc

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for tool in alloy jq perl plutil shasum "$RUN_BASH"; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required; this suite must not pass by skipping"
done
[[ "$(id -u)" -ne 0 ]] || fail 'run this suite as a normal user: the console-owner case needs a file root owns'
for required_file in "$RUNBOOK" "$EXAMPLE" "$AGENT_DIR/trading/setup-macos.sh"; do
  [[ -f "$required_file" ]] || fail "required file is missing: $required_file"
done
REAL_ALLOY="$(command -v alloy)"
REAL_DATE="$(command -v date)"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-macmini-rollout.XXXXXX")"
trap 'rm -rf "$WORK_ROOT"' EXIT

CASE=""
BOX=""
STAGE=""
RC=0
CHECKS=0
FAILURES=0

check() {
  local description="$1"
  shift
  CHECKS=$((CHECKS + 1))
  if "$@"; then
    if [[ "$VERBOSE" == "1" ]]; then
      printf 'ok: %s: %s\n' "$CASE" "$description"
    fi
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL: %s: %s\n' "$CASE" "$description"
    sed 's/^/    | /' "$BOX/log/out" 2>/dev/null | tail -n 20
  fi
}

# ───────────────────────────── Runbook text ─────────────────────────────────

heredoc_body() {
  awk -v open="$1" '$0 == open { on = 1; next } on && $0 == "EOF" { exit } on { print }' "$RUNBOOK"
}
# A block whose first line starts with the given text and that ends at the
# first line "fi".
runbook_block() {
  awk -v first="$1" '!on && index($0, first) == 1 { on = 1 } on { print } on && $0 == "fi" { exit }' "$RUNBOOK"
}

MAC_HELPERS="$WORK_ROOT/runbook-helpers.sh"
heredoc_body "cat >\"\$WORK/helpers.sh\" <<'EOF'" >"$MAC_HELPERS"
grep -qx 'CONSOLE=/dev/console[[:space:]]*#.*' "$MAC_HELPERS" || \
  fail 'the runbook helpers.sh no longer sets CONSOLE=/dev/console on a line of its own'
for helper in env_value outside_window session_gate alloy_pinned alloy_pid start_inputs_fresh \
  ready_url wait_ready jobs_state etc_files hash_etc hash_skyeye hash_inputs inputs_same \
  phase3_ready record_dirs new_record render_compare textfile_values tnauqquant_census \
  rfc3339_ns log_evidence r3_rollback; do
  grep -q "^$helper() {" "$MAC_HELPERS" || fail "the runbook helpers.sh does not define $helper"
done
CENTRAL_HELPERS="$WORK_ROOT/central-helpers.sh"
heredoc_body "cat >\"\$CUT/helpers.sh\" <<'EOF'" >"$CENTRAL_HELPERS"
grep -q '^loki_accept() {' "$CENTRAL_HELPERS" || fail 'the runbook monitoring-prod helpers.sh does not define loki_accept'

PHASE0_BLOCK="$(runbook_block 'S="$HOME/skyeye-staging/macmini-$M7"')"
PHASE2_BLOCK="$(runbook_block 'if outside_window; then')"
PHASE3_BLOCK="$(runbook_block 'if phase3_ready; then')"
PHASE4_EVIDENCE="$(grep -m 1 '^log_evidence toobit-mexc-btc ' "$RUNBOOK")"
HISTORY_KEPT="$(grep -m 1 '^jq -r -s ' "$RUNBOOK")"
[[ "$PHASE0_BLOCK" == *'tar -x -f'* && "$PHASE0_BLOCK" == *$'\nfi' ]] || \
  fail 'the runbook Phase 0 staging block was not found'
[[ -n "$PHASE4_EVIDENCE" ]] || fail 'the runbook Phase 4 log_evidence line was not found'
[[ "$HISTORY_KEPT" == *HISTORY-KEPT*HISTORY-UNVERIFIED ]] || fail 'the runbook Phase 5 HISTORY-KEPT line was not found'
[[ "$PHASE2_BLOCK" == *'brew pin "$FORMULA"'* && "$PHASE2_BLOCK" == *$'\nfi' ]] || \
  fail 'the runbook Phase 2 block was not found'
[[ "$PHASE3_BLOCK" == *'"$SETUP" </dev/null'* && "$PHASE3_BLOCK" == *$'\nfi' ]] || \
  fail 'the runbook Phase 3 block was not found'

# ─────────────────────────────── Sandbox ────────────────────────────────────

shim() {
  {
    printf '#!/bin/bash\n. "$BOX/shims.lib"\n'
    cat
  } >"$BOX/bin/$1"
  chmod 755 "$BOX/bin/$1"
}

write_shims() {
  cat >"$BOX/shims.lib" <<'EOF'
ctl="$BOX/ctl"
state="$BOX/state"
calls="$BOX/log/calls.log"
config="$BOX/brew/etc/alloy/config.alloy"
extra_args="$BOX/brew/etc/alloy/extra-args.txt"

# Which config.alloy a restart would load right now.
config_state() {
  if [ -e "$BOX/old-config" ] && cmp -s "$config" "$BOX/old-config"; then
    echo old
  else
    echo new
  fi
}

listen_port() {
  listen=""
  if [ -f "$extra_args" ]; then
    listen="$(tr '\n' ' ' <"$extra_args" | sed -n 's/.*--server[.]http[.]listen-addr[= ]\([^ ]*\).*/\1/p')"
  fi
  [ -n "$listen" ] || listen=127.0.0.1:12345
  echo "${listen##*:}"
}

version() {
  cat "$ctl/version" 2>/dev/null || echo 1.18.1
}
EOF

  shim sleep <<'EOF'
exit 0
EOF

  shim date <<'EOF'
if [ "$#" -eq 2 ] && [ "$1" = -u ] && [ "$2" = +%H%M ] && [ -e "$ctl/utc-hhmm" ]; then
  cat "$ctl/utc-hhmm"
  exit 0
fi
exec "$REAL_DATE" "$@"
EOF

  shim brew <<'EOF'
case "$1" in
  --prefix)
    echo "$BOX/brew"
    ;;
  info)
    echo "brew info $*" >>"$calls"
    pinned=false
    [ ! -e "$state/pinned" ] || pinned=true
    printf '{"formulae":[{"name":"alloy","full_name":"grafana/grafana/alloy","pinned":%s,"versions":{"stable":"1.21.3"},"installed":[{"version":"%s"}]}],"casks":[]}\n' \
      "$pinned" "$(version)"
    ;;
  list)
    echo "alloy $(version)"
    ;;
  pin)
    echo "brew pin $2" >>"$calls"
    touch "$state/pinned"
    ;;
  unpin)
    echo "brew unpin $2" >>"$calls"
    rm -f "$state/pinned"
    ;;
  services)
    case "$2" in
      info)
        if [ -e "$ctl/ssh-user-domain" ]; then
          echo 'Warning: running over SSH without /dev/console ownership, using user/* instead of gui/* domain!' >&2
        fi
        loaded=false
        running=false
        pid=null
        [ ! -e "$state/loaded_homebrew.mxcl.alloy" ] || loaded=true
        if [ -e "$state/ready" ]; then
          running=true
          pid="$(cat "$state/alloy-pid")"
        fi
        printf '[{"name":"alloy","service_name":"homebrew.mxcl.alloy","running":%s,"loaded":%s,"pid":%s,"file":"%s"}]\n' \
          "$running" "$loaded" "$pid" "$HOME/Library/LaunchAgents/homebrew.mxcl.alloy.plist"
        ;;
      restart)
        seen="$(config_state)"
        echo "brew services restart sees=$seen" >>"$calls"
        [ ! -e "$ctl/restart-fails" ] || exit 1
        # The old Alloy ships one more raw log line just before it stops.
        if [ -e "$ctl/log-on-restart" ]; then
          t="$("$REAL_DATE" +%s)"
          echo "$t" >"$state/old-line-epoch"
          printf 'time=%sZ level=INFO msg=old_pipeline client_id=abc123\n' \
            "$("$REAL_DATE" -u -r "$t" +%Y-%m-%dT%H:%M:%S)" >>"$(cat "$ctl/log-on-restart")"
        fi
        touch "$state/loaded_homebrew.mxcl.alloy"
        echo $(( $(cat "$state/alloy-pid" 2>/dev/null || echo 500) + 1 )) >"$state/alloy-pid"
        "$REAL_DATE" +%s >"$state/alloy-started"
        port="$(listen_port)"
        if [ -e "$ctl/unready-on-new" ] && [ "$seen" = new ]; then
          rm -f "$state/ready" "$state/port"
        else
          touch "$state/ready"
          echo "$port" >"$state/port"
        fi
        ;;
      stop)
        echo "brew services stop" >>"$calls"
        rm -f "$state/loaded_homebrew.mxcl.alloy" "$state/ready" "$state/port" "$state/alloy-pid"
        ;;
      *)
        echo "unexpected brew $*" >>"$calls"
        exit 2
        ;;
    esac
    ;;
  *)
    echo "unexpected brew $*" >>"$calls"
    exit 2
    ;;
esac
EOF

  # Only SkyEye's own labels may ever be booted out, bootstrapped or enabled.
  shim launchctl <<'EOF'
skyeye_label() {
  case "$1" in
    homebrew.mxcl.alloy | com.wanbrain.skyeye-trading-probe | com.wanbrain.skyeye-trading-pnl-history) return 0 ;;
  esac
  return 1
}
case "$1" in
  print)
    case "$2" in
      gui/*/*)
        label="${2##*/}"
        [ -e "$state/loaded_$label" ] || exit 113
        echo "gui/$(id -u)/$label = {"
        if [ "$label" = homebrew.mxcl.alloy ] && [ -e "$state/ready" ]; then
          printf '\tpid = %s\n' "$(cat "$state/alloy-pid")"
        fi
        echo "}"
        ;;
      gui/*)
        [ ! -e "$ctl/no-gui-domain" ] || exit 113
        echo "$2 = {"
        echo "}"
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  list)
    printf 'PID\tStatus\tLabel\n'
    cat "$ctl/launchctl-list" 2>/dev/null
    for loaded in "$state"/loaded_*; do
      [ -e "$loaded" ] && printf -- '-\t0\t%s\n' "${loaded##*/loaded_}"
    done
    ;;
  bootout)
    label="${2##*/}"
    skyeye_label "$label" || { echo "FORBIDDEN launchctl $*" >>"$calls"; exit 1; }
    echo "launchctl bootout $label" >>"$calls"
    [ -e "$state/loaded_$label" ] || exit 3
    rm -f "$state/loaded_$label"
    ;;
  bootstrap)
    label="$(basename "$3" .plist)"
    skyeye_label "$label" || { echo "FORBIDDEN launchctl $*" >>"$calls"; exit 1; }
    echo "launchctl bootstrap $label" >>"$calls"
    touch "$state/loaded_$label"
    ;;
  enable)
    label="${2##*/}"
    skyeye_label "$label" || { echo "FORBIDDEN launchctl $*" >>"$calls"; exit 1; }
    echo "launchctl enable $label" >>"$calls"
    ;;
  *)
    echo "FORBIDDEN launchctl $*" >>"$calls"
    exit 2
    ;;
esac
EOF

  shim curl <<'EOF'
url=""
for argument in "$@"; do
  case "$argument" in
    http://* | https://*) url="$argument" ;;
  esac
done
echo "curl $url" >>"$calls"
case "$url" in
  */-/ready)
    port="${url#http://}"
    port="${port%%/*}"
    port="${port##*:}"
    [ -e "$state/ready" ] || exit 7
    [ "$port" = "$(cat "$state/port" 2>/dev/null || echo 12345)" ] || exit 7
    ;;
  */-/reload)
    echo "alloy reload sees=$(config_state)" >>"$calls"
    echo 'config reloaded'
    ;;
  *)
    exit 2
    ;;
esac
EOF

  shim ps <<'EOF'
[ "$1 $2 $3" = "-o lstart= -p" ] || { echo "unexpected ps $*" >>"$calls"; exit 2; }
[ -e "$state/ready" ] && [ "$4" = "$(cat "$state/alloy-pid")" ] || exit 1
LC_ALL=C "$REAL_DATE" -r "$(cat "$state/alloy-started")" '+%a %b %e %T %Y'
EOF

  shim tmux <<'EOF'
[ "$1" = list-panes ] || { echo "FORBIDDEN tmux $*" >>"$calls"; exit 1; }
cat "$ctl/tmux-panes"
EOF

  shim pgrep <<'EOF'
[ "$1" = -lf ] || { echo "unexpected pgrep $*" >>"$calls"; exit 2; }
[ -s "$ctl/pgrep" ] || exit 1
cat "$ctl/pgrep"
EOF

  shim alloy <<'EOF'
case "$1" in
  --version)
    echo "alloy, version v$(version) (branch: HEAD, revision: shim)"
    ;;
  fmt | validate)
    echo "alloy $1" >>"$calls"
    exec "$REAL_ALLOY" "$@"
    ;;
  *)
    exit 1
    ;;
esac
EOF
}

# A Mac mini where an older setup-macos.sh installed and started everything.
new_box() {
  local tool past
  CASE="$1"
  BOX="$WORK_ROOT/$CASE"
  mkdir -p "$BOX/bin" "$BOX/ctl" "$BOX/state" "$BOX/log" "$BOX/tmp" "$BOX/work" \
    "$BOX/home/Library/LaunchAgents" "$BOX/brew/etc/alloy" "$BOX/brew/var/log" \
    "$BOX/repo/config" "$BOX/repo/logs/live-runs" "$BOX/repo/run-state/$STRATEGY" "$BOX/old" "$BOX/stage"
  chmod 700 "$BOX/work"
  for tool in awk basename cat chmod cmp comm cp cut diff dirname env find grep head id install ls \
    mkdir mktemp mv perl plutil rm sed shasum sort stat tail tar tee touch tr wc; do
    ln -s "$(command -v "$tool")" "$BOX/bin/$tool"
  done
  ln -s "$RUN_BASH" "$BOX/bin/bash"
  write_shims
  : >"$BOX/log/calls.log"
  : >"$BOX/console"

  mkdir -p "$BOX/stage/agents"
  cp -Rp "$AGENT_DIR" "$BOX/stage/agents/alloy"
  STAGE="$BOX/stage"
  cp -Rp "$STAGE/agents" "$BOX/old/agents"
  printf '\n# fixture: an older probe\n' >>"$BOX/old/agents/alloy/trading/probe.sh"
  printf '\n// fixture: an older config\n' >>"$BOX/old/agents/alloy/trading/config-macos.alloy.tmpl"

  sed -e "s#/Users/wan/projects/tnauqquant#$BOX/repo#g" \
    -e "s#/opt/homebrew/bin/tmux#$BOX/bin/tmux#" \
    -e "s#/opt/homebrew#$BOX/brew#g" \
    -e 's/replace-with-trading-service-token-id/sandbox-client.access/' \
    -e 's/replace-with-trading-service-token-secret/sandbox-secret-value/' \
    "$EXAMPLE" >"$BOX/brew/etc/alloy/config.env"
  chmod 600 "$BOX/brew/etc/alloy/config.env"
  : >"$BOX/brew/etc/alloy/extra-args.txt"
  printf 'instance_id: mexc-toobit-btc-initiator-hedge\n' >"$BOX/repo/config/toobit-mexc.yaml"
  printf '{"schema_version":1,"status":"running"}\n' >"$BOX/repo/run-state/$STRATEGY/current.json"

  # The older installer: started Alloy and both jobs, and kept no env record.
  (
    cd "$BOX" || exit 99
    exec env -i PATH="$BOX/bin" HOME="$BOX/home" TMPDIR="$BOX/tmp" BOX="$BOX" \
      REAL_ALLOY="$REAL_ALLOY" REAL_DATE="$REAL_DATE" \
      "$RUN_BASH" "$BOX/old/agents/alloy/trading/setup-macos.sh"
  ) </dev/null >"$BOX/log/old-install" 2>&1 || {
    cat "$BOX/log/old-install" >&2
    fail "$CASE: the older install failed"
  }
  rm -rf "$BOX/brew/var/skyeye-trading/install-backup" "$BOX/brew/var/skyeye-trading/installed-env.sha256"
  cp "$BOX/brew/etc/alloy/config.alloy" "$BOX/old-config"
  # Edited an hour before Alloy last started.
  past="$("$REAL_DATE" -r $(( $("$REAL_DATE" +%s) - 3600 )) +%Y%m%d%H%M.%S)"
  touch -t "$past" "$BOX/brew/etc/alloy/config.env" "$BOX/brew/etc/alloy/extra-args.txt"

  printf -- '-\t0\tcom.example.tnauqquant-unexpected\n' >"$BOX/ctl/launchctl-list"
  printf 'goexchange-sidecar 4100 node\ntoobit 4200 quant\n' >"$BOX/ctl/tmux-panes"
  printf '4201 %s/repo/quant live run --config %s/repo/config/toobit-mexc.yaml\n' "$BOX" "$BOX" >"$BOX/ctl/pgrep"
  echo 1000 >"$BOX/ctl/utc-hhmm"

  sed "s#^CONSOLE=/dev/console[[:space:]].*#CONSOLE=\"\$BOX/console\"#" "$MAC_HELPERS" >"$BOX/work/helpers.sh"
  : >"$BOX/log/calls.log"
}

# mac_sh SCRIPT: runs SCRIPT on the fake Mac mini after sourcing helpers.sh.
mac_sh() {
  (
    cd "$BOX" || exit 99
    exec env -i PATH="$BOX/bin" HOME="$BOX/home" TMPDIR="$BOX/tmp" BOX="$BOX" \
      REAL_ALLOY="$REAL_ALLOY" REAL_DATE="$REAL_DATE" WORK="$BOX/work" STAGE="$STAGE" \
      "$RUN_BASH" -c ". \"\$WORK/helpers.sh\" || exit 99
$1"
  ) </dev/null >"$BOX/log/out" 2>&1
  RC=$?
}

# The Phase 1 baseline commands.
baseline() {
  mac_sh '
jobs_state >"$WORK/jobs.before"
alloy_pid >"$WORK/alloy-pid.before"
alloy_pinned >"$WORK/pinned.before"
brew list --versions "$FORMULA" >"$WORK/brew-versions.before"
record_dirs >"$WORK/records.before"
etc_files >"$WORK/etc-list.before"
hash_etc >"$WORK/etc.before"
hash_inputs >"$WORK/etc-inputs.before"
hash_skyeye >"$WORK/skyeye.before"
tnauqquant_census >"$WORK/tnauqquant.before"
'
  [[ "$RC" -eq 0 ]] || { cat "$BOX/log/out" >&2; fail "$CASE: the Phase 1 baseline failed"; }
  : >"$BOX/log/calls.log"
}

# ─────────────────────────────── Assertions ─────────────────────────────────

rc_is() { [[ "$RC" -eq "$1" ]]; }
out_has() { grep -qF -- "$1" "$BOX/log/out"; }
out_lacks() { ! out_has "$1"; }
out_line() { grep -qxF -- "$1" "$BOX/log/out"; }
calls_lack() { ! grep -qE -- "$1" "$BOX/log/calls.log"; }
nothing_forbidden() { calls_lack '^FORBIDDEN'; }
no_service_change() { calls_lack '^(brew (pin|unpin|services (restart|stop))|launchctl (bootout|bootstrap|enable)|alloy reload)'; }
loaded() { [[ -e "$BOX/state/loaded_$1" ]]; }
alloy_ready() { [[ -e "$BOX/state/ready" ]]; }
pinned() { [[ -e "$BOX/state/pinned" ]]; }
work_file_is() { [[ "$(cat "$BOX/work/$1")" == "$2" ]]; }
skyeye_as_phase1() { mac_sh 'hash_skyeye | cmp -s - "$WORK/skyeye.before"'; rc_is 0; }
census_same() { mac_sh 'tnauqquant_census | cmp -s - "$WORK/tnauqquant.before"'; rc_is 0; }
config_is_new() { cmp -s "$BOX/brew/etc/alloy/config.alloy" "$STAGE/agents/alloy/trading/config-macos.alloy.tmpl"; }
config_is_old() { cmp -s "$BOX/brew/etc/alloy/config.alloy" "$BOX/old-config"; }
probe_is_new() { cmp -s "$BOX/brew/libexec/skyeye-trading/probe.sh" "$STAGE/agents/alloy/trading/probe.sh"; }
census_lists() { grep -qxF -- "$1" "$BOX/work/tnauqquant.before"; }
record_status() { grep -qx "status=$2" "$1/transaction.meta"; }

# ─────────────────────────────── Phase 0 ────────────────────────────────────

new_box phase1
CASE=phase0
M7_TEST=abc1234
mkdir -p "$BOX/tar-src/macmini-$M7_TEST/agents"
cp -Rp "$AGENT_DIR" "$BOX/tar-src/macmini-$M7_TEST/agents/alloy"
tar -c -f "$BOX/home/skyeye-alloy-$M7_TEST.tar" -C "$BOX/tar-src" "macmini-$M7_TEST"
TAR_SHA="$(shasum -a 256 "$BOX/home/skyeye-alloy-$M7_TEST.tar" | cut -c1-64)"
PROBE_SHA="$(shasum -a 256 "$AGENT_DIR/trading/probe.sh" | cut -c1-64)"
stage0() {
  mac_sh "M7=$M7_TEST; TAR_SHA=$TAR_SHA; PROBE_SHA=$PROBE_SHA
$PHASE0_BLOCK"
}
echo 1830 >"$BOX/ctl/utc-hhmm"
stage0
check 'staging inside the window: refused' out_has 'STOP: it is 1830 UTC'
check 'staging inside the window: nothing extracted' bash -c '! test -e "$1"' _ "$BOX/home/skyeye-staging"
check 'staging inside the window: the tar is kept' test -f "$BOX/home/skyeye-alloy-$M7_TEST.tar"
echo 1000 >"$BOX/ctl/utc-hhmm"
stage0
check 'staging outside the window' out_line STAGED
check 'staged probe.sh' cmp -s "$AGENT_DIR/trading/probe.sh" "$BOX/home/skyeye-staging/macmini-$M7_TEST/agents/alloy/trading/probe.sh"
check 'staged tar removed' bash -c '! test -e "$1"' _ "$BOX/home/skyeye-alloy-$M7_TEST.tar"
stage0
check 'staging twice: refused' out_has 'already exists'

# ─────────────────────────────── Phase 1 ────────────────────────────────────

CASE=phase1
baseline
check 'jobs.before: Alloy and both jobs loaded' work_file_is jobs.before \
  "homebrew.mxcl.alloy loaded
$PROBE_LABEL loaded
$HISTORY_LABEL loaded"
check 'brew versions recorded' work_file_is brew-versions.before 'alloy 1.18.1'
check 'not pinned yet' work_file_is pinned.before false
check 'no record before Phase 3' work_file_is records.before ''
check 'five SkyEye files hashed' [ "$(wc -l <"$BOX/work/skyeye.before" | tr -d ' ')" = 5 ]
check 'inputs exclude config.alloy' bash -c '! grep -q "/config\.alloy$" "$1" && grep -q "/config\.env$" "$1"' _ "$BOX/work/etc-inputs.before"
check 'census records the unexpected launchd job' census_lists 'com.example.tnauqquant-unexpected -'
check 'census records the sidecar pane' census_lists 'goexchange-sidecar 4100 node'
check 'census records the trading process' census_lists "4201 $BOX/repo/quant live run --config $BOX/repo/config/toobit-mexc.yaml"
check 'census records the manifest and the missing done marker' census_lists "absent $BOX/repo/run-state/$STRATEGY/current.done.json"
check 'census skips SkyEye jobs' bash -c '! grep -q "com[.]wanbrain[.]skyeye-" "$1"' _ "$BOX/work/tnauqquant.before"

mac_sh 'printf "%s|%s|%s\n" "$(env_value TQ_RAW_LOG_GLOB)" "$(env_value TQ_SERVER_ID)" "$(env_value TQ_REPO_ROOT_REGEX)"'
check 'env_value strips export and quotes' out_line "$BOX/repo/logs/live-runs/*.raw.log|macmini-m2|($BOX/repo)"

mac_sh 'session_gate'
check 'session gate passes' rc_is 0
check 'session gate tokens' bash -c 'grep -qx CONSOLE-OWNER "$1" && grep -qx GUI-DOMAIN "$1" && grep -qx ALLOY-IN-GUI-DOMAIN "$1" && grep -qx BREW-SERVICES-OK "$1"' _ "$BOX/log/out"
mac_sh 'CONSOLE=/dev/null; session_gate'
check 'console of another uid: refused' rc_is 1
check 'console of another uid: names user domain' out_has 'STOP: /dev/null belongs to uid 0'
touch "$BOX/ctl/ssh-user-domain"
mac_sh 'session_gate'
check 'brew services in user/*: refused' rc_is 1
check 'brew services in user/*: says so' out_has 'STOP: brew services uses the user/* domain in this session'
rm -f "$BOX/ctl/ssh-user-domain"
touch "$BOX/ctl/no-gui-domain"
mac_sh 'session_gate'
check 'no gui domain: refused' rc_is 1
check 'no gui domain: says so' out_has 'STOP: launchctl print gui/'
rm -f "$BOX/ctl/no-gui-domain"

for t in 1805 1814 1815 1929; do
  echo "$t" >"$BOX/ctl/utc-hhmm"
  mac_sh 'outside_window'
  check "$t UTC refused" rc_is 1
done
for t in 0000 0905 1804 1930; do
  echo "$t" >"$BOX/ctl/utc-hhmm"
  mac_sh 'outside_window'
  check "$t UTC allowed" out_line "CLOCK-OK $t UTC"
done
echo 1000 >"$BOX/ctl/utc-hhmm"

mac_sh 'start_inputs_fresh'
check 'start inputs fresh' out_has 'START-INPUTS-FRESH pid='
cp -p "$BOX/brew/etc/alloy/config.env" "$BOX/config.env.keep"
touch "$BOX/brew/etc/alloy/config.env"
mac_sh 'start_inputs_fresh'
check 'config.env edited after Alloy started: refused' rc_is 1
check 'config.env edited after Alloy started: named' out_has "STOP: $BOX/brew/etc/alloy/config.env changed at"
cp -p "$BOX/config.env.keep" "$BOX/brew/etc/alloy/config.env"

mac_sh 'render_compare'
check 'render compare passes' rc_is 0
check 'probe changes' out_line 'CHANGED probe.sh'
check 'history builder unchanged' out_line 'SAME pnl-history.sh'
check 'config changes' out_line 'CHANGED config.alloy'
check 'probe plist unchanged' out_line "SAME $PROBE_LABEL.plist"
check 'history plist unchanged' out_line "SAME $HISTORY_LABEL.plist"
check 'render made no service change' no_service_change
check 'nothing forbidden in Phase 1' nothing_forbidden

cp -Rp "$STAGE" "$BOX/stage-moved"
sed -i '' 's/server_id   = sys.env("TQ_SERVER_ID")/server_id   = sys.env("TQ_STRATEGY")/' \
  "$BOX/stage-moved/agents/alloy/trading/config-macos.alloy.tmpl"
STAGE="$BOX/stage-moved" mac_sh 'render_compare'
check 'a moved label: refused' rc_is 1
check 'a moved label: says so' out_has 'STOP: the new config.alloy changes a Loki label or the log path'

# ─────────────────────────────── Phase 2 / R2 ───────────────────────────────

CASE=phase2
echo 1830 >"$BOX/ctl/utc-hhmm"
mac_sh "$PHASE2_BLOCK"
check 'inside the window: not pinned' bash -c '! test -e "$1"' _ "$BOX/state/pinned"
check 'inside the window: brew pin not called' calls_lack '^brew pin'
echo 1000 >"$BOX/ctl/utc-hhmm"
mac_sh "$PHASE2_BLOCK
alloy_pinned
alloy_pid | cmp - \"\$WORK/alloy-pid.before\" && echo ALLOY-PID-SAME"
check 'pinned' pinned
check 'pin reported' out_line true
check 'pin left Alloy alone' out_line ALLOY-PID-SAME
: >"$BOX/log/calls.log"
echo 1830 >"$BOX/ctl/utc-hhmm"
mac_sh 'r2_unpin'
check 'R2 inside the window: refused' bash -c '[ "$1" -eq 1 ] && grep -qF "STOP: R2 waits until 19:30 UTC" "$2"' _ "$RC" "$BOX/log/out"
check 'R2 inside the window: still pinned' pinned
check 'R2 inside the window: brew unpin not called' calls_lack '^brew unpin'
echo 1000 >"$BOX/ctl/utc-hhmm"
mac_sh 'r2_unpin'
check 'R2 rc=0' rc_is 0
check 'R2 unpins' out_line PIN-AS-PHASE1
check 'R2 unpinned' bash -c '! test -e "$1"' _ "$BOX/state/pinned"
mac_sh "$PHASE2_BLOCK"
check 'pinned again' pinned

# ─────────────────────────────── Phase 3 ────────────────────────────────────

CASE=phase3
: >"$BOX/log/calls.log"
echo 1830 >"$BOX/ctl/utc-hhmm"
mac_sh "$PHASE3_BLOCK"
check 'inside the window: refused' out_has 'STOP: it is 1830 UTC'
check 'inside the window: setup not run' bash -c '! test -e "$1"' _ "$BOX/work/setup.out"
echo 1000 >"$BOX/ctl/utc-hhmm"
cp -p "$BOX/brew/libexec/skyeye-trading/probe.sh" "$BOX/probe.keep"
printf '# edited\n' >>"$BOX/brew/libexec/skyeye-trading/probe.sh"
mac_sh "$PHASE3_BLOCK"
check 'a SkyEye file changed since Phase 1: refused' out_has 'STOP: a file setup-macos.sh installs changed since Phase 1'
check 'a SkyEye file changed since Phase 1: setup not run' bash -c '! test -e "$1"' _ "$BOX/work/setup.out"
cp -p "$BOX/probe.keep" "$BOX/brew/libexec/skyeye-trading/probe.sh"
check 'refusals changed no service' no_service_change

PID_BEFORE="$(cat "$BOX/state/alloy-pid")"
mac_sh "$PHASE3_BLOCK"
check 'prechecks printed' bash -c 'for t in "CLOCK-OK 1000 UTC" SESSION-OK ETC-AS-PHASE1 SKYEYE-AS-PHASE1; do grep -qxF "$t" "$1" || exit 1; done' _ "$BOX/log/out"
check 'setup rc=0' out_line 'rc=0'
check 'restart for the missing env record' out_has 'Alloy action: restart (no record of the config.env and extra-args.txt Alloy started with)'
RECORD="$(sed -n 's/^RECORD=//p' "$BOX/log/out")"
check 'new record' [ -n "$RECORD" ]
check 'record committed' record_status "$RECORD" committed
check 'Alloy restarted once' [ "$(grep -c '^brew services restart' "$BOX/log/calls.log")" = 1 ]
check 'Alloy restarted on the new config' calls_lack 'sees=old'
check 'Alloy has a new pid' [ "$(cat "$BOX/state/alloy-pid")" != "$PID_BEFORE" ]
check 'config is current' config_is_new
check 'probe is current' probe_is_new
check 'plists untouched' calls_lack '^launchctl (bootout|bootstrap)'
mac_sh 'inputs_same && echo ETC-INPUTS-SAME
jobs_state | cmp - "$WORK/jobs.before" && echo JOBS-AS-PHASE1
test -s "$STATE/installed-env.sha256" && echo ENV-RECORDED
curl -fsS "$(ready_url)" && echo READY'
check 'Phase 3 checks pass' bash -c 'for t in ETC-INPUTS-SAME JOBS-AS-PHASE1 ENV-RECORDED READY; do grep -qx "$t" "$1" || exit 1; done' _ "$BOX/log/out"
check 'tnauqquant census unchanged' census_same
check 'nothing forbidden in Phase 3' nothing_forbidden

# ─────────────────────────────── R3 ─────────────────────────────────────────

CASE=r3
: >"$BOX/log/calls.log"
mac_sh 'r3_rollback "$BOX/no-such-record"'
check 'missing record: refused' rc_is 1
check 'missing record: says nothing was restored' out_has 'STOP: incomplete record'
cp -p "$BOX/brew/etc/alloy/config.env" "$BOX/config.env.keep"
printf 'export TQ_FIXTURE_EDIT=1\n' >>"$BOX/brew/etc/alloy/config.env"
mac_sh "r3_rollback '$RECORD'"
check 'edited config.env: refused' rc_is 1
check 'edited config.env: says nothing was restored' out_has 'differs from Phase 1; nothing was restored'
check 'edited config.env: config still new' config_is_new
cp -p "$BOX/config.env.keep" "$BOX/brew/etc/alloy/config.env"
printf 'stray\n' >"$BOX/brew/etc/alloy/stray.txt"
mac_sh "r3_rollback '$RECORD'"
check 'an extra file in etc: refused' rc_is 1
rm -f "$BOX/brew/etc/alloy/stray.txt"
check 'refusals changed no service' no_service_change

# A rollback inside the window or from a session that cannot manage gui/<uid>
# stops before it restores anything.
r3_refused() {
  local what="$1" message="$2"
  check "$what: refused" rc_is 1
  check "$what: says why" out_has "$message"
  check "$what: no service change" no_service_change
  check "$what: no file restored" config_is_new
  check "$what: probe not restored" probe_is_new
}
echo 1830 >"$BOX/ctl/utc-hhmm"
mac_sh "r3_rollback '$RECORD'"
r3_refused 'R3 inside the window' 'STOP: R3 waits until 19:30 UTC; nothing was restored'
echo 1814 >"$BOX/ctl/utc-hhmm"
mac_sh "r3_rollback '$RECORD'"
r3_refused 'R3 at 18:14 UTC' 'STOP: R3 waits until 19:30 UTC'
echo 1000 >"$BOX/ctl/utc-hhmm"
touch "$BOX/ctl/ssh-user-domain"
mac_sh "r3_rollback '$RECORD'"
r3_refused 'R3 with brew services in user/*' 'STOP: this session cannot manage gui/'
check 'R3 with brew services in user/*: names the domain' out_has 'STOP: brew services uses the user/* domain in this session'
rm -f "$BOX/ctl/ssh-user-domain"
mac_sh "CONSOLE=/dev/null; r3_rollback '$RECORD'"
r3_refused 'R3 with the console of another uid' 'Wan runs R3 at the console'
touch "$BOX/ctl/no-gui-domain"
mac_sh "r3_rollback '$RECORD'"
r3_refused 'R3 without the gui domain' 'STOP: launchctl print gui/'
rm -f "$BOX/ctl/no-gui-domain"
check 'R3 refusals: nothing forbidden' nothing_forbidden

mac_sh "r3_rollback '$RECORD'"
check 'R3 rc=0' rc_is 0
check 'R3 tokens' bash -c 'for t in "CLOCK-OK 1000 UTC" SESSION-OK status=committed FILES-AS-PHASE1 ALLOY-RESTARTED JOBS-AS-PHASE1; do grep -qxF "$t" "$1" || exit 1; done' _ "$BOX/log/out"
check 'files back to Phase 1' skyeye_as_phase1
check 'config is the old one again' config_is_old
check 'Alloy restarted on the old config' bash -c 'grep -q "^brew services restart sees=old" "$1"' _ "$BOX/log/calls.log"
check 'Alloy ready' alloy_ready
check 'probe job loaded' loaded "$PROBE_LABEL"
check 'history job loaded' loaded "$HISTORY_LABEL"
check 'tnauqquant census unchanged' census_same
check 'nothing forbidden in R3' nothing_forbidden

# ─────────────────────── Phase 3 rc=3, then R3 ──────────────────────────────

new_box critical
baseline
touch "$BOX/ctl/unready-on-new"
mac_sh "$PHASE3_BLOCK"
check 'setup rc=3' out_line 'rc=3'
check 'rollback_incomplete reported' out_has 'CRITICAL: rollback_incomplete: this run restarted Alloy because there is no record'
RECORD="$(sed -n 's/^RECORD=//p' "$BOX/log/out")"
check 'record kept' [ -n "$RECORD" ]
check 'record rollback_incomplete' record_status "$RECORD" rollback_incomplete
rm -f "$BOX/ctl/unready-on-new"
# Alloy stopped and unloaded (for example it went down after rc=3): the Phase 1
# gate refuses it, R3's gate does not, and R3 brings Alloy back.
mac_sh 'brew services stop "$FORMULA"'
mac_sh 'session_gate'
check 'Alloy stopped: the Phase 1 gate refuses' rc_is 1
mac_sh 'session_gate stopped-ok'
check 'Alloy stopped: the R3 gate accepts' bash -c '[ "$1" -eq 0 ] && grep -qx BREW-SERVICES-GUI "$2"' _ "$RC" "$BOX/log/out"
: >"$BOX/log/calls.log"
mac_sh "r3_rollback '$RECORD'"
check 'R3 after rc=3: rc=0' rc_is 0
check 'R3 after rc=3: tokens' bash -c 'for t in status=rollback_incomplete FILES-AS-PHASE1 ALLOY-RESTARTED JOBS-AS-PHASE1; do grep -qx "$t" "$1" || exit 1; done' _ "$BOX/log/out"
check 'R3 after rc=3: files back to Phase 1' skyeye_as_phase1
check 'R3 after rc=3: Alloy ready' alloy_ready
check 'R3 after rc=3: jobs loaded' bash -c 'test -e "$1" && test -e "$2"' _ "$BOX/state/loaded_$PROBE_LABEL" "$BOX/state/loaded_$HISTORY_LABEL"
check 'R3 after rc=3: census unchanged' census_same
check 'R3 after rc=3: nothing forbidden' nothing_forbidden

# ─────────────────────────── Census diff ────────────────────────────────────

CASE=census
printf 'goexchange-sidecar 4100 node\ntoobit 4300 quant\n' >"$BOX/ctl/tmux-panes"
mac_sh 'tnauqquant_census | diff "$WORK/tnauqquant.before" - && echo TNAUQQUANT-SAME'
check 'a restarted pane is a difference' out_lacks TNAUQQUANT-SAME
check 'the diff names it' out_has '> toobit 4300 quant'
printf 'goexchange-sidecar 4100 node\ntoobit 4200 quant\n' >"$BOX/ctl/tmux-panes"
printf '{"schema_version":1,"status":"done"}\n' >"$BOX/repo/run-state/$STRATEGY/current.json"
mac_sh 'tnauqquant_census | diff "$WORK/tnauqquant.before" - && echo TNAUQQUANT-SAME'
check 'a rewritten manifest is a difference' out_lacks TNAUQQUANT-SAME
: >"$BOX/ctl/pgrep"
printf '{"schema_version":1,"status":"running"}\n' >"$BOX/repo/run-state/$STRATEGY/current.json"
mac_sh 'tnauqquant_census | diff "$WORK/tnauqquant.before" - && echo TNAUQQUANT-SAME'
check 'a vanished process is a difference' out_lacks TNAUQQUANT-SAME

# ─────────────────────────── log_evidence ───────────────────────────────────

CASE=log-evidence
now="$("$REAL_DATE" +%s)"
local_time() { "$REAL_DATE" -u -r "$(( $1 + 28800 ))" +%Y-%m-%dT%H:%M:%S; }
{
  printf 'time=%s.1+08:00 level=INFO msg=older\n' "$(local_time "$((now - 90))")"
  printf 'time="%s.25+08:00" level=INFO msg=pnl_status client_id=[ORDER_REF]\n' "$(local_time "$((now - 30))")"
  printf 'time=%s.5+08:00 level=INFO msg=partial' "$(local_time "$((now - 1))")"
} >"$BOX/repo/logs/live-runs/20261114_000000_toobit-mexc.raw.log"
mac_sh "log_evidence $STRATEGY $((now - 300))"
check 'evidence is the last finished line in epoch ns' out_line "loki_accept $STRATEGY $((now - 30))250000000 $((now - 300))"
mac_sh "log_evidence $STRATEGY $((now - 10))"
check 'an event older than SINCE is not evidence' out_line "loki_accept $STRATEGY none $((now - 10))"
printf 'time=%sZ level=INFO msg=a\ntime=%s.123456789Z level=INFO msg=b\nx' \
  "$("$REAL_DATE" -u -r "$((now - 20))" +%Y-%m-%dT%H:%M:%S)" \
  "$("$REAL_DATE" -u -r "$((now - 5))" +%Y-%m-%dT%H:%M:%S)" \
  >"$BOX/repo/logs/live-runs/20261114_000100_toobit-mexc.raw.log"
touch -t "$("$REAL_DATE" -r "$((now + 60))" +%Y%m%d%H%M.%S)" "$BOX/repo/logs/live-runs/20261114_000100_toobit-mexc.raw.log"
mac_sh "log_evidence $STRATEGY $((now - 300))"
check 'the newest raw log, UTC with nanoseconds' out_line "loki_accept $STRATEGY $((now - 5))123456789 $((now - 300))"
mac_sh "log_evidence popdex-btc $((now - 300))"
check 'another strategy: refused' rc_is 1
# A finished last line is the evidence even when the line before it is older than SINCE.
rm -f "$BOX"/repo/logs/live-runs/*.raw.log
{
  printf 'time=%s.1+08:00 level=INFO msg=older\n' "$(local_time "$((now - 90))")"
  printf 'time=%s.75+08:00 level=INFO msg=newer\n' "$(local_time "$((now - 30))")"
} >"$BOX/repo/logs/live-runs/20261114_000200_toobit-mexc.raw.log"
mac_sh "log_evidence $STRATEGY $((now - 60))"
check 'a finished new last line after an old one is evidence' out_line "loki_accept $STRATEGY $((now - 30))750000000 $((now - 60))"
# An unfinished tail is skipped: the finished line before it is the evidence.
printf 'time=%s.5+08:00 level=INFO msg=partial' "$(local_time "$((now - 1))")" \
  >>"$BOX/repo/logs/live-runs/20261114_000200_toobit-mexc.raw.log"
mac_sh "log_evidence $STRATEGY $((now - 60))"
check 'an unfinished tail is skipped' out_line "loki_accept $STRATEGY $((now - 30))750000000 $((now - 60))"
# An unfinished line appended while log_evidence reads the file does not
# replace the finished line it saw.
rm -f "$BOX"/repo/logs/live-runs/*.raw.log
printf 'time=%s.75+08:00 level=INFO msg=newer\n' "$(local_time "$((now - 30))")" \
  >"$BOX/repo/logs/live-runs/20261114_000250_toobit-mexc.raw.log"
printf 'time=%s.5+08:00 level=INFO msg=partial' "$(local_time "$((now - 1))")" >"$BOX/ctl/append-after-tail"
rm -f "$BOX/bin/tail"
{
  printf '#!/bin/bash\n'
  printf '"%s" "$@"\nrc=$?\n' "$(command -v tail)"
  cat <<'EOF'
# After the first read of a raw log, the strategy appends an unfinished line.
if [ -e "$BOX/ctl/append-after-tail" ]; then
  for last; do :; done
  case "$last" in
    *.raw.log) cat "$BOX/ctl/append-after-tail" >>"$last"; rm -f "$BOX/ctl/append-after-tail" ;;
  esac
fi
exit "$rc"
EOF
} >"$BOX/bin/tail"
chmod 755 "$BOX/bin/tail"
mac_sh "log_evidence $STRATEGY $((now - 60))"
check 'an unfinished line appended between reads is skipped' out_line "loki_accept $STRATEGY $((now - 30))750000000 $((now - 60))"
check 'the unfinished line was appended during the read' bash -c '! test -e "$1"' _ "$BOX/ctl/append-after-tail"
rm -f "$BOX/bin/tail"
ln -s "$(command -v tail)" "$BOX/bin/tail"
# A file holding only an unfinished line has no evidence.
rm -f "$BOX"/repo/logs/live-runs/*.raw.log
printf 'time=%s.5+08:00 level=INFO msg=partial' "$(local_time "$((now - 1))")" \
  >"$BOX/repo/logs/live-runs/20261114_000300_toobit-mexc.raw.log"
mac_sh "log_evidence $STRATEGY $((now - 60))"
check 'only an unfinished line: none' out_line "loki_accept $STRATEGY none $((now - 60))"
rm -f "$BOX"/repo/logs/live-runs/*.raw.log
mac_sh "log_evidence $STRATEGY $((now - 300))"
check 'no raw log: none' out_line "loki_accept $STRATEGY none $((now - 300))"

# ─────────────────────────── loki_accept ────────────────────────────────────

CASE=loki-accept
CENTRAL_BIN="$WORK_ROOT/central-bin"
LOKI="$WORK_ROOT/loki"
mkdir -p "$CENTRAL_BIN" "$LOKI"
# scrub_count QUERY LINES_FILE: answers a Loki scrub query from a file of lines.
# The regex is taken from the query as loki_accept sent it and run with rg,
# whose syntax matches the RE2 subset the runbook uses.
cat >"$LOKI/scrub-count.sh" <<'EOF'
scrub_count() {
  local query="$1" lines="$2" re n
  re="${query#*\`}"
  re="${re%\`*}"
  [ -n "$re" ] && [ "$re" != "$query" ] || return 22
  n="$(rg -c -e "$re" -- "$lines")"
  case $? in 0) ;; 1) n=0 ;; *) return 22 ;; esac
  if [ "$n" -eq 0 ]; then
    echo '{"status":"success","data":{"resultType":"vector","result":[]}}'
  else
    printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[0,"%s"]}]}}\n' "$n"
  fi
}
EOF
# With $LOKI/lines present, the scrub query is answered from those lines.
cat >"$CENTRAL_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOKI/calls.log"
case "$*" in
  *127.0.0.1:9090/api/v1/query*) cat "$LOKI/prom.json" ;;
  */loki/api/v1/query_range*) cat "$LOKI/range.json" ;;
  */loki/api/v1/series*) cat "$LOKI/series.json" ;;
  */loki/api/v1/query*)
    [ -e "$LOKI/lines" ] || { cat "$LOKI/count.json"; exit 0; }
    . "$LOKI/scrub-count.sh"
    for a; do case "$a" in query=*) query="${a#query=}" ;; esac; done
    scrub_count "$query" "$LOKI/lines"
    ;;
  *) exit 22 ;;
esac
EOF
chmod 755 "$CENTRAL_BIN/curl"
export LOKI
# central_run CMD...: runs a monitoring-prod helper against the fake curl.
central_run() {
  (
    PATH="${ACCEPT_BIN:-$CENTRAL_BIN}:$PATH"
    # shellcheck source=/dev/null
    . "$CENTRAL_HELPERS"
    "$@"
  )
}
accept() {
  : >"$LOKI/calls.log"
  central_run loki_accept "$@" >"$BOX/log/out" 2>&1
  RC=$?
}
loki_answers() {
  printf '%s\n' "$1" >"$LOKI/range.json"
  printf '%s\n' "$2" >"$LOKI/series.json"
  printf '%s\n' "$3" >"$LOKI/count.json"
}
ns="$((now - 30))250000000"
since="$((now - 300))"
stream='{"environment":"production","level":"INFO","product":"tnauqquant","run_id":"20261114_000000_toobit-mexc","server_id":"macmini-m2","strategy":"toobit-mexc-btc"}'
found_range="{\"status\":\"success\",\"data\":{\"resultType\":\"streams\",\"result\":[{\"stream\":$stream,\"values\":[[\"$ns\",\"client_id=[ORDER_REF]\"]]}]}}"
empty_range='{"status":"success","data":{"resultType":"streams","result":[]}}'
good_series="{\"status\":\"success\",\"data\":[$(jq -c '. + {service_name: "tnauqquant"}' <<<"$stream")]}"
extra_series="{\"status\":\"success\",\"data\":[$(jq -c '. + {order_id: "123"}' <<<"$stream")]}"
no_count='{"status":"success","data":{"resultType":"vector","result":[]}}'
hit_count='{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[0,"2"]}]}}'

loki_answers "$found_range" "$good_series" "$no_count"
accept "$STRATEGY" "$ns" "$since"
check 'the source event is accepted' bash -c '[ "$1" -eq 0 ] && grep -q "^LOKI-ACCEPTED toobit-mexc-btc:" "$2"' _ "$RC" "$BOX/log/out"
check 'the selector is macmini-m2' grep -qF 'server_id="macmini-m2",strategy="toobit-mexc-btc"' "$LOKI/calls.log"
check 'the scrub check starts at SINCE' grep -qF "start=$since" "$LOKI/calls.log"
loki_answers "$empty_range" "$good_series" "$no_count"
accept "$STRATEGY" "$ns" "$since"
check 'an empty stream is MISSING' bash -c '[ "$1" -eq 1 ] && grep -q "^LOKI-MISSING " "$2"' _ "$RC" "$BOX/log/out"
check 'no label or scrub check without the event' [ "$(grep -c . "$LOKI/calls.log")" = 1 ]
loki_answers "$found_range" "$extra_series" "$no_count"
accept "$STRATEGY" "$ns" "$since"
check 'an extra label fails' out_line 'LOKI-LABELS toobit-mexc-btc: unexpected labels ["order_id"]'
loki_answers "$found_range" "$good_series" "$hit_count"
accept "$STRATEGY" "$ns" "$since"
check 'an unscrubbed ID fails' out_has 'LOKI-UNSCRUBBED toobit-mexc-btc:'
accept "$STRATEGY" none "$since"
check 'no source event is PENDING' bash -c '[ "$1" -eq 2 ] && grep -q "^LOKI-PENDING " "$2"' _ "$RC" "$BOX/log/out"
# The scrub check on lines as they reach Loki. Empty values and the scrubber's
# [ORDER_REF] (bare or quoted) are not IDs; any other value is. The first line
# is the only hit of this rollout on 2026-11-14 (a false LOKI-UNSCRUBBED).
scrub_case() {
  printf '%s\n' "$3" >"$LOKI/lines"
  accept "$STRATEGY" "$ns" "$since"
  rm -f "$LOKI/lines"
  case "$2" in
    clean) check "$1: not an ID" bash -c '[ "$1" -eq 0 ] && grep -q "^LOKI-ACCEPTED toobit-mexc-btc:" "$2"' _ "$RC" "$BOX/log/out" ;;
    leak) check "$1: an ID" bash -c '[ "$1" -eq 1 ] && grep -q "^LOKI-UNSCRUBBED toobit-mexc-btc:" "$2"' _ "$RC" "$BOX/log/out" ;;
  esac
}
loki_answers "$found_range" "$good_series" "$no_count"
scrub_case 'order_id="" (11-14)' clean \
  'time=2026-11-14T10:18:31.848Z level=INFO msg=coordinated_dispatch_result order_id="" status=ok'
scrub_case 'order_id= then a space' clean 'order_id= status=ok'
scrub_case 'order_id= at the end' clean 'order_id='
scrub_case 'bare [ORDER_REF]' clean 'msg=pnl_status client_id=[ORDER_REF]'
scrub_case 'quoted [ORDER_REF]' clean 'order_id="[ORDER_REF]" orderId=[ORDER_REF], ack_client_id=[ORDER_REF]'
scrub_case 'bare [ORDER_REF] closing an enclosing quote' clean 'msg="dispatch order_id=[ORDER_REF]" status=ok'
scrub_case 'bare [ORDER_REF] before , ; ) } ]' clean \
  'order_id=[ORDER_REF]; client_id=[ORDER_REF]) clientId=[ORDER_REF]} orderId=[ORDER_REF]]'
scrub_case 'quoted client_id' leak 'msg=coordinated_dispatch_result client_id="tq0123456789abcdefghij"'
scrub_case 'bare client_id' leak 'msg=coordinated_dispatch_result client_id=tq0123456789abcdefghij'
scrub_case 'an ID after an empty value' leak 'order_id="" clientId=tq0123456789abcdefghij'
scrub_case 'a raw value that starts with [' leak 'order_id=[[FAKE-ORDER-0318A FAKE-ORDER-0318B] [FAKE-ORDER-0318C]]'
scrub_case 'an unterminated [ORDER_REF' leak 'client_action_id="[ORDER_REF"'
scrub_case 'a value cut inside [ORDER_RE' leak 'order_id=[ORDER_RE'
scrub_case 'quoted [ORDER_REF] then content' leak 'client_id="[ORDER_REF]tq123"'
scrub_case 'bare [ORDER_REF] then content' leak 'client_id=[ORDER_REF]tq123'
scrub_case 'quoted [ORDER_REF], a space, content' leak 'order_id="[ORDER_REF] tq123"'
scrub_case 'quoted [ORDER_REF], a comma, content' leak 'order_id="[ORDER_REF],tq123"'

# ─────────────────────────── P&L history (Phase 5) ──────────────────────────

CASE=history
CUT_DIR="$WORK_ROOT/cut"
mkdir -p "$CUT_DIR"
prom_history() {
  jq -n -c --arg cycles "$1" --arg first "$2" --arg current "$3" '
    def m($n; $v): {metric: {__name__: ("tnauqquant_pnl_history_" + $n), product: "tnauqquant",
      server_id: "macmini-m2", strategy: "toobit-mexc-btc"}, value: [1763107200, $v]};
    {status: "success", data: {resultType: "vector", result: [m("valid"; "1"), m("cached_cycles"; $cycles),
      m("first_supported_event_timestamp_seconds"; $first), m("current_value_usdt"; $current)]}}' >"$LOKI/prom.json"
}
mac_history_to() {
  : >"$LOKI/calls.log"
  central_run mac_history >"$CUT_DIR/$1" 2>/dev/null
}
history_kept() { CUT="$CUT_DIR" bash -c "$HISTORY_KEPT" >"$BOX/log/out" 2>&1; }
prom_history 42 1762000000 12.5
mac_history_to history.pre.json
check 'mac_history names each history metric' [ "$(cat "$CUT_DIR/history.pre.json")" = \
  '{"cached_cycles":"42","current_value_usdt":"12.5","first_supported_event_timestamp_seconds":"1762000000","valid":"1"}' ]
check 'mac_history queries macmini-m2' grep -qF 'server_id="macmini-m2"' "$LOKI/calls.log"
prom_history 43 1762000000 13.75
mac_history_to history.final.json
history_kept
check 'one more cycle: history kept' out_line HISTORY-KEPT
prom_history 41 1762000000 12.5
mac_history_to history.final.json
history_kept
check 'fewer cycles: history changed' out_line HISTORY-CHANGED
prom_history 42 1762500000 12.5
mac_history_to history.final.json
history_kept
check 'a later first cycle: history changed' out_line HISTORY-CHANGED
# Empty or failed snapshots prove nothing.
empty_prom='{"status":"success","data":{"resultType":"vector","result":[]}}'
printf '%s\n' "$empty_prom" >"$LOKI/prom.json"
mac_history_to history.pre.json
mac_history_to history.final.json
history_kept
check 'two empty snapshots: unverified' out_line HISTORY-UNVERIFIED
prom_history 42 1762000000 12.5
mac_history_to history.pre.json
printf '%s\n' "$empty_prom" >"$LOKI/prom.json"
mac_history_to history.final.json
history_kept
check 'an empty final snapshot: unverified' out_line HISTORY-UNVERIFIED
rm -f "$LOKI/prom.json"
mac_history_to history.final.json
history_kept
check 'a failed final query: unverified' out_line HISTORY-UNVERIFIED
printf '{"cached_cycles":"42","valid":"1"}\n' >"$CUT_DIR/history.final.json"
history_kept
check 'valid=1 without the first cycle time: unverified' out_line HISTORY-UNVERIFIED
printf '{"cached_cycles":"0","valid":"0"}\n' | tee "$CUT_DIR/history.pre.json" >"$CUT_DIR/history.final.json"
history_kept
check 'valid=0 on both sides without a first cycle time: kept' out_line HISTORY-KEPT

# ──────────── Loki acceptance start: old lines during the installer ─────────

# The old Alloy ships an unscrubbed line after the installer started but before
# it switched config.alloy. The Loki acceptance start must exclude it, both for
# the source evidence and for the scrub check.
new_box loki-switch
baseline
RAW="$BOX/repo/logs/live-runs/20261114_010000_toobit-mexc.raw.log"
: >"$RAW"
echo "$RAW" >"$BOX/ctl/log-on-restart"
mac_sh "$PHASE3_BLOCK"
check 'setup rc=0' out_line 'rc=0'
check 'the old Alloy shipped a line during the installer' test -s "$BOX/state/old-line-epoch"
OLD_EPOCH="$(cat "$BOX/state/old-line-epoch" 2>/dev/null || echo 0)"
LOKI_SINCE="$(sed -n 's/^LOKI-SINCE //p' "$BOX/log/out")"
check 'LOKI-SINCE printed after the installer' [ -n "$LOKI_SINCE" ]
check 'loki-since is recorded' bash -c '[ -n "$2" ] && [ "$(cat "$1")" = "$2" ]' _ "$BOX/work/loki-since" "$LOKI_SINCE"
check 'loki-since is after the switch second' [ "${LOKI_SINCE:-0}" -gt "$OLD_EPOCH" ]
LOKI_SINCE="${LOKI_SINCE:-$(( $("$REAL_DATE" +%s) + 1 ))}"
OLD_LINE="$(head -n 1 "$RAW")"
mac_sh "$PHASE4_EVIDENCE"
check 'only the old pipeline wrote a line: no evidence yet' out_line "loki_accept $STRATEGY none $LOKI_SINCE"
NEW_LINE="time=$("$REAL_DATE" -u -r "$LOKI_SINCE" +%Y-%m-%dT%H:%M:%S)Z level=INFO msg=new_pipeline client_id=[ORDER_REF]"
printf '%s\n' "$NEW_LINE" >>"$RAW"
mac_sh "$PHASE4_EVIDENCE"
check 'the evidence is the line after the switch' out_line "loki_accept $STRATEGY ${LOKI_SINCE}000000000 $LOKI_SINCE"
read -r _ EV_STRATEGY EV_NS EV_SINCE < <(grep -m 1 '^loki_accept ' "$BOX/log/out" || echo "x x x x")

# A Loki that answers from a store of "NS<TAB>LINE" and honours the time range
# of every query, holding what both pipelines shipped.
STORE_BIN="$WORK_ROOT/store-bin"
mkdir -p "$STORE_BIN"
cat >"$STORE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOKI/calls.log"
arg() {
  local name="$1" a
  shift
  for a in "$@"; do
    case "$a" in "$name="*) printf '%s\n' "${a#"$name="}"; return ;; esac
  done
}
case "$*" in
  */loki/api/v1/query_range*)
    start="$(arg start "$@")"
    end="$(arg end "$@")"
    while IFS=$'\t' read -r ns line; do
      if [ "$ns" -ge "$start" ] && [ "$ns" -le "$end" ]; then printf '%s\t%s\n' "$ns" "$line"; fi
    done <"$LOKI/store" |
      jq -R -s -c --argjson stream "$STREAM" \
        '{status: "success", data: {resultType: "streams", result: [{stream: $stream,
          values: (split("\n") | map(select(length > 0) | split("\t")))}]}}'
    ;;
  */loki/api/v1/series*)
    printf '{"status":"success","data":[%s]}\n' "$STREAM"
    ;;
  */loki/api/v1/query*)
    query="$(arg query "$@")"
    range="${query##*[}"
    range="${range%%s]*}"
    from=$(( $(date +%s) - range ))
    while IFS=$'\t' read -r ns line; do
      [ $(( ns / 1000000000 )) -lt "$from" ] || printf '%s\n' "$line"
    done <"$LOKI/store" >"$LOKI/store-lines"
    . "$LOKI/scrub-count.sh"
    scrub_count "$query" "$LOKI/store-lines"
    ;;
  *) exit 22 ;;
esac
EOF
chmod 755 "$STORE_BIN/curl"
export STREAM="$stream"
printf '%s000000000\t%s\n%s000000000\t%s\n' "$OLD_EPOCH" "$OLD_LINE" "$LOKI_SINCE" "$NEW_LINE" >"$LOKI/store"
ACCEPT_BIN="$STORE_BIN" accept "$EV_STRATEGY" "$EV_NS" "$EV_SINCE"
check 'the evidence after the switch is accepted' bash -c '[ "$1" -eq 0 ] && grep -q "^LOKI-ACCEPTED toobit-mexc-btc:" "$2"' _ "$RC" "$BOX/log/out"
ACCEPT_BIN="$STORE_BIN" accept "$STRATEGY" "${LOKI_SINCE}000000000" "$OLD_EPOCH"
check 'a SINCE before the switch sees the old line unscrubbed' out_has 'LOKI-UNSCRUBBED toobit-mexc-btc:'

if [[ "$FAILURES" -ne 0 ]]; then
  printf 'FAIL: Mac mini rollout rehearsal: %s of %s checks failed\n' "$FAILURES" "$CHECKS"
  exit 1
fi
printf 'PASS: Mac mini rollout rehearsal: %s checks\n' "$CHECKS"
