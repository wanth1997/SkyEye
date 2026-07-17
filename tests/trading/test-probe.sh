#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE="$REPO_ROOT/agents/alloy/trading/probe.sh"

if [[ ! -x "$PROBE" ]]; then
  printf 'FAIL: probe is missing or not executable: %s\n' "$PROBE" >&2
  exit 1
fi

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-trading-probe.XXXXXX")"
FAKE_REPO="$TEST_ROOT/tnauqquant"
CONFIG_REL="config/mexc_toobit_btc_config.yaml"
CONFIG_PATH="$FAKE_REPO/$CONFIG_REL"
LOG_PATH="$FAKE_REPO/logs/live-runs/20260717_024506_mexc_toobit_btc_config.raw.log"
MANIFEST_PATH="$FAKE_REPO/run-state/mexc-toobit-btc/current.json"
MARKER_PATH="$FAKE_REPO/run-state/mexc-toobit-btc/current.done.json"
TEXTFILE_DIR="$TEST_ROOT/textfile"
METRICS_PATH="$TEXTFILE_DIR/tnauqquant.prom"
PIDS=()

cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$(dirname "$CONFIG_PATH")" "$(dirname "$LOG_PATH")" \
  "$(dirname "$MANIFEST_PATH")" "$TEXTFILE_DIR"

cat >"$CONFIG_PATH" <<'EOF'
instance_id: "mexc-toobit-btc-initiator-hedge"
max_cycles: 50
EOF

cat >"$FAKE_REPO/quant" <<'EOF'
#!/bin/sh
trap 'exit 0' TERM INT
while :; do
  sleep 1
done
EOF
chmod 755 "$FAKE_REPO/quant"
printf 'time=2026-07-17T02:45:06Z level=INFO msg=pnl_status real_pnl_usdt=12 stable=true\n' >"$LOG_PATH"

export TQ_PRODUCT=tnauqquant
export TQ_ENVIRONMENT=development
export TQ_SERVER_ID=tnauqquant-dev-mac
export TQ_STRATEGY=mexc-toobit-btc
export TQ_INSTANCE_ID=mexc-toobit-btc-initiator-hedge
export TQ_REPO_ROOT="$FAKE_REPO"
export TQ_CONFIG_PATH="$CONFIG_PATH"
export TQ_RAW_LOG_GLOB="$FAKE_REPO/logs/live-runs/*.raw.log"
export TQ_RUN_MANIFEST="$MANIFEST_PATH"
export TQ_DONE_MARKER="$MARKER_PATH"
export TQ_POC_RUN_EXPECTED=1
export TQ_TEXTFILE_DIR="$TEXTFILE_DIR"
export TQ_SIDECAR_SESSION=skyeye-fixture-missing
export TQ_SIDECAR_IDENTITY_FILE="$TEST_ROOT/missing-sidecar.identity"
export TQ_SIDECAR_HEALTH_URL=http://127.0.0.1:9/health

run_probe() {
  "$PROBE"
  [[ -f "$METRICS_PATH" ]] || {
    printf 'FAIL: metrics file was not created\n' >&2
    exit 1
  }
}

metric_value() {
  local metric="$1"
  local selector="${2:-}"
  awk -v metric="$metric" -v selector="$selector" '
    index($0, metric "{") == 1 && (selector == "" || index($0, selector) > 0) {
      print $NF
      exit
    }
  ' "$METRICS_PATH"
}

assert_metric() {
  local metric="$1"
  local expected="$2"
  local selector="${3:-}"
  local actual
  actual="$(metric_value "$metric" "$selector")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s selector=%s expected=%s actual=%s\n' \
      "$metric" "$selector" "$expected" "${actual:-<missing>}" >&2
    sed -n '1,240p' "$METRICS_PATH" >&2
    exit 1
  fi
}

start_quant() {
  "$FAKE_REPO/quant" -config "$CONFIG_REL" -s &
  STARTED_PID=$!
  PIDS+=("$STARTED_PID")
  sleep 0.2
}

stop_quant() {
  local pid="$1"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  sleep 0.2
}

write_manifest() {
  local pid="$1"
  local config_sha="$2"
  jq -n \
    --arg run_id "20260717_024506_mexc_toobit_btc_config" \
    --arg strategy "$TQ_STRATEGY" \
    --arg instance_id "$TQ_INSTANCE_ID" \
    --argjson pid "$pid" \
    --arg config_sha256 "$config_sha" \
    --arg executable "$FAKE_REPO/quant" \
    --arg config_path "$CONFIG_PATH" \
    --arg log_path "$LOG_PATH" \
    --arg done_marker_path "$MARKER_PATH" \
    '{
      schema_version: 1,
      run_id: $run_id,
      strategy: $strategy,
      instance_id: $instance_id,
      pid: $pid,
      config_sha256: $config_sha256,
      process_started_at: "2026-07-17T02:45:06Z",
      executable: $executable,
      config_path: $config_path,
      log_path: $log_path,
      done_marker_path: $done_marker_path,
      state: "running"
    }' >"$MANIFEST_PATH"
}

write_marker() {
  local pid="$1"
  local config_sha="$2"
  local reason="$3"
  jq -n \
    --arg run_id "20260717_024506_mexc_toobit_btc_config" \
    --arg strategy "$TQ_STRATEGY" \
    --arg instance_id "$TQ_INSTANCE_ID" \
    --argjson pid "$pid" \
    --arg config_sha256 "$config_sha" \
    --arg reason "$reason" \
    '{
      schema_version: 1,
      run_id: $run_id,
      strategy: $strategy,
      instance_id: $instance_id,
      pid: $pid,
      config_sha256: $config_sha256,
      reason: $reason,
      phase: $reason,
      completed_at: "2026-07-17T16:20:00Z",
      long_btc: 0,
      short_btc: 0,
      net_btc: 0,
      dust_tolerance_btc: 0
    }' >"$MARKER_PATH"
}

printf 'case: heuristic zero process\n'
run_probe
assert_metric tnauqquant_process_count 0
assert_metric tnauqquant_run_expected 1
assert_metric tnauqquant_runtime_contract_available 0
assert_metric tnauqquant_marker_binding_ok 0

printf 'case: heuristic one process\n'
start_quant
pid_one="$STARTED_PID"
run_probe
assert_metric tnauqquant_process_count 1
assert_metric tnauqquant_process_identity_ok 1
assert_metric tnauqquant_log_binding_ok 1
assert_metric tnauqquant_sidecar_up 0
assert_metric tnauqquant_sidecar_identity_ok 0

printf 'case: duplicate process\n'
start_quant
pid_two="$STARTED_PID"
run_probe
assert_metric tnauqquant_process_count 2

stop_quant "$pid_two"

config_sha="$(shasum -a 256 "$CONFIG_PATH" | awk '{print $1}')"
write_manifest "$pid_one" "$config_sha"

printf 'case: contract running\n'
run_probe
assert_metric tnauqquant_runtime_contract_available 1
assert_metric tnauqquant_process_identity_ok 1
assert_metric tnauqquant_strategy_identity_ok 1
assert_metric tnauqquant_log_binding_ok 1
assert_metric tnauqquant_marker_binding_ok 1
assert_metric tnauqquant_run_expected 1

printf 'case: safe completion\n'
write_marker "$pid_one" "$config_sha" max_cycles_complete
run_probe
assert_metric tnauqquant_done_marker 1 'reason="max_cycles_complete"'
assert_metric tnauqquant_marker_binding_ok 1
assert_metric tnauqquant_run_expected 0

printf 'case: critical terminal reason\n'
write_marker "$pid_one" "$config_sha" risk_halt
run_probe
assert_metric tnauqquant_done_marker 1 'reason="risk_halt"'
assert_metric tnauqquant_run_expected 0

printf 'case: unknown terminal reason\n'
write_marker "$pid_one" "$config_sha" future_reason
run_probe
assert_metric tnauqquant_done_marker 1 'reason="unknown"'
assert_metric tnauqquant_run_expected 0

printf 'case: marker binding mismatch\n'
write_marker "$pid_one" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" risk_halt
run_probe
assert_metric tnauqquant_marker_binding_ok 0
if [[ -n "$(metric_value tnauqquant_done_marker)" ]]; then
  printf 'FAIL: unbound marker must not emit a terminal reason\n' >&2
  exit 1
fi

mode="$(stat -f '%Lp' "$METRICS_PATH" 2>/dev/null || stat -c '%a' "$METRICS_PATH")"
if [[ "$mode" != "600" ]]; then
  printf 'FAIL: metrics mode expected=600 actual=%s\n' "$mode" >&2
  exit 1
fi

if find "$TEXTFILE_DIR" -maxdepth 1 -name '.tnauqquant.prom.*' -print | grep -q .; then
  printf 'FAIL: atomic writer left temporary files\n' >&2
  exit 1
fi

printf 'PASS: trading probe contract\n'
