#!/usr/bin/env bash
set -uo pipefail

# Behavior tests for states the probe must never report as safe. Each case runs
# the real probe against a compiled stand-in for quant, so ps sees a true argv.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE="$REPO_ROOT/agents/alloy/trading/probe.sh"
REAL_PS="$(command -v ps)"

for tool in cc jq shasum; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'FAIL: %s is required; this suite must not pass by skipping\n' "$tool" >&2
    exit 1
  }
done

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-probe-safety.XXXXXX")"
PIDS=()
FAILURES=0
CASE_INDEX=0
RUN_ID=20261104_000000_fixture_config
CONFIG_REL=config/fixture.yaml

stop_processes() {
  local pid
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  PIDS=()
}
cleanup() {
  stop_processes
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

printf '#include <unistd.h>\nint main(void) { for (;;) pause(); }\n' >"$TEST_ROOT/fake-quant.c"
cc -o "$TEST_ROOT/fake-quant" "$TEST_ROOT/fake-quant.c" || exit 1

SHIM="$TEST_ROOT/shim"
mkdir -p "$SHIM"
cat >"$SHIM/ps" <<SHIM_EOF
#!/usr/bin/env bash
case "\${PS_MODE:-real}" in
  fail_empty) exit 1 ;;
  ok_empty) exit 0 ;;
  ok_partial)
    "$REAL_PS" "\$@" | awk -v root="\$FIXTURE_ROOT" 'index(\$0, root) { print; exit }'
    exit 0
    ;;
  fail_partial)
    "$REAL_PS" "\$@" | awk -v root="\$FIXTURE_ROOT" 'index(\$0, root) { print; exit }'
    exit 1
    ;;
  *) exec "$REAL_PS" "\$@" ;;
esac
SHIM_EOF
chmod 755 "$SHIM/ps"

iso_at() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}
iso_offset() {
  iso_at "$(($(date +%s) + $1))"
}
iso_with_fraction() { # iso_with_fraction ISO DIGITS
  printf '%s.%sZ\n' "${1%Z}" "$2"
}
iso_in_zone() { # iso_in_zone EPOCH OFFSET_SECONDS OFFSET_TEXT: the producer's millisecond log time
  local wall
  wall="$(iso_at "$(($1 + $2))")"
  printf '%s.123%s\n' "${wall%Z}" "$3"
}
process_started_epoch() {
  local started
  started="$(LC_ALL=C TZ=UTC "$REAL_PS" -o lstart= -p "$1" | sed -E 's/[[:space:]]+$//')"
  [[ -n "$started" ]] || return 1
  LC_ALL=C TZ=UTC date -j -f '%a %b %e %T %Y' "$started" +%s 2>/dev/null ||
    LC_ALL=C TZ=UTC date -d "$started" +%s
}
process_started_iso() {
  local epoch
  epoch="$(process_started_epoch "$1")" && iso_at "$epoch"
}

fixture() {
  stop_processes
  CASE_INDEX=$((CASE_INDEX + 1))
  ROOT="$TEST_ROOT/case$CASE_INDEX"
  REPO="$ROOT/tq"
  LOG="$REPO/logs/live-runs/$RUN_ID.raw.log"
  TEXT="$ROOT/textfile"
  METRICS="$TEXT/tnauqquant.prom"
  mkdir -p "$REPO/config" "$REPO/run-state" "$REPO/logs/live-runs" "$TEXT"
  printf 'instance_id: "fixture-instance"\n' >"$REPO/$CONFIG_REL"
  cp "$TEST_ROOT/fake-quant" "$REPO/quant"
  QUANT="$REPO/quant"
  CONFIG_ABS="$REPO/$CONFIG_REL"
  CONFIG_SHA="$(shasum -a 256 "$CONFIG_ABS" | awk '{print $1}')"
  export TQ_PRODUCT=tnauqquant TQ_ENVIRONMENT=production TQ_SERVER_ID=fixture-server
  export TQ_STRATEGY=fixture-strategy TQ_INSTANCE_ID=fixture-instance TQ_REPO_ROOT="$REPO"
  export TQ_CONFIG_PATH="$CONFIG_ABS" TQ_RAW_LOG_GLOB="$REPO/logs/live-runs/*.raw.log"
  export TQ_RUN_MANIFEST="$REPO/run-state/current.json" TQ_DONE_MARKER="$REPO/run-state/current.done.json"
  export TQ_POC_RUN_EXPECTED=1 TQ_REQUIRE_RUNTIME_CONTRACT=1 TQ_TIMEZONE=Asia/Taipei
  export TQ_TEXTFILE_DIR="$TEXT" TQ_EXECUTOR_MAP=venue-a=exa,venue-b=exb TQ_SIDECAR_REQUIRED=0
  export TQ_TEXTFILE_MODE=600 TQ_SIDECAR_SESSION=fixture-missing TQ_SIDECAR_IDENTITY_FILE="$ROOT/none"
  export TQ_SIDECAR_HEALTH_URL=http://127.0.0.1:9/health FIXTURE_ROOT="$ROOT"
  pnl_line "$(iso_offset -30)" >"$LOG"
}

pnl_line() {
  printf 'time=%s level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=c.1 session_cycle=1 equity_now=1000 real_pnl_usdt=12.5 cycles_completed=1 cycle_real_pnl_usdt=1 risk_stopped=%s\n' \
    "$1" "${2:-false}"
}

start() { # start ARGV... from the fixture repo
  ( cd "$REPO" && exec "$@" ) >/dev/null 2>&1 &
  LAST_PID=$!
  PIDS+=("$LAST_PID")
  sleep 0.2
}

manifest() { # manifest PID [STARTED_AT]
  local started="${2:-}"
  [[ -n "$started" ]] || started="$(process_started_iso "$1" 2>/dev/null || iso_offset -600)"
  jq -n --arg r "$RUN_ID" --arg s "$TQ_STRATEGY" --arg i "$TQ_INSTANCE_ID" --argjson p "$1" \
    --arg c "$CONFIG_SHA" --arg t "$started" --arg e "$QUANT" --arg cp "$CONFIG_ABS" --arg l "$LOG" \
    --arg d "$TQ_DONE_MARKER" \
    '{schema_version:1,run_id:$r,strategy:$s,instance_id:$i,pid:$p,config_sha256:$c,process_started_at:$t,
      executable:$e,config_path:$cp,log_path:$l,done_marker_path:$d,state:"running"}' >"$TQ_RUN_MANIFEST"
}

marker() { # marker PID JQ_OVERRIDE
  jq -n --arg r "$RUN_ID" --arg s "$TQ_STRATEGY" --arg i "$TQ_INSTANCE_ID" --argjson p "$1" \
    --arg c "$CONFIG_SHA" --arg t "$(iso_offset -60)" \
    '{schema_version:1,run_id:$r,strategy:$s,instance_id:$i,pid:$p,config_sha256:$c,
      reason:"max_cycles_complete",phase:"max_cycles_complete",completed_at:$t,
      long_btc:0,short_btc:0,net_btc:0,dust_tolerance_btc:0.0001}' | jq "$2" >"$TQ_DONE_MARKER"
}

run_probe() { # run_probe [PS_MODE]
  PROBE_RC=0
  PS_MODE="${1:-real}" PATH="$SHIM:$PATH" "$PROBE" >/dev/null 2>&1 || PROBE_RC=$?
}

metric() { # metric NAME [SELECTOR]
  awk -v m="tnauqquant_$1" -v s="${2:-}" \
    'index($0, m "{") == 1 && (s == "" || index($0, s) > 0) { print $NF; exit }' "$METRICS" 2>/dev/null
}

expect() { # expect DESCRIPTION ACTUAL WANTED
  if [[ "$2" == "$3" ]]; then
    printf 'ok      %s\n' "$1"
  else
    printf 'not ok  %s (want=%s got=%s)\n' "$1" "$3" "${2:-<none>}"
    FAILURES=$((FAILURES + 1))
  fi
}

printf '# process enumeration\n'
for mode in fail_empty ok_empty ok_partial fail_partial; do
  fixture
  start "$QUANT" -config "$CONFIG_REL"
  manifest "$LAST_PID"
  start "$QUANT" -config "$CONFIG_REL"
  run_probe
  expect "$mode: healthy listing counts both processes" "$(metric process_count)" 2
  before="$(metric probe_timestamp_seconds)"
  sleep 1.1
  run_probe "$mode"
  expect "$mode: probe fails instead of reporting a count" "$([[ "$PROBE_RC" -ne 0 ]] && echo failed)" failed
  expect "$mode: probe timestamp stays frozen" "$(metric probe_timestamp_seconds)" "$before"
done

printf '# process identity\n'
fixture
start /bin/sh -c "sleep 60; $QUANT -config $CONFIG_REL"
manifest 999999
run_probe
expect 'a shell wrapper alone is not a trading process' "$(metric process_count)" 0

fixture
start "$QUANT" -config "$CONFIG_REL"
manifest "$LAST_PID"
start /bin/sh -c "sleep 60; $QUANT -config $CONFIG_REL"
run_probe
expect 'a shell wrapper is not a duplicate' "$(metric process_count)" 1

fixture
start "$QUANT" -config "$CONFIG_REL"
manifest "$LAST_PID"
ln -s "$QUANT" "$REPO/quant-link"
wanted=1
for form in equals double-dash double-dash-equals relative symlink; do
  case "$form" in
    equals) start "$QUANT" "-config=$CONFIG_ABS" ;;
    double-dash) start "$QUANT" --config "$CONFIG_REL" ;;
    double-dash-equals) start "$QUANT" "--config=$CONFIG_REL" ;;
    relative) start ./quant -config "./$CONFIG_REL" ;;
    symlink) start "$REPO/quant-link" -config "$CONFIG_REL" ;;
  esac
  wanted=$((wanted + 1))
  run_probe
  expect "duplicate launched with $form form is counted" "$(metric process_count)" "$wanted"
done

fixture
start "$QUANT" -config "$CONFIG_REL"
manifest "$LAST_PID" 2001-01-01T00:00:00Z
run_probe
expect 'a live PID with another start time is not the manifest process' "$(metric process_identity_ok)" 0

fixture
start "$QUANT" -config "$CONFIG_REL"
manifest "$LAST_PID"
run_probe
expect 'the true process keeps its identity' "$(metric process_identity_ok)" 1

started_epoch="$(process_started_epoch "$LAST_PID")"
manifest "$LAST_PID" "$(iso_with_fraction "$(iso_at "$started_epoch")" 123456789)"
run_probe
expect 'process_started_at with nine fractional digits matches' "$(metric process_identity_ok)" 1
manifest "$LAST_PID" "$(iso_at "$((started_epoch + 8))")"
run_probe
expect 'a start time inside the 10 second tolerance matches' "$(metric process_identity_ok)" 1
manifest "$LAST_PID" "$(iso_at "$((started_epoch - 12))")"
run_probe
expect 'a start time outside the 10 second tolerance does not match' "$(metric process_identity_ok)" 0

printf '# terminal marker\n'
fixture
manifest 999999
marker 999999 .
run_probe
expect 'a consistent safe marker stays safe' "$(metric done_marker 'reason="max_cycles_complete"')" 1

expect_safe() { # expect_safe DESCRIPTION REASON JQ_OVERRIDE
  marker 999999 ".reason=\"$2\"|.phase=(if .reason == \"max_cycles_complete\" then .phase else \"cycle\" end)|$3"
  run_probe
  expect "$1 stays safe" "$(metric done_marker "reason=\"$2\"")" 1
  expect "$1 is not critical" "$(metric done_marker 'reason="unknown"')" ''
}
expect_critical() { # expect_critical DESCRIPTION REASON JQ_OVERRIDE
  marker 999999 ".reason=\"$2\"|.phase=(if .reason == \"max_cycles_complete\" then .phase else \"cycle\" end)|$3"
  run_probe
  expect "$1 is critical" "$(metric done_marker 'reason="unknown"')" 1
  expect "$1 is not safe" "$(metric done_marker "reason=\"$2\"")" ''
}

# phase is the engine stage, never the reason, for every reduce_only_complete marker.
for phase in startup signal_loop cycle; do
  expect_safe "reduce_only_complete in phase $phase" reduce_only_complete ".phase=\"$phase\""
done

for reason in max_cycles_complete reduce_only_complete; do
  expect_safe "$reason with zero tolerance and zero positions" "$reason" '.dust_tolerance_btc=0'
  expect_safe "$reason with long dust inside the tolerance" "$reason" \
    '.long_btc=0.00005|.net_btc=0.00005'
  expect_safe "$reason with short dust inside the tolerance" "$reason" \
    '.short_btc=0.00005|.net_btc=-0.00005'
  nano_completed="$(iso_with_fraction "$(iso_offset -60)" 123456789)"
  expect_safe "$reason with nine fractional digits in completed_at" "$reason" \
    ".completed_at=\"$nano_completed\""
  for spec in \
    'error|.error="position not flat"' \
    'long exposure|.long_btc=1.5|.net_btc=1.5' \
    'short exposure|.short_btc=1.5|.net_btc=-1.5' \
    'open hedged legs|.long_btc=2|.short_btc=2' \
    'dust above a zero tolerance|.dust_tolerance_btc=0|.long_btc=0.00000001' \
    'negative tolerance|.dust_tolerance_btc=-1' \
    'empty phase|.phase=""' \
    'unparsable completion|.completed_at="not-a-time"' \
    'future completion|.completed_at="2099-01-01T00:00:00Z"' \
    'completion before start|.completed_at="2001-01-01T00:00:00Z"'
  do
    expect_critical "$reason with ${spec%%|*}" "$reason" "${spec#*|}"
  done
done

for phase in drain_failed startup cycle; do
  expect_critical "max_cycles_complete with phase $phase" max_cycles_complete ".phase=\"$phase\""
done

printf '# position coherence\n'
book_line() { # book_line TIME CARRIER_VENUE INITIATOR_SIDE INITIATOR_QTY CARRIER_SIDE CARRIER_QTY [EXTRA]
  printf 'time=%s level=INFO msg=trade_status initiator_venue=venue-a initiator_side=%s initiator_qty_btc=%s carrier_venue=%s carrier_side=%s carrier_qty_btc=%s portfolio_projection=coordinator_book %s\n' \
    "$1" "$3" "$4" "$2" "$5" "$6" "${7:-}"
}
venue_line() {
  book_line "$1" venue-b Short 0.5 Long "$2" "${3:-}"
}
net_line() {
  printf 'time=%s level=INFO msg=position_update net_side=%s net_qty_btc=%s portfolio_projection=coordinator_book\n' "$1" "$2" "$3"
}

fixture
start "$QUANT" -config "$CONFIG_REL"
manifest "$LAST_PID"
{ net_line "$(iso_offset -300)" Flat 0; venue_line "$(iso_offset -20)" 0.1; } >"$LOG"
run_probe
expect 'older net does not mask newer venues' "$(metric current_net_position_btc)" -0.4
expect 'venue observation time is published' \
  "$([[ -n "$(metric position_sample_timestamp_seconds 'source="venue"')" ]] && echo yes)" yes

{ venue_line "$(iso_offset -300)" 0.5; net_line "$(iso_offset -20)" Short 0.4; } >"$LOG"
run_probe
expect 'newer net still wins over older venues' "$(metric current_net_position_btc)" -0.4
expect 'net observation time is published' \
  "$([[ -n "$(metric position_sample_timestamp_seconds 'source="net"')" ]] && echo yes)" yes

venue_line "$(iso_offset -20)" 0.1 'net_side=Flat net_qty_btc=0' >"$LOG"
run_probe
expect 'venues decide when one line disagrees with itself' "$(metric current_net_position_btc)" -0.4

# The producer's normal form: every venue line carries the net computed from it.
book_line "$(iso_offset -20)" venue-b Short 0.50000000 Long 0.10000000 \
  'net_side=Short net_qty_btc=0.40000000' >"$LOG"
run_probe
expect 'a shared line keeps the net metric' "$(metric current_net_position_btc)" -0.4
expect 'a shared line stays a valid position' "$(metric current_position_valid)" 1
expect 'a shared line keeps the initiator series' "$(metric current_position_btc 'exchange="exa"')" 0.50000000
expect 'a shared line keeps the carrier series' "$(metric current_position_btc 'exchange="exb"')" 0.10000000

book_line "$(iso_offset -20)" venue-b Flat 0.00000000 Flat 0.00000000 \
  'net_side=Flat net_qty_btc=0.00000000' >"$LOG"
run_probe
expect 'a flat shared line keeps the net metric at zero' "$(metric current_net_position_btc)" 0

# Each quantity is rounded on its own, so the legs can miss net by the last digit.
book_line "$(iso_offset -20)" venue-b Short 0.12345679 Long 0.10000000 \
  'net_side=Short net_qty_btc=0.02345678' >"$LOG"
run_probe
expect 'a shared line keeps the printed net through rounding' "$(metric current_net_position_btc)" -0.02345678

fixture
export TQ_EXECUTOR_MAP=venue-a=exa
start "$QUANT" -config "$CONFIG_REL"
manifest "$LAST_PID"
book_line "$(iso_offset -20)" venue-a Short 0.50000000 Long 0.10000000 \
  'net_side=Short net_qty_btc=0.40000000' >"$LOG"
run_probe
expect 'a one-executor shared line keeps the net metric' "$(metric current_net_position_btc)" -0.4
expect 'a one-executor shared line reports net as the only position' \
  "$(metric current_position_btc 'side="short"')" 0.40000000
expect 'a one-executor shared line drops the leg series' "$(metric current_position_btc 'side="long"')" ''

printf '# event time formats\n'
fixture
start "$QUANT" -config "$CONFIG_REL"
manifest "$LAST_PID"
now="$(date +%s)"
pnl_epoch=$((now - 90))
venue_epoch=$((now - 60))
net_epoch=$((now - 30))
{
  pnl_line "$(iso_in_zone "$pnl_epoch" 28800 +08:00)"
  venue_line "$(iso_in_zone "$venue_epoch" 28800 +08:00)" 0.1
  net_line "$(iso_in_zone "$net_epoch" -18000 -05:00)" Short 0.4
} >"$LOG"
for host_zone in UTC Asia/Taipei America/New_York; do
  TZ="$host_zone" run_probe
  expect "P&L millisecond offset time parses on host zone $host_zone" \
    "$(metric pnl_sample_timestamp_seconds)" "$pnl_epoch"
  expect "venue millisecond offset time parses on host zone $host_zone" \
    "$(metric position_sample_timestamp_seconds 'source="venue"')" "$venue_epoch"
  expect "net millisecond offset time parses on host zone $host_zone" \
    "$(metric position_sample_timestamp_seconds 'source="net"')" "$net_epoch"
done

printf '# future timestamps\n'
fixture
start "$QUANT" -config "$CONFIG_REL"
manifest "$LAST_PID"
pnl_line "$(iso_offset 3600)" >"$LOG"
run_probe
expect 'a future P&L sample is invalid' "$(metric current_pnl_valid)" 0
expect 'a future P&L sample publishes no value' "$(metric current_real_pnl_usdt)" ''

pnl_line "$(iso_offset 3600)" true >"$LOG"
run_probe
expect 'a rejected sample still reports its risk stop' "$(metric risk_stopped)" 1

pnl_line "$(iso_offset 60)" >"$LOG"
run_probe
expect 'small skew inside the allowance stays valid' "$(metric current_pnl_valid)" 1

venue_line "$(iso_offset 3600)" 0.1 >"$LOG"
run_probe
expect 'a future position sample is invalid' "$(metric current_position_valid)" 0

stop_processes
if [[ "$FAILURES" -gt 0 ]]; then
  printf 'FAIL: %s probe safety cases failed\n' "$FAILURES" >&2
  exit 1
fi
printf 'PASS: trading probe safety behavior\n'
