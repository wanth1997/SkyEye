# shellcheck shell=bash
# Shared guards for the Linux Trading monitoring host scripts
# (setup-linux.sh and retire-linux.sh). Source it; do not execute it.
# Callers must define die() before calling these functions.

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

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

# Sets TEST_SYSTEM_ROOT. In test mode every argument must resolve below
# SKYEYE_TRADING_TEST_ROOT; otherwise the caller must be root.
init_system_root() {
  local test_scoped_path resolved_test_path
  TEST_SYSTEM_ROOT="${SKYEYE_TRADING_TEST_ROOT:-}"
  if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
    [[ "$TEST_SYSTEM_ROOT" == /* && "$TEST_SYSTEM_ROOT" != "/" ]] || \
      die "SKYEYE_TRADING_TEST_ROOT must be an absolute non-root path"
    mkdir -p "$TEST_SYSTEM_ROOT"
    TEST_SYSTEM_ROOT="$(cd "$TEST_SYSTEM_ROOT" && pwd -P)"
    for test_scoped_path in "$@"; do
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
}

system_path() {
  local absolute_path="$1"
  if [[ -n "$TEST_SYSTEM_ROOT" ]]; then
    printf '%s%s\n' "$TEST_SYSTEM_ROOT" "$absolute_path"
  else
    printf '%s\n' "$absolute_path"
  fi
}

# Sets SYSTEMCTL_BIN to an absolute, non-symlink path. Test mode requires a
# stub below the test root so no real unit can ever be touched.
resolve_systemctl() {
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
}

# Reads NAME=value from an env file without executing it.
installed_env_value() {
  local name="$1"
  local path="$2"
  sed -n "s/^${name}=//p" "$path" | tail -n 1
}

# Prints the Alloy fragments an Alloy reload/restart re-evaluates.
list_alloy_fragments() {
  local config_dir="$1"
  find "$config_dir" -maxdepth 1 -type f -name '*.alloy' -print 2>/dev/null | \
    sed 's|.*/||' | sort | tr '\n' ' '
}

# Prints "yes" when systemd can reload the Alloy unit in place.
alloy_can_reload() {
  "$SYSTEMCTL_BIN" show -p CanReload --value alloy 2>/dev/null || true
}
