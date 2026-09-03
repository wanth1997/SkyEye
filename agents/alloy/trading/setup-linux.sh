#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCE_TEMPLATE="$SCRIPT_DIR/config-linux.alloy.tmpl"
METRICS_TEMPLATE="$SCRIPT_DIR/config-linux-metrics.alloy.tmpl"
SERVICE_TEMPLATE="$SCRIPT_DIR/skyeye-trading-probe@.service.tmpl"
TIMER_TEMPLATE="$SCRIPT_DIR/skyeye-trading-probe@.timer.tmpl"
SOURCE_PROBE="$SCRIPT_DIR/probe.sh"
SOURCE_ACCESS="$SCRIPT_DIR/ensure-log-access.sh"
ENV_FILE=""
RENDER_ONLY_DIR=""
NO_START=0
MIGRATE_SINGLETON=0
COMPONENT_ID=""

usage() {
  printf '%s\n' \
    'Usage: setup-linux.sh --env-file PATH [--render-only DIR] [--no-start] [--migrate-singleton]' \
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

component_id_for_strategy() {
  local value="$1"
  value="${value//_/_u_}"
  value="${value//-/_h_}"
  value="${value//./_d_}"
  printf 'skyeye_trading_%s\n' "$value"
}

render_instance_alloy() {
  local target="$1"
  local raw_log_glob product environment server_id strategy repo_regex component_id
  raw_log_glob="$(escape_sed_replacement "$TQ_RAW_LOG_GLOB")"
  product="$(escape_sed_replacement "$TQ_PRODUCT")"
  environment="$(escape_sed_replacement "$TQ_ENVIRONMENT")"
  server_id="$(escape_sed_replacement "$TQ_SERVER_ID")"
  strategy="$(escape_sed_replacement "$TQ_STRATEGY")"
  repo_regex="$(escape_sed_replacement "$TQ_REPO_ROOT_REGEX")"
  component_id="$(escape_sed_replacement "$COMPONENT_ID")"
  sed \
    -e "s|@@RAW_LOG_GLOB@@|$raw_log_glob|g" \
    -e "s|@@PRODUCT@@|$product|g" \
    -e "s|@@ENVIRONMENT@@|$environment|g" \
    -e "s|@@SERVER_ID@@|$server_id|g" \
    -e "s|@@STRATEGY@@|$strategy|g" \
    -e "s|@@REPO_ROOT_REGEX@@|$repo_regex|g" \
    -e "s|@@COMPONENT_ID@@|$component_id|g" \
    "$INSTANCE_TEMPLATE" >"$target"
}

render_metrics_alloy() {
  local target="$1" textfile_dir
  textfile_dir="$(escape_sed_replacement "$TQ_TEXTFILE_DIR")"
  sed -e "s|@@TEXTFILE_DIR@@|$textfile_dir|g" \
    "$METRICS_TEMPLATE" >"$target"
}

render_unit() {
  local template="$1"
  local target="$2"
  local env_root="$3"
  local probe_path="$4"
  local access_path="$5"
  local env_escaped probe_escaped access_escaped user_escaped group_escaped
  env_escaped="$(escape_sed_replacement "$env_root")"
  probe_escaped="$(escape_sed_replacement "$probe_path")"
  access_escaped="$(escape_sed_replacement "$access_path")"
  user_escaped="$(escape_sed_replacement "$TQ_PROBE_USER")"
  group_escaped="$(escape_sed_replacement "$TQ_PROBE_GROUP")"
  sed \
    -e "s|@@ENV_ROOT@@|$env_escaped|g" \
    -e "s|@@PROBE_PATH@@|$probe_escaped|g" \
    -e "s|@@ACCESS_PATH@@|$access_escaped|g" \
    -e "s|@@PROBE_USER@@|$user_escaped|g" \
    -e "s|@@PROBE_GROUP@@|$group_escaped|g" \
    "$template" >"$target"
}

render_artifacts() {
  local target_dir="$1"
  local rendered_env_root="$target_dir/instances"
  local rendered_env="$rendered_env_root/$TQ_STRATEGY.env"
  local rendered_probe="$target_dir/probe.sh"
  local rendered_access="$target_dir/ensure-log-access.sh"
  install -d -m 700 "$target_dir"
  install -d -m 700 "$rendered_env_root"
  render_metrics_alloy "$target_dir/trading-metrics.alloy"
  render_instance_alloy "$target_dir/trading-$TQ_STRATEGY.alloy"
  install -m 600 "$ENV_FILE" "$rendered_env"
  install -m 755 "$SOURCE_PROBE" "$rendered_probe"
  install -m 755 "$SOURCE_ACCESS" "$rendered_access"
  render_unit "$SERVICE_TEMPLATE" "$target_dir/skyeye-trading-probe@.service" \
    "$rendered_env_root" "$rendered_probe" "$rendered_access"
  render_unit "$TIMER_TEMPLATE" "$target_dir/skyeye-trading-probe@.timer" \
    "$rendered_env_root" "$rendered_probe" "$rendered_access"
  chmod 644 \
    "$target_dir/trading-metrics.alloy" \
    "$target_dir/trading-$TQ_STRATEGY.alloy" \
    "$target_dir/skyeye-trading-probe@.service" \
    "$target_dir/skyeye-trading-probe@.timer"
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
    --migrate-singleton)
      MIGRATE_SINGLETON=1
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
[[ -f "$INSTANCE_TEMPLATE" ]] || die "missing Alloy instance template: $INSTANCE_TEMPLATE"
[[ -f "$METRICS_TEMPLATE" ]] || die "missing Alloy metrics template: $METRICS_TEMPLATE"
[[ -f "$SERVICE_TEMPLATE" ]] || die "missing systemd service template: $SERVICE_TEMPLATE"
[[ -f "$TIMER_TEMPLATE" ]] || die "missing systemd timer template: $TIMER_TEMPLATE"
[[ -x "$SOURCE_PROBE" ]] || die "missing executable probe: $SOURCE_PROBE"
[[ -x "$SOURCE_ACCESS" ]] || die "missing executable log access helper: $SOURCE_ACCESS"
[[ -f "$ENV_FILE" ]] || die "env file not found: $ENV_FILE"
[[ ! -L "$ENV_FILE" ]] || die "env file must not be a symlink: $ENV_FILE"

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
  TQ_TEXTFILE_NAME \
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

COMPONENT_ID="$(component_id_for_strategy "$TQ_STRATEGY")"
[[ "$COMPONENT_ID" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || \
  die "cannot derive a safe Alloy component ID from TQ_STRATEGY"
[[ "$TQ_TEXTFILE_NAME" == "tnauqquant-$TQ_STRATEGY.prom" ]] || \
  die "Linux multi-instance TQ_TEXTFILE_NAME must equal tnauqquant-$TQ_STRATEGY.prom"

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

TEST_SYSTEM_ROOT="${SKYEYE_TRADING_TEST_ROOT:-}"
if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
  [[ "$TEST_SYSTEM_ROOT" == /* && "$TEST_SYSTEM_ROOT" != "/" ]] || \
    die "SKYEYE_TRADING_TEST_ROOT must be an absolute non-root path"
  mkdir -p "$TEST_SYSTEM_ROOT"
  TEST_SYSTEM_ROOT="$(cd "$TEST_SYSTEM_ROOT" && pwd -P)"
  for test_scoped_path in "$ENV_FILE" "$TQ_REPO_ROOT" "$TQ_TEXTFILE_DIR"; do
    if [[ -d "$test_scoped_path" ]]; then
      resolved_test_path="$(cd "$test_scoped_path" && pwd -P)"
    else
      resolved_test_path="$(cd "$(dirname "$test_scoped_path")" && pwd -P)/$(basename "$test_scoped_path")"
    fi
    case "$resolved_test_path" in
      "$TEST_SYSTEM_ROOT"/*) ;;
      *) die "test-mode paths must stay below SKYEYE_TRADING_TEST_ROOT" ;;
    esac
  done
else
  [[ "$(id -u)" -eq 0 ]] || die "installation must run as root"
fi

system_path() {
  local absolute_path="$1"
  if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
    printf '%s%s\n' "$TEST_SYSTEM_ROOT" "$absolute_path"
  else
    printf '%s\n' "$absolute_path"
  fi
}

for command_name in alloy awk cmp cp date find getent getfacl grep install runuser sed setfacl systemctl tail
do
  command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
done
SYSTEMCTL_BIN="$(command -v systemctl)"
[[ "$SYSTEMCTL_BIN" == /* && -f "$SYSTEMCTL_BIN" && -x "$SYSTEMCTL_BIN" ]] || \
  die "systemctl must resolve to an absolute executable file"
SYSTEMCTL_BIN="$(cd "$(dirname "$SYSTEMCTL_BIN")" && pwd -P)/$(basename "$SYSTEMCTL_BIN")"
if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
  [[ ! -L "$SYSTEMCTL_BIN" ]] || \
    die "test mode requires a non-symlink systemctl stub below SKYEYE_TRADING_TEST_ROOT"
  case "$SYSTEMCTL_BIN" in
    "$TEST_SYSTEM_ROOT"/*) ;;
    *) die "test mode requires a systemctl stub below SKYEYE_TRADING_TEST_ROOT" ;;
  esac
fi
if [[ -z "$TEST_SYSTEM_ROOT" ]]; then
  id "$TQ_PROBE_USER" >/dev/null 2>&1 || die "probe user not found: $TQ_PROBE_USER"
  id "$TQ_ALLOY_USER" >/dev/null 2>&1 || die "Alloy user not found: $TQ_ALLOY_USER"
  getent group "$TQ_PROBE_GROUP" >/dev/null || die "probe group not found: $TQ_PROBE_GROUP"
  getent group "$TQ_ALLOY_GROUP" >/dev/null || die "Alloy group not found: $TQ_ALLOY_GROUP"
fi

ALLOY_CONFIG_DIR="$(system_path /etc/alloy)"
ALLOY_ENV_FILE="$(system_path /etc/default/alloy)"
ALLOY_METRICS_FRAGMENT="$ALLOY_CONFIG_DIR/trading-metrics.alloy"
ALLOY_INSTANCE_FRAGMENT="$ALLOY_CONFIG_DIR/trading-$TQ_STRATEGY.alloy"
INSTALL_ROOT="$(system_path /usr/local/libexec/skyeye-trading)"
INSTALL_ENV_DIR="$(system_path /etc/skyeye-trading)"
INSTALL_ENV_ROOT="$INSTALL_ENV_DIR/instances"
INSTALL_ENV="$INSTALL_ENV_ROOT/$TQ_STRATEGY.env"
BACKUP_ROOT="$INSTALL_ENV_DIR/install-backup"
SYSTEMD_DIR="$(system_path /etc/systemd/system)"
SERVICE_PATH="$SYSTEMD_DIR/skyeye-trading-probe@.service"
TIMER_PATH="$SYSTEMD_DIR/skyeye-trading-probe@.timer"
INSTANCE_SERVICE="skyeye-trading-probe@$TQ_STRATEGY.service"
INSTANCE_TIMER="skyeye-trading-probe@$TQ_STRATEGY.timer"
INSTANCE_TIMER_WANTS="$SYSTEMD_DIR/timers.target.wants/$INSTANCE_TIMER"

LEGACY_ALLOY_FRAGMENT="$ALLOY_CONFIG_DIR/trading.alloy"
LEGACY_ENV="$INSTALL_ENV_DIR/config.env"
LEGACY_SERVICE_PATH="$SYSTEMD_DIR/skyeye-trading-probe.service"
LEGACY_TIMER_PATH="$SYSTEMD_DIR/skyeye-trading-probe.timer"
LEGACY_TIMER_WANTS="$SYSTEMD_DIR/timers.target.wants/skyeye-trading-probe.timer"
LEGACY_METRICS="$TQ_TEXTFILE_DIR/tnauqquant.prom"
LEGACY_SERVICE=skyeye-trading-probe.service
LEGACY_TIMER=skyeye-trading-probe.timer

[[ -f "$ALLOY_ENV_FILE" ]] || die "existing Alloy environment file not found: $ALLOY_ENV_FILE"

grep -R -q --include='*.alloy' 'prometheus.remote_write "central"' "$ALLOY_CONFIG_DIR" || \
  die "existing Alloy config does not define prometheus.remote_write.central"
grep -R -q --include='*.alloy' 'loki.write "central"' "$ALLOY_CONFIG_DIR" || \
  die "existing Alloy config does not define loki.write.central"

RENDER_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-trading-install.XXXXXX")"
STAGING_CONFIG="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-alloy-validate.XXXXXX")"
TRANSACTION_BACKUP=""
MUTATION_STARTED=0
INSTALL_COMMITTED=0
LEGACY_TIMER_WAS_ENABLED=0
LEGACY_TIMER_WAS_ACTIVE=0
LEGACY_SERVICE_WAS_ACTIVE=0
ALLOY_WAS_ACTIVE=0

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

backup_path() {
  local source_path="$1"
  local relative_path="${source_path#/}"
  if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
    relative_path="${source_path#"$TEST_SYSTEM_ROOT"/}"
  fi
  if path_exists "$source_path"; then
    mkdir -p "$TRANSACTION_BACKUP/previous/$(dirname "$relative_path")"
    cp -a "$source_path" "$TRANSACTION_BACKUP/previous/$relative_path"
    printf '%s\n' "$source_path" >>"$TRANSACTION_BACKUP/present.list"
  else
    printf '%s\n' "$source_path" >>"$TRANSACTION_BACKUP/absent.list"
  fi
}

remove_exact_path() {
  local target_path="$1"
  if path_exists "$target_path"; then
    rm -f -- "$target_path"
  fi
}

restore_transaction() {
  local target_path relative_path
  [[ -n "$TRANSACTION_BACKUP" && -d "$TRANSACTION_BACKUP" ]] || return 0
  "$SYSTEMCTL_BIN" disable --now "$INSTANCE_TIMER" >/dev/null 2>&1 || true
  if [[ -f "$TRANSACTION_BACKUP/absent.list" ]]; then
    while IFS= read -r target_path; do
      [[ -n "$target_path" ]] || continue
      remove_exact_path "$target_path"
    done <"$TRANSACTION_BACKUP/absent.list"
  fi
  if [[ -f "$TRANSACTION_BACKUP/present.list" ]]; then
    while IFS= read -r target_path; do
      [[ -n "$target_path" ]] || continue
      relative_path="${target_path#/}"
      if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
        relative_path="${target_path#"$TEST_SYSTEM_ROOT"/}"
      fi
      remove_exact_path "$target_path"
      mkdir -p "$(dirname "$target_path")"
      cp -a "$TRANSACTION_BACKUP/previous/$relative_path" "$target_path"
    done <"$TRANSACTION_BACKUP/present.list"
  fi
  "$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true
  if [[ "$ALLOY_WAS_ACTIVE" -eq 1 ]]; then
    "$SYSTEMCTL_BIN" restart alloy >/dev/null 2>&1 || true
  else
    "$SYSTEMCTL_BIN" stop alloy >/dev/null 2>&1 || true
  fi
  if [[ "$LEGACY_TIMER_WAS_ENABLED" -eq 1 ]]; then
    "$SYSTEMCTL_BIN" enable "$LEGACY_TIMER" >/dev/null 2>&1 || true
  fi
  if [[ "$LEGACY_TIMER_WAS_ACTIVE" -eq 1 ]]; then
    "$SYSTEMCTL_BIN" start "$LEGACY_TIMER" >/dev/null 2>&1 || true
  fi
  if [[ "$LEGACY_SERVICE_WAS_ACTIVE" -eq 1 ]]; then
    "$SYSTEMCTL_BIN" start "$LEGACY_SERVICE" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 && "$MUTATION_STARTED" -eq 1 && "$INSTALL_COMMITTED" -eq 0 ]]; then
    printf 'SkyEye trading Linux setup: installation failed; restoring recorded files\n' >&2
    restore_transaction
  fi
  rm -rf "$RENDER_ROOT" "$STAGING_CONFIG"
  exit "$status"
}
trap cleanup EXIT

render_artifacts "$RENDER_ROOT"
render_unit "$SERVICE_TEMPLATE" "$RENDER_ROOT/installed-probe@.service" \
  "$INSTALL_ENV_ROOT" "$INSTALL_ROOT/probe.sh" "$INSTALL_ROOT/ensure-log-access.sh"
render_unit "$TIMER_TEMPLATE" "$RENDER_ROOT/installed-probe@.timer" \
  "$INSTALL_ENV_ROOT" "$INSTALL_ROOT/probe.sh" "$INSTALL_ROOT/ensure-log-access.sh"

legacy_paths=(
  "$LEGACY_ALLOY_FRAGMENT"
  "$LEGACY_ENV"
  "$LEGACY_SERVICE_PATH"
  "$LEGACY_TIMER_PATH"
  "$LEGACY_TIMER_WANTS"
  "$LEGACY_METRICS"
)
while IFS= read -r -d '' legacy_temp; do
  legacy_paths+=("$legacy_temp")
done < <(find "$TQ_TEXTFILE_DIR" -maxdepth 1 -name '.tnauqquant.prom.*' -print0 2>/dev/null)

legacy_present=0
for legacy_path in "${legacy_paths[@]}"; do
  if path_exists "$legacy_path"; then
    legacy_present=1
    break
  fi
done
if [[ "$legacy_present" -eq 1 && "$MIGRATE_SINGLETON" -ne 1 ]]; then
  die "legacy singleton artifacts exist; rerun once with --migrate-singleton during a maintenance cutover"
fi

if [[ "$MIGRATE_SINGLETON" -eq 1 ]]; then
  if "$SYSTEMCTL_BIN" is-enabled --quiet "$LEGACY_TIMER" >/dev/null 2>&1; then
    LEGACY_TIMER_WAS_ENABLED=1
  fi
  if "$SYSTEMCTL_BIN" is-active --quiet "$LEGACY_TIMER" >/dev/null 2>&1; then
    LEGACY_TIMER_WAS_ACTIVE=1
  fi
  if "$SYSTEMCTL_BIN" is-active --quiet "$LEGACY_SERVICE" >/dev/null 2>&1; then
    LEGACY_SERVICE_WAS_ACTIVE=1
  fi
fi

if "$SYSTEMCTL_BIN" is-active --quiet alloy >/dev/null 2>&1; then
  ALLOY_WAS_ACTIVE=1
fi

installed_env_value() {
  local name="$1"
  local path="$2"
  sed -n "s/^${name}=//p" "$path" | tail -n 1
}

if [[ -d "$INSTALL_ENV_ROOT" ]]; then
  for sibling_env in "$INSTALL_ENV_ROOT"/*.env; do
    [[ -f "$sibling_env" ]] || continue
    [[ "$sibling_env" == "$INSTALL_ENV" ]] && continue
    sibling_textfile_dir="$(installed_env_value TQ_TEXTFILE_DIR "$sibling_env")"
    [[ "$sibling_textfile_dir" == "$TQ_TEXTFILE_DIR" ]] || \
      die "all probe instances must share one TQ_TEXTFILE_DIR"
    for unique_name in \
      TQ_INSTANCE_ID \
      TQ_EXECUTABLE \
      TQ_CONFIG_PATH \
      TQ_RAW_LOG_GLOB \
      TQ_RUN_MANIFEST \
      TQ_DONE_MARKER \
      TQ_TEXTFILE_NAME
    do
      sibling_value="$(installed_env_value "$unique_name" "$sibling_env")"
      current_value="${!unique_name}"
      [[ -n "$sibling_value" && "$sibling_value" != "$current_value" ]] || \
        die "$unique_name must be non-empty and distinct across probe instances"
    done
  done
fi

shared_sources=(
  "$RENDER_ROOT/trading-metrics.alloy"
  "$RENDER_ROOT/probe.sh"
  "$RENDER_ROOT/ensure-log-access.sh"
  "$RENDER_ROOT/installed-probe@.service"
  "$RENDER_ROOT/installed-probe@.timer"
)
shared_destinations=(
  "$ALLOY_METRICS_FRAGMENT"
  "$INSTALL_ROOT/probe.sh"
  "$INSTALL_ROOT/ensure-log-access.sh"
  "$SERVICE_PATH"
  "$TIMER_PATH"
)
shared_changed=0
for index in "${!shared_sources[@]}"; do
  if [[ ! -f "${shared_destinations[$index]}" ]] || \
    ! cmp -s "${shared_sources[$index]}" "${shared_destinations[$index]}"; then
    shared_changed=1
    break
  fi
done

if [[ "$shared_changed" -eq 1 ]]; then
  if "$SYSTEMCTL_BIN" is-active --quiet 'skyeye-trading-probe@*.service' >/dev/null 2>&1 || \
    "$SYSTEMCTL_BIN" is-active --quiet 'skyeye-trading-probe@*.timer' >/dev/null 2>&1 || \
    "$SYSTEMCTL_BIN" is-enabled --quiet 'skyeye-trading-probe@*.timer' >/dev/null 2>&1; then
    die "shared probe artifacts changed while a templated probe service/timer is active or enabled"
  fi
  if [[ -d "$INSTALL_ENV_ROOT" ]]; then
    for installed_probe_env in "$INSTALL_ENV_ROOT"/*.env; do
      [[ -f "$installed_probe_env" ]] || continue
      installed_strategy="$(basename "$installed_probe_env" .env)"
      valid_label_value "$installed_strategy" || \
        die "installed probe env has an invalid strategy basename: $installed_probe_env"
      if "$SYSTEMCTL_BIN" is-active --quiet "skyeye-trading-probe@$installed_strategy.service" >/dev/null 2>&1 || \
        "$SYSTEMCTL_BIN" is-active --quiet "skyeye-trading-probe@$installed_strategy.timer" >/dev/null 2>&1 || \
        "$SYSTEMCTL_BIN" is-enabled --quiet "skyeye-trading-probe@$installed_strategy.timer" >/dev/null 2>&1; then
        die "shared probe artifacts changed while $installed_strategy is active or enabled"
      fi
    done
  fi
fi
if "$SYSTEMCTL_BIN" is-active --quiet "$INSTANCE_SERVICE" >/dev/null 2>&1 || \
  "$SYSTEMCTL_BIN" is-active --quiet "$INSTANCE_TIMER" >/dev/null 2>&1 || \
  "$SYSTEMCTL_BIN" is-enabled --quiet "$INSTANCE_TIMER" >/dev/null 2>&1; then
  die "target probe instance must be inactive and disabled before installation: $TQ_STRATEGY"
fi
for custom_instance_path in \
  "$SYSTEMD_DIR/$INSTANCE_SERVICE" \
  "$SYSTEMD_DIR/$INSTANCE_TIMER"
do
  ! path_exists "$custom_instance_path" || \
    die "custom concrete instance unit conflicts with reviewed template: $custom_instance_path"
done

find "$ALLOY_CONFIG_DIR" -maxdepth 1 -type f -name '*.alloy' \
  ! -name 'trading.alloy' \
  ! -name 'trading-metrics.alloy' \
  ! -name "trading-$TQ_STRATEGY.alloy" \
  -exec cp -p {} "$STAGING_CONFIG/" \;
install -m 644 "$RENDER_ROOT/trading-metrics.alloy" \
  "$STAGING_CONFIG/trading-metrics.alloy"
install -m 644 "$RENDER_ROOT/trading-$TQ_STRATEGY.alloy" \
  "$STAGING_CONFIG/trading-$TQ_STRATEGY.alloy"

printf 'Validating the combined Alloy configuration before installation\n'
alloy validate "$STAGING_CONFIG"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
TRANSACTION_BACKUP="$BACKUP_ROOT/$timestamp-$TQ_STRATEGY-$$"
install -d -m 700 "$BACKUP_ROOT" "$TRANSACTION_BACKUP"
touch "$TRANSACTION_BACKUP/present.list" "$TRANSACTION_BACKUP/absent.list"

paths_to_replace=(
  "$ALLOY_INSTANCE_FRAGMENT"
  "$INSTALL_ENV"
  "$ALLOY_ENV_FILE"
  "$INSTANCE_TIMER_WANTS"
)
if [[ "$shared_changed" -eq 1 ]]; then
  paths_to_replace+=("${shared_destinations[@]}")
fi
if [[ "$MIGRATE_SINGLETON" -eq 1 ]]; then
  paths_to_replace+=("${legacy_paths[@]}")
fi
for replace_path in "${paths_to_replace[@]}"; do
  backup_path "$replace_path"
done
{
  printf 'strategy=%s\n' "$TQ_STRATEGY"
  printf 'legacy_timer_was_enabled=%s\n' "$LEGACY_TIMER_WAS_ENABLED"
  printf 'legacy_timer_was_active=%s\n' "$LEGACY_TIMER_WAS_ACTIVE"
  printf 'legacy_service_was_active=%s\n' "$LEGACY_SERVICE_WAS_ACTIVE"
  printf 'created_at_utc=%s\n' "$timestamp"
} >"$TRANSACTION_BACKUP/transaction.meta"
MUTATION_STARTED=1

if [[ "$MIGRATE_SINGLETON" -eq 1 ]]; then
  if [[ "$legacy_present" -eq 1 || "$LEGACY_TIMER_WAS_ENABLED" -eq 1 || \
    "$LEGACY_TIMER_WAS_ACTIVE" -eq 1 || "$LEGACY_SERVICE_WAS_ACTIVE" -eq 1 ]]; then
    "$SYSTEMCTL_BIN" disable --now "$LEGACY_TIMER"
    "$SYSTEMCTL_BIN" stop "$LEGACY_SERVICE" >/dev/null 2>&1 || true
    ! "$SYSTEMCTL_BIN" is-active --quiet "$LEGACY_TIMER" >/dev/null 2>&1 || \
      die "legacy probe timer remained active after disable --now"
    ! "$SYSTEMCTL_BIN" is-enabled --quiet "$LEGACY_TIMER" >/dev/null 2>&1 || \
      die "legacy probe timer remained enabled after disable --now"
    ! "$SYSTEMCTL_BIN" is-active --quiet "$LEGACY_SERVICE" >/dev/null 2>&1 || \
      die "legacy probe service remained active after stop"
  fi
  for legacy_path in "${legacy_paths[@]}"; do
    remove_exact_path "$legacy_path"
  done
fi

install -d -m 755 "$ALLOY_CONFIG_DIR" "$INSTALL_ROOT"
install -d -m 700 "$INSTALL_ENV_DIR" "$INSTALL_ENV_ROOT"
if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
  install -d -m 2770 "$TQ_TEXTFILE_DIR"
else
  install -d -o "$TQ_PROBE_USER" -g "$TQ_ALLOY_GROUP" -m 2770 "$TQ_TEXTFILE_DIR"
fi
runuser -u "$TQ_PROBE_USER" -- test -x "$TQ_TEXTFILE_DIR" || \
  die "probe user cannot traverse textfile directory: $TQ_TEXTFILE_DIR"
runuser -u "$TQ_PROBE_USER" -- test -w "$TQ_TEXTFILE_DIR" || \
  die "probe user cannot write textfile directory: $TQ_TEXTFILE_DIR"
if [[ "$shared_changed" -eq 1 ]]; then
  install -m 755 "$RENDER_ROOT/probe.sh" "$INSTALL_ROOT/probe.sh"
  install -m 755 "$RENDER_ROOT/ensure-log-access.sh" \
    "$INSTALL_ROOT/ensure-log-access.sh"
  install -m 644 "$RENDER_ROOT/trading-metrics.alloy" "$ALLOY_METRICS_FRAGMENT"
  install -m 644 "$RENDER_ROOT/installed-probe@.service" "$SERVICE_PATH"
  install -m 644 "$RENDER_ROOT/installed-probe@.timer" "$TIMER_PATH"
fi
install -m 600 "$ENV_FILE" "$INSTALL_ENV"
install -m 644 "$RENDER_ROOT/trading-$TQ_STRATEGY.alloy" "$ALLOY_INSTANCE_FRAGMENT"

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

ALLOY_DIRECTORY_SETTING='CONFIG_FILE="/etc/alloy"'
if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
  ALLOY_DIRECTORY_SETTING="CONFIG_FILE=\"$ALLOY_CONFIG_DIR\""
fi
if grep -q '^CONFIG_FILE=' "$ALLOY_ENV_FILE"; then
  sed "s|^CONFIG_FILE=.*$|$ALLOY_DIRECTORY_SETTING|" "$ALLOY_ENV_FILE" \
    >"$ALLOY_ENV_FILE.tmp"
else
  cp -p "$ALLOY_ENV_FILE" "$ALLOY_ENV_FILE.tmp"
  printf '\n%s\n' "$ALLOY_DIRECTORY_SETTING" >>"$ALLOY_ENV_FILE.tmp"
fi
install -m "$(file_mode "$ALLOY_ENV_FILE")" "$ALLOY_ENV_FILE.tmp" "$ALLOY_ENV_FILE"
rm -f "$ALLOY_ENV_FILE.tmp"

alloy validate "$ALLOY_CONFIG_DIR"
"$SYSTEMCTL_BIN" daemon-reload

if [[ "$NO_START" -eq 1 ]]; then
  INSTALL_COMMITTED=1
  printf 'Installed and validated without restarting Alloy or enabling the timer (--no-start)\n'
  printf 'Rollback record: %s\n' "$TRANSACTION_BACKUP"
  exit 0
fi

if ! "$SYSTEMCTL_BIN" restart alloy; then
  die "Alloy restart failed"
fi

"$SYSTEMCTL_BIN" enable --now "$INSTANCE_TIMER"
"$SYSTEMCTL_BIN" start "$INSTANCE_SERVICE"
"$SYSTEMCTL_BIN" is-active --quiet alloy || die "Alloy is not active after installation"
"$SYSTEMCTL_BIN" is-active --quiet "$INSTANCE_TIMER" || die "trading probe timer is not active"

first_log="$(find "$raw_log_dir" -maxdepth 1 -type f -name "$raw_log_pattern" -print -quit)"
if [[ -n "$first_log" ]]; then
  runuser -u "$TQ_ALLOY_USER" -- test -r "$first_log" || \
    die "Alloy user cannot read configured raw logs"
fi

INSTALL_COMMITTED=1
printf 'Installed Linux trading monitoring fragment: %s\n' "$ALLOY_INSTANCE_FRAGMENT"
printf 'Rollback record: %s\n' "$TRANSACTION_BACKUP"
printf 'Probe metrics: %s/%s\n' "$TQ_TEXTFILE_DIR" "$TQ_TEXTFILE_NAME"
