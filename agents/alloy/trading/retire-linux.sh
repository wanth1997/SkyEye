#!/usr/bin/env bash
set -euo pipefail

# Retire one Linux Trading monitoring instance (one strategy on this host).
# Disables only skyeye-trading-probe@STRATEGY, moves its env, Loki fragment
# and metrics output into a private rollback record under
# /etc/skyeye-trading/retired/, and reloads Alloy. Shared artifacts, sibling
# instances, history and the trading process itself are never touched.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMON_LIB="$SCRIPT_DIR/linux-common.sh"
STRATEGY=""
RESTART_ALLOY=0

usage() {
  printf '%s\n' \
    'Usage: setup-linux.sh retire --strategy NAME [--restart-alloy]' \
    '' \
    'Disables skyeye-trading-probe@NAME, archives its env, Alloy fragment and' \
    'metrics file into /etc/skyeye-trading/retired/NAME-<UTC>/ and reloads Alloy.' \
    'Remove the central inventory row and run central-deploy first, so the' \
    'retired target cannot raise TradingTelemetryMissing. Idempotent.'
}

die() {
  printf 'SkyEye trading Linux retire: %s\n' "$*" >&2
  exit 1
}

[[ -f "$COMMON_LIB" ]] || die "missing shared helper library: $COMMON_LIB"
# shellcheck source=agents/alloy/trading/linux-common.sh
source "$COMMON_LIB"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strategy)
      [[ $# -ge 2 ]] || die "--strategy requires a name"
      STRATEGY="$2"
      shift 2
      ;;
    --restart-alloy)
      RESTART_ALLOY=1
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

init_system_root
for command_name in alloy cp date find grep install mv sed systemctl tail
do
  command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
done
resolve_systemctl

ALLOY_CONFIG_DIR="$(system_path /etc/alloy)"
ALLOY_FRAGMENT="$ALLOY_CONFIG_DIR/trading-$STRATEGY.alloy"
INSTALL_ENV_DIR="$(system_path /etc/skyeye-trading)"
INSTALL_ENV="$INSTALL_ENV_DIR/instances/$STRATEGY.env"
RETIRED_ROOT="$INSTALL_ENV_DIR/retired"
INSTANCE_SERVICE="skyeye-trading-probe@$STRATEGY.service"
INSTANCE_TIMER="skyeye-trading-probe@$STRATEGY.timer"

unit_state() {
  "$SYSTEMCTL_BIN" "$1" --quiet "$2" >/dev/null 2>&1
}

TIMER_WAS_ENABLED=0
TIMER_WAS_ACTIVE=0
SERVICE_WAS_ACTIVE=0
unit_state is-enabled "$INSTANCE_TIMER" && TIMER_WAS_ENABLED=1
unit_state is-active "$INSTANCE_TIMER" && TIMER_WAS_ACTIVE=1
unit_state is-active "$INSTANCE_SERVICE" && SERVICE_WAS_ACTIVE=1

TEXTFILE_DIR=""
TEXTFILE_NAME=""
if [[ -f "$INSTALL_ENV" ]]; then
  [[ ! -L "$INSTALL_ENV" ]] || die "installed env must not be a symlink: $INSTALL_ENV"
  installed_strategy="$(installed_env_value TQ_STRATEGY "$INSTALL_ENV")" || \
    die "installed env TQ_STRATEGY cannot be read safely: $INSTALL_ENV"
  [[ "$installed_strategy" == "$STRATEGY" ]] || \
    die "installed env TQ_STRATEGY does not match $STRATEGY: $INSTALL_ENV"
  TEXTFILE_DIR="$(installed_env_value TQ_TEXTFILE_DIR "$INSTALL_ENV")" || \
    die "installed env TQ_TEXTFILE_DIR cannot be read safely: $INSTALL_ENV"
  TEXTFILE_NAME="$(installed_env_value TQ_TEXTFILE_NAME "$INSTALL_ENV")" || \
    die "installed env TQ_TEXTFILE_NAME cannot be read safely: $INSTALL_ENV"
  [[ "$TEXTFILE_DIR" == /* && "$TEXTFILE_DIR" != *[[:space:]\"\']* ]] || \
    die "installed env has an unsafe TQ_TEXTFILE_DIR: $TEXTFILE_DIR"
  [[ "$TEXTFILE_NAME" == "tnauqquant-$STRATEGY.prom" ]] || \
    die "installed env TQ_TEXTFILE_NAME must be tnauqquant-$STRATEGY.prom"
  if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
    init_system_root "$TEXTFILE_DIR"
  fi
fi

archive_paths=()
for candidate in "$INSTALL_ENV" "$ALLOY_FRAGMENT"; do
  path_exists "$candidate" && archive_paths+=("$candidate")
done

# NUL-separated metrics output and probe temp files for this strategy. A
# running probe creates and renames these, so the set to archive is taken
# only after the probe is stopped; this early look only decides the no-op.
list_metrics_paths() {
  [[ -n "$TEXTFILE_DIR" ]] || return 0
  if path_exists "$TEXTFILE_DIR/$TEXTFILE_NAME"; then
    printf '%s\0' "$TEXTFILE_DIR/$TEXTFILE_NAME"
  fi
  find "$TEXTFILE_DIR" -maxdepth 1 -name ".$TEXTFILE_NAME.*" -print0 2>/dev/null || true
}
METRICS_PRESENT=0
while IFS= read -r -d '' _metrics_path; do
  METRICS_PRESENT=1
done < <(list_metrics_paths)

if [[ "${#archive_paths[@]}" -eq 0 && "$METRICS_PRESENT" -eq 0 && "$TIMER_WAS_ENABLED" -eq 0 &&
      "$TIMER_WAS_ACTIVE" -eq 0 && "$SERVICE_WAS_ACTIVE" -eq 0 ]]; then
  latest_record=""
  if [[ -d "$RETIRED_ROOT" ]]; then
    while IFS= read -r -d '' record_meta; do
      if grep -qxF "strategy=$STRATEGY" "$record_meta" && \
        grep -qx 'status=committed' "$record_meta"; then
        latest_record="$(dirname "$record_meta")"
      fi
    done < <(find "$RETIRED_ROOT" -mindepth 2 -maxdepth 2 -path "$RETIRED_ROOT/$STRATEGY-[0-9]*/retire.meta" -print0 | sort -z)
  fi
  if [[ -n "$latest_record" ]]; then
    printf 'Already retired: %s (record %s)\n' "$STRATEGY" "$latest_record"
    exit 0
  fi
  die "nothing installed for $STRATEGY and no retired record exists; check the strategy name"
fi

if [[ -z "$TEXTFILE_DIR" ]]; then
  printf 'Warning: no installed env for %s; its metrics file cannot be located and is left in place\n' \
    "$STRATEGY" >&2
fi

ALLOY_WAS_ACTIVE=0
unit_state is-active alloy && ALLOY_WAS_ACTIVE=1
alloy_fragments="$(list_alloy_fragments "$ALLOY_CONFIG_DIR")"
ALLOY_ACTION=none
if [[ "$ALLOY_WAS_ACTIVE" -eq 1 ]]; then
  if [[ "$RESTART_ALLOY" -eq 1 ]]; then
    ALLOY_ACTION=restart
    printf 'Alloy action: restart (--restart-alloy). This briefly interrupts every Alloy pipeline: %s\n' \
      "$alloy_fragments"
  elif [[ "$(alloy_can_reload)" == "yes" ]]; then
    ALLOY_ACTION=reload
    printf 'Alloy action: reload. Re-evaluates these fragments; unchanged pipelines keep running: %s\n' \
      "$alloy_fragments"
  else
    die "systemd cannot reload the alloy unit; re-run with --restart-alloy, which interrupts every Alloy pipeline ($alloy_fragments)"
  fi
else
  printf 'Alloy action: none (Alloy is not active and stays stopped)\n'
fi

STAGING_CONFIG="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-alloy-retire.XXXXXX")"
RECORD=""
MUTATION_STARTED=0
RETIRE_COMMITTED=0

record_relative() {
  local source_path="$1"
  if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
    printf '%s\n' "${source_path#"$TEST_SYSTEM_ROOT"/}"
  else
    printf '%s\n' "${source_path#/}"
  fi
}

restore_retire() {
  local target_path relative_path alloy_pending=0
  [[ -n "$RECORD" && -f "$RECORD/paths.list" ]] || return 0
  while IFS= read -r target_path; do
    [[ -n "$target_path" ]] || continue
    relative_path="$(record_relative "$target_path")"
    if path_exists "$RECORD/previous/$relative_path" && ! path_exists "$target_path"; then
      mkdir -p "$(dirname "$target_path")"
      mv "$RECORD/previous/$relative_path" "$target_path"
    fi
  done <"$RECORD/paths.list"
  if [[ "$ALLOY_ACTION" == "reload" ]]; then
    # A reload-only invocation never escalates to a restart, even here.
    "$SYSTEMCTL_BIN" reload alloy >/dev/null 2>&1 || alloy_pending=1
  elif [[ "$ALLOY_ACTION" == "restart" ]]; then
    "$SYSTEMCTL_BIN" restart alloy >/dev/null 2>&1 || true
  fi
  if [[ "$TIMER_WAS_ENABLED" -eq 1 ]]; then
    "$SYSTEMCTL_BIN" enable "$INSTANCE_TIMER" >/dev/null 2>&1 || true
  fi
  if [[ "$TIMER_WAS_ACTIVE" -eq 1 ]]; then
    "$SYSTEMCTL_BIN" start "$INSTANCE_TIMER" >/dev/null 2>&1 || true
  fi
  printf 'status=rolled_back\n' >>"$RECORD/retire.meta"
  if [[ "$alloy_pending" -eq 1 ]]; then
    printf 'alloy_recovery=reload_pending\n' >>"$RECORD/retire.meta"
    printf '%s\n' \
      "SkyEye trading Linux retire: files and timer state are restored, but the restoring 'systemctl reload alloy' failed; Alloy may still run without trading-$STRATEGY.alloy." \
      "Remaining recovery action: sudo systemctl reload alloy. If reload keeps failing, sudo systemctl restart alloy, which interrupts every Alloy pipeline: $alloy_fragments" \
      "Rollback record: $RECORD" >&2
  fi
}

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 && "$MUTATION_STARTED" -eq 1 && "$RETIRE_COMMITTED" -eq 0 ]]; then
    printf 'SkyEye trading Linux retire: retirement failed; restoring archived files and timer state\n' >&2
    restore_retire
  fi
  rm -rf "$STAGING_CONFIG"
  exit "$status"
}
trap cleanup EXIT

# Validate the post-retirement Alloy directory before changing anything.
find "$ALLOY_CONFIG_DIR" -maxdepth 1 -type f -name '*.alloy' \
  ! -name "trading-$STRATEGY.alloy" \
  -exec cp -p {} "$STAGING_CONFIG/" \;
printf 'Validating the Alloy configuration without trading-%s.alloy\n' "$STRATEGY"
alloy validate "$STAGING_CONFIG"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
RECORD="$RETIRED_ROOT/$STRATEGY-$timestamp"
[[ ! -e "$RECORD" ]] || RECORD="$RECORD-$$"
install -d -m 700 "$INSTALL_ENV_DIR" "$RETIRED_ROOT" "$RECORD" "$RECORD/previous"
: >"$RECORD/paths.list"
for archive_path in "${archive_paths[@]}"; do
  printf '%s\n' "$archive_path" >>"$RECORD/paths.list"
done
{
  printf 'strategy=%s\n' "$STRATEGY"
  printf 'timer_was_enabled=%s\n' "$TIMER_WAS_ENABLED"
  printf 'timer_was_active=%s\n' "$TIMER_WAS_ACTIVE"
  printf 'service_was_active=%s\n' "$SERVICE_WAS_ACTIVE"
  printf 'alloy_action=%s\n' "$ALLOY_ACTION"
  printf 'created_at_utc=%s\n' "$timestamp"
} >"$RECORD/retire.meta"
MUTATION_STARTED=1

"$SYSTEMCTL_BIN" disable --now "$INSTANCE_TIMER" >/dev/null 2>&1 || \
  [[ "$TIMER_WAS_ENABLED" -eq 0 && "$TIMER_WAS_ACTIVE" -eq 0 ]] || \
  die "could not disable $INSTANCE_TIMER"
"$SYSTEMCTL_BIN" stop "$INSTANCE_SERVICE" >/dev/null 2>&1 || true
! unit_state is-enabled "$INSTANCE_TIMER" || die "$INSTANCE_TIMER remained enabled"
! unit_state is-active "$INSTANCE_TIMER" || die "$INSTANCE_TIMER remained active"
! unit_state is-active "$INSTANCE_SERVICE" || die "$INSTANCE_SERVICE remained active"

# The probe is stopped now, so its metrics output and any temp file it left
# are final; record and archive exactly that set.
while IFS= read -r -d '' metrics_path; do
  archive_paths+=("$metrics_path")
  printf '%s\n' "$metrics_path" >>"$RECORD/paths.list"
done < <(list_metrics_paths)

for archive_path in "${archive_paths[@]}"; do
  relative_path="$(record_relative "$archive_path")"
  mkdir -p "$RECORD/previous/$(dirname "$relative_path")"
  mv "$archive_path" "$RECORD/previous/$relative_path"
done

alloy validate "$ALLOY_CONFIG_DIR"
case "$ALLOY_ACTION" in
  reload) "$SYSTEMCTL_BIN" reload alloy || die "Alloy reload failed" ;;
  restart) "$SYSTEMCTL_BIN" restart alloy || die "Alloy restart failed" ;;
esac
if [[ "$ALLOY_WAS_ACTIVE" -eq 1 ]]; then
  unit_state is-active alloy || die "Alloy is not active after retirement"
fi

printf 'status=committed\n' >>"$RECORD/retire.meta"
RETIRE_COMMITTED=1
printf 'Retired Linux trading monitoring instance: %s\n' "$STRATEGY"
printf 'Rollback record: %s\n' "$RECORD"
archived_env="$RECORD/previous/$(record_relative "$INSTALL_ENV")"
if [[ -f "$archived_env" ]]; then
  printf 'Re-add with: sudo %s/setup-linux.sh add --env-file %s\n' "$SCRIPT_DIR" "$archived_env"
fi
