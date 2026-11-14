#!/usr/bin/env bash
set -euo pipefail

# Rehearses the Trading01 PopDEX rollout (docs/trading01-popdex-rollout.md,
# Phases 2 to 4 and the Phase 3/4 rollback) on a fake Trading01 below a test
# root: a ZenIncome base config, Robinhood and Mainnet installed and running
# with a shared probe and fragments older than this checkout, and a leftover
# Mainnet manifest. The instance envs come from the checked-in examples with
# only the repo root, textfile directory and users moved into the test root.
# The runbook's Phase 1 helpers.sh is taken from the runbook itself, with only
# HOST_ROOT pointed at the test root, so R3 and log_evidence run exactly as
# written there, and its monitoring-prod helpers.sh runs loki_accept against a
# fake Loki; the other commands below are the runbook's commands. Real `alloy
# validate` checks every combined config; systemctl is a stub, so no unit is
# ever touched.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRADING_DIR="$REPO_ROOT/agents/alloy/trading"
SETUP="$TRADING_DIR/setup-linux.sh"
ROBINHOOD_EXAMPLE="$TRADING_DIR/deployment-linux-robinhood.env.example"
MAINNET_EXAMPLE="$TRADING_DIR/deployment-linux-mainnet.env.example"
POPDEX_EXAMPLE="$TRADING_DIR/deployment-linux-popdex.env.example"
RUNBOOK="$REPO_ROOT/docs/trading01-popdex-rollout.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for required_tool in alloy rg jq shasum perl; do
  command -v "$required_tool" >/dev/null 2>&1 || \
    fail "$required_tool is required; this suite must not pass by skipping"
done
REAL_ALLOY="$(command -v alloy)"
REAL_DATE="$(command -v date)"
for required_file in "$SETUP" "$ROBINHOOD_EXAMPLE" "$MAINNET_EXAMPLE" "$POPDEX_EXAMPLE" "$RUNBOOK"; do
  [[ -f "$required_file" ]] || fail "required file is missing: $required_file"
done

example_value() {
  sed -nE "s/^$1=//p" "$2" | tail -n 1
}

ROBINHOOD="$(example_value TQ_STRATEGY "$ROBINHOOD_EXAMPLE")"
MAINNET="$(example_value TQ_STRATEGY "$MAINNET_EXAMPLE")"
POPDEX="$(example_value TQ_STRATEGY "$POPDEX_EXAMPLE")"
[[ "$POPDEX" == "popdex-btc" ]] || fail "the PopDEX example names strategy $POPDEX"
[[ "$(example_value TQ_EXECUTOR_MAP "$POPDEX_EXAMPLE")" == "popdex-main=popdex" ]] || \
  fail 'the PopDEX example must map its single executor popdex-main to exchange popdex'
[[ "$(example_value TQ_SERVER_ID "$POPDEX_EXAMPLE")" == "trading01" ]] || \
  fail 'the PopDEX example must run on trading01'
[[ "$(example_value TQ_STRATEGY_DISABLED "$MAINNET_EXAMPLE")" == "1" ]] || \
  fail 'the Mainnet example must keep TQ_STRATEGY_DISABLED=1'
if rg -n -i 'CF_ACCESS|SECRET|TOKEN|PASSWORD|PRIVATE' "$POPDEX_EXAMPLE"; then
  fail 'the PopDEX example must not name a credential'
fi

# setup-linux.sh resolves the test root with pwd -P and its records use that
# form, so the test root is resolved once here and used in that form throughout.
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-t01-popdex.XXXXXX")"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"

SYSTEM_ROOT="$TEST_ROOT"
ROOT_P="$SYSTEM_ROOT"
PROBE_HOME="$TEST_ROOT/home/ubuntu"
FAKE_REPO="$PROBE_HOME/tnauqquant"
TEXTFILE_DIR="$TEST_ROOT/var/lib/skyeye-trading/textfile"
WORK="$TEST_ROOT/root/skyeye-popdex-work"
FAKE_BIN="$TEST_ROOT/fake-bin"
SYSTEMCTL_STATE="$TEST_ROOT/systemctl-state"
SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
SYSTEMCTL_LOG_ALL="$TEST_ROOT/systemctl-all.log"
INSTANCES="$SYSTEM_ROOT/etc/skyeye-trading/instances"
LIVE_PROBE="$SYSTEM_ROOT/usr/local/libexec/skyeye-trading/probe.sh"
ALLOY_DIR="$SYSTEM_ROOT/etc/alloy"
CURRENT_USER="$(id -un)"
CURRENT_GROUP="$(id -gn)"

mkdir -p "$ALLOY_DIR" "$SYSTEM_ROOT/etc/default" "$SYSTEM_ROOT/run" \
  "$SYSTEM_ROOT/etc/systemd/system/timers.target.wants" \
  "$FAKE_REPO/logs/live-runs" "$TEXTFILE_DIR" "$FAKE_BIN" "$SYSTEMCTL_STATE"
install -d -m 700 "$WORK"

# The examples, moved into the test root and nothing else.
host_env() {
  local example="$1" target="$2"
  sed -E \
    -e "s#/home/ubuntu/tnauqquant#$FAKE_REPO#g" \
    -e "s#/var/lib/skyeye-trading/textfile#$TEXTFILE_DIR#g" \
    -e "s#^TQ_PROBE_USER=.*#TQ_PROBE_USER=$CURRENT_USER#" \
    -e "s#^TQ_PROBE_GROUP=.*#TQ_PROBE_GROUP=$CURRENT_GROUP#" \
    -e "s#^TQ_ALLOY_USER=.*#TQ_ALLOY_USER=$CURRENT_USER#" \
    -e "s#^TQ_ALLOY_GROUP=.*#TQ_ALLOY_GROUP=$CURRENT_GROUP#" \
    "$example" >"$target"
  chmod 600 "$target"
}

SOURCE_ENVS="$TEST_ROOT/source-envs"
install -d -m 700 "$SOURCE_ENVS"
host_env "$ROBINHOOD_EXAMPLE" "$SOURCE_ENVS/$ROBINHOOD.env"
host_env "$POPDEX_EXAMPLE" "$SOURCE_ENVS/$POPDEX.env"
# Mainnet as installed before this change: no TQ_STRATEGY_DISABLED line yet.
host_env "$MAINNET_EXAMPLE" "$TEST_ROOT/mainnet-example.env"
grep -v '^TQ_STRATEGY_DISABLED=' "$TEST_ROOT/mainnet-example.env" >"$SOURCE_ENVS/$MAINNET.env"
chmod 600 "$SOURCE_ENVS/$MAINNET.env"

for strategy in "$ROBINHOOD" "$MAINNET" "$POPDEX"; do
  env_path="$SOURCE_ENVS/$strategy.env"
  executable="$(example_value TQ_EXECUTABLE "$env_path")"
  config_path="$(example_value TQ_CONFIG_PATH "$env_path")"
  manifest_path="$(example_value TQ_RUN_MANIFEST "$env_path")"
  mkdir -p "$(dirname "$executable")" "$(dirname "$config_path")" "$(dirname "$manifest_path")"
  printf '#!/bin/sh\nexit 0\n' >"$executable"
  chmod 755 "$executable"
  printf 'instance_id: "%s"\n' "$(example_value TQ_INSTANCE_ID "$env_path")" >"$config_path"
done
printf 'time=2026-11-14T00:00:00.000Z level=INFO msg=engine_started\n' \
  >"$FAKE_REPO/logs/live-runs/20261113_141635_popdex_btc_config.raw.log"

# Trading01's base config.alloy also carries ZenIncome; it must never change.
cat >"$ALLOY_DIR/config.alloy" <<'EOF'
loki.write "central" {
  endpoint { url = "https://loki.invalid/loki/api/v1/push" }
}
prometheus.remote_write "central" {
  endpoint { url = "https://prometheus.invalid/api/v1/write" }
}
loki.source.file "zenincome" {
  targets    = [{"__path__" = "/var/log/zenincome/*.log", "product" = "zenincome"}]
  forward_to = [loki.write.central.receiver]
}
EOF
printf '// unloaded backup kept from the 2026-09 singleton migration\n' \
  >"$ALLOY_DIR/trading.alloy.pre-pr34.20260901111534"
printf 'CONFIG_FILE="%s/etc/alloy"\nCUSTOM_ARGS=""\n' "$ROOT_P" >"$SYSTEM_ROOT/etc/default/alloy"
touch "$SYSTEMCTL_STATE/active_alloy"

cat >"$FAKE_BIN/alloy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'alloy, version v%s (branch: HEAD, revision: fixture)\n' "${FAKE_ALLOY_VERSION:-1.16.3}"
  exit 0
fi
if [[ "${1:-}" == "validate" && -n "${FAKE_ALLOY_VALIDATE_FAILS:-}" ]]; then
  printf 'Error: fixture validation failure\n' >&2
  exit 1
fi
exec "$REAL_ALLOY" "$@"
EOF

cat >"$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"
shift
for systemctl_log_path in "$SYSTEMCTL_LOG" "$SYSTEMCTL_LOG_ALL"; do
  {
    printf '%s' "$cmd"
    printf ' %s' "$@"
    printf '\n'
  } >>"$systemctl_log_path"
done
state_path() {
  printf '%s/%s_%s\n' "$SYSTEMCTL_STATE" "$1" "${2//\//_}"
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
  is-active|is-enabled)
    [[ "${1:-}" != "--quiet" ]] || shift
    kind=active
    [[ "$cmd" != "is-enabled" ]] || kind=enabled
    state_exists "$kind" "$1"
    ;;
  disable)
    [[ "${1:-}" != "--now" ]] || shift
    if [[ -n "${FAKE_SYSTEMCTL_FAIL_DISABLE:-}" && "$1" == "$FAKE_SYSTEMCTL_FAIL_DISABLE" ]]; then
      printf 'Failed to disable unit %s (fixture)\n' "$1" >&2
      exit 1
    fi
    rm -f "$(state_path enabled "$1")" "$(state_path active "$1")"
    ;;
  enable)
    if [[ "${1:-}" == "--now" ]]; then
      shift
      touch "$(state_path active "$1")"
    fi
    touch "$(state_path enabled "$1")"
    ;;
  start|restart)
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
    printf 'yes\n'
    ;;
  *)
    printf 'unexpected fake systemctl command: %s\n' "$cmd" >&2
    exit 2
    ;;
esac
EOF

# Trading01 has GNU date, and log_evidence uses its "-u -d TIME +%s%N"; every
# other call goes to this machine's date.
cat >"$FAKE_BIN/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" -eq 4 && "$1" == "-u" && "$2" == "-d" && "$4" == "+%s%N" ]]; then
  exec perl -MTime::Local=timegm -e '
    $ARGV[0] =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d{1,9}))?(?:(Z)|([+-])(\d\d):(\d\d))$/ or exit 1;
    my $seconds = timegm($6, $5, $4, $3, $2 - 1, $1);
    $seconds -= ($9 eq "-" ? -1 : 1) * ($10 * 3600 + $11 * 60) if defined $9;
    printf "%d%s\n", $seconds, substr(($7 // "") . "000000000", 0, 9);' "$3"
fi
exec @REAL_DATE@ "$@"
EOF
# Baked in: the probe runs under env -i.
sed -i.bak "s#@REAL_DATE@#$REAL_DATE#" "$FAKE_BIN/date" && rm -f "$FAKE_BIN/date.bak"

cat >"$FAKE_BIN/runuser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
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
export SYSTEMCTL_STATE SYSTEMCTL_LOG SYSTEMCTL_LOG_ALL REAL_ALLOY
export FAKE_PASSWD_HOME="$PROBE_HOME"
export SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT"

# The runbook's Phase 1 helpers.sh, as written there. STAGE is the checkout, so
# SETUP is this checkout's setup-linux.sh; HOST_ROOT is the only line changed.
helpers_open="cat >\"\$WORK/helpers.sh\" <<'EOF'"
awk -v open="$helpers_open" '$0 == open { on = 1; next } on && $0 == "EOF" { exit } on { print }' \
  "$RUNBOOK" >"$TEST_ROOT/runbook-helpers.sh"
grep -qx 'HOST_ROOT=""[[:space:]]*#.*' "$TEST_ROOT/runbook-helpers.sh" || \
  fail 'the runbook helpers.sh no longer sets HOST_ROOT="" on a line of its own'
sed -E "s#^HOST_ROOT=\"\"#HOST_ROOT=\"$ROOT_P\"#" "$TEST_ROOT/runbook-helpers.sh" >"$TEST_ROOT/helpers.sh"
for helper in record_timer_states textfile_values probe_strategies stop_all_probes r3_rollback log_evidence; do
  grep -q "^$helper() {" "$TEST_ROOT/helpers.sh" || fail "the runbook helpers.sh does not define $helper"
done
# shellcheck disable=SC2034  # read by the sourced helpers.sh
STAGE="$REPO_ROOT"
# shellcheck source=/dev/null
. "$TEST_ROOT/helpers.sh"
[[ "$INSTANCES" == "$ROOT_P/etc/skyeye-trading/instances" && "$SETUP" == "$TRADING_DIR/setup-linux.sh" ]] || \
  fail 'the runbook helpers.sh does not resolve below the test root'

sha_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}
assert_no_mutation() {
  if rg -q '^(restart|reload|enable|disable|start|stop|daemon-reload)( |$)' "$SYSTEMCTL_LOG"; then
    printf 'FAIL: %s changed systemd state:\n' "$1" >&2
    cat "$SYSTEMCTL_LOG" >&2
    exit 1
  fi
}
timer_is() {
  local strategy="$1" expected="$2" actual="disabled inactive"
  [[ -e "$SYSTEMCTL_STATE/enabled_skyeye-trading-probe@$strategy.timer" ]] && actual="enabled ${actual#* }"
  [[ -e "$SYSTEMCTL_STATE/active_skyeye-trading-probe@$strategy.timer" ]] && actual="${actual% *} active"
  [[ "$actual" == "$expected" ]] || fail "$strategy timer is '$actual', expected '$expected'"
}
# Every file a rollout may change, by content and mode. Records, retired
# instances and probe outputs are left out: they only grow.
snapshot() {
  find "$ALLOY_DIR" "$INSTANCES" "$SYSTEM_ROOT/usr/local/libexec/skyeye-trading" \
    "$SYSTEM_ROOT/etc/systemd/system" "$SYSTEM_ROOT/etc/default" -type f 2>/dev/null | LC_ALL=C sort |
    while IFS= read -r path; do
      printf '%s %s %s\n' "${path#"$SYSTEM_ROOT"}" \
        "$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path")" "$(sha_of "$path")"
    done
}
record_of() {
  sed -n 's/^Rollback record: //p' "$1" | tail -n 1
}
# The files every templated probe shares, and the siblings' own files: the
# snapshot without the lines of the instance R3 retires.
shared_snapshot() {
  snapshot | grep -v "$POPDEX"
}
run_installed_probe() {
  # Positional parameters belong to the child shell.
  # shellcheck disable=SC2016
  env -i PATH="$PATH" bash -c 'set -a; source "$1"; set +a; exec "$2"' \
    bash "$INSTANCES/$1.env" "$LIVE_PROBE"
}
probe_metric() {
  awk -v metric="$2" 'index($0, metric "{") == 1 { print $NF; exit }' \
    "$TEXTFILE_DIR/tnauqquant-$1.prom"
}

printf 'case: Trading01 as found on 2026-11-14\n'
for strategy in "$ROBINHOOD" "$MAINNET"; do
  "$SETUP" add --env-file "$SOURCE_ENVS/$strategy.env" >/dev/null
done
# The shared probe is SkyEye 5803549 (2026-09-13); both fragments predate the
# 2026-11-05 scrub fixes.
printf '# shared probe from SkyEye 5803549\n' >>"$LIVE_PROBE"
for strategy in "$ROBINHOOD" "$MAINNET"; do
  printf '// rendered before the 2026-11-05 scrub fixes\n' >>"$ALLOY_DIR/trading-$strategy.alloy"
done
# Mainnet was stopped on 2026-11-07 without a done marker.
mainnet_manifest="$(example_value TQ_RUN_MANIFEST "$SOURCE_ENVS/$MAINNET.env")"
jq -n --arg strategy "$MAINNET" \
  '{schema_version: 1, run_id: "20261106_000000_lighter_mainnet_btc_config",
    strategy: $strategy, instance_id: $strategy, pid: 999999, state: "running"}' \
  >"$mainnet_manifest"
timer_is "$ROBINHOOD" "enabled active"
timer_is "$MAINNET" "enabled active"
zenincome_sha="$(sha_of "$ALLOY_DIR/config.alloy")"
backup_sha="$(sha_of "$ALLOY_DIR/trading.alloy.pre-pr34.20260901111534")"
snapshot >"$TEST_ROOT/before-phase3.snapshot"

printf 'case: Phase 1 records the timer states and copies the installed envs\n'
record_timer_states >"$WORK/timers.before"
[[ "$(cat "$WORK/timers.before")" == "$MAINNET enabled active"$'\n'"$ROBINHOOD enabled active" ]] || {
  printf 'FAIL: unexpected timer record:\n' >&2
  cat "$WORK/timers.before" >&2
  exit 1
}
for strategy in "$ROBINHOOD" "$MAINNET"; do
  install -m 600 "$INSTANCES/$strategy.env" "$WORK/$strategy.env"
done
install -m 600 "$SOURCE_ENVS/$POPDEX.env" "$WORK/$POPDEX.env"
"$SETUP" --render-only "$WORK/render-$POPDEX" --env-file "$WORK/$POPDEX.env" >/dev/null
rg -q 'strategy[[:space:]]*=[[:space:]]*"popdex-btc"' "$WORK/render-$POPDEX/trading-$POPDEX.alloy" || \
  fail 'the PopDEX render does not carry its strategy label'
rg -q 'loki.source.file "skyeye_trading_popdex_h_btc_raw"' "$WORK/render-$POPDEX/trading-$POPDEX.alloy" || \
  fail 'the PopDEX render does not define its raw log source'
if rg -q 'prometheus[.]exporter[.]unix|@@[A-Z_]+@@' "$WORK/render-$POPDEX/trading-$POPDEX.alloy"; then
  fail 'the PopDEX render carries a collector or an unrendered placeholder'
fi
combined="$TEST_ROOT/combined-popdex"
mkdir -p "$combined"
cp "$ALLOY_DIR"/*.alloy "$combined/"
cp "$WORK/render-$POPDEX/trading-metrics.alloy" "$WORK/render-$POPDEX/trading-$POPDEX.alloy" "$combined/"
"$REAL_ALLOY" validate "$combined" >/dev/null

printf 'case: before the Alloy upgrade, add popdex refuses and changes nothing\n'
: >"$SYSTEMCTL_LOG"
if output="$(FAKE_ALLOY_VERSION=1.16.0 "$SETUP" add --env-file "$WORK/$POPDEX.env" 2>&1)"; then
  fail 'add accepted Alloy 1.16.0'
fi
[[ "$output" == *'installed Alloy 1.16.0 is not tested on linux'* ]] || fail "unexpected refusal: $output"
assert_no_mutation 'add on Alloy 1.16.0'
snapshot | cmp -s - "$TEST_ROOT/before-phase3.snapshot" || fail 'a refused add changed a file'

printf 'case: while sibling timers run, add popdex refuses and changes nothing\n'
: >"$SYSTEMCTL_LOG"
if output="$("$SETUP" add --env-file "$WORK/$POPDEX.env" 2>&1)"; then
  fail 'add rewrote the shared probe while sibling timers were enabled'
fi
[[ "$output" == *'shared probe artifacts changed while a templated probe service/timer is active or enabled'* ]] || \
  fail "unexpected refusal: $output"
assert_no_mutation 'add while siblings run'
snapshot | cmp -s - "$TEST_ROOT/before-phase3.snapshot" || fail 'a refused add changed a file'
[[ ! -e "$INSTANCES/$POPDEX.env" ]] || fail 'a refused add installed the PopDEX env'

printf 'case: Phase 3 stops both probes, adds popdex, restores both probes\n'
: >"$SYSTEMCTL_LOG"
while read -r strategy _ _; do
  systemctl disable --now "skyeye-trading-probe@$strategy.timer"
  systemctl stop "skyeye-trading-probe@$strategy.service"
done <"$WORK/timers.before"
"$SETUP" add --env-file "$WORK/$POPDEX.env" >"$WORK/add-$POPDEX.out"
printf '%s\n' "$(record_of "$WORK/add-$POPDEX.out")" >>"$WORK/records.list"
rg -q '^reload alloy$' "$SYSTEMCTL_LOG" || fail 'add popdex did not reload Alloy'
if rg -q '^restart alloy$' "$SYSTEMCTL_LOG"; then fail 'add popdex restarted Alloy'; fi
cmp -s "$TRADING_DIR/probe.sh" "$LIVE_PROBE" || fail 'add popdex did not install the shared probe'
cmp -s "$WORK/$POPDEX.env" "$INSTANCES/$POPDEX.env" || fail 'add popdex did not install its env'
timer_is "$POPDEX" "enabled active"
timer_is "$ROBINHOOD" "disabled inactive"
timer_is "$MAINNET" "disabled inactive"
popdex_record="$(record_of "$WORK/add-$POPDEX.out")"
rg -q '^# shared probe from SkyEye 5803549$' "$popdex_record/previous/${LIVE_PROBE#"$SYSTEM_ROOT"/}" || \
  fail 'the PopDEX add record does not keep the old shared probe'

while read -r strategy enabled active; do
  [[ "$enabled $active" == "enabled active" ]] || fail "runbook STOP: $strategy was $enabled $active"
  : >"$SYSTEMCTL_LOG"
  "$SETUP" add --env-file "$WORK/$strategy.env" --enable-probe >"$WORK/add-$strategy.out"
  printf '%s\n' "$(record_of "$WORK/add-$strategy.out")" >>"$WORK/records.list"
  rg -q '^reload alloy$' "$SYSTEMCTL_LOG" || fail "add $strategy did not reload Alloy"
  if rg -q '^restart alloy$' "$SYSTEMCTL_LOG"; then fail "add $strategy restarted Alloy"; fi
  "$SETUP" --render-only "$WORK/render-$strategy" --env-file "$WORK/$strategy.env" >/dev/null
  cmp -s "$WORK/render-$strategy/trading-$strategy.alloy" "$ALLOY_DIR/trading-$strategy.alloy" || \
    fail "add $strategy did not re-render its fragment"
  timer_is "$strategy" "enabled active"
done <"$WORK/timers.before"
[[ "$(sha_of "$ALLOY_DIR/config.alloy")" == "$zenincome_sha" ]] || fail 'the rollout changed the ZenIncome config.alloy'
[[ "$(sha_of "$ALLOY_DIR/trading.alloy.pre-pr34.20260901111534")" == "$backup_sha" ]] || \
  fail 'the rollout changed the unloaded singleton backup'
"$REAL_ALLOY" validate "$ALLOY_DIR" >/dev/null

printf 'case: before Phase 4 the leftover Mainnet manifest reads as an expected run\n'
for strategy in "$ROBINHOOD" "$MAINNET" "$POPDEX"; do
  run_installed_probe "$strategy"
done
[[ "$(probe_metric "$MAINNET" tnauqquant_run_expected)" == "1" ]] || \
  fail 'the fixture does not reproduce the Mainnet ProcessDown'

printf 'case: Phase 4 disables Mainnet in its env and keeps its timer state\n'
install -m 600 "$INSTANCES/$MAINNET.env" "$WORK/$MAINNET.installed.env"
grep -v '^TQ_STRATEGY_DISABLED=' "$WORK/$MAINNET.installed.env" >"$WORK/$MAINNET.phase4.env"
printf 'TQ_STRATEGY_DISABLED=1\n' >>"$WORK/$MAINNET.phase4.env"
chmod 600 "$WORK/$MAINNET.phase4.env"
: >"$SYSTEMCTL_LOG"
"$SETUP" add --env-file "$WORK/$MAINNET.phase4.env" >"$WORK/add-$MAINNET.phase4.out"
printf '%s\n' "$(record_of "$WORK/add-$MAINNET.phase4.out")" >>"$WORK/records.list"
rg -q '^reload alloy$' "$SYSTEMCTL_LOG" || fail 'Phase 4 did not reload Alloy'
if rg -q '^restart alloy$' "$SYSTEMCTL_LOG"; then fail 'Phase 4 restarted Alloy'; fi
rg -q '^TQ_STRATEGY_DISABLED=1$' "$INSTANCES/$MAINNET.env" || fail 'Phase 4 did not install TQ_STRATEGY_DISABLED=1'
timer_is "$MAINNET" "enabled active"
timer_is "$ROBINHOOD" "enabled active"
timer_is "$POPDEX" "enabled active"

printf 'case: three probes publish three distinct outputs\n'
rm -f "$TEXTFILE_DIR"/tnauqquant-*.prom
for strategy in "$ROBINHOOD" "$MAINNET" "$POPDEX"; do
  run_installed_probe "$strategy"
done
output_count="$(find "$TEXTFILE_DIR" -maxdepth 1 -type f -name 'tnauqquant-*.prom' | wc -l | tr -d ' ')"
[[ "$output_count" == "3" ]] || fail "expected three strategy outputs, got $output_count"
for strategy in "$ROBINHOOD" "$MAINNET" "$POPDEX"; do
  rg -q "strategy=\"$strategy\"" "$TEXTFILE_DIR/tnauqquant-$strategy.prom" || \
    fail "$strategy output lost its strategy identity"
done
[[ "$(probe_metric "$MAINNET" tnauqquant_run_expected)" == "0" ]] || \
  fail 'disabled Mainnet still reads as an expected run'
[[ "$(probe_metric "$ROBINHOOD" tnauqquant_run_expected)" == "1" ]] || \
  fail 'Robinhood stopped reading as an expected run'

printf 'case: log_evidence names a finished source event after SINCE\n'
live_runs="$FAKE_REPO/logs/live-runs"
now="$(date +%s)"
utc() {
  perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%S", gmtime($ARGV[0] + $ARGV[1]))' "$1" "${2:-0}"
}
# The older PopDEX raw log from the fixture, an hour old, and a newer one whose
# last line is the newest event. That last line ends with a newline, so it is
# finished and is the evidence, not the line before it.
perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1]' "$((now - 3600))" \
  "$live_runs/20261113_141635_popdex_btc_config.raw.log"
{
  printf 'time=%s.456Z level=INFO msg="cycle start"\n' "$(utc "$((now - 180))")"
  printf 'time=%s.123Z level=INFO msg="cycle done" client_id=[ORDER_REF]\n' "$(utc "$((now - 120))")"
} >"$live_runs/20261114_121500_popdex_btc_config.raw.log"
popdex_since="$((now - 86400))"
popdex_ns="$((now - 120))123000000"
evidence="$(log_evidence "$POPDEX" "$popdex_since")"
[[ "$evidence" == "loki_accept $POPDEX $popdex_ns $popdex_since" ]] || \
  fail "PopDEX evidence is not the finished last line of the newest log: $evidence"
# Robinhood writes local time with an offset; its last line is still being written.
{
  printf 'time=%s.000+08:00 level=INFO msg=a\n' "$(utc "$((now - 40))" 28800)"
  printf 'time=%s.250+08:00 level=INFO msg=b\n' "$(utc "$((now - 30))" 28800)"
  printf 'time=%s.500+08:00 level=INFO msg=partial' "$(utc "$((now - 1))" 28800)"
} >"$live_runs/20261114_000000_lighter_robinhood_btc_config.raw.log"
evidence="$(log_evidence "$ROBINHOOD" "$((now - 300))")"
[[ "$evidence" == "loki_accept $ROBINHOOD $((now - 30))250000000 $((now - 300))" ]] || \
  fail "Robinhood evidence did not take the last finished line in UTC: $evidence"
evidence="$(log_evidence "$ROBINHOOD" "$((now - 10))")"
[[ "$evidence" == "loki_accept $ROBINHOOD none $((now - 10))" ]] || \
  fail "an event older than SINCE counted as evidence: $evidence"
robinhood_log="$live_runs/20261114_000000_lighter_robinhood_btc_config.raw.log"
# A finished new last line after an old one is the evidence even when the old
# line is before SINCE; taking the line before the last reported PENDING here.
{
  printf 'time=%s.000+08:00 level=INFO msg=a\n' "$(utc "$((now - 40))" 28800)"
  printf 'time=%s.250+08:00 level=INFO msg=b\n' "$(utc "$((now - 30))" 28800)"
} >"$robinhood_log"
evidence="$(log_evidence "$ROBINHOOD" "$((now - 35))")"
[[ "$evidence" == "loki_accept $ROBINHOOD $((now - 30))250000000 $((now - 35))" ]] || \
  fail "a finished last line after an older one was not the evidence: $evidence"
# The unfinished tail is skipped: the finished line before it is the evidence.
printf 'time=%s.500+08:00 level=INFO msg=partial' "$(utc "$((now - 1))" 28800)" >>"$robinhood_log"
evidence="$(log_evidence "$ROBINHOOD" "$((now - 35))")"
[[ "$evidence" == "loki_accept $ROBINHOOD $((now - 30))250000000 $((now - 35))" ]] || \
  fail "an unfinished tail replaced the finished line before it: $evidence"
# A file holding only an unfinished line has no evidence.
printf 'time=%s.500+08:00 level=INFO msg=partial' "$(utc "$((now - 1))" 28800)" >"$robinhood_log"
evidence="$(log_evidence "$ROBINHOOD" "$((now - 35))")"
[[ "$evidence" == "loki_accept $ROBINHOOD none $((now - 35))" ]] || \
  fail "an unfinished line counted as evidence: $evidence"
evidence="$(log_evidence "$MAINNET" "$((now - 300))")"
[[ "$evidence" == "loki_accept $MAINNET none $((now - 300))" ]] || \
  fail "a strategy without a raw log produced evidence: $evidence"

printf 'case: loki_accept passes only on the source event, never on an empty stream\n'
cut_open="cat >\"\$CUT/helpers.sh\" <<'EOF'"
awk -v open="$cut_open" '$0 == open { on = 1; next } on && $0 == "EOF" { exit } on { print }' \
  "$RUNBOOK" >"$TEST_ROOT/central-helpers.sh"
grep -q '^loki_accept() {' "$TEST_ROOT/central-helpers.sh" || \
  fail 'the runbook monitoring-prod helpers.sh does not define loki_accept'
CENTRAL_BIN="$TEST_ROOT/central-bin"
LOKI="$TEST_ROOT/loki"
mkdir -p "$CENTRAL_BIN" "$LOKI"
# Loki as the runbook queries it: an answer per endpoint, every call logged.
# With $LOKI/lines present, the scrub query is answered from those lines: the
# regex is taken from the query as loki_accept sent it and run with rg, whose
# syntax matches the RE2 subset the runbook uses.
cat >"$CENTRAL_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOKI/calls.log"
[[ ! -e "$LOKI/down" ]] || exit 7
case "$*" in
  */loki/api/v1/query_range*) cat "$LOKI/range.json" ;;
  */loki/api/v1/series*) cat "$LOKI/series.json" ;;
  */loki/api/v1/query*)
    [[ -e "$LOKI/lines" ]] || { cat "$LOKI/count.json"; exit 0; }
    for a; do case "$a" in query=*) query="${a#query=}" ;; esac; done
    re="${query#*\`}"
    re="${re%\`*}"
    [[ -n "$re" && "$re" != "$query" ]] || exit 22
    n="$(rg -c -e "$re" -- "$LOKI/lines")"
    case $? in 0) ;; 1) n=0 ;; *) exit 22 ;; esac
    if [[ "$n" -eq 0 ]]; then
      echo '{"status":"success","data":{"resultType":"vector","result":[]}}'
    else
      printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[0,"%s"]}]}}\n' "$n"
    fi
    ;;
  *) exit 22 ;;
esac
EOF
chmod 755 "$CENTRAL_BIN/curl"
export LOKI
central_accept() {
  (
    export PATH="$CENTRAL_BIN:$PATH"
    # shellcheck source=/dev/null
    . "$TEST_ROOT/central-helpers.sh"
    loki_accept "$@"
  )
}
LOKI_OUT=""
LOKI_RC=0
accept() {
  : >"$LOKI/calls.log"
  if LOKI_OUT="$(central_accept "$@" 2>&1)"; then LOKI_RC=0; else LOKI_RC=$?; fi
}
loki_answers() {
  printf '%s\n' "$1" >"$LOKI/range.json"
  printf '%s\n' "$2" >"$LOKI/series.json"
  printf '%s\n' "$3" >"$LOKI/count.json"
}
stream='{"environment":"production","level":"INFO","product":"tnauqquant","run_id":"20261114_121500_popdex_btc_config","server_id":"trading01","strategy":"popdex-btc"}'
found_range="{\"status\":\"success\",\"data\":{\"resultType\":\"streams\",\"result\":[{\"stream\":$stream,\"values\":[[\"$popdex_ns\",\"client_id=[ORDER_REF]\"],[\"$((now - 60))456000000\",\"cycle start\"]]}]}}"
other_range="{\"status\":\"success\",\"data\":{\"resultType\":\"streams\",\"result\":[{\"stream\":$stream,\"values\":[[\"$((popdex_ns + 1))\",\"x\"]]}]}}"
empty_range='{"status":"success","data":{"resultType":"streams","result":[]}}'
good_series="{\"status\":\"success\",\"data\":[$(jq -c '. + {service_name: "tnauqquant"}' <<<"$stream")]}"
extra_series="{\"status\":\"success\",\"data\":[$(jq -c '. + {order_id: "123"}' <<<"$stream")]}"
empty_series='{"status":"success","data":[]}'
no_count='{"status":"success","data":{"resultType":"vector","result":[]}}'
hit_count='{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[0,"2"]}]}}'

loki_answers "$found_range" "$good_series" "$no_count"
accept "$POPDEX" "$popdex_ns" "$popdex_since"
[[ "$LOKI_RC" -eq 0 && "$LOKI_OUT" == "LOKI-ACCEPTED $POPDEX:"* ]] || fail "the source event was not accepted: $LOKI_OUT"
if ! rg -qF "start=$((popdex_ns - 1000000000))" "$LOKI/calls.log" ||
  ! rg -qF "end=$((popdex_ns + 1000000000))" "$LOKI/calls.log"; then
  fail 'loki_accept did not query the two seconds around the source event'
fi
rg -qF "start=$popdex_since" "$LOKI/calls.log" || fail 'the label check does not start at SINCE'
rg -qF "[$((now - popdex_since))s]" "$LOKI/calls.log" || rg -qF "[$((now - popdex_since + 1))s]" "$LOKI/calls.log" || \
  fail 'the scrub check does not cover SINCE to now'

# No stream at all: the label and scrub checks would both read "[]", which the
# previous Phase 6 counted as a pass. They must not even run.
loki_answers "$empty_range" "$empty_series" "$no_count"
accept "$POPDEX" "$popdex_ns" "$popdex_since"
[[ "$LOKI_RC" -eq 1 && "$LOKI_OUT" == "LOKI-MISSING $POPDEX:"* ]] || fail "an empty stream was not MISSING: $LOKI_OUT"
if rg -q 'series|v1/query --' "$LOKI/calls.log" || [[ "$(grep -c . "$LOKI/calls.log")" -ne 1 ]]; then
  fail 'loki_accept ran the label or scrub check without the source event'
fi

loki_answers "$other_range" "$good_series" "$no_count"
accept "$POPDEX" "$popdex_ns" "$popdex_since"
[[ "$LOKI_RC" -eq 1 && "$LOKI_OUT" == "LOKI-MISSING $POPDEX:"* ]] || fail "other lines stood in for the source event: $LOKI_OUT"

loki_answers "$found_range" "$extra_series" "$no_count"
accept "$POPDEX" "$popdex_ns" "$popdex_since"
[[ "$LOKI_RC" -eq 1 && "$LOKI_OUT" == "LOKI-LABELS $POPDEX: unexpected labels [\"order_id\"]" ]] || \
  fail "an extra label passed: $LOKI_OUT"

loki_answers "$found_range" "$good_series" "$hit_count"
accept "$POPDEX" "$popdex_ns" "$popdex_since"
[[ "$LOKI_RC" -eq 1 && "$LOKI_OUT" == "LOKI-UNSCRUBBED $POPDEX:"* ]] || fail "an unscrubbed ID passed: $LOKI_OUT"

# The scrub check on lines as they reach Loki. Empty values and the scrubber's
# [ORDER_REF] (bare or quoted) are not IDs; any other value is. The first line
# is the only hit of the Mac mini rollout on 2026-11-14.
scrub_case() {
  local want="$1" line="$2"
  printf '%s\n' "$line" >"$LOKI/lines"
  accept "$POPDEX" "$popdex_ns" "$popdex_since"
  rm -f "$LOKI/lines"
  case "$want" in
    clean) [[ "$LOKI_RC" -eq 0 && "$LOKI_OUT" == "LOKI-ACCEPTED $POPDEX:"* ]] || \
      fail "a scrubbed or empty value counted as an ID: $line -> $LOKI_OUT" ;;
    leak) [[ "$LOKI_RC" -eq 1 && "$LOKI_OUT" == "LOKI-UNSCRUBBED $POPDEX:"* ]] || \
      fail "an unscrubbed ID passed: $line -> $LOKI_OUT" ;;
  esac
}
loki_answers "$found_range" "$good_series" "$no_count"
scrub_case clean 'time=2026-11-14T10:18:31.848Z level=INFO msg=coordinated_dispatch_result order_id="" status=ok'
scrub_case clean 'order_id= status=ok'
scrub_case clean 'order_id='
scrub_case clean 'msg="cycle done" client_id=[ORDER_REF]'
scrub_case clean 'order_id="[ORDER_REF]" orderId=[ORDER_REF], ack_client_id=[ORDER_REF]'
# A bare [ORDER_REF] ends where a scrubbed value ends: the closing quote of an
# enclosing value (the scrubber writes this), whitespace, the end or , ; ) } ].
scrub_case clean 'msg="dispatch order_id=[ORDER_REF]" status=ok'
scrub_case clean 'order_id=[ORDER_REF]; client_id=[ORDER_REF]) clientId=[ORDER_REF]} orderId=[ORDER_REF]]'
scrub_case leak 'msg=coordinated_dispatch_result client_id="tq0123456789abcdefghij"'
scrub_case leak 'msg=coordinated_dispatch_result client_id=tq0123456789abcdefghij'
scrub_case leak 'order_id="" clientId=tq0123456789abcdefghij'
scrub_case leak 'order_id=[[FAKE-ORDER-0318A FAKE-ORDER-0318B] [FAKE-ORDER-0318C]]'
scrub_case leak 'client_action_id="[ORDER_REF"'
scrub_case leak 'order_id=[ORDER_RE'
# [ORDER_REF] followed by more of the value is not a complete scrubbed value.
scrub_case leak 'client_id="[ORDER_REF]tq123"'
scrub_case leak 'client_id=[ORDER_REF]tq123'
scrub_case leak 'order_id="[ORDER_REF] tq123"'
scrub_case leak 'order_id="[ORDER_REF],tq123"'

touch "$LOKI/down"
accept "$POPDEX" "$popdex_ns" "$popdex_since"
rm -f "$LOKI/down"
[[ "$LOKI_RC" -eq 1 && "$LOKI_OUT" == "LOKI-ERROR $POPDEX:"* ]] || fail "a failed Loki call was not an error: $LOKI_OUT"

loki_answers "$found_range" "$good_series" "$no_count"
accept "$ROBINHOOD" none "$((now - 10))"
[[ "$LOKI_RC" -eq 2 && "$LOKI_OUT" == "LOKI-PENDING $ROBINHOOD:"* ]] || fail "no source event was not PENDING: $LOKI_OUT"
[[ ! -s "$LOKI/calls.log" ]] || fail 'loki_accept queried Loki without a source event'

printf 'case: R3 stops at a failed retire and changes nothing\n'
snapshot >"$TEST_ROOT/before-r3.snapshot"
: >"$SYSTEMCTL_LOG"
export FAKE_ALLOY_VALIDATE_FAILS=1
if r3_rollback >"$WORK/r3-retire-fails.log" 2>&1; then
  fail 'R3 went on after retire failed'
fi
unset FAKE_ALLOY_VALIDATE_FAILS
rg -q '^STOP: retire popdex-btc exited [1-9]' "$WORK/r3-retire-fails.log" || {
  cat "$WORK/r3-retire-fails.log" >&2
  fail 'R3 did not stop on the failed retire'
}
assert_no_mutation 'R3 after a failed retire'
snapshot | cmp -s - "$TEST_ROOT/before-r3.snapshot" || fail 'R3 changed a file after retire failed'
[[ -f "$INSTANCES/$POPDEX.env" ]] || fail 'R3 removed the PopDEX env although retire failed'
for strategy in "$ROBINHOOD" "$MAINNET" "$POPDEX"; do
  timer_is "$strategy" "enabled active"
done

printf 'case: R3 stops when a probe cannot be disabled and restores no shared file\n'
shared_snapshot >"$TEST_ROOT/shared-before-r3.snapshot"
: >"$SYSTEMCTL_LOG"
export FAKE_SYSTEMCTL_FAIL_DISABLE="skyeye-trading-probe@$ROBINHOOD.timer"
if r3_rollback >"$WORK/r3-disable-fails.log" 2>&1; then
  fail 'R3 restored files while a probe timer could not be disabled'
fi
unset FAKE_SYSTEMCTL_FAIL_DISABLE
rg -q '^Retired Linux trading monitoring instance: popdex-btc$' "$WORK/r3-disable-fails.log" || \
  fail 'R3 did not retire popdex-btc first'
rg -q "^still enabled or active: skyeye-trading-probe@$ROBINHOOD\$" "$WORK/r3-disable-fails.log" || \
  fail 'R3 did not name the probe it could not stop'
rg -q '^STOP: a templated probe is still enabled or active' "$WORK/r3-disable-fails.log" || \
  fail 'R3 did not stop before the restore'
if rg -q '^(restored |PROBES-STOPPED|ALLOY-RELOADED)' "$WORK/r3-disable-fails.log"; then
  fail 'R3 went on to the restore while a probe was enabled'
fi
shared_snapshot | cmp -s - "$TEST_ROOT/shared-before-r3.snapshot" || \
  fail 'R3 changed a shared file while a probe was still enabled'
cmp -s "$TRADING_DIR/probe.sh" "$LIVE_PROBE" || fail 'R3 swapped the shared probe while a probe was enabled'
timer_is "$ROBINHOOD" "enabled active"
timer_is "$POPDEX" "disabled inactive"

printf 'case: R3 run again puts Trading01 back byte for byte\n'
: >"$SYSTEMCTL_LOG"
r3_rollback >"$WORK/r3.log" 2>&1 || {
  cat "$WORK/r3.log" >&2
  fail 'R3 did not finish'
}
for marker in PROBES-STOPPED ALLOY-RELOADED TIMERS-ENABLED; do
  rg -qx "$marker" "$WORK/r3.log" || fail "R3 did not print $marker"
done
if rg -q '^Retired ' "$WORK/r3.log"; then fail 'R3 retired popdex-btc a second time'; fi
[[ "$(rg -c '^restored ' "$WORK/r3.log")" == "$(grep -c . "$WORK/records.list")" ]] || \
  fail 'R3 did not restore every record'
snapshot | diff "$TEST_ROOT/before-phase3.snapshot" - >&2 || fail 'the rollback did not restore every file'
record_timer_states | cmp -s - "$WORK/timers.before" || fail 'the rollback did not restore the timer states'
timer_is "$POPDEX" "disabled inactive"

if rg -q 'tnauqquant' "$SYSTEMCTL_LOG_ALL"; then
  fail 'the rollout touched a tnauqquant unit'
fi

printf 'PASS: Trading01 PopDEX rollout rehearsal\n'
