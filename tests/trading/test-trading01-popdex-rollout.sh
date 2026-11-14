#!/usr/bin/env bash
set -euo pipefail

# Rehearses the Trading01 PopDEX rollout (docs/trading01-popdex-rollout.md,
# Phases 2 to 4 and the Phase 3/4 rollback) on a fake Trading01 below a test
# root: a ZenIncome base config, Robinhood and Mainnet installed and running
# with a shared probe and fragments older than this checkout, and a leftover
# Mainnet manifest. The instance envs come from the checked-in examples with
# only the repo root, textfile directory and users moved into the test root.
# The commands below are the runbook's commands. Real `alloy validate` checks
# every combined config; systemctl is a stub, so no unit is ever touched.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRADING_DIR="$REPO_ROOT/agents/alloy/trading"
SETUP="$TRADING_DIR/setup-linux.sh"
ROBINHOOD_EXAMPLE="$TRADING_DIR/deployment-linux-robinhood.env.example"
MAINNET_EXAMPLE="$TRADING_DIR/deployment-linux-mainnet.env.example"
POPDEX_EXAMPLE="$TRADING_DIR/deployment-linux-popdex.env.example"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for required_tool in alloy rg jq shasum; do
  command -v "$required_tool" >/dev/null 2>&1 || \
    fail "$required_tool is required; this suite must not pass by skipping"
done
REAL_ALLOY="$(command -v alloy)"
for required_file in "$SETUP" "$ROBINHOOD_EXAMPLE" "$MAINNET_EXAMPLE" "$POPDEX_EXAMPLE"; do
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

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-t01-popdex.XXXXXX")"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

SYSTEM_ROOT="$TEST_ROOT"
# setup-linux.sh resolves the test root with pwd -P, and its records use that form.
ROOT_P="$(cd "$SYSTEM_ROOT" && pwd -P)"
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
# The runbook's Phase 1 timer record: one line per installed instance.
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

printf 'case: the Phase 3/4 rollback puts Trading01 back byte for byte\n'
: >"$SYSTEMCTL_LOG"
"$SETUP" retire --strategy "$POPDEX" >"$WORK/retire-$POPDEX.out"
while read -r strategy _ _; do
  systemctl disable --now "skyeye-trading-probe@$strategy.timer"
  systemctl stop "skyeye-trading-probe@$strategy.service"
done <"$WORK/timers.before"
# Newest record first. In test mode the recorded paths sit below the test root.
tail -r "$WORK/records.list" 2>/dev/null >"$WORK/records.reverse" ||
  tac "$WORK/records.list" >"$WORK/records.reverse"
while IFS= read -r record; do
  [[ -d "$record" ]] || fail "missing rollback record: $record"
  while IFS= read -r path; do
    [[ -n "$path" ]] && rm -f -- "$path"
  done <"$record/absent.list"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    rm -f -- "$path"
    cp -a "$record/previous/${path#"$ROOT_P"/}" "$path"
  done <"$record/present.list"
done <"$WORK/records.reverse"
systemctl daemon-reload
"$REAL_ALLOY" validate "$ALLOY_DIR" >/dev/null
systemctl reload alloy
while read -r strategy enabled active; do
  [[ "$enabled $active" == "enabled active" ]] && systemctl enable --now "skyeye-trading-probe@$strategy.timer"
done <"$WORK/timers.before"
snapshot | diff "$TEST_ROOT/before-phase3.snapshot" - >&2 || fail 'the rollback did not restore every file'
record_timer_states | cmp -s - "$WORK/timers.before" || fail 'the rollback did not restore the timer states'
timer_is "$POPDEX" "disabled inactive"

if rg -q 'tnauqquant' "$SYSTEMCTL_LOG_ALL"; then
  fail 'the rollout touched a tnauqquant unit'
fi

printf 'PASS: Trading01 PopDEX rollout rehearsal\n'
