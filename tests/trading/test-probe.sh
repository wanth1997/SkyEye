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

# Compiled so ps, lsof and /proc report quant itself, as for the real binary.
printf '#include <unistd.h>\nint main(void) { for (;;) pause(); }\n' >"$TEST_ROOT/fake-quant.c"
cc -o "$FAKE_REPO/quant" "$TEST_ROOT/fake-quant.c"
# These events sit at fixed hours of today. The probe rejects future samples and
# counts today by instant, so the log offset must be the zone's and those hours must
# have passed. The zone where it is now about 18:00 gives both at any time of day,
# and leaves hours before midnight, so this suite does not depend on when it runs.
fixture_utc_hour="$(date -u +%H)"
fixture_offset_hours=$(((18 - 10#$fixture_utc_hour + 36) % 24 - 12))
FIXTURE_OFFSET="$(printf '%+03d:00' "$fixture_offset_hours")"
FIXTURE_TIMEZONE="$(printf 'Etc/GMT%+d' "$((-fixture_offset_hours))")"
today_local="$(TZ="$FIXTURE_TIMEZONE" date +%F)"
cat >"$LOG_PATH" <<EOF
time=${today_local}T09:00:00${FIXTURE_OFFSET} level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=current.1 session_cycle=1 real_pnl_usdt=10 cash_pnl_usdt=8 rebate_usdt=2 risk_pnl_usdt=9 cycles_completed=1 cycle_real_pnl_usdt=10
time=${today_local}T09:30:00${FIXTURE_OFFSET} level=INFO msg=pnl_status stable=false cycle_completed=false cycle_id=current.pending real_pnl_usdt=999 cash_pnl_usdt=999 rebate_usdt=0 risk_pnl_usdt=999 cycles_completed=1
time=${today_local}T10:00:00${FIXTURE_OFFSET} level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=current.2 session_cycle=2 equity_now=3000.75 equity_usdt_by_executor=mexc-ui:1000.25,toobit-main:2000.50 real_pnl_usdt=12.5 cash_pnl_usdt=9.5 rebate_usdt=3 risk_pnl_usdt=11.5 cycles_completed=2 cycle_real_pnl_usdt=2.5
time=${today_local}T10:00:00${FIXTURE_OFFSET} level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=current.2 session_cycle=2 equity_now=3000.75 equity_usdt_by_executor=mexc-ui:1000.25,toobit-main:2000.50 real_pnl_usdt=12.5 cash_pnl_usdt=9.5 rebate_usdt=3 risk_pnl_usdt=11.5 cycles_completed=2 cycle_real_pnl_usdt=2.5 risk_stopped=false
time=${today_local}T10:01:00${FIXTURE_OFFSET} level=INFO msg=trade_status state=settled initiator_venue=toobit-main initiator_side=Short initiator_qty_btc=0.125 carrier_venue=mexc-ui carrier_side=Long carrier_qty_btc=0.125 portfolio_projection=coordinator_book
time=${today_local}T10:02:00${FIXTURE_OFFSET} level=INFO msg=coordinated_signal_skipped initiator_venue=toobit-main initiator_side=Short initiator_qty_btc=0.103 carrier_venue=mexc-ui carrier_side=Long carrier_qty_btc=0.103 portfolio_projection=coordinator_book
time=${today_local}T10:03:00${FIXTURE_OFFSET} level=INFO msg=invalid_snapshot initiator_venue=unknown initiator_side=Short initiator_qty_btc=99 carrier_venue=mexc-ui carrier_side=Long carrier_qty_btc=99 portfolio_projection=coordinator_book
time=${today_local}T10:04:00${FIXTURE_OFFSET} level=INFO msg=trade_status state=open executor=toobit-main attempt_id=101 volume_usd=100.25 total_volume_usd=100.25
time=${today_local}T10:05:00${FIXTURE_OFFSET} level=INFO msg=trade_status state=closed executor=mexc-ui attempt_id=102 volume_usd=99.75 total_volume_usd=200
time=${today_local}T10:06:00${FIXTURE_OFFSET} level=INFO msg=trade_status state=settled executor=mexc-ui attempt_id=102 settlement=confirmed
time=${today_local}T10:07:00${FIXTURE_OFFSET} level=INFO msg=coordinated_signal_skipped executor=toobit-main volume_usd=500
time=${today_local}T10:08:00${FIXTURE_OFFSET} level=INFO msg=trade_status state=closed executor=unknown volume_usd=700
time=${today_local}T10:09:00${FIXTURE_OFFSET} level=INFO msg=trade_status state=closed executor=toobit-main volume_usd=-1
EOF
cat >"$PREVIOUS_LOG_PATH" <<EOF
time=${today_local}T08:00:00${FIXTURE_OFFSET} level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=previous.1 equity_now=99999 real_pnl_usdt=4 cash_pnl_usdt=3 rebate_usdt=1 risk_pnl_usdt=3.5 cycles_completed=1
time=${today_local}T08:00:00${FIXTURE_OFFSET} level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=previous.1 equity_now=99999 real_pnl_usdt=4 cash_pnl_usdt=3 rebate_usdt=1 risk_pnl_usdt=3.5 cycles_completed=1
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
export TQ_TIMEZONE="$FIXTURE_TIMEZONE"
export TQ_TEXTFILE_DIR="$TEXTFILE_DIR"
export TQ_EXECUTOR_MAP=toobit-main=toobit,mexc-ui=mexc
export TQ_SIDECAR_REQUIRED=1
export TQ_TEXTFILE_MODE=600
export TQ_SIDECAR_SESSION=skyeye-fixture-missing
export TQ_SIDECAR_IDENTITY_FILE="$TEST_ROOT/missing-sidecar.identity"
export TQ_SIDECAR_HEALTH_URL=http://127.0.0.1:9/health
# Unset, not empty: the default (BTC) applies only to an undefined variable,
# whatever the shell that runs this suite exported.
unset TQ_BASE_ASSET

# The HELP text of the position families as master published it before
# TQ_BASE_ASSET existed. One textfile collector drops a family whose HELP
# differs between .prom files, and old and new probe outputs share a collector
# while a host's probes are re-added one at a time, so it must never change.
PINNED_POSITION_HELP='# HELP tnauqquant_current_position_btc Latest coordinator-reported position quantity by exchange and side.
# HELP tnauqquant_current_net_position_btc Signed net BTC position from the latest coordinator book.'

assert_position_help_pinned() {
  local actual
  actual="$(rg '^# HELP tnauqquant_current_(net_)?position_btc ' "$METRICS_PATH" || true)"
  if [[ "$actual" != "$PINNED_POSITION_HELP" ]]; then
    printf 'FAIL: position HELP text differs from the pinned master text; old and new .prom files could not share a collector\nexpected:\n%s\nactual:\n%s\n' \
      "$PINNED_POSITION_HELP" "$actual" >&2
    exit 1
  fi
}

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

process_started_iso() {
  local started
  started="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$1" | sed -E 's/[[:space:]]+$//')"
  LC_ALL=C TZ=UTC date -j -f '%a %b %e %T %Y' "$started" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    LC_ALL=C TZ=UTC date -d "$started" +%Y-%m-%dT%H:%M:%SZ
}

write_manifest() {
  local pid="$1"
  local config_sha="$2"
  MANIFEST_STARTED_AT="$(process_started_iso "$pid")"
  jq -n \
    --arg process_started_at "$MANIFEST_STARTED_AT" \
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
      process_started_at: $process_started_at,
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
    --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      schema_version: 1,
      run_id: $run_id,
      strategy: $strategy,
      instance_id: $instance_id,
      pid: $pid,
      config_sha256: $config_sha256,
      reason: $reason,
      phase: $reason,
      completed_at: $completed_at,
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
assert_metric tnauqquant_config_snapshot_match 0
assert_metric tnauqquant_log_binding_ok 0
assert_metric tnauqquant_marker_binding_ok 0
assert_metric tnauqquant_current_pnl_valid 0
assert_metric_missing tnauqquant_current_equity_usdt
assert_metric tnauqquant_current_position_valid 0
assert_metric_missing tnauqquant_current_run_info
assert_metric_missing tnauqquant_current_real_pnl_usdt
assert_metric_missing tnauqquant_last_cycle_real_pnl_usdt
assert_metric_missing tnauqquant_cycle_cumulative_real_pnl_usdt
assert_metric_missing tnauqquant_current_position_btc
assert_metric_missing tnauqquant_current_run_exchange_volume_usd

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
assert_metric tnauqquant_config_snapshot_match 0
assert_metric tnauqquant_log_binding_ok 1
assert_metric tnauqquant_sidecar_up 0
assert_metric tnauqquant_sidecar_identity_ok 0
assert_metric tnauqquant_sidecar_required 1

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
assert_metric tnauqquant_config_snapshot_match 1
assert_metric tnauqquant_log_binding_ok 1
assert_metric tnauqquant_marker_binding_ok 1
assert_metric tnauqquant_run_expected 1
assert_metric tnauqquant_current_run_info 1 'run_id="20260717_024506_mexc_toobit_btc_config"'
assert_metric tnauqquant_current_pnl_valid 1
assert_metric tnauqquant_current_real_pnl_usdt 12.5
assert_metric tnauqquant_current_equity_usdt 3000.75
assert_metric tnauqquant_current_cash_pnl_usdt 9.5
assert_metric tnauqquant_current_rebate_usdt 3
assert_metric tnauqquant_current_risk_pnl_usdt 11.5
assert_metric tnauqquant_current_cycles_completed 2
assert_metric tnauqquant_completed_cycles_today 3
assert_metric tnauqquant_last_cycle_real_pnl_usdt 2.5
assert_metric tnauqquant_cycle_cumulative_real_pnl_usdt 10 'cycle="1"'
assert_metric tnauqquant_cycle_cumulative_real_pnl_usdt 12.5 'cycle="2"'
cycle_pnl_series_count="$(awk '
  index($0, "tnauqquant_cycle_cumulative_real_pnl_usdt{") == 1 { count++ }
  END { print count + 0 }
' "$METRICS_PATH")"
if [[ "$cycle_pnl_series_count" != "2" ]]; then
  printf 'FAIL: expected two deduplicated current-run cycle PNL series, got %s\n' \
    "$cycle_pnl_series_count" >&2
  exit 1
fi
assert_metric tnauqquant_current_position_valid 1
assert_metric tnauqquant_current_position_btc 0.103 'exchange="toobit",side="short"'
assert_metric tnauqquant_current_position_btc 0.103 'exchange="mexc",side="long"'
assert_metric tnauqquant_current_net_position_btc 0
# TQ_BASE_ASSET is unset here: quantities stay BTC, as before the variable
# existed, and no other series gains the label.
assert_metric tnauqquant_current_position_btc 0.103 'base_asset="BTC",exchange="toobit",side="short"'
assert_metric tnauqquant_current_net_position_btc 0 'base_asset="BTC"}'
base_asset_metrics="$(rg -o '^[a-z_]+\{[^}]*base_asset=' "$METRICS_PATH" | sed 's/{.*//' | sort -u | tr '\n' ' ')"
[[ "$base_asset_metrics" == 'tnauqquant_current_net_position_btc tnauqquant_current_position_btc ' ]] || {
  printf 'FAIL: base_asset must label only the position quantities, found it on: %s\n' "$base_asset_metrics" >&2
  exit 1
}
assert_position_help_pinned
assert_metric tnauqquant_current_run_exchange_volume_usd 100.25 'exchange="toobit"'
assert_metric tnauqquant_current_run_exchange_volume_usd 99.75 'exchange="mexc"'
assert_metric tnauqquant_risk_stopped 0

printf 'case: latest stable total equity ignores unstable snapshots\n'
cp "$LOG_PATH" "$TEST_ROOT/balance.original.log"
printf 'time=%sT10:10:00%s level=INFO msg=pnl_status stable=false equity_now=999999 real_pnl_usdt=999999\n' \
  "$today_local" "$FIXTURE_OFFSET" >>"$LOG_PATH"
run_probe
assert_metric tnauqquant_current_equity_usdt 3000.75

printf 'case: valid zero equity is emitted\n'
printf 'time=%sT10:11:00%s level=INFO msg=pnl_status stable=true equity_now=0 real_pnl_usdt=0\n' \
  "$today_local" "$FIXTURE_OFFSET" >>"$LOG_PATH"
run_probe
assert_metric tnauqquant_current_equity_usdt 0

printf 'case: missing and invalid equity never reuse an earlier total\n'
for equity_field in '' 'equity_now=NaN' 'equity_now=+Inf' 'equity_now=invalid'; do
  cp "$TEST_ROOT/balance.original.log" "$LOG_PATH"
  printf 'time=%sT10:12:00%s level=INFO msg=pnl_status stable=true real_pnl_usdt=12.5 %s\n' \
    "$today_local" "$FIXTURE_OFFSET" "$equity_field" >>"$LOG_PATH"
  run_probe
  assert_metric tnauqquant_current_pnl_valid 1
  assert_metric_missing tnauqquant_current_equity_usdt
done
cp "$TEST_ROOT/balance.original.log" "$LOG_PATH"

printf 'case: running config drift remains observable\n'
config_before_drift="$TEST_ROOT/config.before-drift"
cp "$CONFIG_PATH" "$config_before_drift"
printf 'future_setting: true\n' >>"$CONFIG_PATH"
run_probe
assert_metric tnauqquant_runtime_contract_available 1
assert_metric tnauqquant_config_snapshot_match 0
assert_metric tnauqquant_process_identity_ok 1
assert_metric tnauqquant_log_binding_ok 1
assert_metric tnauqquant_current_pnl_valid 1
assert_metric tnauqquant_cycle_cumulative_real_pnl_usdt 10 'cycle="1"'
assert_metric tnauqquant_cycle_cumulative_real_pnl_usdt 12.5 'cycle="2"'
mv "$config_before_drift" "$CONFIG_PATH"

sample_timestamp="$(metric_value tnauqquant_pnl_sample_timestamp_seconds)"
last_completed_timestamp="$(metric_value tnauqquant_last_completed_cycle_timestamp_seconds)"
run_started_timestamp="$(metric_value tnauqquant_current_run_started_timestamp_seconds)"
expected_run_started="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$MANIFEST_STARTED_AT" +%s 2>/dev/null ||
  date -d "$MANIFEST_STARTED_AT" +%s)"
if [[ "$run_started_timestamp" != "$expected_run_started" ]]; then
  printf 'FAIL: UTC run start expected=%s actual=%s\n' "$expected_run_started" \
    "${run_started_timestamp:-<missing>}" >&2
  exit 1
fi
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

printf 'case: single-exchange Lighter contract\n'
stop_quant "$pid_one"

LIGHTER_CONFIG_PATH="$FAKE_REPO/config/lighter_robinhood_btc_config.yaml"
LIGHTER_LOG_PATH="$FAKE_REPO/logs/live-runs/20260826_235524_lighter_robinhood_btc_config.raw.log"
LIGHTER_MANIFEST_PATH="$FAKE_REPO/run-state/lighter-robinhood-btc-canary/current.json"
LIGHTER_MARKER_PATH="$FAKE_REPO/run-state/lighter-robinhood-btc-canary/current.done.json"
mkdir -p "$(dirname "$LIGHTER_MANIFEST_PATH")"
cat >"$LIGHTER_CONFIG_PATH" <<'EOF'
instance_id: "lighter-robinhood-btc-canary"
max_cycles: 500
EOF
cat >"$LIGHTER_LOG_PATH" <<EOF
time=${today_local}T11:12:11${FIXTURE_OFFSET} level=INFO msg=pnl_status stable=false cycle_completed=false real_pnl_usdt=999 volume_usd_by_executor=lighter-robinhood-main:999
time=${today_local}T11:14:06${FIXTURE_OFFSET} level=WARN msg=coordinator_domain_fenced_signal_skipped attempt_id=44 reservation_id=1268 linked_reservation_id=0 recovery_group_id=0 initiator_venue=lighter-robinhood-main initiator_side=Short initiator_qty_btc=0.00231 net_side=Short net_qty_btc=0.00231 portfolio_projection=coordinator_book
time=${today_local}T11:14:14${FIXTURE_OFFSET} level=INFO msg=pnl_status stable=true cycle_completed=true session_cycle=196 equity_now=501.4083 equity_usdt_by_executor=lighter-robinhood-main:501.41 real_pnl_usdt=1.4083 cash_pnl_usdt=1.4083 rebate_usdt=0 risk_pnl_usdt=1.4083 cycles_completed=195 cycle_real_pnl_usdt=-0.0151 risk_stopped=false volume_usd_by_executor=lighter-robinhood-main:68610.97
EOF

export TQ_STRATEGY=lighter-robinhood-btc-canary
export TQ_INSTANCE_ID=lighter-robinhood-btc-canary
export TQ_CONFIG_PATH="$LIGHTER_CONFIG_PATH"
export TQ_RUN_MANIFEST="$LIGHTER_MANIFEST_PATH"
export TQ_DONE_MARKER="$LIGHTER_MARKER_PATH"
export TQ_EXECUTOR_MAP=lighter-robinhood-main=lighter
export TQ_SIDECAR_REQUIRED=0
export TQ_TEXTFILE_MODE=640

lighter_config_sha="$(shasum -a 256 "$LIGHTER_CONFIG_PATH" | awk '{print $1}')"
jq -n \
  --arg run_id "20260826_235524_lighter_robinhood_btc_config" \
  --arg strategy "$TQ_STRATEGY" \
  --arg instance_id "$TQ_INSTANCE_ID" \
  --arg config_sha256 "$lighter_config_sha" \
  --arg executable "$FAKE_REPO/quant" \
  --arg config_path "$LIGHTER_CONFIG_PATH" \
  --arg log_path "$LIGHTER_LOG_PATH" \
  --arg done_marker_path "$LIGHTER_MARKER_PATH" \
  '{
    schema_version: 1,
    run_id: $run_id,
    strategy: $strategy,
    instance_id: $instance_id,
    pid: 999999,
    config_sha256: $config_sha256,
    process_started_at: "2026-08-26T23:55:24Z",
    executable: $executable,
    config_path: $config_path,
    log_path: $log_path,
    done_marker_path: $done_marker_path,
    state: "running"
  }' >"$LIGHTER_MANIFEST_PATH"

run_probe
assert_metric tnauqquant_process_count 0
assert_metric tnauqquant_run_expected 1
assert_metric tnauqquant_current_real_pnl_usdt 1.4083
assert_metric tnauqquant_current_equity_usdt 501.4083
assert_metric tnauqquant_current_run_exchange_volume_usd 68610.97 'exchange="lighter"'
assert_metric tnauqquant_current_position_valid 1
assert_metric tnauqquant_current_position_btc 0.00231 'exchange="lighter",side="short"'
assert_metric tnauqquant_current_net_position_btc -0.00231
assert_metric tnauqquant_sidecar_required 0
assert_metric tnauqquant_risk_stopped 0

printf 'case: single-exchange flat and long net positions\n'
printf 'time=%sT11:15:00%s level=INFO msg=position_update net_side=Flat net_qty_btc=0 portfolio_projection=coordinator_book\n' \
  "$today_local" "$FIXTURE_OFFSET" >>"$LIGHTER_LOG_PATH"
run_probe
assert_metric tnauqquant_current_position_btc 0 'exchange="lighter",side="flat"'
assert_metric tnauqquant_current_net_position_btc 0

printf 'time=%sT11:16:00%s level=INFO msg=position_update net_side=Long net_qty_btc=0.003 portfolio_projection=coordinator_book\n' \
  "$today_local" "$FIXTURE_OFFSET" >>"$LIGHTER_LOG_PATH"
run_probe
assert_metric tnauqquant_current_position_btc 0.003 'exchange="lighter",side="long"'
assert_metric tnauqquant_current_net_position_btc 0.003

# GNU first: its stat -f prints filesystem data before failing, which would stay in mode.
mode="$(stat -c '%a' "$METRICS_PATH" 2>/dev/null || stat -f '%Lp' "$METRICS_PATH")"
if [[ "$mode" != "640" ]]; then
  printf 'FAIL: metrics mode expected=640 actual=%s\n' "$mode" >&2
  exit 1
fi

printf 'case: single-exchange PopDEX text-log contract\n'
# logging.format: text is Go slog TextHandler output, i.e. logfmt. These lines
# follow the 2026-11-13 Trading01 canary: UTC times with milliseconds, a quoted
# summary that repeats keys with rounded values, an empty quoted value, one
# executor and a net position with no carrier. IDs are synthetic.
POPDEX_CONFIG_PATH="$FAKE_REPO/config/popdex_btc_config.yaml"
POPDEX_LOG_PATH="$FAKE_REPO/logs/live-runs/20261113_141635_popdex_btc_config.raw.log"
POPDEX_MANIFEST_PATH="$FAKE_REPO/run-state/popdex-btc/current.json"
POPDEX_MARKER_PATH="$FAKE_REPO/run-state/popdex-btc/current.done.json"
POPDEX_RUN_ID=20261113_141635_popdex_btc_config
mkdir -p "$(dirname "$POPDEX_MANIFEST_PATH")"
cat >"$POPDEX_CONFIG_PATH" <<'EOF'
instance_id: "popdex-btc"
max_cycles: 3
logging:
  format: text
EOF
cat >"$POPDEX_LOG_PATH" <<EOF
time=${today_local}T12:00:01.763${FIXTURE_OFFSET} level=INFO msg=tactic_taker_ioc_sent order_id=9000001 price=68836 book_level=0 qty_contracts=0.0002 order_qty=0.0002
time=${today_local}T12:00:01.764${FIXTURE_OFFSET} level=WARN msg=coordinated_dispatch_result intent=normal_entry executor=popdex-main attempt_id=11 client_action_id=tq-fixture-11 dispatch_claimed=true disposition=unresolved order_id=9000001 ack_client_id=tq-fixture-11 cycle_state=waiting signal_direction=Short net_side=Flat net_qty_btc=0.00000000 portfolio_projection=coordinator_book ui_submission_status=accepted
time=${today_local}T12:00:02.063${FIXTURE_OFFSET} level=INFO msg=trade_status state=open signal=open position=Short executor=popdex-main attempt_id=11 client_action_id=tq-fixture-11 qty_base=0.00020000 volume_usd=13.82 total_volume_usd=13.82 quote_notional="" settlement=pending cycle=1 session_cycle=1 cycle_id=fixture-1.1 cycle_identity_state=active
time=${today_local}T12:00:02.545${FIXTURE_OFFSET} level=INFO msg=trade_status state=settled phase=entry executor=popdex-main attempt_id=11 settlement=confirmed evidence_source=api_position cycle=1 session_cycle=1 cycle_id=fixture-1.1 initiator_venue=popdex-main initiator_side=Short initiator_qty_btc=0.00020000 net_side=Short net_qty_btc=0.00020000 portfolio_projection=coordinator_book next_action=close_position
time=${today_local}T12:01:04.218${FIXTURE_OFFSET} level=INFO msg=trade_status state=closed executor=popdex-main attempt_id=12 volume_usd=13.82 total_volume_usd=27.64 net_side=Flat net_qty_btc=0.00000000 portfolio_projection=coordinator_book
time=${today_local}T12:01:04.300${FIXTURE_OFFSET} level=INFO msg=pnl_status equity_start=9999 equity_now=9998.9862 rebate_usdt=0.0044 cash_pnl_usdt=-0.0062 real_pnl_usdt=-0.0018 risk_pnl_usdt=-0.0018 cycles_completed=1 risk_stopped=false samples=2 stable=true cycle_completed=true summary="PNL equity_start=9999.00 equity_now=9998.99 cash_pnl=-0.0062 rebate=0.0044 real_pnl=-0.0018 risk_pnl=-0.0018 cycles=1 risk_stopped=false samples=2 stable=true cycle_completed=true" equity_usdt_by_executor=popdex-main:9998.99 volume_usd_by_executor=popdex-main:27.64 cycle_real_pnl_usdt=-0.0018 cycle=1 session_cycle=1 cycle_id=fixture-1.1 cycle_identity_state=complete
time=${today_local}T12:02:43.216${FIXTURE_OFFSET} level=INFO msg=trade_status state=open signal=open position=Short executor=popdex-main attempt_id=13 client_action_id=tq-fixture-13 volume_usd=13.76 total_volume_usd=41.4 quote_notional="" settlement=pending cycle=2 session_cycle=2 cycle_id=fixture-1.2
time=${today_local}T12:02:43.329${FIXTURE_OFFSET} level=INFO msg=trade_status state=settled phase=entry executor=popdex-main attempt_id=13 settlement=confirmed cycle=2 session_cycle=2 cycle_id=fixture-1.2 initiator_venue=popdex-main initiator_side=Short initiator_qty_btc=0.10000000 net_side=Short net_qty_btc=0.10000000 portfolio_projection=coordinator_book
EOF

export TQ_STRATEGY=popdex-btc
export TQ_INSTANCE_ID=popdex-btc
export TQ_CONFIG_PATH="$POPDEX_CONFIG_PATH"
export TQ_RAW_LOG_GLOB="$FAKE_REPO/logs/live-runs/*popdex_btc_config.raw.log"
export TQ_RUN_MANIFEST="$POPDEX_MANIFEST_PATH"
export TQ_DONE_MARKER="$POPDEX_MARKER_PATH"
export TQ_EXECUTOR_MAP=popdex-main=popdex
export TQ_TEXTFILE_NAME=tnauqquant-popdex-btc.prom
ROBINHOOD_METRICS_PATH="$METRICS_PATH"
METRICS_PATH="$TEXTFILE_DIR/tnauqquant-popdex-btc.prom"

popdex_config_sha="$(shasum -a 256 "$POPDEX_CONFIG_PATH" | awk '{print $1}')"
jq -n \
  --arg run_id "$POPDEX_RUN_ID" \
  --arg strategy "$TQ_STRATEGY" \
  --arg instance_id "$TQ_INSTANCE_ID" \
  --arg config_sha256 "$popdex_config_sha" \
  --arg executable "$FAKE_REPO/quant" \
  --arg config_path "$POPDEX_CONFIG_PATH" \
  --arg log_path "$POPDEX_LOG_PATH" \
  --arg done_marker_path "$POPDEX_MARKER_PATH" \
  '{
    schema_version: 1,
    run_id: $run_id,
    strategy: $strategy,
    instance_id: $instance_id,
    pid: 999999,
    config_sha256: $config_sha256,
    process_started_at: "2026-11-13T14:16:35Z",
    executable: $executable,
    config_path: $config_path,
    log_path: $log_path,
    done_marker_path: $done_marker_path,
    state: "running"
  }' >"$POPDEX_MANIFEST_PATH"

run_probe
assert_metric tnauqquant_process_count 0
assert_metric tnauqquant_run_expected 1
assert_metric tnauqquant_runtime_contract_available 1
assert_metric tnauqquant_log_binding_ok 1
assert_metric tnauqquant_current_run_info 1 "run_id=\"$POPDEX_RUN_ID\""
assert_metric tnauqquant_current_pnl_valid 1
assert_metric tnauqquant_current_real_pnl_usdt -0.0018
# The first equity_now is the record's; the summary repeats it rounded.
assert_metric tnauqquant_current_equity_usdt 9998.9862
assert_metric tnauqquant_current_cycles_completed 1
assert_metric tnauqquant_last_cycle_real_pnl_usdt -0.0018
assert_metric tnauqquant_cycle_cumulative_real_pnl_usdt -0.0018 'cycle="1"'
# The stable snapshot wins over the trade_status volumes, which include cycle 2.
assert_metric tnauqquant_current_run_exchange_volume_usd 27.64 'exchange="popdex"'
assert_metric tnauqquant_current_position_valid 1
assert_metric tnauqquant_current_position_btc 0.10000000 'exchange="popdex",side="short"'
assert_metric tnauqquant_current_net_position_btc -0.1
assert_metric tnauqquant_sidecar_required 0
assert_metric tnauqquant_risk_stopped 0
popdex_exchange_series="$(rg -o 'exchange="[^"]*"' "$METRICS_PATH" | sort -u | tr '\n' ' ')"
[[ "$popdex_exchange_series" == 'exchange="popdex" ' ]] || {
  printf 'FAIL: PopDEX output named another exchange: %s\n' "$popdex_exchange_series" >&2
  exit 1
}
if rg -q '(_path|pid|order_id|client_id)=' "$METRICS_PATH"; then
  printf 'FAIL: PopDEX paths, PIDs or order references became metric labels\n' >&2
  exit 1
fi
for single_exec_metric in \
  tnauqquant_current_executor_equity_usdt \
  tnauqquant_current_executor_real_pnl_usdt \
  tnauqquant_current_executor_cycles_completed \
  tnauqquant_current_run_executor_volume_usd
do
  assert_metric_missing "$single_exec_metric"
done

printf 'case: TQ_BASE_ASSET=ETH labels the quantities ETH\n'
# popdex-02 trades ETH and still logs *_qty_btc; the env names the real asset.
export TQ_BASE_ASSET=ETH
run_probe
assert_metric tnauqquant_current_position_btc 0.10000000 'base_asset="ETH",exchange="popdex",side="short"'
assert_metric tnauqquant_current_net_position_btc -0.1 'base_asset="ETH"}'
if rg -q 'base_asset="BTC"' "$METRICS_PATH"; then
  printf 'FAIL: an ETH lane still published a BTC quantity\n' >&2
  exit 1
fi
assert_position_help_pinned

printf 'case: invalid TQ_BASE_ASSET is refused before any output\n'
eth_output="$(cat "$METRICS_PATH")"
# '' is set but empty: only an unset variable means BTC. The full-width ETH
# runs under a UTF-8 locale, where a range class can match it.
for bad_asset in '' eth Eth 'ETH ' 'E-TH' 'ETH"' 'BTC,x="y"' ABCDEFGHIJKLMNOPQ 'ＥＴＨ'; do
  export TQ_BASE_ASSET="$bad_asset"
  if bad_output="$(LC_ALL=en_US.UTF-8 "$PROBE" 2>&1)"; then
    printf 'FAIL: probe accepted TQ_BASE_ASSET=%s\n' "$bad_asset" >&2
    exit 1
  fi
  [[ "$bad_output" == *'TQ_BASE_ASSET must be'* ]] || {
    printf 'FAIL: refusal of TQ_BASE_ASSET=%s did not name the variable: %s\n' "$bad_asset" "$bad_output" >&2
    exit 1
  }
  [[ "$(cat "$METRICS_PATH")" == "$eth_output" ]] || {
    printf 'FAIL: refused TQ_BASE_ASSET=%s still rewrote the metrics\n' "$bad_asset" >&2
    exit 1
  }
done
unset TQ_BASE_ASSET

printf 'case: a gross-flat line publishes the filled close before the next book line\n'
# Fixture lines 1-16 are popdex-02 evidence lines 126-141 of 2026-11-19 with IDs
# redacted and the accounting lines cut to synthetic values: a Long 1.5 entry, a
# close that fills at line 12 while the last book line (11) still says Long, the
# gross_flat_verified line 15 and the next book line 16. Lines 17-24 open a new
# Short 0.75 entry in the same shape.
POSITION_FIXTURE="$REPO_ROOT/tests/fixtures/tnauqquant/position-flat.raw.log"
(cd "$REPO_ROOT" && shasum -a 256 -c tests/fixtures/tnauqquant/position-flat.raw.log.sha256 >/dev/null) || {
  printf 'FAIL: position-flat fixture does not match its checksum\n' >&2
  exit 1
}
cp "$POPDEX_LOG_PATH" "$TEST_ROOT/popdex.original.log"

replay_position_fixture() {
  head -n "$1" "$POSITION_FIXTURE" >"$POPDEX_LOG_PATH"
  run_probe
}

assert_position_series() {
  local expected="$1"
  local actual
  # No series at all is a failure to report, not an rg error that stops the suite.
  actual="$({ rg -o '^tnauqquant_current_position_btc\{.*exchange="[^"]*",side="[^"]*"\} \S+$' "$METRICS_PATH" || true; } |
    sed -E 's/^.*exchange="([^"]*)",side="([^"]*)"\} /\1 \2 /' | tr '\n' ';')"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: position series expected=%s actual=%s\n' "$expected" "$actual" >&2
    sed -n '1,240p' "$METRICS_PATH" >&2
    exit 1
  fi
}

replay_position_fixture 14
assert_position_series 'popdex long 1.50000000;'
assert_metric tnauqquant_current_net_position_btc 1.5

replay_position_fixture 15
assert_metric tnauqquant_current_position_valid 1
assert_position_series 'popdex flat 0;'
assert_metric tnauqquant_current_net_position_btc 0
assert_metric tnauqquant_position_sample_timestamp_seconds 1795063612 'source="net"'

replay_position_fixture 16
assert_position_series 'popdex flat 0.00000000;'
assert_metric tnauqquant_current_net_position_btc 0
assert_metric tnauqquant_position_sample_timestamp_seconds 1795063685 'source="net"'

# The gross-flat line is now older than the newest book line.
replay_position_fixture 24
assert_position_series 'popdex short 0.75000000;'
assert_metric tnauqquant_current_net_position_btc -0.75
assert_metric tnauqquant_position_sample_timestamp_seconds 1795063752 'source="net"'

printf 'case: only a mapped, gross-flat readiness line counts as flat\n'
append_after_close() {
  head -n 14 "$POSITION_FIXTURE" >"$POPDEX_LOG_PATH"
  printf '%s\n' "$@" >>"$POPDEX_LOG_PATH"
  run_probe
}
append_after_close 'time=2026-11-19T04:46:52.883Z level=INFO msg=ui_warmup_async_ready executor=other-main reason=gross_flat_verified:coordinated_carrier_exit'
assert_position_series 'popdex long 1.50000000;'
append_after_close 'time=2026-11-19T04:46:52.883Z level=INFO msg=ui_warmup_async_ready executor=popdex-main reason=warmup_complete'
assert_position_series 'popdex long 1.50000000;'
append_after_close 'time=2026-11-19T04:46:52.883Z level=INFO msg=coordinated_signal_skipped executor=popdex-main reason=gross_flat_verified:coordinated_carrier_exit'
assert_position_series 'popdex long 1.50000000;'

printf 'case: a gross-flat line keeps the existing sample-time rules\n'
# A future sample is refused as for any book line: nothing current is published.
append_after_close 'time=2099-01-01T00:00:00Z level=INFO msg=ui_warmup_async_ready executor=popdex-main reason=gross_flat_verified:coordinated_carrier_exit'
assert_metric tnauqquant_current_position_valid 0
assert_metric_missing tnauqquant_current_position_btc
assert_metric_missing tnauqquant_current_net_position_btc
# An absent time still publishes the value, without a sample timestamp.
append_after_close 'level=INFO msg=ui_warmup_async_ready executor=popdex-main reason=gross_flat_verified:coordinated_carrier_exit'
assert_position_series 'popdex flat 0;'
assert_metric tnauqquant_current_net_position_btc 0
assert_metric_missing tnauqquant_position_sample_timestamp_seconds
# An unparsable time is handled like an absent one.
append_after_close 'time=not-a-time level=INFO msg=ui_warmup_async_ready executor=popdex-main reason=gross_flat_verified:coordinated_carrier_exit'
assert_position_series 'popdex flat 0;'
assert_metric tnauqquant_current_net_position_btc 0
assert_metric_missing tnauqquant_position_sample_timestamp_seconds

printf 'case: a gross-flat line clears both venues of a two-exchange lane\n'
# A hedged book reads net Flat with both legs open; only gross flat clears the legs.
export TQ_EXECUTOR_MAP=toobit-main=toobit,mexc-ui=mexc
cat >"$POPDEX_LOG_PATH" <<'EOF'
time=2026-11-19T04:30:00.100Z level=INFO msg=trade_status state=settled executor=toobit-main initiator_venue=toobit-main initiator_side=Short initiator_qty_btc=0.103 carrier_venue=mexc-ui carrier_side=Long carrier_qty_btc=0.103 net_side=Flat net_qty_btc=0.00000000 portfolio_projection=coordinator_book
time=2026-11-19T04:31:00.200Z level=INFO msg=coordinated_attempt_terminal attempt_id=31 client_action_id=<redacted> venue=mexc-ui action_kind=close_position requested_btc=0.103 disposition=filled
EOF
run_probe
assert_position_series 'toobit short 0.103;mexc long 0.103;'
assert_metric tnauqquant_current_net_position_btc 0
printf '%s\n' 'time=2026-11-19T04:31:07.300Z level=INFO msg=ui_warmup_async_ready executor=mexc-ui reason=gross_flat_verified:coordinated_carrier_exit' \
  >>"$POPDEX_LOG_PATH"
run_probe
assert_position_series 'toobit flat 0;mexc flat 0;'
assert_metric tnauqquant_current_net_position_btc 0
assert_metric tnauqquant_position_sample_timestamp_seconds 1795062667 'source="net"'
assert_metric tnauqquant_position_sample_timestamp_seconds 1795062667 'source="venue"'

printf 'case: a net-only book line keeps a two-exchange lane gross flat\n'
# waiting_entry book lines carry net but no legs: they must not bring back the
# closed legs, and the venue time stays at the gross-flat line.
printf '%s\n' 'time=2026-11-19T04:32:00.000Z level=INFO msg=coordinated_signal_skipped reason=entry_spread_too_wide executor=toobit-main strategy_phase=waiting_entry net_side=Flat net_qty_btc=0.00000000 portfolio_projection=coordinator_book' \
  >>"$POPDEX_LOG_PATH"
run_probe
assert_metric tnauqquant_current_position_valid 1
assert_position_series 'toobit flat 0;mexc flat 0;'
assert_metric tnauqquant_current_net_position_btc 0
assert_metric tnauqquant_position_sample_timestamp_seconds 1795062667 'source="venue"'
assert_metric tnauqquant_position_sample_timestamp_seconds 1795062720 'source="net"'
# A new two-leg book line still replaces the gross-flat legs.
printf '%s\n' 'time=2026-11-19T04:33:00.000Z level=INFO msg=trade_status state=settled executor=toobit-main initiator_venue=toobit-main initiator_side=Long initiator_qty_btc=0.2 carrier_venue=mexc-ui carrier_side=Short carrier_qty_btc=0.2 net_side=Flat net_qty_btc=0.00000000 portfolio_projection=coordinator_book' \
  >>"$POPDEX_LOG_PATH"
run_probe
assert_position_series 'toobit long 0.2;mexc short 0.2;'
assert_metric tnauqquant_current_net_position_btc 0
assert_metric tnauqquant_position_sample_timestamp_seconds 1795062780 'source="venue"'

printf 'case: a two-exchange gross-flat line keeps the existing sample-time rules\n'
DUAL_OPEN_LINE='time=2026-11-19T04:30:00.100Z level=INFO msg=trade_status state=settled executor=toobit-main initiator_venue=toobit-main initiator_side=Short initiator_qty_btc=0.103 carrier_venue=mexc-ui carrier_side=Long carrier_qty_btc=0.103 net_side=Flat net_qty_btc=0.00000000 portfolio_projection=coordinator_book'
DUAL_FLAT_TAIL='level=INFO msg=ui_warmup_async_ready executor=mexc-ui reason=gross_flat_verified:coordinated_carrier_exit'
# A future gross-flat line is refused, and the older legs are not published.
printf '%s\n' "$DUAL_OPEN_LINE" "time=2099-01-01T00:00:00Z $DUAL_FLAT_TAIL" >"$POPDEX_LOG_PATH"
run_probe
assert_metric tnauqquant_current_position_valid 0
assert_metric_missing tnauqquant_current_position_btc
assert_metric_missing tnauqquant_current_net_position_btc
# An unparsable time still publishes flat, without a sample timestamp.
printf '%s\n' "$DUAL_OPEN_LINE" "time=not-a-time $DUAL_FLAT_TAIL" >"$POPDEX_LOG_PATH"
run_probe
assert_metric tnauqquant_current_position_valid 1
assert_position_series 'toobit flat 0;mexc flat 0;'
assert_metric tnauqquant_current_net_position_btc 0
assert_metric_missing tnauqquant_position_sample_timestamp_seconds

printf 'case: a gross-flat line before any two-leg line keeps two-exchange series\n'
printf '%s\n' "time=2026-11-19T04:31:07.300Z $DUAL_FLAT_TAIL" \
  'time=2026-11-19T04:32:00.000Z level=INFO msg=coordinated_signal_skipped executor=toobit-main strategy_phase=waiting_entry net_side=Flat net_qty_btc=0.00000000 portfolio_projection=coordinator_book' \
  >"$POPDEX_LOG_PATH"
run_probe
assert_metric tnauqquant_current_position_valid 1
assert_position_series 'toobit flat 0;mexc flat 0;'
assert_metric tnauqquant_current_net_position_btc 0
assert_metric tnauqquant_position_sample_timestamp_seconds 1795062667 'source="venue"'
assert_metric tnauqquant_position_sample_timestamp_seconds 1795062720 'source="net"'
export TQ_EXECUTOR_MAP=popdex-main=popdex
cp "$TEST_ROOT/popdex.original.log" "$POPDEX_LOG_PATH"
run_probe

printf 'case: a bound PopDEX max-cycles marker makes the run not expected\n'
jq -n \
  --arg run_id "$POPDEX_RUN_ID" \
  --arg strategy "$TQ_STRATEGY" \
  --arg instance_id "$TQ_INSTANCE_ID" \
  --arg config_sha256 "$popdex_config_sha" \
  '{
    schema_version: 1,
    run_id: $run_id,
    strategy: $strategy,
    instance_id: $instance_id,
    pid: 999999,
    config_sha256: $config_sha256,
    reason: "max_cycles_complete",
    phase: "max_cycles_complete",
    completed_at: "2026-11-13T22:56:00Z",
    long_btc: 0,
    short_btc: 0,
    net_btc: 0,
    dust_tolerance_btc: 0
  }' >"$POPDEX_MARKER_PATH"
run_probe
assert_metric tnauqquant_marker_binding_ok 1
assert_metric tnauqquant_done_marker 1 'reason="max_cycles_complete"'
assert_metric tnauqquant_run_expected 0
if [[ ! -f "$ROBINHOOD_METRICS_PATH" ]] ||
   ! rg -q 'strategy="lighter-robinhood-btc-canary"' "$ROBINHOOD_METRICS_PATH"; then
  printf 'FAIL: the PopDEX probe changed the Robinhood output\n' >&2
  exit 1
fi
METRICS_PATH="$ROBINHOOD_METRICS_PATH"
unset TQ_TEXTFILE_NAME
export TQ_RAW_LOG_GLOB="$FAKE_REPO/logs/live-runs/*.raw.log"

printf 'case: two strategy probes keep distinct atomic outputs\n'
MAINNET_CONFIG_PATH="$FAKE_REPO/config/lighter_mainnet_btc_config.yaml"
MAINNET_METRICS_PATH="$TEXTFILE_DIR/tnauqquant-lighter-mainnet-btc-canary.prom"
cat >"$MAINNET_CONFIG_PATH" <<'EOF'
instance_id: "lighter-mainnet-btc-canary"
max_cycles: 100
EOF
export TQ_STRATEGY=lighter-mainnet-btc-canary
export TQ_INSTANCE_ID=lighter-mainnet-btc-canary
export TQ_CONFIG_PATH="$MAINNET_CONFIG_PATH"
export TQ_RUN_MANIFEST="$FAKE_REPO/run-state/lighter-mainnet-btc-canary/current.json"
export TQ_DONE_MARKER="$FAKE_REPO/run-state/lighter-mainnet-btc-canary/current.done.json"
export TQ_POC_RUN_EXPECTED=0
export TQ_EXECUTOR_MAP=lighter-mainnet-main=lighter
export TQ_TEXTFILE_NAME=tnauqquant-lighter-mainnet-btc-canary.prom
"$PROBE"
[[ -f "$METRICS_PATH" && -f "$MAINNET_METRICS_PATH" ]] || {
  printf 'FAIL: concurrent strategy output files were not preserved\n' >&2
  exit 1
}
rg -q 'strategy="lighter-robinhood-btc-canary"' "$METRICS_PATH" || {
  printf 'FAIL: Robinhood output lost its strategy identity\n' >&2
  exit 1
}
rg -q 'strategy="lighter-mainnet-btc-canary"' "$MAINNET_METRICS_PATH" || {
  printf 'FAIL: Mainnet output lost its strategy identity\n' >&2
  exit 1
}

printf 'case: unsafe textfile basename is rejected\n'
export TQ_TEXTFILE_NAME=../outside.prom
if "$PROBE" >/dev/null 2>&1; then
  printf 'FAIL: unsafe TQ_TEXTFILE_NAME was accepted\n' >&2
  exit 1
fi
[[ ! -e "$TEST_ROOT/outside.prom" ]] || {
  printf 'FAIL: unsafe textfile basename escaped the output directory\n' >&2
  exit 1
}

if find "$TEXTFILE_DIR" -maxdepth 1 -name '.tnauqquant*.prom.*' -print | grep -q .; then
  printf 'FAIL: atomic writer left temporary files\n' >&2
  exit 1
fi

printf 'case: multi-account same-exchange PopDEX rotation contract (popdex-multi-accounts)\n'
MULTI_CONFIG_PATH="$FAKE_REPO/config/popdex_multi_accounts_config.yaml"
MULTI_RUN_ID=20261126_020000_popdex_multi_accounts_config
MULTI_LOG_PATH="$FAKE_REPO/logs/live-runs/$MULTI_RUN_ID.raw.log"
MULTI_MANIFEST_PATH="$FAKE_REPO/run-state/popdex-multi-accounts/current.json"
MULTI_MARKER_PATH="$FAKE_REPO/run-state/popdex-multi-accounts/current.done.json"
MULTI_METRICS_PATH="$TEXTFILE_DIR/tnauqquant-popdex-multi-accounts.prom"
mkdir -p "$(dirname "$MULTI_MANIFEST_PATH")"
cat >"$MULTI_CONFIG_PATH" <<'EOF'
instance_id: "popdex-multi-accounts"
routing:
  mode: "random"
  accounts:
    - name: "popdex-main"
    - name: "popdex-rot2"
EOF
multi_config_sha="$(shasum -a 256 "$MULTI_CONFIG_PATH" | awk '{print $1}')"
jq -n \
  --arg run_id "$MULTI_RUN_ID" \
  --arg strategy "popdex-multi-accounts" \
  --arg instance_id "popdex-multi-accounts" \
  --arg config_sha256 "$multi_config_sha" \
  --arg executable "$FAKE_REPO/quant" \
  --arg config_path "$MULTI_CONFIG_PATH" \
  --arg log_path "$MULTI_LOG_PATH" \
  --arg done_marker_path "$MULTI_MARKER_PATH" \
  '{
    schema_version: 1,
    run_id: $run_id,
    strategy: $strategy,
    instance_id: $instance_id,
    pid: 999999,
    config_sha256: $config_sha256,
    process_started_at: "2026-11-26T02:00:00Z",
    executable: $executable,
    config_path: $config_path,
    log_path: $log_path,
    done_marker_path: $done_marker_path,
    state: "running"
  }' >"$MULTI_MANIFEST_PATH"

export TQ_STRATEGY=popdex-multi-accounts
export TQ_INSTANCE_ID=popdex-multi-accounts
export TQ_CONFIG_PATH="$MULTI_CONFIG_PATH"
export TQ_RAW_LOG_GLOB="$FAKE_REPO/logs/live-runs/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]_popdex_multi_accounts_config.raw.log"
export TQ_RUN_MANIFEST="$MULTI_MANIFEST_PATH"
export TQ_DONE_MARKER="$MULTI_MARKER_PATH"
export TQ_POC_RUN_EXPECTED=1
export TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex
export TQ_TEXTFILE_NAME=tnauqquant-popdex-multi-accounts.prom
export TQ_SIDECAR_REQUIRED=0
export TQ_TEXTFILE_MODE=640
METRICS_PATH="$MULTI_METRICS_PATH"

# 1) Startup initial_equity_recorded before first pnl_status (+ non-allowlisted executor dropped).
cat >"$MULTI_LOG_PATH" <<EOF
time=${today_local}T09:00:00.100${FIXTURE_OFFSET} level=INFO msg=initial_equity_recorded equity_usdt=10000.00 equity_usdt_by_executor=popdex-main:5000.00,popdex-rot2:5000.00,rogue-acct:9999.00
time=${today_local}T09:01:00.200${FIXTURE_OFFSET} level=INFO msg=trade_status state=open executor=popdex-rot2 volume_usd=14.10
time=${today_local}T09:01:00.300${FIXTURE_OFFSET} level=INFO msg=trade_status state=open executor=rogue-acct volume_usd=999.99
time=${today_local}T09:01:01.000${FIXTURE_OFFSET} level=INFO msg=trade_status state=settled phase=entry executor=popdex-rot2 initiator_venue=popdex-rot2 initiator_side=Short initiator_qty_btc=0.00020000 net_side=Short net_qty_btc=0.00020000 portfolio_projection=coordinator_book
EOF
run_probe
assert_metric tnauqquant_current_pnl_valid 0
assert_metric tnauqquant_current_equity_usdt 10000.00
assert_metric tnauqquant_current_executor_equity_usdt 5000.00 'exchange="popdex",executor="popdex-main"'
assert_metric tnauqquant_current_executor_equity_usdt 5000.00 'exchange="popdex",executor="popdex-rot2"'
assert_metric tnauqquant_current_run_exchange_volume_usd 14.1 'exchange="popdex"'
assert_metric tnauqquant_current_run_executor_volume_usd 0 'exchange="popdex",executor="popdex-main"'
assert_metric tnauqquant_current_run_executor_volume_usd 14.1 'exchange="popdex",executor="popdex-rot2"'
assert_metric_missing tnauqquant_current_executor_real_pnl_usdt
assert_metric_missing tnauqquant_current_executor_cycles_completed
# Non-hedge open position on single-exchange multi-account lane publishes exchange="popdex" position.
assert_metric tnauqquant_current_position_valid 1
assert_metric tnauqquant_current_position_btc 0.00020000 'base_asset="BTC",exchange="popdex",side="short"'
assert_metric tnauqquant_current_net_position_btc -0.0002 'base_asset="BTC"}'
if rg -q 'rogue-acct' "$METRICS_PATH"; then
  printf 'FAIL: non-allowlisted executor leaked into metrics at startup\n' >&2
  exit 1
fi

# 2) Confirmed coordinator_book exit clears position; delayed warmup from another account
#    cannot clear a confirmed open position (C2).
cat >>"$MULTI_LOG_PATH" <<EOF
time=${today_local}T09:02:00.000${FIXTURE_OFFSET} level=INFO msg=trade_status state=settled phase=carrier_exit executor=popdex-rot2 net_side=Flat net_qty_btc=0.00000000 portfolio_projection=coordinator_book
EOF
run_probe
assert_metric tnauqquant_current_position_btc 0.00000000 'base_asset="BTC",exchange="popdex",side="flat"'
assert_metric tnauqquant_current_net_position_btc 0 'base_asset="BTC"}'

cat >>"$MULTI_LOG_PATH" <<EOF
time=${today_local}T09:02:05.000${FIXTURE_OFFSET} level=INFO msg=pnl_status equity_start=10000 equity_now=10002.125 rebate_usdt=0.25 cash_pnl_usdt=1.875 real_pnl_usdt=2.125 risk_pnl_usdt=2.125 cycles_completed=1 risk_stopped=false samples=2 stable=true cycle_completed=true summary="PNL equity_start=10000.00 equity_now=10002.13 real_pnl=+2.1250 cycles=1 risk_stopped=false samples=2 stable=true cycle_completed=true" equity_usdt_by_executor=popdex-main:5000.00,popdex-rot2:5002.13,rogue-acct:123.45 volume_usd_by_executor=popdex-rot2:28.20,rogue-acct:777.00 cycle_real_pnl_usdt=2.125 cycle_executor=popdex-rot2 cycle=1 session_cycle=1 cycle_id=m.1
time=${today_local}T09:02:05.000${FIXTURE_OFFSET} level=INFO msg=pnl_status equity_start=10000 equity_now=10002.125 rebate_usdt=0.25 cash_pnl_usdt=1.875 real_pnl_usdt=2.125 risk_pnl_usdt=2.125 cycles_completed=1 risk_stopped=false samples=2 stable=true cycle_completed=true equity_usdt_by_executor=popdex-main:5000.00,popdex-rot2:5002.13 volume_usd_by_executor=popdex-rot2:28.20 cycle_real_pnl_usdt=2.125 cycle_executor=popdex-rot2 cycle=1 session_cycle=1 cycle_id=m.1
time=${today_local}T09:03:00.000${FIXTURE_OFFSET} level=INFO msg=trade_status state=settled phase=entry executor=popdex-main initiator_venue=popdex-main initiator_side=Long initiator_qty_btc=0.00040000 net_side=Long net_qty_btc=0.00040000 portfolio_projection=coordinator_book
time=${today_local}T09:03:05.000${FIXTURE_OFFSET} level=INFO msg=ui_warmup_async_ready executor=popdex-rot2 reason=gross_flat_verified:coordinated_carrier_exit
time=${today_local}T09:04:00.000${FIXTURE_OFFSET} level=INFO msg=pnl_status equity_start=10000 equity_now=10001.500 rebate_usdt=0.40 cash_pnl_usdt=1.100 real_pnl_usdt=1.500 risk_pnl_usdt=1.500 cycles_completed=2 risk_stopped=false samples=2 stable=true cycle_completed=true equity_usdt_by_executor=popdex-main:4999.38,popdex-rot2:5002.13 volume_usd_by_executor=popdex-main:55.50,popdex-rot2:28.20,rogue-acct:888.00 cycle_real_pnl_usdt=-0.625 cycle_executor=popdex-main cycle=2 session_cycle=2 cycle_id=m.2
time=${today_local}T09:04:30.000${FIXTURE_OFFSET} level=INFO msg=pnl_status equity_start=10000 equity_now=10001.500 rebate_usdt=0.40 cash_pnl_usdt=1.100 real_pnl_usdt=1.500 risk_pnl_usdt=1.500 cycles_completed=3 risk_stopped=false samples=2 stable=true cycle_completed=true equity_usdt_by_executor=popdex-main:4999.38,popdex-rot2:5002.13 volume_usd_by_executor=popdex-main:55.50,popdex-rot2:28.20 cycle_real_pnl_usdt=99.0 cycle_executor=rogue-acct cycle=3 session_cycle=3 cycle_id=m.3
EOF
run_probe
assert_metric tnauqquant_current_pnl_valid 1
# Merged total equity preserves exact equity_now (10001.500), not rounded breakdown sum.
assert_metric tnauqquant_current_equity_usdt 10001.500
assert_metric tnauqquant_current_real_pnl_usdt 1.500
assert_metric tnauqquant_current_cycles_completed 3
assert_metric tnauqquant_completed_cycles_today 3
# Merged exchange volume equals sum of mapped executors (55.50 + 28.20 = 83.7); rogue-acct excluded.
assert_metric tnauqquant_current_run_exchange_volume_usd 83.7 'exchange="popdex"'
assert_metric tnauqquant_current_run_executor_volume_usd 55.5 'exchange="popdex",executor="popdex-main"'
assert_metric tnauqquant_current_run_executor_volume_usd 28.2 'exchange="popdex",executor="popdex-rot2"'
# Per-executor equity, deduplicated cycle PnL and cycles (cycle 1 duplicate counted once; cycle 3 rogue-acct dropped).
assert_metric tnauqquant_current_executor_equity_usdt 4999.38 'exchange="popdex",executor="popdex-main"'
assert_metric tnauqquant_current_executor_equity_usdt 5002.13 'exchange="popdex",executor="popdex-rot2"'
assert_metric tnauqquant_current_executor_real_pnl_usdt -0.625 'exchange="popdex",executor="popdex-main"'
assert_metric tnauqquant_current_executor_real_pnl_usdt 2.125 'exchange="popdex",executor="popdex-rot2"'
assert_metric tnauqquant_current_executor_cycles_completed 1 'exchange="popdex",executor="popdex-main"'
assert_metric tnauqquant_current_executor_cycles_completed 1 'exchange="popdex",executor="popdex-rot2"'
# New open position on popdex-main survived delayed gross_flat_verified warmup from popdex-rot2.
assert_metric tnauqquant_current_position_btc 0.00040000 'base_asset="BTC",exchange="popdex",side="long"'
assert_metric tnauqquant_current_net_position_btc 0.0004 'base_asset="BTC"}'
assert_position_help_pinned
multi_exec_labels="$(rg -o 'executor="[^"]*"' "$METRICS_PATH" | sort -u | tr '\n' ' ')"
[[ "$multi_exec_labels" == 'executor="popdex-main" executor="popdex-rot2" ' ]] || {
  printf 'FAIL: multi-account executor labels must strictly match TQ_EXECUTOR_MAP allowlist, got: %s\n' "$multi_exec_labels" >&2
  exit 1
}
if rg -q 'rogue-acct' "$METRICS_PATH"; then
  printf 'FAIL: non-allowlisted executor appeared in metrics output\n' >&2
  exit 1
fi

# 2b) Dedicated C2 replay: main finishes cycle -> rot2 opens confirmed Long 0.02 BTC ->
#     main's delayed gross_flat_verified warmup finishes after the new open.
printf 'case: multi-account delayed warmup from prior executor never clears open position (C2)\n'
cat >"$MULTI_LOG_PATH" <<EOF
time=${today_local}T09:10:00.000${FIXTURE_OFFSET} level=INFO msg=trade_status state=settled phase=carrier_exit executor=popdex-main net_side=Flat net_qty_btc=0.00000000 portfolio_projection=coordinator_book
time=${today_local}T09:10:05.000${FIXTURE_OFFSET} level=INFO msg=trade_status state=settled phase=entry executor=popdex-rot2 initiator_venue=popdex-rot2 initiator_side=Long initiator_qty_btc=0.02000000 net_side=Long net_qty_btc=0.02000000 portfolio_projection=coordinator_book
time=${today_local}T09:10:06.000${FIXTURE_OFFSET} level=INFO msg=ui_warmup_async_ready executor=popdex-main reason=gross_flat_verified:coordinated_carrier_exit
EOF
run_probe
assert_metric tnauqquant_current_position_valid 1
assert_metric tnauqquant_current_position_btc 0.02000000 'base_asset="BTC",exchange="popdex",side="long"'
assert_metric tnauqquant_current_net_position_btc 0.02 'base_asset="BTC"}'

# Restore full multi-account log before fail-closed checks.
cat >"$MULTI_LOG_PATH" <<EOF
time=${today_local}T09:00:00.100${FIXTURE_OFFSET} level=INFO msg=initial_equity_recorded equity_usdt=10000.00 equity_usdt_by_executor=popdex-main:5000.00,popdex-rot2:5000.00
time=${today_local}T09:04:00.000${FIXTURE_OFFSET} level=INFO msg=pnl_status equity_start=10000 equity_now=10001.500 rebate_usdt=0.40 cash_pnl_usdt=1.100 real_pnl_usdt=1.500 risk_pnl_usdt=1.500 cycles_completed=2 risk_stopped=false samples=2 stable=true cycle_completed=true equity_usdt_by_executor=popdex-main:4999.38,popdex-rot2:5002.13 volume_usd_by_executor=popdex-main:55.50,popdex-rot2:28.20 cycle_real_pnl_usdt=-0.625 cycle_executor=popdex-main cycle=2 session_cycle=2 cycle_id=m.2
EOF

# 3) Fail-closed: missing equity_usdt_by_executor or future pnl_status never falls back to earlier equity.
cp "$MULTI_LOG_PATH" "$TEST_ROOT/multi.original.log"
printf 'time=%sT09:05:00.000%s level=INFO msg=pnl_status stable=true equity_now=10001.500 real_pnl_usdt=1.500 cycles_completed=3 equity_usdt_by_executor=popdex-main:4999.38\n' \
  "$today_local" "$FIXTURE_OFFSET" >>"$MULTI_LOG_PATH"
run_probe
assert_metric tnauqquant_current_equity_usdt 10001.500
assert_metric_missing tnauqquant_current_executor_equity_usdt

cp "$TEST_ROOT/multi.original.log" "$MULTI_LOG_PATH"
printf 'time=%sT09:05:00.000%s level=INFO msg=pnl_status stable=true equity_now=NaN real_pnl_usdt=1.500 cycles_completed=3 equity_usdt_by_executor=popdex-main:4999.38,popdex-rot2:5002.13\n' \
  "$today_local" "$FIXTURE_OFFSET" >>"$MULTI_LOG_PATH"
run_probe
assert_metric_missing tnauqquant_current_equity_usdt
assert_metric_missing tnauqquant_current_executor_equity_usdt

cp "$TEST_ROOT/multi.original.log" "$MULTI_LOG_PATH"
printf 'time=2099-01-01T00:00:00Z level=INFO msg=pnl_status stable=true equity_now=10001.500 real_pnl_usdt=1.500 cycles_completed=3 equity_usdt_by_executor=popdex-main:4999.38,popdex-rot2:5002.13\n' \
  >>"$MULTI_LOG_PATH"
run_probe
assert_metric tnauqquant_current_pnl_valid 0
assert_metric_missing tnauqquant_current_equity_usdt
assert_metric_missing tnauqquant_current_executor_equity_usdt
assert_metric_missing tnauqquant_current_executor_real_pnl_usdt
assert_metric_missing tnauqquant_current_executor_cycles_completed

# 4) Future initial_equity_recorded before any pnl_status is rejected fail-closed.
printf 'time=2099-01-01T00:00:00Z level=INFO msg=initial_equity_recorded equity_usdt=10000.00 equity_usdt_by_executor=popdex-main:5000.00,popdex-rot2:5000.00\n' \
  >"$MULTI_LOG_PATH"
run_probe
assert_metric_missing tnauqquant_current_equity_usdt
assert_metric_missing tnauqquant_current_executor_equity_usdt

# 5) C3: unmapped rogue executor in warmup or coordinator_book must never autovivify
#    the awk allowlist (neither hiding valid equities on rogue:bad nor fabricating 0 PnL/cycles).
printf 'case: rogue executor warmup/book never poisons allowlist on bad equity or rogue-only cycle (C3)\n'
cat >"$MULTI_LOG_PATH" <<EOF
time=${today_local}T09:20:00.000${FIXTURE_OFFSET} level=INFO msg=ui_warmup_async_ready executor=rogue-acct reason=gross_flat_verified:coordinated_carrier_exit
time=${today_local}T09:20:01.000${FIXTURE_OFFSET} level=INFO msg=trade_status state=settled phase=entry executor=rogue-acct initiator_venue=rogue-acct initiator_side=Long initiator_qty_btc=0.01000000 carrier_venue=popdex-main carrier_side=Flat carrier_qty_btc=0.00000000 net_side=Long net_qty_btc=0.01000000 portfolio_projection=coordinator_book
time=${today_local}T09:20:02.000${FIXTURE_OFFSET} level=INFO msg=pnl_status stable=true cycle_completed=false equity_now=10000.00 real_pnl_usdt=0 cycles_completed=0 equity_usdt_by_executor=popdex-main:5000.00,popdex-rot2:5000.00,rogue-acct:bad
EOF
run_probe
assert_metric tnauqquant_current_executor_equity_usdt 5000.00 'exchange="popdex",executor="popdex-main"'
assert_metric tnauqquant_current_executor_equity_usdt 5000.00 'exchange="popdex",executor="popdex-rot2"'
if rg -q 'rogue-acct' "$METRICS_PATH"; then
  printf 'FAIL: rogue executor leaked into equity metrics after warmup/book\n' >&2
  exit 1
fi

cat >"$MULTI_LOG_PATH" <<EOF
time=${today_local}T09:21:00.000${FIXTURE_OFFSET} level=INFO msg=ui_warmup_async_ready executor=rogue-acct reason=gross_flat_verified:coordinated_carrier_exit
time=${today_local}T09:21:01.000${FIXTURE_OFFSET} level=INFO msg=trade_status state=settled phase=entry executor=rogue-acct initiator_venue=rogue-acct initiator_side=Long initiator_qty_btc=0.01000000 carrier_venue=popdex-main carrier_side=Flat carrier_qty_btc=0.00000000 net_side=Long net_qty_btc=0.01000000 portfolio_projection=coordinator_book
time=${today_local}T09:21:02.000${FIXTURE_OFFSET} level=INFO msg=pnl_status stable=true cycle_completed=true cycle=1 session_cycle=1 cycle_id=r.1 cycle_executor=rogue-acct cycle_real_pnl_usdt=12.50 equity_now=10012.50 real_pnl_usdt=12.50 cycles_completed=1 equity_usdt_by_executor=popdex-main:5000.00,popdex-rot2:5012.50
EOF
run_probe
assert_metric tnauqquant_current_executor_equity_usdt 5000.00 'exchange="popdex",executor="popdex-main"'
assert_metric tnauqquant_current_executor_equity_usdt 5012.50 'exchange="popdex",executor="popdex-rot2"'
assert_metric_missing tnauqquant_current_executor_real_pnl_usdt
assert_metric_missing tnauqquant_current_executor_cycles_completed
if rg -q 'rogue-acct' "$METRICS_PATH"; then
  printf 'FAIL: rogue executor leaked into cycle metrics after warmup/book\n' >&2
  exit 1
fi

printf 'PASS: trading probe contract\n'
