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

# The probe's TQ_BASE_ASSET rule: 1-16 ASCII upper-case letters or digits,
# spelled out so no locale widens the class. Keep it equal to probe.sh.
valid_base_asset() {
  [[ "$1" =~ ^[ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789]{1,16}$ ]]
}

# Comma-separated <executor>=<exchange> pairs. Multiple distinct executors may
# map to the same exchange (e.g. popdex-main=popdex,popdex-rot2=popdex). Empty
# segments, trailing commas, invalid labels and duplicate executors are refused.
valid_executor_map() {
  local mapping="$1"
  [[ -n "$mapping" && "$mapping" != ,* && "$mapping" != *, && "$mapping" != *,,* ]] || return 1
  local entries=()
  local old_ifs="$IFS"
  IFS=',' read -r -a entries <<<"$mapping"
  IFS="$old_ifs"
  [[ "${#entries[@]}" -gt 0 ]] || return 1
  local entry executor exchange seen_executors=","
  for entry in "${entries[@]}"; do
    [[ "$entry" == *=* ]] || return 1
    executor="${entry%%=*}"
    exchange="${entry#*=}"
    [[ "$exchange" != *=* ]] || return 1
    valid_label_value "$executor" || return 1
    valid_label_value "$exchange" || return 1
    [[ "$seen_executors" != *",$executor,"* ]] || return 1
    seen_executors+="$executor,"
  done
}

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

# Runs a command as USER with / as its working directory. runuser keeps the
# caller's working directory, which the user may not be able to open (a root
# shell in /root, mode 700); GNU find then lists its files and still exits 1
# with "Failed to restore initial working directory".
run_as_user() {
  local user="$1"
  shift
  (cd / && exec runuser -u "$user" -- "$@")
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

# Reads NAME's value from an env file without executing it, decoding the
# assignment forms that bash `source` and systemd EnvironmentFile= both read
# the same way: NAME=value (no whitespace, quotes, $, backquote, backslash,
# ~ or shell operators), NAME="value" (no $, backquote, backslash or ") and
# NAME='value' (no '). Trailing whitespace is ignored and the last assignment
# wins. Prints nothing when NAME is absent; fails on any other syntax.
installed_env_value() {
  local name="$1"
  local path="$2"
  local line="" candidate value readable=1
  while IFS= read -r candidate || [[ -n "$candidate" ]]; do
    if [[ "$candidate" == "$name="* ]]; then
      line="$candidate"
    fi
  done <"$path"
  [[ -n "$line" ]] || return 0
  value="${line#"$name"=}"
  value="${value%"${value##*[![:space:]]}"}"
  case "$value" in
    \'*\')
      value="${value:1:${#value}-2}"
      case "$value" in
        *\'*) readable=0 ;;
      esac
      ;;
    \"*\")
      value="${value:1:${#value}-2}"
      case "$value" in
        *[\"\\\$\`]*) readable=0 ;;
      esac
      ;;
    *[[:space:]\'\"\\\$\`\;\&\|\<\>\(\)~]*) readable=0 ;;
  esac
  if [[ "$readable" -eq 0 ]]; then
    printf 'cannot read %s from %s without executing it; use NAME=value, NAME="value" or NAME='"'"'value'"'"' with no $, backquote or backslash\n' \
      "$name" "$path" >&2
    return 1
  fi
  printf '%s\n' "$value"
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
