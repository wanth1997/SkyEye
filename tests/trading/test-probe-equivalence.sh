#!/usr/bin/env bash
set -euo pipefail

# Byte-for-byte equivalence tests comparing the frozen pre-optimization baseline
# probe against the current single-pass probe across growing logs, dual/single
# exchange lanes, partial last lines, run_id rotation, midnight/DST rollovers,
# future-time thawing, key precedence, pre-filter false-positive noise,
# single-read atomicity (C1), failure propagation with preserved .prom (C2),
# and large line numbers / >1 MiB logs without %g formatting (C3).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NEW_PROBE="$REPO_ROOT/agents/alloy/trading/probe.sh"
OLD_PROBE="$REPO_ROOT/tests/fixtures/tnauqquant/probe-baseline-reference.sh"
REAL_DATE="$(command -v date)"
REAL_GREP="$(command -v grep)"
REAL_AWK="$(command -v awk)"

for required_file in "$NEW_PROBE" "$OLD_PROBE"; do
  [[ -x "$required_file" ]] || {
    printf 'FAIL: probe is missing or not executable: %s\n' "$required_file" >&2
    exit 1
  }
done

for tool in awk cmp diff jq shasum touch; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'FAIL: %s is required\n' "$tool" >&2
    exit 1
  }
done

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-probe-equiv.XXXXXX")"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

SHIM="$TEST_ROOT/shim"
mkdir -p "$SHIM"
cat >"$SHIM/date" <<SHIM_EOF
#!/usr/bin/env bash
if [[ -n "\${FAKE_NOW:-}" ]]; then
  case "\$*" in
    +%s) printf '%s\n' "\$FAKE_NOW"; exit 0 ;;
    +%F) "$REAL_DATE" -r "\$FAKE_NOW" +%F 2>/dev/null || "$REAL_DATE" -d "@\$FAKE_NOW" +%F; exit ;;
  esac
fi
exec "$REAL_DATE" "\$@"
SHIM_EOF
chmod 755 "$SHIM/date"

epoch_of() {
  TZ=UTC "$REAL_DATE" -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null ||
    TZ=UTC "$REAL_DATE" -d "$1" +%s
}

touch_epoch() {
  local path="$1"
  local epoch="$2"
  local stamp
  stamp="$(TZ=UTC "$REAL_DATE" -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null ||
    TZ=UTC "$REAL_DATE" -d "@$epoch" +%Y%m%d%H%M.%S)"
  TZ=UTC touch -t "$stamp" "$path"
}

CASE_INDEX=0
PASS_COUNT=0

new_fixture() {
  local strategy="$1"
  local config_stem="$2"
  local executor_map="$3"
  local timezone="${4:-Asia/Taipei}"
  local base_asset="${5:-}"
  CASE_INDEX=$((CASE_INDEX + 1))
  CASE_DIR="$TEST_ROOT/case-$CASE_INDEX"
  REPO="$CASE_DIR/tnauqquant"
  TEXT_OLD="$CASE_DIR/text-old"
  TEXT_NEW="$CASE_DIR/text-new"
  mkdir -p "$REPO/config" "$REPO/logs/live-runs" "$REPO/run-state/$strategy" "$TEXT_OLD" "$TEXT_NEW"
  CONFIG_PATH="$REPO/config/$config_stem.yaml"
  printf 'instance_id: "%s"\n' "$strategy" >"$CONFIG_PATH"
  CONFIG_SHA="$(shasum -a 256 "$CONFIG_PATH" | awk '{print $1}')"
  QUANT="$REPO/quant"
  printf '#!/bin/sh\nexit 0\n' >"$QUANT"
  chmod 755 "$QUANT"
  MANIFEST_PATH="$REPO/run-state/$strategy/current.json"
  MARKER_PATH="$REPO/run-state/$strategy/current.done.json"

  export TQ_PRODUCT=tnauqquant
  export TQ_ENVIRONMENT=production
  export TQ_SERVER_ID=trading01
  export TQ_STRATEGY="$strategy"
  export TQ_INSTANCE_ID="$strategy"
  export TQ_REPO_ROOT="$REPO"
  export TQ_EXECUTABLE="$QUANT"
  export TQ_CONFIG_PATH="$CONFIG_PATH"
  export TQ_RAW_LOG_GLOB="$REPO/logs/live-runs/*$config_stem.raw.log"
  export TQ_RUN_MANIFEST="$MANIFEST_PATH"
  export TQ_DONE_MARKER="$MARKER_PATH"
  export TQ_POC_RUN_EXPECTED=1
  export TQ_REQUIRE_RUNTIME_CONTRACT=1
  export TQ_TIMEZONE="$timezone"
  export TQ_TEXTFILE_NAME="tnauqquant-$strategy.prom"
  export TQ_EXECUTOR_MAP="$executor_map"
  export TQ_SIDECAR_REQUIRED=0
  export TQ_TEXTFILE_MODE=640
  export TQ_SIDECAR_SESSION=fixture-missing
  export TQ_SIDECAR_IDENTITY_FILE="$CASE_DIR/missing-sidecar"
  export TQ_SIDECAR_HEALTH_URL=http://127.0.0.1:9/health
  unset TQ_STRATEGY_DISABLED
  if [[ -n "$base_asset" ]]; then
    export TQ_BASE_ASSET="$base_asset"
  else
    unset TQ_BASE_ASSET
  fi
}

write_manifest() {
  local run_id="$1"
  local log_path="$2"
  local started_at="${3:-2025-07-17T00:00:00Z}"
  jq -n \
    --arg run_id "$run_id" \
    --arg strategy "$TQ_STRATEGY" \
    --arg instance_id "$TQ_INSTANCE_ID" \
    --arg config_sha256 "$CONFIG_SHA" \
    --arg process_started_at "$started_at" \
    --arg executable "$QUANT" \
    --arg config_path "$CONFIG_PATH" \
    --arg log_path "$log_path" \
    --arg done_marker_path "$MARKER_PATH" \
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
    }' >"$MANIFEST_PATH"
}

assert_identical() {
  local description="$1"
  local pinned_now="$2"
  local old_metrics="$TEXT_OLD/$TQ_TEXTFILE_NAME"
  local new_metrics="$TEXT_NEW/$TQ_TEXTFILE_NAME"
  rm -f "$old_metrics" "$new_metrics"

  FAKE_NOW="$pinned_now" TQ_TEXTFILE_DIR="$TEXT_OLD" PATH="$SHIM:$PATH" "$OLD_PROBE"
  FAKE_NOW="$pinned_now" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$SHIM:$PATH" "$NEW_PROBE"

  if ! cmp -s "$old_metrics" "$new_metrics"; then
    printf 'FAIL: %s (.prom output differs from baseline)\n' "$description" >&2
    diff -u "$old_metrics" "$new_metrics" >&2 || true
    exit 1
  fi
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok      %s\n' "$description"
}

NOW_DEFAULT="$(epoch_of 2025-07-17T10:00:00Z)"

printf '# Scenario 1: single-exchange PopDEX ETH growing log + >256 KiB tail fast-path & fallback\n'
new_fixture popdex-02 popdex_02_config 'popdex-02=popdex' Asia/Taipei ETH
RUN1="20250717_000000_popdex_02_config"
LOG1="$REPO/logs/live-runs/$RUN1.raw.log"
: >"$LOG1"
write_manifest "$RUN1" "$LOG1"
assert_identical "scenario 1a: empty manifest log" "$NOW_DEFAULT"

# Line 1 (byte offset 0 -> pos=1) must not collide with VENUE_POSITION_LINE=0.
printf '%s\n' \
  'time=2025-07-17T08:00:00.100Z level=INFO msg=position_update net_side=Long net_qty_btc=1.25000000 portfolio_projection=coordinator_book' \
  >"$LOG1"
assert_identical "scenario 1b: net position on line 1 (byte offset 0)" "$NOW_DEFAULT"

cat >>"$LOG1" <<'EOF'
time=2025-07-17T08:01:00.200Z level=INFO msg=pnl_status equity_start=1000 equity_now=1002.125 rebate_usdt=0.25 cash_pnl_usdt=1.875 real_pnl_usdt=2.125 risk_pnl_usdt=2.0 cycles_completed=1 risk_stopped=false samples=2 stable=true cycle_completed=true summary="PNL equity_start=1000.00 equity_now=1002.13 real_pnl=+2.13 cycles=1 stable=true cycle_completed=true" equity_usdt_by_executor=popdex-02:1002.13 volume_usd_by_executor=popdex-02:15000.5 cycle_real_pnl_usdt=2.125 cycle=1 session_cycle=1 cycle_id=c.1
time=2025-07-17T08:01:05.000Z level=INFO msg=pnl_status stable=false equity_now=999999 real_pnl_usdt=999999 volume_usd_by_executor=popdex-02:999999
time=2025-07-17T08:01:06.000Z level=INFO msg=ui_warmup_async_ready executor=popdex-02 reason=gross_flat_verified:coordinated_carrier_exit
EOF
assert_identical "scenario 1c: growing PopDEX ETH log after gross_flat_verified" "$NOW_DEFAULT"

printf '%s\n' \
  'time=2025-07-17T08:02:00.000Z level=INFO msg=coordinated_signal_skipped executor=popdex-02 strategy_phase=waiting_entry net_side=Flat net_qty_btc=0.00000000 portfolio_projection=coordinator_book' \
  >>"$LOG1"
assert_identical "scenario 1c2: PopDEX ETH waiting_entry book line after gross_flat" "$NOW_DEFAULT"

# Pad beyond the 256 KiB tail window with unrelated lines, then place a book line inside the tail.
awk 'BEGIN {
  line = "time=2025-07-17T08:05:00.000Z level=INFO msg=tactic_taker_ioc_sent order_id=ord999 price=1805.4 qty_contracts=1.5 entry_pricing_mode=touch_spread_gate entry_spread_ticks=2 max_entry_spread_ticks=2"
  for (i = 0; i < 2000; i++) print line
}' >>"$LOG1"
printf '%s\n' \
  'time=2025-07-17T08:10:00.000Z level=INFO msg=position_update net_side=Short net_qty_btc=0.75000000 portfolio_projection=coordinator_book' \
  >>"$LOG1"
assert_identical "scenario 1d: >256 KiB log with coordinator_book inside tail window" "$NOW_DEFAULT"

# Pad >300 KiB of unrelated lines AFTER the last coordinator_book so tail fast-path triggers full fallback.
awk 'BEGIN {
  line = "time=2025-07-17T08:11:00.000Z level=INFO msg=tactic_taker_ioc_sent order_id=ord999 price=1805.4 qty_contracts=1.5 entry_pricing_mode=touch_spread_gate entry_spread_ticks=2 max_entry_spread_ticks=2"
  for (i = 0; i < 2000; i++) print line
}' >>"$LOG1"
assert_identical "scenario 1e: >256 KiB log with no coordinator_book in tail window (fallback)" "$NOW_DEFAULT"

# Add a gross_flat_verified inside the tail window after the unrelated padding.
printf '%s\n' \
  'time=2025-07-17T08:15:00.000Z level=INFO msg=ui_warmup_async_ready executor=popdex-02 reason=gross_flat_verified:coordinated_carrier_exit' \
  >>"$LOG1"
assert_identical "scenario 1f: >256 KiB log with gross_flat_verified after tail_start" "$NOW_DEFAULT"

# Pad >300 KiB after gross_flat_verified so gross_flat_verified is also before tail_start.
awk 'BEGIN {
  line = "time=2025-07-17T08:16:00.000Z level=INFO msg=coordinated_attempt_started attempt_id=19 venue=popdex-02 action_kind=open_position requested_btc=0.5 dispatch_claimed=true"
  for (i = 0; i < 2200; i++) print line
}' >>"$LOG1"
assert_identical "scenario 1g: >256 KiB log with gross_flat_verified before tail_start" "$NOW_DEFAULT"

printf '# Scenario 2: dual-exchange Toobit/MEXC with trade_status fallback volume & leg/net precedence\n'
new_fixture toobit-mexc-btc toobit_mexc_btc_config 'toobit-main=toobit,mexc-ui=mexc' Asia/Taipei
RUN2="20250717_010000_toobit_mexc_btc_config"
LOG2="$REPO/logs/live-runs/$RUN2.raw.log"
write_manifest "$RUN2" "$LOG2"

cat >"$LOG2" <<'EOF'
time=2025-07-17T08:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 equity_now=3000 real_pnl_usdt=5 cash_pnl_usdt=4 rebate_usdt=1 risk_pnl_usdt=4.5 cycles_completed=1 cycle_real_pnl_usdt=5
time=2025-07-17T08:01:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 equity_now=3001 real_pnl_usdt=5.5 cash_pnl_usdt=4.5 rebate_usdt=1 risk_pnl_usdt=5 cycles_completed=1 cycle_real_pnl_usdt=5.5
time=2025-07-17T08:02:00Z level=INFO msg=trade_status state=open executor=toobit-main volume_usd=100.25
time=2025-07-17T08:02:10Z level=INFO msg=trade_status state=closed executor=mexc-ui volume_usd=99.75
time=2025-07-17T08:02:20Z level=INFO msg=trade_status state=closed executor=unknown-venue volume_usd=9000
time=2025-07-17T08:02:30Z level=INFO msg=trade_status state=closed executor=toobit-main volume_usd=-50
time=2025-07-17T08:03:00Z level=INFO msg=trade_status state=settled initiator_venue=toobit-main initiator_side=Short initiator_qty_btc=0.50000000 carrier_venue=mexc-ui carrier_side=Long carrier_qty_btc=0.10000000 net_side=Flat net_qty_btc=0.00000000 portfolio_projection=coordinator_book
EOF
assert_identical "scenario 2a: dual-exchange trade_status volume fallback & contradicting same-line net" "$NOW_DEFAULT"

# Older net must not mask newer venue; then gross_flat clears both legs; then waiting_entry keeps both flat.
printf '%s\n' \
  'time=2025-07-17T08:04:00Z level=INFO msg=ui_warmup_async_ready executor=mexc-ui reason=gross_flat_verified:coordinated_carrier_exit' \
  'time=2025-07-17T08:05:00Z level=INFO msg=coordinated_signal_skipped executor=toobit-main strategy_phase=waiting_entry net_side=Flat net_qty_btc=0.00000000 portfolio_projection=coordinator_book' \
  >>"$LOG2"
assert_identical "scenario 2b: dual-exchange gross_flat followed by net-only waiting_entry" "$NOW_DEFAULT"

# Snapshot volume on pnl_status, followed by a newer pnl_status WITHOUT volume_usd_by_executor (reverts to trade_status sum).
printf '%s\n' \
  'time=2025-07-17T08:06:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.2 session_cycle=2 real_pnl_usdt=8 cycles_completed=2 cycle_real_pnl_usdt=2.5 volume_usd_by_executor=toobit-main:500,mexc-ui:600' \
  >>"$LOG2"
assert_identical "scenario 2c: dual-exchange volume_usd_by_executor snapshot wins" "$NOW_DEFAULT"

printf '%s\n' \
  'time=2025-07-17T08:07:00Z level=INFO msg=pnl_status stable=true cycle_completed=false real_pnl_usdt=8.2 cycles_completed=2' \
  >>"$LOG2"
assert_identical "scenario 2d: newer pnl_status without volume_usd_by_executor reverts to trade_status sum" "$NOW_DEFAULT"

printf '# Scenario 3: partial last line (no trailing newline)\n'
new_fixture popdex-btc popdex_btc_config 'popdex-main=popdex' Asia/Taipei
RUN3="20250717_020000_popdex_btc_config"
LOG3="$REPO/logs/live-runs/$RUN3.raw.log"
write_manifest "$RUN3" "$LOG3"

printf '%s\n' \
  'time=2025-07-17T08:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 real_pnl_usdt=1.5 cycles_completed=1 cycle_real_pnl_usdt=1.5' \
  >"$LOG3"
# Partial trade_status mid-number (no trailing \n)
printf 'time=2025-07-17T08:01:00Z level=INFO msg=trade_status state=closed executor=popdex-main volume_usd=1' >>"$LOG3"
assert_identical "scenario 3a: partial trade_status mid-number without trailing newline" "$NOW_DEFAULT"

# Complete that line
printf '00.5\n' >>"$LOG3"
assert_identical "scenario 3b: after completing partial trade_status line" "$NOW_DEFAULT"

# Partial pnl_status without trailing \n
printf 'time=2025-07-17T08:02:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.2 session_cycle=2 real_pnl_usdt=3.25 cycles_completed=2 cycle_real_pnl_usdt=1.75' >>"$LOG3"
assert_identical "scenario 3c: partial pnl_status without trailing newline" "$NOW_DEFAULT"
printf '\n' >>"$LOG3"

# Partial coordinator_book without trailing \n
printf 'time=2025-07-17T08:03:00Z level=INFO msg=position_update net_side=Short net_qty_btc=0.25 portfolio_projection=coordinator_book' >>"$LOG3"
assert_identical "scenario 3d: partial coordinator_book without trailing newline" "$NOW_DEFAULT"
printf '\n' >>"$LOG3"

# Partial gross_flat_verified without trailing \n
printf 'time=2025-07-17T08:04:00Z level=INFO msg=ui_warmup_async_ready executor=popdex-main reason=gross_flat_verified:coordinated_carrier_exit' >>"$LOG3"
assert_identical "scenario 3e: partial gross_flat_verified without trailing newline" "$NOW_DEFAULT"

printf '# Scenario 6: run_id rotation & multi-log TODAY_COMPLETED_CYCLES\n'
new_fixture lighter-canary lighter_canary_config 'lighter-main=lighter' Asia/Taipei
RUN6_OLD="20250716_120000_lighter_canary_config"
RUN6_PREV="20250717_001000_lighter_canary_config"
RUN6_CURR="20250717_050000_lighter_canary_config"
LOG6_OLD="$REPO/logs/live-runs/$RUN6_OLD.raw.log"
LOG6_PREV="$REPO/logs/live-runs/$RUN6_PREV.raw.log"
LOG6_CURR="$REPO/logs/live-runs/$RUN6_CURR.raw.log"

# Yesterday log (mtime before today start in Asia/Taipei)
cat >"$LOG6_OLD" <<'EOF'
time=2025-07-16T10:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=old.1 session_cycle=1 real_pnl_usdt=1 cycles_completed=1
EOF
touch_epoch "$LOG6_OLD" "$(epoch_of 2025-07-16T12:00:00Z)"

# Earlier today log: includes duplicate cycle_id and a record with no cycle_id (uses timestamp:cycles_completed)
cat >"$LOG6_PREV" <<'EOF'
time=2025-07-17T01:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=prev.1 session_cycle=1 real_pnl_usdt=2 cycles_completed=1
time=2025-07-17T01:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=prev.1 session_cycle=1 real_pnl_usdt=2 cycles_completed=1
time=2025-07-17T02:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true session_cycle=2 real_pnl_usdt=4 cycles_completed=2
EOF
touch_epoch "$LOG6_PREV" "$(epoch_of 2025-07-17T03:00:00Z)"

# Current run log
cat >"$LOG6_CURR" <<'EOF'
time=2025-07-17T06:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=curr.1 session_cycle=1 real_pnl_usdt=3 cycles_completed=1 volume_usd_by_executor=lighter-main:1234.5
EOF
touch_epoch "$LOG6_CURR" "$(epoch_of 2025-07-17T06:05:00Z)"

write_manifest "$RUN6_PREV" "$LOG6_PREV" "2025-07-17T00:10:00Z"
assert_identical "scenario 6a: multi-log today cycles before run_id switch" "$NOW_DEFAULT"

write_manifest "$RUN6_CURR" "$LOG6_CURR" "2025-07-17T05:00:00Z"
assert_identical "scenario 6b: after manifest run_id switches to newer log" "$NOW_DEFAULT"

# Also check unbound manifest (LOG_BINDING_OK=0) and heuristic mode (TQ_REQUIRE_RUNTIME_CONTRACT=0)
rm -f "$MANIFEST_PATH"
assert_identical "scenario 6c: missing manifest still counts all today logs identically" "$NOW_DEFAULT"
export TQ_REQUIRE_RUNTIME_CONTRACT=0
assert_identical "scenario 6d: heuristic mode without manifest counts all today logs identically" "$NOW_DEFAULT"
export TQ_REQUIRE_RUNTIME_CONTRACT=1

printf '# Scenario 7: midnight rollover & DST day boundaries\n'
new_fixture tz-lane tz_lane_config 'popdex-main=popdex' Asia/Taipei
RUN7="20250717_000000_tz_lane_config"
LOG7="$REPO/logs/live-runs/$RUN7.raw.log"
cat >"$LOG7" <<'EOF'
time=2025-07-17T15:59:29Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=before.1 session_cycle=1 real_pnl_usdt=1 cycles_completed=1
time=2025-07-17T16:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=after.1 session_cycle=2 real_pnl_usdt=2 cycles_completed=2
EOF
touch_epoch "$LOG7" "$(epoch_of 2025-07-17T16:05:00Z)"
write_manifest "$RUN7" "$LOG7"
assert_identical "scenario 7a: Asia/Taipei just before local midnight (23:59:30+08:00)" "$(epoch_of 2025-07-17T15:59:30Z)"
assert_identical "scenario 7b: Asia/Taipei just after local midnight (00:00:30+08:00)" "$(epoch_of 2025-07-17T16:00:30Z)"

export TQ_TIMEZONE=America/New_York
cat >"$LOG7" <<'EOF'
time=2025-03-09T05:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=dst.1 session_cycle=1 real_pnl_usdt=1 cycles_completed=1
time=2025-03-10T03:59:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=dst.2 session_cycle=2 real_pnl_usdt=2 cycles_completed=2
time=2025-03-10T04:00:30Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=dst.3 session_cycle=3 real_pnl_usdt=3 cycles_completed=3
EOF
touch_epoch "$LOG7" "$(epoch_of 2025-03-10T04:01:00Z)"
assert_identical "scenario 7c: America/New_York 23-hour DST boundary" "$(epoch_of 2025-03-10T03:59:30Z)"

printf '# Scenario 8: future timestamps, thawing, unreadable times & key precedence\n'
new_fixture clock-lane clock_lane_config 'venue-a=exa,venue-b=exb' Asia/Taipei
RUN8="20250717_000000_clock_lane_config"
LOG8="$REPO/logs/live-runs/$RUN8.raw.log"
write_manifest "$RUN8" "$LOG8"

cat >"$LOG8" <<'EOF'
time=2025-07-17T09:50:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 real_pnl_usdt=10 cycles_completed=1 cycle_real_pnl_usdt=10 volume_usd_by_executor=venue-a:100,venue-b:50
time=2025-07-17T10:05:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.2 session_cycle=2 real_pnl_usdt=999 cycles_completed=2 cycle_real_pnl_usdt=989 risk_stopped=true volume_usd_by_executor=venue-a:9000,venue-b:9000
time=not-a-time level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.bad1 session_cycle=3 real_pnl_usdt=777 cycles_completed=3
time=2025-02-30T00:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.bad2 session_cycle=4 real_pnl_usdt=777 cycles_completed=4
time=2099-01-01T00:00:00 level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.bad3 session_cycle=5 real_pnl_usdt=777 cycles_completed=5
time="" level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.empty session_cycle=6 real_pnl_usdt=888 cycles_completed=6 time=2025-07-17T09:55:00Z
time=2025-07-17T09:56:00Z level=INFO msg=trade_status initiator_venue=venue-a initiator_side=Short initiator_qty_btc=0.2 carrier_venue=venue-b carrier_side=Long carrier_qty_btc=0.2 portfolio_projection=coordinator_book time=2025-07-17T09:57:00Z
EOF
assert_identical "scenario 8a: future newest pnl_status rejected, risk_stopped kept, empty first time= ignored" "$(epoch_of 2025-07-17T10:00:00Z)"
assert_identical "scenario 8b: after clock advances past future event" "$(epoch_of 2025-07-17T10:10:00Z)"

printf '# Scenario 9: pre-filter false positives & tag collisions (no false negatives)\n'
new_fixture noise-lane noise_lane_config 'toobit-main=toobit,mexc-ui=mexc' Asia/Taipei
RUN9="20250717_030000_noise_lane_config"
LOG9="$REPO/logs/live-runs/$RUN9.raw.log"
write_manifest "$RUN9" "$LOG9"

cat >"$LOG9" <<'EOF'
time=2025-07-17T09:00:00Z level=INFO msg=noise detail="saw pnl_status trade_status coordinator_book ui_warmup_async_ready carrier_venue=mexc-ui"
time=2025-07-17T09:00:01Z level=INFO msg=not_pnl_status stable=true cycle_completed=true real_pnl_usdt=99999
time=2025-07-17T09:00:02Z level=INFO msg=other_event note=trade_status executor=toobit-main volume_usd=88888
time=2025-07-17T09:00:03Z level=INFO msg="pnl_status" stable="true" cycle_completed="true" cycle_id="q.1" session_cycle="1" equity_now="2500.5" real_pnl_usdt="7.5" cash_pnl_usdt="6.5" rebate_usdt="1" risk_pnl_usdt="7" cycles_completed="1" cycle_real_pnl_usdt="7.5"
time=2025-07-17T09:00:04Z level=INFO msg="trade_status" executor="toobit-main" volume_usd="42.5"
time=2025-07-17T09:00:05Z level=INFO msg=invalid_snapshot initiator_venue=unknown initiator_side=Short initiator_qty_btc=99 carrier_venue=mexc-ui carrier_side=Long carrier_qty_btc=99 portfolio_projection=coordinator_book
time=2025-07-17T09:00:06Z level=INFO msg=trade_status initiator_venue="toobit-main" initiator_side="Long" initiator_qty_btc="0.3" carrier_venue="mexc-ui" carrier_side="Short" carrier_qty_btc="0.2" portfolio_projection="coordinator_book"
time=2025-07-17T09:00:07Z level=INFO msg=other_msg executor=mexc-ui reason=gross_flat_verified:fake msg=ui_warmup_async_ready
time=2025-07-17T09:00:08Z level=INFO msg=ui_warmup_async_ready executor=mexc-ui reason=gross_flat_verified:real msg=later_summary executor=other reason=later_reason
EOF
assert_identical "scenario 9a: pre-filter false positives, quoted values & first/last key precedence" "$NOW_DEFAULT"

# Edge case: single line carrying BOTH ui_warmup_async_ready/gross_flat_verified AND coordinator_book valid net
printf '%s\n' \
  'time=2025-07-17T09:01:00Z level=INFO msg=ui_warmup_async_ready executor=mexc-ui reason=gross_flat_verified:dual portfolio_projection=coordinator_book net_side=Long net_qty_btc=0.05' \
  >>"$LOG9"
assert_identical "scenario 9b: same line has both gross_flat_verified and coordinator_book net" "$NOW_DEFAULT"

# Edge case: coordinator_book-only line with repeated net_side/portfolio_projection keys later on the same line
printf '%s\n' \
  'time=2025-07-17T09:02:00Z level=INFO msg=coordinated_signal_skipped net_side=Flat net_qty_btc=0.00000000 portfolio_projection=coordinator_book net_side=Short net_qty_btc=0.15' \
  >>"$LOG9"
assert_identical "scenario 9c: coordinator_book-only line with overridden trailing net keys" "$NOW_DEFAULT"

printf '# Scenario 10 (C1): single-pass atomicity when book and closing gross_flat are appended together\n'
new_fixture popdex-02 popdex_02_config 'popdex-02=popdex' Asia/Taipei ETH
RUN10="20250717_040000_popdex_02_config"
LOG10="$REPO/logs/live-runs/$RUN10.raw.log"
write_manifest "$RUN10" "$LOG10"
cat >"$LOG10" <<'EOF'
time=2025-07-17T09:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 real_pnl_usdt=1 cycles_completed=1 volume_usd_by_executor=popdex-02:100
EOF

# First verify static equivalence when a book record and its closing gross_flat record are both present.
cat >>"$LOG10" <<'EOF'
time=2025-07-17T09:01:00Z level=INFO msg=position_update net_side=Long net_qty_btc=1.50000000 portfolio_projection=coordinator_book
time=2025-07-17T09:01:01Z level=INFO msg=ui_warmup_async_ready executor=popdex-02 reason=gross_flat_verified:coordinated_carrier_exit
EOF
assert_identical "scenario 10a: book record and closing gross_flat record together match baseline" "$NOW_DEFAULT"

# Now simulate a live writer appending BOTH a book record (Long 1.5) and its closing
# gross_flat record right after the first grep read of the active log. A single-pass
# probe reads the active log once and can never observe the torn state (Long 1.5 without
# its closing gross_flat).
cat >"$LOG10" <<'EOF'
time=2025-07-17T09:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 real_pnl_usdt=1 cycles_completed=1 volume_usd_by_executor=popdex-02:100
EOF
C1_SHIM="$CASE_DIR/c1-shim"
mkdir -p "$C1_SHIM"
C1_COUNT_FILE="$CASE_DIR/c1-grep-count"
printf '0\n' >"$C1_COUNT_FILE"
cat >"$C1_SHIM/grep" <<SHIM_EOF
#!/usr/bin/env bash
rc=0
"$REAL_GREP" "\$@" || rc=\$?
count="\$(cat "$C1_COUNT_FILE")"
count=\$((count + 1))
printf '%s\n' "\$count" >"$C1_COUNT_FILE"
if [[ "\$count" -eq 1 ]]; then
  printf '%s\n' \
    'time=2025-07-17T09:01:00Z level=INFO msg=position_update net_side=Long net_qty_btc=1.50000000 portfolio_projection=coordinator_book' \
    'time=2025-07-17T09:01:01Z level=INFO msg=ui_warmup_async_ready executor=popdex-02 reason=gross_flat_verified:coordinated_carrier_exit' \
    >>"$LOG10"
fi
exit "\$rc"
SHIM_EOF
chmod 755 "$C1_SHIM/grep"
rm -f "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"
# Capture the frozen reference output just before the controlled append.
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_OLD" PATH="$SHIM:$PATH" "$OLD_PROBE"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$C1_SHIM:$SHIM:$PATH" "$NEW_PROBE"
c1_reads="$(cat "$C1_COUNT_FILE")"
if [[ "$c1_reads" != "1" ]]; then
  printf 'FAIL: scenario 10b (C1): active manifest log was grepped %s times (expected 1)\n' "$c1_reads" >&2
  exit 1
fi
if ! cmp -s "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
  printf 'FAIL: scenario 10b (C1/C8): output differed from pre-append baseline\n' >&2
  diff -u "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME" >&2 || true
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok      scenario 10b (C1/C8): single-pass read matches pre-append baseline byte-for-byte\n'

printf '# Scenario 11 (C2): read/parser failures exit non-zero and preserve existing .prom\n'
new_fixture err-lane err_lane_config 'popdex-main=popdex' Asia/Taipei
RUN11_PREV="20250717_010000_err_lane_config"
RUN11_CURR="20250717_050000_err_lane_config"
LOG11_PREV="$REPO/logs/live-runs/$RUN11_PREV.raw.log"
LOG11_CURR="$REPO/logs/live-runs/$RUN11_CURR.raw.log"
cat >"$LOG11_PREV" <<'EOF'
time=2025-07-17T02:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=p.1 session_cycle=1 real_pnl_usdt=2 cycles_completed=1
EOF
cat >"$LOG11_CURR" <<'EOF'
time=2025-07-17T06:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 real_pnl_usdt=5 cycles_completed=1 volume_usd_by_executor=popdex-main:500
EOF
touch_epoch "$LOG11_PREV" "$(epoch_of 2025-07-17T03:00:00Z)"
touch_epoch "$LOG11_CURR" "$(epoch_of 2025-07-17T06:05:00Z)"
write_manifest "$RUN11_CURR" "$LOG11_CURR"

# Seed a valid baseline .prom before injecting failures.
ERR_PROM="$TEXT_NEW/$TQ_TEXTFILE_NAME"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$SHIM:$PATH" "$NEW_PROBE"
cp "$ERR_PROM" "$CASE_DIR/expected-preserved.prom"

assert_error_preserves_prom() {
  local description="$1"
  local shim_dir="$2"
  local rc=0
  FAKE_NOW="$((NOW_DEFAULT + 60))" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$shim_dir:$SHIM:$PATH" \
    "$NEW_PROBE" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    printf 'FAIL: %s (probe exited 0 instead of failing)\n' "$description" >&2
    exit 1
  fi
  if ! cmp -s "$CASE_DIR/expected-preserved.prom" "$ERR_PROM"; then
    printf 'FAIL: %s (existing .prom was modified on failure)\n' "$description" >&2
    diff -u "$CASE_DIR/expected-preserved.prom" "$ERR_PROM" >&2 || true
    exit 1
  fi
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok      %s\n' "$description"
}

# 11a: stat failure
STAT_SHIM="$CASE_DIR/stat-fail-shim"
mkdir -p "$STAT_SHIM"
printf '#!/usr/bin/env bash\nexit 1\n' >"$STAT_SHIM/stat"
chmod 755 "$STAT_SHIM/stat"
assert_error_preserves_prom "scenario 11a (C2): stat failure aborts and preserves .prom" "$STAT_SHIM"

# 11b: grep rc=2 on manifest log
GREP_MAN_SHIM="$CASE_DIR/grep-manifest-fail-shim"
mkdir -p "$GREP_MAN_SHIM"
cat >"$GREP_MAN_SHIM/grep" <<SHIM_EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == "$LOG11_CURR" ]]; then exit 2; fi
done
exec "$REAL_GREP" "\$@"
SHIM_EOF
chmod 755 "$GREP_MAN_SHIM/grep"
assert_error_preserves_prom "scenario 11b (C2): grep rc=2 on manifest log aborts and preserves .prom" "$GREP_MAN_SHIM"

# 11c: grep rc=2 on non-manifest today-cycle log
GREP_HIST_SHIM="$CASE_DIR/grep-hist-fail-shim"
mkdir -p "$GREP_HIST_SHIM"
cat >"$GREP_HIST_SHIM/grep" <<SHIM_EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == "$LOG11_PREV" ]]; then exit 2; fi
done
exec "$REAL_GREP" "\$@"
SHIM_EOF
chmod 755 "$GREP_HIST_SHIM/grep"
assert_error_preserves_prom "scenario 11c (C2): grep rc=2 on history today log aborts and preserves .prom" "$GREP_HIST_SHIM"

# 11d: awk failure during manifest scan
AWK_MAN_SHIM="$CASE_DIR/awk-manifest-fail-shim"
mkdir -p "$AWK_MAN_SHIM"
cat >"$AWK_MAN_SHIM/awk" <<SHIM_EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == *"__SKYEYE_HEADER__"* ]]; then exit 1; fi
done
exec "$REAL_AWK" "\$@"
SHIM_EOF
chmod 755 "$AWK_MAN_SHIM/awk"
assert_error_preserves_prom "scenario 11d (C2): awk failure in manifest scan aborts and preserves .prom" "$AWK_MAN_SHIM"

# 11e: awk failure during history today-cycle scan
AWK_HIST_SHIM="$CASE_DIR/awk-hist-fail-shim"
mkdir -p "$AWK_HIST_SHIM"
cat >"$AWK_HIST_SHIM/awk" <<SHIM_EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == "run_id=$RUN11_PREV" ]]; then exit 1; fi
done
exec "$REAL_AWK" "\$@"
SHIM_EOF
chmod 755 "$AWK_HIST_SHIM/awk"
assert_error_preserves_prom "scenario 11e (C2): awk failure in history today log scan aborts and preserves .prom" "$AWK_HIST_SHIM"

# 11f: positive control — grep rc=1 (no matching lines) still succeeds and updates .prom
printf 'time=2025-07-17T06:00:00Z level=INFO msg=unrelated_only detail=nothing\n' >"$LOG11_CURR"
printf 'time=2025-07-17T02:00:00Z level=INFO msg=unrelated_only detail=nothing\n' >"$LOG11_PREV"
touch_epoch "$LOG11_PREV" "$(epoch_of 2025-07-17T03:00:00Z)"
touch_epoch "$LOG11_CURR" "$(epoch_of 2025-07-17T06:05:00Z)"
assert_identical "scenario 11f (C2): grep rc=1 (no matches) succeeds and matches baseline" "$((NOW_DEFAULT + 60))"

printf '# Scenario 12 (C3): >1 MiB log and fabricated >1,000,000 line numbers without %%g formatting\n'
new_fixture big-lane big_lane_config 'toobit-main=toobit,mexc-ui=mexc' Asia/Taipei
RUN12="20250717_060000_big_lane_config"
LOG12="$REPO/logs/live-runs/$RUN12.raw.log"
write_manifest "$RUN12" "$LOG12"

# 12a: real >1 MiB two-exchange log (positions sit past byte offset 1,000,000, which
# caused byte-offset arithmetic in awk to format as 1e+06 before C3 was fixed).
awk 'BEGIN {
  pad = "time=2025-07-17T08:00:00Z level=INFO msg=tactic_taker_ioc_sent order_id=ord999 price=68000 qty_contracts=0.1 entry_pricing_mode=touch_spread_gate entry_spread_ticks=2 max_entry_spread_ticks=2"
  for (i = 0; i < 6500; i++) print pad
}' >"$LOG12"
cat >>"$LOG12" <<'EOF'
time=2025-07-17T09:00:00Z level=INFO msg=trade_status state=settled initiator_venue=toobit-main initiator_side=Short initiator_qty_btc=0.50000000 carrier_venue=mexc-ui carrier_side=Long carrier_qty_btc=0.10000000 net_side=Short net_qty_btc=0.40000000 portfolio_projection=coordinator_book
time=2025-07-17T09:01:00Z level=INFO msg=position_update net_side=Short net_qty_btc=0.35000000 portfolio_projection=coordinator_book
EOF
assert_identical "scenario 12a (C3): >1 MiB two-exchange log past offset 1,000,000" "$NOW_DEFAULT"

# 12b & 12c: fabricated large line numbers via grep shim:
# - 2,500,000,000+ crosses INT_MAX (2^31), where Ubuntu 22.04 mawk formats
#   numeric awk expressions as 2.5e+09 (%g).
# - 1,000,000,000,000,000,000+ crosses 2^53, where any awk numeric conversion
#   loses unit precision and collapses adjacent lines on macOS and Linux alike.
cat >"$LOG12" <<'EOF'
time=2025-07-17T09:00:00Z level=INFO msg=trade_status state=settled initiator_venue=toobit-main initiator_side=Short initiator_qty_btc=0.50000000 carrier_venue=mexc-ui carrier_side=Long carrier_qty_btc=0.10000000 net_side=Short net_qty_btc=0.40000000 portfolio_projection=coordinator_book
time=2025-07-17T09:01:00Z level=INFO msg=position_update net_side=Short net_qty_btc=0.25000000 portfolio_projection=coordinator_book
EOF
for large_case in "12b:2500000000" "12c:8000000000000000000"; do
  case_tag="${large_case%%:*}"
  line_base="${large_case#*:}"
  BIG_GREP_SHIM="$CASE_DIR/big-grep-shim-$case_tag"
  mkdir -p "$BIG_GREP_SHIM"
  cat >"$BIG_GREP_SHIM/grep" <<SHIM_EOF
#!/usr/bin/env bash
rc=0
out="\$("$REAL_GREP" "\$@")" || rc=\$?
if [[ "\$rc" -eq 0 && -n "\$out" ]]; then
  while IFS= read -r l; do
    n="\${l%%:*}"
    r="\${l#*:}"
    if [[ "\$n" =~ ^[0-9]+$ ]]; then
      printf '%s:%s\n' "\$((n + $line_base))" "\$r"
    else
      printf '%s\n' "\$l"
    fi
  done <<<"\$out"
fi
exit "\$rc"
SHIM_EOF
  chmod 755 "$BIG_GREP_SHIM/grep"
  rm -f "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"
  FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_OLD" PATH="$SHIM:$PATH" "$OLD_PROBE"
  FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$BIG_GREP_SHIM:$SHIM:$PATH" "$NEW_PROBE"
  if ! cmp -s "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
    printf 'FAIL: scenario %s (C3): fabricated line numbers +%s differed from baseline\n' "$case_tag" "$line_base" >&2
    diff -u "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME" >&2 || true
    exit 1
  fi
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok      scenario %s (C3): fabricated line numbers +%s compare cleanly without %%g or precision loss\n' "$case_tag" "$line_base"
done

printf '# Scenario 13 (C6): multi-object and non-single-object manifests fail closed like reference\n'
new_fixture c6-lane c6_lane_config 'popdex-main=popdex' Asia/Taipei
RUN13="20250717_070000_c6_lane_config"
LOG13="$REPO/logs/live-runs/$RUN13.raw.log"
cat >"$LOG13" <<'EOF'
time=2025-07-17T09:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 real_pnl_usdt=10 cycles_completed=1 volume_usd_by_executor=popdex-main:100
EOF
# Two-object JSON stream: stopped v2 object first (matching identity), valid running v1 object second.
{
  jq -n \
    --arg run_id "$RUN13" \
    --arg strategy "$TQ_STRATEGY" \
    --arg instance_id "$TQ_INSTANCE_ID" \
    --arg config_sha256 "$CONFIG_SHA" \
    --arg executable "$QUANT" \
    --arg config_path "$CONFIG_PATH" \
    --arg log_path "$LOG13" \
    --arg done_marker_path "$MARKER_PATH" \
    '{
      schema_version: 2,
      run_id: $run_id,
      strategy: $strategy,
      instance_id: $instance_id,
      pid: 999999,
      config_sha256: $config_sha256,
      process_started_at: "2025-07-17T00:00:00Z",
      executable: $executable,
      config_path: $config_path,
      log_path: $log_path,
      done_marker_path: $done_marker_path,
      state: "stopped"
    }'
  jq -n \
    --arg run_id "$RUN13" \
    --arg strategy "$TQ_STRATEGY" \
    --arg instance_id "$TQ_INSTANCE_ID" \
    --arg config_sha256 "$CONFIG_SHA" \
    --arg executable "$QUANT" \
    --arg config_path "$CONFIG_PATH" \
    --arg log_path "$LOG13" \
    --arg done_marker_path "$MARKER_PATH" \
    '{
      schema_version: 1,
      run_id: $run_id,
      strategy: $strategy,
      instance_id: $instance_id,
      pid: 999999,
      config_sha256: $config_sha256,
      process_started_at: "2025-07-17T00:00:00Z",
      executable: $executable,
      config_path: $config_path,
      log_path: $log_path,
      done_marker_path: $done_marker_path,
      state: "running"
    }'
} >"$MANIFEST_PATH"
assert_identical "scenario 13a (C6): two-object manifest (stopped v2 then valid running v1) stays unbound" "$NOW_DEFAULT"
if ! grep -q 'tnauqquant_log_binding_ok{.*strategy="c6-lane"} 0$' "$TEXT_NEW/$TQ_TEXTFILE_NAME" ||
   grep -q '^tnauqquant_current_run_info{' "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
  printf 'FAIL: scenario 13a (C6): two-object manifest must produce log_binding_ok=0 and no current_run_info\n' >&2
  cat "$TEXT_NEW/$TQ_TEXTFILE_NAME" >&2
  exit 1
fi

: >"$MANIFEST_PATH"
assert_identical "scenario 13b (C6): empty manifest file stays unbound" "$NOW_DEFAULT"

printf '# Scenario 14 (C7): exchange labels containing section marker substrings pass through unchanged\n'
new_fixture c7-lane c7_lane_config 'x=a__SKYEYE_CYCLES__b' Asia/Taipei
RUN14="20250717_080000_c7_lane_config"
LOG14="$REPO/logs/live-runs/$RUN14.raw.log"
write_manifest "$RUN14" "$LOG14"
cat >"$LOG14" <<'EOF'
time=2025-07-17T09:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 real_pnl_usdt=12.5 cycles_completed=1 cycle_real_pnl_usdt=12.5 volume_usd_by_executor=x:456.75 note=__SKYEYE_VOLUMES__
time=2025-07-17T09:01:00Z level=INFO msg=position_update net_side=Long net_qty_btc=0.5 portfolio_projection=coordinator_book
EOF
assert_identical "scenario 14a (C7): mapping x=a__SKYEYE_CYCLES__b matches baseline byte-for-byte" "$NOW_DEFAULT"

export TQ_EXECUTOR_MAP='x=a__SKYEYE_CYCLES__b,y=c__SKYEYE_TODAY__d'
cat >"$LOG14" <<'EOF'
time=2025-07-17T09:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 real_pnl_usdt=12.5 cycles_completed=1 cycle_real_pnl_usdt=12.5 volume_usd_by_executor=x:100,y:200 note=__SKYEYE_END__
EOF
assert_identical "scenario 14b (C7): multiple exchange labels containing section markers match baseline byte-for-byte" "$NOW_DEFAULT"

printf '# Scenario 15 (C4): 80 historical glob matches with varied mtimes, spaces, genuine bound manifest, and shasum fallback\n'
new_fixture many-logs many_logs_config 'lighter-main=lighter' Asia/Taipei
# 70 older logs (days before today in Asia/Taipei), some with spaces in names.
old_base_epoch="$(epoch_of 2025-07-10T00:00:00Z)"
for (( n = 1; n <= 70; n++ )); do
  printf -v idx '%02d' "$n"
  if [[ "$idx" == "15" || "$idx" == "42" ]]; then
    hist_path="$REPO/logs/live-runs/20250710_0000${idx}_with space_many_logs_config.raw.log"
  else
    hist_path="$REPO/logs/live-runs/20250710_0000${idx}_many_logs_config.raw.log"
  fi
  printf 'time=2025-07-10T01:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=old.%s session_cycle=1 real_pnl_usdt=1 cycles_completed=1\n' "$idx" >"$hist_path"
  touch_epoch "$hist_path" "$((old_base_epoch + n * 60))"
done

# 10 today logs (mtime >= today start in Asia/Taipei), including a name with spaces and a newest log.
today_base_epoch="$(epoch_of 2025-07-17T00:00:00Z)"
NEWEST_SPACED_LOG="$REPO/logs/live-runs/20250717_090000_today space_many_logs_config.raw.log"
NEWEST_SPACED_MTIME="$(epoch_of 2025-07-17T09:15:00Z)"
LOG15=""
LOG15_MTIME=0
for (( n = 1; n <= 9; n++ )); do
  printf -v idx '%02d' "$n"
  hist_path="$REPO/logs/live-runs/20250717_0000${idx}_many_logs_config.raw.log"
  if [[ "$n" -le 5 ]]; then
    printf 'time=2025-07-17T01:%s:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=t.%s session_cycle=1 real_pnl_usdt=%s cycles_completed=1\n' "$idx" "$idx" "$n" >"$hist_path"
  else
    printf 'time=2025-07-17T02:%s:00Z level=INFO msg=unrelated_only detail=quiet\n' "$idx" >"$hist_path"
  fi
  hist_mtime="$((today_base_epoch + n * 300))"
  touch_epoch "$hist_path" "$hist_mtime"
  if [[ "$n" -eq 5 ]]; then
    LOG15="$hist_path"
    LOG15_MTIME="$hist_mtime"
  fi
done
cat >"$NEWEST_SPACED_LOG" <<'EOF'
time=2025-07-17T08:30:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=space.1 session_cycle=1 real_pnl_usdt=9.5 cycles_completed=1 volume_usd_by_executor=lighter-main:2500
EOF
touch_epoch "$NEWEST_SPACED_LOG" "$NEWEST_SPACED_MTIME"

# Verify fixture invariants: exactly 80 matches and LOG15 exists with distinct mtime < newest.
match_count_15="$(compgen -G "$TQ_RAW_LOG_GLOB" | wc -l | tr -d ' ')"
if [[ "$match_count_15" != "80" || ! -f "$LOG15" || "$LOG15_MTIME" -ge "$NEWEST_SPACED_MTIME" ]]; then
  printf 'FAIL: scenario 15 fixture invariant failed (matches=%s, log15=%s, mtime=%s, newest=%s)\n' \
    "$match_count_15" "$LOG15" "$LOG15_MTIME" "$NEWEST_SPACED_MTIME" >&2
  exit 1
fi
RUN15="${LOG15##*/}"
RUN15="${RUN15%.raw.log}"

assert_metric_value() {
  local description="$1"
  local file="$2"
  local metric="$3"
  local expected="$4"
  if ! grep -Eq "^${metric}\\{[^}]+\\} ${expected}\$" "$file"; then
    printf 'FAIL: %s: expected %s=%s in %s\n' "$description" "$metric" "$expected" "$file" >&2
    grep -E "^${metric}\{" "$file" >&2 || true
    exit 1
  fi
}

# Sub-case 15a: manifest genuinely bound to LOG15 (not the newest spaced log).
write_manifest "$RUN15" "$LOG15" "2025-07-17T00:05:00Z"
assert_identical "scenario 15a (C4): 80 historical logs (manifest-bound + today cycles + spaces)" "$NOW_DEFAULT"
assert_metric_value "scenario 15a (C4)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_log_binding_ok 1
assert_metric_value "scenario 15a (C4)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_log_mtime_seconds "$LOG15_MTIME"
assert_metric_value "scenario 15a (C4)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_completed_cycles_today 6

# Sub-case 15b: heuristic mode without manifest (exercises latest-log selection across 80 files including spaces).
rm -f "$MANIFEST_PATH"
export TQ_REQUIRE_RUNTIME_CONTRACT=0
assert_identical "scenario 15b: 80 historical logs heuristic mode latest-log selection with spaces" "$NOW_DEFAULT"
assert_metric_value "scenario 15b" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_log_mtime_seconds "$NEWEST_SPACED_MTIME"
export TQ_REQUIRE_RUNTIME_CONTRACT=1

# Sub-case 15c: shasum fallback when sha256sum is absent from PATH.
write_manifest "$RUN15" "$LOG15" "2025-07-17T00:05:00Z"
NO_SHA256SUM_BIN="$CASE_DIR/no-sha256sum-bin"
mkdir -p "$NO_SHA256SUM_BIN"
for tool in awk basename bash chmod date env find grep head jq lsof mkdir mktemp mv ps readlink rm sed shasum sort stat xargs; do
  tool_path="$(command -v "$tool" || true)"
  [[ -n "$tool_path" ]] && ln -s "$tool_path" "$NO_SHA256SUM_BIN/$tool"
done
rm -f "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_OLD" PATH="$SHIM:$PATH" "$OLD_PROBE"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$SHIM:$NO_SHA256SUM_BIN" "$NEW_PROBE"
assert_metric_value "scenario 15c" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_log_binding_ok 1
assert_metric_value "scenario 15c" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_log_mtime_seconds "$LOG15_MTIME"
if ! cmp -s "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
  printf 'FAIL: scenario 15c: shasum fallback without sha256sum differed from baseline\n' >&2
  diff -u "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME" >&2 || true
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok      scenario 15c: shasum fallback without sha256sum matches baseline byte-for-byte\n'

# Sub-case 15d: GNU stat -c and GNU date -d paths match baseline byte-for-byte on macOS too.
REAL_STAT="$(command -v stat)"
GNU_SHIM="$CASE_DIR/gnu-shim"
mkdir -p "$GNU_SHIM"
GNU_STAT_CALLS="$CASE_DIR/gnu-stat.calls"
: >"$GNU_STAT_CALLS"
cat >"$GNU_SHIM/stat" <<SHIM_EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'call\n' >>"$GNU_STAT_CALLS"
if [[ "\${1:-}" == "-c" && "\${2:-}" == "%Y" ]]; then
  shift 2
  if [[ "\${1:-}" == "--" ]]; then shift; fi
  if "$REAL_STAT" -c '%Y' -- "\$@" 2>/dev/null; then
    exit 0
  fi
  exec "$REAL_STAT" -f '%m' -- "\$@"
fi
exit 1
SHIM_EOF
cat >"$GNU_SHIM/date" <<SHIM_EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "\${FAKE_NOW:-}" ]]; then
  case "\$*" in
    +%s) printf '%s\n' "\$FAKE_NOW"; exit 0 ;;
    +%F) "$REAL_DATE" -r "\$FAKE_NOW" +%F 2>/dev/null || "$REAL_DATE" -d "@\$FAKE_NOW" +%F; exit ;;
  esac
fi
if [[ "\${1:-}" == "-d" ]]; then
  spec="\$2"
  fmt="\$3"
  if "$REAL_DATE" -d "\$spec" "\$fmt" 2>/dev/null; then
    exit 0
  fi
  case "\$spec" in
    *" + 1 day")
      day="\${spec% + 1 day}"
      exec "$REAL_DATE" -j -v+1d -f '%Y-%m-%d' "\$day" "\$fmt"
      ;;
    *" 00:00:00"|*" 01:00:00")
      exec "$REAL_DATE" -j -f '%Y-%m-%d %H:%M:%S' "\$spec" "\$fmt"
      ;;
    *Z)
      norm="\$(printf '%s' "\$spec" | sed -E 's/\\.[0-9]+Z\$/Z/')"
      exec "$REAL_DATE" -j -f '%Y-%m-%dT%H:%M:%SZ' "\$norm" "\$fmt"
      ;;
    *)
      norm="\$(printf '%s' "\$spec" | sed -E 's/\\.[0-9]+([+-][0-9]{2}):([0-9]{2})\$/\\1\\2/; s/([+-][0-9]{2}):([0-9]{2})\$/\\1\\2/')"
      exec "$REAL_DATE" -j -f '%Y-%m-%dT%H:%M:%S%z' "\$norm" "\$fmt"
      ;;
  esac
fi
exec "$REAL_DATE" "\$@"
SHIM_EOF
chmod 755 "$GNU_SHIM/stat" "$GNU_SHIM/date"
rm -f "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_OLD" PATH="$SHIM:$PATH" "$OLD_PROBE"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$GNU_SHIM:$PATH" "$NEW_PROBE"
assert_metric_value "scenario 15d (C4)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_log_binding_ok 1
assert_metric_value "scenario 15d (C4)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_log_mtime_seconds "$LOG15_MTIME"
if ! cmp -s "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
  printf 'FAIL: scenario 15d (C4): GNU stat/date path differed from baseline\n' >&2
  diff -u "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME" >&2 || true
  exit 1
fi
gnu_stat_count="$(wc -l <"$GNU_STAT_CALLS" | tr -d ' ')"
if [[ "$gnu_stat_count" != "1" ]]; then
  printf 'FAIL: scenario 15d (C4): expected 1 batched GNU stat call for 80 bound logs, got %s\n' "$gnu_stat_count" >&2
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok      scenario 15d (C4): GNU stat/date path matches baseline with 1 stat call for 80 genuinely bound logs\n'

printf '# Scenario 16 (C3): >500 short matching paths use 1 stat batch on both BSD and GNU paths\n'
new_fixture big-glob big_glob_config 'lighter-main=lighter' Asia/Taipei
SHORT_LOG_DIR="$REPO/l"
mkdir -p "$SHORT_LOG_DIR"
export TQ_RAW_LOG_GLOB="$SHORT_LOG_DIR/*.raw.log"
for (( n = 1; n <= 504; n++ )); do
  printf -v idx '%03d' "$n"
  p="$SHORT_LOG_DIR/o${idx}_big_glob_config.raw.log"
  : >"$p"
  touch_epoch "$p" "$((old_base_epoch + n))"
done
RUN16="20250717_000001_big_glob_config"
LOG16="$SHORT_LOG_DIR/$RUN16.raw.log"
LOG16_MTIME="$(epoch_of 2025-07-17T06:00:00Z)"
printf 'time=2025-07-17T06:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 real_pnl_usdt=4 cycles_completed=1\n' >"$LOG16"
touch_epoch "$LOG16" "$LOG16_MTIME"
write_manifest "$RUN16" "$LOG16" "2025-07-17T05:00:00Z"

match_count_16="$(compgen -G "$TQ_RAW_LOG_GLOB" | wc -l | tr -d ' ')"
[[ "$match_count_16" == "505" ]] || {
  printf 'FAIL: scenario 16 (C3): expected 505 matches, got %s\n' "$match_count_16" >&2
  exit 1
}

# 16a: BSD/native stat success-batch count == 1 for 505 short paths.
STAT_OK_SHIM="$CASE_DIR/stat-ok-shim"
mkdir -p "$STAT_OK_SHIM"
STAT_OK_CALLS="$CASE_DIR/stat-ok.calls"
: >"$STAT_OK_CALLS"
cat >"$STAT_OK_SHIM/stat" <<SHIM_EOF
#!/usr/bin/env bash
rc=0
"$REAL_STAT" "\$@" || rc=\$?
if [[ "\$rc" -eq 0 ]]; then
  printf 'ok\n' >>"$STAT_OK_CALLS"
fi
exit "\$rc"
SHIM_EOF
chmod 755 "$STAT_OK_SHIM/stat"
rm -f "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_OLD" PATH="$SHIM:$PATH" "$OLD_PROBE"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$STAT_OK_SHIM:$SHIM:$PATH" "$NEW_PROBE"
if ! cmp -s "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
  printf 'FAIL: scenario 16a (C3): 505 short paths differed from baseline\n' >&2
  diff -u "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME" >&2 || true
  exit 1
fi
stat_ok_count="$(wc -l <"$STAT_OK_CALLS" | tr -d ' ')"
if [[ "$stat_ok_count" != "1" ]]; then
  printf 'FAIL: scenario 16a (C3): expected 1 successful stat batch for 505 short paths, got %s\n' "$stat_ok_count" >&2
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok      scenario 16a (C3): 505 short paths use 1 successful stat batch and match baseline\n'

# 16b: GNU stat call count == 1 for 505 short paths.
: >"$GNU_STAT_CALLS"
rm -f "$TEXT_NEW/$TQ_TEXTFILE_NAME"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$GNU_SHIM:$PATH" "$NEW_PROBE"
if ! cmp -s "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
  printf 'FAIL: scenario 16b (C3): 505 short paths on GNU stat differed from baseline\n' >&2
  diff -u "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME" >&2 || true
  exit 1
fi
gnu_stat_count_16="$(wc -l <"$GNU_STAT_CALLS" | tr -d ' ')"
if [[ "$gnu_stat_count_16" != "1" ]]; then
  printf 'FAIL: scenario 16b (C3): expected 1 GNU stat call for 505 short paths, got %s\n' "$gnu_stat_count_16" >&2
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok      scenario 16b (C3): 505 short paths use 1 GNU stat call and match baseline\n'

# 16c & 16d: large ASCII argument list (>1 MiB on 2 MiB ARG_MAX Linux; >650 KiB on 1 MiB macOS)
# uses 1 stat call, and UTF-8 paths exceeding ARG_MAX in encoded bytes succeed without E2BIG.
PLATFORM_ARG_MAX="$(getconf ARG_MAX 2>/dev/null || printf '1048576')"
if [[ "$PLATFORM_ARG_MAX" -ge 1500000 ]]; then
  ASCII16_DEPTH=9
  ASCII16_SEG="$(printf 'a%.0s' {1..200})"
  ASCII16_COUNT=600
  UTF816_DEPTH=20
  UTF816_SEG="$(printf '中%.0s' {1..60})"
  UTF816_COUNT=600
else
  ASCII16_DEPTH=4
  ASCII16_SEG="$(printf 'a%.0s' {1..200})"
  ASCII16_COUNT=800
  UTF816_DEPTH=4
  UTF816_SEG="$(printf '中%.0s' {1..65})"
  UTF816_COUNT=1350
fi

ASCII16_DIR="$REPO"
for (( d = 1; d <= ASCII16_DEPTH; d++ )); do
  ASCII16_DIR="$ASCII16_DIR/$ASCII16_SEG"
done
mkdir -p "$ASCII16_DIR"
export TQ_RAW_LOG_GLOB="$ASCII16_DIR/*.raw.log"
for (( n = 1; n < ASCII16_COUNT; n++ )); do
  printf -v idx '%04d' "$n"
  p="$ASCII16_DIR/o${idx}_big_glob_config.raw.log"
  : >"$p"
  touch_epoch "$p" "$((old_base_epoch + n))"
done
LOG16C="$ASCII16_DIR/$RUN16.raw.log"
printf 'time=2025-07-17T06:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 real_pnl_usdt=4 cycles_completed=1\n' >"$LOG16C"
touch_epoch "$LOG16C" "$LOG16_MTIME"
write_manifest "$RUN16" "$LOG16C" "2025-07-17T05:00:00Z"
: >"$STAT_OK_CALLS"
rm -f "$TEXT_NEW/$TQ_TEXTFILE_NAME"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$STAT_OK_SHIM:$SHIM:$PATH" "$NEW_PROBE"
assert_metric_value "scenario 16c (C3)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_log_binding_ok 1
assert_metric_value "scenario 16c (C3)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_log_mtime_seconds "$LOG16_MTIME"
assert_metric_value "scenario 16c (C3)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_completed_cycles_today 1
stat_ok_16c="$(wc -l <"$STAT_OK_CALLS" | tr -d ' ')"
if [[ "$stat_ok_16c" != "1" ]]; then
  printf 'FAIL: scenario 16c (C3): expected 1 successful stat batch for %s large ASCII paths, got %s\n' "$ASCII16_COUNT" "$stat_ok_16c" >&2
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok      scenario 16c (C3): %s large ASCII paths use 1 stat call\n' "$ASCII16_COUNT"

UTF816_DIR="$REPO"
for (( d = 1; d <= UTF816_DEPTH; d++ )); do
  UTF816_DIR="$UTF816_DIR/$UTF816_SEG"
done
mkdir -p "$UTF816_DIR"
export TQ_RAW_LOG_GLOB="$UTF816_DIR/*.raw.log"
for (( n = 1; n < UTF816_COUNT; n++ )); do
  printf -v idx '%04d' "$n"
  p="$UTF816_DIR/o${idx}_big_glob_config.raw.log"
  : >"$p"
  touch_epoch "$p" "$((old_base_epoch + n))"
done
LOG16D="$UTF816_DIR/$RUN16.raw.log"
printf 'time=2025-07-17T06:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 real_pnl_usdt=4 cycles_completed=1\n' >"$LOG16D"
touch_epoch "$LOG16D" "$LOG16_MTIME"
utf8_bytes_16d="$(find "$UTF816_DIR" -maxdepth 1 -type f -name '*.raw.log' -print0 | wc -c | tr -d ' ')"
if [[ "$utf8_bytes_16d" -le "$PLATFORM_ARG_MAX" ]]; then
  printf 'FAIL: scenario 16d (C3): UTF-8 fixture (%s bytes) did not exceed ARG_MAX (%s)\n' "$utf8_bytes_16d" "$PLATFORM_ARG_MAX" >&2
  exit 1
fi
write_manifest "$RUN16" "$LOG16D" "2025-07-17T05:00:00Z"
rm -f "$TEXT_NEW/$TQ_TEXTFILE_NAME"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$SHIM:$PATH" "$NEW_PROBE"
assert_metric_value "scenario 16d (C3)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_log_binding_ok 1
assert_metric_value "scenario 16d (C3)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_log_mtime_seconds "$LOG16_MTIME"
assert_metric_value "scenario 16d (C3)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_completed_cycles_today 1
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok      scenario 16d (C3): %s UTF-8 paths (%s bytes > ARG_MAX %s) succeed without E2BIG\n' "$UTF816_COUNT" "$utf8_bytes_16d" "$PLATFORM_ARG_MAX"

printf '# Scenario 17 (C1): manifest log created after enumeration, first write after midnight, and out-of-glob exclusion\n'
REAL_JQ="$(command -v jq)"
new_fixture race-c1 race_c1_config 'lighter-main=lighter' Asia/Taipei
RUN17="20250717_060000_race_c1_config"
LOG17="$REPO/logs/live-runs/$RUN17.raw.log"
TODAY_TOUCH_17="$(epoch_of 2025-07-17T06:05:00Z)"
YEST_TOUCH_17="$(epoch_of 2025-07-16T12:00:00Z)"
write_manifest "$RUN17" "$LOG17" "2025-07-17T06:00:00Z"

# 17a: in-glob manifest log created between initial glob enumeration and manifest read.
C1A_SHIM="$CASE_DIR/c1a-jq-shim"
mkdir -p "$C1A_SHIM"
C1A_FLAG="$CASE_DIR/c1a-triggered"
cat >"$C1A_SHIM/jq" <<SHIM_EOF
#!/usr/bin/env bash
if [[ ! -f "$C1A_FLAG" ]]; then
  : >"$C1A_FLAG"
  printf 'time=2025-07-17T06:01:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=late.1 session_cycle=1 real_pnl_usdt=3 cycles_completed=1\n' >"$LOG17"
  TZ=UTC touch -t "\$(TZ=UTC "$REAL_DATE" -r "$TODAY_TOUCH_17" +%Y%m%d%H%M.%S 2>/dev/null || TZ=UTC "$REAL_DATE" -d "@$TODAY_TOUCH_17" +%Y%m%d%H%M.%S)" "$LOG17"
fi
exec "$REAL_JQ" "\$@"
SHIM_EOF
chmod 755 "$C1A_SHIM/jq"
rm -f "$LOG17" "$C1A_FLAG" "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_OLD" PATH="$C1A_SHIM:$SHIM:$PATH" "$OLD_PROBE"
rm -f "$LOG17" "$C1A_FLAG"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$C1A_SHIM:$SHIM:$PATH" "$NEW_PROBE"
assert_metric_value "scenario 17a (C1)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_current_cycles_completed 1
assert_metric_value "scenario 17a (C1)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_completed_cycles_today 1
if ! cmp -s "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
  printf 'FAIL: scenario 17a (C1): late-created manifest log differed from baseline\n' >&2
  diff -u "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME" >&2 || true
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok      scenario 17a (C1): in-glob manifest log created after enumeration counts daily cycle once and matches baseline\n'

# 17b: existing in-glob manifest log receives first write of the day after mtime snapshot.
C1B_SHIM="$CASE_DIR/c1b-jq-shim"
mkdir -p "$C1B_SHIM"
C1B_FLAG="$CASE_DIR/c1b-triggered"
cat >"$C1B_SHIM/jq" <<SHIM_EOF
#!/usr/bin/env bash
if [[ ! -f "$C1B_FLAG" ]]; then
  : >"$C1B_FLAG"
  printf 'time=2025-07-17T06:02:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=midnight.1 session_cycle=1 real_pnl_usdt=5 cycles_completed=1\n' >>"$LOG17"
  TZ=UTC touch -t "\$(TZ=UTC "$REAL_DATE" -r "$TODAY_TOUCH_17" +%Y%m%d%H%M.%S 2>/dev/null || TZ=UTC "$REAL_DATE" -d "@$TODAY_TOUCH_17" +%Y%m%d%H%M.%S)" "$LOG17"
fi
exec "$REAL_JQ" "\$@"
SHIM_EOF
chmod 755 "$C1B_SHIM/jq"
: >"$LOG17"
touch_epoch "$LOG17" "$YEST_TOUCH_17"
rm -f "$C1B_FLAG" "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_OLD" PATH="$C1B_SHIM:$SHIM:$PATH" "$OLD_PROBE"
: >"$LOG17"
touch_epoch "$LOG17" "$YEST_TOUCH_17"
rm -f "$C1B_FLAG"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$C1B_SHIM:$SHIM:$PATH" "$NEW_PROBE"
assert_metric_value "scenario 17b (C1)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_current_cycles_completed 1
assert_metric_value "scenario 17b (C1)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_completed_cycles_today 1
if ! cmp -s "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
  printf 'FAIL: scenario 17b (C1): first write after midnight race differed from baseline\n' >&2
  diff -u "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME" >&2 || true
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok      scenario 17b (C1): first write of the day after mtime snapshot counts daily cycle and matches baseline\n'

# 17c: out-of-glob manifest log stays excluded from completed_cycles_today.
rm -f "$LOG17"
OUT_OF_GLOB_DIR="$REPO/logs/other-runs"
mkdir -p "$OUT_OF_GLOB_DIR"
LOG17_OUT="$OUT_OF_GLOB_DIR/$RUN17.raw.log"
printf 'time=2025-07-17T06:03:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=out.1 session_cycle=1 real_pnl_usdt=7 cycles_completed=1\n' >"$LOG17_OUT"
touch_epoch "$LOG17_OUT" "$TODAY_TOUCH_17"
write_manifest "$RUN17" "$LOG17_OUT" "2025-07-17T06:00:00Z"
assert_identical "scenario 17c (C1): out-of-glob manifest log stays excluded from completed_cycles_today" "$NOW_DEFAULT"
assert_metric_value "scenario 17c (C1)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_current_cycles_completed 1
assert_metric_value "scenario 17c (C1)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_completed_cycles_today 0

# 17d (C1): late-created manifest log with canonical path and equivalent /./ glob directory.
write_manifest "$RUN17" "$LOG17" "2025-07-17T06:00:00Z"
export TQ_RAW_LOG_GLOB="$REPO/logs/./live-runs/*race_c1_config.raw.log"
rm -f "$LOG17" "$C1A_FLAG" "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_OLD" PATH="$C1A_SHIM:$SHIM:$PATH" "$OLD_PROBE"
rm -f "$LOG17" "$C1A_FLAG"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$C1A_SHIM:$SHIM:$PATH" "$NEW_PROBE"
assert_metric_value "scenario 17d (C1)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_log_binding_ok 1
assert_metric_value "scenario 17d (C1)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_current_cycles_completed 1
assert_metric_value "scenario 17d (C1)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_completed_cycles_today 1
if ! cmp -s "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
  printf 'FAIL: scenario 17d (C1): late-created manifest log with /./ glob differed from baseline\n' >&2
  diff -u "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME" >&2 || true
  exit 1
fi
export TQ_RAW_LOG_GLOB="$REPO/logs/live-runs/*race_c1_config.raw.log"
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok      scenario 17d (C1): late-created manifest log with /./ equivalent glob counts daily cycle once and matches baseline\n'

# 17e (C9): first-write heartbeat (no completed cycle) between enumeration and manifest read updates mtime.
C9_SHIM="$CASE_DIR/c9-jq-shim"
mkdir -p "$C9_SHIM"
C9_FLAG="$CASE_DIR/c9-triggered"
cat >"$C9_SHIM/jq" <<SHIM_EOF
#!/usr/bin/env bash
if [[ ! -f "$C9_FLAG" ]]; then
  : >"$C9_FLAG"
  printf 'time=2025-07-17T06:04:00Z level=INFO msg=heartbeat status=alive\n' >>"$LOG17"
  TZ=UTC touch -t "\$(TZ=UTC "$REAL_DATE" -r "$TODAY_TOUCH_17" +%Y%m%d%H%M.%S 2>/dev/null || TZ=UTC "$REAL_DATE" -d "@$TODAY_TOUCH_17" +%Y%m%d%H%M.%S)" "$LOG17"
fi
exec "$REAL_JQ" "\$@"
SHIM_EOF
chmod 755 "$C9_SHIM/jq"
: >"$LOG17"
touch_epoch "$LOG17" "$YEST_TOUCH_17"
rm -f "$C9_FLAG" "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_OLD" PATH="$C9_SHIM:$SHIM:$PATH" "$OLD_PROBE"
: >"$LOG17"
touch_epoch "$LOG17" "$YEST_TOUCH_17"
rm -f "$C9_FLAG"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$C9_SHIM:$SHIM:$PATH" "$NEW_PROBE"
assert_metric_value "scenario 17e (C9)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_log_mtime_seconds "$TODAY_TOUCH_17"
assert_metric_value "scenario 17e (C9)" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_completed_cycles_today 0
if ! cmp -s "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
  printf 'FAIL: scenario 17e (C9): first-write heartbeat mtime refresh differed from baseline\n' >&2
  diff -u "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME" >&2 || true
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok      scenario 17e (C9): first-write heartbeat without completed cycle refreshes log_mtime_seconds and matches baseline\n'

printf '# Scenario 18 (C2): same-day history log archived between enumeration and history scan\n'
new_fixture race-c2 race_c2_config 'lighter-main=lighter' Asia/Taipei
RUN18_HIST="20250717_010000_race_c2_config"
RUN18_CURR="20250717_050000_race_c2_config"
LOG18_HIST="$REPO/logs/live-runs/$RUN18_HIST.raw.log"
LOG18_CURR="$REPO/logs/live-runs/$RUN18_CURR.raw.log"
ARCHIVE_DIR="$CASE_DIR/archive"
mkdir -p "$ARCHIVE_DIR"
printf 'time=2025-07-17T05:30:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=curr.1 session_cycle=1 real_pnl_usdt=4 cycles_completed=1\n' >"$LOG18_CURR"
touch_epoch "$LOG18_CURR" "$(epoch_of 2025-07-17T05:35:00Z)"
write_manifest "$RUN18_CURR" "$LOG18_CURR" "2025-07-17T05:00:00Z"

C2_SHIM="$CASE_DIR/c2-jq-shim"
mkdir -p "$C2_SHIM"
C2_FLAG="$CASE_DIR/c2-triggered"
cat >"$C2_SHIM/jq" <<SHIM_EOF
#!/usr/bin/env bash
if [[ ! -f "$C2_FLAG" ]]; then
  : >"$C2_FLAG"
  mv "$LOG18_HIST" "$ARCHIVE_DIR/"
fi
exec "$REAL_JQ" "\$@"
SHIM_EOF
chmod 755 "$C2_SHIM/jq"

seed_c2_hist() {
  printf 'time=2025-07-17T01:30:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=hist.1 session_cycle=1 real_pnl_usdt=2 cycles_completed=1\n' >"$LOG18_HIST"
  touch_epoch "$LOG18_HIST" "$(epoch_of 2025-07-17T02:00:00Z)"
  rm -f "$C2_FLAG" "$ARCHIVE_DIR/${LOG18_HIST##*/}"
}
rm -f "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"
seed_c2_hist
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_OLD" PATH="$C2_SHIM:$SHIM:$PATH" "$OLD_PROBE"
seed_c2_hist
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$C2_SHIM:$SHIM:$PATH" "$NEW_PROBE"
if ! cmp -s "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
  printf 'FAIL: scenario 18 (C2): archived history log differed from baseline\n' >&2
  diff -u "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME" >&2 || true
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok      scenario 18 (C2): archived same-day history log skipped cleanly and matches baseline\n'

printf '# Scenario 19 (C5): negative pre-epoch mtime (-1) on historical log is accepted\n'
new_fixture neg-mtime neg_mtime_config 'lighter-main=lighter' Asia/Taipei
RUN19="20250717_060000_neg_mtime_config"
LOG19="$REPO/logs/live-runs/$RUN19.raw.log"
LOG19_OLD="$REPO/logs/live-runs/19691231_235959_neg_mtime_config.raw.log"
printf 'time=2025-07-17T06:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 real_pnl_usdt=6 cycles_completed=1\n' >"$LOG19"
touch_epoch "$LOG19" "$(epoch_of 2025-07-17T06:05:00Z)"
printf 'time=1969-12-31T23:59:59Z level=INFO msg=unrelated\n' >"$LOG19_OLD"
perl -e 'utime -1, -1, $ARGV[0]' "$LOG19_OLD"
write_manifest "$RUN19" "$LOG19" "2025-07-17T06:00:00Z"
assert_identical "scenario 19a (C5): negative mtime -1 in glob matches baseline" "$NOW_DEFAULT"
# Also check GNU stat path with negative mtime -1.
rm -f "$TEXT_NEW/$TQ_TEXTFILE_NAME"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$GNU_SHIM:$PATH" "$NEW_PROBE"
if ! cmp -s "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
  printf 'FAIL: scenario 19b (C5): negative mtime -1 on GNU stat path differed from baseline\n' >&2
  diff -u "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME" >&2 || true
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok      scenario 19b (C5): negative mtime -1 on GNU stat path matches baseline\n'

printf '# Scenario 20 (C6): accepted trailing-comma TQ_EXECUTOR_MAP preserves awk field count\n'
new_fixture trailing-comma trailing_comma_config 'x=venue,' Asia/Taipei
RUN20="20250717_070000_trailing_comma_config"
LOG20="$REPO/logs/live-runs/$RUN20.raw.log"
printf 'time=2025-07-17T07:00:00Z level=INFO msg=position_update net_side=Long net_qty_btc=1.50000000 portfolio_projection=coordinator_book\n' >"$LOG20"
touch_epoch "$LOG20" "$(epoch_of 2025-07-17T07:05:00Z)"
write_manifest "$RUN20" "$LOG20" "2025-07-17T07:00:00Z"
assert_identical "scenario 20 (C6): trailing-comma mapping omits single-exchange series just like baseline" "$NOW_DEFAULT"
if grep -q '^tnauqquant_current_position_btc{' "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
  printf 'FAIL: scenario 20 (C6): trailing-comma mapping unexpectedly emitted exchange-level position series\n' >&2
  exit 1
fi

printf '# Scenario 21 (C7): config basename containing backslash hashes identically with sha256sum and shasum\n'
new_fixture bs-cfg 'bs\config' 'lighter-main=lighter' Asia/Taipei
# Recompute CONFIG_SHA via stdin so neither backend adds a leading backslash.
CONFIG_SHA="$(shasum -a 256 <"$CONFIG_PATH" | awk '{print $1}')"
RUN21="20250717_080000_bs_cfg"
LOG21="$REPO/logs/live-runs/$RUN21.raw.log"
export TQ_RAW_LOG_GLOB="$REPO/logs/live-runs/*bs_cfg.raw.log"
printf 'time=2025-07-17T08:00:00Z level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 real_pnl_usdt=2 cycles_completed=1\n' >"$LOG21"
touch_epoch "$LOG21" "$(epoch_of 2025-07-17T08:05:00Z)"
write_manifest "$RUN21" "$LOG21" "2025-07-17T08:00:00Z"
rm -f "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_OLD" PATH="$SHIM:$PATH" "$NEW_PROBE"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$SHIM:$NO_SHA256SUM_BIN" "$NEW_PROBE"
assert_metric_value "scenario 21 (C7) sha256sum" "$TEXT_OLD/$TQ_TEXTFILE_NAME" tnauqquant_config_snapshot_match 1
assert_metric_value "scenario 21 (C7) shasum" "$TEXT_NEW/$TQ_TEXTFILE_NAME" tnauqquant_config_snapshot_match 1
if ! cmp -s "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
  printf 'FAIL: scenario 21 (C7): sha256sum and shasum outputs differed on backslash config basename\n' >&2
  diff -u "$TEXT_OLD/$TQ_TEXTFILE_NAME" "$TEXT_NEW/$TQ_TEXTFILE_NAME" >&2 || true
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok      scenario 21 (C7): sha256sum and shasum match with config_snapshot_match=1 on backslash basename\n'

printf 'PASS: %s probe equivalence checks matched baseline byte-for-byte\n' "$PASS_COUNT"
