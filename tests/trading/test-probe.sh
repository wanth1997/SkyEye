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
PREVIOUS_LOG_PATH="$FAKE_REPO/logs/live-runs/20260717_010000_previous_mexc_toobit_btc_config.raw.log"
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
today_local="$(TZ=Asia/Taipei date +%F)"
cat >"$LOG_PATH" <<EOF
time=${today_local}T09:00:00+08:00 level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=current.1 real_pnl_usdt=10 cash_pnl_usdt=8 rebate_usdt=2 risk_pnl_usdt=9 cycles_completed=1 cycle_real_pnl_usdt=10
time=${today_local}T09:30:00+08:00 level=INFO msg=pnl_status stable=false cycle_completed=false cycle_id=current.pending real_pnl_usdt=999 cash_pnl_usdt=999 rebate_usdt=0 risk_pnl_usdt=999 cycles_completed=1
time=${today_local}T10:00:00+08:00 level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=current.2 real_pnl_usdt=12.5 cash_pnl_usdt=9.5 rebate_usdt=3 risk_pnl_usdt=11.5 cycles_completed=2 cycle_real_pnl_usdt=2.5
time=${today_local}T10:00:00+08:00 level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=current.2 real_pnl_usdt=12.5 cash_pnl_usdt=9.5 rebate_usdt=3 risk_pnl_usdt=11.5 cycles_completed=2 cycle_real_pnl_usdt=2.5
time=${today_local}T10:01:00+08:00 level=INFO msg=trade_status state=settled initiator_venue=toobit-main initiator_side=Short initiator_qty_btc=0.125 carrier_venue=mexc-ui carrier_side=Long carrier_qty_btc=0.125 portfolio_projection=coordinator_book
time=${today_local}T10:02:00+08:00 level=INFO msg=coordinated_signal_skipped initiator_venue=toobit-main initiator_side=Short initiator_qty_btc=0.103 carrier_venue=mexc-ui carrier_side=Long carrier_qty_btc=0.103 portfolio_projection=coordinator_book
time=${today_local}T10:03:00+08:00 level=INFO msg=invalid_snapshot initiator_venue=unknown initiator_side=Short initiator_qty_btc=99 carrier_venue=mexc-ui carrier_side=Long carrier_qty_btc=99 portfolio_projection=coordinator_book
EOF
cat >"$PREVIOUS_LOG_PATH" <<EOF
time=${today_local}T08:00:00+08:00 level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=previous.1 real_pnl_usdt=4 cash_pnl_usdt=3 rebate_usdt=1 risk_pnl_usdt=3.5 cycles_completed=1
time=${today_local}T08:00:00+08:00 level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=previous.1 real_pnl_usdt=4 cash_pnl_usdt=3 rebate_usdt=1 risk_pnl_usdt=3.5 cycles_completed=1
EOF

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
export TQ_REQUIRE_RUNTIME_CONTRACT=1
export TQ_TIMEZONE=Asia/Taipei
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

assert_metric_missing() {
  local metric="$1"
  if [[ -n "$(metric_value "$metric")" ]]; then
    printf 'FAIL: %s must not be emitted\n' "$metric" >&2
    sed -n '1,280p' "$METRICS_PATH" >&2
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

printf 'case: production contract required\n'
run_probe
assert_metric tnauqquant_process_count 0
assert_metric tnauqquant_run_expected 1
assert_metric tnauqquant_runtime_contract_available 0
assert_metric tnauqquant_process_identity_ok 0
assert_metric tnauqquant_log_binding_ok 0
assert_metric tnauqquant_marker_binding_ok 0
assert_metric tnauqquant_current_pnl_valid 0
assert_metric tnauqquant_current_position_valid 0
assert_metric_missing tnauqquant_current_run_info
assert_metric_missing tnauqquant_current_real_pnl_usdt
assert_metric_missing tnauqquant_last_cycle_real_pnl_usdt
assert_metric_missing tnauqquant_current_position_btc

printf 'case: development heuristic zero process\n'
export TQ_REQUIRE_RUNTIME_CONTRACT=0
run_probe
assert_metric tnauqquant_process_count 0
assert_metric tnauqquant_run_expected 1
assert_metric tnauqquant_runtime_contract_available 0
assert_metric tnauqquant_log_binding_ok 1

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
export TQ_REQUIRE_RUNTIME_CONTRACT=1

printf 'case: contract running\n'
run_probe
assert_metric tnauqquant_runtime_contract_available 1
assert_metric tnauqquant_process_identity_ok 1
assert_metric tnauqquant_strategy_identity_ok 1
assert_metric tnauqquant_log_binding_ok 1
assert_metric tnauqquant_marker_binding_ok 1
assert_metric tnauqquant_run_expected 1
assert_metric tnauqquant_current_run_info 1 'run_id="20260717_024506_mexc_toobit_btc_config"'
assert_metric tnauqquant_current_pnl_valid 1
assert_metric tnauqquant_current_real_pnl_usdt 12.5
assert_metric tnauqquant_current_cash_pnl_usdt 9.5
assert_metric tnauqquant_current_rebate_usdt 3
assert_metric tnauqquant_current_risk_pnl_usdt 11.5
assert_metric tnauqquant_current_cycles_completed 2
assert_metric tnauqquant_completed_cycles_today 3
assert_metric tnauqquant_last_cycle_real_pnl_usdt 2.5
assert_metric tnauqquant_current_position_valid 1
assert_metric tnauqquant_current_position_btc 0.103 'exchange="toobit",side="short"'
assert_metric tnauqquant_current_position_btc 0.103 'exchange="mexc",side="long"'

sample_timestamp="$(metric_value tnauqquant_pnl_sample_timestamp_seconds)"
last_completed_timestamp="$(metric_value tnauqquant_last_completed_cycle_timestamp_seconds)"
run_started_timestamp="$(metric_value tnauqquant_current_run_started_timestamp_seconds)"
for timestamp_value in "$sample_timestamp" "$last_completed_timestamp" "$run_started_timestamp"; do
  if [[ ! "$timestamp_value" =~ ^[0-9]+$ ]] || [[ "$timestamp_value" -le 0 ]]; then
    printf 'FAIL: expected a positive timestamp, got %s\n' "${timestamp_value:-<missing>}" >&2
    exit 1
  fi
done

if rg -q '(_path|pid)=' "$METRICS_PATH"; then
  printf 'FAIL: paths and process IDs must not become metric labels\n' >&2
  exit 1
fi

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
