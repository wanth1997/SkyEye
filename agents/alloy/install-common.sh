# shellcheck shell=bash
# The SKYEYE_* results are read by the scripts that source this file.
# shellcheck disable=SC2034
# Shared guards for the SkyEye Alloy host scripts: setup.sh, uninstall.sh and
# trading/{setup-linux,retire-linux,setup-macos}.sh. Source it; do not run it.
# macOS runs these scripts with /bin/bash, so keep this file bash 3.2 safe.
#
# A function that refuses returns non-zero and leaves the reason in
# SKYEYE_INSTALL_ERROR, so each caller reports it in its own format and picks
# its own exit code.

SKYEYE_INSTALL_ERROR=""
SKYEYE_ALLOY_VERSION=""
SKYEYE_ALLOY_VERSIONS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/alloy-versions.env"

skyeye_load_alloy_versions() {
  if [[ ! -f "$SKYEYE_ALLOY_VERSIONS_FILE" ]]; then
    SKYEYE_INSTALL_ERROR="missing $SKYEYE_ALLOY_VERSIONS_FILE; copy the whole agents/alloy directory"
    return 1
  fi
  # shellcheck source=agents/alloy/alloy-versions.env
  . "$SKYEYE_ALLOY_VERSIONS_FILE"
  if [[ -z "${SKYEYE_ALLOY_LINUX_VERSIONS:-}" || -z "${SKYEYE_ALLOY_MACOS_VERSIONS:-}" ||
        -z "${SKYEYE_ALLOY_APT_VERSION:-}" ]]; then
    SKYEYE_INSTALL_ERROR="$SKYEYE_ALLOY_VERSIONS_FILE does not list the tested Alloy versions"
    return 1
  fi
}

# Prints the version from `alloy --version` output, whose first line reads
# "alloy, version v1.18.1 (branch: HEAD, ...)". Prints nothing otherwise.
skyeye_alloy_parse_version() {
  local pattern='^alloy, version v?([0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.+-]+)?)([[:space:]]|$)'
  local first_line="${1%%$'\n'*}"
  if [[ "$first_line" =~ $pattern ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

# skyeye_alloy_version_ok PLATFORM VERSION WHAT
# Accepts VERSION when it is listed for PLATFORM (linux or macos). An unlisted
# version passes only when SKYEYE_ALLOY_UNTESTED_VERSION names exactly that
# version, so a variable left set from an earlier run cannot wave through a
# different one. WHAT names the version in messages, e.g. "installed Alloy".
skyeye_alloy_version_ok() {
  local platform="$1" version="$2" what="$3" tested candidate
  skyeye_load_alloy_versions || return 1
  case "$platform" in
    linux) tested="$SKYEYE_ALLOY_LINUX_VERSIONS" ;;
    macos) tested="$SKYEYE_ALLOY_MACOS_VERSIONS" ;;
    *)
      SKYEYE_INSTALL_ERROR="unknown platform for the Alloy version check: $platform"
      return 1
      ;;
  esac
  if [[ -z "$version" ]]; then
    SKYEYE_INSTALL_ERROR="cannot tell which version $what is"
    return 1
  fi
  for candidate in $tested; do
    if [[ "$candidate" == "$version" ]]; then
      return 0
    fi
  done
  if [[ -n "${SKYEYE_ALLOY_UNTESTED_VERSION:-}" ]]; then
    if [[ "$SKYEYE_ALLOY_UNTESTED_VERSION" == "$version" ]]; then
      printf 'WARNING: %s %s is not tested on %s (tested: %s); continuing because SKYEYE_ALLOY_UNTESTED_VERSION=%s\n' \
        "$what" "$version" "$platform" "$tested" "$version" >&2
      return 0
    fi
    SKYEYE_INSTALL_ERROR="SKYEYE_ALLOY_UNTESTED_VERSION=$SKYEYE_ALLOY_UNTESTED_VERSION does not match $what $version; it must name that exact version"
    return 1
  fi
  SKYEYE_INSTALL_ERROR="$what $version is not tested on $platform (tested: $tested). Use a tested version, or test this one and add it to agents/alloy/alloy-versions.env (see Alloy versions in agents/alloy/README.md)"
  return 1
}

# skyeye_alloy_version_gate PLATFORM
# Checks the Alloy on PATH and sets SKYEYE_ALLOY_VERSION.
skyeye_alloy_version_gate() {
  local output first_line
  output="$(alloy --version 2>&1)" || output=""
  first_line="${output%%$'\n'*}"
  SKYEYE_ALLOY_VERSION="$(skyeye_alloy_parse_version "$output")"
  if [[ -z "$SKYEYE_ALLOY_VERSION" ]]; then
    SKYEYE_INSTALL_ERROR="cannot read a version from 'alloy --version' (first line: ${first_line:-empty})"
    return 1
  fi
  skyeye_alloy_version_ok "$1" "$SKYEYE_ALLOY_VERSION" "installed Alloy"
}

# skyeye_take_host_lock PATH
# Takes an exclusive flock(2) on PATH through fd 9 and keeps it until this
# shell exits. It never waits. The kernel drops the lock when the last process
# holding fd 9 exits, so a killed run leaves no stale lock; a child that is
# still running with the inherited fd keeps it until that child exits. perl
# locks the descriptor it inherits, because macOS has no flock(1); Linux
# (perl-base) and macOS both ship perl. The file is created mode 0600 so no
# other user can open it and hold the lock.
skyeye_take_host_lock() {
  local lock_path="$1" old_umask rc=0
  if [[ -L "$lock_path" ]]; then
    SKYEYE_INSTALL_ERROR="lock file $lock_path is a symlink; remove it and re-run"
    return 1
  fi
  old_umask="$(umask)"
  umask 077
  if ! exec 9>>"$lock_path"; then
    umask "$old_umask"
    SKYEYE_INSTALL_ERROR="cannot open lock file $lock_path"
    return 1
  fi
  umask "$old_umask"
  perl -MFcntl=:flock -e \
    'open(my $fh, ">>&=", 9) or exit 2; exit(flock($fh, LOCK_EX | LOCK_NB) ? 0 : 1)' || rc=$?
  case "$rc" in
    0)
      return 0
      ;;
    1)
      SKYEYE_INSTALL_ERROR="another SkyEye Alloy install, retire or uninstall holds $lock_path. Nothing was changed; re-run after it finishes"
      ;;
    *)
      SKYEYE_INSTALL_ERROR="could not lock $lock_path (perl exited $rc). Nothing was changed"
      ;;
  esac
  exec 9>&-
  return 1
}
