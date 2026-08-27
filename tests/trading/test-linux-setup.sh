#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRADING_DIR="$REPO_ROOT/agents/alloy/trading"
SETUP="$TRADING_DIR/setup-linux.sh"
TEMPLATE="$TRADING_DIR/config-linux.alloy.tmpl"
SERVICE_TEMPLATE="$TRADING_DIR/skyeye-trading-probe.service.tmpl"
TIMER_TEMPLATE="$TRADING_DIR/skyeye-trading-probe.timer.tmpl"
ENV_EXAMPLE="$TRADING_DIR/deployment-linux.env.example"

for required_file in \
  "$SETUP" \
  "$TEMPLATE" \
  "$SERVICE_TEMPLATE" \
  "$TIMER_TEMPLATE" \
  "$ENV_EXAMPLE"
do
  [[ -f "$required_file" ]] || {
    printf 'FAIL: required Linux deployment file is missing: %s\n' "$required_file" >&2
    exit 1
  }
done

[[ -x "$SETUP" ]] || {
  printf 'FAIL: Linux setup script is not executable\n' >&2
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

assert_contains "$TEMPLATE" 'loki.source.file "skyeye_trading_raw"'
assert_contains "$TEMPLATE" 'loki.write.central.receiver'
assert_contains "$TEMPLATE" 'prometheus.remote_write.central.receiver'
assert_contains "$TEMPLATE" '\[TRACE_REF\]'
assert_contains "$TEMPLATE" 'stage.label_keep'
assert_not_contains "$TEMPLATE" 'loki.write "central"'
assert_not_contains "$TEMPLATE" 'prometheus.remote_write "central"'
assert_not_contains "$TEMPLATE" 'CF-Access-Client-Secret'

assert_contains "$SETUP" 'CONFIG_FILE="/etc/alloy"'
assert_contains "$SETUP" 'alloy validate'
assert_contains "$SETUP" 'setfacl -m'
assert_contains "$SETUP" 'install -d -o .* -g .* -m 2770'
assert_contains "$SETUP" 'systemctl restart alloy'
assert_not_contains "$SETUP" 'systemctl.*tnauqquant'
assert_not_contains "$SERVICE_TEMPLATE" 'quant'
assert_contains "$SERVICE_TEMPLATE" 'Type=oneshot'
assert_contains "$TIMER_TEMPLATE" 'OnUnitActiveSec=15s'
assert_contains "$ENV_EXAMPLE" '^TQ_TEXTFILE_DIR=/var/lib/skyeye-trading/textfile$'
assert_not_contains "$ENV_EXAMPLE" '^TQ_TEXTFILE_DIR=/var/lib/alloy/'
assert_contains "$SETUP" 'runuser -u "[$]TQ_PROBE_USER" -- test -x "[$]TQ_TEXTFILE_DIR"'
assert_contains "$SETUP" 'runuser -u "[$]TQ_PROBE_USER" -- test -w "[$]TQ_TEXTFILE_DIR"'

TEST_ROOT="$(mktemp -d /tmp/skyeye-linux-render.XXXXXX)"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

FAKE_REPO="$TEST_ROOT/tnauqquant"
ENV_FILE="$TEST_ROOT/config.env"
RENDERED="$TEST_ROOT/rendered"
mkdir -p \
  "$FAKE_REPO/config" \
  "$FAKE_REPO/logs/live-runs" \
  "$FAKE_REPO/run-state/lighter-robinhood-btc-canary" \
  "$TEST_ROOT/textfile"
printf 'instance_id: "lighter-robinhood-btc-canary"\n' \
  >"$FAKE_REPO/config/lighter_robinhood_btc_config.yaml"

cat >"$ENV_FILE" <<EOF
TQ_PRODUCT=tnauqquant
TQ_ENVIRONMENT=production
TQ_SERVER_ID=trading01
TQ_STRATEGY=lighter-robinhood-btc-canary
TQ_INSTANCE_ID=lighter-robinhood-btc-canary
TQ_REPO_ROOT=$FAKE_REPO
TQ_REPO_ROOT_REGEX='('$FAKE_REPO')'
TQ_EXECUTABLE=$FAKE_REPO/quant
TQ_CONFIG_PATH=$FAKE_REPO/config/lighter_robinhood_btc_config.yaml
TQ_RAW_LOG_GLOB=$FAKE_REPO/logs/live-runs/*.raw.log
TQ_RUN_MANIFEST=$FAKE_REPO/run-state/lighter-robinhood-btc-canary/current.json
TQ_DONE_MARKER=$FAKE_REPO/run-state/lighter-robinhood-btc-canary/current.done.json
TQ_POC_RUN_EXPECTED=1
TQ_REQUIRE_RUNTIME_CONTRACT=1
TQ_TIMEZONE=Asia/Taipei
TQ_TEXTFILE_DIR=$TEST_ROOT/textfile
TQ_EXECUTOR_MAP=lighter-robinhood-main=lighter
TQ_SIDECAR_REQUIRED=0
TQ_TEXTFILE_MODE=640
TQ_PROBE_USER=ubuntu
TQ_PROBE_GROUP=ubuntu
TQ_ALLOY_USER=alloy
TQ_ALLOY_GROUP=alloy
EOF
chmod 600 "$ENV_FILE"

"$SETUP" --render-only "$RENDERED" --env-file "$ENV_FILE"

for rendered_file in \
  "$RENDERED/trading.alloy" \
  "$RENDERED/config.env" \
  "$RENDERED/probe.sh" \
  "$RENDERED/skyeye-trading-probe.service" \
  "$RENDERED/skyeye-trading-probe.timer"
do
  [[ -f "$rendered_file" ]] || {
    printf 'FAIL: rendered artifact is missing: %s\n' "$rendered_file" >&2
    exit 1
  }
done

assert_contains "$RENDERED/trading.alloy" "$FAKE_REPO/logs/live-runs/\*\.raw\.log"
assert_contains "$RENDERED/trading.alloy" 'server_id[[:space:]]*=[[:space:]]*"trading01"'
assert_contains "$RENDERED/trading.alloy" 'strategy[[:space:]]*=[[:space:]]*"lighter-robinhood-btc-canary"'
assert_not_contains "$RENDERED/trading.alloy" '@@[A-Z_]+@@'
assert_not_contains "$RENDERED/trading.alloy" 'fake-client-secret'
assert_contains "$RENDERED/skyeye-trading-probe.service" 'User=ubuntu'
assert_contains "$RENDERED/skyeye-trading-probe.service" 'Group=ubuntu'

mode="$(stat -f '%Lp' "$RENDERED/config.env" 2>/dev/null || stat -c '%a' "$RENDERED/config.env")"
[[ "$mode" == "600" ]] || {
  printf 'FAIL: rendered Linux env mode expected=600 actual=%s\n' "$mode" >&2
  exit 1
}

if command -v alloy >/dev/null 2>&1; then
  cat >"$RENDERED/base.alloy" <<'EOF'
loki.write "central" {
  endpoint {
    url = "https://loki.invalid/loki/api/v1/push"
  }
}

prometheus.remote_write "central" {
  endpoint {
    url = "https://prometheus.invalid/api/v1/write"
  }
}
EOF
  alloy validate "$RENDERED"
fi

printf 'PASS: Linux trading Alloy coexistence render\n'
