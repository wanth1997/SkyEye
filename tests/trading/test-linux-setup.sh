#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRADING_DIR="$REPO_ROOT/agents/alloy/trading"
SETUP="$TRADING_DIR/setup-linux.sh"
INSTANCE_TEMPLATE="$TRADING_DIR/config-linux.alloy.tmpl"
METRICS_TEMPLATE="$TRADING_DIR/config-linux-metrics.alloy.tmpl"
SERVICE_TEMPLATE="$TRADING_DIR/skyeye-trading-probe@.service.tmpl"
TIMER_TEMPLATE="$TRADING_DIR/skyeye-trading-probe@.timer.tmpl"
ROBINHOOD_EXAMPLE="$TRADING_DIR/deployment-linux-robinhood.env.example"
MAINNET_EXAMPLE="$TRADING_DIR/deployment-linux-mainnet.env.example"
ACCESS_HELPER="$TRADING_DIR/ensure-log-access.sh"

for required_file in \
  "$SETUP" \
  "$INSTANCE_TEMPLATE" \
  "$METRICS_TEMPLATE" \
  "$SERVICE_TEMPLATE" \
  "$TIMER_TEMPLATE" \
  "$ROBINHOOD_EXAMPLE" \
  "$MAINNET_EXAMPLE" \
  "$ACCESS_HELPER"
do
  [[ -f "$required_file" ]] || {
    printf 'FAIL: required Linux deployment file is missing: %s\n' "$required_file" >&2
    exit 1
  }
done

[[ -x "$SETUP" && -x "$ACCESS_HELPER" ]] || {
  printf 'FAIL: Linux setup and access helper must be executable\n' >&2
  exit 1
}

assert_contains() {
  local path="$1"
  local pattern="$2"
  rg -q -- "$pattern" "$path" || {
    printf 'FAIL: %s does not contain pattern: %s\n' "$path" "$pattern" >&2
    exit 1
  }
}

assert_not_contains() {
  local path="$1"
  local pattern="$2"
  if rg -q -- "$pattern" "$path"; then
    printf 'FAIL: %s contains forbidden pattern: %s\n' "$path" "$pattern" >&2
    exit 1
  fi
}

assert_contains "$INSTANCE_TEMPLATE" 'loki.source.file "@@COMPONENT_ID@@_raw"'
assert_contains "$INSTANCE_TEMPLATE" 'loki.write.central.receiver'
assert_not_contains "$INSTANCE_TEMPLATE" 'prometheus.remote_write.central.receiver'
assert_contains "$INSTANCE_TEMPLATE" '\[TRACE_REF\]'
assert_contains "$INSTANCE_TEMPLATE" '\[EXECUTION_REF\]'
assert_contains "$INSTANCE_TEMPLATE" 'stage.label_keep'
assert_contains "$METRICS_TEMPLATE" 'prometheus.exporter.unix "skyeye_trading_textfile"'
assert_contains "$METRICS_TEMPLATE" 'prometheus.remote_write.central.receiver'
assert_not_contains "$INSTANCE_TEMPLATE" 'loki.write "central"'
assert_not_contains "$METRICS_TEMPLATE" 'prometheus.remote_write "central"'
assert_not_contains "$INSTANCE_TEMPLATE" 'CF-Access-Client-Secret'

assert_contains "$SETUP" 'CONFIG_FILE="/etc/alloy"'
assert_contains "$SETUP" 'alloy validate'
assert_contains "$SETUP" '"[$]SYSTEMCTL_BIN" disable --now "[$]LEGACY_TIMER"'
assert_contains "$SETUP" 'legacy singleton artifacts exist'
assert_contains "$SETUP" 'install -d -o .* -g .* -m 2770'
assert_contains "$SETUP" '"[$]SYSTEMCTL_BIN" restart alloy'
assert_contains "$SETUP" 'test mode requires a non-symlink systemctl stub below SKYEYE_TRADING_TEST_ROOT'
assert_not_contains "$SETUP" 'systemctl.*tnauqquant'
assert_not_contains "$SERVICE_TEMPLATE" 'quant'
assert_contains "$SERVICE_TEMPLATE" 'Type=oneshot'
assert_contains "$SERVICE_TEMPLATE" 'EnvironmentFile=@@ENV_ROOT@@/%i.env'
assert_contains "$TIMER_TEMPLATE" 'OnUnitActiveSec=15s'
assert_contains "$TIMER_TEMPLATE" 'Unit=skyeye-trading-probe@%i.service'
assert_contains "$ROBINHOOD_EXAMPLE" '^TQ_TEXTFILE_NAME=tnauqquant-lighter-robinhood-btc-canary[.]prom$'
assert_contains "$MAINNET_EXAMPLE" '^TQ_TEXTFILE_NAME=tnauqquant-lighter-mainnet-btc-canary[.]prom$'
assert_contains "$MAINNET_EXAMPLE" '^TQ_POC_RUN_EXPECTED=0$'
assert_contains "$ROBINHOOD_EXAMPLE" '/bin/lighter-robinhood-btc-canary/quant$'
assert_contains "$MAINNET_EXAMPLE" '/bin/lighter-mainnet-btc-canary/quant$'
assert_contains "$SETUP" 'runuser -u "[$]TQ_PROBE_USER" -- test -x "[$]TQ_TEXTFILE_DIR"'
assert_contains "$SETUP" 'runuser -u "[$]TQ_PROBE_USER" -- test -w "[$]TQ_TEXTFILE_DIR"'
assert_contains "$SERVICE_TEMPLATE" '^ExecStartPre=@@ACCESS_PATH@@$'

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-linux-multi.XXXXXX")"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

FAKE_REPO="$TEST_ROOT/tnauqquant"
TEXTFILE_DIR="$TEST_ROOT/textfile"
ROBINHOOD=lighter-robinhood-btc-canary
MAINNET=lighter-mainnet-btc-canary
ROBINHOOD_ENV="$TEST_ROOT/$ROBINHOOD.env"
MAINNET_ENV="$TEST_ROOT/$MAINNET.env"
CURRENT_USER="$(id -un)"
CURRENT_GROUP="$(id -gn)"

mkdir -p \
  "$FAKE_REPO/config" \
  "$FAKE_REPO/logs/live-runs" \
  "$FAKE_REPO/run-state/$ROBINHOOD" \
  "$FAKE_REPO/run-state/$MAINNET" \
  "$FAKE_REPO/bin/$ROBINHOOD" \
  "$FAKE_REPO/bin/$MAINNET" \
  "$TEXTFILE_DIR"
printf 'instance_id: "%s"\n' "$ROBINHOOD" \
  >"$FAKE_REPO/config/lighter_robinhood_btc_config.yaml"
printf 'instance_id: "%s"\n' "$MAINNET" \
  >"$FAKE_REPO/config/lighter_mainnet_btc_config.yaml"
for strategy in "$ROBINHOOD" "$MAINNET"; do
  printf '#!/bin/sh\nexit 0\n' >"$FAKE_REPO/bin/$strategy/quant"
  chmod 755 "$FAKE_REPO/bin/$strategy/quant"
done

write_env() {
  local strategy="$1"
  local config_stem="$2"
  local executor="$3"
  local expected="$4"
  local target="$5"
  cat >"$target" <<EOF
TQ_PRODUCT=tnauqquant
TQ_ENVIRONMENT=production
TQ_SERVER_ID=trading01
TQ_STRATEGY=$strategy
TQ_INSTANCE_ID=$strategy
TQ_REPO_ROOT=$FAKE_REPO
TQ_REPO_ROOT_REGEX='($FAKE_REPO)'
TQ_EXECUTABLE=$FAKE_REPO/bin/$strategy/quant
TQ_CONFIG_PATH=$FAKE_REPO/config/$config_stem.yaml
TQ_RAW_LOG_GLOB=$FAKE_REPO/logs/live-runs/*$config_stem.raw.log
TQ_RUN_MANIFEST=$FAKE_REPO/run-state/$strategy/current.json
TQ_DONE_MARKER=$FAKE_REPO/run-state/$strategy/current.done.json
TQ_POC_RUN_EXPECTED=$expected
TQ_REQUIRE_RUNTIME_CONTRACT=1
TQ_TIMEZONE=Asia/Taipei
TQ_TEXTFILE_DIR=$TEXTFILE_DIR
TQ_TEXTFILE_NAME=tnauqquant-$strategy.prom
TQ_EXECUTOR_MAP=$executor=lighter
TQ_SIDECAR_REQUIRED=0
TQ_TEXTFILE_MODE=640
TQ_PROBE_USER=$CURRENT_USER
TQ_PROBE_GROUP=$CURRENT_GROUP
TQ_ALLOY_USER=$CURRENT_USER
TQ_ALLOY_GROUP=$CURRENT_GROUP
EOF
  chmod 600 "$target"
}

write_env "$ROBINHOOD" lighter_robinhood_btc_config lighter-robinhood-main 1 "$ROBINHOOD_ENV"
write_env "$MAINNET" lighter_mainnet_btc_config lighter-mainnet-main 0 "$MAINNET_ENV"

ROBINHOOD_RENDERED="$TEST_ROOT/rendered-robinhood"
MAINNET_RENDERED="$TEST_ROOT/rendered-mainnet"
"$SETUP" --render-only "$ROBINHOOD_RENDERED" --env-file "$ROBINHOOD_ENV"
"$SETUP" --render-only "$MAINNET_RENDERED" --env-file "$MAINNET_ENV"

for strategy in "$ROBINHOOD" "$MAINNET"; do
  if [[ "$strategy" == "$ROBINHOOD" ]]; then
    rendered="$ROBINHOOD_RENDERED"
  else
    rendered="$MAINNET_RENDERED"
  fi
  for rendered_file in \
    "$rendered/trading-metrics.alloy" \
    "$rendered/trading-$strategy.alloy" \
    "$rendered/instances/$strategy.env" \
    "$rendered/probe.sh" \
    "$rendered/ensure-log-access.sh" \
    "$rendered/skyeye-trading-probe@.service" \
    "$rendered/skyeye-trading-probe@.timer"
  do
    [[ -f "$rendered_file" ]] || {
      printf 'FAIL: rendered artifact is missing: %s\n' "$rendered_file" >&2
      exit 1
    }
  done
  assert_contains "$rendered/trading-$strategy.alloy" \
    "strategy[[:space:]]*=[[:space:]]*\"$strategy\""
  assert_not_contains "$rendered/trading-$strategy.alloy" 'prometheus[.]exporter[.]unix'
  assert_not_contains "$rendered/trading-$strategy.alloy" '@@[A-Z_]+@@'
  assert_contains "$rendered/skyeye-trading-probe@.service" '/instances/%i[.]env'
  assert_not_contains "$rendered/skyeye-trading-probe@.service" "${strategy}[.]env"
done

assert_contains "$ROBINHOOD_RENDERED/trading-$ROBINHOOD.alloy" \
  'loki.source.file "skyeye_trading_lighter_h_robinhood_h_btc_h_canary_raw"'
assert_contains "$MAINNET_RENDERED/trading-$MAINNET.alloy" \
  'loki.source.file "skyeye_trading_lighter_h_mainnet_h_btc_h_canary_raw"'
cmp -s "$ROBINHOOD_RENDERED/trading-metrics.alloy" \
  "$MAINNET_RENDERED/trading-metrics.alloy" || {
  printf 'FAIL: the two instances rendered different shared metrics fragments\n' >&2
  exit 1
}

for rendered_env in \
  "$ROBINHOOD_RENDERED/instances/$ROBINHOOD.env" \
  "$MAINNET_RENDERED/instances/$MAINNET.env"
do
  mode="$(stat -f '%Lp' "$rendered_env" 2>/dev/null || stat -c '%a' "$rendered_env")"
  [[ "$mode" == "600" ]] || {
    printf 'FAIL: rendered Linux env mode expected=600 actual=%s\n' "$mode" >&2
    exit 1
  }
done

COMBINED="$TEST_ROOT/combined-alloy"
mkdir -p "$COMBINED"
cat >"$COMBINED/base.alloy" <<'EOF'
loki.write "central" {
  endpoint { url = "https://loki.invalid/loki/api/v1/push" }
}
prometheus.remote_write "central" {
  endpoint { url = "https://prometheus.invalid/api/v1/write" }
}
EOF
cp "$ROBINHOOD_RENDERED/trading-metrics.alloy" "$COMBINED/"
cp "$ROBINHOOD_RENDERED/trading-$ROBINHOOD.alloy" "$COMBINED/"
cp "$MAINNET_RENDERED/trading-$MAINNET.alloy" "$COMBINED/"
if command -v alloy >/dev/null 2>&1; then
  alloy validate "$COMBINED"
fi

printf 'case: singleton migration is explicit and recoverable\n'
SYSTEM_ROOT="$TEST_ROOT"
FAKE_BIN="$TEST_ROOT/fake-bin"
SYSTEMCTL_STATE="$TEST_ROOT/systemctl-state"
SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
SYSTEMCTL_LOG_ALL="$TEST_ROOT/systemctl-all.log"
ALLOY_CALL_COUNT="$TEST_ROOT/alloy-call-count"
mkdir -p \
  "$SYSTEM_ROOT/etc/alloy" \
  "$SYSTEM_ROOT/etc/default" \
  "$SYSTEM_ROOT/etc/skyeye-trading" \
  "$SYSTEM_ROOT/etc/systemd/system/timers.target.wants" \
  "$FAKE_BIN" \
  "$SYSTEMCTL_STATE"
cp "$COMBINED/base.alloy" "$SYSTEM_ROOT/etc/alloy/base.alloy"
printf '// legacy singleton fragment\n' >"$SYSTEM_ROOT/etc/alloy/trading.alloy"
printf 'CONFIG_FILE="/etc/alloy/config.alloy"\n' >"$SYSTEM_ROOT/etc/default/alloy"
printf 'legacy env\n' >"$SYSTEM_ROOT/etc/skyeye-trading/config.env"
printf 'legacy service\n' >"$SYSTEM_ROOT/etc/systemd/system/skyeye-trading-probe.service"
printf 'legacy timer\n' >"$SYSTEM_ROOT/etc/systemd/system/skyeye-trading-probe.timer"
ln -s ../skyeye-trading-probe.timer \
  "$SYSTEM_ROOT/etc/systemd/system/timers.target.wants/skyeye-trading-probe.timer"
printf 'legacy metrics\n' >"$TEXTFILE_DIR/tnauqquant.prom"
printf 'legacy temp\n' >"$TEXTFILE_DIR/.tnauqquant.prom.fixture"
touch \
  "$SYSTEMCTL_STATE/enabled_skyeye-trading-probe.timer" \
  "$SYSTEMCTL_STATE/active_skyeye-trading-probe.timer" \
  "$SYSTEMCTL_STATE/active_skyeye-trading-probe.service" \
  "$SYSTEMCTL_STATE/active_alloy"

cat >"$FAKE_BIN/alloy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f "$ALLOY_CALL_COUNT" ]] || count="$(cat "$ALLOY_CALL_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" >"$ALLOY_CALL_COUNT"
if [[ "${ALLOY_FAIL_ON_CALL:-0}" == "$count" ]]; then
  exit 1
fi
exit 0
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

if [[ "$cmd" == "restart" && "${1:-}" == "alloy" &&
      "${SYSTEMCTL_FAIL_RESTART_ONCE:-0}" == "1" ]]; then
  fail_marker="$SYSTEMCTL_STATE/fail_restart_once_consumed"
  if [[ ! -e "$fail_marker" ]]; then
    touch "$fail_marker"
    exit 1
  fi
fi

state_path() {
  local kind="$1"
  local unit="$2"
  printf '%s/%s_%s\n' "$SYSTEMCTL_STATE" "$kind" "${unit//\//_}"
}

state_exists() {
  local kind="$1"
  local unit="$2"
  local candidate
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
    unit="$1"
    kind=active
    [[ "$cmd" != "is-enabled" ]] || kind=enabled
    state_exists "$kind" "$unit"
    ;;
  disable)
    [[ "${1:-}" != "--now" ]] || shift
    unit="$1"
    rm -f "$(state_path enabled "$unit")" "$(state_path active "$unit")"
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
export SYSTEMCTL_STATE SYSTEMCTL_LOG SYSTEMCTL_LOG_ALL ALLOY_CALL_COUNT
export FAKE_PASSWD_HOME="$TEST_ROOT"

printf 'case: test mode rejects a systemctl symlink even below its root\n'
mv "$FAKE_BIN/systemctl" "$FAKE_BIN/systemctl.stub"
ln -s /usr/bin/false "$FAKE_BIN/systemctl"
if SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" --env-file "$ROBINHOOD_ENV" --no-start >/dev/null 2>&1
then
  printf 'FAIL: test mode accepted a symlinked systemctl\n' >&2
  exit 1
fi
rm -f "$FAKE_BIN/systemctl"
mv "$FAKE_BIN/systemctl.stub" "$FAKE_BIN/systemctl"

if SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" --env-file "$ROBINHOOD_ENV" --no-start >/dev/null 2>&1
then
  printf 'FAIL: singleton artifacts were accepted without --migrate-singleton\n' >&2
  exit 1
fi
[[ -e "$TEXTFILE_DIR/tnauqquant.prom" ]] || {
  printf 'FAIL: refused migration changed legacy metrics\n' >&2
  exit 1
}

printf 'case: failed migration restores singleton files and timer state\n'
printf '0\n' >"$ALLOY_CALL_COUNT"
if ALLOY_FAIL_ON_CALL=2 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" --env-file "$ROBINHOOD_ENV" --migrate-singleton --no-start \
  >/dev/null 2>&1
then
  printf 'FAIL: forced installed-config validation failure was accepted\n' >&2
  exit 1
fi
for restored in \
  "$SYSTEM_ROOT/etc/alloy/trading.alloy" \
  "$SYSTEM_ROOT/etc/skyeye-trading/config.env" \
  "$SYSTEM_ROOT/etc/systemd/system/skyeye-trading-probe.service" \
  "$SYSTEM_ROOT/etc/systemd/system/skyeye-trading-probe.timer" \
  "$SYSTEM_ROOT/etc/systemd/system/timers.target.wants/skyeye-trading-probe.timer" \
  "$TEXTFILE_DIR/tnauqquant.prom" \
  "$TEXTFILE_DIR/.tnauqquant.prom.fixture"
do
  [[ -e "$restored" || -L "$restored" ]] || {
    printf 'FAIL: rollback did not restore %s\n' "$restored" >&2
    exit 1
  }
done
[[ -e "$SYSTEMCTL_STATE/enabled_skyeye-trading-probe.timer" &&
   -e "$SYSTEMCTL_STATE/active_skyeye-trading-probe.timer" &&
   -e "$SYSTEMCTL_STATE/active_skyeye-trading-probe.service" ]] || {
  printf 'FAIL: rollback did not restore legacy probe state\n' >&2
  exit 1
}

printf 'case: two instance installs preserve shared and sibling artifacts\n'
printf '0\n' >"$ALLOY_CALL_COUNT"
: >"$SYSTEMCTL_LOG"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" --env-file "$ROBINHOOD_ENV" --migrate-singleton --no-start >/dev/null
assert_contains "$SYSTEMCTL_LOG" 'disable --now skyeye-trading-probe[.]timer'
assert_not_contains "$SYSTEMCTL_LOG" '^restart alloy$'
assert_not_contains "$SYSTEMCTL_LOG" '^enable --now skyeye-trading-probe@'
assert_not_contains "$SYSTEMCTL_LOG" '^start skyeye-trading-probe@'
for removed in \
  "$SYSTEM_ROOT/etc/alloy/trading.alloy" \
  "$SYSTEM_ROOT/etc/skyeye-trading/config.env" \
  "$SYSTEM_ROOT/etc/systemd/system/skyeye-trading-probe.service" \
  "$SYSTEM_ROOT/etc/systemd/system/skyeye-trading-probe.timer" \
  "$SYSTEM_ROOT/etc/systemd/system/timers.target.wants/skyeye-trading-probe.timer" \
  "$TEXTFILE_DIR/tnauqquant.prom" \
  "$TEXTFILE_DIR/.tnauqquant.prom.fixture"
do
  [[ ! -e "$removed" && ! -L "$removed" ]] || {
    printf 'FAIL: successful migration left legacy artifact %s\n' "$removed" >&2
    exit 1
  }
done

ROBINHOOD_FRAGMENT="$SYSTEM_ROOT/etc/alloy/trading-$ROBINHOOD.alloy"
ROBINHOOD_INSTALLED_ENV="$SYSTEM_ROOT/etc/skyeye-trading/instances/$ROBINHOOD.env"
robinhood_fragment_sha="$(shasum -a 256 "$ROBINHOOD_FRAGMENT" | awk '{print $1}')"
robinhood_env_sha="$(shasum -a 256 "$ROBINHOOD_INSTALLED_ENV" | awk '{print $1}')"
: >"$SYSTEMCTL_LOG"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" --env-file "$MAINNET_ENV" --no-start >/dev/null
assert_not_contains "$SYSTEMCTL_LOG" '^restart alloy$'
assert_not_contains "$SYSTEMCTL_LOG" '^enable --now skyeye-trading-probe@'
assert_not_contains "$SYSTEMCTL_LOG" '^start skyeye-trading-probe@'
[[ "$robinhood_fragment_sha" == "$(shasum -a 256 "$ROBINHOOD_FRAGMENT" | awk '{print $1}')" ]] || {
  printf 'FAIL: Mainnet install rewrote the Robinhood Alloy fragment\n' >&2
  exit 1
}
[[ "$robinhood_env_sha" == "$(shasum -a 256 "$ROBINHOOD_INSTALLED_ENV" | awk '{print $1}')" ]] || {
  printf 'FAIL: Mainnet install rewrote the Robinhood env\n' >&2
  exit 1
}
for installed in \
  "$SYSTEM_ROOT/etc/alloy/trading-metrics.alloy" \
  "$ROBINHOOD_FRAGMENT" \
  "$SYSTEM_ROOT/etc/alloy/trading-$MAINNET.alloy" \
  "$ROBINHOOD_INSTALLED_ENV" \
  "$SYSTEM_ROOT/etc/skyeye-trading/instances/$MAINNET.env" \
  "$SYSTEM_ROOT/etc/systemd/system/skyeye-trading-probe@.service" \
  "$SYSTEM_ROOT/etc/systemd/system/skyeye-trading-probe@.timer"
do
  [[ -f "$installed" ]] || {
    printf 'FAIL: multi-instance install artifact is missing: %s\n' "$installed" >&2
    exit 1
  }
done

printf 'case: installed probes publish exactly two distinct outputs\n'
for strategy in "$ROBINHOOD" "$MAINNET"; do
  env_path="$SYSTEM_ROOT/etc/skyeye-trading/instances/$strategy.env"
  # Positional parameters belong to the child shell.
  # shellcheck disable=SC2016
  env -i PATH="$PATH" bash -c \
    'set -a; source "$1"; set +a; exec "$2"' \
    bash "$env_path" "$SYSTEM_ROOT/usr/local/libexec/skyeye-trading/probe.sh"
done
output_count="$(find "$TEXTFILE_DIR" -maxdepth 1 -type f -name 'tnauqquant-*.prom' | wc -l | tr -d ' ')"
[[ "$output_count" == "2" ]] || {
  printf 'FAIL: expected exactly two strategy outputs, got %s\n' "$output_count" >&2
  find "$TEXTFILE_DIR" -maxdepth 1 -type f -print >&2
  exit 1
}
[[ ! -e "$TEXTFILE_DIR/tnauqquant.prom" ]] || {
  printf 'FAIL: legacy singleton metrics output survived migration\n' >&2
  exit 1
}
if find "$TEXTFILE_DIR" -maxdepth 1 -type f -name '.tnauqquant*.prom.*' -print | grep -q .; then
  printf 'FAIL: a probe left an atomic temporary output behind\n' >&2
  exit 1
fi
assert_contains "$TEXTFILE_DIR/tnauqquant-$ROBINHOOD.prom" \
  'strategy="lighter-robinhood-btc-canary"'
assert_contains "$TEXTFILE_DIR/tnauqquant-$MAINNET.prom" \
  'strategy="lighter-mainnet-btc-canary"'

printf 'case: failed started install restores files and Alloy state\n'
MAINNET_CHANGED_ENV="$TEST_ROOT/$MAINNET.changed.env"
cp "$MAINNET_ENV" "$MAINNET_CHANGED_ENV"
printf '# force a distinct transaction payload\n' >>"$MAINNET_CHANGED_ENV"
chmod 600 "$MAINNET_CHANGED_ENV"
mainnet_installed_sha="$(shasum -a 256 "$SYSTEM_ROOT/etc/skyeye-trading/instances/$MAINNET.env" | awk '{print $1}')"
rm -f "$SYSTEMCTL_STATE/fail_restart_once_consumed"
: >"$SYSTEMCTL_LOG"
if SYSTEMCTL_FAIL_RESTART_ONCE=1 SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" --env-file "$MAINNET_CHANGED_ENV" >/dev/null 2>&1
then
  printf 'FAIL: forced Alloy restart failure was accepted\n' >&2
  exit 1
fi
[[ "$mainnet_installed_sha" == "$(shasum -a 256 "$SYSTEM_ROOT/etc/skyeye-trading/instances/$MAINNET.env" | awk '{print $1}')" ]] || {
  printf 'FAIL: failed started install did not restore the Mainnet env\n' >&2
  exit 1
}
[[ "$(rg -c '^restart alloy$' "$SYSTEMCTL_LOG")" == "2" ]] || {
  printf 'FAIL: restart failure rollback did not retry the prior active Alloy state\n' >&2
  exit 1
}

printf 'case: started install restarts Alloy and enables only its probe\n'
: >"$SYSTEMCTL_LOG"
SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" --env-file "$MAINNET_ENV" >/dev/null
assert_contains "$SYSTEMCTL_LOG" '^restart alloy$'
assert_contains "$SYSTEMCTL_LOG" "^enable --now skyeye-trading-probe@${MAINNET}[.]timer$"
assert_contains "$SYSTEMCTL_LOG" "^start skyeye-trading-probe@${MAINNET}[.]service$"
assert_not_contains "$SYSTEMCTL_LOG" "skyeye-trading-probe@${ROBINHOOD}"
[[ -e "$SYSTEMCTL_STATE/enabled_skyeye-trading-probe@$MAINNET.timer" &&
   -e "$SYSTEMCTL_STATE/active_skyeye-trading-probe@$MAINNET.timer" ]] || {
  printf 'FAIL: started install did not activate the Mainnet probe timer\n' >&2
  exit 1
}

printf 'case: changed shared artifacts require all templated probes disabled\n'
printf '# fixture drift\n' >>"$SYSTEM_ROOT/usr/local/libexec/skyeye-trading/probe.sh"
touch "$SYSTEMCTL_STATE/enabled_skyeye-trading-probe@$ROBINHOOD.timer"
if SKYEYE_TRADING_TEST_ROOT="$SYSTEM_ROOT" \
  "$SETUP" --env-file "$MAINNET_ENV" --no-start >/dev/null 2>&1
then
  printf 'FAIL: shared artifact update was accepted while a sibling timer was enabled\n' >&2
  exit 1
fi

if rg -q 'tnauqquant' "$SYSTEMCTL_LOG_ALL"; then
  printf 'FAIL: monitoring installer attempted to control a trading service\n' >&2
  exit 1
fi

printf 'PASS: Linux multi-instance trading monitoring and singleton migration\n'
