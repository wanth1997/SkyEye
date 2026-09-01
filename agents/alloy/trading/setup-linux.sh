#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/config-linux.alloy.tmpl"
SERVICE_TEMPLATE="$SCRIPT_DIR/skyeye-trading-probe.service.tmpl"
TIMER_TEMPLATE="$SCRIPT_DIR/skyeye-trading-probe.timer.tmpl"
SOURCE_PROBE="$SCRIPT_DIR/probe.sh"
SOURCE_ACCESS="$SCRIPT_DIR/ensure-log-access.sh"
ENV_FILE=""
RENDER_ONLY_DIR=""
NO_START=0

usage() {
  printf '%s\n' \
    'Usage: setup-linux.sh --env-file PATH [--render-only DIR] [--no-start]' \
    '' \
    'Installs a trading fragment into an existing Alloy deployment. The base' \
    'configuration must define prometheus.remote_write.central and loki.write.central.'
}

die() {
  printf 'SkyEye trading Linux setup: %s\n' "$*" >&2
  exit 1
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "$name is required in $ENV_FILE"
}

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

valid_label_value() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

render_alloy() {
  local target="$1"
  local raw_log_glob product environment server_id strategy repo_regex textfile_dir
  raw_log_glob="$(escape_sed_replacement "$TQ_RAW_LOG_GLOB")"
  product="$(escape_sed_replacement "$TQ_PRODUCT")"
  environment="$(escape_sed_replacement "$TQ_ENVIRONMENT")"
  server_id="$(escape_sed_replacement "$TQ_SERVER_ID")"
  strategy="$(escape_sed_replacement "$TQ_STRATEGY")"
  repo_regex="$(escape_sed_replacement "$TQ_REPO_ROOT_REGEX")"
  textfile_dir="$(escape_sed_replacement "$TQ_TEXTFILE_DIR")"
  sed \
    -e "s|@@RAW_LOG_GLOB@@|$raw_log_glob|g" \
    -e "s|@@PRODUCT@@|$product|g" \
    -e "s|@@ENVIRONMENT@@|$environment|g" \
    -e "s|@@SERVER_ID@@|$server_id|g" \
    -e "s|@@STRATEGY@@|$strategy|g" \
    -e "s|@@REPO_ROOT_REGEX@@|$repo_regex|g" \
    -e "s|@@TEXTFILE_DIR@@|$textfile_dir|g" \
    "$TEMPLATE" >"$target"
}

render_unit() {
  local template="$1"
  local target="$2"
  local env_path="$3"
  local probe_path="$4"
  local access_path="$5"
  local env_escaped probe_escaped access_escaped user_escaped group_escaped
  env_escaped="$(escape_sed_replacement "$env_path")"
  probe_escaped="$(escape_sed_replacement "$probe_path")"
  access_escaped="$(escape_sed_replacement "$access_path")"
  user_escaped="$(escape_sed_replacement "$TQ_PROBE_USER")"
  group_escaped="$(escape_sed_replacement "$TQ_PROBE_GROUP")"
  sed \
    -e "s|@@ENV_FILE@@|$env_escaped|g" \
    -e "s|@@PROBE_PATH@@|$probe_escaped|g" \
    -e "s|@@ACCESS_PATH@@|$access_escaped|g" \
    -e "s|@@PROBE_USER@@|$user_escaped|g" \
    -e "s|@@PROBE_GROUP@@|$group_escaped|g" \
    "$template" >"$target"
}

render_artifacts() {
  local target_dir="$1"
  local rendered_env="$target_dir/config.env"
  local rendered_probe="$target_dir/probe.sh"
  local rendered_access="$target_dir/ensure-log-access.sh"
  install -d -m 700 "$target_dir"
  render_alloy "$target_dir/trading.alloy"
  install -m 600 "$ENV_FILE" "$rendered_env"
  install -m 755 "$SOURCE_PROBE" "$rendered_probe"
  install -m 755 "$SOURCE_ACCESS" "$rendered_access"
  render_unit "$SERVICE_TEMPLATE" "$target_dir/skyeye-trading-probe.service" \
    "$rendered_env" "$rendered_probe" "$rendered_access"
  render_unit "$TIMER_TEMPLATE" "$target_dir/skyeye-trading-probe.timer" \
    "$rendered_env" "$rendered_probe" "$rendered_access"
  chmod 644 \
    "$target_dir/trading.alloy" \
    "$target_dir/skyeye-trading-probe.service" \
    "$target_dir/skyeye-trading-probe.timer"
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

[[ -n "$ENV_FILE" ]] || die "--env-file is required"
[[ -f "$TEMPLATE" ]] || die "missing Alloy template: $TEMPLATE"
[[ -f "$SERVICE_TEMPLATE" ]] || die "missing systemd service template: $SERVICE_TEMPLATE"
[[ -f "$TIMER_TEMPLATE" ]] || die "missing systemd timer template: $TIMER_TEMPLATE"
[[ -x "$SOURCE_PROBE" ]] || die "missing executable probe: $SOURCE_PROBE"
[[ -x "$SOURCE_ACCESS" ]] || die "missing executable log access helper: $SOURCE_ACCESS"
[[ -f "$ENV_FILE" ]] || die "env file not found: $ENV_FILE"

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
  TQ_EXECUTOR_MAP \
  TQ_SIDECAR_REQUIRED \
  TQ_TEXTFILE_MODE \
  TQ_PROBE_USER \
  TQ_PROBE_GROUP \
  TQ_ALLOY_USER \
  TQ_ALLOY_GROUP
do
  require_env "$required_name"
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

[[ "$TQ_ENVIRONMENT" == "development" || "$TQ_ENVIRONMENT" == "production" ]] || \
  die "TQ_ENVIRONMENT must be development or production"
[[ "$TQ_SIDECAR_REQUIRED" == "0" || "$TQ_SIDECAR_REQUIRED" == "1" ]] || \
  die "TQ_SIDECAR_REQUIRED must be 0 or 1"
[[ "$TQ_TEXTFILE_MODE" == "640" ]] || \
  die "Linux coexistence requires TQ_TEXTFILE_MODE=640"

for absolute_path in \
  "$TQ_REPO_ROOT" \
  "$TQ_EXECUTABLE" \
  "$TQ_CONFIG_PATH" \
  "$TQ_RAW_LOG_GLOB" \
  "$TQ_RUN_MANIFEST" \
  "$TQ_DONE_MARKER" \
  "$TQ_TEXTFILE_DIR"
do
  [[ "$absolute_path" == /* ]] || die "path must be absolute: $absolute_path"
  [[ "$absolute_path" != *[[:space:]\"\']* ]] || die "unsafe monitored path: $absolute_path"
done

[[ "$TQ_REPO_ROOT_REGEX" != *[\"$'\n']* ]] || die "unsafe TQ_REPO_ROOT_REGEX"
[[ -d "$TQ_REPO_ROOT" ]] || die "repo root not found: $TQ_REPO_ROOT"
[[ -f "$TQ_CONFIG_PATH" ]] || die "config not found: $TQ_CONFIG_PATH"

if [[ -n "$RENDER_ONLY_DIR" ]]; then
  render_artifacts "$RENDER_ONLY_DIR"
  printf 'Rendered Linux trading artifacts under %s\n' "$RENDER_ONLY_DIR"
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || die "installation must run as root"
for command_name in alloy find getent getfacl grep install runuser sed setfacl systemctl
do
  command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
done
id "$TQ_PROBE_USER" >/dev/null 2>&1 || die "probe user not found: $TQ_PROBE_USER"
id "$TQ_ALLOY_USER" >/dev/null 2>&1 || die "Alloy user not found: $TQ_ALLOY_USER"
getent group "$TQ_PROBE_GROUP" >/dev/null || die "probe group not found: $TQ_PROBE_GROUP"
getent group "$TQ_ALLOY_GROUP" >/dev/null || die "Alloy group not found: $TQ_ALLOY_GROUP"

ALLOY_CONFIG_DIR=/etc/alloy
ALLOY_ENV_FILE=/etc/default/alloy
ALLOY_FRAGMENT="$ALLOY_CONFIG_DIR/trading.alloy"
INSTALL_ROOT=/usr/local/libexec/skyeye-trading
INSTALL_ENV_DIR=/etc/skyeye-trading
INSTALL_ENV="$INSTALL_ENV_DIR/config.env"
SYSTEMD_DIR=/etc/systemd/system
SERVICE_PATH="$SYSTEMD_DIR/skyeye-trading-probe.service"
TIMER_PATH="$SYSTEMD_DIR/skyeye-trading-probe.timer"

grep -R -q --include='*.alloy' 'prometheus.remote_write "central"' "$ALLOY_CONFIG_DIR" || \
  die "existing Alloy config does not define prometheus.remote_write.central"
grep -R -q --include='*.alloy' 'loki.write "central"' "$ALLOY_CONFIG_DIR" || \
  die "existing Alloy config does not define loki.write.central"

RENDER_ROOT="$(mktemp -d /tmp/skyeye-trading-install.XXXXXX)"
STAGING_CONFIG="$(mktemp -d /tmp/skyeye-alloy-validate.XXXXXX)"
cleanup() {
  rm -rf "$RENDER_ROOT" "$STAGING_CONFIG"
}
trap cleanup EXIT

render_artifacts "$RENDER_ROOT"
find "$ALLOY_CONFIG_DIR" -maxdepth 1 -type f -name '*.alloy' \
  ! -name 'trading.alloy' -exec cp -p {} "$STAGING_CONFIG/" \;
install -m 644 "$RENDER_ROOT/trading.alloy" "$STAGING_CONFIG/trading.alloy"

printf 'Validating the combined Alloy configuration before installation\n'
alloy validate "$STAGING_CONFIG"

install -d -m 755 "$ALLOY_CONFIG_DIR" "$INSTALL_ROOT" "$INSTALL_ENV_DIR"
install -d -o "$TQ_PROBE_USER" -g "$TQ_ALLOY_GROUP" -m 2770 "$TQ_TEXTFILE_DIR"
runuser -u "$TQ_PROBE_USER" -- test -x "$TQ_TEXTFILE_DIR" || \
  die "probe user cannot traverse textfile directory: $TQ_TEXTFILE_DIR"
runuser -u "$TQ_PROBE_USER" -- test -w "$TQ_TEXTFILE_DIR" || \
  die "probe user cannot write textfile directory: $TQ_TEXTFILE_DIR"
install -m 755 "$RENDER_ROOT/probe.sh" "$INSTALL_ROOT/probe.sh"
install -m 755 "$RENDER_ROOT/ensure-log-access.sh" \
  "$INSTALL_ROOT/ensure-log-access.sh"
install -m 600 "$ENV_FILE" "$INSTALL_ENV"
install -m 644 "$RENDER_ROOT/trading.alloy" "$ALLOY_FRAGMENT"
render_unit "$SERVICE_TEMPLATE" "$SERVICE_PATH" "$INSTALL_ENV" \
  "$INSTALL_ROOT/probe.sh" "$INSTALL_ROOT/ensure-log-access.sh"
render_unit "$TIMER_TEMPLATE" "$TIMER_PATH" "$INSTALL_ENV" \
  "$INSTALL_ROOT/probe.sh" "$INSTALL_ROOT/ensure-log-access.sh"
chmod 644 "$SERVICE_PATH" "$TIMER_PATH"

probe_home="$(getent passwd "$TQ_PROBE_USER" | awk -F: '{ print $6 }')"
raw_log_dir="${TQ_RAW_LOG_GLOB%/*}"
raw_log_pattern="${TQ_RAW_LOG_GLOB##*/}"
if [[ "$raw_log_dir" == "$probe_home"/* ]]; then
  setfacl -m "u:$TQ_ALLOY_USER:r-x" "$raw_log_dir"
  acl_path="$(dirname "$raw_log_dir")"
  while [[ "$acl_path" == "$probe_home" || "$acl_path" == "$probe_home"/* ]]; do
    setfacl -m "u:$TQ_ALLOY_USER:--x" "$acl_path"
    [[ "$acl_path" == "$probe_home" ]] && break
    acl_path="$(dirname "$acl_path")"
  done
fi

runuser -u "$TQ_PROBE_USER" -- "$INSTALL_ROOT/ensure-log-access.sh"

ALLOY_ENV_BACKUP="$ALLOY_ENV_FILE.skyeye-trading.bak.$(date +%s)"
cp -p "$ALLOY_ENV_FILE" "$ALLOY_ENV_BACKUP"
ALLOY_DIRECTORY_SETTING='CONFIG_FILE="/etc/alloy"'
if grep -q '^CONFIG_FILE=' "$ALLOY_ENV_FILE"; then
  sed 's|^CONFIG_FILE=.*$|CONFIG_FILE="/etc/alloy"|' "$ALLOY_ENV_FILE" \
    >"$ALLOY_ENV_FILE.tmp"
else
  cp -p "$ALLOY_ENV_FILE" "$ALLOY_ENV_FILE.tmp"
  printf '\n%s\n' "$ALLOY_DIRECTORY_SETTING" >>"$ALLOY_ENV_FILE.tmp"
fi
install -m "$(file_mode "$ALLOY_ENV_FILE")" "$ALLOY_ENV_FILE.tmp" "$ALLOY_ENV_FILE"
rm -f "$ALLOY_ENV_FILE.tmp"

alloy validate "$ALLOY_CONFIG_DIR"
systemctl daemon-reload

if [[ "$NO_START" -eq 1 ]]; then
  printf 'Installed and validated without restarting Alloy or enabling the timer (--no-start)\n'
  printf 'Alloy environment backup: %s\n' "$ALLOY_ENV_BACKUP"
  exit 0
fi

if ! systemctl restart alloy; then
  cp -p "$ALLOY_ENV_BACKUP" "$ALLOY_ENV_FILE"
  systemctl restart alloy || true
  die "Alloy restart failed; restored $ALLOY_ENV_FILE"
fi

systemctl enable --now skyeye-trading-probe.timer
systemctl start skyeye-trading-probe.service
systemctl is-active --quiet alloy || die "Alloy is not active after installation"
systemctl is-active --quiet skyeye-trading-probe.timer || die "trading probe timer is not active"

first_log="$(find "$raw_log_dir" -maxdepth 1 -type f -name "$raw_log_pattern" -print -quit)"
if [[ -n "$first_log" ]]; then
  runuser -u "$TQ_ALLOY_USER" -- test -r "$first_log" || \
    die "Alloy user cannot read configured raw logs"
fi

printf 'Installed Linux trading monitoring fragment: %s\n' "$ALLOY_FRAGMENT"
printf 'Alloy environment backup: %s\n' "$ALLOY_ENV_BACKUP"
printf 'Probe metrics: %s/tnauqquant.prom\n' "$TQ_TEXTFILE_DIR"
