#!/usr/bin/env bash
set -euo pipefail

# Installs the macOS Trading monitoring agent: Alloy config, the probe and P&L
# history scripts and their launchd jobs. Every file is staged next to its
# destination and validated before any live file is replaced. Only what
# changed is applied, and a failure puts files, Alloy and both launchd jobs
# back the way this run found them. macOS may run this with /bin/bash 3.2.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/config-macos.alloy.tmpl"
PLIST_TEMPLATE="$SCRIPT_DIR/com.wanbrain.skyeye-trading-probe.plist.tmpl"
HISTORY_PLIST_TEMPLATE="$SCRIPT_DIR/com.wanbrain.skyeye-trading-pnl-history.plist.tmpl"
SOURCE_PROBE="$SCRIPT_DIR/probe.sh"
SOURCE_HISTORY="$SCRIPT_DIR/pnl-history.sh"
INSTALL_COMMON="$SCRIPT_DIR/../install-common.sh"
RENDER_ONLY_DIR=""
ENV_FILE=""
NO_START=0
RESTART_ALLOY=0

ALLOY_FORMULA=grafana/grafana/alloy
ALLOY_SERVICE_LABEL=homebrew.mxcl.alloy
PROBE_LABEL=com.wanbrain.skyeye-trading-probe
HISTORY_LABEL=com.wanbrain.skyeye-trading-pnl-history
READY_SECONDS=60

usage() {
  printf '%s\n' \
    'Usage: setup-macos.sh [--env-file PATH] [--render-only DIR] [--no-start | --restart-alloy]' \
    '' \
    'Default env file: <brew-prefix>/etc/alloy/config.env' \
    '' \
    'Validates every file before it replaces a live one and applies only what' \
    'changed. A config.alloy change reloads Alloy; a changed config.env or' \
    'extra-args.txt, or --restart-alloy, restarts it, because Alloy reads those only' \
    'when it starts. A failure restores the printed rollback record. --no-start' \
    'installs files without starting anything, and only runs while Alloy and both' \
    'launchd jobs are stopped. Alloy must be a version listed in' \
    'agents/alloy/alloy-versions.env.'
}

die() {
  printf 'SkyEye trading setup: %s\n' "$*" >&2
  exit 1
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "$name is required in $ENV_FILE"
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

render_plist() {
  local template="$1"
  local target="$2"
  local executable_path="$3"
  local log_dir="$4"
  local env_escaped executable_escaped log_escaped
  env_escaped="$(escape_sed_replacement "$ENV_FILE")"
  executable_escaped="$(escape_sed_replacement "$executable_path")"
  log_escaped="$(escape_sed_replacement "$log_dir")"
  sed \
    -e "s|@@ENV_FILE@@|$env_escaped|g" \
    -e "s|@@PROBE_PATH@@|$executable_escaped|g" \
    -e "s|@@HISTORY_PATH@@|$executable_escaped|g" \
    -e "s|@@LOG_DIR@@|$log_escaped|g" \
    "$template" >"$target"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      [[ $# -ge 2 ]] || die "--env-file requires a path"
      ENV_FILE="$2"
      shift 2
      ;;
    --render-only)
      [[ $# -ge 2 ]] || die "--render-only requires a directory"
      RENDER_ONLY_DIR="$2"
      shift 2
      ;;
    --no-start)
      NO_START=1
      shift
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
[[ "$NO_START" -eq 0 || "$RESTART_ALLOY" -eq 0 ]] || \
  die "--no-start and --restart-alloy are mutually exclusive"

command -v brew >/dev/null 2>&1 || die "Homebrew is required"
BREW_PREFIX="$(brew --prefix)"
[[ -n "$ENV_FILE" ]] || ENV_FILE="$BREW_PREFIX/etc/alloy/config.env"

[[ -f "$TEMPLATE" ]] || die "missing Alloy template: $TEMPLATE"
[[ -f "$PLIST_TEMPLATE" ]] || die "missing launchd template: $PLIST_TEMPLATE"
[[ -f "$HISTORY_PLIST_TEMPLATE" ]] || die "missing launchd template: $HISTORY_PLIST_TEMPLATE"
[[ -x "$SOURCE_PROBE" ]] || die "missing executable probe: $SOURCE_PROBE"
[[ -x "$SOURCE_HISTORY" ]] || die "missing executable P&L history builder: $SOURCE_HISTORY"
[[ -f "$ENV_FILE" ]] || die "env file not found: $ENV_FILE"
[[ "$ENV_FILE" != *"'"* ]] || die "single quotes are not supported in env file path"

mode="$(file_mode "$ENV_FILE")"
[[ "$mode" == "600" ]] || die "env file must have mode 600, found $mode"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for required_name in \
  TQ_PRODUCT \
  TQ_ENVIRONMENT \
  TQ_SERVER_ID \
  TQ_STRATEGY \
  TQ_INSTANCE_ID \
  TQ_REPO_ROOT \
  TQ_REPO_ROOT_REGEX \
  TQ_EXECUTABLE \
  TQ_CONFIG_PATH \
  TQ_RAW_LOG_GLOB \
  TQ_RUN_MANIFEST \
  TQ_DONE_MARKER \
  TQ_POC_RUN_EXPECTED \
  TQ_REQUIRE_RUNTIME_CONTRACT \
  TQ_TIMEZONE \
  TQ_TEXTFILE_DIR \
  TQ_PNL_HISTORY_CACHE_DIR \
  TQ_PNL_HISTORY_DAYS \
  TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES \
  LOKI_PUSH_URL \
  PROM_PUSH_URL \
  CF_ACCESS_CLIENT_ID \
  CF_ACCESS_CLIENT_SECRET
do
  require_env "$required_name"
done

[[ "$TQ_ENVIRONMENT" == "development" || "$TQ_ENVIRONMENT" == "production" ]] || \
  die "TQ_ENVIRONMENT must be development or production"
[[ "$TQ_POC_RUN_EXPECTED" == "0" || "$TQ_POC_RUN_EXPECTED" == "1" ]] || \
  die "TQ_POC_RUN_EXPECTED must be 0 or 1"
[[ "$TQ_REQUIRE_RUNTIME_CONTRACT" == "0" || "$TQ_REQUIRE_RUNTIME_CONTRACT" == "1" ]] || \
  die "TQ_REQUIRE_RUNTIME_CONTRACT must be 0 or 1"
[[ "$TQ_TIMEZONE" =~ ^[A-Za-z0-9_+./-]+$ ]] || die "invalid TQ_TIMEZONE"
[[ "$TQ_REPO_ROOT" == /* ]] || die "TQ_REPO_ROOT must be absolute"
[[ "$TQ_CONFIG_PATH" == /* ]] || die "TQ_CONFIG_PATH must be absolute"
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
[[ -d "$TQ_REPO_ROOT" ]] || die "repo root not found: $TQ_REPO_ROOT"
[[ -f "$TQ_CONFIG_PATH" ]] || die "config not found: $TQ_CONFIG_PATH"

if [[ -z "$RENDER_ONLY_DIR" ]]; then
  case "$CF_ACCESS_CLIENT_ID:$CF_ACCESS_CLIENT_SECRET" in
    *replace-with*|*fake-*) die "replace the Cloudflare service-token placeholders" ;;
  esac
fi

if [[ -n "$RENDER_ONLY_DIR" ]]; then
  install -d -m 700 "$RENDER_ONLY_DIR"
  install -m 600 "$TEMPLATE" "$RENDER_ONLY_DIR/config.alloy"
  install -m 755 "$SOURCE_PROBE" "$RENDER_ONLY_DIR/probe.sh"
  install -m 755 "$SOURCE_HISTORY" "$RENDER_ONLY_DIR/pnl-history.sh"
  render_plist \
    "$PLIST_TEMPLATE" \
    "$RENDER_ONLY_DIR/com.wanbrain.skyeye-trading-probe.plist" \
    "$RENDER_ONLY_DIR/probe.sh" \
    "$RENDER_ONLY_DIR"
  render_plist \
    "$HISTORY_PLIST_TEMPLATE" \
    "$RENDER_ONLY_DIR/com.wanbrain.skyeye-trading-pnl-history.plist" \
    "$RENDER_ONLY_DIR/pnl-history.sh" \
    "$RENDER_ONLY_DIR"
  chmod 600 "$RENDER_ONLY_DIR"/*.plist
  printf 'Rendered Alloy config and launchd plists under %s\n' "$RENDER_ONLY_DIR"
  exit 0
fi

# ───────────────────────────── Preflight ───────────────────────────────────

[[ -f "$INSTALL_COMMON" ]] || die "missing shared helper library: $INSTALL_COMMON"
# shellcheck source=agents/alloy/install-common.sh
source "$INSTALL_COMMON"

ALLOY_CONFIG_DIR="$BREW_PREFIX/etc/alloy"
ALLOY_CONFIG="$ALLOY_CONFIG_DIR/config.alloy"
# The brew service wrapper reads these two when Alloy starts, and only then.
ALLOY_ENV="$ALLOY_CONFIG_DIR/config.env"
ALLOY_EXTRA_ARGS="$ALLOY_CONFIG_DIR/extra-args.txt"
INSTALL_ROOT="$BREW_PREFIX/libexec/skyeye-trading"
LOG_DIR="$BREW_PREFIX/var/log/alloy"
STATE_DIR="$BREW_PREFIX/var/skyeye-trading"
ENV_RECORD="$STATE_DIR/installed-env.sha256"
BACKUP_ROOT="$STATE_DIR/install-backup"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT="$LAUNCH_AGENT_DIR/$PROBE_LABEL.plist"
HISTORY_LAUNCH_AGENT="$LAUNCH_AGENT_DIR/$HISTORY_LABEL.plist"
domain="gui/$(id -u)"

# Held until this script exits, so two runs cannot interleave their rollbacks.
install -d -m 700 "$STATE_DIR"
skyeye_take_host_lock "$STATE_DIR/setup.lock" || die "$SKYEYE_INSTALL_ERROR"

if ! command -v alloy >/dev/null 2>&1; then
  brew tap grafana/grafana
  brew_version="$(brew info --json=v2 "$ALLOY_FORMULA" | plutil -extract formulae.0.versions.stable raw -o - -)" || \
    die "cannot read the $ALLOY_FORMULA version from brew info"
  skyeye_alloy_version_ok macos "$brew_version" "Homebrew's $ALLOY_FORMULA" || \
    die "$SKYEYE_INSTALL_ERROR. Alloy was not installed"
  printf 'Installing Grafana Alloy %s with Homebrew\n' "$brew_version"
  brew install "$ALLOY_FORMULA"
fi
skyeye_alloy_version_gate macos || die "$SKYEYE_INSTALL_ERROR. Nothing was changed"

# Alloy listens where extra-args.txt says, 127.0.0.1:12345 by default.
alloy_url() {
  local pattern='--server[.]http[.]listen-addr[=[:space:]]+([^[:space:]]+)'
  local args="" listen="" host
  if [[ -f "$ALLOY_EXTRA_ARGS" ]]; then
    args="$(tr '\n' ' ' <"$ALLOY_EXTRA_ARGS")"
  fi
  if [[ "$args" =~ $pattern ]]; then
    listen="${BASH_REMATCH[1]}"
  fi
  [[ -n "$listen" ]] || listen=127.0.0.1:12345
  host="${listen%:*}"
  case "$host" in
    "" | 0.0.0.0 | "[::]") host=127.0.0.1 ;;
  esac
  printf 'http://%s:%s\n' "$host" "${listen##*:}"
}
ALLOY_URL="$(alloy_url)"

job_loaded() {
  launchctl print "$domain/$1" >/dev/null 2>&1
}

alloy_ready() {
  curl -fsS -m 5 -o /dev/null "$ALLOY_URL/-/ready" >/dev/null 2>&1
}

# A crash loop can answer once, so a second answer a moment later is required.
wait_ready() {
  local waited=0
  while [[ "$waited" -lt "$READY_SECONDS" ]]; do
    if alloy_ready; then
      sleep 2
      if alloy_ready; then
        return 0
      fi
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# Alloy answers 400 with the error, and keeps its old config, when it rejects one.
alloy_reload() {
  local response
  if ! response="$(curl -sS -m 30 --fail-with-body -X POST "$ALLOY_URL/-/reload" 2>&1)"; then
    printf 'Alloy rejected the reload: %s\n' "$response" >&2
    return 1
  fi
}

# What Alloy reads when it starts: a change here needs a restart, not a reload.
start_inputs_sha() {
  {
    printf 'config.env\n'
    if [[ -f "$ALLOY_ENV" ]]; then cat "$ALLOY_ENV"; fi
    printf '\nextra-args.txt\n'
    if [[ -f "$ALLOY_EXTRA_ARGS" ]]; then cat "$ALLOY_EXTRA_ARGS"; fi
  } | shasum -a 256 | sed 's/[[:space:]].*//'
}

# ───────────────────────────── Stage ───────────────────────────────────────

# Parallel arrays: destination, final mode, staged file, whether it changes.
DESTS=(
  "$INSTALL_ROOT/probe.sh"
  "$INSTALL_ROOT/pnl-history.sh"
  "$ALLOY_CONFIG"
  "$LAUNCH_AGENT"
  "$HISTORY_LAUNCH_AGENT"
)
MODES=(755 755 600 600 600)
STAGED=("" "" "" "" "")
CHANGED=(0 0 0 0 0)
INDEXES="0 1 2 3 4"
CONFIG_INDEX=2
PROBE_PLIST_INDEX=3
HISTORY_PLIST_INDEX=4

VALIDATE_DIR=""
TRANSACTION_BACKUP=""
SWAPPED=0
COMMITTED=0
ALLOY_ACTION=none
ALLOY_TOUCHED=0
PROBE_TOUCHED=0
HISTORY_TOUCHED=0

for index in $INDEXES; do
  dest="${DESTS[$index]}"
  if [[ -L "$dest" ]] || { [[ -e "$dest" ]] && [[ ! -f "$dest" ]]; }; then
    die "$dest must be a regular file; refusing to replace it"
  fi
done

record_status() {
  if [[ -n "$TRANSACTION_BACKUP" ]]; then
    printf 'status=%s\n' "$1" >>"$TRANSACTION_BACKUP/transaction.meta" 2>/dev/null || true
  fi
}

restore_job() {
  local label="$1" plist="$2" touched="$3" was_loaded="$4"
  [[ "$touched" -eq 1 ]] || return 0
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  if [[ "$was_loaded" -eq 1 ]]; then
    launchctl bootstrap "$domain" "$plist" && launchctl enable "$domain/$label" && job_loaded "$label"
  elif job_loaded "$label"; then
    return 1
  fi
}

# Restores the recorded files, then the services this run touched. Runs from
# the EXIT trap with set -e off, so each step reports its own failure.
rollback() {
  local failed=0 target
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    rm -f -- "$target" || failed=1
  done <"$TRANSACTION_BACKUP/absent.list"
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    cp -p "$TRANSACTION_BACKUP/previous/${target#/}" "$target" || failed=1
  done <"$TRANSACTION_BACKUP/present.list"
  if [[ "$ALLOY_TOUCHED" -eq 1 ]]; then
    case "$ALLOY_ACTION" in
      reload)
        alloy_reload && wait_ready || failed=1
        ;;
      restart)
        brew services restart "$ALLOY_FORMULA" >/dev/null 2>&1 || failed=1
        if [[ "$ALLOY_WAS_READY" -eq 1 ]]; then
          wait_ready || failed=1
        fi
        ;;
      start)
        brew services stop "$ALLOY_FORMULA" >/dev/null 2>&1 || failed=1
        ;;
    esac
  fi
  restore_job "$PROBE_LABEL" "$LAUNCH_AGENT" "$PROBE_TOUCHED" "$PROBE_WAS_LOADED" || failed=1
  restore_job "$HISTORY_LABEL" "$HISTORY_LAUNCH_AGENT" "$HISTORY_TOUCHED" "$HISTORY_WAS_LOADED" || failed=1
  return "$failed"
}

on_exit() {
  local status=$?
  set +e
  trap - EXIT
  trap '' HUP INT TERM
  if [[ "$SWAPPED" -eq 1 && "$COMMITTED" -eq 0 ]]; then
    [[ "$status" -ne 0 ]] || status=1
    if rollback; then
      record_status rolled_back
      printf 'SkyEye trading setup: install failed; files, Alloy and both launchd jobs are back to their state before this run. Record: %s\n' \
        "$TRANSACTION_BACKUP" >&2
    else
      status=3
      record_status rollback_incomplete
      printf '%s\n' \
        "CRITICAL: rollback did not finish. The files from before this run are in $TRANSACTION_BACKUP/previous (see present.list and absent.list)." \
        "          Check by hand: brew services info $ALLOY_FORMULA; curl -fsS $ALLOY_URL/-/ready" \
        "          launchctl print $domain/$PROBE_LABEL; launchctl print $domain/$HISTORY_LABEL" >&2
    fi
  fi
  for index in $INDEXES; do
    [[ -z "${STAGED[$index]}" ]] || rm -f "${STAGED[$index]}"
  done
  [[ -z "$VALIDATE_DIR" ]] || rm -rf "$VALIDATE_DIR"
  exit "$status"
}
trap on_exit EXIT

install -d -m 700 "$INSTALL_ROOT" "$LOG_DIR" "$TQ_TEXTFILE_DIR"
install -d -m 755 "$ALLOY_CONFIG_DIR" "$LAUNCH_AGENT_DIR"

# Staged beside the destination so the swap is a rename on one filesystem.
# mktemp creates each file 0600, and no staged name ends in .alloy or .plist,
# so neither Alloy's directory mode nor launchd ever loads one.
for index in $INDEXES; do
  dest="${DESTS[$index]}"
  STAGED[$index]="$(mktemp "$(dirname "$dest")/.$(basename "$dest").staged.XXXXXX")"
done
cat "$SOURCE_PROBE" >"${STAGED[0]}"
cat "$SOURCE_HISTORY" >"${STAGED[1]}"
cat "$TEMPLATE" >"${STAGED[$CONFIG_INDEX]}"
render_plist "$PLIST_TEMPLATE" "${STAGED[$PROBE_PLIST_INDEX]}" "$INSTALL_ROOT/probe.sh" "$LOG_DIR"
render_plist "$HISTORY_PLIST_TEMPLATE" "${STAGED[$HISTORY_PLIST_INDEX]}" \
  "$INSTALL_ROOT/pnl-history.sh" "$LOG_DIR"
for index in $INDEXES; do
  chmod "${MODES[$index]}" "${STAGED[$index]}"
done

# ───────────────────────────── Validate ────────────────────────────────────

printf 'Validating the staged files\n'
bash -n "${STAGED[0]}" || die "probe.sh does not parse; nothing was changed"
bash -n "${STAGED[1]}" || die "pnl-history.sh does not parse; nothing was changed"
plutil -lint "${STAGED[$PROBE_PLIST_INDEX]}" >/dev/null || \
  die "the probe launchd plist is invalid; nothing was changed"
plutil -lint "${STAGED[$HISTORY_PLIST_INDEX]}" >/dev/null || \
  die "the P&L history launchd plist is invalid; nothing was changed"
# The brew service runs Alloy on the whole directory, so validate the staged
# config together with every other *.alloy file in it.
VALIDATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-alloy-validate.XXXXXX")"
find "$ALLOY_CONFIG_DIR" -maxdepth 1 -type f -name '*.alloy' ! -name config.alloy \
  -exec cp -p {} "$VALIDATE_DIR/" \;
cp "${STAGED[$CONFIG_INDEX]}" "$VALIDATE_DIR/config.alloy"
alloy fmt "$VALIDATE_DIR/config.alloy" >/dev/null || die "alloy fmt rejected the config; nothing was changed"
alloy validate "$VALIDATE_DIR" || die "alloy validate rejected the config; nothing was changed"

# ───────────────────────────── Plan ────────────────────────────────────────

any_changed=0
for index in $INDEXES; do
  dest="${DESTS[$index]}"
  if [[ ! -f "$dest" ]] || ! cmp -s "${STAGED[$index]}" "$dest" ||
    [[ "$(file_mode "$dest")" != "${MODES[$index]}" ]]; then
    CHANGED[$index]=1
    any_changed=1
  fi
done

ALLOY_WAS_LOADED=0
ALLOY_WAS_READY=0
PROBE_WAS_LOADED=0
HISTORY_WAS_LOADED=0
if job_loaded "$ALLOY_SERVICE_LABEL"; then ALLOY_WAS_LOADED=1; fi
if alloy_ready; then ALLOY_WAS_READY=1; fi
if job_loaded "$PROBE_LABEL"; then PROBE_WAS_LOADED=1; fi
if job_loaded "$HISTORY_LABEL"; then HISTORY_WAS_LOADED=1; fi
START_SHA="$(start_inputs_sha)"
RECORDED_SHA=""
if [[ -f "$ENV_RECORD" ]]; then
  RECORDED_SHA="$(sed -n 1p "$ENV_RECORD")"
fi

PROBE_BOOTSTRAP=0
HISTORY_BOOTSTRAP=0
alloy_reason=""
if [[ "$NO_START" -eq 1 ]]; then
  if [[ "$ALLOY_WAS_LOADED" -eq 1 || "$ALLOY_WAS_READY" -eq 1 ||
        "$PROBE_WAS_LOADED" -eq 1 || "$HISTORY_WAS_LOADED" -eq 1 ]]; then
    die "--no-start installs files without applying them, so it only runs while Alloy and both launchd jobs are stopped. Something is running here; re-run without --no-start, which reloads Alloy for a config-only change. Nothing was changed"
  fi
  alloy_reason="--no-start"
else
  if [[ "$ALLOY_WAS_LOADED" -eq 0 && "$ALLOY_WAS_READY" -eq 1 ]]; then
    die "an Alloy answers at $ALLOY_URL but the $ALLOY_SERVICE_LABEL service is not loaded in $domain; this script manages only that service. Nothing was changed"
  fi
  if [[ "${CHANGED[$PROBE_PLIST_INDEX]}" -eq 1 || "$PROBE_WAS_LOADED" -eq 0 ]]; then
    PROBE_BOOTSTRAP=1
  fi
  if [[ "${CHANGED[$HISTORY_PLIST_INDEX]}" -eq 1 || "$HISTORY_WAS_LOADED" -eq 0 ]]; then
    HISTORY_BOOTSTRAP=1
  fi
  if [[ "$ALLOY_WAS_LOADED" -eq 0 ]]; then
    ALLOY_ACTION=start
    alloy_reason="the brew service is not loaded"
  elif [[ "$RESTART_ALLOY" -eq 1 ]]; then
    ALLOY_ACTION=restart
    alloy_reason="--restart-alloy"
  elif [[ -z "$RECORDED_SHA" ]]; then
    ALLOY_ACTION=restart
    alloy_reason="no record of the config.env and extra-args.txt Alloy started with"
  elif [[ "$RECORDED_SHA" != "$START_SHA" ]]; then
    ALLOY_ACTION=restart
    alloy_reason="config.env or extra-args.txt changed since the last install"
  elif [[ "$ALLOY_WAS_READY" -eq 0 ]]; then
    ALLOY_ACTION=restart
    alloy_reason="Alloy is loaded but not ready at $ALLOY_URL/-/ready"
  elif [[ "${CHANGED[$CONFIG_INDEX]}" -eq 1 ]]; then
    ALLOY_ACTION=reload
    alloy_reason="config.alloy changed; its environment did not"
  else
    alloy_reason="config.alloy, config.env and extra-args.txt are unchanged"
  fi
fi

if [[ "$any_changed" -eq 0 && "$ALLOY_ACTION" == "none" &&
      "$PROBE_BOOTSTRAP" -eq 0 && "$HISTORY_BOOTSTRAP" -eq 0 ]]; then
  if [[ "$NO_START" -eq 1 ]]; then
    printf 'Already installed (no changes; nothing started because of --no-start)\n'
  else
    printf 'Already installed and running (no changes; Alloy and the launchd jobs untouched)\n'
  fi
  exit 0
fi
printf 'Alloy action: %s (%s)\n' "$ALLOY_ACTION" "$alloy_reason"

# ───────────────────────────── Record + swap ───────────────────────────────

# Holds only what this run replaces or adds. None of it is secret: the config
# reads credentials with sys.env and the plists name only the env file path.
TRANSACTION_BACKUP="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$"
install -d -m 700 "$BACKUP_ROOT" "$TRANSACTION_BACKUP" "$TRANSACTION_BACKUP/previous"
: >"$TRANSACTION_BACKUP/present.list"
: >"$TRANSACTION_BACKUP/absent.list"
for index in $INDEXES; do
  [[ "${CHANGED[$index]}" -eq 1 ]] || continue
  dest="${DESTS[$index]}"
  if [[ -f "$dest" ]]; then
    mkdir -p "$TRANSACTION_BACKUP/previous$(dirname "$dest")"
    cp -p "$dest" "$TRANSACTION_BACKUP/previous$dest"
    printf '%s\n' "$dest" >>"$TRANSACTION_BACKUP/present.list"
  else
    printf '%s\n' "$dest" >>"$TRANSACTION_BACKUP/absent.list"
  fi
done
{
  printf 'alloy_action=%s\n' "$ALLOY_ACTION"
  printf 'alloy_was_loaded=%s\n' "$ALLOY_WAS_LOADED"
  printf 'alloy_was_ready=%s\n' "$ALLOY_WAS_READY"
  printf 'probe_was_loaded=%s\n' "$PROBE_WAS_LOADED"
  printf 'history_was_loaded=%s\n' "$HISTORY_WAS_LOADED"
} >"$TRANSACTION_BACKUP/transaction.meta"

# Signals wait for the renames, so SWAPPED always matches what is on disk.
swap_in_staged_files() {
  trap '' HUP INT TERM
  SWAPPED=1
  for index in $INDEXES; do
    [[ "${CHANGED[$index]}" -eq 1 ]] || continue
    mv -f "${STAGED[$index]}" "${DESTS[$index]}"
    STAGED[$index]=""
  done
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
swap_in_staged_files

# ───────────────────────────── Apply ───────────────────────────────────────

if [[ "$NO_START" -eq 0 ]]; then
  ALLOY_TOUCHED=1
  case "$ALLOY_ACTION" in
    reload)
      alloy_reload || die "Alloy reload failed"
      wait_ready || die "Alloy is not ready at $ALLOY_URL/-/ready after the reload"
      ;;
    restart | start)
      brew services restart "$ALLOY_FORMULA" || die "brew services restart $ALLOY_FORMULA failed"
      wait_ready || die "Alloy did not become ready at $ALLOY_URL/-/ready within ${READY_SECONDS}s"
      ;;
  esac

  # launchd reads a plist only when the job is bootstrapped. A changed probe
  # or history script needs nothing: each run of the job executes the file.
  apply_job() {
    local label="$1" plist="$2" was_loaded="$3"
    if [[ "$was_loaded" -eq 1 ]]; then
      launchctl bootout "$domain/$label" || return 1
    fi
    launchctl bootstrap "$domain" "$plist" || return 1
    launchctl enable "$domain/$label" || return 1
    job_loaded "$label"
  }
  if [[ "$PROBE_BOOTSTRAP" -eq 1 ]]; then
    PROBE_TOUCHED=1
    apply_job "$PROBE_LABEL" "$LAUNCH_AGENT" "$PROBE_WAS_LOADED" || \
      die "could not load launchd job $PROBE_LABEL"
  fi
  if [[ "$HISTORY_BOOTSTRAP" -eq 1 ]]; then
    HISTORY_TOUCHED=1
    apply_job "$HISTORY_LABEL" "$HISTORY_LAUNCH_AGENT" "$HISTORY_WAS_LOADED" || \
      die "could not load launchd job $HISTORY_LABEL"
  fi
fi

# The install is proven; a failure from here on must not undo it.
COMMITTED=1
record_status committed
if [[ "$ALLOY_ACTION" == "start" || "$ALLOY_ACTION" == "restart" ]]; then
  if ! { printf '%s\n' "$START_SHA" >"$ENV_RECORD.tmp" && mv -f "$ENV_RECORD.tmp" "$ENV_RECORD"; }; then
    printf 'WARNING: could not write %s; the next run will restart Alloy instead of reloading it\n' \
      "$ENV_RECORD" >&2
  fi
fi

if [[ "$NO_START" -eq 1 ]]; then
  printf 'Installed and validated without starting services (--no-start)\n'
fi
printf 'Rollback record: %s\n' "$TRANSACTION_BACKUP"
printf 'Alloy: %s\n' "$SKYEYE_ALLOY_VERSION"
printf 'Probe launchd label: %s\n' "$PROBE_LABEL"
printf 'P&L history launchd label: %s\n' "$HISTORY_LABEL"
printf 'Alloy config: %s\n' "$ALLOY_CONFIG"
printf 'Probe metrics: %s/tnauqquant.prom\n' "$TQ_TEXTFILE_DIR"
printf 'P&L history metrics: %s/tnauqquant-pnl-history.prom\n' "$TQ_TEXTFILE_DIR"
