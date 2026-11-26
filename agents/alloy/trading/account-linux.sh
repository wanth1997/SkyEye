#!/usr/bin/env bash
set -euo pipefail

# Manage accounts (executors) in an already-installed Linux Trading monitoring
# instance (/etc/skyeye-trading/instances/<strategy>.env) by updating only
# TQ_EXECUTOR_MAP.
#
# Scope: Linux Trading lanes installed via agents/alloy/trading/setup-linux.sh
# only. macOS (Mac mini) and Windows lanes are out of scope.
#
# Invoked directly or through:
#   agents/alloy/trading/setup-linux.sh account add|remove|list ...
#
# Safety invariants:
# - Never touches tnauqquant@* systemd units, configs, or credential files.
# - Never overwrites shared probe.sh or other shared artifacts (refuses even if
#   every probe timer is stopped).
# - Never restarts Alloy (reload only).
# - Preserves each instance's probe timer enabled/active state.
# - Refuses mutating subcommands during UTC 18:10-19:30.
# - Automatically restores the pre-change env backup if apply or post-apply
#   verification fails.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup-linux.sh"
SERVICE_TEMPLATE="$SCRIPT_DIR/skyeye-trading-probe@.service.tmpl"
TIMER_TEMPLATE="$SCRIPT_DIR/skyeye-trading-probe@.timer.tmpl"
COMMON_LIB="$SCRIPT_DIR/linux-common.sh"
INSTALL_COMMON="$SCRIPT_DIR/../install-common.sh"

SUBCOMMAND=""
SERVER_ID=""
STRATEGY=""
EXECUTOR=""
EXCHANGE=""
DRY_RUN=0

WAIT_SECONDS="${SKYEYE_ACCOUNT_WAIT_SECONDS:-16}"
VERIFY_TIMEOUT="${SKYEYE_ACCOUNT_VERIFY_TIMEOUT:-35}"
POLL_INTERVAL="${SKYEYE_ACCOUNT_POLL_INTERVAL:-2}"

usage() {
  printf '%s\n' \
    'Usage: setup-linux.sh account add    [--server ID] --strategy NAME --executor NAME [--exchange NAME] [--dry-run]' \
    '       setup-linux.sh account remove [--server ID] --strategy NAME --executor NAME [--exchange NAME] [--dry-run]' \
    '       setup-linux.sh account list   [--server ID] --strategy NAME' \
    '' \
    'Manage executors in an installed Linux Trading lane (TQ_EXECUTOR_MAP only).' \
    'Scope: Linux Trading lanes installed via setup-linux.sh only; macOS (Mac mini)' \
    'and Windows lanes are out of scope.' \
    '' \
    'Subcommands:' \
    '  add     Add one executor to TQ_EXECUTOR_MAP, reload Alloy, preserve timer state,' \
    '          and wait one probe cycle to confirm .prom updates cleanly.' \
    '          If --exchange is omitted and all current executors share one exchange,' \
    '          that exchange is inferred; multi-exchange lanes require --exchange.' \
    '  remove  Remove one executor from TQ_EXECUTOR_MAP (refuses removing the last one).' \
    '          If --exchange is given, verifies the existing mapping matches it.' \
    '  list    Read-only: display TQ_EXECUTOR_MAP and executors currently emitting' \
    '          series in the strategy .prom file.' \
    '' \
    'Options:' \
    '  --server ID       Verify TQ_SERVER_ID in the installed env matches ID.' \
    '  --strategy NAME   Installed strategy slug (/etc/skyeye-trading/instances/NAME.env).' \
    '  --executor NAME   Executor name (add/remove only).' \
    '  --exchange NAME   Exchange label (optional on add/remove; required on add when' \
    '                    multiple exchanges exist in TQ_EXECUTOR_MAP).' \
    '  --dry-run         Validate and print the planned change without modifying the host.' \
    '  -h, --help        Show this help.' \
    '' \
    'Ordering with tnauqquant (SkyEye never touches tnauqquant@* units/configs/envs):' \
    '  Add:    1) Run SkyEye account add first; 2) Add the account in tnauqquant and restart.' \
    '  Remove: 1) Remove the account in tnauqquant and restart first; 2) Run SkyEye account remove.' \
    '' \
    'Guards:' \
    '  - Mutating commands (add/remove) are refused during UTC 18:10-19:30.' \
    '  - Refuses if shared probe.sh or shared unit/metrics files differ from the host.' \
    '  - Never restarts Alloy (reload only) and preserves probe timer enabled/active state.' \
    '  - Automatically restores the backed-up env on apply or verification failure.' \
    '  - New strategies, strategy retirement, and shared probe.sh updates still require' \
    '    the full workflow in agents/alloy/trading/README.md.'
}

die() {
  printf 'SkyEye trading account: %s\n' "$*" >&2
  exit 1
}

[[ -f "$COMMON_LIB" ]] || die "missing shared helper library: $COMMON_LIB"
# shellcheck source=agents/alloy/trading/linux-common.sh
source "$COMMON_LIB"
[[ -f "$INSTALL_COMMON" ]] || die "missing shared helper library: $INSTALL_COMMON"
# shellcheck source=agents/alloy/install-common.sh
source "$INSTALL_COMMON"

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

render_unit_for_installed() {
  local template="$1"
  local target="$2"
  local env_root="$3"
  local probe_path="$4"
  local access_path="$5"
  local probe_user="$6"
  local probe_group="$7"
  local env_escaped probe_escaped access_escaped user_escaped group_escaped
  env_escaped="$(escape_sed_replacement "$env_root")"
  probe_escaped="$(escape_sed_replacement "$probe_path")"
  access_escaped="$(escape_sed_replacement "$access_path")"
  user_escaped="$(escape_sed_replacement "$probe_user")"
  group_escaped="$(escape_sed_replacement "$probe_group")"
  sed \
    -e "s|@@ENV_ROOT@@|$env_escaped|g" \
    -e "s|@@PROBE_PATH@@|$probe_escaped|g" \
    -e "s|@@ACCESS_PATH@@|$access_escaped|g" \
    -e "s|@@PROBE_USER@@|$user_escaped|g" \
    -e "s|@@PROBE_GROUP@@|$group_escaped|g" \
    "$template" >"$target"
}

check_utc_window() {
  local now_hm hh mm total_min
  now_hm="$(date -u '+%H:%M')"
  [[ "$now_hm" =~ ^([0-9]{2}):([0-9]{2})$ ]] || \
    die "cannot determine current UTC time from 'date -u +%H:%M': $now_hm"
  hh="${BASH_REMATCH[1]}"
  mm="${BASH_REMATCH[2]}"
  total_min=$((10#$hh * 60 + 10#$mm))
  # Refuse UTC 18:10 (1090) through 19:30 (1170) inclusive.
  if [[ "$total_min" -ge 1090 && "$total_min" -le 1170 ]]; then
    die "refusing to modify trading accounts during the UTC 18:10-19:30 maintenance/restart window (current UTC: $now_hm). Retry after 19:30 UTC."
  fi
}

take_account_lock() {
  local lock_path="$1" old_umask rc=0
  if [[ -L "$lock_path" ]]; then
    die "lock file $lock_path is a symlink; remove it and re-run"
  fi
  mkdir -p "$(dirname "$lock_path")"
  old_umask="$(umask)"
  umask 077
  if ! exec 8>>"$lock_path"; then
    umask "$old_umask"
    die "cannot open lock file $lock_path"
  fi
  umask "$old_umask"
  perl -MFcntl=:flock -e \
    'open(my $fh, ">>&=", 8) or exit 2; exit(flock($fh, LOCK_EX | LOCK_NB) ? 0 : 1)' || rc=$?
  case "$rc" in
    0) return 0 ;;
    1)
      exec 8>&-
      die "another SkyEye trading-account run holds $lock_path. Nothing was changed; re-run after it finishes"
      ;;
    *)
      exec 8>&-
      die "could not lock $lock_path (perl exited $rc). Nothing was changed"
      ;;
  esac
}

check_alloy_lock_free() {
  local lock_path="$1" rc=0
  if [[ -L "$lock_path" ]]; then
    die "lock file $lock_path is a symlink; remove it and re-run"
  fi
  [[ -e "$lock_path" ]] || return 0
  (
    exec 7>>"$lock_path"
    perl -MFcntl=:flock -e \
      'open(my $fh, ">>&=", 7) or exit 2; exit(flock($fh, LOCK_EX | LOCK_NB) ? 0 : 1)'
  ) || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) die "another SkyEye Alloy install, retire or uninstall holds $lock_path. Nothing was changed; re-run after it finishes" ;;
    *) die "could not inspect lock $lock_path (perl exited $rc). Nothing was changed" ;;
  esac
}

format_rerun_cmd() {
  local base="$1"
  local cmd="$base $SUBCOMMAND"
  if [[ -n "$SERVER_ID" ]]; then
    cmd="$cmd --server $SERVER_ID"
  elif [[ -n "${ENV_SERVER_ID:-}" ]]; then
    cmd="$cmd --server $ENV_SERVER_ID"
  fi
  cmd="$cmd --strategy $STRATEGY --executor $EXECUTOR"
  if [[ -n "$EXCHANGE" ]]; then
    cmd="$cmd --exchange $EXCHANGE"
  fi
  printf '%s' "$cmd"
}

die_shared_mismatch() {
  local artifact="$1"
  local rerun_wrapper
  rerun_wrapper="$(format_rerun_cmd "scripts/trading-account")"
  printf '%s\n' \
    "SkyEye trading account: shared artifact differs from installed host copy ($artifact); trading-account never overwrites shared probe.sh or shared unit/metrics files." \
    "Next steps:" \
    "  1) If the host has a staged checkout matching the installed probe.sh, re-run with --remote-dir:" \
    "     $rerun_wrapper --remote-dir /home/ubuntu/skyeye-staging/<MATCHING_CHECKOUT>" \
    "  2) Or if you intend to upgrade shared probe.sh/units on this host, stop and disable all skyeye-trading-probe@* units first following 'Probe CPU limits and shared probe rollout' in agents/alloy/trading/README.md." >&2
  exit 1
}

prom_probe_timestamp() {
  local prom_path="$1"
  local strategy="$2"
  [[ -f "$prom_path" ]] || return 0
  LC_ALL=C awk -v want="strategy=\"$strategy\"" '
    index($0, "tnauqquant_probe_timestamp_seconds{") == 1 && index($0, want) > 0 {
      val = $NF
      if (val ~ /^[0-9]+([.][0-9]+)?$/) {
        sub(/[.].*$/, "", val)
        print val
        exit
      }
    }
  ' "$prom_path"
}

# Lists executors present in .prom series as: <executor>\t<exchange>\t<metrics>
prom_list_executors() {
  local prom_path="$1"
  [[ -f "$prom_path" ]] || return 0
  LC_ALL=C awk '
    /^#/ || /^[[:space:]]*$/ { next }
    /^tnauqquant_[A-Za-z0-9_]+\{/ {
      metric = $1
      brace = index(metric, "{")
      if (brace <= 1) next
      mname = substr(metric, 1, brace - 1)
      rest = substr($0, brace + 1)
      close_b = index(rest, "}")
      if (close_b <= 1) next
      labels = substr(rest, 1, close_b - 1)

      ex = ""
      exch = ""
      n = split(labels, parts, ",")
      for (i = 1; i <= n; i++) {
        p = parts[i]
        if (index(p, "executor=\"") == 1 && substr(p, length(p), 1) == "\"") {
          ex = substr(p, 11, length(p) - 11)
        } else if (index(p, "exchange=\"") == 1 && substr(p, length(p), 1) == "\"") {
          exch = substr(p, 11, length(p) - 11)
        }
      }
      if (ex == "") next

      tag = mname
      if (mname == "tnauqquant_current_executor_equity_usdt") tag = "equity"
      else if (mname == "tnauqquant_current_executor_real_pnl_usdt") tag = "real_pnl"
      else if (mname == "tnauqquant_current_executor_cycles_completed") tag = "cycles"
      else if (mname == "tnauqquant_current_run_executor_volume_usd") tag = "volume"

      if (!(ex in seen_ex)) {
        seen_ex[ex] = 1
        order[++cnt] = ex
        ex_exchange[ex] = exch
      }
      key = ex SUBSEP tag
      if (!(key in seen_tag)) {
        seen_tag[key] = 1
        if (ex_tags[ex] == "") ex_tags[ex] = tag
        else ex_tags[ex] = ex_tags[ex] "," tag
      }
    }
    END {
      for (i = 1; i <= cnt; i++) {
        ex = order[i]
        printf "%s\t%s\t%s\n", ex, ex_exchange[ex], ex_tags[ex]
      }
    }
  ' "$prom_path"
}

# Prints any executor=<name> series in .prom that violates allowed_map.
# When allowed_map has no shared exchange (single-account or distinct exchanges),
# probe.sh must not emit any executor="..." series at all.
prom_unexpected_executors() {
  local prom_path="$1"
  local allowed_map="$2"
  [[ -f "$prom_path" ]] || return 0
  LC_ALL=C awk -v mapping="$allowed_map" '
    BEGIN {
      has_shared = 0
      n = split(mapping, entries, ",")
      for (i = 1; i <= n; i++) {
        eq = index(entries[i], "=")
        if (eq <= 1) continue
        ex = substr(entries[i], 1, eq - 1)
        exch = substr(entries[i], eq + 1)
        allow[ex] = exch
        if (++exch_count[exch] >= 2) has_shared = 1
      }
    }
    /^#/ || /^[[:space:]]*$/ { next }
    /^tnauqquant_[A-Za-z0-9_]+\{/ {
      brace = index($0, "{")
      rest = substr($0, brace + 1)
      close_b = index(rest, "}")
      if (close_b <= 1) next
      labels = substr(rest, 1, close_b - 1)
      ex = ""
      exch = ""
      n = split(labels, parts, ",")
      for (i = 1; i <= n; i++) {
        p = parts[i]
        if (index(p, "executor=\"") == 1 && substr(p, length(p), 1) == "\"") {
          ex = substr(p, 11, length(p) - 11)
        } else if (index(p, "exchange=\"") == 1 && substr(p, length(p), 1) == "\"") {
          exch = substr(p, 11, length(p) - 11)
        }
      }
      if (ex == "") next
      if (!has_shared || !(ex in allow) || (exch != "" && allow[ex] != exch)) {
        item = ex "=" exch
        if (!(item in bad)) {
          bad[item] = 1
          print item
        }
      }
    }
  ' "$prom_path"
}

# Verifies new_file differs from old_file on exactly one TQ_EXECUTOR_MAP= line.
verify_single_line_env_diff() {
  local old_file="$1"
  local new_file="$2"
  local expected_line="$3"
  LC_ALL=C awk -v want="$expected_line" '
    NR == FNR {
      old[FNR] = $0
      old_n = FNR
      next
    }
    {
      new[FNR] = $0
      new_n = FNR
    }
    END {
      if (old_n != new_n) {
        print "line count changed: old=" old_n " new=" new_n > "/dev/stderr"
        exit 1
      }
      diffs = 0
      for (i = 1; i <= old_n; i++) {
        if (old[i] != new[i]) {
          diffs++
          if (index(old[i], "TQ_EXECUTOR_MAP=") != 1 || new[i] != want) {
            print "unexpected line diff at line " i > "/dev/stderr"
            exit 1
          }
        }
      }
      if (diffs != 1) {
        print "expected exactly 1 changed line, found " diffs > "/dev/stderr"
        exit 1
      }
    }
  ' "$old_file" "$new_file"
}

case "${1:-}" in
  add|remove|list)
    SUBCOMMAND="$1"
    shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  "")
    usage >&2
    exit 2
    ;;
  *)
    die "unknown subcommand: $1 (expected add, remove, or list)"
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)
      [[ $# -ge 2 ]] || die "--server requires a value"
      SERVER_ID="$2"
      shift 2
      ;;
    --strategy)
      [[ $# -ge 2 ]] || die "--strategy requires a value"
      STRATEGY="$2"
      shift 2
      ;;
    --executor)
      [[ $# -ge 2 ]] || die "--executor requires a value"
      EXECUTOR="$2"
      shift 2
      ;;
    --exchange)
      [[ $# -ge 2 ]] || die "--exchange requires a value"
      EXCHANGE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$STRATEGY" ]] || die "--strategy is required"
valid_label_value "$STRATEGY" || die "invalid strategy name: $STRATEGY"
if [[ -n "$SERVER_ID" ]]; then
  valid_label_value "$SERVER_ID" || die "invalid server_id: $SERVER_ID"
fi

if [[ "$SUBCOMMAND" == "list" ]]; then
  [[ -z "$EXECUTOR" ]] || die "list does not take --executor"
  [[ -z "$EXCHANGE" ]] || die "list does not take --exchange"
  [[ "$DRY_RUN" -eq 0 ]] || die "list does not take --dry-run"
else
  [[ -n "$EXECUTOR" ]] || die "--executor is required for $SUBCOMMAND"
  valid_label_value "$EXECUTOR" || die "invalid executor name: $EXECUTOR"
  if [[ -n "$EXCHANGE" ]]; then
    valid_label_value "$EXCHANGE" || die "invalid exchange name: $EXCHANGE"
  fi
  [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "SKYEYE_ACCOUNT_WAIT_SECONDS must be a non-negative integer, got: $WAIT_SECONDS"
  [[ "$VERIFY_TIMEOUT" =~ ^[0-9]+$ ]] || die "SKYEYE_ACCOUNT_VERIFY_TIMEOUT must be a non-negative integer, got: $VERIFY_TIMEOUT"
  [[ "$POLL_INTERVAL" =~ ^[0-9]+$ && "$POLL_INTERVAL" -ge 1 ]] || \
    die "SKYEYE_ACCOUNT_POLL_INTERVAL must be a positive integer, got: $POLL_INTERVAL"
fi

if [[ "$SUBCOMMAND" == "add" || "$SUBCOMMAND" == "remove" ]]; then
  check_utc_window
fi

init_system_root

INSTALL_ENV_DIR="$(system_path /etc/skyeye-trading)"
INSTALL_ENV_ROOT="$INSTALL_ENV_DIR/instances"
INSTALL_ENV="$INSTALL_ENV_ROOT/$STRATEGY.env"

[[ ! -L "$INSTALL_ENV" ]] || die "installed env must not be a symlink: $INSTALL_ENV"
[[ -f "$INSTALL_ENV" ]] || \
  die "installed strategy instance not found: $INSTALL_ENV (to onboard a new strategy, follow 'Add or remove a Trading target' in agents/alloy/trading/README.md)"

env_mode="$(file_mode "$INSTALL_ENV")"
[[ "$env_mode" == "600" ]] || die "installed env must have mode 600, found $env_mode: $INSTALL_ENV"

map_line_count="$(grep -c '^TQ_EXECUTOR_MAP=' "$INSTALL_ENV" || true)"
[[ "$map_line_count" == "1" ]] || \
  die "expected exactly one literal TQ_EXECUTOR_MAP= line in $INSTALL_ENV, found $map_line_count"

ENV_STRATEGY="$(installed_env_value TQ_STRATEGY "$INSTALL_ENV")" || \
  die "TQ_STRATEGY in $INSTALL_ENV cannot be read safely"
[[ "$ENV_STRATEGY" == "$STRATEGY" ]] || \
  die "installed env TQ_STRATEGY ($ENV_STRATEGY) does not match --strategy ($STRATEGY)"

ENV_SERVER_ID="$(installed_env_value TQ_SERVER_ID "$INSTALL_ENV")" || \
  die "TQ_SERVER_ID in $INSTALL_ENV cannot be read safely"
[[ -n "$ENV_SERVER_ID" ]] || die "TQ_SERVER_ID is missing in $INSTALL_ENV"
if [[ -n "$SERVER_ID" && "$ENV_SERVER_ID" != "$SERVER_ID" ]]; then
  die "server_id mismatch: --server is '$SERVER_ID' but $INSTALL_ENV has TQ_SERVER_ID='$ENV_SERVER_ID'"
fi

ENV_EXECUTOR_MAP="$(installed_env_value TQ_EXECUTOR_MAP "$INSTALL_ENV")" || \
  die "TQ_EXECUTOR_MAP in $INSTALL_ENV cannot be read safely"
valid_executor_map "$ENV_EXECUTOR_MAP" || \
  die "existing TQ_EXECUTOR_MAP in $INSTALL_ENV is invalid: $ENV_EXECUTOR_MAP"

ENV_TEXTFILE_DIR="$(installed_env_value TQ_TEXTFILE_DIR "$INSTALL_ENV")" || \
  die "TQ_TEXTFILE_DIR in $INSTALL_ENV cannot be read safely"
ENV_TEXTFILE_NAME="$(installed_env_value TQ_TEXTFILE_NAME "$INSTALL_ENV")" || \
  die "TQ_TEXTFILE_NAME in $INSTALL_ENV cannot be read safely"
[[ "$ENV_TEXTFILE_DIR" == /* && "$ENV_TEXTFILE_DIR" != *[[:space:]\"\']* ]] || \
  die "unsafe TQ_TEXTFILE_DIR in $INSTALL_ENV: $ENV_TEXTFILE_DIR"
[[ "$ENV_TEXTFILE_NAME" == "tnauqquant-$STRATEGY.prom" ]] || \
  die "TQ_TEXTFILE_NAME in $INSTALL_ENV must be tnauqquant-$STRATEGY.prom, found: $ENV_TEXTFILE_NAME"
if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
  init_system_root "$ENV_TEXTFILE_DIR"
fi
PROM_PATH="$ENV_TEXTFILE_DIR/$ENV_TEXTFILE_NAME"

# Parse existing TQ_EXECUTOR_MAP into parallel bash 3.2 arrays.
EXISTING_EXECUTORS=()
EXISTING_EXCHANGES=()
UNIQUE_EXCHANGES=()
old_ifs="$IFS"
IFS=',' read -r -a raw_entries <<<"$ENV_EXECUTOR_MAP"
IFS="$old_ifs"
for entry in "${raw_entries[@]}"; do
  ex_name="${entry%%=*}"
  exch_name="${entry#*=}"
  EXISTING_EXECUTORS+=("$ex_name")
  EXISTING_EXCHANGES+=("$exch_name")
  seen_u=0
  for u in ${UNIQUE_EXCHANGES[@]+"${UNIQUE_EXCHANGES[@]}"}; do
    if [[ "$u" == "$exch_name" ]]; then
      seen_u=1
      break
    fi
  done
  if [[ "$seen_u" -eq 0 ]]; then
    UNIQUE_EXCHANGES+=("$exch_name")
  fi
done

if [[ "$SUBCOMMAND" == "list" ]]; then
  printf 'server_id: %s\n' "$ENV_SERVER_ID"
  printf 'strategy: %s\n' "$ENV_STRATEGY"
  printf 'env_file: %s\n' "$INSTALL_ENV"
  if [[ -f "$PROM_PATH" ]]; then
    prom_ts="$(prom_probe_timestamp "$PROM_PATH" "$STRATEGY")"
    printf 'prom_file: %s\n' "$PROM_PATH"
    printf 'probe_timestamp_seconds: %s\n' "${prom_ts:-none}"
  else
    printf 'prom_file: %s (missing)\n' "$PROM_PATH"
    printf 'probe_timestamp_seconds: none\n'
  fi
  printf 'configured_executors (TQ_EXECUTOR_MAP=%s):\n' "$ENV_EXECUTOR_MAP"
  for i in "${!EXISTING_EXECUTORS[@]}"; do
    printf '  %s\t%s\n' "${EXISTING_EXECUTORS[$i]}" "${EXISTING_EXCHANGES[$i]}"
  done
  printf 'prom_series_executors:\n'
  if [[ ! -f "$PROM_PATH" ]]; then
    printf '  (prom file missing)\n'
  else
    prom_execs="$(prom_list_executors "$PROM_PATH")"
    if [[ -n "$prom_execs" ]]; then
      while IFS=$'\t' read -r p_ex p_exch p_tags; do
        printf '  %s\t%s\t(%s)\n' "$p_ex" "$p_exch" "$p_tags"
      done <<<"$prom_execs"
    else
      printf '  (none)\n'
    fi
  fi
  exit 0
fi

# ---- Mutating subcommands (add / remove) ----

for command_name in alloy awk cmp cp date find grep install mktemp perl sed systemctl wc; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
done
[[ -x "$SETUP_SCRIPT" ]] || die "missing executable setup script: $SETUP_SCRIPT"
[[ -f "$SERVICE_TEMPLATE" ]] || die "missing systemd service template: $SERVICE_TEMPLATE"
[[ -f "$TIMER_TEMPLATE" ]] || die "missing systemd timer template: $TIMER_TEMPLATE"
resolve_systemctl

ACCOUNT_LOCK="$(system_path /run/skyeye-trading-account.lock)"
ALLOY_LOCK="$(system_path /run/skyeye-alloy.lock)"
take_account_lock "$ACCOUNT_LOCK"
check_alloy_lock_free "$ALLOY_LOCK"

skyeye_alloy_version_gate linux || die "$SKYEYE_INSTALL_ERROR. Nothing was changed"

ALLOY_CONFIG_DIR="$(system_path /etc/alloy)"
ALLOY_ENV_FILE="$(system_path /etc/default/alloy)"
ALLOY_METRICS_FRAGMENT="$ALLOY_CONFIG_DIR/trading-metrics.alloy"
INSTALL_ROOT="$(system_path /usr/local/libexec/skyeye-trading)"
SYSTEMD_DIR="$(system_path /etc/systemd/system)"
SERVICE_PATH="$SYSTEMD_DIR/skyeye-trading-probe@.service"
TIMER_PATH="$SYSTEMD_DIR/skyeye-trading-probe@.timer"
INSTANCE_SERVICE="skyeye-trading-probe@$STRATEGY.service"
INSTANCE_TIMER="skyeye-trading-probe@$STRATEGY.timer"
BACKUP_ROOT="$INSTALL_ENV_DIR/account-backup"

ALLOY_DIRECTORY_SETTING='CONFIG_FILE="/etc/alloy"'
if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
  ALLOY_DIRECTORY_SETTING="CONFIG_FILE=\"$ALLOY_CONFIG_DIR\""
fi

[[ -f "$ALLOY_ENV_FILE" ]] || die "existing Alloy environment file not found: $ALLOY_ENV_FILE"
if ! grep -qxF -- "$ALLOY_DIRECTORY_SETTING" "$ALLOY_ENV_FILE" || \
   [[ "$(grep -c '^CONFIG_FILE=' "$ALLOY_ENV_FILE" || true)" != "1" ]]; then
  die "Alloy is not configured in directory mode ($ALLOY_DIRECTORY_SETTING); trading-account never restarts Alloy. Follow 'Add or remove a Trading target' in agents/alloy/trading/README.md first"
fi
"$SYSTEMCTL_BIN" is-active --quiet alloy >/dev/null 2>&1 || \
  die "Alloy is not active; trading-account only reloads an active Alloy and never restarts it"
[[ "$(alloy_can_reload)" == "yes" ]] || \
  die "systemd cannot reload the alloy unit (CanReload != yes); trading-account never restarts Alloy"

ENV_PROBE_USER="$(installed_env_value TQ_PROBE_USER "$INSTALL_ENV")" || \
  die "TQ_PROBE_USER in $INSTALL_ENV cannot be read safely"
ENV_PROBE_GROUP="$(installed_env_value TQ_PROBE_GROUP "$INSTALL_ENV")" || \
  die "TQ_PROBE_GROUP in $INSTALL_ENV cannot be read safely"
[[ -n "$ENV_PROBE_USER" && -n "$ENV_PROBE_GROUP" ]] || \
  die "TQ_PROBE_USER and TQ_PROBE_GROUP are required in $INSTALL_ENV"

# Compute the new TQ_EXECUTOR_MAP.
NEW_EXECUTOR_MAP=""
TARGET_EXCHANGE=""
INFERRED_EXCHANGE=0
if [[ "$SUBCOMMAND" == "add" ]]; then
  for existing_ex in "${EXISTING_EXECUTORS[@]}"; do
    if [[ "$existing_ex" == "$EXECUTOR" ]]; then
      die "executor '$EXECUTOR' already exists in TQ_EXECUTOR_MAP ($ENV_EXECUTOR_MAP)"
    fi
  done
  if [[ -n "$EXCHANGE" ]]; then
    TARGET_EXCHANGE="$EXCHANGE"
  else
    if [[ "${#UNIQUE_EXCHANGES[@]}" -eq 1 ]]; then
      TARGET_EXCHANGE="${UNIQUE_EXCHANGES[0]}"
      INFERRED_EXCHANGE=1
    else
      die "multiple exchanges present in TQ_EXECUTOR_MAP (${UNIQUE_EXCHANGES[*]}); specify --exchange <name>"
    fi
  fi
  NEW_EXECUTOR_MAP="$ENV_EXECUTOR_MAP,$EXECUTOR=$TARGET_EXCHANGE"
else
  found_index=-1
  found_exchange=""
  for i in "${!EXISTING_EXECUTORS[@]}"; do
    if [[ "${EXISTING_EXECUTORS[$i]}" == "$EXECUTOR" ]]; then
      found_index="$i"
      found_exchange="${EXISTING_EXCHANGES[$i]}"
      break
    fi
  done
  if [[ "$found_index" -lt 0 ]]; then
    die "executor '$EXECUTOR' is not present in TQ_EXECUTOR_MAP ($ENV_EXECUTOR_MAP)"
  fi
  if [[ -n "$EXCHANGE" && "$found_exchange" != "$EXCHANGE" ]]; then
    die "executor '$EXECUTOR' is mapped to exchange '$found_exchange', not '$EXCHANGE'"
  fi
  if [[ "${#EXISTING_EXECUTORS[@]}" -le 1 ]]; then
    die "cannot remove the last executor '$EXECUTOR' from $STRATEGY (TQ_EXECUTOR_MAP must keep at least one executor; to retire the entire strategy use setup-linux.sh retire --strategy $STRATEGY)"
  fi
  TARGET_EXCHANGE="$found_exchange"
  for i in "${!EXISTING_EXECUTORS[@]}"; do
    [[ "$i" -eq "$found_index" ]] && continue
    pair="${EXISTING_EXECUTORS[$i]}=${EXISTING_EXCHANGES[$i]}"
    if [[ -z "$NEW_EXECUTOR_MAP" ]]; then
      NEW_EXECUTOR_MAP="$pair"
    else
      NEW_EXECUTOR_MAP="$NEW_EXECUTOR_MAP,$pair"
    fi
  done
fi

valid_executor_map "$NEW_EXECUTOR_MAP" || \
  die "computed TQ_EXECUTOR_MAP is invalid: $NEW_EXECUTOR_MAP"

if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
  WORK_DIR="$(mktemp -d "$TEST_SYSTEM_ROOT/skyeye-trading-account.XXXXXX")"
else
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-trading-account.XXXXXX")"
fi
chmod 700 "$WORK_DIR"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

CANDIDATE_ENV="$WORK_DIR/$STRATEGY.env.new"
(
  umask 077
  NEW_MAP="$NEW_EXECUTOR_MAP" LC_ALL=C awk '
    index($0, "TQ_EXECUTOR_MAP=") == 1 {
      print "TQ_EXECUTOR_MAP=" ENVIRON["NEW_MAP"]
      next
    }
    { print }
  ' "$INSTALL_ENV" >"$CANDIDATE_ENV"
)
chmod 600 "$CANDIDATE_ENV"

if ! verify_single_line_env_diff "$INSTALL_ENV" "$CANDIDATE_ENV" "TQ_EXECUTOR_MAP=$NEW_EXECUTOR_MAP"; then
  die "refusing to apply: staged env changed more than the single TQ_EXECUTOR_MAP line"
fi

# Offline render validation (validates env vars, paths, templates, TQ_BASE_ASSET, TQ_EXECUTOR_MAP).
RENDER_DIR="$WORK_DIR/render"
if ! "$SETUP_SCRIPT" --render-only "$RENDER_DIR" --env-file "$CANDIDATE_ENV" >"$WORK_DIR/render.out" 2>&1; then
  cat "$WORK_DIR/render.out" >&2
  die "offline render validation failed; host was not changed"
fi

# Check shared probe.sh and all shared artifacts BEFORE touching the host.
if [[ ! -f "$INSTALL_ROOT/probe.sh" ]] || ! cmp -s "$RENDER_DIR/probe.sh" "$INSTALL_ROOT/probe.sh"; then
  die_shared_mismatch "$INSTALL_ROOT/probe.sh"
fi
if [[ ! -f "$INSTALL_ROOT/ensure-log-access.sh" ]] || \
   ! cmp -s "$RENDER_DIR/ensure-log-access.sh" "$INSTALL_ROOT/ensure-log-access.sh"; then
  die_shared_mismatch "$INSTALL_ROOT/ensure-log-access.sh"
fi
if [[ ! -f "$ALLOY_METRICS_FRAGMENT" ]] || \
   ! cmp -s "$RENDER_DIR/trading-metrics.alloy" "$ALLOY_METRICS_FRAGMENT"; then
  die_shared_mismatch "$ALLOY_METRICS_FRAGMENT"
fi

render_unit_for_installed "$SERVICE_TEMPLATE" "$WORK_DIR/installed-probe@.service" \
  "$INSTALL_ENV_ROOT" "$INSTALL_ROOT/probe.sh" "$INSTALL_ROOT/ensure-log-access.sh" \
  "$ENV_PROBE_USER" "$ENV_PROBE_GROUP"
render_unit_for_installed "$TIMER_TEMPLATE" "$WORK_DIR/installed-probe@.timer" \
  "$INSTALL_ENV_ROOT" "$INSTALL_ROOT/probe.sh" "$INSTALL_ROOT/ensure-log-access.sh" \
  "$ENV_PROBE_USER" "$ENV_PROBE_GROUP"

if [[ ! -f "$SERVICE_PATH" ]] || ! cmp -s "$WORK_DIR/installed-probe@.service" "$SERVICE_PATH"; then
  die_shared_mismatch "$SERVICE_PATH"
fi
if [[ ! -f "$TIMER_PATH" ]] || ! cmp -s "$WORK_DIR/installed-probe@.timer" "$TIMER_PATH"; then
  die_shared_mismatch "$TIMER_PATH"
fi

# Offline Alloy config validation combining existing /etc/alloy with rendered fragment.
STAGING_ALLOY="$WORK_DIR/alloy-validate"
mkdir -p "$STAGING_ALLOY"
find "$ALLOY_CONFIG_DIR" -maxdepth 1 -type f -name '*.alloy' \
  ! -name "trading-$STRATEGY.alloy" \
  -exec cp -p {} "$STAGING_ALLOY/" \;
install -m 644 "$RENDER_DIR/trading-$STRATEGY.alloy" "$STAGING_ALLOY/trading-$STRATEGY.alloy"
if ! alloy validate "$STAGING_ALLOY" >"$WORK_DIR/alloy-validate.out" 2>&1; then
  cat "$WORK_DIR/alloy-validate.out" >&2
  die "offline Alloy validation failed; host was not changed"
fi

PRIOR_TIMER_ENABLED=0
PRIOR_TIMER_ACTIVE=0
"$SYSTEMCTL_BIN" is-enabled --quiet "$INSTANCE_TIMER" >/dev/null 2>&1 && PRIOR_TIMER_ENABLED=1
"$SYSTEMCTL_BIN" is-active --quiet "$INSTANCE_TIMER" >/dev/null 2>&1 && PRIOR_TIMER_ACTIVE=1

timer_label() {
  case "${1}${2}" in
    11) printf 'enabled/active' ;;
    10) printf 'enabled/inactive' ;;
    01) printf 'disabled/active' ;;
    *)  printf 'disabled/inactive' ;;
  esac
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'Dry run (%s) for %s/%s:\n' "$SUBCOMMAND" "$ENV_SERVER_ID" "$STRATEGY"
  if [[ "$INFERRED_EXCHANGE" -eq 1 ]]; then
    printf '  inferred_exchange: %s\n' "$TARGET_EXCHANGE"
  fi
  printf '  old TQ_EXECUTOR_MAP: %s\n' "$ENV_EXECUTOR_MAP"
  printf '  new TQ_EXECUTOR_MAP: %s\n' "$NEW_EXECUTOR_MAP"
  printf '  timer_state (preserved): %s\n' "$(timer_label "$PRIOR_TIMER_ENABLED" "$PRIOR_TIMER_ACTIVE")"
  printf 'Dry run: validation passed (no changes made)\n'
  exit 0
fi

# Record baseline before mutation.
BEFORE_PROM_EXISTS=0
BEFORE_PROM_TS=""
if [[ -f "$PROM_PATH" ]]; then
  BEFORE_PROM_EXISTS=1
  BEFORE_PROM_TS="$(prom_probe_timestamp "$PROM_PATH" "$STRATEGY")"
fi
APPLY_START_EPOCH="$(date +%s)"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$timestamp-$STRATEGY-$$"
BACKUP_ENV="$BACKUP_DIR/$STRATEGY.env.before"
install -d -m 700 "$INSTALL_ENV_DIR" "$BACKUP_ROOT" "$BACKUP_DIR"
install -m 600 "$INSTALL_ENV" "$BACKUP_ENV"
{
  printf 'action=%s\n' "$SUBCOMMAND"
  printf 'server_id=%s\n' "$ENV_SERVER_ID"
  printf 'strategy=%s\n' "$STRATEGY"
  printf 'executor=%s\n' "$EXECUTOR"
  printf 'exchange=%s\n' "$TARGET_EXCHANGE"
  printf 'old_executor_map=%s\n' "$ENV_EXECUTOR_MAP"
  printf 'new_executor_map=%s\n' "$NEW_EXECUTOR_MAP"
  printf 'prior_timer_enabled=%s\n' "$PRIOR_TIMER_ENABLED"
  printf 'prior_timer_active=%s\n' "$PRIOR_TIMER_ACTIVE"
  printf 'created_at_utc=%s\n' "$timestamp"
} >"$BACKUP_DIR/account.meta"

printf 'Backup record: %s\n' "$BACKUP_DIR"
if [[ "$INFERRED_EXCHANGE" -eq 1 ]]; then
  printf 'Inferred exchange from existing TQ_EXECUTOR_MAP: %s\n' "$TARGET_EXCHANGE"
fi

timer_matches_prior() {
  local cur_e=0 cur_a=0
  "$SYSTEMCTL_BIN" is-enabled --quiet "$INSTANCE_TIMER" >/dev/null 2>&1 && cur_e=1
  "$SYSTEMCTL_BIN" is-active --quiet "$INSTANCE_TIMER" >/dev/null 2>&1 && cur_a=1
  [[ "$cur_e" -eq "$PRIOR_TIMER_ENABLED" && "$cur_a" -eq "$PRIOR_TIMER_ACTIVE" ]]
}

restore_timer_direct() {
  case "${PRIOR_TIMER_ENABLED}${PRIOR_TIMER_ACTIVE}" in
    11)
      "$SYSTEMCTL_BIN" enable --now "$INSTANCE_TIMER" >/dev/null 2>&1 || return 1
      ;;
    10)
      "$SYSTEMCTL_BIN" disable --now "$INSTANCE_TIMER" >/dev/null 2>&1 || true
      "$SYSTEMCTL_BIN" enable "$INSTANCE_TIMER" >/dev/null 2>&1 || return 1
      ;;
    01)
      "$SYSTEMCTL_BIN" disable "$INSTANCE_TIMER" >/dev/null 2>&1 || true
      "$SYSTEMCTL_BIN" start "$INSTANCE_TIMER" >/dev/null 2>&1 || return 1
      ;;
    *)
      "$SYSTEMCTL_BIN" disable --now "$INSTANCE_TIMER" >/dev/null 2>&1 || true
      ;;
  esac
  timer_matches_prior
}

rollback_change() {
  local reason="$1"
  local setup_had_reload_pending=0
  printf 'SkyEye trading account: %s; restoring backup from %s\n' "$reason" "$BACKUP_ENV" >&2

  if [[ -f "$WORK_DIR/setup-add.out" ]] && \
     grep -q "restoring 'systemctl reload alloy' failed" "$WORK_DIR/setup-add.out"; then
    setup_had_reload_pending=1
  fi

  # If setup-linux.sh already rolled back cleanly (env + timer + active Alloy, no reload_pending):
  if [[ "$setup_had_reload_pending" -eq 0 ]] && \
     cmp -s "$BACKUP_ENV" "$INSTALL_ENV" && \
     timer_matches_prior && \
     "$SYSTEMCTL_BIN" is-active --quiet alloy >/dev/null 2>&1; then
    printf 'status=rolled_back\nrollback_reason=%s\n' "$reason" >>"$BACKUP_DIR/account.meta"
    printf 'SkyEye trading account: backup already restored cleanly (%s)\n' "$BACKUP_ENV" >&2
    printf 'Backup record: %s\n' "$BACKUP_DIR" >&2
    exit 1
  fi

  # Otherwise try clean restore via setup-linux.sh add with the original env (reload only, never restart).
  if [[ "$setup_had_reload_pending" -eq 0 ]]; then
    if "$SETUP_SCRIPT" add --env-file "$BACKUP_ENV" </dev/null >"$WORK_DIR/rollback-add.out" 2>&1 && \
       cmp -s "$BACKUP_ENV" "$INSTALL_ENV" && \
       timer_matches_prior; then
      printf 'status=rolled_back\nrollback_reason=%s\n' "$reason" >>"$BACKUP_DIR/account.meta"
      printf 'SkyEye trading account: restored original env and timer state (%s)\n' "$BACKUP_ENV" >&2
      printf 'Backup record: %s\n' "$BACKUP_DIR" >&2
      exit 1
    fi
  fi

  # Fallback direct restore (still never restarts Alloy).
  local incomplete=0
  if ! install -m 600 "$BACKUP_ENV" "$INSTALL_ENV"; then
    incomplete=1
  fi
  if ! restore_timer_direct; then
    incomplete=1
  fi
  if ! "$SYSTEMCTL_BIN" reload alloy >/dev/null 2>&1; then
    incomplete=1
  fi

  if [[ "$incomplete" -eq 1 ]]; then
    printf 'status=rollback_incomplete\nalloy_recovery=reload_pending\nrollback_reason=%s\n' \
      "$reason" >>"$BACKUP_DIR/account.meta"
    printf '%s\n' \
      "CRITICAL: rollback_incomplete — original env was restored to $INSTALL_ENV (from $BACKUP_ENV), but recovery reload or timer restoration did not complete." \
      "Remaining recovery action: sudo systemctl reload alloy (and check: sudo systemctl status $INSTANCE_TIMER)" \
      "Backup record: $BACKUP_DIR" >&2
    exit 3
  fi

  printf 'status=rolled_back\nrollback_reason=%s\n' "$reason" >>"$BACKUP_DIR/account.meta"
  printf 'SkyEye trading account: restored original env and timer state (%s)\n' "$BACKUP_ENV" >&2
  printf 'Backup record: %s\n' "$BACKUP_DIR" >&2
  exit 1
}

# Apply via setup-linux.sh add (never --restart-alloy, never --enable-probe).
add_rc=0
"$SETUP_SCRIPT" add --env-file "$CANDIDATE_ENV" </dev/null >"$WORK_DIR/setup-add.out" 2>&1 || add_rc=$?
if [[ "$add_rc" -ne 0 ]]; then
  cat "$WORK_DIR/setup-add.out" >&2
  rollback_change "setup-linux.sh add failed (rc=$add_rc)"
fi
cat "$WORK_DIR/setup-add.out"
if grep -q '^Alloy action: restart' "$WORK_DIR/setup-add.out" || \
   ! grep -q '^Alloy action: reload' "$WORK_DIR/setup-add.out"; then
  rollback_change "setup-linux.sh add did not apply with Alloy reload"
fi
if ! cmp -s "$CANDIDATE_ENV" "$INSTALL_ENV"; then
  rollback_change "installed env does not match expected TQ_EXECUTOR_MAP update"
fi
if ! timer_matches_prior; then
  rollback_change "probe timer state drifted from prior $(timer_label "$PRIOR_TIMER_ENABLED" "$PRIOR_TIMER_ACTIVE")"
fi

# Post-apply verification.
FINAL_PROM_TS=""
if [[ "$PRIOR_TIMER_ACTIVE" -eq 1 ]]; then
  verify_start="$SECONDS"
  verify_deadline=$((verify_start + VERIFY_TIMEOUT))
  if [[ "$WAIT_SECONDS" -gt 0 ]]; then
    printf 'Waiting %ss (one probe cycle) to verify %s updates cleanly...\n' "$WAIT_SECONDS" "$PROM_PATH"
    sleep "$WAIT_SECONDS"
  fi
  verified=0
  last_fail_reason="probe metrics did not update within timeout (${VERIFY_TIMEOUT}s)"
  while true; do
    if ! "$SYSTEMCTL_BIN" is-active --quiet alloy >/dev/null 2>&1; then
      rollback_change "Alloy became inactive during post-apply verification"
    fi
    if ! timer_matches_prior; then
      rollback_change "probe timer state changed during post-apply verification"
    fi
    if "$SYSTEMCTL_BIN" is-failed --quiet "$INSTANCE_SERVICE" >/dev/null 2>&1; then
      rollback_change "probe service $INSTANCE_SERVICE entered failed state"
    fi

    if [[ ! -s "$PROM_PATH" ]]; then
      last_fail_reason="probe output missing or empty: $PROM_PATH"
    else
      cur_ts="$(prom_probe_timestamp "$PROM_PATH" "$STRATEGY")"
      if [[ -z "$cur_ts" ]]; then
        last_fail_reason="tnauqquant_probe_timestamp_seconds missing in $PROM_PATH"
      elif [[ "$BEFORE_PROM_EXISTS" -eq 1 && -n "$BEFORE_PROM_TS" && "$cur_ts" -le "$BEFORE_PROM_TS" ]]; then
        last_fail_reason="tnauqquant_probe_timestamp_seconds ($cur_ts) did not advance past pre-change timestamp ($BEFORE_PROM_TS)"
      elif [[ "$BEFORE_PROM_EXISTS" -eq 0 && "$cur_ts" -lt "$APPLY_START_EPOCH" ]]; then
        last_fail_reason="tnauqquant_probe_timestamp_seconds ($cur_ts) predates apply start ($APPLY_START_EPOCH)"
      else
        unexpected="$(prom_unexpected_executors "$PROM_PATH" "$NEW_EXECUTOR_MAP")"
        if [[ -n "$unexpected" ]]; then
          last_fail_reason="unexpected executor series remain in $PROM_PATH: $(printf '%s' "$unexpected" | tr '\n' ' ')"
        else
          FINAL_PROM_TS="$cur_ts"
          verified=1
          break
        fi
      fi
    fi

    if [[ "$SECONDS" -ge "$verify_deadline" ]]; then
      break
    fi
    sleep "$POLL_INTERVAL"
  done

  if [[ "$verified" -ne 1 ]]; then
    rollback_change "$last_fail_reason"
  fi
else
  if ! "$SYSTEMCTL_BIN" is-active --quiet alloy >/dev/null 2>&1; then
    rollback_change "Alloy became inactive after apply"
  fi
  if ! timer_matches_prior; then
    rollback_change "probe timer state drifted from inactive"
  fi
fi

printf 'status=committed\n' >>"$BACKUP_DIR/account.meta"

printf '\nAccount %s committed for %s/%s:\n' "$SUBCOMMAND" "$ENV_SERVER_ID" "$STRATEGY"
printf '  old TQ_EXECUTOR_MAP: %s\n' "$ENV_EXECUTOR_MAP"
printf '  new TQ_EXECUTOR_MAP: %s\n' "$NEW_EXECUTOR_MAP"
printf '  timer_state: %s (preserved)\n' "$(timer_label "$PRIOR_TIMER_ENABLED" "$PRIOR_TIMER_ACTIVE")"
if [[ "$PRIOR_TIMER_ACTIVE" -eq 1 ]]; then
  printf '  prom_verified: %s (probe_timestamp_seconds=%s)\n' "$PROM_PATH" "$FINAL_PROM_TS"
  prom_execs="$(prom_list_executors "$PROM_PATH")"
  if [[ -n "$prom_execs" ]]; then
    printf '  prom_series_executors:\n'
    while IFS=$'\t' read -r p_ex p_exch p_tags; do
      printf '    %s\t%s\t(%s)\n' "$p_ex" "$p_exch" "$p_tags"
    done <<<"$prom_execs"
  else
    printf '  prom_series_executors: (none)\n'
  fi
else
  printf '  prom_check: live .prom wait not run because probe timer remains %s\n' \
    "$(timer_label "$PRIOR_TIMER_ENABLED" "$PRIOR_TIMER_ACTIVE")"
fi
printf '  backup_record: %s\n' "$BACKUP_DIR"
if [[ "$SUBCOMMAND" == "add" ]]; then
  printf 'Next: add %s to tnauqquant config/env and restart the tnauqquant lane (SkyEye never controls tnauqquant@*).\n' "$EXECUTOR"
else
  printf 'Note: ensure %s was already removed from tnauqquant config/env and the tnauqquant lane restarted.\n' "$EXECUTOR"
fi
