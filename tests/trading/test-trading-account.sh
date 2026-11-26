#!/usr/bin/env bash
set -euo pipefail

# Tests for host-side agents/alloy/trading/account-linux.sh (dispatched via
# setup-linux.sh account) and the operator wrapper scripts/trading-account.
# Uses SKYEYE_TRADING_TEST_ROOT and stub binaries so no real host or SSH target
# is ever touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRADING_DIR="$REPO_ROOT/agents/alloy/trading"
SETUP="$TRADING_DIR/setup-linux.sh"
ACCOUNT_HOST="$TRADING_DIR/account-linux.sh"
WRAPPER="$REPO_ROOT/scripts/trading-account"

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

printf 'case: static safety invariants and help text\n'
for script_path in "$SETUP" "$ACCOUNT_HOST" "$WRAPPER"; do
  [[ -x "$script_path" ]] || fail "script must be executable: $script_path"
  bash -n "$script_path" || fail "syntax error in $script_path"
done

assert_not_contains "$ACCOUNT_HOST" 'systemctl.*tnauqquant'
assert_not_contains "$ACCOUNT_HOST" 'SYSTEMCTL_BIN.*tnauqquant'
assert_not_contains "$ACCOUNT_HOST" 'manager[.]env'
assert_not_contains "$ACCOUNT_HOST" 'systemctl.*restart alloy'
assert_not_contains "$ACCOUNT_HOST" 'SYSTEMCTL_BIN.*restart alloy'
assert_not_contains "$WRAPPER" 'systemctl.*tnauqquant'
assert_not_contains "$WRAPPER" 'manager[.]env'
assert_not_contains "$WRAPPER" 'restart alloy'

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
done

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-trading-account-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
cleanup() {
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
ALLOY_CALL_COUNT="$TEST_ROOT/alloy-call-count"
SSH_LOG="$TEST_ROOT/ssh.log"

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
  "$FAKE_REPO/config" \
  "$FAKE_REPO/logs/live-runs" \
  "$FAKE_REPO/run-state/$MULTI_STRAT" \
  "$FAKE_REPO/run-state/$SIBLING_STRAT" \
  "$FAKE_REPO/run-state/$MULTI_EXCH_STRAT" \
  "$FAKE_REPO/bin/$MULTI_STRAT" \
  "$FAKE_REPO/bin/$SIBLING_STRAT" \
  "$FAKE_REPO/bin/$MULTI_EXCH_STRAT" \
  "$TEXTFILE_DIR"

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

# Real configs, executables, manifest, done marker, and raw log so real probe.sh
# emits genuine per-executor metrics for popdex-multi-accounts.
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

# Stub binaries in FAKE_BIN
REAL_DATE="$(command -v date)"
cat >"$FAKE_BIN/date" <<EOF
#!/usr/bin/env bash
if [[ -n "\${FAKE_UTC_HM:-}" && "\${1:-}" == "-u" && "\${2:-}" == "+%H:%M" ]]; then
  printf '%s\n' "\$FAKE_UTC_HM"
  exit 0
fi
exec "$REAL_DATE" "\$@"
EOF

cat >"$FAKE_BIN/alloy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'alloy, version v%s (branch: HEAD, revision: fixture)\n' "${FAKE_ALLOY_VERSION:-1.16.3}"
  exit 0
fi
count=0
[[ ! -f "$ALLOY_CALL_COUNT" ]] || count="$(cat "$ALLOY_CALL_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" >"$ALLOY_CALL_COUNT"
if [[ "${ALLOY_FAIL_ON_CALL:-0}" == "$count" ]]; then
  printf 'fake alloy validate failure\n' >&2
  exit 1
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
      if [[ "${FAKE_PROBE_START_EXIT_FAIL:-0}" == "1" ]]; then
        touch "$(state_path failed "$unit")"
        exit 1
      fi
      if [[ "${FAKE_PROBE_MARK_FAILED:-0}" == "1" ]]; then
        touch "$(state_path failed "$unit")"
        exit 0
      fi
      if [[ "${FAKE_PROBE_STALE:-0}" == "1" ]]; then
        exit 0
      fi
      if [[ "${FAKE_PROBE_UNEXPECTED_EXECUTOR:-0}" == "1" ]]; then
        env_path="$SYSTEM_ROOT/etc/skyeye-trading/instances/$strat.env"
        prom_dir="$(sed -n 's/^TQ_TEXTFILE_DIR=//p' "$env_path" | tail -n 1)"
        prom_name="$(sed -n 's/^TQ_TEXTFILE_NAME=//p' "$env_path" | tail -n 1)"
        {
          printf 'tnauqquant_probe_timestamp_seconds{product="tnauqquant",environment="production",server_id="trading01",strategy="%s"} %s\n' "$strat" "$(date +%s)"
          printf 'tnauqquant_current_run_executor_volume_usd{product="tnauqquant",environment="production",server_id="trading01",strategy="%s",exchange="popdex",executor="ghost-exec"} 10\n' "$strat"
        } >"$prom_dir/$prom_name"
        exit 0
      fi
      env_path="$SYSTEM_ROOT/etc/skyeye-trading/instances/$strat.env"
      probe_bin="$SYSTEM_ROOT/usr/local/libexec/skyeye-trading/probe.sh"
      if [[ -f "$env_path" && -x "$probe_bin" ]]; then
        # Run the real installed probe with the installed strategy env.
        # shellcheck disable=SC2016
        env -i PATH="$PATH" FAKE_UTC_HM="${FAKE_UTC_HM:-}" bash -c \
          'set -a; source "$1"; set +a; exec "$2"' bash "$env_path" "$probe_bin"
      fi
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
    if [[ "${SYSTEMCTL_FAIL_RELOAD_ONCE:-0}" == "1" ]]; then
      marker="$SYSTEMCTL_STATE/fail_reload_once_consumed"
      if [[ ! -e "$marker" ]]; then
        touch "$marker"
        exit 1
      fi
    fi
    [[ "${SYSTEMCTL_FAIL_RELOAD:-0}" != "1" ]] || exit 1
    [[ -e "$(state_path active "$1")" ]] || exit 1
    ;;
  show)
    printf '%s\n' "${FAKE_ALLOY_CAN_RELOAD:-yes}"
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
export SYSTEM_ROOT SYSTEMCTL_STATE SYSTEMCTL_LOG SYSTEMCTL_LOG_ALL ALLOY_CALL_COUNT SSH_LOG
export FAKE_PASSWD_HOME="$TEST_ROOT"
export FAKE_UTC_HM="12:00"
export SKYEYE_ACCOUNT_WAIT_SECONDS=0
export SKYEYE_ACCOUNT_VERIFY_TIMEOUT=2
export SKYEYE_ACCOUNT_POLL_INTERVAL=1

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

# Install all three strategies via setup-linux.sh add.
for strat in "$MULTI_STRAT" "$SIBLING_STRAT" "$MULTI_EXCH_STRAT"; do
  : >"$SYSTEMCTL_LOG"
  SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
    "$SETUP" add --env-file "$TEST_ROOT/$strat.seed.env" >/dev/null
done
# Reset the full systemctl audit log after initial setup so every command below
# is strictly from trading-account / setup-linux.sh account.
: >"$SYSTEMCTL_LOG_ALL"

MULTI_ENV="$SYSTEM_ROOT/etc/skyeye-trading/instances/$MULTI_STRAT.env"
SIBLING_ENV="$SYSTEM_ROOT/etc/skyeye-trading/instances/$SIBLING_STRAT.env"
MULTI_EXCH_ENV="$SYSTEM_ROOT/etc/skyeye-trading/instances/$MULTI_EXCH_STRAT.env"
MULTI_PROM="$TEXTFILE_DIR/tnauqquant-$MULTI_STRAT.prom"
SIBLING_PROM="$TEXTFILE_DIR/tnauqquant-$SIBLING_STRAT.prom"
MULTI_EXCH_PROM="$TEXTFILE_DIR/tnauqquant-$MULTI_EXCH_STRAT.prom"
INSTALLED_PROBE="$SYSTEM_ROOT/usr/local/libexec/skyeye-trading/probe.sh"
INSTALLED_SERVICE="$SYSTEM_ROOT/etc/systemd/system/skyeye-trading-probe@.service"

age_prom() {
  local prom="$1"
  [[ -f "$prom" ]] || return 0
  local aged=$(( $(date +%s) - 30 ))
  LC_ALL=C awk -v ts="$aged" '
    index($0, "tnauqquant_probe_timestamp_seconds{") == 1 {
      sub(/[0-9]+([.][0-9]+)?$/, ts)
    }
    { print }
  ' "$prom" >"$prom.aged"
  mv "$prom.aged" "$prom"
}

assert_no_mutation() {
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

printf 'case: list is read-only and reports configured and .prom series executors\n'
: >"$SYSTEMCTL_LOG"
list_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account list --server trading01 --strategy "$MULTI_STRAT")"
assert_no_mutation "list"
[[ ! -s "$SYSTEMCTL_LOG" ]] || fail "list called systemctl unexpectedly: $(cat "$SYSTEMCTL_LOG")"
[[ "$list_out" == *"TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex"* ]] || \
  fail "list missing TQ_EXECUTOR_MAP: $list_out"
[[ "$list_out" == *"popdex-main	popdex	(equity,real_pnl,cycles,volume)"* &&
   "$list_out" == *"popdex-rot2	popdex	(equity,real_pnl,cycles,volume)"* ]] || \
  fail "list missing .prom series executors: $list_out"

# list also works cleanly when .prom is absent
mv "$MULTI_PROM" "$MULTI_PROM.bak"
list_missing_prom="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account list --server trading01 --strategy "$MULTI_STRAT")"
[[ "$list_missing_prom" == *"(missing)"* && "$list_missing_prom" == *"(prom file missing)"* ]] || \
  fail "list did not handle missing .prom cleanly: $list_missing_prom"
mv "$MULTI_PROM.bak" "$MULTI_PROM"

printf 'case: time protection refuses add/remove in UTC 18:10-19:30 and allows boundaries & list\n'
before_sha="$(sha_of "$MULTI_ENV")"
before_backups="$(backup_count)"
for blocked_time in 18:10 18:30 19:30; do
  : >"$SYSTEMCTL_LOG"
  if out="$(FAKE_UTC_HM="$blocked_time" SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
    "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)"; then
    fail "account add succeeded at blocked UTC $blocked_time"
  fi
  [[ "$out" == *"18:10-19:30"* && "$out" == *"$blocked_time"* ]] || \
    fail "time guard error unclear at $blocked_time: $out"
  assert_no_mutation "blocked add at $blocked_time"
  if out="$(FAKE_UTC_HM="$blocked_time" SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
    "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot2 2>&1)"; then
    fail "account remove succeeded at blocked UTC $blocked_time"
  fi
  assert_no_mutation "blocked remove at $blocked_time"
  if out="$(FAKE_UTC_HM="$blocked_time" SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
    "$WRAPPER" add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --local 2>&1)"; then
    fail "wrapper add succeeded at blocked UTC $blocked_time"
  fi
  [[ "$out" == *"18:10-19:30"* ]] || fail "wrapper time guard error unclear: $out"
done
# list stays allowed during the maintenance window
FAKE_UTC_HM="18:30" SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account list --server trading01 --strategy "$MULTI_STRAT" >/dev/null || \
  fail "read-only list was blocked during UTC 18:30"
# 18:09 and 19:31 are allowed
for ok_time in 18:09 19:31; do
  FAKE_UTC_HM="$ok_time" SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
    "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --dry-run >/dev/null || \
    fail "dry-run add was wrongly blocked at UTC $ok_time"
done
[[ "$before_sha" == "$(sha_of "$MULTI_ENV")" && "$before_backups" == "$(backup_count)" ]] || \
  fail "time-window tests modified env or created backups"

printf 'case: refusal conditions reject invalid operations without mutating host\n'
expect_refuse() {
  local label="$1" pattern="$2"
  shift 2
  : >"$SYSTEMCTL_LOG"
  local out
  if out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" "$@" 2>&1)"; then
    fail "$label unexpectedly succeeded: $out"
  fi
  [[ "$out" == *"$pattern"* ]] || fail "$label error did not contain '$pattern': $out"
  assert_no_mutation "$label"
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

# Wrong mode / symlink env refused
chmod 644 "$MULTI_ENV"
expect_refuse "wrong env mode 644" "mode 600" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3
chmod 600 "$MULTI_ENV"

ln -s "$MULTI_ENV" "$SYSTEM_ROOT/etc/skyeye-trading/instances/symlink-lane.env"
expect_refuse "symlinked env" "symlink" \
  "$SETUP" account add --server trading01 --strategy symlink-lane --executor ex1
rm -f "$SYSTEM_ROOT/etc/skyeye-trading/instances/symlink-lane.env"

# Duplicate TQ_EXECUTOR_MAP lines and non-literal TQ_EXECUTOR_MAP refused
cp "$MULTI_ENV" "$TEST_ROOT/multi.env.save"
printf 'TQ_EXECUTOR_MAP=popdex-main=popdex\n' >>"$MULTI_ENV"
expect_refuse "duplicate TQ_EXECUTOR_MAP lines" "exactly one literal TQ_EXECUTOR_MAP=" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3
# Literal "$EXP" in fixture is intentional.
# shellcheck disable=SC2016
sed 's/^TQ_EXECUTOR_MAP=.*/TQ_EXECUTOR_MAP="$EXP"/' "$TEST_ROOT/multi.env.save" >"$MULTI_ENV"
chmod 600 "$MULTI_ENV"
expect_refuse "non-literal TQ_EXECUTOR_MAP" "cannot be read safely" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3
cp "$TEST_ROOT/multi.env.save" "$MULTI_ENV"
chmod 600 "$MULTI_ENV"

# Shared probe.sh mismatch refused even when EVERY probe timer is stopped and disabled!
probe_orig_sha="$(sha_of "$INSTALLED_PROBE")"
cp "$INSTALLED_PROBE" "$TEST_ROOT/probe.sh.save"
printf '\n# fixture host drift\n' >>"$INSTALLED_PROBE"
probe_drifted_sha="$(sha_of "$INSTALLED_PROBE")"
expect_refuse "shared probe.sh mismatch (probes active)" "Probe CPU limits and shared probe rollout" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3
# Also verify error prints concrete --remote-dir next-step command
probe_err="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1 || true)"
[[ "$probe_err" == *"--remote-dir"* && "$probe_err" == *"agents/alloy/trading/README.md"* ]] || \
  fail "shared probe.sh refusal did not give actionable --remote-dir and README next steps: $probe_err"

# Stop & disable ALL probe timers and confirm it STILL refuses to overwrite probe.sh
mkdir -p "$TEST_ROOT/saved-state"
cp -a "$SYSTEMCTL_STATE"/. "$TEST_ROOT/saved-state/"
rm -f "$SYSTEMCTL_STATE"/*skyeye-trading-probe@*
expect_refuse "shared probe.sh mismatch (all probes stopped)" "never overwrites shared probe.sh" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3
[[ "$(sha_of "$INSTALLED_PROBE")" == "$probe_drifted_sha" ]] || \
  fail "refused probe.sh mismatch modified installed probe.sh"
cp "$TEST_ROOT/probe.sh.save" "$INSTALLED_PROBE"
chmod 755 "$INSTALLED_PROBE"
[[ "$(sha_of "$INSTALLED_PROBE")" == "$probe_orig_sha" ]] || fail "could not restore probe.sh fixture"

# Other shared artifact mismatch (service unit) refused even when all probes stopped
cp "$INSTALLED_SERVICE" "$TEST_ROOT/service.save"
printf '\n# fixture unit drift\n' >>"$INSTALLED_SERVICE"
expect_refuse "shared service unit mismatch" "Probe CPU limits and shared probe rollout" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3
cp "$TEST_ROOT/service.save" "$INSTALLED_SERVICE"
rm -rf "$SYSTEMCTL_STATE"
mkdir -p "$SYSTEMCTL_STATE"
cp -a "$TEST_ROOT/saved-state"/. "$SYSTEMCTL_STATE/"

# Lock refusals: account lock and Alloy lock
for lock_name in skyeye-trading-account.lock skyeye-alloy.lock; do
  lock_file="$SYSTEM_ROOT/run/$lock_name"
  mkdir -p "$SYSTEM_ROOT/run"
  exec 6>>"$lock_file"
  perl -MFcntl=:flock -e 'open(my $fh, ">>&=", 6) or exit 2; exit(flock($fh, LOCK_EX | LOCK_NB) ? 0 : 1)' || \
    fail "could not acquire test lock $lock_file"
  expect_refuse "held lock $lock_name" "$lock_name" \
    "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3
  exec 6>&-
done

# Alloy inactive, CanReload=no, untested version
rm -f "$SYSTEMCTL_STATE/active_alloy"
expect_refuse "Alloy inactive" "Alloy is not active" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3
touch "$SYSTEMCTL_STATE/active_alloy"

: >"$SYSTEMCTL_LOG"
if out="$(FAKE_ALLOY_CAN_RELOAD=no SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)"; then
  fail "account add accepted CanReload=no"
fi
[[ "$out" == *"never restarts Alloy"* ]] || fail "CanReload=no refusal unclear: $out"
assert_no_mutation "CanReload=no"

: >"$SYSTEMCTL_LOG"
if out="$(FAKE_ALLOY_VERSION=1.99.0 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)"; then
  fail "account add accepted untested Alloy version"
fi
[[ "$out" == *"not tested on linux"* ]] || fail "untested Alloy refusal unclear: $out"
assert_no_mutation "untested Alloy"

[[ "$before_sha" == "$(sha_of "$MULTI_ENV")" && "$before_backups" == "$(backup_count)" ]] || \
  fail "refused calls mutated env or created backups"

printf 'case: dry-run validates and reports change without modifying host\n'
: >"$SYSTEMCTL_LOG"
dry_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --dry-run)"
[[ "$dry_out" == *"inferred_exchange: popdex"* &&
   "$dry_out" == *"new TQ_EXECUTOR_MAP: popdex-main=popdex,popdex-rot2=popdex,popdex-rot3=popdex"* &&
   "$dry_out" == *"Dry run: validation passed"* ]] || fail "unexpected dry-run output: $dry_out"
assert_no_mutation "dry-run"
[[ "$before_sha" == "$(sha_of "$MULTI_ENV")" && "$before_backups" == "$(backup_count)" ]] || \
  fail "dry-run mutated env or created backup"

printf 'case: add infers exchange, edits only TQ_EXECUTOR_MAP, reloads Alloy, verifies .prom, preserves sibling & shared files\n'
immutable_paths=(
  "$SIBLING_ENV"
  "$SYSTEM_ROOT/etc/alloy/trading-$SIBLING_STRAT.alloy"
  "$SIBLING_PROM"
  "$INSTALLED_PROBE"
  "$SYSTEM_ROOT/usr/local/libexec/skyeye-trading/ensure-log-access.sh"
  "$SYSTEM_ROOT/etc/alloy/trading-metrics.alloy"
  "$INSTALLED_SERVICE"
  "$SYSTEM_ROOT/etc/systemd/system/skyeye-trading-probe@.timer"
)
immutable_shas=()
for p in "${immutable_paths[@]}"; do
  immutable_shas+=("$(sha_of "$p")")
done

cp "$MULTI_ENV" "$TEST_ROOT/multi.before-add"
age_prom "$MULTI_PROM"
: >"$SYSTEMCTL_LOG"
add_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3)"
[[ "$add_out" == *"Account add committed"* &&
   "$add_out" == *"Inferred exchange from existing TQ_EXECUTOR_MAP: popdex"* &&
   "$add_out" == *"prom_verified:"* ]] || fail "unexpected add output: $add_out"
assert_contains "$SYSTEMCTL_LOG" '^reload alloy$'
assert_not_contains "$SYSTEMCTL_LOG" '^restart alloy$'
assert_not_contains "$SYSTEMCTL_LOG" "skyeye-trading-probe@${SIBLING_STRAT}"

# Exactly one line changed in env
diff_lines="$(diff "$TEST_ROOT/multi.before-add" "$MULTI_ENV" | grep -c '^[<>]' || true)"
[[ "$diff_lines" == "2" ]] || fail "expected single-line diff (2 diff lines), got $diff_lines"
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex,popdex-rot3=popdex$'

# Sibling and shared files untouched
for idx in "${!immutable_paths[@]}"; do
  [[ "${immutable_shas[$idx]}" == "$(sha_of "${immutable_paths[$idx]}")" ]] || \
    fail "account add altered immutable file: ${immutable_paths[$idx]}"
done

# Backup created cleanly with committed status
backup_dir="$(sed -n 's/^Backup record: //p' <<<"$add_out" | head -n 1)"
[[ -d "$backup_dir" && -f "$backup_dir/$MULTI_STRAT.env.before" ]] || \
  fail "backup record missing: $backup_dir"
cmp -s "$TEST_ROOT/multi.before-add" "$backup_dir/$MULTI_STRAT.env.before" || \
  fail "backup env does not match pre-change env"
assert_contains "$backup_dir/account.meta" '^status=committed$'

# list now shows all 3 configured executors and popdex-rot3 in volume/cycles/pnl series
list_after_add="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account list --server trading01 --strategy "$MULTI_STRAT")"
[[ "$list_after_add" == *"popdex-rot3	popdex"* ]] || \
  fail "list after add did not show popdex-rot3: $list_after_add"

printf 'case: explicit --exchange add/remove works on multi-exchange lane\n'
age_prom "$MULTI_EXCH_PROM"
: >"$SYSTEMCTL_LOG"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_EXCH_STRAT" \
  --executor mexc-rot2 --exchange mexc >/dev/null
assert_contains "$MULTI_EXCH_ENV" '^TQ_EXECUTOR_MAP=toobit-main=toobit,mexc-ui=mexc,mexc-rot2=mexc$'
age_prom "$MULTI_EXCH_PROM"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_EXCH_STRAT" \
  --executor mexc-rot2 --exchange mexc >/dev/null
assert_contains "$MULTI_EXCH_ENV" '^TQ_EXECUTOR_MAP=toobit-main=toobit,mexc-ui=mexc$'

printf 'case: remove drops executor from env and .prom (3->2 and 2->1 single-account)\n'
age_prom "$MULTI_PROM"
: >"$SYSTEMCTL_LOG"
rm_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3)"
[[ "$rm_out" == *"Account remove committed"* ]] || fail "unexpected remove output: $rm_out"
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex$'
assert_not_contains "$MULTI_PROM" 'executor="popdex-rot3"'
assert_contains "$MULTI_PROM" 'executor="popdex-main"'
assert_contains "$MULTI_PROM" 'executor="popdex-rot2"'

# 2->1 transitions to single-account mode (no per-executor series emitted)
age_prom "$MULTI_PROM"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot2 >/dev/null
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex$'
assert_not_contains "$MULTI_PROM" 'executor='

# Re-add popdex-rot2 back to restore 2-account state
age_prom "$MULTI_PROM"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot2 >/dev/null
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex$'
assert_contains "$MULTI_PROM" 'executor="popdex-rot2"'

printf 'case: timer state preservation across all four enabled/active combinations\n'
MULTI_TIMER_ENABLED="$SYSTEMCTL_STATE/enabled_skyeye-trading-probe@$MULTI_STRAT.timer"
MULTI_TIMER_ACTIVE="$SYSTEMCTL_STATE/active_skyeye-trading-probe@$MULTI_STRAT.timer"

# 1) disabled + inactive
rm -f "$MULTI_TIMER_ENABLED" "$MULTI_TIMER_ACTIVE"
: >"$SYSTEMCTL_LOG"
t_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3)"
[[ ! -e "$MULTI_TIMER_ENABLED" && ! -e "$MULTI_TIMER_ACTIVE" ]] || \
  fail "disabled/inactive timer was started or enabled"
assert_not_contains "$SYSTEMCTL_LOG" "^(enable|start)( --now)? skyeye-trading-probe@${MULTI_STRAT}[.]"
[[ "$t_out" == *"timer_state: disabled/inactive (preserved)"* &&
   "$t_out" == *"live .prom wait not run because probe timer remains disabled/inactive"* ]] || \
  fail "disabled/inactive output unclear: $t_out"

# 2) enabled + inactive
touch "$MULTI_TIMER_ENABLED"
rm -f "$MULTI_TIMER_ACTIVE"
: >"$SYSTEMCTL_LOG"
t_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3)"
[[ -e "$MULTI_TIMER_ENABLED" && ! -e "$MULTI_TIMER_ACTIVE" ]] || \
  fail "enabled/inactive timer changed state"
assert_not_contains "$SYSTEMCTL_LOG" "^start skyeye-trading-probe@${MULTI_STRAT}[.]"
[[ "$t_out" == *"timer_state: enabled/inactive (preserved)"* ]] || \
  fail "enabled/inactive output unclear: $t_out"

# 3) disabled + active
rm -f "$MULTI_TIMER_ENABLED"
touch "$MULTI_TIMER_ACTIVE"
age_prom "$MULTI_PROM"
: >"$SYSTEMCTL_LOG"
t_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3)"
[[ ! -e "$MULTI_TIMER_ENABLED" && -e "$MULTI_TIMER_ACTIVE" ]] || \
  fail "disabled/active timer changed state"
[[ "$t_out" == *"timer_state: disabled/active (preserved)"* && "$t_out" == *"prom_verified:"* ]] || \
  fail "disabled/active output unclear: $t_out"

# 4) enabled + active (back to normal)
touch "$MULTI_TIMER_ENABLED" "$MULTI_TIMER_ACTIVE"
age_prom "$MULTI_PROM"
: >"$SYSTEMCTL_LOG"
t_out="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3)"
[[ -e "$MULTI_TIMER_ENABLED" && -e "$MULTI_TIMER_ACTIVE" ]] || \
  fail "enabled/active timer changed state"
[[ "$t_out" == *"timer_state: enabled/active (preserved)"* && "$t_out" == *"prom_verified:"* ]] || \
  fail "enabled/active output unclear: $t_out"

printf 'case: automatic rollback on Alloy reload failure (transient and persistent)\n'
env_before_rb="$(sha_of "$MULTI_ENV")"

# Transient reload failure during setup-linux.sh add: restores cleanly, exit 1, never restarts Alloy
rm -f "$SYSTEMCTL_STATE/fail_reload_once_consumed"
: >"$SYSTEMCTL_LOG"
rc=0
rb_out="$(SYSTEMCTL_FAIL_RELOAD_ONCE=1 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "transient reload failure expected rc=1, got rc=$rc: $rb_out"
[[ "$(sha_of "$MULTI_ENV")" == "$env_before_rb" ]] || fail "transient reload failure did not restore env"
[[ -e "$MULTI_TIMER_ENABLED" && -e "$MULTI_TIMER_ACTIVE" ]] || fail "transient reload failure did not restore timer"
assert_not_contains "$SYSTEMCTL_LOG" '^restart alloy$'
rb_dir="$(sed -n 's/^Backup record: //p' <<<"$rb_out" | head -n 1)"
assert_contains "$rb_dir/account.meta" '^status=rolled_back$'

# Persistent reload failure: restores env & timer, reports rollback_incomplete, exit 3, never restarts Alloy
: >"$SYSTEMCTL_LOG"
rc=0
rb_out="$(SYSTEMCTL_FAIL_RELOAD=1 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || rc=$?
[[ "$rc" -eq 3 ]] || fail "persistent reload failure expected rc=3, got rc=$rc: $rb_out"
[[ "$(sha_of "$MULTI_ENV")" == "$env_before_rb" ]] || fail "persistent reload failure did not restore env"
[[ -e "$MULTI_TIMER_ENABLED" && -e "$MULTI_TIMER_ACTIVE" ]] || fail "persistent reload failure did not restore timer"
[[ "$rb_out" == *"CRITICAL: rollback_incomplete"* && "$rb_out" == *"sudo systemctl reload alloy"* ]] || \
  fail "persistent reload failure did not print recovery instructions: $rb_out"
assert_not_contains "$SYSTEMCTL_LOG" '^restart alloy$'
rb_dir="$(sed -n 's/^Backup record: //p' <<<"$rb_out" | head -n 1)"
assert_contains "$rb_dir/account.meta" '^status=rollback_incomplete$'

printf 'case: automatic rollback on probe failure, stale .prom timeout, and unexpected executor in .prom\n'
# 1) Probe service enters failed state after add
age_prom "$MULTI_PROM"
: >"$SYSTEMCTL_LOG"
rc=0
rb_out="$(FAKE_PROBE_MARK_FAILED=1 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || rc=$?
rm -f "$SYSTEMCTL_STATE/failed_skyeye-trading-probe@$MULTI_STRAT.service"
[[ "$rc" -eq 1 ]] || fail "failed probe service expected rc=1, got rc=$rc: $rb_out"
[[ "$(sha_of "$MULTI_ENV")" == "$env_before_rb" ]] || fail "failed probe rollback did not restore env"
[[ -e "$MULTI_TIMER_ENABLED" && -e "$MULTI_TIMER_ACTIVE" ]] || fail "failed probe rollback did not restore timer"
[[ "$rb_out" == *"entered failed state"* ]] || fail "failed probe rollback did not name failed service: $rb_out"
assert_not_contains "$SYSTEMCTL_LOG" '^restart alloy$'
rb_dir="$(sed -n 's/^Backup record: //p' <<<"$rb_out" | head -n 1)"
assert_contains "$rb_dir/account.meta" '^status=rolled_back$'

# 2) .prom never updates (timeout)
age_prom "$MULTI_PROM"
: >"$SYSTEMCTL_LOG"
rc=0
rb_out="$(FAKE_PROBE_STALE=1 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "stale .prom expected rc=1, got rc=$rc: $rb_out"
[[ "$(sha_of "$MULTI_ENV")" == "$env_before_rb" ]] || fail "stale .prom rollback did not restore env"
[[ -e "$MULTI_TIMER_ENABLED" && -e "$MULTI_TIMER_ACTIVE" ]] || fail "stale .prom rollback did not restore timer"
[[ "$rb_out" == *"did not advance"* ]] || fail "stale .prom rollback did not report stale timestamp: $rb_out"
assert_not_contains "$SYSTEMCTL_LOG" '^restart alloy$'
rb_dir="$(sed -n 's/^Backup record: //p' <<<"$rb_out" | head -n 1)"
assert_contains "$rb_dir/account.meta" '^status=rolled_back$'

# 3) .prom contains disallowed/unexpected executor series
age_prom "$MULTI_PROM"
: >"$SYSTEMCTL_LOG"
rc=0
rb_out="$(FAKE_PROBE_UNEXPECTED_EXECUTOR=1 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" account add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "unexpected executor in .prom expected rc=1, got rc=$rc: $rb_out"
[[ "$(sha_of "$MULTI_ENV")" == "$env_before_rb" ]] || fail "unexpected executor rollback did not restore env"
[[ "$rb_out" == *"unexpected executor series"* && "$rb_out" == *"ghost-exec"* ]] || \
  fail "unexpected executor rollback did not name ghost-exec: $rb_out"
assert_not_contains "$SYSTEMCTL_LOG" '^restart alloy$'

# Refresh clean .prom after the ghost-exec test
"$FAKE_BIN/systemctl" start "skyeye-trading-probe@$MULTI_STRAT.service"

printf 'case: scripts/trading-account wrapper (--local, SSH stream, --remote-dir, sudo error, validation)\n'
# --local end-to-end
age_prom "$MULTI_PROM"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$WRAPPER" add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --local >/dev/null
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex,popdex-rot3=popdex$'
wrap_list="$(SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$WRAPPER" list --server trading01 --strategy "$MULTI_STRAT" --local)"
[[ "$wrap_list" == *"popdex-rot3	popdex"* ]] || fail "wrapper --local list failed: $wrap_list"
age_prom "$MULTI_PROM"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$WRAPPER" remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --local >/dev/null
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex$'

# Wrapper rejects unsafe SSH target / remote dir / conflicting flags before invoking ssh
for bad_wrap in \
  "add --server trading01 --strategy $MULTI_STRAT --executor popdex-rot3 --ssh-target -oProxyCommand=id" \
  "add --server trading01 --strategy $MULTI_STRAT --executor popdex-rot3 --remote-dir /home/ubuntu/../etc" \
  "add --server trading01 --strategy $MULTI_STRAT --executor popdex-rot3 --remote-dir relative/dir" \
  "add --server trading01 --strategy $MULTI_STRAT --executor popdex-rot3 --remote-dir /tmp/a;id" \
  "add --server trading01 --strategy $MULTI_STRAT --executor popdex-rot3 --local --ssh-target trading01" \
  "add --server trading01 --strategy $MULTI_STRAT --executor popdex-rot3 --local --remote-dir /tmp/x" \
  "list --server trading01 --strategy $MULTI_STRAT --executor popdex-main" \
  "list --server trading01 --strategy $MULTI_STRAT --dry-run"
do
  # Intentional word splitting to build each argument vector.
  # shellcheck disable=SC2086
  if "$WRAPPER" $bad_wrap >/dev/null 2>&1; then
    fail "wrapper accepted invalid args: $bad_wrap"
  fi
done

# Stub ssh for testing default remote stream mode, sudo password guidance, and --remote-dir mode.
TAR_CAPTURE="$TEST_ROOT/received.tar"
cat >"$FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--" ]] || { printf 'stub ssh expected -- delimiter\n' >&2; exit 2; }
shift
target="$1"
shift
remote_cmd="$*"
printf 'TARGET=%s CMD=%s\n' "$target" "$remote_cmd" >>"$SSH_LOG"

if [[ "${FAKE_SSH_SUDO_PW_REQUIRED:-0}" == "1" ]]; then
  cat >/dev/null || true
  printf 'sudo: a password is required\n' >&2
  exit 1
fi

if [[ "${FAKE_SSH_CAPTURE_STREAM:-0}" == "1" ]]; then
  cat >"$TAR_CAPTURE"
  # Replace sudo -n with direct bash execution so we exercise the exact streamed script locally.
  local_cmd="${remote_cmd#sudo -n }"
  exec bash -c "$local_cmd" <"$TAR_CAPTURE"
fi

# --remote-dir mode: verify command shape and return 0 without executing.
exit 0
EOF
chmod 755 "$FAKE_BIN/ssh"
export TAR_CAPTURE

# Default remote streaming mode: verify exact allowlisted tar contents and live execution against test root
: >"$SSH_LOG"
age_prom "$MULTI_PROM"
stream_out="$(FAKE_SSH_CAPTURE_STREAM=1 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$WRAPPER" add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --ssh-target ubuntu@t01)"
[[ "$stream_out" == *"Account add committed"* ]] || fail "streamed ssh add failed: $stream_out"
assert_contains "$SSH_LOG" '^TARGET=ubuntu@t01 CMD=sudo -n bash -c '
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex,popdex-rot3=popdex$'

expected_tar_files="$(printf '%s\n' \
  agents/alloy/alloy-versions.env \
  agents/alloy/install-common.sh \
  agents/alloy/trading/account-linux.sh \
  agents/alloy/trading/config-linux-metrics.alloy.tmpl \
  agents/alloy/trading/config-linux.alloy.tmpl \
  agents/alloy/trading/ensure-log-access.sh \
  agents/alloy/trading/linux-common.sh \
  agents/alloy/trading/probe.sh \
  agents/alloy/trading/setup-linux.sh \
  agents/alloy/trading/skyeye-trading-probe@.service.tmpl \
  agents/alloy/trading/skyeye-trading-probe@.timer.tmpl | LC_ALL=C sort)"
actual_tar_files="$(tar -tf "$TAR_CAPTURE" | LC_ALL=C sort)"
[[ "$actual_tar_files" == "$expected_tar_files" ]] || \
  fail "streamed tar payload mismatch:
expected:
$expected_tar_files
actual:
$actual_tar_files"

# Remove popdex-rot3 back via streamed ssh
age_prom "$MULTI_PROM"
FAKE_SSH_CAPTURE_STREAM=1 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$WRAPPER" remove --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --ssh-target ubuntu@t01 >/dev/null
assert_contains "$MULTI_ENV" '^TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex$'

# Default remote mode when sudo -n requires password gives concrete next-step commands
rc=0
sudo_err="$(FAKE_SSH_SUDO_PW_REQUIRED=1 \
  "$WRAPPER" add --server trading01 --strategy "$MULTI_STRAT" --executor popdex-rot3 --ssh-target ubuntu@t01 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "sudo password failure unexpectedly exited 0"
[[ "$sudo_err" == *"--remote-dir"* &&
   "$sudo_err" == *"setup-linux.sh account add --server trading01 --strategy $MULTI_STRAT --executor popdex-rot3"* &&
   "$sudo_err" == *"--ssh-target ubuntu@t01"* ]] || \
  fail "sudo password refusal did not provide actionable next-step commands: $sudo_err"

# --remote-dir mode builds exact sudo command targeting the staged checkout
: >"$SSH_LOG"
"$WRAPPER" list --server trading01 --strategy "$MULTI_STRAT" \
  --remote-dir /home/ubuntu/skyeye-staging/popdex-589d4ae >/dev/null
assert_contains "$SSH_LOG" "^TARGET=trading01 CMD=sudo -- '/home/ubuntu/skyeye-staging/popdex-589d4ae/agents/alloy/trading/setup-linux[.]sh' account 'list' '--server' 'trading01' '--strategy' '${MULTI_STRAT}'$"

printf 'case: zero tnauqquant unit touches and zero Alloy restarts across entire run\n'
assert_not_contains "$SYSTEMCTL_LOG_ALL" 'tnauqquant'
assert_not_contains "$SYSTEMCTL_LOG_ALL" '^restart alloy$'

printf 'PASS: trading account add/remove/list host and wrapper checks\n'
