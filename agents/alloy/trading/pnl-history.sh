#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'SkyEye P&L history: %s\n' "$*" >&2
  exit 1
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "$name is required"
}

file_fingerprint() {
  local path="$1"
  stat -f '%i %z %m' "$path" 2>/dev/null || stat -c '%i %s %Y' "$path"
}

rfc3339_epoch() {
  local value="$1"
  local base zone normalized
  if [[ ! "$value" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]]; then
    return 1
  fi
  base="${BASH_REMATCH[1]}"
  zone="${BASH_REMATCH[3]}"
  if [[ "$zone" == "Z" ]]; then
    zone="+0000"
  else
    zone="${zone/:/}"
  fi
  normalized="$base$zone"
  if date -j -f '%Y-%m-%dT%H:%M:%S%z' "$normalized" '+%s' 2>/dev/null; then
    return 0
  fi
  date -d "$value" '+%s' 2>/dev/null
}

local_date_for_epoch() {
  local epoch="$1"
  if TZ="$TQ_TIMEZONE" date -r "$epoch" '+%Y-%m-%d' 2>/dev/null; then
    return 0
  fi
  TZ="$TQ_TIMEZONE" date -d "@$epoch" '+%Y-%m-%d'
}

date_days_ago() {
  local date_value="$1"
  local days="$2"
  if TZ="$TQ_TIMEZONE" date -j -v-"${days}"d -f '%Y-%m-%d' "$date_value" '+%Y-%m-%d' 2>/dev/null; then
    return 0
  fi
  TZ="$TQ_TIMEZONE" date -d "$date_value - $days days" '+%Y-%m-%d'
}

date_days_after() {
  local date_value="$1"
  local days="$2"
  if TZ="$TQ_TIMEZONE" date -j -v+"${days}"d -f '%Y-%m-%d' "$date_value" '+%Y-%m-%d' 2>/dev/null; then
    return 0
  fi
  TZ="$TQ_TIMEZONE" date -d "$date_value + $days days" '+%Y-%m-%d'
}

local_midnight_epoch() {
  local date_value="$1"
  if TZ="$TQ_TIMEZONE" date -j -f '%Y-%m-%dT%H:%M:%S' \
      "${date_value}T00:00:00" '+%s' 2>/dev/null; then
    return 0
  fi
  TZ="$TQ_TIMEZONE" date -d "$date_value 00:00:00" '+%s'
}

for required_name in \
  TQ_PRODUCT \
  TQ_ENVIRONMENT \
  TQ_SERVER_ID \
  TQ_STRATEGY \
  TQ_RAW_LOG_GLOB \
  TQ_TIMEZONE \
  TQ_TEXTFILE_DIR \
  TQ_PNL_HISTORY_CACHE_DIR \
  TQ_PNL_HISTORY_DAYS \
  TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES
do
  require_env "$required_name"
done

for label_name in TQ_PRODUCT TQ_ENVIRONMENT TQ_SERVER_ID TQ_STRATEGY; do
  [[ "${!label_name}" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "invalid metric label value in $label_name"
done
[[ "$TQ_TIMEZONE" =~ ^[A-Za-z0-9_+./-]+$ ]] || die "invalid TQ_TIMEZONE"
[[ "$TQ_RAW_LOG_GLOB" == /* ]] || die "TQ_RAW_LOG_GLOB must be absolute"
[[ "$TQ_TEXTFILE_DIR" == /* ]] || die "TQ_TEXTFILE_DIR must be absolute"
[[ "$TQ_PNL_HISTORY_CACHE_DIR" == /* ]] || die "TQ_PNL_HISTORY_CACHE_DIR must be absolute"
[[ "$TQ_PNL_HISTORY_DAYS" =~ ^[0-9]+$ ]] || die "TQ_PNL_HISTORY_DAYS must be an integer"
[[ "$TQ_PNL_HISTORY_DAYS" -ge 1 && "$TQ_PNL_HISTORY_DAYS" -le 366 ]] || \
  die "TQ_PNL_HISTORY_DAYS must be between 1 and 366"
[[ "$TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES" =~ ^[0-9]+$ ]] || \
  die "TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES must be an integer"
[[ "$TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES" -ge 1 && \
   "$TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES" -le 10000 ]] || \
  die "TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES must be between 1 and 10000"

if [[ -n "${TQ_PNL_HISTORY_NOW_SECONDS:-}" ]]; then
  [[ "$TQ_PNL_HISTORY_NOW_SECONDS" =~ ^[0-9]+$ ]] || die "invalid TQ_PNL_HISTORY_NOW_SECONDS"
  now_seconds="$TQ_PNL_HISTORY_NOW_SECONDS"
else
  now_seconds="$(date '+%s')"
fi

umask 077
install -d -m 700 "$TQ_TEXTFILE_DIR" "$TQ_PNL_HISTORY_CACHE_DIR" \
  "$TQ_PNL_HISTORY_CACHE_DIR/runs"

lock_dir="$TQ_PNL_HISTORY_CACHE_DIR/.lock"
mkdir "$lock_dir" 2>/dev/null || die "another history build is already running"
work_files=()
cleanup() {
  rm -rf "$lock_dir"
  if [[ "${#work_files[@]}" -gt 0 ]]; then
    rm -f "${work_files[@]}"
  fi
}
trap cleanup EXIT INT TERM

scan_log() {
  local source_path="$1"
  local run_key="$2"
  local events_path="$TQ_PNL_HISTORY_CACHE_DIR/runs/$run_key.events"
  local meta_path="$TQ_PNL_HISTORY_CACHE_DIR/runs/$run_key.meta"
  local fingerprint="$3"
  local extracted converted meta_tmp events_tmp
  local record_kind timestamp cycle_id delta epoch skipped=0

  extracted="$(mktemp "$TQ_PNL_HISTORY_CACHE_DIR/.pnl-history-extract.XXXXXX")"
  converted="$(mktemp "$TQ_PNL_HISTORY_CACHE_DIR/.pnl-history-convert.XXXXXX")"
  meta_tmp="$(mktemp "$TQ_PNL_HISTORY_CACHE_DIR/.pnl-history-meta.XXXXXX")"
  events_tmp="$(mktemp "$TQ_PNL_HISTORY_CACHE_DIR/.pnl-history-events.XXXXXX")"
  work_files+=("$extracted" "$converted" "$meta_tmp" "$events_tmp")

  awk -v run_key="$run_key" '
    function value_for(key,    i, pair, prefix) {
      prefix = key "="
      for (i = 1; i <= NF; i++) {
        if (index($i, prefix) == 1) return substr($i, length(prefix) + 1)
      }
      return ""
    }
    {
      msg = value_for("msg")
      stable = value_for("stable")
      completed = value_for("cycle_completed")
      if (msg != "pnl_status" || stable != "true" || completed != "true") next
      timestamp = value_for("time")
      cycle = value_for("cycle_id")
      delta = value_for("cycle_real_pnl_usdt")
      if (timestamp == "" || cycle == "" || delta == "") {
        print "L"
        next
      }
      if (cycle !~ /^[A-Za-z0-9_.:-]+$/) {
        print "X\tinvalid cycle_id " cycle
        next
      }
      if (delta !~ /^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$/) {
        print "X\tinvalid cycle delta " delta
        next
      }
      numeric = delta + 0
      normalized = sprintf("%.15g", numeric)
      if (normalized ~ /[Ii][Nn][Ff]|[Nn][Aa][Nn]/) {
        print "X\tnon-finite cycle delta"
        next
      }
      printf "E\t%s\t%s/%s\t%s\n", timestamp, run_key, cycle, normalized
    }
  ' "$source_path" >"$extracted"

  while IFS=$'\t' read -r record_kind timestamp cycle_id delta; do
    case "$record_kind" in
      L)
        skipped=$((skipped + 1))
        ;;
      X)
        die "$source_path: ${timestamp:-invalid authoritative event}"
        ;;
      E)
        epoch="$(rfc3339_epoch "$timestamp")" || die "$source_path: invalid RFC3339 timestamp $timestamp"
        printf '%s\t%s\t%s\n' "$epoch" "$cycle_id" "$delta" >>"$converted"
        ;;
    esac
  done <"$extracted"

  awk -F '\t' '
    {
      key = $2
      signature = $1 FS $3
      if (key in seen && seen[key] != signature) {
        printf "conflicting cycle_id %s\n", key > "/dev/stderr"
        exit 1
      }
      if (!(key in seen)) {
        seen[key] = signature
        print
      }
    }
  ' "$converted" | sort -t $'\t' -k1,1n -k2,2 >"$events_tmp" || \
    die "$source_path contains conflicting cycle data"

  printf '%s\t%s\n' "${fingerprint// /$'\t'}" "$skipped" >"$meta_tmp"
  chmod 600 "$events_tmp" "$meta_tmp"
  mv "$events_tmp" "$events_path"
  mv "$meta_tmp" "$meta_path"
}

while IFS= read -r source_path; do
  [[ -f "$source_path" ]] || continue
  source_name="${source_path##*/}"
  run_key="${source_name%.raw.log}"
  [[ "$run_key" != "$source_name" && "$run_key" =~ ^[A-Za-z0-9_.:-]+$ ]] || \
    die "unsafe raw log filename: $source_name"
  fingerprint="$(file_fingerprint "$source_path")"
  meta_path="$TQ_PNL_HISTORY_CACHE_DIR/runs/$run_key.meta"
  events_path="$TQ_PNL_HISTORY_CACHE_DIR/runs/$run_key.events"
  cached_fingerprint=""
  if [[ -f "$meta_path" ]]; then
    IFS=$'\t' read -r inode size mtime cached_skipped <"$meta_path" || true
    cached_fingerprint="$inode $size $mtime"
  fi
  if [[ ! -f "$events_path" || "$cached_fingerprint" != "$fingerprint" ]]; then
    scan_log "$source_path" "$run_key" "$fingerprint"
  fi
done < <(compgen -G "$TQ_RAW_LOG_GLOB" | sort || true)

all_events="$(mktemp "$TQ_PNL_HISTORY_CACHE_DIR/.pnl-history-all.XXXXXX")"
unique_events="$(mktemp "$TQ_PNL_HISTORY_CACHE_DIR/.pnl-history-unique.XXXXXX")"
boundaries="$(mktemp "$TQ_PNL_HISTORY_CACHE_DIR/.pnl-history-boundaries.XXXXXX")"
points="$(mktemp "$TQ_PNL_HISTORY_CACHE_DIR/.pnl-history-points.XXXXXX")"
metric_tmp="$(mktemp "$TQ_TEXTFILE_DIR/.tnauqquant-pnl-history.prom.XXXXXX")"
work_files+=("$all_events" "$unique_events" "$boundaries" "$points" "$metric_tmp")

skipped_legacy=0
for meta_path in "$TQ_PNL_HISTORY_CACHE_DIR"/runs/*.meta; do
  [[ -f "$meta_path" ]] || continue
  IFS=$'\t' read -r inode size mtime cached_skipped <"$meta_path" || die "invalid cache metadata: $meta_path"
  [[ "${cached_skipped:-}" =~ ^[0-9]+$ ]] || die "invalid skipped count in $meta_path"
  skipped_legacy=$((skipped_legacy + cached_skipped))
done
for events_path in "$TQ_PNL_HISTORY_CACHE_DIR"/runs/*.events; do
  [[ -f "$events_path" ]] || continue
  cat "$events_path" >>"$all_events"
done

awk -F '\t' '
  NF != 3 { print "malformed cached event" > "/dev/stderr"; exit 1 }
  {
    key = $2
    signature = $1 FS $3
    if (key in seen && seen[key] != signature) {
      printf "conflicting cycle_id %s across cached runs\n", key > "/dev/stderr"
      exit 1
    }
    if (!(key in seen)) {
      seen[key] = signature
      print
    }
  }
' "$all_events" | sort -t $'\t' -k1,1n -k2,2 >"$unique_events" || \
  die "cached history contains conflicting cycle data"

cached_cycles="$(awk 'END { print NR + 0 }' "$unique_events")"
today="$(local_date_for_epoch "$now_seconds")"
cutoff_date="$(date_days_ago "$today" "$((TQ_PNL_HISTORY_DAYS - 1))")"
cutoff_epoch="$(local_midnight_epoch "$cutoff_date")"
today_epoch="$(local_midnight_epoch "$today")"

printf 'B\t%s\n' "$cutoff_epoch" >"$boundaries"
day_offset=1
while [[ "$day_offset" -lt "$TQ_PNL_HISTORY_DAYS" ]]; do
  boundary_date="$(date_days_after "$cutoff_date" "$day_offset")"
  printf 'B\t%s\n' "$(local_midnight_epoch "$boundary_date")" >>"$boundaries"
  day_offset=$((day_offset + 1))
done

if [[ "$cached_cycles" -gt 0 ]]; then
  {
    cat "$boundaries"
    awk -F '\t' '{ print "E\t" $1 "\t" $2 "\t" $3 }' "$unique_events"
  } | awk -F '\t' -v today="$today_epoch" -v now="$now_seconds" \
      -v max_today="$TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES" '
    $1 == "B" { boundary[++boundary_count] = $2; next }
    $1 == "E" {
      event_epoch[++event_count] = $2
      event_delta[event_count] = $4 + 0
      next
    }
    END {
      cumulative = 0
      event_index = 1
      point = 0
      while (event_index <= event_count && event_epoch[event_index] < boundary[1]) {
        cumulative += event_delta[event_index++]
      }
      printf "%d\t%.15g\n", boundary[1], cumulative
      point++
      for (b = 2; b <= boundary_count; b++) {
        while (event_index <= event_count && event_epoch[event_index] < boundary[b]) {
          cumulative += event_delta[event_index++]
        }
        printf "%d\t%.15g\n", boundary[b], cumulative
        point++
      }
      today_count = 0
      while (event_index <= event_count) {
        if (event_epoch[event_index] > now) {
          print "future cycle timestamp exceeds build time" > "/dev/stderr"
          exit 2
        }
        cumulative += event_delta[event_index]
        today_count++
        if (today_count > max_today) {
          print "current-day cycle point bound exceeded" > "/dev/stderr"
          exit 3
        }
        printf "%d\t%.15g\n", event_epoch[event_index], cumulative
        event_index++
        point++
      }
    }
  ' >"$points" || die "unable to construct bounded display history"
fi

base_labels="product=\"$TQ_PRODUCT\",environment=\"$TQ_ENVIRONMENT\",server_id=\"$TQ_SERVER_ID\",strategy=\"$TQ_STRATEGY\""
{
  printf '# HELP tnauqquant_pnl_history_build_timestamp_seconds Unix time of the last successful P&L history build.\n'
  printf '# TYPE tnauqquant_pnl_history_build_timestamp_seconds gauge\n'
  printf 'tnauqquant_pnl_history_build_timestamp_seconds{%s} %s\n' "$base_labels" "$now_seconds"
  printf '# HELP tnauqquant_pnl_history_cached_cycles Number of unique authoritative completed cycles retained in the local cache.\n'
  printf '# TYPE tnauqquant_pnl_history_cached_cycles gauge\n'
  printf 'tnauqquant_pnl_history_cached_cycles{%s} %s\n' "$base_labels" "$cached_cycles"
  printf '# HELP tnauqquant_pnl_history_skipped_legacy_events Completed P&L events excluded because the authoritative cycle contract was incomplete.\n'
  printf '# TYPE tnauqquant_pnl_history_skipped_legacy_events gauge\n'
  printf 'tnauqquant_pnl_history_skipped_legacy_events{%s} %s\n' "$base_labels" "$skipped_legacy"
  printf '# HELP tnauqquant_pnl_history_valid Whether at least one authoritative completed cycle is available.\n'
  printf '# TYPE tnauqquant_pnl_history_valid gauge\n'
  if [[ "$cached_cycles" -eq 0 ]]; then
    printf 'tnauqquant_pnl_history_valid{%s} 0\n' "$base_labels"
  else
    first_epoch="$(awk -F '\t' 'NR == 1 { print $1 }' "$unique_events")"
    last_epoch="$(awk -F '\t' 'END { print $1 }' "$unique_events")"
    printf 'tnauqquant_pnl_history_valid{%s} 1\n' "$base_labels"
    printf '# HELP tnauqquant_pnl_history_first_supported_event_timestamp_seconds Unix time of the earliest authoritative cycle retained in history.\n'
    printf '# TYPE tnauqquant_pnl_history_first_supported_event_timestamp_seconds gauge\n'
    printf 'tnauqquant_pnl_history_first_supported_event_timestamp_seconds{%s} %s\n' "$base_labels" "$first_epoch"
    printf '# HELP tnauqquant_pnl_history_last_event_timestamp_seconds Unix time of the latest authoritative cycle retained in history.\n'
    printf '# TYPE tnauqquant_pnl_history_last_event_timestamp_seconds gauge\n'
    printf 'tnauqquant_pnl_history_last_event_timestamp_seconds{%s} %s\n' "$base_labels" "$last_epoch"
    printf '# HELP tnauqquant_pnl_history_point_value_usdt Cross-run accumulated real P&L in USDT at a bounded display point.\n'
    printf '# TYPE tnauqquant_pnl_history_point_value_usdt gauge\n'
    printf '# HELP tnauqquant_pnl_history_point_timestamp_seconds Unix time represented by a bounded P&L display point.\n'
    printf '# TYPE tnauqquant_pnl_history_point_timestamp_seconds gauge\n'
    point=0
    while IFS=$'\t' read -r point_timestamp point_value; do
      printf 'tnauqquant_pnl_history_point_value_usdt{%s,point="%s"} %s\n' \
        "$base_labels" "$point" "$point_value"
      printf 'tnauqquant_pnl_history_point_timestamp_seconds{%s,point="%s"} %s\n' \
        "$base_labels" "$point" "$point_timestamp"
      point=$((point + 1))
    done <"$points"
  fi
} >"$metric_tmp"

chmod 600 "$metric_tmp"
mv "$metric_tmp" "$TQ_TEXTFILE_DIR/tnauqquant-pnl-history.prom"
