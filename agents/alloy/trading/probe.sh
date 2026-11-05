#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'skyeye trading probe: %s\n' "$*" >&2
  exit 1
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "$name is required"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

valid_label_value() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

file_mtime() {
  local path="$1"
  if stat -c '%Y' "$path" >/dev/null 2>&1; then
    stat -c '%Y' "$path"
  else
    stat -f '%m' "$path"
  fi
}

is_number() {
  [[ "$1" =~ ^-?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$ ]]
}

timestamp_to_epoch() {
  local timestamp="$1"
  local normalized result
  normalized="$(printf '%s\n' "$timestamp" | sed -E \
    's/\.[0-9]+([+-][0-9]{2}):([0-9]{2})$/\1\2/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/; s/\.[0-9]+Z$/Z/')"

  case "$normalized" in
    *Z)
      if result="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$normalized" '+%s' 2>/dev/null)"; then
        printf '%s\n' "$result"
        return 0
      fi
      ;;
    *)
      if result="$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$normalized" '+%s' 2>/dev/null)"; then
        printf '%s\n' "$result"
        return 0
      fi
      ;;
  esac

  TZ=UTC date -d "$timestamp" '+%s' 2>/dev/null
}

local_day_start_epoch() {
  local day="$1"
  local result
  if result="$(TZ="$TQ_TIMEZONE" date -j -f '%Y-%m-%d %H:%M:%S' \
    "$day 00:00:00" '+%s' 2>/dev/null)"; then
    printf '%s\n' "$result"
    return 0
  fi
  TZ="$TQ_TIMEZONE" date -d "$day 00:00:00" '+%s' 2>/dev/null
}

# Event times are read in awk: forking date per line would dominate every full-log
# scan. Programs that use event_time_trusted set future_limit with -v.
# shellcheck disable=SC2016
AWK_EVENT_TIME='
  # The first time= is the record time, as in logfmt_value. A later one is an attribute.
  function event_time(    i, value) {
    for (i = 1; i <= NF; i++) {
      if (index($i, "time=") == 1) {
        value = substr($i, 6)
        gsub(/^"|"$/, "", value)
        return value
      }
    }
    return ""
  }
  # RFC 3339 to epoch seconds, or -1 when it is not a real instant. Regex intervals
  # are avoided: older mawk does not support them.
  function event_epoch(value,    year, month, day, hour, minute, second, zone,
      zone_hours, zone_minutes, offset, month_days) {
    if (value !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]([.][0-9]+)?(Z|[-+][0-9][0-9]:?[0-9][0-9])$/) {
      return -1
    }
    year = substr(value, 1, 4) + 0
    month = substr(value, 6, 2) + 0
    day = substr(value, 9, 2) + 0
    hour = substr(value, 12, 2) + 0
    minute = substr(value, 15, 2) + 0
    second = substr(value, 18, 2) + 0
    if (year < 1970 || month < 1 || month > 12 || hour > 23 || minute > 59 || second > 59) {
      return -1
    }
    month_days = substr("312831303130313130313031", month * 2 - 1, 2) + 0
    if (month == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) month_days = 29
    if (day < 1 || day > month_days) return -1

    zone = substr(value, 20)
    sub(/^[.][0-9]+/, "", zone)
    sub(/:/, "", zone)
    offset = 0
    if (zone != "Z") {
      zone_hours = substr(zone, 2, 2) + 0
      zone_minutes = substr(zone, 4, 2) + 0
      if (zone_hours > 23 || zone_minutes > 59) return -1
      offset = zone_hours * 3600 + zone_minutes * 60
      if (substr(zone, 1, 1) == "-") offset = -offset
    }

    # Counting years from March puts the leap day at the end of the year.
    if (month <= 2) {
      year--
      month += 12
    }
    return (365 * year + int(year / 4) - int(year / 100) + int(year / 400) + \
      int((153 * (month - 3) + 2) / 5) + day - 719469) * 86400 + \
      hour * 3600 + minute * 60 + second - offset
  }
  # An unreadable time cannot be shown to be past, so it is not trusted either.
  function event_time_trusted(    epoch) {
    epoch = event_epoch(event_time())
    return epoch >= 0 && epoch <= future_limit
  }
'

# With require_trusted_time=1 the latest line is the latest one whose time can be
# trusted, so a future event falls back to the event before it.
latest_pnl_line() {
  local log_path="$1"
  local require_completed="$2"
  local require_trusted_time="${3:-0}"
  awk -v require_completed="$require_completed" \
      -v require_trusted_time="$require_trusted_time" \
      -v future_limit="$FUTURE_EVENT_LIMIT" "$AWK_EVENT_TIME"'
    {
      message = ""
      stable = ""
      completed = ""
      for (i = 1; i <= NF; i++) {
        equals = index($i, "=")
        if (equals == 0) {
          continue
        }
        key = substr($i, 1, equals - 1)
        value = substr($i, equals + 1)
        gsub(/^"|"$/, "", value)
        if (key == "msg") message = value
        if (key == "stable") stable = value
        if (key == "cycle_completed") completed = value
      }
      if (message == "pnl_status" && stable == "true" &&
          (require_completed != "1" || completed == "true") &&
          (require_trusted_time != "1" || event_time_trusted())) {
        latest = $0
      }
    }
    END { if (latest != "") print latest }
  ' "$log_path"
}

completed_cycle_pnl_series() {
  local log_path="$1"
  awk -v future_limit="$FUTURE_EVENT_LIMIT" "$AWK_EVENT_TIME"'
    function valid_number(value) {
      return value ~ /^-?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/
    }
    {
      message = ""
      stable = ""
      completed = ""
      cycle = ""
      fallback_cycle = ""
      real_pnl = ""
      for (i = 1; i <= NF; i++) {
        equals = index($i, "=")
        if (equals == 0) continue
        key = substr($i, 1, equals - 1)
        value = substr($i, equals + 1)
        gsub(/^"|"$/, "", value)
        if (key == "msg") message = value
        if (key == "stable") stable = value
        if (key == "cycle_completed") completed = value
        if (key == "session_cycle") cycle = value
        if (key == "cycles_completed") fallback_cycle = value
        if (key == "real_pnl_usdt") real_pnl = value
      }
      if (cycle == "") cycle = fallback_cycle
      if (message != "pnl_status" || stable != "true" ||
          completed != "true" || cycle !~ /^[0-9]+$/ ||
          !valid_number(real_pnl) || !event_time_trusted()) {
        next
      }
      if (!(cycle in seen)) {
        seen[cycle] = 1
        order[++count] = cycle
      }
      pnl[cycle] = real_pnl
    }
    END {
      for (i = 1; i <= count; i++) {
        cycle = order[i]
        print cycle "\t" pnl[cycle]
      }
    }
  ' "$log_path"
}

mapped_executor_volumes() {
  local log_path="$1"
  local latest_line volume_snapshot
  latest_line="$(latest_pnl_line "$log_path" 0 1)"
  volume_snapshot="$(logfmt_value "$latest_line" volume_usd_by_executor)"

  awk -v mapping="$TQ_EXECUTOR_MAP" -v snapshot="$volume_snapshot" \
      -v future_limit="$FUTURE_EVENT_LIMIT" "$AWK_EVENT_TIME"'
    function valid_number(value) {
      return value ~ /^-?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/
    }
    function format_number(value, formatted) {
      formatted = sprintf("%.10f", value)
      sub(/0+$/, "", formatted)
      sub(/[.]$/, "", formatted)
      return formatted == "" ? "0" : formatted
    }
    BEGIN {
      mapping_count = split(mapping, mapping_entries, ",")
      for (i = 1; i <= mapping_count; i++) {
        equals = index(mapping_entries[i], "=")
        executor = substr(mapping_entries[i], 1, equals - 1)
        exchange = substr(mapping_entries[i], equals + 1)
        executor_exchange[executor] = exchange
        if (!(exchange in exchange_seen)) {
          exchange_seen[exchange] = 1
          exchange_order[++exchange_count] = exchange
        }
      }

      if (snapshot != "") {
        snapshot_count = split(snapshot, snapshot_entries, ",")
        for (i = 1; i <= snapshot_count; i++) {
          colon = index(snapshot_entries[i], ":")
          executor = substr(snapshot_entries[i], 1, colon - 1)
          volume = substr(snapshot_entries[i], colon + 1)
          exchange = executor_exchange[executor]
          if (colon > 1 && exchange != "" && valid_number(volume) && volume + 0 >= 0) {
            exchange_volume[exchange] += volume
          }
        }
        for (i = 1; i <= exchange_count; i++) {
          exchange = exchange_order[i]
          print exchange "\t" format_number(exchange_volume[exchange] + 0)
        }
        exit
      }
    }
    {
      message = ""
      executor = ""
      volume_usd = ""
      for (i = 1; i <= NF; i++) {
        equals = index($i, "=")
        if (equals == 0) continue
        key = substr($i, 1, equals - 1)
        value = substr($i, equals + 1)
        gsub(/^"|"$/, "", value)
        if (key == "msg") message = value
        if (key == "executor") executor = value
        if (key == "volume_usd") volume_usd = value
      }

      if (message != "trade_status" || !valid_number(volume_usd) ||
          volume_usd + 0 < 0 || !event_time_trusted()) {
        next
      }

      exchange = executor_exchange[executor]
      if (exchange != "") {
        exchange_volume[exchange] += volume_usd
      }
    }
    END {
      if (snapshot != "") exit
      for (i = 1; i <= exchange_count; i++) {
        exchange = exchange_order[i]
        print exchange "\t" format_number(exchange_volume[exchange] + 0)
      }
    }
  ' "$log_path"
}

latest_position_snapshot() {
  local log_path="$1"
  awk -v mapping="$TQ_EXECUTOR_MAP" '
    function valid_number(value) {
      return value ~ /^-?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/
    }
    function normalize_side(value) {
      if (value == "Long") return "long"
      if (value == "Short") return "short"
      if (value == "Flat") return "flat"
      return ""
    }
    BEGIN {
      mapping_count = split(mapping, mapping_entries, ",")
      for (i = 1; i <= mapping_count; i++) {
        equals = index(mapping_entries[i], "=")
        executor = substr(mapping_entries[i], 1, equals - 1)
        mapped_executor[executor] = 1
      }
    }
    {
      projection = ""
      sample_time = ""
      initiator_venue = ""
      initiator_side = ""
      initiator_qty = ""
      carrier_venue = ""
      carrier_side = ""
      carrier_qty = ""

      for (i = 1; i <= NF; i++) {
        equals = index($i, "=")
        if (equals == 0) continue
        key = substr($i, 1, equals - 1)
        value = substr($i, equals + 1)
        gsub(/^"|"$/, "", value)
        if (key == "time") sample_time = value
        if (key == "portfolio_projection") projection = value
        if (key == "initiator_venue") initiator_venue = value
        if (key == "initiator_side") initiator_side = normalize_side(value)
        if (key == "initiator_qty_btc") initiator_qty = value
        if (key == "carrier_venue") carrier_venue = value
        if (key == "carrier_side") carrier_side = normalize_side(value)
        if (key == "carrier_qty_btc") carrier_qty = value
      }

      if (projection != "coordinator_book" ||
          !mapped_executor[initiator_venue] || !mapped_executor[carrier_venue] ||
          initiator_side == "" || carrier_side == "" ||
          !valid_number(initiator_qty) || !valid_number(carrier_qty) ||
          initiator_qty + 0 < 0 || carrier_qty + 0 < 0) {
        next
      }

      # The "-" placeholder keeps the columns stable: tab is IFS whitespace, so
      # read would otherwise shift every field when an event has no time.
      latest = NR "\t" (sample_time == "" ? "-" : sample_time) "\t" \
        initiator_venue "\t" initiator_side "\t" initiator_qty "\t" \
        carrier_venue "\t" carrier_side "\t" carrier_qty
    }
    END { if (latest != "") print latest }
  ' "$log_path"
}

latest_net_position_snapshot() {
  local log_path="$1"
  awk '
    function valid_number(value) {
      return value ~ /^-?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/
    }
    function normalize_side(value) {
      if (value == "Long") return "long"
      if (value == "Short") return "short"
      if (value == "Flat") return "flat"
      return ""
    }
    {
      projection = ""
      sample_time = ""
      net_side = ""
      net_qty = ""
      for (i = 1; i <= NF; i++) {
        equals = index($i, "=")
        if (equals == 0) continue
        key = substr($i, 1, equals - 1)
        value = substr($i, equals + 1)
        gsub(/^"|"$/, "", value)
        if (key == "time") sample_time = value
        if (key == "portfolio_projection") projection = value
        if (key == "net_side") net_side = normalize_side(value)
        if (key == "net_qty_btc") net_qty = value
      }
      if (projection == "coordinator_book" && net_side != "" &&
          valid_number(net_qty) && net_qty + 0 >= 0) {
        latest = NR "\t" (sample_time == "" ? "-" : sample_time) "\t" net_side "\t" net_qty
      }
    }
    END { if (latest != "") print latest }
  ' "$log_path"
}

logfmt_value() {
  local line="$1"
  local wanted="$2"
  awk -v wanted="$wanted" '
    {
      for (i = 1; i <= NF; i++) {
        equals = index($i, "=")
        if (equals == 0 || substr($i, 1, equals - 1) != wanted) {
          continue
        }
        value = substr($i, equals + 1)
        gsub(/^"|"$/, "", value)
        print value
        exit
      }
    }
  ' <<<"$line"
}

exchange_for_executor() {
  local wanted="$1"
  local entry executor exchange
  local old_ifs="$IFS"
  IFS=','
  for entry in $TQ_EXECUTOR_MAP; do
    executor="${entry%%=*}"
    exchange="${entry#*=}"
    if [[ "$executor" == "$wanted" ]]; then
      printf '%s\n' "$exchange"
      IFS="$old_ifs"
      return 0
    fi
  done
  IFS="$old_ifs"
  return 1
}

executor_map_size() {
  awk -F, '{ print NF }' <<<"$TQ_EXECUTOR_MAP"
}

first_mapped_exchange() {
  local first_entry="${TQ_EXECUTOR_MAP%%,*}"
  printf '%s\n' "${first_entry#*=}"
}

signed_position() {
  local side="$1"
  local quantity="$2"
  awk -v side="$side" -v quantity="$quantity" 'BEGIN {
    if (side == "short") quantity = -quantity
    if (side == "flat") quantity = 0
    printf "%.10f", quantity
  }' | sed -E 's/0+$//; s/[.]$//; s/^-0$/0/'
}

sum_signed_position_series() {
  awk -F '\t' '
    $2 == "long" { total += $3 }
    $2 == "short" { total -= $3 }
    END {
      formatted = sprintf("%.10f", total)
      sub(/0+$/, "", formatted)
      sub(/[.]$/, "", formatted)
      if (formatted == "" || formatted == "-0") formatted = "0"
      print formatted
    }
  '
}

config_instance_id() {
  sed -nE "s/^[[:space:]]*instance_id:[[:space:]]*['\"]?([^'\"#[:space:]]+)['\"]?.*$/\\1/p" \
    "$TQ_CONFIG_PATH" | head -n 1
}

sidecar_identity_field() {
  local key="$1"
  [[ -f "$TQ_SIDECAR_IDENTITY_FILE" ]] || return 0
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' \
    "$TQ_SIDECAR_IDENTITY_FILE"
}

process_has_pid() {
  local expected="$1"
  local pid
  for pid in "${PROCESS_PIDS[@]}"; do
    [[ "$pid" == "$expected" ]] && return 0
  done
  return 1
}

normalize_reason() {
  case "$1" in
    max_cycles_complete|reduce_only_complete|risk_halt|max_cycles_drain_failed)
      printf '%s\n' "$1"
      ;;
    *)
      printf 'unknown\n'
      ;;
  esac
}

is_future_epoch() {
  [[ "$1" -gt "$FUTURE_EVENT_LIMIT" ]]
}

# Prints the event time as epoch seconds, or nothing when it is absent or
# unparsable. A future time fails: the caller must not publish that sample.
position_sample_epoch() {
  local epoch
  [[ "$1" != "-" ]] || return 0
  epoch="$(timestamp_to_epoch "$1" || true)"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 0
  ! is_future_epoch "$epoch" || return 1
  printf '%s\n' "$epoch"
}

# An older net must never mask newer venues. The producer writes net and venues on
# one line, so a shared line is the normal case and net stands there, exactly as
# printed. Venues decide only if that line contradicts itself. Each quantity is
# printed to 8 decimals, so a consistent line can still differ by rounding.
net_position_applies() {
  local net_line="$1"
  local net_btc="$2"
  [[ "$net_line" -ge "$VENUE_POSITION_LINE" ]] || return 1
  [[ "$net_line" -eq "$VENUE_POSITION_LINE" ]] || return 0
  awk -v net="$net_btc" -v venues="$CURRENT_NET_POSITION_BTC" 'BEGIN {
    difference = net - venues
    if (difference < 0) difference = -difference
    exit !(difference < 0.00000002)
  }'
}

# ps -o comm= reports argv[0] on macOS, so the running image comes from /proc
# or lsof. An empty result means the image could not be read.
process_executable() {
  local pid="$1"
  local path=""
  if [[ -e /proc/self/exe ]]; then
    path="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
    path="${path% (deleted)}"
  elif command -v lsof >/dev/null 2>&1; then
    path="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | awk '/^n/ { print substr($0, 2); exit }' || true)"
  fi
  printf '%s\n' "$path"
}

process_start_epoch() {
  local pid="$1"
  local started result
  started="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null | sed -E 's/[[:space:]]+$//' || true)"
  [[ -n "$started" ]] || return 1
  if result="$(LC_ALL=C TZ=UTC date -j -f '%a %b %e %T %Y' "$started" '+%s' 2>/dev/null)"; then
    printf '%s\n' "$result"
    return 0
  fi
  LC_ALL=C TZ=UTC date -d "$started" '+%s' 2>/dev/null
}

# A manifest PID alone cannot tell the recorded process from a later one that
# reused the number, so the OS start time must agree with process_started_at.
manifest_process_start_matches() {
  local recorded actual drift
  recorded="$(timestamp_to_epoch "$MANIFEST_PROCESS_STARTED_AT" || true)"
  actual="$(process_start_epoch "$MANIFEST_PID" || true)"
  [[ "$recorded" =~ ^[0-9]+$ && "$actual" =~ ^[0-9]+$ ]] || return 1
  drift=$((actual - recorded))
  [[ "$drift" -ge 0 ]] || drift=$((-drift))
  [[ "$drift" -le "$MAX_PROCESS_START_DRIFT_SECONDS" ]]
}

# A safe reason is a claim, not proof. long_btc and short_btc are non-negative
# amounts and net_btc is signed, so each is compared by magnitude. phase names the
# engine stage: reduce_only_complete can end in several, and only
# max_cycles_complete has a fixed one. A zero tolerance is valid when all are zero.
safe_marker_consistent() {
  local completed started
  jq -e '
    def magnitude: if . < 0 then -. else . end;
    ((.error // "") == "") and
    (.phase | length) > 0 and
    (.reason != "max_cycles_complete" or .phase == "max_cycles_complete") and
    .dust_tolerance_btc >= 0 and
    (.long_btc | magnitude) <= .dust_tolerance_btc and
    (.short_btc | magnitude) <= .dust_tolerance_btc and
    (.net_btc | magnitude) <= .dust_tolerance_btc
  ' "$TQ_DONE_MARKER" >/dev/null 2>&1 || return 1
  completed="$(timestamp_to_epoch "$(jq -r '.completed_at' "$TQ_DONE_MARKER")" || true)"
  [[ "$completed" =~ ^[0-9]+$ ]] || return 1
  ! is_future_epoch "$completed" || return 1
  started="$(timestamp_to_epoch "$MANIFEST_PROCESS_STARTED_AT" || true)"
  [[ "$started" =~ ^[0-9]+$ ]] || return 1
  [[ "$completed" -ge "$started" ]]
}

emit_gauge() {
  local metric="$1"
  local help="$2"
  local value="$3"
  printf '# HELP %s %s\n' "$metric" "$help"
  printf '# TYPE %s gauge\n' "$metric"
  printf '%s{%s} %s\n' "$metric" "$METRIC_LABELS" "$value"
}

for required_name in \
  TQ_PRODUCT \
  TQ_ENVIRONMENT \
  TQ_SERVER_ID \
  TQ_STRATEGY \
  TQ_INSTANCE_ID \
  TQ_REPO_ROOT \
  TQ_CONFIG_PATH \
  TQ_RAW_LOG_GLOB \
  TQ_RUN_MANIFEST \
  TQ_DONE_MARKER \
  TQ_POC_RUN_EXPECTED \
  TQ_REQUIRE_RUNTIME_CONTRACT \
  TQ_TIMEZONE \
  TQ_TEXTFILE_DIR
do
  require_env "$required_name"
done

for command_name in awk date find jq mktemp ps sed shasum sort stat
do
  require_command "$command_name"
done

for label_value in \
  "$TQ_PRODUCT" \
  "$TQ_ENVIRONMENT" \
  "$TQ_SERVER_ID" \
  "$TQ_STRATEGY" \
  "$TQ_INSTANCE_ID"
do
  valid_label_value "$label_value" || die "invalid label or identity value: $label_value"
done

case "$TQ_ENVIRONMENT" in
  development|production) ;;
  *) die "TQ_ENVIRONMENT must be development or production" ;;
esac

case "$TQ_POC_RUN_EXPECTED" in
  0|1) ;;
  *) die "TQ_POC_RUN_EXPECTED must be 0 or 1" ;;
esac

case "$TQ_REQUIRE_RUNTIME_CONTRACT" in
  0|1) ;;
  *) die "TQ_REQUIRE_RUNTIME_CONTRACT must be 0 or 1" ;;
esac

TQ_EXECUTOR_MAP="${TQ_EXECUTOR_MAP:-toobit-main=toobit,mexc-ui=mexc}"
TQ_SIDECAR_REQUIRED="${TQ_SIDECAR_REQUIRED:-1}"
TQ_TEXTFILE_MODE="${TQ_TEXTFILE_MODE:-600}"
TQ_TEXTFILE_NAME="${TQ_TEXTFILE_NAME:-tnauqquant.prom}"

case "$TQ_SIDECAR_REQUIRED" in
  0|1) ;;
  *) die "TQ_SIDECAR_REQUIRED must be 0 or 1" ;;
esac

case "$TQ_TEXTFILE_MODE" in
  600|640) ;;
  *) die "TQ_TEXTFILE_MODE must be 600 or 640" ;;
esac

[[ "$TQ_TEXTFILE_NAME" =~ ^(tnauqquant|tnauqquant-[A-Za-z0-9][A-Za-z0-9_.-]*)[.]prom$ ]] || \
  die "TQ_TEXTFILE_NAME must be a safe tnauqquant .prom basename"
[[ "$TQ_TEXTFILE_NAME" != *..* ]] || die "TQ_TEXTFILE_NAME must not contain '..'"

executor_entries=()
old_ifs="$IFS"
IFS=',' read -r -a executor_entries <<<"$TQ_EXECUTOR_MAP"
IFS="$old_ifs"
[[ "${#executor_entries[@]}" -gt 0 ]] || die "TQ_EXECUTOR_MAP must not be empty"
seen_executors=","
for executor_entry in "${executor_entries[@]}"; do
  [[ "$executor_entry" == *=* ]] || die "invalid TQ_EXECUTOR_MAP entry: $executor_entry"
  executor_name="${executor_entry%%=*}"
  exchange_name="${executor_entry#*=}"
  valid_label_value "$executor_name" || die "invalid executor name: $executor_name"
  valid_label_value "$exchange_name" || die "invalid exchange label: $exchange_name"
  [[ "$seen_executors" != *",$executor_name,"* ]] || die "duplicate executor mapping: $executor_name"
  seen_executors+="$executor_name,"
done

[[ "$TQ_TIMEZONE" =~ ^[A-Za-z0-9_+./-]+$ ]] || die "invalid TQ_TIMEZONE"

for absolute_path in \
  "$TQ_REPO_ROOT" \
  "$TQ_CONFIG_PATH" \
  "$TQ_RAW_LOG_GLOB" \
  "$TQ_RUN_MANIFEST" \
  "$TQ_DONE_MARKER" \
  "$TQ_TEXTFILE_DIR"
do
  [[ "$absolute_path" == /* ]] || die "path must be absolute: $absolute_path"
  [[ "$absolute_path" != *[[:space:]]* ]] || die "whitespace in monitored paths is not supported"
done

[[ -d "$TQ_REPO_ROOT" ]] || die "repo root not found: $TQ_REPO_ROOT"
[[ -f "$TQ_CONFIG_PATH" ]] || die "config not found: $TQ_CONFIG_PATH"

TQ_EXECUTABLE="${TQ_EXECUTABLE:-$TQ_REPO_ROOT/quant}"
TQ_SIDECAR_SESSION="${TQ_SIDECAR_SESSION:-goexchange-sidecar}"
TQ_SIDECAR_IDENTITY_FILE="${TQ_SIDECAR_IDENTITY_FILE:-$TQ_REPO_ROOT/logs/sidecar-runtime.identity}"
TQ_SIDECAR_HEALTH_URL="${TQ_SIDECAR_HEALTH_URL:-http://127.0.0.1:3457/health}"
TQ_TMUX_PATH="${TQ_TMUX_PATH:-$(command -v tmux || true)}"
TQ_CURL_PATH="${TQ_CURL_PATH:-$(command -v curl || true)}"
[[ -n "$TQ_TMUX_PATH" ]] || [[ ! -x /opt/homebrew/bin/tmux ]] || TQ_TMUX_PATH=/opt/homebrew/bin/tmux
[[ -n "$TQ_CURL_PATH" ]] || [[ ! -x /usr/bin/curl ]] || TQ_CURL_PATH=/usr/bin/curl

[[ "$TQ_EXECUTABLE" == /* ]] || die "TQ_EXECUTABLE must be absolute"
[[ "$TQ_CONFIG_PATH" == "$TQ_REPO_ROOT/"* ]] || \
  die "TQ_CONFIG_PATH must be inside TQ_REPO_ROOT"

CONFIG_REL="${TQ_CONFIG_PATH#"$TQ_REPO_ROOT"/}"
CONFIG_STEM="$(basename "$TQ_CONFIG_PATH")"
CONFIG_STEM="${CONFIG_STEM%.*}"
CONFIG_SHA256="$(shasum -a 256 "$TQ_CONFIG_PATH" | awk '{print $1}')"
ACTUAL_INSTANCE_ID="$(config_instance_id)"

# Sample timestamps ahead of this clock by more than the allowance are rejected.
MAX_FUTURE_SKEW_SECONDS=120
MAX_PROCESS_START_DRIFT_SECONDS=10
PROBE_NOW="$(date +%s)"
FUTURE_EVENT_LIMIT=$((PROBE_NOW + MAX_FUTURE_SKEW_SECONDS))

# A failed or implausible listing is unknown, never zero processes. Exiting here
# leaves the old textfile in place, so the frozen probe timestamp raises
# TradingTelemetryMissing instead of a false ProcessDown or a hidden duplicate.
PROCESS_LISTING="$(ps -axo pid=,command=)" || die "process listing failed"
awk -v self="$$" '
  $1 == 1 { saw_init = 1 }
  $1 == self { saw_self = 1 }
  END { exit !(saw_init && saw_self) }
' <<<"$PROCESS_LISTING" || die "process listing is incomplete"

CONFIG_MATCHED_PIDS="$(awk -v config_abs="$TQ_CONFIG_PATH" -v config_rel="$CONFIG_REL" '
  {
    for (i = 2; i <= NF; i++) {
      value = ""
      if (($i == "-config" || $i == "--config") && i < NF) value = $(i + 1)
      else if (index($i, "-config=") == 1) value = substr($i, 9)
      else if (index($i, "--config=") == 1) value = substr($i, 10)
      if (substr(value, 1, 2) == "./") value = substr(value, 3)
      if (value != "" && (value == config_abs || value == config_rel)) {
        print $1
        next
      }
    }
  }
' <<<"$PROCESS_LISTING")"

EXECUTABLE_REAL="$(readlink -f "$TQ_EXECUTABLE" 2>/dev/null || printf '%s' "$TQ_EXECUTABLE")"
PROCESS_PIDS=()
while IFS= read -r process_pid; do
  [[ -n "$process_pid" ]] || continue
  process_path="$(process_executable "$process_pid")"
  # An unreadable image stays counted: hiding a live process is the unsafe side.
  if [[ -z "$process_path" || "$process_path" == "$TQ_EXECUTABLE" ||
        "$process_path" == "$EXECUTABLE_REAL" ]]
  then
    PROCESS_PIDS+=("$process_pid")
  fi
done <<<"$CONFIG_MATCHED_PIDS"
PROCESS_COUNT="${#PROCESS_PIDS[@]}"

LATEST_LOG=""
LATEST_LOG_MTIME=0
while IFS= read -r log_candidate; do
  [[ -n "$log_candidate" ]] || continue
  [[ -f "$log_candidate" ]] || continue
  candidate_mtime="$(file_mtime "$log_candidate")"
  if [[ "$candidate_mtime" -gt "$LATEST_LOG_MTIME" ]]; then
    LATEST_LOG="$log_candidate"
    LATEST_LOG_MTIME="$candidate_mtime"
  fi
done <<EOF
$(compgen -G "$TQ_RAW_LOG_GLOB" || true)
EOF

RUNTIME_CONTRACT_AVAILABLE=0
PROCESS_IDENTITY_OK=0
STRATEGY_IDENTITY_OK=0
CONFIG_SNAPSHOT_MATCH=0
LOG_BINDING_OK=0
MARKER_BINDING_OK=0
RUN_EXPECTED="$TQ_POC_RUN_EXPECTED"
DONE_REASON=""
CURRENT_RUN_ID=""
CURRENT_RUN_STARTED_TIMESTAMP=""
CURRENT_PNL_VALID=0
CURRENT_REAL_PNL=""
CURRENT_EQUITY=""
CURRENT_CASH_PNL=""
CURRENT_REBATE=""
CURRENT_RISK_PNL=""
CURRENT_CYCLES_COMPLETED=""
PNL_SAMPLE_TIMESTAMP=""
LAST_COMPLETED_CYCLE_TIMESTAMP=""
LAST_COMPLETED_CYCLE_REAL_PNL=""
COMPLETED_CYCLE_PNL_SERIES=""
CURRENT_POSITION_VALID=0
CURRENT_POSITION_SERIES=""
CURRENT_NET_POSITION_BTC=""
VENUE_POSITION_LINE=0
VENUE_POSITION_TIMESTAMP=""
NET_POSITION_TIMESTAMP=""
CURRENT_EXCHANGE_VOLUMES=""
RISK_STOPPED=0

if [[ "$ACTUAL_INSTANCE_ID" == "$TQ_INSTANCE_ID" ]]; then
  STRATEGY_IDENTITY_OK=1
fi

if [[ "$TQ_REQUIRE_RUNTIME_CONTRACT" -eq 0 && "$PROCESS_COUNT" -eq 1 ]]; then
  PROCESS_IDENTITY_OK=1
fi

if [[ "$TQ_REQUIRE_RUNTIME_CONTRACT" -eq 0 && -n "$LATEST_LOG" &&
      "$(basename "$LATEST_LOG")" == *"_$CONFIG_STEM.raw.log" ]]
then
  LOG_BINDING_OK=1
fi

if [[ -f "$TQ_RUN_MANIFEST" ]]; then
  RUNTIME_CONTRACT_AVAILABLE=1
  PROCESS_IDENTITY_OK=0
  LOG_BINDING_OK=0
  MARKER_BINDING_OK=0
  RUN_EXPECTED=1

  MANIFEST_VALID=0
  if jq -e '
      .schema_version == 1 and
      (.run_id | type) == "string" and
      (.strategy | type) == "string" and
      (.instance_id | type) == "string" and
      (.pid | type) == "number" and .pid > 0 and
      (.config_sha256 | type) == "string" and
      (.process_started_at | type) == "string" and
      (.executable | type) == "string" and (.executable | startswith("/")) and
      (.config_path | type) == "string" and (.config_path | startswith("/")) and
      (.log_path | type) == "string" and (.log_path | startswith("/")) and
      (.done_marker_path | type) == "string" and (.done_marker_path | startswith("/")) and
      .state == "running"
    ' "$TQ_RUN_MANIFEST" >/dev/null 2>&1
  then
    MANIFEST_RUN_ID="$(jq -r '.run_id' "$TQ_RUN_MANIFEST")"
    MANIFEST_STRATEGY="$(jq -r '.strategy' "$TQ_RUN_MANIFEST")"
    MANIFEST_INSTANCE_ID="$(jq -r '.instance_id' "$TQ_RUN_MANIFEST")"
    MANIFEST_PID="$(jq -r '.pid' "$TQ_RUN_MANIFEST")"
    MANIFEST_CONFIG_SHA256="$(jq -r '.config_sha256' "$TQ_RUN_MANIFEST")"
    MANIFEST_PROCESS_STARTED_AT="$(jq -r '.process_started_at' "$TQ_RUN_MANIFEST")"
    MANIFEST_EXECUTABLE="$(jq -r '.executable' "$TQ_RUN_MANIFEST")"
    MANIFEST_CONFIG_PATH="$(jq -r '.config_path' "$TQ_RUN_MANIFEST")"
    MANIFEST_LOG_PATH="$(jq -r '.log_path' "$TQ_RUN_MANIFEST")"
    MANIFEST_DONE_MARKER_PATH="$(jq -r '.done_marker_path' "$TQ_RUN_MANIFEST")"

    if [[ "$MANIFEST_RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] &&
       [[ "$MANIFEST_STRATEGY" == "$TQ_STRATEGY" ]] &&
       [[ "$MANIFEST_INSTANCE_ID" == "$TQ_INSTANCE_ID" ]] &&
       [[ "$MANIFEST_INSTANCE_ID" == "$ACTUAL_INSTANCE_ID" ]] &&
       [[ "$MANIFEST_CONFIG_SHA256" =~ ^[0-9a-f]{64}$ ]] &&
       [[ "$MANIFEST_EXECUTABLE" == "$TQ_EXECUTABLE" ]] &&
       [[ "$MANIFEST_CONFIG_PATH" == "$TQ_CONFIG_PATH" ]] &&
       [[ "$MANIFEST_DONE_MARKER_PATH" == "$TQ_DONE_MARKER" ]]
    then
      MANIFEST_VALID=1
      STRATEGY_IDENTITY_OK=1
      if [[ "$MANIFEST_CONFIG_SHA256" == "$CONFIG_SHA256" ]]; then
        CONFIG_SNAPSHOT_MATCH=1
      fi
    fi
  fi

  if [[ "$MANIFEST_VALID" -eq 1 ]]; then
    if [[ "$PROCESS_COUNT" -eq 0 ]]; then
      PROCESS_IDENTITY_OK=1
    elif process_has_pid "$MANIFEST_PID" && manifest_process_start_matches; then
      PROCESS_IDENTITY_OK=1
    fi

    if [[ -f "$MANIFEST_LOG_PATH" ]] &&
       [[ "$(basename "$MANIFEST_LOG_PATH")" == "$MANIFEST_RUN_ID.raw.log" ]]
    then
      LOG_BINDING_OK=1
      LATEST_LOG_MTIME="$(file_mtime "$MANIFEST_LOG_PATH")"
      CURRENT_RUN_ID="$MANIFEST_RUN_ID"
      CURRENT_RUN_STARTED_TIMESTAMP="$(timestamp_to_epoch "$MANIFEST_PROCESS_STARTED_AT" || true)"
      COMPLETED_CYCLE_PNL_SERIES="$(completed_cycle_pnl_series "$MANIFEST_LOG_PATH")"
      CURRENT_EXCHANGE_VOLUMES="$(mapped_executor_volumes "$MANIFEST_LOG_PATH")"

      # Unfiltered on purpose: a value called current must not fall back to an older
      # event, so a future newest line invalidates it instead.
      CURRENT_PNL_LINE="$(latest_pnl_line "$MANIFEST_LOG_PATH" 0)"
      if [[ -n "$CURRENT_PNL_LINE" ]]; then
        current_pnl_time="$(logfmt_value "$CURRENT_PNL_LINE" time)"
        current_real_pnl="$(logfmt_value "$CURRENT_PNL_LINE" real_pnl_usdt)"
        current_pnl_timestamp="$(timestamp_to_epoch "$current_pnl_time" || true)"
        # Read before validity: a rejected sample must not hide a reported risk stop.
        current_risk_stopped="$(logfmt_value "$CURRENT_PNL_LINE" risk_stopped)"
        [[ "$current_risk_stopped" == "true" ]] && RISK_STOPPED=1
        if is_number "$current_real_pnl" && [[ "$current_pnl_timestamp" =~ ^[0-9]+$ ]] &&
           ! is_future_epoch "$current_pnl_timestamp"
        then
          CURRENT_PNL_VALID=1
          CURRENT_REAL_PNL="$current_real_pnl"
          PNL_SAMPLE_TIMESTAMP="$current_pnl_timestamp"
          # The producer already sums all executor accounts in this stable snapshot.
          current_equity="$(logfmt_value "$CURRENT_PNL_LINE" equity_now)"
          current_cash_pnl="$(logfmt_value "$CURRENT_PNL_LINE" cash_pnl_usdt)"
          current_rebate="$(logfmt_value "$CURRENT_PNL_LINE" rebate_usdt)"
          current_risk_pnl="$(logfmt_value "$CURRENT_PNL_LINE" risk_pnl_usdt)"
          current_cycles_completed="$(logfmt_value "$CURRENT_PNL_LINE" cycles_completed)"
          is_number "$current_equity" && CURRENT_EQUITY="$current_equity"
          is_number "$current_cash_pnl" && CURRENT_CASH_PNL="$current_cash_pnl"
          is_number "$current_rebate" && CURRENT_REBATE="$current_rebate"
          is_number "$current_risk_pnl" && CURRENT_RISK_PNL="$current_risk_pnl"
          is_number "$current_cycles_completed" && CURRENT_CYCLES_COMPLETED="$current_cycles_completed"
        fi
      fi

      LAST_COMPLETED_LINE="$(latest_pnl_line "$MANIFEST_LOG_PATH" 1 1)"
      if [[ -n "$LAST_COMPLETED_LINE" ]]; then
        last_completed_time="$(logfmt_value "$LAST_COMPLETED_LINE" time)"
        LAST_COMPLETED_CYCLE_TIMESTAMP="$(timestamp_to_epoch "$last_completed_time" || true)"
        last_completed_cycle_real_pnl="$(logfmt_value "$LAST_COMPLETED_LINE" cycle_real_pnl_usdt)"
        is_number "$last_completed_cycle_real_pnl" && \
          LAST_COMPLETED_CYCLE_REAL_PNL="$last_completed_cycle_real_pnl"
      fi

      POSITION_SNAPSHOT="$(latest_position_snapshot "$MANIFEST_LOG_PATH")"
      if [[ -n "$POSITION_SNAPSHOT" ]]; then
        IFS=$'\t' read -r \
          current_venue_line \
          current_venue_time \
          current_initiator_venue \
          current_initiator_side \
          current_initiator_qty \
          current_carrier_venue \
          current_carrier_side \
          current_carrier_qty <<<"$POSITION_SNAPSHOT"

        current_initiator_exchange="$(exchange_for_executor "$current_initiator_venue" || true)"
        current_carrier_exchange="$(exchange_for_executor "$current_carrier_venue" || true)"
        if [[ -n "$current_initiator_exchange" && -n "$current_carrier_exchange" ]] &&
           is_number "$current_initiator_qty" &&
           is_number "$current_carrier_qty" &&
           [[ "$current_initiator_side" =~ ^(long|short|flat)$ ]] &&
           [[ "$current_carrier_side" =~ ^(long|short|flat)$ ]] &&
           VENUE_POSITION_TIMESTAMP="$(position_sample_epoch "$current_venue_time")"
        then
          CURRENT_POSITION_VALID=1
          VENUE_POSITION_LINE="$current_venue_line"
          CURRENT_POSITION_SERIES="$(printf '%s\t%s\t%s\n%s\t%s\t%s\n' \
            "$current_initiator_exchange" "$current_initiator_side" "$current_initiator_qty" \
            "$current_carrier_exchange" "$current_carrier_side" "$current_carrier_qty")"
          CURRENT_NET_POSITION_BTC="$(sum_signed_position_series <<<"$CURRENT_POSITION_SERIES")"
        fi
      fi

      NET_POSITION_SNAPSHOT="$(latest_net_position_snapshot "$MANIFEST_LOG_PATH")"
      if [[ -n "$NET_POSITION_SNAPSHOT" ]]; then
        IFS=$'\t' read -r current_net_line current_net_time current_net_side current_net_qty \
          <<<"$NET_POSITION_SNAPSHOT"
        if [[ "$current_net_side" =~ ^(long|short|flat)$ ]] && is_number "$current_net_qty" &&
           net_position_applies "$current_net_line" \
             "$(signed_position "$current_net_side" "$current_net_qty")" &&
           NET_POSITION_TIMESTAMP="$(position_sample_epoch "$current_net_time")"
        then
          CURRENT_POSITION_VALID=1
          CURRENT_NET_POSITION_BTC="$(signed_position "$current_net_side" "$current_net_qty")"
          if [[ "$(executor_map_size)" -eq 1 ]]; then
            CURRENT_POSITION_SERIES="$(printf '%s\t%s\t%s\n' \
              "$(first_mapped_exchange)" "$current_net_side" "$current_net_qty")"
          fi
        fi
      fi
    fi

    if [[ ! -e "$TQ_DONE_MARKER" ]]; then
      MARKER_BINDING_OK=1
    elif jq -e '
        .schema_version == 1 and
        (.run_id | type) == "string" and
        (.strategy | type) == "string" and
        (.instance_id | type) == "string" and
        (.pid | type) == "number" and .pid > 0 and
        (.config_sha256 | type) == "string" and
        (.reason | type) == "string" and
        (.phase | type) == "string" and
        (.completed_at | type) == "string" and
        (.long_btc | type) == "number" and
        (.short_btc | type) == "number" and
        (.net_btc | type) == "number" and
        (.dust_tolerance_btc | type) == "number" and
        ((.error == null) or ((.error | type) == "string"))
      ' "$TQ_DONE_MARKER" >/dev/null 2>&1
    then
      MARKER_RUN_ID="$(jq -r '.run_id' "$TQ_DONE_MARKER")"
      MARKER_STRATEGY="$(jq -r '.strategy' "$TQ_DONE_MARKER")"
      MARKER_INSTANCE_ID="$(jq -r '.instance_id' "$TQ_DONE_MARKER")"
      MARKER_PID="$(jq -r '.pid' "$TQ_DONE_MARKER")"
      MARKER_CONFIG_SHA256="$(jq -r '.config_sha256' "$TQ_DONE_MARKER")"

      if [[ "$MARKER_RUN_ID" == "$MANIFEST_RUN_ID" ]] &&
         [[ "$MARKER_STRATEGY" == "$MANIFEST_STRATEGY" ]] &&
         [[ "$MARKER_INSTANCE_ID" == "$MANIFEST_INSTANCE_ID" ]] &&
         [[ "$MARKER_PID" == "$MANIFEST_PID" ]] &&
         [[ "$MARKER_CONFIG_SHA256" == "$MANIFEST_CONFIG_SHA256" ]]
      then
        MARKER_BINDING_OK=1
        DONE_REASON="$(normalize_reason "$(jq -r '.reason' "$TQ_DONE_MARKER")")"
        case "$DONE_REASON" in
          max_cycles_complete|reduce_only_complete)
            safe_marker_consistent || DONE_REASON=unknown
            ;;
        esac
        RUN_EXPECTED=0
        PROCESS_IDENTITY_OK=1
      fi
    fi
  fi
fi

TODAY_LOCAL="$(TZ="$TQ_TIMEZONE" date +%F)"
TODAY_START_EPOCH="$(local_day_start_epoch "$TODAY_LOCAL")"
TODAY_COMPLETED_CYCLES="$({
  while IFS= read -r history_log; do
    [[ -n "$history_log" && -f "$history_log" ]] || continue
    history_mtime="$(file_mtime "$history_log")"
    [[ "$history_mtime" -ge "$TODAY_START_EPOCH" ]] || continue
    history_run_id="$(basename "$history_log")"
    history_run_id="${history_run_id%.raw.log}"
    awk -v day="$TODAY_LOCAL" -v run_id="$history_run_id" '
      {
        timestamp = ""
        message = ""
        stable = ""
        completed = ""
        cycle_id = ""
        cycles_completed = ""
        for (i = 1; i <= NF; i++) {
          equals = index($i, "=")
          if (equals == 0) continue
          key = substr($i, 1, equals - 1)
          value = substr($i, equals + 1)
          gsub(/^"|"$/, "", value)
          if (key == "time") timestamp = value
          if (key == "msg") message = value
          if (key == "stable") stable = value
          if (key == "cycle_completed") completed = value
          if (key == "cycle_id") cycle_id = value
          if (key == "cycles_completed") cycles_completed = value
        }
        if (substr(timestamp, 1, 10) == day && message == "pnl_status" &&
            stable == "true" && completed == "true") {
          if (cycle_id == "") cycle_id = timestamp ":" cycles_completed
          print run_id ":" cycle_id
        }
      }
    ' "$history_log"
  done <<EOF
$(compgen -G "$TQ_RAW_LOG_GLOB" || true)
EOF
} | sort -u | awk 'END { print NR + 0 }')"

SIDECAR_UP=0
SIDECAR_IDENTITY_OK=0
if [[ "$TQ_SIDECAR_REQUIRED" -eq 1 ]] &&
   [[ -x "$TQ_TMUX_PATH" ]] &&
   "$TQ_TMUX_PATH" has-session -t "$TQ_SIDECAR_SESSION" 2>/dev/null
then
  SIDECAR_UP=1
  recorded_session="$(sidecar_identity_field session)"
  recorded_created="$(sidecar_identity_field session_created)"
  recorded_source_root="$(sidecar_identity_field source_root)"
  recorded_source_version="$(sidecar_identity_field source_version)"
  current_created="$("$TQ_TMUX_PATH" display-message -p -t "$TQ_SIDECAR_SESSION" '#{session_created}' 2>/dev/null || true)"

  if [[ "$recorded_session" == "$TQ_SIDECAR_SESSION" ]] &&
     [[ -n "$recorded_created" ]] &&
     [[ "$recorded_created" == "$current_created" ]] &&
     [[ -n "$recorded_source_root" ]] &&
     [[ -n "$recorded_source_version" ]] &&
     [[ -x "$TQ_CURL_PATH" ]] &&
     "$TQ_CURL_PATH" -fsS --max-time 2 "$TQ_SIDECAR_HEALTH_URL" >/dev/null 2>&1
  then
    SIDECAR_IDENTITY_OK=1
  fi
fi

METRIC_LABELS="product=\"$TQ_PRODUCT\",environment=\"$TQ_ENVIRONMENT\",server_id=\"$TQ_SERVER_ID\",strategy=\"$TQ_STRATEGY\""
PROBE_TIMESTAMP="$(date +%s)"

mkdir -p "$TQ_TEXTFILE_DIR"
umask 077
metric_stem="${TQ_TEXTFILE_NAME%.prom}"
TEMP_METRICS="$(mktemp "$TQ_TEXTFILE_DIR/.$metric_stem.prom.XXXXXX")"

cleanup_temp() {
  if [[ -n "${TEMP_METRICS:-}" && -e "$TEMP_METRICS" ]]; then
    rm -f -- "$TEMP_METRICS"
  fi
}
trap cleanup_temp EXIT HUP INT TERM

{
  emit_gauge tnauqquant_process_count "Matching trading processes." "$PROCESS_COUNT"
  emit_gauge tnauqquant_run_expected "Whether the current strategy is expected to run." "$RUN_EXPECTED"
  emit_gauge tnauqquant_runtime_contract_available "Whether manifest contract v1 is present." "$RUNTIME_CONTRACT_AVAILABLE"
  emit_gauge tnauqquant_process_identity_ok "Whether process identity matches the configured run." "$PROCESS_IDENTITY_OK"
  emit_gauge tnauqquant_strategy_identity_ok "Whether strategy and instance identity match." "$STRATEGY_IDENTITY_OK"
  emit_gauge tnauqquant_config_snapshot_match "Whether the on-disk config matches the running manifest snapshot." "$CONFIG_SNAPSHOT_MATCH"
  emit_gauge tnauqquant_log_binding_ok "Whether the current log belongs to the current run." "$LOG_BINDING_OK"
  emit_gauge tnauqquant_marker_binding_ok "Whether the terminal marker belongs to the current run." "$MARKER_BINDING_OK"
  emit_gauge tnauqquant_sidecar_required "Whether this strategy requires the managed sidecar." "$TQ_SIDECAR_REQUIRED"
  emit_gauge tnauqquant_sidecar_up "Whether the managed sidecar session exists." "$SIDECAR_UP"
  emit_gauge tnauqquant_sidecar_identity_ok "Whether sidecar runtime identity and health match." "$SIDECAR_IDENTITY_OK"
  emit_gauge tnauqquant_probe_timestamp_seconds "Unix timestamp of the latest successful probe." "$PROBE_TIMESTAMP"
  emit_gauge tnauqquant_log_mtime_seconds "Unix mtime of the current bound log, or zero." "$LATEST_LOG_MTIME"
  emit_gauge tnauqquant_current_pnl_valid "Whether current-run stable PNL is available." "$CURRENT_PNL_VALID"
  emit_gauge tnauqquant_risk_stopped "Whether the latest stable current-run PNL reports a risk stop." "$RISK_STOPPED"
  emit_gauge tnauqquant_current_position_valid "Whether a current-run coordinator position snapshot is available." "$CURRENT_POSITION_VALID"
  emit_gauge tnauqquant_completed_cycles_today "Completed cycles today across all runs in the configured timezone." "$TODAY_COMPLETED_CYCLES"
  if [[ -n "$CURRENT_RUN_ID" ]]; then
    printf '# HELP tnauqquant_current_run_info Current manifest-bound run identity.\n'
    printf '# TYPE tnauqquant_current_run_info gauge\n'
    printf 'tnauqquant_current_run_info{%s,run_id="%s"} 1\n' "$METRIC_LABELS" "$CURRENT_RUN_ID"
  fi
  [[ -n "$CURRENT_RUN_STARTED_TIMESTAMP" ]] && emit_gauge tnauqquant_current_run_started_timestamp_seconds "Unix timestamp when the current run process started." "$CURRENT_RUN_STARTED_TIMESTAMP"
  [[ -n "$CURRENT_REAL_PNL" ]] && emit_gauge tnauqquant_current_real_pnl_usdt "Latest stable real PNL for the current run in USDT." "$CURRENT_REAL_PNL"
  [[ -n "$CURRENT_EQUITY" ]] && emit_gauge tnauqquant_current_equity_usdt "Total account equity across all executors in the latest stable current-run snapshot in USDT." "$CURRENT_EQUITY"
  [[ -n "$CURRENT_CASH_PNL" ]] && emit_gauge tnauqquant_current_cash_pnl_usdt "Latest stable cash PNL for the current run in USDT." "$CURRENT_CASH_PNL"
  [[ -n "$CURRENT_REBATE" ]] && emit_gauge tnauqquant_current_rebate_usdt "Latest stable rebate for the current run in USDT." "$CURRENT_REBATE"
  [[ -n "$CURRENT_RISK_PNL" ]] && emit_gauge tnauqquant_current_risk_pnl_usdt "Latest stable risk PNL for the current run in USDT." "$CURRENT_RISK_PNL"
  [[ -n "$CURRENT_CYCLES_COMPLETED" ]] && emit_gauge tnauqquant_current_cycles_completed "Completed cycles reported by the current run." "$CURRENT_CYCLES_COMPLETED"
  [[ -n "$PNL_SAMPLE_TIMESTAMP" ]] && emit_gauge tnauqquant_pnl_sample_timestamp_seconds "Unix timestamp of the latest stable current-run PNL sample." "$PNL_SAMPLE_TIMESTAMP"
  [[ -n "$LAST_COMPLETED_CYCLE_TIMESTAMP" ]] && emit_gauge tnauqquant_last_completed_cycle_timestamp_seconds "Unix timestamp of the latest completed current-run cycle." "$LAST_COMPLETED_CYCLE_TIMESTAMP"
  [[ -n "$LAST_COMPLETED_CYCLE_REAL_PNL" ]] && emit_gauge tnauqquant_last_cycle_real_pnl_usdt "Real PNL change of the latest completed current-run cycle in USDT." "$LAST_COMPLETED_CYCLE_REAL_PNL"
  if [[ -n "$COMPLETED_CYCLE_PNL_SERIES" ]]; then
    printf '# HELP tnauqquant_cycle_cumulative_real_pnl_usdt Cumulative real PNL at each completed cycle in the current manifest-bound run.\n'
    printf '# TYPE tnauqquant_cycle_cumulative_real_pnl_usdt gauge\n'
    while IFS=$'\t' read -r cycle cumulative_real_pnl; do
      printf 'tnauqquant_cycle_cumulative_real_pnl_usdt{%s,cycle="%s"} %s\n' \
        "$METRIC_LABELS" "$cycle" "$cumulative_real_pnl"
    done <<<"$COMPLETED_CYCLE_PNL_SERIES"
  fi
  if [[ -n "$CURRENT_POSITION_SERIES" ]]; then
    printf '# HELP tnauqquant_current_position_btc Latest coordinator-reported position quantity by exchange and side.\n'
    printf '# TYPE tnauqquant_current_position_btc gauge\n'
    while IFS=$'\t' read -r exchange side quantity; do
      printf 'tnauqquant_current_position_btc{%s,exchange="%s",side="%s"} %s\n' \
        "$METRIC_LABELS" "$exchange" "$side" "$quantity"
    done <<<"$CURRENT_POSITION_SERIES"
  fi
  [[ -n "$CURRENT_NET_POSITION_BTC" ]] && emit_gauge tnauqquant_current_net_position_btc "Signed net BTC position from the latest coordinator book." "$CURRENT_NET_POSITION_BTC"
  if [[ -n "$VENUE_POSITION_TIMESTAMP$NET_POSITION_TIMESTAMP" ]]; then
    printf '# HELP tnauqquant_position_sample_timestamp_seconds Unix timestamp of the position observation behind the published values, by source.\n'
    printf '# TYPE tnauqquant_position_sample_timestamp_seconds gauge\n'
    if [[ -n "$VENUE_POSITION_TIMESTAMP" ]]; then
      printf 'tnauqquant_position_sample_timestamp_seconds{%s,source="venue"} %s\n' \
        "$METRIC_LABELS" "$VENUE_POSITION_TIMESTAMP"
    fi
    if [[ -n "$NET_POSITION_TIMESTAMP" ]]; then
      printf 'tnauqquant_position_sample_timestamp_seconds{%s,source="net"} %s\n' \
        "$METRIC_LABELS" "$NET_POSITION_TIMESTAMP"
    fi
  fi
  if [[ -n "$CURRENT_EXCHANGE_VOLUMES" ]]; then
    printf '# HELP tnauqquant_current_run_exchange_volume_usd Latest stable current-run volume by mapped exchange.\n'
    printf '# TYPE tnauqquant_current_run_exchange_volume_usd gauge\n'
    while IFS=$'\t' read -r exchange volume_usd; do
      printf 'tnauqquant_current_run_exchange_volume_usd{%s,exchange="%s"} %s\n' \
        "$METRIC_LABELS" "$exchange" "$volume_usd"
    done <<<"$CURRENT_EXCHANGE_VOLUMES"
  fi
  if [[ -n "$DONE_REASON" ]]; then
    printf '# HELP tnauqquant_done_marker Bound terminal marker by normalized reason.\n'
    printf '# TYPE tnauqquant_done_marker gauge\n'
    printf 'tnauqquant_done_marker{%s,reason="%s"} 1\n' "$METRIC_LABELS" "$DONE_REASON"
  fi
} >"$TEMP_METRICS"

chmod "$TQ_TEXTFILE_MODE" "$TEMP_METRICS"
mv "$TEMP_METRICS" "$TQ_TEXTFILE_DIR/$TQ_TEXTFILE_NAME"
TEMP_METRICS=""
