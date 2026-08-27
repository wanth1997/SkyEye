#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/config-macos.alloy.tmpl"
PLIST_TEMPLATE="$SCRIPT_DIR/com.wanbrain.skyeye-trading-probe.plist.tmpl"
HISTORY_PLIST_TEMPLATE="$SCRIPT_DIR/com.wanbrain.skyeye-trading-pnl-history.plist.tmpl"
SOURCE_PROBE="$SCRIPT_DIR/probe.sh"
SOURCE_HISTORY="$SCRIPT_DIR/pnl-history.sh"
RENDER_ONLY_DIR=""
ENV_FILE=""
NO_START=0

usage() {
  printf '%s\n' \
    'Usage: setup-macos.sh [--env-file PATH] [--render-only DIR] [--no-start]' \
    '' \
    'Default env file: <brew-prefix>/etc/alloy/config.env'
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

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

if ! command -v alloy >/dev/null 2>&1; then
  printf 'Installing Grafana Alloy with Homebrew\n'
  brew tap grafana/grafana
  brew install grafana/grafana/alloy
fi

ALLOY_CONFIG_DIR="$BREW_PREFIX/etc/alloy"
ALLOY_CONFIG="$ALLOY_CONFIG_DIR/config.alloy"
INSTALL_ROOT="$BREW_PREFIX/libexec/skyeye-trading"
LOG_DIR="$BREW_PREFIX/var/log/alloy"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT="$LAUNCH_AGENT_DIR/com.wanbrain.skyeye-trading-probe.plist"
HISTORY_LAUNCH_AGENT="$LAUNCH_AGENT_DIR/com.wanbrain.skyeye-trading-pnl-history.plist"

install -d -m 700 "$INSTALL_ROOT" "$LOG_DIR" "$TQ_TEXTFILE_DIR"
install -d -m 755 "$ALLOY_CONFIG_DIR" "$LAUNCH_AGENT_DIR"
install -m 755 "$SOURCE_PROBE" "$INSTALL_ROOT/probe.sh"
install -m 755 "$SOURCE_HISTORY" "$INSTALL_ROOT/pnl-history.sh"
install -m 600 "$TEMPLATE" "$ALLOY_CONFIG"
render_plist "$PLIST_TEMPLATE" "$LAUNCH_AGENT" "$INSTALL_ROOT/probe.sh" "$LOG_DIR"
render_plist "$HISTORY_PLIST_TEMPLATE" "$HISTORY_LAUNCH_AGENT" \
  "$INSTALL_ROOT/pnl-history.sh" "$LOG_DIR"
chmod 600 "$LAUNCH_AGENT" "$HISTORY_LAUNCH_AGENT"

printf 'Validating Alloy config\n'
alloy fmt "$ALLOY_CONFIG" >/dev/null
alloy validate "$ALLOY_CONFIG"
plutil -lint "$LAUNCH_AGENT" >/dev/null
plutil -lint "$HISTORY_LAUNCH_AGENT" >/dev/null

if [[ "$NO_START" -eq 1 ]]; then
  printf 'Installed and validated without starting services (--no-start)\n'
  exit 0
fi

domain="gui/$(id -u)"
launchctl bootout "$domain" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
launchctl bootout "$domain" "$HISTORY_LAUNCH_AGENT" >/dev/null 2>&1 || true
launchctl bootstrap "$domain" "$LAUNCH_AGENT"
launchctl bootstrap "$domain" "$HISTORY_LAUNCH_AGENT"
launchctl enable "$domain/com.wanbrain.skyeye-trading-probe"
launchctl enable "$domain/com.wanbrain.skyeye-trading-pnl-history"
brew services restart grafana/grafana/alloy

printf 'Alloy: %s\n' "$(alloy --version | head -n 1)"
printf 'Probe launchd label: com.wanbrain.skyeye-trading-probe\n'
printf 'P&L history launchd label: com.wanbrain.skyeye-trading-pnl-history\n'
printf 'Alloy config: %s\n' "$ALLOY_CONFIG"
printf 'Probe metrics: %s/tnauqquant.prom\n' "$TQ_TEXTFILE_DIR"
printf 'P&L history metrics: %s/tnauqquant-pnl-history.prom\n' "$TQ_TEXTFILE_DIR"
