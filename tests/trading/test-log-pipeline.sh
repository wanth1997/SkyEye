#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRADING_DIR="$REPO_ROOT/agents/alloy/trading"
TEMPLATE="$TRADING_DIR/config-macos.alloy.tmpl"
ENV_EXAMPLE="$TRADING_DIR/deployment.env.example"
SETUP="$TRADING_DIR/setup-macos.sh"
PLIST_TEMPLATE="$TRADING_DIR/com.wanbrain.skyeye-trading-probe.plist.tmpl"

for required_file in \
  "$TEMPLATE" \
  "$ENV_EXAMPLE" \
  "$SETUP" \
  "$PLIST_TEMPLATE" \
  "$TRADING_DIR/README.md"
do
  if [[ ! -f "$required_file" ]]; then
    printf 'FAIL: required macOS Alloy file is missing: %s\n' "$required_file" >&2
    exit 1
  fi
done

if [[ ! -x "$SETUP" ]]; then
  printf 'FAIL: setup script is not executable\n' >&2
  exit 1
fi

assert_contains() {
  local path="$1"
  local pattern="$2"
  if ! rg -q -- "$pattern" "$path"; then
    printf 'FAIL: %s does not contain pattern: %s\n' "$path" "$pattern" >&2
    exit 1
  fi
}

assert_not_contains() {
  local path="$1"
  local pattern="$2"
  if rg -q -- "$pattern" "$path"; then
    printf 'FAIL: %s contains forbidden pattern: %s\n' "$path" "$pattern" >&2
    exit 1
  fi
}

assert_contains "$TEMPLATE" 'loki.source.file "trading_raw"'
assert_contains "$TEMPLATE" 'tail_from_end[[:space:]]*=[[:space:]]*false'
assert_contains "$TEMPLATE" 'on_positions_file_error[[:space:]]*=[[:space:]]*"restart_from_end"'
assert_contains "$TEMPLATE" 'ignore_older_than[[:space:]]*=[[:space:]]*"24h"'
assert_contains "$TEMPLATE" 'stage.logfmt'
assert_contains "$TEMPLATE" 'format[[:space:]]*=[[:space:]]*"RFC3339Nano"'
assert_contains "$TEMPLATE" 'action_on_failure[[:space:]]*=[[:space:]]*"skip"'
assert_contains "$TEMPLATE" 'action_on_duplicate_timestamp[[:space:]]*=[[:space:]]*"fudge"'
assert_contains "$TEMPLATE" 'stage.replace'
assert_contains "$TEMPLATE" 'TQ_REPO_ROOT_REGEX'
assert_contains "$TEMPLATE" '\\[EMAIL\\]'
assert_contains "$TEMPLATE" '\\[ORDER_REF\\]'
assert_contains "$TEMPLATE" 'stage.label_drop'
assert_contains "$TEMPLATE" 'stage.label_keep'
assert_contains "$TEMPLATE" 'prometheus.exporter.unix "trading_textfile"'
assert_contains "$TEMPLATE" 'set_collectors[[:space:]]*=[[:space:]]*\["textfile"\]'
assert_contains "$TEMPLATE" 'sys.env\("CF_ACCESS_CLIENT_ID"\)'
assert_contains "$TEMPLATE" 'sys.env\("CF_ACCESS_CLIENT_SECRET"\)'
assert_not_contains "$TEMPLATE" 'order_id[[:space:]]*='
assert_not_contains "$TEMPLATE" 'client_action_id[[:space:]]*='

label_keep_line="$(rg 'values = \["product", "environment", "server_id", "strategy", "run_id", "level"\]' "$TEMPLATE" || true)"
if [[ -z "$label_keep_line" ]]; then
  printf 'FAIL: Loki label allowlist is not exact\n' >&2
  exit 1
fi

first_replace_line="$(rg -n 'stage.replace' "$TEMPLATE" | head -n 1 | cut -d: -f1)"
label_keep_stage_line="$(rg -n 'stage.label_keep' "$TEMPLATE" | head -n 1 | cut -d: -f1)"
loki_sink_line="$(rg -n 'loki.write "central"' "$TEMPLATE" | head -n 1 | cut -d: -f1)"
if [[ "$first_replace_line" -ge "$label_keep_stage_line" ||
      "$label_keep_stage_line" -ge "$loki_sink_line" ]]; then
  printf 'FAIL: scrub and label allowlist must execute before the Loki sink\n' >&2
  exit 1
fi

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-alloy-render.XXXXXX")"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

FAKE_REPO="$TEST_ROOT/tnauqquant"
ENV_FILE="$TEST_ROOT/config.env"
RENDERED="$TEST_ROOT/rendered"
mkdir -p "$FAKE_REPO/config" "$FAKE_REPO/logs/live-runs" \
  "$FAKE_REPO/run-state/mexc-toobit-btc" "$TEST_ROOT/textfile"
printf 'instance_id: "mexc-toobit-btc-initiator-hedge"\n' \
  >"$FAKE_REPO/config/mexc_toobit_btc_config.yaml"

cat >"$ENV_FILE" <<EOF
export TQ_PRODUCT=tnauqquant
export TQ_ENVIRONMENT=development
export TQ_SERVER_ID=tnauqquant-dev-mac
export TQ_STRATEGY=mexc-toobit-btc
export TQ_INSTANCE_ID=mexc-toobit-btc-initiator-hedge
export TQ_REPO_ROOT=$FAKE_REPO
export TQ_REPO_ROOT_REGEX='($FAKE_REPO)'
export TQ_EXECUTABLE=$FAKE_REPO/quant
export TQ_CONFIG_PATH=$FAKE_REPO/config/mexc_toobit_btc_config.yaml
export TQ_RAW_LOG_GLOB='$FAKE_REPO/logs/live-runs/*.raw.log'
export TQ_RUN_MANIFEST=$FAKE_REPO/run-state/mexc-toobit-btc/current.json
export TQ_DONE_MARKER=$FAKE_REPO/run-state/mexc-toobit-btc/current.done.json
export TQ_POC_RUN_EXPECTED=1
export TQ_REQUIRE_RUNTIME_CONTRACT=1
export TQ_TIMEZONE=Asia/Taipei
export TQ_TEXTFILE_DIR=$TEST_ROOT/textfile
export LOKI_PUSH_URL=https://loki.invalid/loki/api/v1/push
export PROM_PUSH_URL=https://prom.invalid/api/v1/write
export CF_ACCESS_CLIENT_ID=fake-client-id
export CF_ACCESS_CLIENT_SECRET=fake-client-secret
EOF
chmod 600 "$ENV_FILE"

"$SETUP" --render-only "$RENDERED" --env-file "$ENV_FILE"

RENDERED_CONFIG="$RENDERED/config.alloy"
RENDERED_PLIST="$RENDERED/com.wanbrain.skyeye-trading-probe.plist"
[[ -f "$RENDERED_CONFIG" ]] || {
  printf 'FAIL: rendered Alloy config is missing\n' >&2
  exit 1
}
[[ -f "$RENDERED_PLIST" ]] || {
  printf 'FAIL: rendered launchd plist is missing\n' >&2
  exit 1
}

assert_contains "$RENDERED_CONFIG" 'sys.env\("CF_ACCESS_CLIENT_SECRET"\)'
assert_not_contains "$RENDERED_CONFIG" 'fake-client-secret'
assert_not_contains "$RENDERED_PLIST" 'fake-client-secret'
plutil -lint "$RENDERED_PLIST" >/dev/null

if command -v alloy >/dev/null 2>&1; then
  alloy fmt "$RENDERED_CONFIG" >/dev/null
  alloy validate "$RENDERED_CONFIG"
fi

printf 'PASS: trading Alloy render and label contract\n'
