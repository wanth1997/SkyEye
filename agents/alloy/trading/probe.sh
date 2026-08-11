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
  stat -f '%m' "$path" 2>/dev/null || stat -c '%Y' "$path"
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
      if result="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$normalized" '+%s' 2>/dev/null)"; then
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

  date -d "$timestamp" '+%s' 2>/dev/null
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

latest_pnl_line() {
  local log_path="$1"
  local require_completed="$2"
  awk -v require_completed="$require_completed" '
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
          (require_completed != "1" || completed == "true")) {
        latest = $0
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

[[ "$TQ_TIMEZONE" =~ ^[A-Za-z0-9_+./-]+$ ]] || die "invalid TQ_TIMEZONE"

for absolute_path in \
  "$TQ_REPO_ROOT" \
  "$TQ_CONFIG_PATH" \
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

PROCESS_PIDS=()
while IFS= read -r process_pid; do
  [[ -n "$process_pid" ]] && PROCESS_PIDS+=("$process_pid")
done <<EOF
$(ps -axo pid=,command= | awk \
  -v executable="$TQ_EXECUTABLE" \
  -v config_abs="$TQ_CONFIG_PATH" \
  -v config_rel="$CONFIG_REL" '
  {
    pid = $1
    executable_match = 0
    config_match = 0
    for (i = 2; i <= NF; i++) {
      if ($i == executable) {
        executable_match = 1
      }
      if ($i == "-config" && i < NF &&
          ($(i + 1) == config_abs || $(i + 1) == config_rel)) {
        config_match = 1
      }
    }
    if (executable_match && config_match) {
      print pid
    }
  }')
EOF
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
LOG_BINDING_OK=0
MARKER_BINDING_OK=0
RUN_EXPECTED="$TQ_POC_RUN_EXPECTED"
DONE_REASON=""
CURRENT_RUN_ID=""
CURRENT_RUN_STARTED_TIMESTAMP=""
CURRENT_PNL_VALID=0
CURRENT_REAL_PNL=""
CURRENT_CASH_PNL=""
CURRENT_REBATE=""
CURRENT_RISK_PNL=""
CURRENT_CYCLES_COMPLETED=""
PNL_SAMPLE_TIMESTAMP=""
LAST_COMPLETED_CYCLE_TIMESTAMP=""

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
       [[ "$MANIFEST_CONFIG_SHA256" == "$CONFIG_SHA256" ]] &&
       [[ "$MANIFEST_EXECUTABLE" == "$TQ_EXECUTABLE" ]] &&
       [[ "$MANIFEST_CONFIG_PATH" == "$TQ_CONFIG_PATH" ]] &&
       [[ "$MANIFEST_DONE_MARKER_PATH" == "$TQ_DONE_MARKER" ]]
    then
      MANIFEST_VALID=1
      STRATEGY_IDENTITY_OK=1
    fi
  fi

  if [[ "$MANIFEST_VALID" -eq 1 ]]; then
    if [[ "$PROCESS_COUNT" -eq 0 ]] || process_has_pid "$MANIFEST_PID"; then
      PROCESS_IDENTITY_OK=1
    fi

    if [[ -f "$MANIFEST_LOG_PATH" ]] &&
       [[ "$(basename "$MANIFEST_LOG_PATH")" == "$MANIFEST_RUN_ID.raw.log" ]]
    then
      LOG_BINDING_OK=1
      LATEST_LOG_MTIME="$(file_mtime "$MANIFEST_LOG_PATH")"
      CURRENT_RUN_ID="$MANIFEST_RUN_ID"
      CURRENT_RUN_STARTED_TIMESTAMP="$(timestamp_to_epoch "$MANIFEST_PROCESS_STARTED_AT" || true)"

      CURRENT_PNL_LINE="$(latest_pnl_line "$MANIFEST_LOG_PATH" 0)"
      if [[ -n "$CURRENT_PNL_LINE" ]]; then
        current_pnl_time="$(logfmt_value "$CURRENT_PNL_LINE" time)"
        current_real_pnl="$(logfmt_value "$CURRENT_PNL_LINE" real_pnl_usdt)"
        current_pnl_timestamp="$(timestamp_to_epoch "$current_pnl_time" || true)"
        if is_number "$current_real_pnl" && [[ "$current_pnl_timestamp" =~ ^[0-9]+$ ]]; then
          CURRENT_PNL_VALID=1
          CURRENT_REAL_PNL="$current_real_pnl"
          PNL_SAMPLE_TIMESTAMP="$current_pnl_timestamp"
          current_cash_pnl="$(logfmt_value "$CURRENT_PNL_LINE" cash_pnl_usdt)"
          current_rebate="$(logfmt_value "$CURRENT_PNL_LINE" rebate_usdt)"
          current_risk_pnl="$(logfmt_value "$CURRENT_PNL_LINE" risk_pnl_usdt)"
          current_cycles_completed="$(logfmt_value "$CURRENT_PNL_LINE" cycles_completed)"
          is_number "$current_cash_pnl" && CURRENT_CASH_PNL="$current_cash_pnl"
          is_number "$current_rebate" && CURRENT_REBATE="$current_rebate"
          is_number "$current_risk_pnl" && CURRENT_RISK_PNL="$current_risk_pnl"
          is_number "$current_cycles_completed" && CURRENT_CYCLES_COMPLETED="$current_cycles_completed"
        fi
      fi

      LAST_COMPLETED_LINE="$(latest_pnl_line "$MANIFEST_LOG_PATH" 1)"
      if [[ -n "$LAST_COMPLETED_LINE" ]]; then
        last_completed_time="$(logfmt_value "$LAST_COMPLETED_LINE" time)"
        LAST_COMPLETED_CYCLE_TIMESTAMP="$(timestamp_to_epoch "$last_completed_time" || true)"
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
if [[ -x "$TQ_TMUX_PATH" ]] &&
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
chmod 700 "$TQ_TEXTFILE_DIR"
umask 077
TEMP_METRICS="$(mktemp "$TQ_TEXTFILE_DIR/.tnauqquant.prom.XXXXXX")"

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
  emit_gauge tnauqquant_log_binding_ok "Whether the current log belongs to the current run." "$LOG_BINDING_OK"
  emit_gauge tnauqquant_marker_binding_ok "Whether the terminal marker belongs to the current run." "$MARKER_BINDING_OK"
  emit_gauge tnauqquant_sidecar_up "Whether the managed sidecar session exists." "$SIDECAR_UP"
  emit_gauge tnauqquant_sidecar_identity_ok "Whether sidecar runtime identity and health match." "$SIDECAR_IDENTITY_OK"
  emit_gauge tnauqquant_probe_timestamp_seconds "Unix timestamp of the latest successful probe." "$PROBE_TIMESTAMP"
  emit_gauge tnauqquant_log_mtime_seconds "Unix mtime of the current bound log, or zero." "$LATEST_LOG_MTIME"
  emit_gauge tnauqquant_current_pnl_valid "Whether current-run stable PNL is available." "$CURRENT_PNL_VALID"
  emit_gauge tnauqquant_completed_cycles_today "Completed cycles today across all runs in the configured timezone." "$TODAY_COMPLETED_CYCLES"
  if [[ -n "$CURRENT_RUN_ID" ]]; then
    printf '# HELP tnauqquant_current_run_info Current manifest-bound run identity.\n'
    printf '# TYPE tnauqquant_current_run_info gauge\n'
    printf 'tnauqquant_current_run_info{%s,run_id="%s"} 1\n' "$METRIC_LABELS" "$CURRENT_RUN_ID"
  fi
  [[ -n "$CURRENT_RUN_STARTED_TIMESTAMP" ]] && emit_gauge tnauqquant_current_run_started_timestamp_seconds "Unix timestamp when the current run process started." "$CURRENT_RUN_STARTED_TIMESTAMP"
  [[ -n "$CURRENT_REAL_PNL" ]] && emit_gauge tnauqquant_current_real_pnl_usdt "Latest stable real PNL for the current run in USDT." "$CURRENT_REAL_PNL"
  [[ -n "$CURRENT_CASH_PNL" ]] && emit_gauge tnauqquant_current_cash_pnl_usdt "Latest stable cash PNL for the current run in USDT." "$CURRENT_CASH_PNL"
  [[ -n "$CURRENT_REBATE" ]] && emit_gauge tnauqquant_current_rebate_usdt "Latest stable rebate for the current run in USDT." "$CURRENT_REBATE"
  [[ -n "$CURRENT_RISK_PNL" ]] && emit_gauge tnauqquant_current_risk_pnl_usdt "Latest stable risk PNL for the current run in USDT." "$CURRENT_RISK_PNL"
  [[ -n "$CURRENT_CYCLES_COMPLETED" ]] && emit_gauge tnauqquant_current_cycles_completed "Completed cycles reported by the current run." "$CURRENT_CYCLES_COMPLETED"
  [[ -n "$PNL_SAMPLE_TIMESTAMP" ]] && emit_gauge tnauqquant_pnl_sample_timestamp_seconds "Unix timestamp of the latest stable current-run PNL sample." "$PNL_SAMPLE_TIMESTAMP"
  [[ -n "$LAST_COMPLETED_CYCLE_TIMESTAMP" ]] && emit_gauge tnauqquant_last_completed_cycle_timestamp_seconds "Unix timestamp of the latest completed current-run cycle." "$LAST_COMPLETED_CYCLE_TIMESTAMP"
  if [[ -n "$DONE_REASON" ]]; then
    printf '# HELP tnauqquant_done_marker Bound terminal marker by normalized reason.\n'
    printf '# TYPE tnauqquant_done_marker gauge\n'
    printf 'tnauqquant_done_marker{%s,reason="%s"} 1\n' "$METRIC_LABELS" "$DONE_REASON"
  fi
} >"$TEMP_METRICS"

chmod 600 "$TEMP_METRICS"
mv "$TEMP_METRICS" "$TQ_TEXTFILE_DIR/tnauqquant.prom"
TEMP_METRICS=""
