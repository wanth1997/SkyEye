#!/usr/bin/env bash
set -euo pipefail

# Behavior tests for agents/alloy/trading/account-linux.sh (dispatched via
# setup-linux.sh account) and the operator wrapper scripts/trading-account.
# Uses SKYEYE_TRADING_TEST_ROOT and stub binaries so no real host or SSH target
# is ever touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRADING_DIR="$REPO_ROOT/agents/alloy/trading"
SETUP="$TRADING_DIR/setup-linux.sh"
ACCOUNT_HOST="$TRADING_DIR/account-linux.sh"
WRAPPER="$REPO_ROOT/scripts/trading-account"
README="$TRADING_DIR/README.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local path="$1" pattern="$2"
  rg -q -- "$pattern" "$path" || fail "$path does not contain pattern: $pattern"
}

assert_not_contains() {
  local path="$1" pattern="$2"
  if rg -q -- "$pattern" "$path"; then
    fail "$path contains forbidden pattern: $pattern"
  fi
}

sha_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# Set up isolated test root and ALL stubs (including SSH stub via absolute
# SKYEYE_SSH_BIN) BEFORE invoking wrapper or host scripts even once (C11).
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-trading-account-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
BG_PIDS=()
cleanup() {
  local pid
  for pid in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

SYSTEM_ROOT="$TEST_ROOT"
FAKE_BIN="$TEST_ROOT/fake-bin"
FAKE_REPO="$TEST_ROOT/tnauqquant"
TEXTFILE_DIR="$TEST_ROOT/textfile"
SYSTEMCTL_STATE="$TEST_ROOT/systemctl-state"
SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
SYSTEMCTL_LOG_ALL="$TEST_ROOT/systemctl-all.log"
SSH_LOG="$TEST_ROOT/ssh.log"
TAR_CAPTURE="$TEST_ROOT/received.tar"
REMOTE_STAGING_PARENT="$TEST_ROOT/remote-tmp"

CURRENT_USER="$(id -un)"
CURRENT_GROUP="$(id -gn)"
MULTI_STRAT="popdex-multi-accounts"
SIBLING_STRAT="lighter-robinhood-btc-canary"
MULTI_EXCH_STRAT="toobit-mexc-btc"

mkdir -p \
  "$SYSTEM_ROOT/etc/alloy" \
  "$SYSTEM_ROOT/etc/default" \
  "$SYSTEM_ROOT/etc/skyeye-trading" \
  "$SYSTEM_ROOT/etc/systemd/system/timers.target.wants" \
  "$FAKE_BIN" \
  "$SYSTEMCTL_STATE" \
  "$REMOTE_STAGING_PARENT" \
  "$FAKE_REPO/config" \
  "$FAKE_REPO/logs/live-runs" \
  "$FAKE_REPO/run-state/$MULTI_STRAT" \
  "$FAKE_REPO/run-state/$SIBLING_STRAT" \
  "$FAKE_REPO/run-state/$MULTI_EXCH_STRAT" \
  "$FAKE_REPO/bin/$MULTI_STRAT" \
  "$FAKE_REPO/bin/$SIBLING_STRAT" \
  "$FAKE_REPO/bin/$MULTI_EXCH_STRAT" \
  "$TEXTFILE_DIR"

# Create SSH stub FIRST and bind SKYEYE_SSH_BIN to its absolute path while
# clearing any inherited transport variables from the caller's environment.
cat >"$FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
flags=""
while [[ $# -gt 0 && "$1" != "--" ]]; do
  flags="${flags:+$flags }$1"
  shift
done
[[ "${1:-}" == "--" ]] || { printf 'stub ssh expected -- delimiter\n' >&2; exit 2; }
shift
target="$1"
shift
remote_cmd="$*"
printf 'FLAGS=%s TARGET=%s CMD=%s\n' "$flags" "$target" "$remote_cmd" >>"$SSH_LOG"

# Cleanup invocation (Step 3)
if [[ "$remote_cmd" == "rm -rf -- "* ]]; then
  if [[ "${FAKE_SSH_CLEANUP_FAIL:-0}" == "1" ]]; then
    printf 'stub ssh: permission denied removing remote temp dir\n' >&2
    exit 1
  fi
  exec sh -c "$remote_cmd"
fi

# Stage upload invocation (Step 1)
if [[ "$remote_cmd" == *"__SKYEYE_STAGE__="* ]]; then
  cat >"$TAR_CAPTURE"
  if [[ -n "${FAKE_SSH_REMOTE_TMPDIR:-}" ]]; then
    # Run remote_stage_cmd verbatim with a space-containing remote TMPDIR
    # to prove scripts/trading-account ignores remote TMPDIR.
    TMPDIR="$FAKE_SSH_REMOTE_TMPDIR" exec sh -c "$remote_cmd" <"$TAR_CAPTURE"
  fi
  local_stage_cmd="${remote_cmd/\/tmp\/skyeye-trading-account.XXXXXX/$REMOTE_STAGING_PARENT/skyeye-trading-account.XXXXXX}"
  exec sh -c "$local_stage_cmd" <"$TAR_CAPTURE"
fi

# Sudo execution invocation (Step 2)
if [[ "${FAKE_SSH_SUDO_PW_REQUIRED:-0}" == "1" ]]; then
  printf 'sudo: a password is required\n' >&2
  exit 1
fi

if [[ "${FAKE_SSH_EXEC_LOCAL:-0}" == "1" ]]; then
  # Strip leading "sudo -n -- " or "sudo -- " and execute the staged script locally.
  local_cmd="$remote_cmd"
  local_cmd="${local_cmd#sudo -n -- }"
  local_cmd="${local_cmd#sudo -- }"
  exec sh -c "$local_cmd"
fi

exit 0
EOF
chmod 755 "$FAKE_BIN/ssh"

# Clear any inherited transport settings and pin SSH stub absolutely (C11).
unset SKYEYE_SSH_TARGET SKYEYE_TRADING_REMOTE_DIR
export SKYEYE_SSH_BIN="$FAKE_BIN/ssh"

# Stub date supporting both fixed FAKE_UTC_HM and sequential FAKE_UTC_HM_SEQ_FILE (C5).
REAL_DATE="$(command -v date)"
cat >"$FAKE_BIN/date" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-u" && "\${2:-}" == "+%H:%M" ]]; then
  if [[ -n "\${FAKE_UTC_HM_SEQ_FILE:-}" && -f "\$FAKE_UTC_HM_SEQ_FILE" ]]; then
    val="\$(head -n 1 "\$FAKE_UTC_HM_SEQ_FILE")"
    if [[ -n "\$val" ]]; then
      tail -n +2 "\$FAKE_UTC_HM_SEQ_FILE" >"\$FAKE_UTC_HM_SEQ_FILE.next"
      mv "\$FAKE_UTC_HM_SEQ_FILE.next" "\$FAKE_UTC_HM_SEQ_FILE"
      printf '%s\n' "\$val"
      exit 0
    fi
  fi
  if [[ -n "\${FAKE_UTC_HM:-}" ]]; then
    printf '%s\n' "\$FAKE_UTC_HM"
    exit 0
  fi
fi
exec "$REAL_DATE" "\$@"
EOF

# Stub cp supporting deterministic fault injection or mid-rollback hook (C3, C20).
REAL_CP="$(command -v cp)"
cat >"$FAKE_BIN/cp" <<EOF
#!/usr/bin/env bash
if [[ -n "\${FAKE_FAIL_CP_PATTERN:-}" ]]; then
  for arg in "\$@"; do
    if [[ "\$arg" == *"\$FAKE_FAIL_CP_PATTERN"* ]]; then
      if [[ -n "\${FAKE_CP_HOOK:-}" && -x "\$FAKE_CP_HOOK" ]]; then
        "\$FAKE_CP_HOOK" "\$arg"
      fi
      if [[ "\${FAKE_FAIL_CP_EXIT:-1}" != "0" ]]; then
        printf 'stub cp: injected failure for %s\n' "\$arg" >&2
        exit 1
      fi
    fi
  done
fi
exec "$REAL_CP" "\$@"
EOF

cat >"$FAKE_BIN/alloy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'alloy, version v%s (branch: HEAD, revision: fixture)\n' "${FAKE_ALLOY_VERSION:-1.16.3}"
  exit 0
fi
exit 0
EOF

cat >"$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"
shift
for log_path in "$SYSTEMCTL_LOG" "$SYSTEMCTL_LOG_ALL"; do
  {
    printf '%s' "$cmd"
    printf ' %s' "$@"
    printf '\n'
  } >>"$log_path"
done

if [[ "${FAKE_SYSTEMCTL_BUS_ERROR:-0}" == "1" || -e "$SYSTEMCTL_STATE/bus_error" ]]; then
  printf 'Failed to connect to bus: No such file or directory\n' >&2
  exit 1
fi

state_path() {
  local kind="$1" unit="$2"
  printf '%s/%s_%s\n' "$SYSTEMCTL_STATE" "$kind" "${unit//\//_}"
}

state_exists() {
  local kind="$1" unit="$2" candidate
  if [[ "$unit" == *'*'* ]]; then
    for candidate in "$SYSTEMCTL_STATE"/"$kind"_skyeye-trading-probe@*; do
      [[ -e "$candidate" ]] || continue
      case "$unit" in
        *'.service') [[ "$candidate" == *.service ]] && return 0 ;;
        *'.timer') [[ "$candidate" == *.timer ]] && return 0 ;;
      esac
    done
    return 1
  fi
  [[ -e "$(state_path "$kind" "$unit")" ]]
}

bump_service_invocation() {
  local unit="$1"
  local seq_file="$SYSTEMCTL_STATE/inv_seq"
  local seq=0
  if [[ -f "$seq_file" ]]; then
    seq="$(cat "$seq_file")"
  fi
  seq=$((seq + 1))
  printf '%s\n' "$seq" >"$seq_file"
  printf 'inv-%s-%s\n' "${unit//\//_}" "$seq" >"$(state_path inv "$unit")"
  printf '%s000000\n' "$seq" >"$(state_path mono "$unit")"
}

case "$cmd" in
  is-active|is-enabled|is-failed)
    [[ "${1:-}" != "--quiet" ]] || shift
    unit="$1"
    kind=active
    [[ "$cmd" != "is-enabled" ]] || kind=enabled
    [[ "$cmd" != "is-failed" ]] || kind=failed
    state_exists "$kind" "$unit"
    ;;
  disable)
    if [[ "${1:-}" == "--now" ]]; then
      shift
      rm -f "$(state_path active "$1")"
    fi
    rm -f "$(state_path enabled "$1")"
    ;;
  enable)
    if [[ "${1:-}" == "--now" ]]; then
      shift
      touch "$(state_path active "$1")"
    fi
    touch "$(state_path enabled "$1")"
    ;;
  start)
    unit="$1"
    if [[ "$unit" == skyeye-trading-probe@*.service ]]; then
      strat="${unit#skyeye-trading-probe@}"
      strat="${strat%.service}"
      rm -f "$(state_path failed "$unit")"
      touch "$(state_path activating "$unit")"
      bump_service_invocation "$unit"
      env_path="$SYSTEM_ROOT/etc/skyeye-trading/instances/$strat.env"
      probe_bin="$SYSTEM_ROOT/usr/local/libexec/skyeye-trading/probe.sh"
      run_rc=0
      if [[ -f "$env_path" && -x "$probe_bin" ]]; then
        # shellcheck disable=SC2016
        env -i PATH="$PATH" FAKE_UTC_HM="${FAKE_UTC_HM:-}" bash -c \
          'set -a; source "$1"; set +a; exec "$2"' bash "$env_path" "$probe_bin" || run_rc=$?
      fi
      rm -f "$(state_path activating "$unit")"
      if [[ "$run_rc" -ne 0 ]]; then
        touch "$(state_path failed "$unit")"
        printf 'exit-code\n' >"$(state_path result "$unit")"
        exit "$run_rc"
      fi
      printf 'success\n' >"$(state_path result "$unit")"
      exit 0
    fi
    touch "$(state_path active "$unit")"
    ;;
  restart)
    touch "$(state_path active "$1")"
    ;;
  stop)
    rm -f "$(state_path active "$1")"
    ;;
  daemon-reload)
    ;;
  reload)
    [[ -e "$(state_path active "$1")" ]] || exit 1
    ;;
  show)
    props=()
    value_only=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --no-pager) shift ;;
        --value) value_only=1; shift ;;
        -p)
          props+=("$2")
          shift 2
          ;;
        -p*)
          props+=("${1#-p}")
          shift
          ;;
        --)
          shift
          break
          ;;
        *)
          break
          ;;
      esac
    done
    unit="${1:-}"

    if [[ "$unit" == "alloy" ]]; then
      printf '%s\n' "${FAKE_ALLOY_CAN_RELOAD:-yes}"
      exit 0
    fi

    # Optional hook executed when querying a probe service unit to inject
    # deterministic faults mid-verification (e.g., failed service, timer drift,
    # or bus error for C6/C15/C20).
    if [[ "$unit" == skyeye-trading-probe@*.service && -n "${FAKE_SHOW_SERVICE_HOOK:-}" && -x "$FAKE_SHOW_SERVICE_HOOK" ]]; then
      "$FAKE_SHOW_SERVICE_HOOK" "$unit"
      if [[ "${FAKE_SYSTEMCTL_BUS_ERROR:-0}" == "1" || -e "$SYSTEMCTL_STATE/bus_error" ]]; then
        printf 'Failed to connect to bus: No such file or directory\n' >&2
        exit 1
      fi
    fi

    load_state="loaded"
    if [[ -e "$(state_path notfound "$unit")" ]]; then
      load_state="not-found"
    elif [[ "$unit" == skyeye-trading-probe@*.timer && ! -f "$SYSTEM_ROOT/etc/systemd/system/skyeye-trading-probe@.timer" ]]; then
      load_state="not-found"
    elif [[ "$unit" == skyeye-trading-probe@*.service && ! -f "$SYSTEM_ROOT/etc/systemd/system/skyeye-trading-probe@.service" ]]; then
      load_state="not-found"
    fi

    unit_file_state=""
    if [[ "$load_state" == "loaded" ]]; then
      if state_exists enabled "$unit"; then
        unit_file_state="enabled"
      else
        unit_file_state="disabled"
      fi
    fi

    active_state="inactive"
    if [[ "$load_state" == "loaded" ]]; then
      if state_exists failed "$unit"; then
        active_state="failed"
      elif state_exists activating "$unit"; then
        active_state="activating"
      elif state_exists active "$unit"; then
        active_state="active"
      fi
    fi

    result_state="success"
    if state_exists failed "$unit"; then
      result_state="exit-code"
    elif [[ -f "$(state_path result "$unit")" ]]; then
      result_state="$(cat "$(state_path result "$unit")")"
    fi

    inv_id=""
    if [[ -f "$(state_path inv "$unit")" ]]; then
      inv_id="$(cat "$(state_path inv "$unit")")"
    fi

    exec_mono="0"
    if [[ -f "$(state_path mono "$unit")" ]]; then
      exec_mono="$(cat "$(state_path mono "$unit")")"
    fi

    for p in "${props[@]}"; do
      val=""
      case "$p" in
        LoadState) val="$load_state" ;;
        UnitFileState) val="$unit_file_state" ;;
        ActiveState) val="$active_state" ;;
        Result) val="$result_state" ;;
        InvocationID) val="$inv_id" ;;
        ExecMainStartTimestampMonotonic) val="$exec_mono" ;;
      esac
      if [[ "$value_only" -eq 1 ]]; then
        printf '%s\n' "$val"
      else
        printf '%s=%s\n' "$p" "$val"
      fi
    done
    ;;
  *)
    printf 'unexpected fake systemctl command: %s\n' "$cmd" >&2
    exit 2
    ;;
esac
EOF

cat >"$FAKE_BIN/runuser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "-u" ]] || exit 2
while [[ "$1" != "--" ]]; do shift; done
shift
exec "$@"
EOF

cat >"$FAKE_BIN/getent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  passwd) printf '%s:x:1000:1000:fixture:%s:/bin/bash\n' "$2" "$FAKE_PASSWD_HOME" ;;
  group) printf '%s:x:1000:\n' "$2" ;;
  *) exit 2 ;;
esac
EOF

cat >"$FAKE_BIN/getfacl" <<'EOF'
#!/usr/bin/env bash
printf 'user::rw-\nuser:%s:r--\ngroup::r--\nmask::r--\nother::---\n' "$TQ_ALLOY_USER"
EOF

cat >"$FAKE_BIN/setfacl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod 755 "$FAKE_BIN"/*
export PATH="$FAKE_BIN:$PATH"
export SYSTEM_ROOT SYSTEMCTL_STATE SYSTEMCTL_LOG SYSTEMCTL_LOG_ALL SSH_LOG TAR_CAPTURE REMOTE_STAGING_PARENT
export FAKE_PASSWD_HOME="$TEST_ROOT"
export FAKE_UTC_HM="12:00"
export SKYEYE_ACCOUNT_WAIT_SECONDS=0
export SKYEYE_ACCOUNT_VERIFY_TIMEOUT=4
export SKYEYE_ACCOUNT_POLL_INTERVAL=1

printf 'case: static safety invariants and help text\n'
for script_path in "$SETUP" "$ACCOUNT_HOST" "$WRAPPER"; do
  [[ -x "$script_path" ]] || fail "script must be executable: $script_path"
  bash -n "$script_path" || fail "syntax error in $script_path"
done

assert_not_contains "$ACCOUNT_HOST" 'systemctl.*tnauqquant'
assert_not_contains "$ACCOUNT_HOST" 'SYSTEMCTL_BIN.*tnauqquant'
assert_not_contains "$ACCOUNT_HOST" 'manager[.]env'
assert_not_contains "$ACCOUNT_HOST" 'systemctl.*(reload|restart) alloy'
assert_not_contains "$ACCOUNT_HOST" 'SYSTEMCTL_BIN.*(reload|restart) alloy'
assert_not_contains "$WRAPPER" 'systemctl.*tnauqquant'
assert_not_contains "$WRAPPER" 'manager[.]env'
assert_not_contains "$WRAPPER" 'remote-dir'

: >"$SSH_LOG"
for help_cmd in \
  "$WRAPPER --help" \
  "$SETUP account --help" \
  "$ACCOUNT_HOST --help"
do
  # Intentional word split for the 2-3 token command forms above.
  # shellcheck disable=SC2086
  help_out="$($help_cmd)"
  [[ "$help_out" == *'TQ_EXECUTOR_MAP'* ]] || fail "$help_cmd did not mention TQ_EXECUTOR_MAP"
  [[ "$help_out" == *'18:10-19:30'* ]] || fail "$help_cmd did not mention UTC 18:10-19:30"
  [[ "$help_out" == *'Linux'* && "$help_out" == *'macOS'* && "$help_out" == *'Windows'* ]] || \
    fail "$help_cmd did not state Linux-only scope (excluding macOS and Windows)"
  [[ "$help_out" == *'tnauqquant'* ]] || fail "$help_cmd did not describe ordering with tnauqquant"
  [[ "$help_out" == *'Inactive timer'* ]] || fail "$help_cmd did not explain inactive timer verification scope"
done
[[ ! -s "$SSH_LOG" ]] || fail "--help unexpectedly invoked ssh"

# Install 3 realistic strategies using setup-linux.sh add.
cat >"$SYSTEM_ROOT/etc/alloy/base.alloy" <<'EOF'
loki.write "central" {
  endpoint { url = "https://loki.invalid/loki/api/v1/push" }
}
prometheus.remote_write "central" {
  endpoint { url = "https://prometheus.invalid/api/v1/write" }
}
EOF
printf 'CONFIG_FILE="%s/etc/alloy"\n' "$SYSTEM_ROOT" >"$SYSTEM_ROOT/etc/default/alloy"
touch "$SYSTEMCTL_STATE/active_alloy"

for pair in \
  "$MULTI_STRAT:popdex_multi_accounts_config" \
  "$SIBLING_STRAT:lighter_robinhood_btc_config" \
  "$MULTI_EXCH_STRAT:toobit_mexc_btc_config"
do
  s="${pair%%:*}"
  stem="${pair#*:}"
  printf 'instance_id: "%s"\n' "$s" >"$FAKE_REPO/config/$stem.yaml"
  printf '#!/bin/sh\nexit 0\n' >"$FAKE_REPO/bin/$s/quant"
  chmod 755 "$FAKE_REPO/bin/$s/quant"
done

fixture_utc_hour="$(date -u +%H)"
fixture_offset_hours=$(((18 - 10#$fixture_utc_hour + 36) % 24 - 12))
FIXTURE_OFFSET="$(printf '%+03d:00' "$fixture_offset_hours")"
FIXTURE_TIMEZONE="$(printf 'Etc/GMT%+d' "$((-fixture_offset_hours))")"
today_local="$(TZ="$FIXTURE_TIMEZONE" date +%F)"

MULTI_LOG="$FAKE_REPO/logs/live-runs/20261126_090000_popdex_multi_accounts_config.raw.log"
cat >"$MULTI_LOG" <<EOF
time=${today_local}T09:00:00${FIXTURE_OFFSET} level=INFO msg=initial_equity_recorded equity_usdt=10000.00 equity_usdt_by_executor=popdex-main:5000.00,popdex-rot2:5000.00
time=${today_local}T10:00:00${FIXTURE_OFFSET} level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 equity_now=10025.00 equity_usdt_by_executor=popdex-main:5015.00,popdex-rot2:5010.00 volume_usd_by_executor=popdex-main:1200.00,popdex-rot2:800.00 real_pnl_usdt=25.00 cash_pnl_usdt=20.00 rebate_usdt=5.00 risk_pnl_usdt=24.00 cycles_completed=1 cycle_real_pnl_usdt=25.00 cycle_executor=popdex-main risk_stopped=false
time=${today_local}T10:05:00${FIXTURE_OFFSET} level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.2 session_cycle=2 equity_now=10040.00 equity_usdt_by_executor=popdex-main:5015.00,popdex-rot2:5025.00 volume_usd_by_executor=popdex-main:1200.00,popdex-rot2:1600.00 real_pnl_usdt=40.00 cash_pnl_usdt=32.00 rebate_usdt=8.00 risk_pnl_usdt=38.00 cycles_completed=2 cycle_real_pnl_usdt=15.00 cycle_executor=popdex-rot2 risk_stopped=false
EOF

multi_cfg_sha="$(sha_of "$FAKE_REPO/config/popdex_multi_accounts_config.yaml")"
multi_manifest="$FAKE_REPO/run-state/$MULTI_STRAT/current.json"
multi_marker="$FAKE_REPO/run-state/$MULTI_STRAT/current.done.json"
jq -n \
  --arg run_id "20261126_090000_popdex_multi_accounts_config" \
  --arg strategy "$MULTI_STRAT" \
  --arg instance_id "$MULTI_STRAT" \
  --arg config_sha256 "$multi_cfg_sha" \
  --arg process_started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg executable "$FAKE_REPO/bin/$MULTI_STRAT/quant" \
  --arg config_path "$FAKE_REPO/config/popdex_multi_accounts_config.yaml" \
  --arg log_path "$MULTI_LOG" \
  --arg done_marker_path "$multi_marker" \
  '{
    schema_version: 1,
    run_id: $run_id,
    strategy: $strategy,
    instance_id: $instance_id,
    pid: 999999,
    config_sha256: $config_sha256,
    process_started_at: $process_started_at,
    executable: $executable,
    config_path: $config_path,
    log_path: $log_path,
    done_marker_path: $done_marker_path,
    state: "running"
  }' >"$multi_manifest"

jq -n \
  --arg run_id "20261126_090000_popdex_multi_accounts_config" \
  --arg strategy "$MULTI_STRAT" \
  --arg instance_id "$MULTI_STRAT" \
  --arg config_sha256 "$multi_cfg_sha" \
  --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    schema_version: 1,
    run_id: $run_id,
    strategy: $strategy,
    instance_id: $instance_id,
    pid: 999999,
    config_sha256: $config_sha256,
    reason: "max_cycles_complete",
    phase: "max_cycles_complete",
    completed_at: $completed_at,
    long_btc: 0,
    short_btc: 0,
    net_btc: 0,
    dust_tolerance_btc: 0
  }' >"$multi_marker"

write_seed_env() {
  local strategy="$1" config_stem="$2" executor_map="$3" target="$4"
  cat >"$target" <<EOF
# Fixture env for $strategy
TQ_PRODUCT=tnauqquant
TQ_ENVIRONMENT=production
TQ_SERVER_ID=trading01
TQ_STRATEGY=$strategy
TQ_INSTANCE_ID=$strategy
TQ_REPO_ROOT=$FAKE_REPO
TQ_REPO_ROOT_REGEX='($FAKE_REPO)'
TQ_EXECUTABLE=$FAKE_REPO/bin/$strategy/quant
TQ_CONFIG_PATH=$FAKE_REPO/config/$config_stem.yaml
TQ_RAW_LOG_GLOB=$FAKE_REPO/logs/live-runs/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]_${config_stem}.raw.log
TQ_RUN_MANIFEST=$FAKE_REPO/run-state/$strategy/current.json
TQ_DONE_MARKER=$FAKE_REPO/run-state/$strategy/current.done.json
TQ_POC_RUN_EXPECTED=1
TQ_REQUIRE_RUNTIME_CONTRACT=1
TQ_TIMEZONE=$FIXTURE_TIMEZONE
TQ_TEXTFILE_DIR=$TEXTFILE_DIR
TQ_TEXTFILE_NAME=tnauqquant-$strategy.prom
TQ_EXECUTOR_MAP=$executor_map
TQ_SIDECAR_REQUIRED=0
TQ_TEXTFILE_MODE=640
TQ_PROBE_USER=$CURRENT_USER
TQ_PROBE_GROUP=$CURRENT_GROUP
TQ_ALLOY_USER=$CURRENT_USER
TQ_ALLOY_GROUP=$CURRENT_GROUP
EOF
  chmod 600 "$target"
}

write_seed_env "$MULTI_STRAT" popdex_multi_accounts_config "popdex-main=popdex,popdex-rot2=popdex" "$TEST_ROOT/$MULTI_STRAT.seed.env"
write_seed_env "$SIBLING_STRAT" lighter_robinhood_btc_config "lighter-robinhood-main=lighter" "$TEST_ROOT/$SIBLING_STRAT.seed.env"
write_seed_env "$MULTI_EXCH_STRAT" toobit_mexc_btc_config "toobit-main=toobit,mexc-ui=mexc" "$TEST_ROOT/$MULTI_EXCH_STRAT.seed.env"

for strat in "$MULTI_STRAT" "$SIBLING_STRAT" "$MULTI_EXCH_STRAT"; do
  : >"$SYSTEMCTL_LOG"
  SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
    "$SETUP" add --env-file "$TEST_ROOT/$strat.seed.env" >/dev/null
done
# Reset audit log after initial setup so everything recorded below comes solely
# from account / retire interactions.
: >"$SYSTEMCTL_LOG_ALL"

MULTI_ENV="$SYSTEM_ROOT/etc/skyeye-trading/instances/$MULTI_STRAT.env"
SIBLING_ENV="$SYSTEM_ROOT/etc/skyeye-trading/instances/$SIBLING_STRAT.env"
MULTI_EXCH_ENV="$SYSTEM_ROOT/etc/skyeye-trading/instances/$MULTI_EXCH_STRAT.env"
MULTI_PROM="$TEXTFILE_DIR/tnauqquant-$MULTI_STRAT.prom"
SIBLING_PROM="$TEXTFILE_DIR/tnauqquant-$SIBLING_STRAT.prom"
INSTALLED_PROBE="$SYSTEM_ROOT/usr/local/libexec/skyeye-trading/probe.sh"
INSTALLED_SERVICE="$SYSTEM_ROOT/etc/systemd/system/skyeye-trading-probe@.service"
MULTI_TIMER_ENABLED="$SYSTEMCTL_STATE/enabled_skyeye-trading-probe@$MULTI_STRAT.timer"
MULTI_TIMER_ACTIVE="$SYSTEMCTL_STATE/active_skyeye-trading-probe@$MULTI_STRAT.timer"

assert_no_systemd_mutation() {
  local label="$1"
  if rg -q '^(restart|reload|enable|disable|start|stop|daemon-reload)( |$)' "$SYSTEMCTL_LOG"; then
    cat "$SYSTEMCTL_LOG" >&2
    fail "$label unexpectedly mutated systemd state"
  fi
}

backup_count() {
  if [[ -d "$SYSTEM_ROOT/etc/skyeye-trading/account-backup" ]]; then
    find "$SYSTEM_ROOT/etc/skyeye-trading/account-backup" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
  else
    printf '0\n'
  fi
}

# Simulates systemd's 15s timer firing AFTER the instance env changes: watches
# for env SHA change, settles briefly past POST_WRITE_EPOCH, waits for the next
# integer second, advances InvocationID / ExecMainStartTimestampMonotonic, and
# runs the real installed probe.sh with the new env.
bump_probe_invocation() {
  local strat="$1"
  local unit="skyeye-trading-probe@${strat}.service"
  local seq_file="$SYSTEMCTL_STATE/inv_seq"
  local seq=0
  if [[ -f "$seq_file" ]]; then
    seq="$(cat "$seq_file")"
  fi
  seq=$((seq + 1))
  printf '%s\n' "$seq" >"$seq_file"
  printf 'inv-%s-%s\n' "${unit//\//_}" "$seq" >"$SYSTEMCTL_STATE/inv_${unit}"
  printf '%s000000\n' "$seq" >"$SYSTEMCTL_STATE/mono_${unit}"
  printf 'success\n' >"$SYSTEMCTL_STATE/result_${unit}"
  rm -f "$SYSTEMCTL_STATE/failed_${unit}"
}

simulate_timer_probe_run() {
  local strat="$1"
  local env_path="$SYSTEM_ROOT/etc/skyeye-trading/instances/$strat.env"
  local unit="skyeye-trading-probe@${strat}.service"
  touch "$SYSTEMCTL_STATE/activating_${unit}"
  bump_probe_invocation "$strat"
  # shellcheck disable=SC2016
  env -i PATH="$PATH" FAKE_UTC_HM="${FAKE_UTC_HM:-}" bash -c \
    'set -a; source "$1"; set +a; exec "$2"' bash "$env_path" "$INSTALLED_PROBE"
  rm -f "$SYSTEMCTL_STATE/activating_${unit}"
}

wait_next_epoch_second() {
  local base_sec="$1"
  perl -e '
    my ($base) = @ARGV;
    while (time() <= $base) {
      select(undef, undef, undef, 0.05);
    }
  ' "$base_sec"
}

wait_env_change_and_next_second() {
  local env_path="$1"
  perl -e '
    my ($path) = @ARGV;
    sub read_all {
      open(my $f, "<:raw", $_[0]) or return undef;
      local $/; my $d = <$f>; close($f); return $d;
    }
    my $orig = read_all($path);
    my $deadline = time() + 10;
    while (time() < $deadline) {
      my $cur = read_all($path);
      if (defined($cur) && (!defined($orig) || $cur ne $orig)) {
        select(undef, undef, undef, 0.08);
        my $base = time();
        while (time() <= $base) {
          select(undef, undef, undef, 0.02);
        }
        exit 0;
      }
      select(undef, undef, undef, 0.02);
    }
    exit 1;
  ' "$env_path"
}

spawn_timer_tick_on_env_change() {
  local strat="$1"
  local env_path="$SYSTEM_ROOT/etc/skyeye-trading/instances/$strat.env"
  (
    if wait_env_change_and_next_second "$env_path"; then
      simulate_timer_probe_run "$strat"
    fi
  ) &
  BG_PIDS+=("$!")
  LAST_TIMER_PID=$!
}

wait_bg_timer() {
  if [[ -n "${LAST_TIMER_PID:-}" ]]; then
    wait "$LAST_TIMER_PID" 2>/dev/null || true
    LAST_TIMER_PID=""
  fi
}

# ---- Core read-only list & C10 (.prom symlink / non-regular refusal) ----

printf 'case: list is read-only and reports configured and .prom series executors\n'
: >"$SYSTEMCTL_LOG"
list_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account list --server trading01 --strategy "$MULTI_STRAT")"
[[ ! -s "$SYSTEMCTL_LOG" ]] || fail "list called systemctl unexpectedly: $(cat "$SYSTEMCTL_LOG")"
[[ "$list_out" == *"TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex"* ]] || \
  fail "list missing TQ_EXECUTOR_MAP: $list_out"
[[ "$list_out" == *"popdex-main	popdex	(equity,real_pnl,cycles,volume)"* &&
   "$list_out" == *"popdex-rot2	popdex	(equity,real_pnl,cycles,volume)"* ]] || \
  fail "list missing .prom series executors: $list_out"

mv "$MULTI_PROM" "$MULTI_PROM.bak"
list_missing_prom="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account list --server trading01 --strategy "$MULTI_STRAT")"
[[ "$list_missing_prom" == *"(missing)"* && "$list_missing_prom" == *"(prom file missing)"* ]] || \
  fail "list did not handle missing .prom cleanly: $list_missing_prom"
: >"$MULTI_PROM"
list_empty_prom="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account list --server trading01 --strategy "$MULTI_STRAT")"
[[ "$list_empty_prom" == *"probe_timestamp_seconds: none"* && "$list_empty_prom" == *"(none)"* ]] || \
  fail "list did not handle 0-byte .prom cleanly: $list_empty_prom"
mv "$MULTI_PROM.bak" "$MULTI_PROM"

printf 'case: C10 symlink and non-regular .prom files are refused in both list and add verification\n'
SECRET_SENTINEL_FILE="$TEST_ROOT/secret-sentinel.txt"
printf 'SECRET_SENTINEL=DO_NOT_LEAK\ntnauqquant_probe_timestamp_seconds{strategy="%s"} 9999999999\n' \
  "$MULTI_STRAT" >"$SECRET_SENTINEL_FILE"
mv "$MULTI_PROM" "$MULTI_PROM.real"
ln -s "$SECRET_SENTINEL_FILE" "$MULTI_PROM"

if sym_list="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account list --server trading01 --strategy "$MULTI_STRAT" 2>&1)"; then
  fail "list accepted symlinked .prom"
fi
[[ "$sym_list" == *"symlink"* && "$sym_list" != *"SECRET_SENTINEL"* ]] || \
  fail "symlink .prom refusal in list unclear or leaked sentinel: $sym_list"

env_before_c10="$(sha_of "$MULTI_ENV")"
if sym_add="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)"; then
  fail "add accepted symlinked .prom"
fi
[[ "$sym_add" == *"symlink"* && "$sym_add" != *"SECRET_SENTINEL"* ]] || \
  fail "symlink .prom refusal in add unclear or leaked sentinel: $sym_add"
[[ "$(sha_of "$MULTI_ENV")" == "$env_before_c10" ]] || fail "symlink .prom add did not restore env"

# Non-regular FIFO must fail immediately without hanging
rm -f "$MULTI_PROM"
mkfifo "$MULTI_PROM"
if fifo_list="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account list --server trading01 --strategy "$MULTI_STRAT" 2>&1)"; then
  fail "list accepted FIFO .prom"
fi
[[ "$fifo_list" == *"non-regular"* ]] || fail "FIFO refusal in list unclear: $fifo_list"
if fifo_add="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)"; then
  fail "add accepted FIFO .prom"
fi
[[ "$fifo_add" == *"non-regular"* ]] || fail "FIFO refusal in add unclear: $fifo_add"
[[ "$(sha_of "$MULTI_ENV")" == "$env_before_c10" ]] || fail "FIFO .prom add did not restore env"
rm -f "$MULTI_PROM"

printf 'case: C18 oversized .prom exceeding 4 MiB read cap is refused immediately in list and rolls back add\n'
perl -e 'print "x" x (4 * 1024 * 1024 + 1)' >"$MULTI_PROM"
if big_list="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account list --server trading01 --strategy "$MULTI_STRAT" 2>&1)"; then
  fail "C18: list accepted .prom exceeding 4 MiB cap"
fi
[[ "$big_list" == *"exceeds maximum allowed size (4194304 bytes)"* ]] || \
  fail "C18: oversized .prom refusal in list unclear: $big_list"

if big_add="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)"; then
  fail "C18: add accepted .prom exceeding 4 MiB cap"
fi
[[ "$big_add" == *"exceeds maximum allowed size (4194304 bytes)"* ]] || \
  fail "C18: oversized .prom refusal in add unclear: $big_add"
[[ "$(sha_of "$MULTI_ENV")" == "$env_before_c10" ]] || fail "C18: oversized .prom add did not restore env"
rm -f "$MULTI_PROM"
mv "$MULTI_PROM.real" "$MULTI_PROM"

# ---- Time window protection & C5 (preflight 18:09 -> pre-backup / pre-rename 18:10) ----

printf 'case: time protection refuses add/remove in UTC 18:10-19:30 and allows boundaries & list\n'
before_sha="$(sha_of "$MULTI_ENV")"
before_backups="$(backup_count)"
for blocked_time in 18:10 18:30 19:30; do
  : >"$SYSTEMCTL_LOG"
  : >"$SSH_LOG"
  if out="$(FAKE_UTC_HM="$blocked_time" SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
    "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)"; then
    fail "account add succeeded at blocked UTC $blocked_time"
  fi
  [[ "$out" == *"18:10-19:30"* && "$out" == *"$blocked_time"* ]] || \
    fail "time guard error unclear at $blocked_time: $out"
  assert_no_systemd_mutation "blocked add at $blocked_time"
  if out="$(FAKE_UTC_HM="$blocked_time" SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
    "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot2 2>&1)"; then
    fail "account remove succeeded at blocked UTC $blocked_time"
  fi
  if out="$(FAKE_UTC_HM="$blocked_time" \
    "$WRAPPER" add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --ssh-target ubuntu@t01 2>&1)"; then
    fail "wrapper add succeeded at blocked UTC $blocked_time"
  fi
  [[ "$out" == *"18:10-19:30"* ]] || fail "wrapper time guard error unclear: $out"
  [[ ! -s "$SSH_LOG" ]] || fail "wrapper invoked ssh during blocked UTC $blocked_time"
done
FAKE_UTC_HM="18:30" SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account list --server trading01 --strategy "$MULTI_STRAT" >/dev/null || \
  fail "read-only list was blocked during UTC 18:30"
for ok_time in 18:09 19:31; do
  FAKE_UTC_HM="$ok_time" SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
    "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --dry-run >/dev/null || \
    fail "dry-run add was wrongly blocked at UTC $ok_time"
done
[[ "$before_sha" == "$(sha_of "$MULTI_ENV")" && "$before_backups" == "$(backup_count)" ]] || \
  fail "time-window tests modified env or created backups"

printf 'case: C5 UTC 18:10-19:30 re-checked before backup AND after staging right before rename (rollback rename still allowed at 18:10)\n'
UTC_SEQ="$TEST_ROOT/utc-seq.txt"
# 1) Preflight 18:09 -> lock-entry pre-backup check 18:10 (no backup created, env untouched)
printf '18:09\n18:10\n' >"$UTC_SEQ"
before_backups="$(backup_count)"
if c5_out="$(FAKE_UTC_HM_SEQ_FILE="$UTC_SEQ" SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)"; then
  fail "C5: add proceeded after clock crossed from 18:09 into 18:10 before backup"
fi
[[ "$c5_out" == *"18:10-19:30"* && "$c5_out" == *"18:10"* ]] || fail "C5 pre-backup refusal unclear: $c5_out"
[[ "$(sha_of "$MULTI_ENV")" == "$before_sha" && "$(backup_count)" == "$before_backups" ]] || \
  fail "C5 pre-backup refused write still modified env or created backup"

# 2) Preflight 18:09 -> pre-backup 18:09 -> backup + temp staged -> pre-rename check 18:10
# Must refuse BEFORE mv -f, leave installed env untouched, clean up staged temp, and record refused_utc_window.
printf '18:09\n18:09\n18:10\n' >"$UTC_SEQ"
if c5_mv_out="$(FAKE_UTC_HM_SEQ_FILE="$UTC_SEQ" SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)"; then
  fail "C5: add performed rename after clock crossed into 18:10 following backup/staging"
fi
[[ "$c5_mv_out" == *"18:10-19:30"* && "$c5_mv_out" == *"18:10"* ]] || \
  fail "C5 pre-rename refusal unclear: $c5_mv_out"
[[ "$(sha_of "$MULTI_ENV")" == "$before_sha" ]] || \
  fail "C5 pre-rename 18:10 check still modified installed env"
c5_mv_dir="$(sed -n 's/^Backup record: //p' <<<"$c5_mv_out" | head -n 1)"
assert_contains "$c5_mv_dir/account.meta" '^status=refused_utc_window$'
assert_not_contains "$c5_mv_dir/account.meta" '^status=committed$'
leftover_c5_tmp="$(find "$SYSTEM_ROOT/etc/skyeye-trading/instances" -name '*.tmp.*' -print)"
[[ -z "$leftover_c5_tmp" ]] || fail "C5 pre-rename refusal left temp file behind: $leftover_c5_tmp"

# 3) Already-started transaction (preflight 18:09 + pre-backup 18:09 + pre-rename 18:09)
# that fails verification during 18:10 MUST still execute rollback rename cleanly.
printf '18:09\n18:09\n18:09\n18:10\n' >"$UTC_SEQ"
if c5_rb="$(SKYEYE_ACCOUNT_VERIFY_TIMEOUT=1 FAKE_UTC_HM_SEQ_FILE="$UTC_SEQ" \
  SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)"; then
  fail "C5 started-tx failure unexpectedly succeeded"
fi
[[ "$(sha_of "$MULTI_ENV")" == "$before_sha" ]] || fail "C5 failed tx did not roll back at 18:10"
c5_dir="$(sed -n 's/^Backup record: //p' <<<"$c5_rb" | head -n 1)"
assert_contains "$c5_dir/account.meta" '^status=rolled_back$'

# ---- Standard refusal conditions, C16 (EnvironmentFile= duplicates/indentation), C15 (systemd query errors) ----

printf 'case: refusal conditions reject invalid operations without mutating host\n'
before_backups="$(backup_count)"
expect_refuse() {
  local label="$1" pattern="$2"
  shift 2
  : >"$SYSTEMCTL_LOG"
  local out
  if out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" "$@" 2>&1)"; then
    fail "$label unexpectedly succeeded: $out"
  fi
  [[ "$out" == *"$pattern"* ]] || fail "$label error did not contain '$pattern': $out"
  assert_no_systemd_mutation "$label"
}

expect_refuse "missing strategy" "not found" \
  "$SETUP" account add --server trading01 --strategy no-such-lane --executor ex1
expect_refuse "invalid executor name" "invalid executor name" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor "bad=name"
expect_refuse "leading dash executor" "invalid executor name" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor "-bad"
expect_refuse "invalid exchange name" "invalid exchange name" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --exchange "bad!ex"
expect_refuse "server mismatch" "server_id mismatch" \
  "$SETUP" account add --server trading02 --strategy "$MULTI_STRAT" --executor popdex-rot3
expect_refuse "duplicate add" "already exists" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-main
expect_refuse "ambiguous exchange on multi-exchange lane" "specify --exchange" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_EXCH_STRAT" --executor toobit-2
expect_refuse "remove missing executor" "is not present" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor no-such-exec
expect_refuse "remove with mismatched exchange" "mapped to exchange" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot2 --exchange lighter
expect_refuse "remove last executor" "cannot remove the last executor" \
  "$SETUP" account remove --server trading01 --strategy "$SIBLING_STRAT" --executor lighter-robinhood-main

chmod 644 "$MULTI_ENV"
expect_refuse "wrong env mode 644" "mode 600" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3
chmod 600 "$MULTI_ENV"

ln -s "$MULTI_ENV" "$SYSTEM_ROOT/etc/skyeye-trading/instances/symlink-lane.env"
expect_refuse "symlinked env" "symlink" \
  "$SETUP" account add --server trading01 --strategy symlink-lane --executor ex1
rm -f "$SYSTEM_ROOT/etc/skyeye-trading/instances/symlink-lane.env"

cp "$MULTI_ENV" "$TEST_ROOT/multi.env.save"
printf 'TQ_EXECUTOR_MAP=popdex-main=popdex\n' >>"$MULTI_ENV"
expect_refuse "duplicate TQ_EXECUTOR_MAP lines" "exactly one literal TQ_EXECUTOR_MAP=" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3

printf 'case: C16 indented, export, and line-continued EnvironmentFile= assignments are refused before write\n'
cp "$TEST_ROOT/multi.env.save" "$MULTI_ENV"
chmod 600 "$MULTI_ENV"
printf '  TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex\n' >>"$MULTI_ENV"
expect_refuse "C16 indented duplicate TQ_EXECUTOR_MAP (add)" "leading whitespace" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3
expect_refuse "C16 indented duplicate TQ_EXECUTOR_MAP (remove)" "leading whitespace" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot2
expect_refuse "C16 indented duplicate TQ_EXECUTOR_MAP (list)" "leading whitespace" \
  "$SETUP" account list --server trading01 --strategy "$MULTI_STRAT"

cp "$TEST_ROOT/multi.env.save" "$MULTI_ENV"
chmod 600 "$MULTI_ENV"
printf 'export TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex\n' >>"$MULTI_ENV"
expect_refuse "C16 export duplicate TQ_EXECUTOR_MAP" "export" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3

cp "$TEST_ROOT/multi.env.save" "$MULTI_ENV"
chmod 600 "$MULTI_ENV"
printf '  TQ_SERVER_ID=trading01\n' >>"$MULTI_ENV"
expect_refuse "C16 indented duplicate TQ_SERVER_ID" "leading whitespace" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3

perl -pe 's/^TQ_EXECUTOR_MAP=/TQ_DUMMY=abc\\\nTQ_EXECUTOR_MAP=/' "$TEST_ROOT/multi.env.save" >"$MULTI_ENV"
chmod 600 "$MULTI_ENV"
expect_refuse "C16 backslash line continuation into TQ_EXECUTOR_MAP" "line continuation" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3

# Literal "$EXP" in fixture is intentional.
# shellcheck disable=SC2016
sed 's/^TQ_EXECUTOR_MAP=.*/TQ_EXECUTOR_MAP="$EXP"/' "$TEST_ROOT/multi.env.save" >"$MULTI_ENV"
chmod 600 "$MULTI_ENV"
expect_refuse "non-literal TQ_EXECUTOR_MAP" "cannot be read safely" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3
cp "$TEST_ROOT/multi.env.save" "$MULTI_ENV"
chmod 600 "$MULTI_ENV"

printf 'case: C15 systemctl bus error and missing timer/service units are refused before write\n'
rc=0
c15_bus_out="$(FAKE_SYSTEMCTL_BUS_ERROR=1 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || rc=$?
[[ "$rc" -eq 1 && "$c15_bus_out" == *"Failed to connect to bus"* ]] || \
  fail "C15: systemctl bus failure was not refused cleanly (rc=$rc): $c15_bus_out"

touch "$SYSTEMCTL_STATE/notfound_skyeye-trading-probe@$MULTI_STRAT.timer"
rc=0
c15_nf_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || rc=$?
rm -f "$SYSTEMCTL_STATE/notfound_skyeye-trading-probe@$MULTI_STRAT.timer"
[[ "$rc" -eq 1 && "$c15_nf_out" == *"LoadState=not-found"* ]] || \
  fail "C15: missing timer unit was not refused cleanly (rc=$rc): $c15_nf_out"

touch "$SYSTEMCTL_STATE/notfound_skyeye-trading-probe@$MULTI_STRAT.service"
rc=0
c15_snf_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || rc=$?
rm -f "$SYSTEMCTL_STATE/notfound_skyeye-trading-probe@$MULTI_STRAT.service"
[[ "$rc" -eq 1 && "$c15_snf_out" == *"LoadState=not-found"* ]] || \
  fail "C15: missing service unit was not refused cleanly (rc=$rc): $c15_snf_out"

[[ "$before_sha" == "$(sha_of "$MULTI_ENV")" && "$before_backups" == "$(backup_count)" ]] || \
  fail "refused calls mutated env or created backups"

# C15 rollback check: bus fails mid-verification -> env restores, timer state is
# reported truthfully as unknown (rollback_incomplete, rc=3), never falsely preserved.
HOOK_BUS_AFTER_WRITE="$TEST_ROOT/hook-bus-after-write.sh"
cat >"$HOOK_BUS_AFTER_WRITE" <<EOF
#!/usr/bin/env bash
if [[ "\$(shasum -a 256 "$MULTI_ENV" | awk '{print \$1}')" != "$before_sha" ]]; then
  touch "$SYSTEMCTL_STATE/bus_error"
fi
EOF
chmod 755 "$HOOK_BUS_AFTER_WRITE"
rc=0
c15_rb_out="$(FAKE_SHOW_SERVICE_HOOK="$HOOK_BUS_AFTER_WRITE" SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || rc=$?
rm -f "$SYSTEMCTL_STATE/bus_error"
[[ "$rc" -eq 3 ]] || fail "C15 rollback bus failure expected rc=3, got rc=$rc: $c15_rb_out"
[[ "$(sha_of "$MULTI_ENV")" == "$before_sha" ]] || fail "C15 rollback bus failure did not restore env"
c15_dir="$(sed -n 's/^Backup record: //p' <<<"$c15_rb_out" | head -n 1)"
assert_contains "$c15_dir/account.meta" '^status=rollback_incomplete$'
assert_contains "$c15_dir/account.meta" '^rollback_env_restored=1$'
assert_contains "$c15_dir/account.meta" '^rollback_timer_preserved=unknown$'
[[ "$c15_rb_out" == *"Timer state check UNKNOWN"* && "$c15_rb_out" == *"Failed to connect to bus"* ]] || \
  fail "C15 rollback bus failure message did not truthfully report unknown timer state: $c15_rb_out"

# ---- C1: Shared /run/skyeye-alloy.lock serializes account/retire and account/account ----

printf 'case: C1 host lock serializes interleaved account/retire and concurrent account runs\n'
HOST_LOCK="$SYSTEM_ROOT/run/skyeye-alloy.lock"
mkdir -p "$SYSTEM_ROOT/run"
exec 6>>"$HOST_LOCK"
perl -MFcntl=:flock -e 'open(my $fh, ">>&=", 6) or exit 2; exit(flock($fh, LOCK_EX | LOCK_NB) ? 0 : 1)' || \
  fail "could not acquire test lock $HOST_LOCK"
expect_refuse "held shared host lock blocks account add" "skyeye-alloy.lock" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3
exec 6>&-

# Interleaved test: start account add waiting on timer tick (holding lock),
# verify BOTH retire and a second account add are refused while the lock is held.
c1_out_file="$TEST_ROOT/c1-add.out"
SKYEYE_ACCOUNT_VERIFY_TIMEOUT=8 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 \
  >"$c1_out_file" 2>&1 &
c1_pid=$!
BG_PIDS+=("$c1_pid")

# Wait until the first account add has replaced the env and is holding the lock while waiting.
c1_written=0
for ((i = 0; i < 40; i++)); do
  if rg -q '^TQ_EXECUTOR_MAP=.*,popdex-rot3=popdex$' "$MULTI_ENV"; then
    c1_written=1
    break
  fi
  sleep 0.1
done
[[ "$c1_written" -eq 1 ]] || fail "C1: first account add did not enter wait phase"

if retire_race="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" retire --strategy "$MULTI_STRAT" 2>&1)"; then
  fail "C1: retire succeeded while account add held /run/skyeye-alloy.lock"
fi
[[ "$retire_race" == *"skyeye-alloy.lock"* ]] || fail "C1: retire lock refusal unclear: $retire_race"
[[ -f "$MULTI_ENV" ]] || fail "C1: refused retire removed env"

if acct_race="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot4 2>&1)"; then
  fail "C1: concurrent account add succeeded while first account add held lock"
fi
[[ "$acct_race" == *"skyeye-alloy.lock"* ]] || fail "C1: concurrent account refusal unclear: $acct_race"

# Now trigger the simulated timer tick so the first account add commits cleanly.
wait_next_epoch_second "$(date +%s)"
simulate_timer_probe_run "$MULTI_STRAT"
wait "$c1_pid" || fail "C1: first account add failed: $(cat "$c1_out_file")"
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex,popdex-rot3=popdex$'

# Restore back to 2 executors via remove with simulated timer tick.
spawn_timer_tick_on_env_change "$MULTI_STRAT"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 >/dev/null
wait_bg_timer
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex$'

# ---- C2 & C12: Never touches Alloy fragments / shared files / Alloy service; account-only output ----

printf 'case: C2 account update never modifies Alloy fragments, /etc/default/alloy, ACLs, units, or probe.sh\n'
printf 'case: C12 success output contains account-only summary without trading-target or central-deploy instructions\n'
# Introduce deliberate drift in fragment, /etc/default/alloy, probe.sh, and service unit
# to prove account updates never overwrite or depend on matching repo templates.
MULTI_FRAGMENT="$SYSTEM_ROOT/etc/alloy/trading-$MULTI_STRAT.alloy"
printf '\n// custom-loki-template-marker\n' >>"$MULTI_FRAGMENT"
printf '# custom-alloy-env-comment\n' >>"$SYSTEM_ROOT/etc/default/alloy"
printf '\n# host-probe-marker\n' >>"$INSTALLED_PROBE"
printf '\n# host-service-marker\n' >>"$INSTALLED_SERVICE"

immutable_paths=(
  "$MULTI_FRAGMENT"
  "$SYSTEM_ROOT/etc/alloy/trading-metrics.alloy"
  "$SYSTEM_ROOT/etc/default/alloy"
  "$INSTALLED_PROBE"
  "$SYSTEM_ROOT/usr/local/libexec/skyeye-trading/ensure-log-access.sh"
  "$INSTALLED_SERVICE"
  "$SYSTEM_ROOT/etc/systemd/system/skyeye-trading-probe@.timer"
  "$SIBLING_ENV"
  "$SYSTEM_ROOT/etc/alloy/trading-$SIBLING_STRAT.alloy"
  "$SIBLING_PROM"
)
immutable_shas=()
for p in "${immutable_paths[@]}"; do
  immutable_shas+=("$(sha_of "$p")")
done

cp "$MULTI_ENV" "$TEST_ROOT/multi.before-c2"
: >"$SYSTEMCTL_LOG"
spawn_timer_tick_on_env_change "$MULTI_STRAT"
c2_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3)"
wait_bg_timer

assert_no_systemd_mutation "C2 account add"
assert_not_contains "$SYSTEMCTL_LOG" '^(reload|restart) alloy$'
[[ "$c2_out" == *"Account add committed"* &&
   "$c2_out" == *"Inferred exchange from existing TQ_EXECUTOR_MAP: popdex"* &&
   "$c2_out" == *"prom_verified:"* &&
   "$c2_out" == *"Next: add popdex-rot3 to tnauqquant"* ]] || fail "unexpected add output: $c2_out"
# C12: no contradictory onboarding/central-deploy messages
if grep -qE 'scripts/trading-target|central-deploy|--enable-probe' <<<"$c2_out"; then
  fail "C12: account add output contained contradictory onboarding instructions: $c2_out"
fi

for idx in "${!immutable_paths[@]}"; do
  [[ "${immutable_shas[$idx]}" == "$(sha_of "${immutable_paths[$idx]}")" ]] || \
    fail "C2: account add altered untouched file: ${immutable_paths[$idx]}"
done

# Also verify remove + 2->1 single-account transition + explicit --exchange on multi-exchange lane.
spawn_timer_tick_on_env_change "$MULTI_STRAT"
rm_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3)"
wait_bg_timer
[[ "$rm_out" == *"Account remove committed"* ]] || fail "unexpected remove output: $rm_out"
if grep -qE 'scripts/trading-target|central-deploy|--enable-probe' <<<"$rm_out"; then
  fail "C12: account remove output contained contradictory onboarding instructions: $rm_out"
fi
assert_not_contains "$MULTI_PROM" 'executor="popdex-rot3"'

spawn_timer_tick_on_env_change "$MULTI_STRAT"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot2 >/dev/null
wait_bg_timer
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex$'
assert_not_contains "$MULTI_PROM" 'executor='

spawn_timer_tick_on_env_change "$MULTI_STRAT"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot2 >/dev/null
wait_bg_timer
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex$'
assert_contains "$MULTI_PROM" 'executor="popdex-rot2"'

spawn_timer_tick_on_env_change "$MULTI_EXCH_STRAT"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_EXCH_STRAT" \
  --executor mexc-rot2 --exchange mexc >/dev/null
wait_bg_timer
assert_contains "$MULTI_EXCH_ENV" '^TQ_EXECUTOR_MAP=toobit-main=toobit,mexc-ui=mexc,mexc-rot2=mexc$'
# Newly added executor has zero .prom series before tnauqquant restarts, and add still commits.
assert_not_contains "$TEXTFILE_DIR/tnauqquant-$MULTI_EXCH_STRAT.prom" 'executor="mexc-rot2"'
rm -f "$SYSTEMCTL_STATE/active_skyeye-trading-probe@$MULTI_EXCH_STRAT.timer"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_EXCH_STRAT" \
  --executor mexc-rot2 --exchange mexc >/dev/null
touch "$SYSTEMCTL_STATE/active_skyeye-trading-probe@$MULTI_EXCH_STRAT.timer"
assert_contains "$MULTI_EXCH_ENV" '^TQ_EXECUTOR_MAP=toobit-main=toobit,mexc-ui=mexc$'

# ---- C4: Post-write baseline rejects missing timer trigger & in-flight pre-write probes ----

printf 'case: C4 active timer waits for post-write timer-triggered .prom snapshot and fails when timer never triggers\n'
env_before_c4="$(sha_of "$MULTI_ENV")"
# Refresh .prom right BEFORE account add (simulating a recent sample) and DO NOT
# spawn any timer tick after the env write -> must time out and roll back!
simulate_timer_probe_run "$MULTI_STRAT"
rc=0
c4_out="$(SKYEYE_ACCOUNT_VERIFY_TIMEOUT=2 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "C4: no-timer-trigger expected rc=1, got rc=$rc: $c4_out"
[[ "$(sha_of "$MULTI_ENV")" == "$env_before_c4" ]] || fail "C4: no-timer-trigger did not restore env"
[[ "$c4_out" == *"timer may not have triggered"* ]] || fail "C4: error did not report missing timer trigger: $c4_out"

printf 'case: C4 in-flight probe started before env write delivering old map after write is excluded\n'
# Subcase 4a: A probe invocation started BEFORE account add (holding the old
# env in memory) finishes AFTER the env write and publishes a newer timestamp
# with the old allowlist. Without a subsequent post-write timer run, add MUST
# fail and roll back instead of accepting the stale-env snapshot.
MULTI_SVC="skyeye-trading-probe@${MULTI_STRAT}.service"
cp "$MULTI_ENV" "$TEST_ROOT/multi.inflight-old.env"
chmod 600 "$TEST_ROOT/multi.inflight-old.env"
bump_probe_invocation "$MULTI_STRAT"
touch "$SYSTEMCTL_STATE/activating_${MULTI_SVC}"

(
  if wait_env_change_and_next_second "$MULTI_ENV"; then
    # In-flight pre-write probe finishes with the OLD env (same InvocationID!)
    # shellcheck disable=SC2016
    env -i PATH="$PATH" FAKE_UTC_HM="12:00" bash -c \
      'set -a; source "$1"; set +a; exec "$2"' bash "$TEST_ROOT/multi.inflight-old.env" "$INSTALLED_PROBE"
    rm -f "$SYSTEMCTL_STATE/activating_${MULTI_SVC}"
  fi
) &
inflight_fail_pid=$!
BG_PIDS+=("$inflight_fail_pid")

rc=0
c4_inf_fail="$(SKYEYE_ACCOUNT_VERIFY_TIMEOUT=2 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || rc=$?
wait "$inflight_fail_pid" 2>/dev/null || true
rm -f "$SYSTEMCTL_STATE/activating_${MULTI_SVC}"
[[ "$rc" -eq 1 ]] || fail "C4 in-flight old-map probe falsely succeeded (rc=$rc): $c4_inf_fail"
[[ "$(sha_of "$MULTI_ENV")" == "$env_before_c4" ]] || fail "C4 in-flight failure did not restore env"
[[ "$c4_inf_fail" == *"started before or during write"* ]] || \
  fail "C4 in-flight failure reason unclear: $c4_inf_fail"

# Subcase 4b: Same in-flight pre-write probe delivers old-map snapshot at t1 > POST_WRITE_EPOCH,
# followed by a genuinely new post-write timer run at t2 > t1 with the NEW env (where the newly
# added executor popdex-rot3 has NO equity series yet because tnauqquant has not restarted). Must
# exclude t1, accept t2, and commit cleanly!
bump_probe_invocation "$MULTI_STRAT"
touch "$SYSTEMCTL_STATE/activating_${MULTI_SVC}"
INFLIGHT_TS_FILE="$TEST_ROOT/c4-inflight-t1.txt"
rm -f "$INFLIGHT_TS_FILE"

(
  if wait_env_change_and_next_second "$MULTI_ENV"; then
    # 1) In-flight pre-write probe finishes with OLD env (same InvocationID!)
    # shellcheck disable=SC2016
    env -i PATH="$PATH" FAKE_UTC_HM="12:00" bash -c \
      'set -a; source "$1"; set +a; exec "$2"' bash "$TEST_ROOT/multi.inflight-old.env" "$INSTALLED_PROBE"
    rm -f "$SYSTEMCTL_STATE/activating_${MULTI_SVC}"
    t1="$(awk '/^tnauqquant_probe_timestamp_seconds\{/ { print $NF; exit }' "$MULTI_PROM")"
    printf '%s\n' "$t1" >"$INFLIGHT_TS_FILE"
    # 2) Next timer tick starts strictly AFTER write with NEW env & new InvocationID
    wait_next_epoch_second "$(date +%s)"
    simulate_timer_probe_run "$MULTI_STRAT"
  fi
) &
inflight_ok_pid=$!
BG_PIDS+=("$inflight_ok_pid")

c4_inf_rc=0
c4_inf_ok="$(SKYEYE_ACCOUNT_VERIFY_TIMEOUT=10 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || c4_inf_rc=$?
wait "$inflight_ok_pid" 2>/dev/null || true
rm -f "$SYSTEMCTL_STATE/activating_${MULTI_SVC}"
[[ "$c4_inf_rc" -eq 0 ]] || fail "C4 in-flight recovery failed (rc=$c4_inf_rc): $c4_inf_ok"
[[ -f "$INFLIGHT_TS_FILE" ]] || fail "C4 in-flight recovery helper never wrote $INFLIGHT_TS_FILE"
t1_ts="$(cat "$INFLIGHT_TS_FILE")"
t2_ts="$(sed -n 's/.*probe_timestamp_seconds=\([0-9]*\).*/\1/p' <<<"$c4_inf_ok" | head -n 1)"
[[ "$c4_inf_ok" == *"Account add committed"* && -n "$t1_ts" && -n "$t2_ts" && "$t2_ts" -gt "$t1_ts" ]] || \
  fail "C4 in-flight recovery did not wait for post-write run (t1=$t1_ts t2=$t2_ts): $c4_inf_ok"
# Before tnauqquant restarts with popdex-rot3, popdex-rot3 has no equity series in .prom
# (equity stays fail-closed while strategy totals keep publishing).
assert_not_contains "$MULTI_PROM" 'tnauqquant_current_executor_equity_usdt.*executor="popdex-rot3"'

# Restore back to 2 executors (fast inactive cleanup)
rm -f "$MULTI_TIMER_ACTIVE"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 >/dev/null
touch "$MULTI_TIMER_ACTIVE"
[[ "$(sha_of "$MULTI_ENV")" == "$env_before_c4" ]] || fail "C4 cleanup did not restore 2-executor env"

# Also verify unexpected executor in post-write .prom triggers rollback, and failed probe service triggers rollback.
touch "$SYSTEMCTL_STATE/failed_skyeye-trading-probe@$MULTI_STRAT.service"
rc=0
fail_svc_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || rc=$?
rm -f "$SYSTEMCTL_STATE/failed_skyeye-trading-probe@$MULTI_STRAT.service"
[[ "$rc" -eq 1 && "$fail_svc_out" == *"entered failed state"* ]] || \
  fail "failed probe service rollback check failed (rc=$rc): $fail_svc_out"
[[ "$(sha_of "$MULTI_ENV")" == "$env_before_c4" ]] || fail "failed probe service did not restore env"

# Unexpected executor written by a post-write probe run triggers rollback
(
  if wait_env_change_and_next_second "$MULTI_ENV"; then
    bump_probe_invocation "$MULTI_STRAT"
    {
      printf 'tnauqquant_probe_timestamp_seconds{product="tnauqquant",environment="production",server_id="trading01",strategy="%s"} %s\n' "$MULTI_STRAT" "$(date +%s)"
      printf 'tnauqquant_current_run_executor_volume_usd{product="tnauqquant",environment="production",server_id="trading01",strategy="%s",exchange="popdex",executor="ghost-exec"} 10\n' "$MULTI_STRAT"
    } >"$MULTI_PROM"
  fi
) &
ghost_pid=$!
BG_PIDS+=("$ghost_pid")
rc=0
ghost_out="$(SKYEYE_ACCOUNT_VERIFY_TIMEOUT=2 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || rc=$?
wait "$ghost_pid" 2>/dev/null || true
[[ "$rc" -eq 1 && "$ghost_out" == *"ghost-exec"* ]] || fail "unexpected executor check failed (rc=$rc): $ghost_out"
[[ "$(sha_of "$MULTI_ENV")" == "$env_before_c4" ]] || fail "unexpected executor did not restore env"
# Restore clean .prom
simulate_timer_probe_run "$MULTI_STRAT"

# All 4 timer state combinations preserved; inactive timers verify env/timer only (no .prom wait).
printf 'case: timer state preservation across all four enabled/active combinations\n'
rm -f "$MULTI_TIMER_ENABLED" "$MULTI_TIMER_ACTIVE"
: >"$SYSTEMCTL_LOG"
t_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3)"
[[ ! -e "$MULTI_TIMER_ENABLED" && ! -e "$MULTI_TIMER_ACTIVE" ]] || fail "disabled/inactive timer changed"
assert_no_systemd_mutation "disabled/inactive add"
[[ "$t_out" == *"timer_state: disabled/inactive (preserved)"* &&
   "$t_out" == *"not verified because probe timer remains disabled/inactive"* ]] || \
  fail "disabled/inactive output unclear: $t_out"
if grep -qE 'scripts/trading-target|central-deploy|--enable-probe' <<<"$t_out"; then
  fail "C12: inactive timer output contained onboarding/temp hints: $t_out"
fi

touch "$MULTI_TIMER_ENABLED"
rm -f "$MULTI_TIMER_ACTIVE"
: >"$SYSTEMCTL_LOG"
t_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3)"
[[ -e "$MULTI_TIMER_ENABLED" && ! -e "$MULTI_TIMER_ACTIVE" ]] || fail "enabled/inactive timer changed"
assert_no_systemd_mutation "enabled/inactive remove"
[[ "$t_out" == *"timer_state: enabled/inactive (preserved)"* ]] || fail "enabled/inactive output unclear: $t_out"

rm -f "$MULTI_TIMER_ENABLED"
touch "$MULTI_TIMER_ACTIVE"
spawn_timer_tick_on_env_change "$MULTI_STRAT"
t_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3)"
wait_bg_timer
[[ ! -e "$MULTI_TIMER_ENABLED" && -e "$MULTI_TIMER_ACTIVE" ]] || fail "disabled/active timer changed"
[[ "$t_out" == *"timer_state: disabled/active (preserved)"* && "$t_out" == *"prom_verified:"* ]] || \
  fail "disabled/active output unclear: $t_out"

touch "$MULTI_TIMER_ENABLED" "$MULTI_TIMER_ACTIVE"
spawn_timer_tick_on_env_change "$MULTI_STRAT"
t_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3)"
wait_bg_timer
[[ -e "$MULTI_TIMER_ENABLED" && -e "$MULTI_TIMER_ACTIVE" ]] || fail "enabled/active timer changed"
[[ "$t_out" == *"timer_state: enabled/active (preserved)"* && "$t_out" == *"prom_verified:"* ]] || \
  fail "enabled/active output unclear: $t_out"

# ---- C3: SIGTERM after write + second SIGTERM/SIGHUP mid-rollback still completes rollback ----

printf 'case: C3 SIGTERM after env write ignores follow-up SIGTERM/SIGHUP during rollback and completes restore\n'
env_before_c3="$(sha_of "$MULTI_ENV")"
c3_out="$TEST_ROOT/c3-term.out"
C3_IN_RB_FLAG="$TEST_ROOT/c3-in-rollback"
C3_RELEASE_FLAG="$TEST_ROOT/c3-second-term-sent"
rm -f "$C3_IN_RB_FLAG" "$C3_RELEASE_FLAG"

C3_RB_HOOK="$TEST_ROOT/c3-rollback-hook.sh"
cat >"$C3_RB_HOOK" <<EOF
#!/usr/bin/env bash
touch "$C3_IN_RB_FLAG"
for ((k = 0; k < 40; k++)); do
  [[ -e "$C3_RELEASE_FLAG" ]] && break
  perl -e 'select(undef, undef, undef, 0.05)'
done
# Small extra pause so the second SIGTERM/SIGHUP is definitely delivered before cp completes.
perl -e 'select(undef, undef, undef, 0.15)'
EOF
chmod 755 "$C3_RB_HOOK"

FAKE_FAIL_CP_PATTERN=".env.before" FAKE_FAIL_CP_EXIT=0 FAKE_CP_HOOK="$C3_RB_HOOK" \
  SKYEYE_ACCOUNT_VERIFY_TIMEOUT=15 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 \
  >"$c3_out" 2>&1 &
c3_pid=$!
BG_PIDS+=("$c3_pid")

c3_mutated=0
for ((i = 0; i < 60; i++)); do
  if rg -q '^TQ_EXECUTOR_MAP=.*,popdex-rot3=popdex$' "$MULTI_ENV"; then
    c3_mutated=1
    break
  fi
  perl -e 'select(undef, undef, undef, 0.05)'
done
[[ "$c3_mutated" -eq 1 ]] || fail "C3: env was not mutated before sending first SIGTERM"

# First SIGTERM initiates transactional rollback.
kill -TERM "$c3_pid"

c3_entered_rb=0
for ((i = 0; i < 60; i++)); do
  if [[ -e "$C3_IN_RB_FLAG" ]]; then
    c3_entered_rb=1
    break
  fi
  perl -e 'select(undef, undef, undef, 0.05)'
done
[[ "$c3_entered_rb" -eq 1 ]] || fail "C3: rollback copy hook was never entered"

# Deliver follow-up SIGTERM and SIGHUP while rollback is mid-restore!
kill -TERM "$c3_pid"
kill -HUP "$c3_pid"
touch "$C3_RELEASE_FLAG"

c3_rc=0
wait "$c3_pid" || c3_rc=$?
[[ "$c3_rc" -eq 143 ]] || fail "C3: expected SIGTERM exit 143 after second TERM mid-rollback, got $c3_rc: $(cat "$c3_out")"
[[ "$(sha_of "$MULTI_ENV")" == "$env_before_c3" ]] || fail "C3: follow-up SIGTERM interrupted rollback and left env mutated"
c3_dir="$(sed -n 's/^Backup record: //p' "$c3_out" | head -n 1)"
assert_contains "$c3_dir/account.meta" '^status=rolled_back$'
assert_contains "$c3_dir/account.meta" '^rollback_reason=interrupted by SIGTERM$'
assert_not_contains "$c3_dir/account.meta" '^status=committed$'
leftover_tmp="$(find "$SYSTEM_ROOT/etc/skyeye-trading/instances" -name '*.tmp.*' -print)"
[[ -z "$leftover_tmp" ]] || fail "C3: leftover staged temp files after SIGTERM: $leftover_tmp"

# ---- C6 & C20: Separate env & timer rollback accounting via root-safe cp stub ----

printf 'case: C6 & C20 incomplete rollback reports env and timer results separately using cp stub (root-safe, no chmod 500)\n'
env_before_c6="$(sha_of "$MULTI_ENV")"
cp "$MULTI_ENV" "$TEST_ROOT/multi.c6-save"

# 1) Env restore fails via cp stub rejecting only .env.before restore copy (works under root too)
#    while timer stays intact.
HOOK_FAIL_SVC="$TEST_ROOT/hook-fail-svc.sh"
cat >"$HOOK_FAIL_SVC" <<EOF
#!/usr/bin/env bash
if [[ "\$(shasum -a 256 "$MULTI_ENV" | awk '{print \$1}')" != "$env_before_c6" ]]; then
  touch "$SYSTEMCTL_STATE/failed_skyeye-trading-probe@$MULTI_STRAT.service"
fi
EOF
chmod 755 "$HOOK_FAIL_SVC"

rc=0
c6_env_out="$(FAKE_FAIL_CP_PATTERN=".env.before" FAKE_FAIL_CP_EXIT=1 \
  FAKE_SHOW_SERVICE_HOOK="$HOOK_FAIL_SVC" SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || rc=$?
rm -f "$SYSTEMCTL_STATE/failed_skyeye-trading-probe@$MULTI_STRAT.service"

[[ "$rc" -eq 3 ]] || fail "C6/C20 env restore failure expected rc=3, got rc=$rc: $c6_env_out"
c6_dir="$(sed -n 's/^Backup record: //p' <<<"$c6_env_out" | head -n 1)"
assert_contains "$c6_dir/account.meta" '^status=rollback_incomplete$'
assert_contains "$c6_dir/account.meta" '^rollback_env_restored=0$'
assert_contains "$c6_dir/account.meta" '^rollback_timer_preserved=1$'
[[ "$c6_env_out" == *"CRITICAL: rollback_incomplete"* &&
   "$c6_env_out" == *"Env restore FAILED"* &&
   "$c6_env_out" == *"sudo install -m 600 $c6_dir/$MULTI_STRAT.env.before $MULTI_ENV"* &&
   "$c6_env_out" == *"sudo cmp -s $c6_dir/$MULTI_STRAT.env.before $MULTI_ENV"* &&
   "$c6_env_out" != *"original env was restored"* ]] || \
  fail "C6/C20 env restore failure message inaccurate: $c6_env_out"
# Restore fixture env back to pre-C6 state
install -m 600 "$TEST_ROOT/multi.c6-save" "$MULTI_ENV"

# 2) Env restore succeeds, timer drifts during verification
HOOK_TIMER_DRIFT="$TEST_ROOT/hook-timer-drift.sh"
cat >"$HOOK_TIMER_DRIFT" <<EOF
#!/usr/bin/env bash
if [[ "\$(shasum -a 256 "$MULTI_ENV" | awk '{print \$1}')" != "$env_before_c6" ]]; then
  rm -f "$MULTI_TIMER_ACTIVE"
fi
EOF
chmod 755 "$HOOK_TIMER_DRIFT"
rc=0
c6_tm_out="$(FAKE_SHOW_SERVICE_HOOK="$HOOK_TIMER_DRIFT" SKYEYE_ACCOUNT_VERIFY_TIMEOUT=2 \
  SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || rc=$?
touch "$MULTI_TIMER_ACTIVE"

[[ "$rc" -eq 3 ]] || fail "C6 timer drift rollback expected rc=3, got rc=$rc: $c6_tm_out"
[[ "$(sha_of "$MULTI_ENV")" == "$env_before_c6" ]] || fail "C6 timer drift did not restore env"
c6_tm_dir="$(sed -n 's/^Backup record: //p' <<<"$c6_tm_out" | head -n 1)"
assert_contains "$c6_tm_dir/account.meta" '^status=rollback_incomplete$'
assert_contains "$c6_tm_dir/account.meta" '^rollback_env_restored=1$'
assert_contains "$c6_tm_dir/account.meta" '^rollback_timer_preserved=0$'
[[ "$c6_tm_out" == *"Env restore OK"* && "$c6_tm_out" == *"Timer state check FAILED"* ]] || \
  fail "C6 timer drift message inaccurate: $c6_tm_out"

# ---- C13: Exact byte preservation including missing trailing newline ----

printf 'case: C13 single-line replacement preserves exact bytes and missing final newline\n'
cp "$MULTI_ENV" "$TEST_ROOT/multi.c13-orig"

# Case 13a: final line is OTHER variable with NO trailing newline
perl -e '
  open my $in, "<:raw", $ARGV[0] or die $!;
  local $/; my $d = <$in>; close $in;
  $d =~ s/\n\z//;
  open my $out, ">:raw", $ARGV[1] or die $!;
  print $out $d; close $out;
' "$TEST_ROOT/multi.c13-orig" "$MULTI_ENV"
chmod 600 "$MULTI_ENV"
cp "$MULTI_ENV" "$TEST_ROOT/multi.c13a-before"

rm -f "$MULTI_TIMER_ACTIVE" # fast inactive apply to test byte preservation directly
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 >/dev/null
perl -e '
  sub slurp { open my $f, "<:raw", $_[0] or die $!; local $/; my $d = <$f>; close $f; $d }
  my $before = slurp($ARGV[0]);
  my $after  = slurp($ARGV[1]);
  die "trailing newline was added!\n" if $after =~ /\n\z/;
  my $exp = $before;
  $exp =~ s/^TQ_EXECUTOR_MAP=[^\n]*/TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex,popdex-rot3=popdex/m;
  die "bytes outside TQ_EXECUTOR_MAP differed!\n" unless $after eq $exp;
' "$TEST_ROOT/multi.c13a-before" "$MULTI_ENV" || fail "C13a failed byte/no-trailing-newline preservation"

# Case 13b: TQ_EXECUTOR_MAP itself is the final line with NO trailing newline
{
  grep -v '^TQ_EXECUTOR_MAP=' "$TEST_ROOT/multi.c13-orig"
  printf 'TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex'
} >"$MULTI_ENV"
chmod 600 "$MULTI_ENV"
cp "$MULTI_ENV" "$TEST_ROOT/multi.c13b-before"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 >/dev/null
perl -e '
  sub slurp { open my $f, "<:raw", $_[0] or die $!; local $/; my $d = <$f>; close $f; $d }
  my $before = slurp($ARGV[0]);
  my $after  = slurp($ARGV[1]);
  die "trailing newline was added on final TQ_EXECUTOR_MAP line!\n" if $after =~ /\n\z/;
  my $exp = $before;
  $exp =~ s/TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex\z/TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex,popdex-rot3=popdex/;
  die "bytes differed when TQ_EXECUTOR_MAP was last line!\n" unless $after eq $exp;
' "$TEST_ROOT/multi.c13b-before" "$MULTI_ENV" || fail "C13b failed when TQ_EXECUTOR_MAP was final line without newline"

# Restore normal env and active timer
install -m 600 "$TEST_ROOT/multi.c13-orig" "$MULTI_ENV"
touch "$MULTI_TIMER_ENABLED" "$MULTI_TIMER_ACTIVE"

# ---- C7, C8, C9, C11: Wrapper remote upload + PTY -t + retry preservation + no --remote-dir ----

printf 'case: C11 SSH stub fixed via absolute SKYEYE_SSH_BIN before first wrapper call and never invoked on negative cases\n'
printf 'case: C9 --remote-dir is removed and remote mode uploads only minimal helper scripts without staged checkout\n'
for bad_wrap in \
  "add --server trading01 --strategy $MULTI_STRAT --executor popdex-rot3 --remote-dir /home/ubuntu/skyeye-staging/popdex-589d4ae" \
  "add --server trading01 --strategy $MULTI_STRAT --executor popdex-rot3 --ssh-target -oProxyCommand=id" \
  "add --server trading01 --strategy $MULTI_STRAT --executor popdex-rot3 --local --ssh-target trading01" \
  "list --server trading01 --strategy $MULTI_STRAT --executor popdex-main" \
  "list --server trading01 --strategy $MULTI_STRAT --dry-run"
do
  : >"$SSH_LOG"
  # Intentional word splitting to build each argument vector.
  # shellcheck disable=SC2086
  if "$WRAPPER" $bad_wrap >/dev/null 2>&1; then
    fail "wrapper accepted invalid args: $bad_wrap"
  fi
  [[ ! -s "$SSH_LOG" ]] || fail "C11: negative wrapper case invoked ssh: $bad_wrap"
done

# --local mode runs without SSH
: >"$SSH_LOG"
spawn_timer_tick_on_env_change "$MULTI_STRAT"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$WRAPPER" add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --local >/dev/null
wait_bg_timer
[[ ! -s "$SSH_LOG" ]] || fail "--local invoked ssh"
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex,popdex-rot3=popdex$'

rm -f "$MULTI_TIMER_ACTIVE"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$WRAPPER" remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --local >/dev/null
touch "$MULTI_TIMER_ACTIVE"
[[ ! -s "$SSH_LOG" ]] || fail "--local remove invoked ssh"
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex$'

# Remote non-TTY mode: uploads ONLY the 3 minimal scripts (-T), executes via sudo -n (-T),
# and cleans up remote temp dir (-T).
: >"$SSH_LOG"
spawn_timer_tick_on_env_change "$MULTI_STRAT"
remote_out="$(FAKE_SSH_EXEC_LOCAL=1 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$WRAPPER" add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --ssh-target ubuntu@t01)"
wait_bg_timer
[[ "$remote_out" == *"Account add committed"* ]] || fail "remote add failed: $remote_out"
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex,popdex-rot3=popdex$'
assert_contains "$SSH_LOG" '^FLAGS=-T TARGET=ubuntu@t01 CMD=.*__SKYEYE_STAGE__='
assert_contains "$SSH_LOG" '^FLAGS=-T TARGET=ubuntu@t01 CMD=sudo -n -- '
assert_contains "$SSH_LOG" '^FLAGS=-T TARGET=ubuntu@t01 CMD=rm -rf -- '

# Confirm remote temp dir was cleaned up
leftover_remote="$(find "$REMOTE_STAGING_PARENT" -mindepth 1 -maxdepth 1 -print)"
[[ -z "$leftover_remote" ]] || fail "remote temp dir was not cleaned up: $leftover_remote"

# Confirm ONLY the 3 minimal helper scripts were uploaded (no probe.sh, no templates)
expected_tar_files="$(printf '%s\n' \
  agents/alloy/install-common.sh \
  agents/alloy/trading/account-linux.sh \
  agents/alloy/trading/linux-common.sh | LC_ALL=C sort)"
actual_tar_files="$(tar -tf "$TAR_CAPTURE" | LC_ALL=C sort)"
[[ "$actual_tar_files" == "$expected_tar_files" ]] || \
  fail "C9: uploaded tar payload mismatch:
expected:
$expected_tar_files
actual:
$actual_tar_files"

# Clean back to 2 executors via remote remove
rm -f "$MULTI_TIMER_ACTIVE"
FAKE_SSH_EXEC_LOCAL=1 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$WRAPPER" remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --ssh-target ubuntu@t01 >/dev/null
touch "$MULTI_TIMER_ACTIVE"
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex$'

printf 'case: C7 remote wrapper allocates PTY (-t) when attached to interactive TTY and keeps tar upload without PTY (-T)\n'
: >"$SSH_LOG"
pty_rc=0
pty_out="$(python3 -I - "$WRAPPER" "$MULTI_STRAT" "$SYSTEM_ROOT" <<'PYEOF'
import os, pty, select, subprocess, sys
wrapper, strat, sysroot = sys.argv[1:4]
master, slave = pty.openpty()
env = os.environ.copy()
env["FAKE_SSH_EXEC_LOCAL"] = "1"
env["SKYEYE_TRADING_TEST_ROOT"] = sysroot
proc = subprocess.Popen(
    [wrapper, "add", "--server", "trading01", "--strategy", strat,
     "--executor", "popdex-rot3", "--dry-run", "--ssh-target", "ubuntu@t01"],
    stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True,
)
os.close(slave)
chunks = []
while True:
    r, _, _ = select.select([master], [], [], 5.0)
    if not r:
        break
    try:
        data = os.read(master, 4096)
    except OSError:
        break
    if not data:
        break
    chunks.append(data)
os.close(master)
rc = proc.wait(timeout=10)
sys.stdout.buffer.write(b"".join(chunks))
sys.exit(rc)
PYEOF
)" || pty_rc=$?
[[ "$pty_rc" -eq 0 && "$pty_out" == *"Dry run: validation passed"* ]] || \
  fail "C7 PTY execution failed (rc=$pty_rc): $pty_out"
# Step 1 upload MUST be -T (no PTY), Step 2 sudo MUST be -t (PTY, without -n), Step 3 cleanup MUST be -T
assert_contains "$SSH_LOG" '^FLAGS=-T TARGET=ubuntu@t01 CMD=.*__SKYEYE_STAGE__='
assert_contains "$SSH_LOG" '^FLAGS=-t TARGET=ubuntu@t01 CMD=sudo -- '
assert_not_contains "$SSH_LOG" '^FLAGS=-t TARGET=ubuntu@t01 CMD=sudo -n'
assert_contains "$SSH_LOG" '^FLAGS=-T TARGET=ubuntu@t01 CMD=rm -rf -- '
leftover_remote="$(find "$REMOTE_STAGING_PARENT" -mindepth 1 -maxdepth 1 -print)"
[[ -z "$leftover_remote" ]] || fail "C7: PTY run leaked remote temp dir: $leftover_remote"

printf 'case: C8 retry hints preserve --dry-run and --ssh-target in wrapper and preserve host mode directly on host\n'
# 1) Wrapper non-TTY sudo password failure preserves --dry-run and --ssh-target
rc=0
sudo_err="$(FAKE_SSH_SUDO_PW_REQUIRED=1 \
  "$WRAPPER" add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 \
  --exchange popdex --dry-run --ssh-target ubuntu@t01 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "sudo password failure unexpectedly exited 0"
[[ "$sudo_err" == *"scripts/trading-account add --server trading01 --strategy $MULTI_STRAT --executor popdex-rot3 --exchange popdex --dry-run --ssh-target ubuntu@t01"* &&
   "$sudo_err" == *"ssh -t ubuntu@t01"* &&
   "$sudo_err" == *"setup-linux.sh account add --server trading01 --strategy $MULTI_STRAT --executor popdex-rot3 --exchange popdex --dry-run"* ]] || \
  fail "C8: wrapper sudo failure did not preserve --dry-run and --ssh-target: $sudo_err"

# 2) Wrapper UTC refusal preserves --dry-run and --ssh-target
: >"$SSH_LOG"
rc=0
utc_wrap_err="$(FAKE_UTC_HM="18:30" \
  "$WRAPPER" add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 \
  --dry-run --ssh-target ubuntu@t01 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "wrapper UTC refusal unexpectedly exited 0"
[[ "$utc_wrap_err" == *"scripts/trading-account add --server trading01 --strategy $MULTI_STRAT --executor popdex-rot3 --dry-run --ssh-target ubuntu@t01"* ]] || \
  fail "C8: wrapper UTC retry did not preserve --dry-run and --ssh-target: $utc_wrap_err"
[[ ! -s "$SSH_LOG" ]] || fail "C11: UTC refusal called ssh"

# 3) Wrapper host-lock refusal preserves --dry-run and --ssh-target (and does not leak temp dir path)
exec 6>>"$HOST_LOCK"
perl -MFcntl=:flock -e 'open(my $fh, ">>&=", 6) or exit 2; exit(flock($fh, LOCK_EX | LOCK_NB) ? 0 : 1)' || \
  fail "could not acquire test lock for C8"
rc=0
lock_wrap_err="$(FAKE_SSH_EXEC_LOCAL=1 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$WRAPPER" add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 \
  --dry-run --ssh-target ubuntu@t01 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "wrapper lock refusal unexpectedly exited 0"
[[ "$lock_wrap_err" == *"Retry command: scripts/trading-account add --server trading01 --strategy $MULTI_STRAT --executor popdex-rot3 --dry-run --ssh-target ubuntu@t01"* &&
   "$lock_wrap_err" != *"$REMOTE_STAGING_PARENT"* ]] || \
  fail "C8: wrapper lock retry did not preserve --dry-run/--ssh-target or leaked temp dir: $lock_wrap_err"

# 4) Direct host execution gives host-side retry command preserving --dry-run
rc=0
lock_host_err="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --dry-run 2>&1)" || rc=$?
exec 6>&-
[[ "$rc" -ne 0 ]] || fail "direct host lock refusal unexpectedly exited 0"
[[ "$lock_host_err" == *"sudo $TRADING_DIR/setup-linux.sh account add --server trading01 --strategy $MULTI_STRAT --executor popdex-rot3 --dry-run"* ]] || \
  fail "C8: host-side retry did not preserve host mode and --dry-run: $lock_host_err"

# ---- C19: Remote staging ignores space-containing TMPDIR & reports cleanup failures separately ----

printf 'case: C19 remote staging uses supported /tmp path ignoring space-containing remote TMPDIR\n'
: >"$SSH_LOG"
c19_sp_out="$(FAKE_SSH_REMOTE_TMPDIR="/tmp/dir with spaces" FAKE_SSH_EXEC_LOCAL=1 \
  SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$WRAPPER" list --server trading01 --strategy "$MULTI_STRAT" --ssh-target ubuntu@t01)"
[[ "$c19_sp_out" == *"TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex"* ]] || \
  fail "C19 space TMPDIR remote list failed: $c19_sp_out"
c19_rm_path="$(sed -n 's/^FLAGS=-T TARGET=ubuntu@t01 CMD=rm -rf -- '\''\([^'\'']*\)'\''$/\1/p' "$SSH_LOG" | tail -n 1)"
[[ "$c19_rm_path" == /tmp/skyeye-trading-account.* && ! -e "$c19_rm_path" ]] || \
  fail "C19 space TMPDIR did not stage under /tmp or leaked dir: path='$c19_rm_path' log=$(cat "$SSH_LOG")"

printf 'case: C19 remote temp cleanup failure returns non-zero and reports account result and residual path separately\n'
# 1) Read-only list succeeds, but remote rm -rf fails -> rc=4, stdout has list,
#    stderr separates account succeeded (rc=0) from exact residual remote path.
: >"$SSH_LOG"
c19_list_stdout="$TEST_ROOT/c19-list.out"
c19_list_stderr="$TEST_ROOT/c19-list.err"
c19_list_rc=0
FAKE_SSH_CLEANUP_FAIL=1 FAKE_SSH_EXEC_LOCAL=1 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$WRAPPER" list --server trading01 --strategy "$MULTI_STRAT" --ssh-target ubuntu@t01 \
  >"$c19_list_stdout" 2>"$c19_list_stderr" || c19_list_rc=$?
[[ "$c19_list_rc" -eq 4 ]] || \
  fail "C19 cleanup failure on list expected rc=4, got $c19_list_rc: $(cat "$c19_list_stderr")"
assert_contains "$c19_list_stdout" '^configured_executors \(TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex\):$'
c19_residual="$(sed -n 's/^.*residual path on ubuntu@t01: //p' "$c19_list_stderr" | head -n 1)"
[[ -n "$c19_residual" && -d "$c19_residual" ]] || \
  fail "C19 cleanup failure did not report existing residual dir: $(cat "$c19_list_stderr")"
assert_contains "$c19_list_stderr" 'account command result: list succeeded \(rc=0\)'
assert_contains "$c19_list_stderr" 'remote temp cleanup FAILED'
assert_contains "$c19_list_stderr" "Manual cleanup: ssh 'ubuntu@t01' rm -rf -- '$c19_residual'"
rm -rf -- "$c19_residual"

# 2) Committed add succeeds, but remote rm -rf fails -> rc=4, env IS committed,
#    stderr separates add succeeded (rc=0) from exact residual remote path.
rm -f "$MULTI_TIMER_ACTIVE" # fast inactive commit to test wrapper cleanup reporting
c19_add_stdout="$TEST_ROOT/c19-add.out"
c19_add_stderr="$TEST_ROOT/c19-add.err"
c19_add_rc=0
FAKE_SSH_CLEANUP_FAIL=1 FAKE_SSH_EXEC_LOCAL=1 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$WRAPPER" add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --ssh-target ubuntu@t01 \
  >"$c19_add_stdout" 2>"$c19_add_stderr" || c19_add_rc=$?
[[ "$c19_add_rc" -eq 4 ]] || \
  fail "C19 cleanup failure on committed add expected rc=4, got $c19_add_rc: $(cat "$c19_add_stderr")"
assert_contains "$c19_add_stdout" '^Account add committed for trading01/popdex-multi-accounts:$'
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex,popdex-rot3=popdex$'
c19_add_residual="$(sed -n 's/^.*residual path on ubuntu@t01: //p' "$c19_add_stderr" | head -n 1)"
[[ -n "$c19_add_residual" && -d "$c19_add_residual" ]] || \
  fail "C19 cleanup failure on add did not report existing residual dir: $(cat "$c19_add_stderr")"
assert_contains "$c19_add_stderr" 'account command result: add succeeded \(rc=0\)'
assert_contains "$c19_add_stderr" 'remote temp cleanup FAILED'
rm -rf -- "$c19_add_residual"
# Restore 2-executor env and active timer cleanly
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 >/dev/null
touch "$MULTI_TIMER_ACTIVE"

# ---- C14: README bash examples are complete copy-pasteable commands ----

printf 'case: C14 README bash examples are complete copy-pasteable commands without literal brackets\n'
readme_block="$(awk '
  /^### Add or remove an account \(executor\)/ { in_sec = 1; next }
  in_sec && /^### / { exit }
  in_sec && /^~~~bash$/ { in_code = 1; next }
  in_code && /^~~~$/ { exit }
  in_code { print }
' "$README")"
[[ -n "$readme_block" ]] || fail "C14: could not extract bash example block from README"
if grep -qE '\[|\]' <<<"$readme_block"; then
  fail "C14: README bash examples still contain literal brackets:
$readme_block"
fi
# Collapse line continuations and execute every scripts/trading-account example
# safely in read-only / --dry-run --local mode against the test host.
readme_cmds="$(awk '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  {
    line = $0
    if (line ~ /\\$/) {
      sub(/\\$/, "", line)
      buf = buf line " "
    } else {
      print buf line
      buf = ""
    }
  }
' <<<"$readme_block")"
cmd_count=0
while IFS= read -r cmd; do
  [[ -n "$cmd" ]] || continue
  [[ "$cmd" == scripts/trading-account\ * ]] || fail "C14: unexpected command in README block: $cmd"
  cmd_count=$((cmd_count + 1))
  args="${cmd#scripts/trading-account }"
  extra="--local"
  case "$args" in
    list\ *) ;;
    *--dry-run*) ;;
    remove\ *)
      # Use popdex-rot2 (which exists in fixture) for remove dry-run check.
      args="${args/popdex-rot3/popdex-rot2}"
      extra="--dry-run --local"
      ;;
    *)
      extra="--dry-run --local"
      ;;
  esac
  # Intentional word split on documented CLI tokens.
  # shellcheck disable=SC2086
  SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" "$WRAPPER" $args $extra >/dev/null || \
    fail "C14: README example failed to parse/validate: $cmd"
done <<<"$readme_cmds"
[[ "$cmd_count" -ge 5 ]] || fail "C14: expected at least 5 example commands in README, got $cmd_count"

printf 'case: zero tnauqquant unit touches and zero Alloy reloads/restarts across entire run\n'
assert_not_contains "$SYSTEMCTL_LOG_ALL" 'tnauqquant'
assert_not_contains "$SYSTEMCTL_LOG_ALL" '^(reload|restart) alloy$'

printf 'PASS: trading account add/remove/list host and wrapper checks\n'
