#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/config-macos.alloy.tmpl"
PLIST_TEMPLATE="$SCRIPT_DIR/com.wanbrain.skyeye-trading-probe.plist.tmpl"
SOURCE_PROBE="$SCRIPT_DIR/probe.sh"
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
  local target="$1"
  local probe_path="$2"
  local log_dir="$3"
  local env_escaped probe_escaped log_escaped
  env_escaped="$(escape_sed_replacement "$ENV_FILE")"
  probe_escaped="$(escape_sed_replacement "$probe_path")"
  log_escaped="$(escape_sed_replacement "$log_dir")"
  sed \
    -e "s|@@ENV_FILE@@|$env_escaped|g" \
    -e "s|@@PROBE_PATH@@|$probe_escaped|g" \
    -e "s|@@LOG_DIR@@|$log_escaped|g" \
    "$PLIST_TEMPLATE" >"$target"
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
[[ -x "$SOURCE_PROBE" ]] || die "missing executable probe: $SOURCE_PROBE"
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
  TQ_TEXTFILE_DIR \
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
[[ "$TQ_REPO_ROOT" == /* ]] || die "TQ_REPO_ROOT must be absolute"
[[ "$TQ_CONFIG_PATH" == /* ]] || die "TQ_CONFIG_PATH must be absolute"
[[ "$TQ_RAW_LOG_GLOB" == /* ]] || die "TQ_RAW_LOG_GLOB must be absolute"
[[ "$TQ_TEXTFILE_DIR" == /* ]] || die "TQ_TEXTFILE_DIR must be absolute"
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
  render_plist \
    "$RENDER_ONLY_DIR/com.wanbrain.skyeye-trading-probe.plist" \
    "$RENDER_ONLY_DIR/probe.sh" \
    "$RENDER_ONLY_DIR"
  chmod 600 "$RENDER_ONLY_DIR/com.wanbrain.skyeye-trading-probe.plist"
  printf 'Rendered Alloy config and launchd plist under %s\n' "$RENDER_ONLY_DIR"
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

install -d -m 700 "$INSTALL_ROOT" "$LOG_DIR" "$TQ_TEXTFILE_DIR"
install -d -m 755 "$ALLOY_CONFIG_DIR" "$LAUNCH_AGENT_DIR"
install -m 755 "$SOURCE_PROBE" "$INSTALL_ROOT/probe.sh"
install -m 600 "$TEMPLATE" "$ALLOY_CONFIG"
render_plist "$LAUNCH_AGENT" "$INSTALL_ROOT/probe.sh" "$LOG_DIR"
chmod 600 "$LAUNCH_AGENT"

printf 'Validating Alloy config\n'
alloy fmt "$ALLOY_CONFIG" >/dev/null
alloy validate "$ALLOY_CONFIG"
plutil -lint "$LAUNCH_AGENT" >/dev/null

if [[ "$NO_START" -eq 1 ]]; then
  printf 'Installed and validated without starting services (--no-start)\n'
  exit 0
fi

domain="gui/$(id -u)"
launchctl bootout "$domain" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
launchctl bootstrap "$domain" "$LAUNCH_AGENT"
launchctl enable "$domain/com.wanbrain.skyeye-trading-probe"
brew services restart grafana/grafana/alloy

printf 'Alloy: %s\n' "$(alloy --version | head -n 1)"
printf 'Probe launchd label: com.wanbrain.skyeye-trading-probe\n'
printf 'Alloy config: %s\n' "$ALLOY_CONFIG"
printf 'Probe metrics: %s/tnauqquant.prom\n' "$TQ_TEXTFILE_DIR"
