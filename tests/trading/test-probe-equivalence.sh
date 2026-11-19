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
rm -f "$TEXT_NEW/$TQ_TEXTFILE_NAME"
FAKE_NOW="$NOW_DEFAULT" TQ_TEXTFILE_DIR="$TEXT_NEW" PATH="$C1_SHIM:$SHIM:$PATH" "$NEW_PROBE"
c1_reads="$(cat "$C1_COUNT_FILE")"
if [[ "$c1_reads" != "1" ]]; then
  printf 'FAIL: scenario 10b (C1): active manifest log was grepped %s times (expected 1)\n' "$c1_reads" >&2
  exit 1
fi
if rg -q '^tnauqquant_current_net_position_btc\{.*\} 1\.5$' "$TEXT_NEW/$TQ_TEXTFILE_NAME"; then
  printf 'FAIL: scenario 10b (C1): torn read published open Long 1.5 without its closing gross_flat\n' >&2
  cat "$TEXT_NEW/$TQ_TEXTFILE_NAME" >&2
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok      scenario 10b (C1): single-pass read prevents torn book+gross_flat observation\n'

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

printf 'PASS: %s probe equivalence checks matched baseline byte-for-byte\n' "$PASS_COUNT"
