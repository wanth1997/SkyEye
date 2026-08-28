#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILDER="$REPO_ROOT/agents/alloy/trading/pnl-history.sh"

[[ -x "$BUILDER" ]] || {
  printf 'FAIL: executable P&L history builder is missing: %s\n' "$BUILDER" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-pnl-history.XXXXXX")"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

RAW_DIR="$TEST_ROOT/raw"
TEXTFILE_DIR="$TEST_ROOT/textfile"
CACHE_DIR="$TEST_ROOT/cache"
mkdir -p "$RAW_DIR" "$TEXTFILE_DIR"

export TQ_PRODUCT=tnauqquant
export TQ_ENVIRONMENT=production
export TQ_SERVER_ID=tnauqquant-prod-1
export TQ_STRATEGY=toobit-mexc-btc
export TQ_RAW_LOG_GLOB="$RAW_DIR/*.raw.log"
export TQ_TIMEZONE=Asia/Taipei
export TQ_TEXTFILE_DIR="$TEXTFILE_DIR"
export TQ_PNL_HISTORY_CACHE_DIR="$CACHE_DIR"
export TQ_PNL_HISTORY_DAYS=2
export TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES=10
export TQ_PNL_HISTORY_NOW_SECONDS=1787803200

METRICS_PATH="$TEXTFILE_DIR/tnauqquant-pnl-history.prom"

cat >"$RAW_DIR/run-a.raw.log" <<'EOF'
time=2026-08-25T23:00:00+08:00 level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=cycle.0 cycle_real_pnl_usdt=10 real_pnl_usdt=10
time=2026-08-26T09:00:00+08:00 level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=cycle.1 cycle_real_pnl_usdt=2 real_pnl_usdt=12
time=2026-08-26T09:00:00+08:00 level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=cycle.1 cycle_real_pnl_usdt=2 real_pnl_usdt=12
time=2026-08-26T10:00:00+08:00 level=INFO msg=pnl_status stable=true cycle_completed=true real_pnl_usdt=11
time=2026-08-26T10:30:00+08:00 level=INFO msg=pnl_status stable=true real_pnl_usdt=11
EOF

cat >"$RAW_DIR/run-b.raw.log" <<'EOF'
time=2026-08-26T11:00:00+08:00 level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=cycle.1 cycle_real_pnl_usdt=-1 real_pnl_usdt=-1
time=2026-08-27T09:00:00+08:00 level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=cycle.2 cycle_real_pnl_usdt=3 real_pnl_usdt=2
time=2026-08-27T10:00:00+08:00 level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=cycle.3 cycle_real_pnl_usdt=-0.5 real_pnl_usdt=1.5
EOF

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
    printf 'FAIL: %s %s expected=%s actual=%s\n' \
      "$metric" "$selector" "$expected" "${actual:-<missing>}" >&2
    exit 1
  fi
}

assert_point() {
  local point="$1"
  local expected_value="$2"
  local expected_timestamp="$3"
  assert_metric tnauqquant_pnl_history_point_value_usdt "$expected_value" "point=\"$point\""
  assert_metric tnauqquant_pnl_history_point_timestamp_seconds "$expected_timestamp" "point=\"$point\""
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

file_mtime() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1"
}

checksum() {
  shasum -a 256 "$1" | awk '{print $1}'
}

printf 'case: stale lock recovery\n'
mkdir -p "$CACHE_DIR/.lock"
touch -t 202001010000 "$CACHE_DIR/.lock"
"$BUILDER"

printf 'case: cross-run and cross-day accumulation\n'
[[ -f "$METRICS_PATH" ]] || {
  printf 'FAIL: metrics file was not created\n' >&2
  exit 1
}

assert_point 0 10 1787673600
assert_point 1 11 1787760000
assert_point 2 14 1787792400
assert_point 3 13.5 1787796000
assert_metric tnauqquant_pnl_history_cached_cycles 5
assert_metric tnauqquant_pnl_history_skipped_legacy_events 2
assert_metric tnauqquant_pnl_history_first_supported_event_timestamp_seconds 1787670000
assert_metric tnauqquant_pnl_history_last_event_timestamp_seconds 1787796000
assert_metric tnauqquant_pnl_history_build_timestamp_seconds "$TQ_PNL_HISTORY_NOW_SECONDS"
assert_metric tnauqquant_pnl_history_valid 1
assert_metric tnauqquant_pnl_history_current_value_usdt 13.5

point_count="$(awk 'index($0, "tnauqquant_pnl_history_point_value_usdt{") == 1 { count++ } END { print count + 0 }' "$METRICS_PATH")"
[[ "$point_count" == "4" ]] || {
  printf 'FAIL: expected four bounded display points, got %s\n' "$point_count" >&2
  exit 1
}

if rg -q 'time(stamp)?=' "$METRICS_PATH"; then
  printf 'FAIL: timestamps must be metric values, not labels\n' >&2
  exit 1
fi
[[ "$(file_mode "$CACHE_DIR")" == "700" ]] || {
  printf 'FAIL: cache directory must have mode 700\n' >&2
  exit 1
}
[[ "$(file_mode "$METRICS_PATH")" == "600" ]] || {
  printf 'FAIL: metrics file must have mode 600\n' >&2
  exit 1
}
last_value_line="$(rg -n '^tnauqquant_pnl_history_point_value_usdt\{' "$METRICS_PATH" | tail -n 1 | cut -d: -f1)"
timestamp_help_line="$(rg -n '^# HELP tnauqquant_pnl_history_point_timestamp_seconds ' "$METRICS_PATH" | cut -d: -f1)"
[[ "$last_value_line" -lt "$timestamp_help_line" ]] || {
  printf 'FAIL: point metric families must be emitted in canonical groups\n' >&2
  exit 1
}
if find "$TEXTFILE_DIR" "$CACHE_DIR" \
    \( -name '.tnauqquant-pnl-history.prom.*' -o -name '.pnl-history-*' \) | rg -q .; then
  printf 'FAIL: successful build left temporary history files behind\n' >&2
  exit 1
fi

printf 'case: a fresh lock protects an active build\n'
metrics_before_fresh_lock="$(checksum "$METRICS_PATH")"
mkdir "$CACHE_DIR/.lock"
if "$BUILDER"; then
  printf 'FAIL: builder should respect a fresh lock\n' >&2
  exit 1
fi
[[ "$(checksum "$METRICS_PATH")" == "$metrics_before_fresh_lock" ]] || {
  printf 'FAIL: fresh-lock refusal replaced the last good metrics\n' >&2
  exit 1
}
rmdir "$CACHE_DIR/.lock"

printf 'case: unchanged logs reuse their cached summaries\n'
RUN_A_CACHE="$CACHE_DIR/runs/run-a.events"
[[ -f "$RUN_A_CACHE" ]] || {
  printf 'FAIL: expected per-run cache %s\n' "$RUN_A_CACHE" >&2
  exit 1
}
run_a_mtime_before="$(file_mtime "$RUN_A_CACHE")"
sleep 1
"$BUILDER"
run_a_mtime_after="$(file_mtime "$RUN_A_CACHE")"
[[ "$run_a_mtime_after" == "$run_a_mtime_before" ]] || {
  printf 'FAIL: unchanged log cache was rewritten\n' >&2
  exit 1
}

printf 'case: retained summaries survive raw-log rotation\n'
metrics_before_rotation="$(checksum "$METRICS_PATH")"
rm "$RAW_DIR/run-a.raw.log"
"$BUILDER"
metrics_after_rotation="$(checksum "$METRICS_PATH")"
[[ "$metrics_after_rotation" == "$metrics_before_rotation" ]] || {
  printf 'FAIL: removing a raw log changed retained P&L history\n' >&2
  exit 1
}

printf 'case: conflicting cycle data preserves the last good metrics\n'
metrics_before_conflict="$(checksum "$METRICS_PATH")"
cat >>"$RAW_DIR/run-b.raw.log" <<'EOF'
time=2026-08-27T10:01:00+08:00 level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=cycle.3 cycle_real_pnl_usdt=99 real_pnl_usdt=100.5
EOF
if "$BUILDER"; then
  printf 'FAIL: conflicting cycle data should fail closed\n' >&2
  exit 1
fi
[[ "$(checksum "$METRICS_PATH")" == "$metrics_before_conflict" ]] || {
  printf 'FAIL: conflict replaced the last good metrics\n' >&2
  exit 1
}

printf 'case: current-day point bound fails closed\n'
sed -i.bak '$d' "$RAW_DIR/run-b.raw.log"
rm "$RAW_DIR/run-b.raw.log.bak"
export TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES=1
if "$BUILDER"; then
  printf 'FAIL: excess current-day cycles should exceed the configured bound\n' >&2
  exit 1
fi
[[ "$(checksum "$METRICS_PATH")" == "$metrics_before_conflict" ]] || {
  printf 'FAIL: bound failure replaced the last good metrics\n' >&2
  exit 1
}

printf 'case: coverage begins with the first supported value, not synthetic zeroes\n'
COVERAGE_ROOT="$TEST_ROOT/coverage"
mkdir -p "$COVERAGE_ROOT/raw" "$COVERAGE_ROOT/textfile"
cat >"$COVERAGE_ROOT/raw/run-coverage.raw.log" <<'EOF'
time=2026-08-27T09:00:00+08:00 level=INFO msg=pnl_status stable=true cycle_completed=true cycle_id=coverage.1 cycle_real_pnl_usdt=3 real_pnl_usdt=3
EOF
export TQ_RAW_LOG_GLOB="$COVERAGE_ROOT/raw/*.raw.log"
export TQ_TEXTFILE_DIR="$COVERAGE_ROOT/textfile"
export TQ_PNL_HISTORY_CACHE_DIR="$COVERAGE_ROOT/cache"
export TQ_PNL_HISTORY_DAYS=2
export TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES=10
"$BUILDER"
METRICS_PATH="$COVERAGE_ROOT/textfile/tnauqquant-pnl-history.prom"
assert_point 0 3 1787792400
assert_metric tnauqquant_pnl_history_current_value_usdt 3
coverage_point_count="$(awk 'index($0, "tnauqquant_pnl_history_point_value_usdt{") == 1 { count++ } END { print count + 0 }' "$METRICS_PATH")"
[[ "$coverage_point_count" == "1" ]] || {
  printf 'FAIL: unsupported pre-coverage days must not emit synthetic points; got %s\n' \
    "$coverage_point_count" >&2
  exit 1
}

printf 'case: empty source emits validity metadata without a fake point\n'
EMPTY_ROOT="$TEST_ROOT/empty"
mkdir -p "$EMPTY_ROOT/raw" "$EMPTY_ROOT/textfile"
export TQ_RAW_LOG_GLOB="$EMPTY_ROOT/raw/*.raw.log"
export TQ_TEXTFILE_DIR="$EMPTY_ROOT/textfile"
export TQ_PNL_HISTORY_CACHE_DIR="$EMPTY_ROOT/cache"
export TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES=10
"$BUILDER"
METRICS_PATH="$EMPTY_ROOT/textfile/tnauqquant-pnl-history.prom"
assert_metric tnauqquant_pnl_history_valid 0
if rg -q '^tnauqquant_pnl_history_point_' "$METRICS_PATH"; then
  printf 'FAIL: empty history must not emit a fabricated P&L point\n' >&2
  exit 1
fi
if rg -q '^tnauqquant_pnl_history_current_value_usdt' "$METRICS_PATH"; then
  printf 'FAIL: empty history must not emit a fabricated current P&L value\n' >&2
  exit 1
fi

printf 'PASS: historical P&L cache and accumulation contract\n'
