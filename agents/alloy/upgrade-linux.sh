#!/usr/bin/env bash
#
# Moves an apt-installed Grafana Alloy to a version listed in alloy-versions.env,
# with an automatic rollback, or later back to the version it replaced.
#
# Usage:
#   sudo agents/alloy/upgrade-linux.sh --to VERSION [--check]
#   sudo agents/alloy/upgrade-linux.sh --rollback RECORD_DIR
#
# Before it changes anything, --to refuses unless it runs as root and holds
# /run/skyeye-alloy.lock, VERSION is listed for linux, the alloy package is
# installed and its binary reports the same version, apt offers exactly one
# VERSION-* package and still offers the installed one. It then downloads both
# packages, checks their names and versions, and validates the live CONFIG_FILE
# with the new binary. --check stops there and deletes what it downloaded.
#
# The change: unhold, dpkg --force-confold -i, daemon-reload, require
# /etc/default/alloy and every file in /etc/alloy to be unchanged, restart Alloy
# if it was running (unless the package scripts already did), then require one
# main process for 5 s, /-/ready within 60 s and the new version, and hold the
# package. Any failure reinstalls the previous package, restores those files and
# the hold, and brings Alloy back as it was; when the files had to be restored,
# Alloy is restarted after that, so it runs on the restored files.
#
# --rollback RECORD_DIR moves back to the package that RECORD_DIR replaced, with
# the same checks and the same automatic rollback. It leaves RECORD_DIR as it is
# and writes a record of its own (mode=rollback, rollback_of=RECORD_DIR).
#
# Every run that changes the host has one record under RECORD_ROOT: upgrade.meta
# (mode, from/to package, hold and service state, status), debs/ with both
# packages, and while the run is open conffiles/, a copy of /etc/default/alloy
# and /etc/alloy taken before the change. A CRITICAL exit names that record.
#
# Exit codes: 0 done, or nothing to do; 1 refused with nothing changed, or failed
# and rolled back; 2 usage; 3 CRITICAL: the rollback did not finish.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Shared with setup.sh, uninstall.sh and trading/{setup,retire}-linux.sh.
LOCK_FILE=/run/skyeye-alloy.lock
ALLOY_DEFAULTS=/etc/default/alloy
ALLOY_ETC=/etc/alloy
RECORD_ROOT=/var/lib/skyeye-alloy/upgrade
READY_TIMEOUT=60

PROG="SkyEye Alloy upgrade"
MODE=""
TARGET_VERSION=""
CHECK_ONLY=0
ROLLBACK_RECORD=""

usage() {
  printf 'usage: %s --to VERSION [--check]\n       %s --rollback RECORD_DIR\n' "$0" "$0" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)
      [[ $# -ge 2 && -z "$MODE" ]] || usage
      MODE=to
      TARGET_VERSION="$2"
      shift 2
      ;;
    --check)
      CHECK_ONLY=1
      shift
      ;;
    --rollback)
      [[ $# -ge 2 && -z "$MODE" ]] || usage
      MODE=rollback
      ROLLBACK_RECORD="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done
[[ -n "$MODE" ]] || usage
if [[ "$MODE" == "to" ]]; then
  [[ "$TARGET_VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || usage
else
  [[ "$CHECK_ONLY" -eq 0 && "$ROLLBACK_RECORD" == /* ]] || usage
fi

say() {
  printf '%s\n' "$*"
}

refuse() {
  printf '%s: refused, nothing was changed: %s\n' "$PROG" "$*" >&2
  exit 1
}

[[ "$(id -u)" -eq 0 ]] || refuse "run it as root (sudo)"

# shellcheck source=agents/alloy/install-common.sh
. "$SCRIPT_DIR/install-common.sh"
skyeye_load_alloy_versions || refuse "$SKYEYE_INSTALL_ERROR"

if [[ "$MODE" == "to" ]]; then
  listed=0
  for tested in $SKYEYE_ALLOY_LINUX_VERSIONS; do
    [[ "$tested" != "$TARGET_VERSION" ]] || listed=1
  done
  [[ "$listed" -eq 1 ]] || \
    refuse "Alloy $TARGET_VERSION is not tested on linux (tested: $SKYEYE_ALLOY_LINUX_VERSIONS); this script never installs an unlisted version"
fi

for tool in dpkg-query dpkg dpkg-deb apt-cache apt-get apt-mark systemctl curl sha256sum perl; do
  command -v "$tool" >/dev/null 2>&1 || refuse "$tool is not available; this script supports apt hosts only"
done

skyeye_take_host_lock "$LOCK_FILE" || refuse "$SKYEYE_INSTALL_ERROR"

# ─────────────────────────────── Read the host ──────────────────────────────

# Prints the installed package version, or nothing when alloy is not installed.
installed_deb() {
  local line status
  line="$(dpkg-query -W -f='${Status}\t${Version}\n' alloy 2>/dev/null)" || return 0
  status="${line%%$'\t'*}"
  case "$status" in
    "install ok installed"|"hold ok installed") printf '%s\n' "${line#*$'\t'}" ;;
  esac
}

binary_version() {
  local output
  output="$("$1" --version 2>&1)" || output=""
  skyeye_alloy_parse_version "$output"
}

defaults_value() {
  sed -nE "s/^$1=[\"']?([^\"']*)[\"']?[[:space:]]*$/\\1/p" "$ALLOY_DEFAULTS" | tail -n 1
}

main_pid() {
  systemctl show -p MainPID --value alloy 2>/dev/null || printf '0\n'
}

# One line per file: hash, mode, owner, path. Any difference is a change.
config_hashes() {
  {
    [[ ! -e "$ALLOY_DEFAULTS" ]] || printf '%s\n' "$ALLOY_DEFAULTS"
    [[ ! -d "$ALLOY_ETC" ]] || find "$ALLOY_ETC" \( -type f -o -type l \)
  } | LC_ALL=C sort | while IFS= read -r path; do
    printf '%s %s %s\n' "$(sha256sum <"$path" | cut -c1-64)" \
      "$(stat -c '%a %U:%G' "$path" 2>/dev/null || stat -f '%Lp %Su:%Sg' "$path")" "$path"
  done
}

CURRENT_DEB="$(installed_deb)"
[[ -n "$CURRENT_DEB" ]] || refuse "the alloy apt package is not installed (dpkg-query -W alloy)"
CURRENT_VERSION="$(binary_version alloy)"
[[ -n "$CURRENT_VERSION" ]] || refuse "cannot read a version from 'alloy --version'"
[[ "$CURRENT_DEB" == "$CURRENT_VERSION"-* ]] || \
  refuse "the alloy package is $CURRENT_DEB but the alloy binary reports $CURRENT_VERSION"

[[ -f "$ALLOY_DEFAULTS" ]] || refuse "$ALLOY_DEFAULTS not found"
CONFIG_PATH="$(defaults_value CONFIG_FILE)"
[[ -n "$CONFIG_PATH" && -e "$CONFIG_PATH" ]] || refuse "CONFIG_FILE in $ALLOY_DEFAULTS does not name an existing path"
listen_addr="$(defaults_value CUSTOM_ARGS | sed -nE 's/.*--server[.]http[.]listen-addr[= ]([^[:space:]]+).*/\1/p')"
[[ -n "$listen_addr" ]] || listen_addr=127.0.0.1:12345
listen_host="${listen_addr%:*}"
case "$listen_host" in
  ""|0.0.0.0) listen_host=127.0.0.1 ;;
  "[::]") listen_host="[::1]" ;;
esac
READY_URL="http://$listen_host:${listen_addr##*:}/-/ready"

WAS_HELD=0
if apt-mark showhold alloy 2>/dev/null | grep -qx alloy; then WAS_HELD=1; fi
WAS_ACTIVE=0
if systemctl is-active --quiet alloy; then WAS_ACTIVE=1; fi
WAS_ENABLED=0
if systemctl is-enabled --quiet alloy; then WAS_ENABLED=1; fi

# FROM is what is installed now and what a failure goes back to; TO is where
# this run moves. FINAL_HOLD is the hold state a successful run leaves.
FROM_VERSION="$CURRENT_VERSION"
FROM_DEB="$CURRENT_DEB"
if [[ "$MODE" == "to" ]]; then
  TO_VERSION="$TARGET_VERSION"
  if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" ]]; then
    say "Already at Alloy $CURRENT_VERSION (package $CURRENT_DEB); nothing to do"
    exit 0
  fi
  madison="$(apt-cache madison alloy 2>/dev/null)" || madison=""
  candidates="$(awk -F'|' 'NF >= 2 { gsub(/[[:space:]]/, "", $2); if ($2 != "") print $2 }' <<<"$madison" | LC_ALL=C sort -u)"
  target_candidates="$(awk -v prefix="$TARGET_VERSION-" 'index($0, prefix) == 1' <<<"$candidates")"
  case "$(grep -c . <<<"$target_candidates" || true)" in
    0) refuse "apt offers no alloy $TARGET_VERSION-* package (apt-cache madison alloy); run 'sudo apt-get update' and check the Grafana apt source" ;;
    1) TO_DEB="$target_candidates" ;;
    *) refuse "apt offers more than one alloy $TARGET_VERSION-* package: $(tr '\n' ' ' <<<"$target_candidates")" ;;
  esac
  grep -qxF -- "$FROM_DEB" <<<"$candidates" || \
    refuse "apt no longer offers the installed alloy $FROM_DEB, so a failed upgrade could not be rolled back"
  FINAL_HOLD=1
else
  [[ -d "$ROLLBACK_RECORD" && -f "$ROLLBACK_RECORD/upgrade.meta" ]] || \
    refuse "$ROLLBACK_RECORD is not an upgrade record"
  record_value() {
    sed -n "s/^$1=//p" "$ROLLBACK_RECORD/upgrade.meta" | tail -n 1
  }
  [[ "$(record_value status)" == "committed" ]] || \
    refuse "$ROLLBACK_RECORD did not commit an upgrade (status=$(record_value status))"
  if [[ "$CURRENT_DEB" == "$(record_value from_deb)" ]]; then
    say "Already at Alloy $CURRENT_VERSION (package $CURRENT_DEB), the version $ROLLBACK_RECORD replaced; nothing to do"
    exit 0
  fi
  [[ "$CURRENT_DEB" == "$(record_value to_deb)" ]] || \
    refuse "the installed alloy $CURRENT_DEB is not the $(record_value to_deb) that $ROLLBACK_RECORD installed"
  TO_VERSION="$(record_value from_version)"
  TO_DEB="$(record_value from_deb)"
  FINAL_HOLD="$(record_value was_held)"
fi

# ─────────────────────────────── Preflight ──────────────────────────────────

WORK=""
WORK_IS_RECORD=0
RECORD=""
MUTATED=0
PACKAGE_TOUCHED=0
CONFIG_RESTORED=0
COMMITTED=0
ROLLING_BACK=0
FAIL_REASON=""

# A failure after MUTATED=1 rolls back. Otherwise only a scratch WORK, never a
# record, is removed, so a refusal leaves nothing behind.
on_exit() {
  local status=$?
  trap - EXIT
  if [[ "$MUTATED" -eq 1 && "$COMMITTED" -eq 0 && "$ROLLING_BACK" -eq 0 ]]; then
    [[ -n "$FAIL_REASON" ]] || FAIL_REASON="interrupted (exit $status)"
    if rollback; then
      [[ "$WORK_IS_RECORD" -eq 1 || -z "$WORK" ]] || rm -rf "$WORK"
      exit 1
    fi
    exit 3
  fi
  [[ "$WORK_IS_RECORD" -eq 1 || -z "$WORK" ]] || rm -rf "$WORK"
  exit "$status"
}
trap on_exit EXIT
trap 'FAIL_REASON="interrupted by a signal"; exit 1' INT TERM HUP

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-alloy-upgrade.XXXXXX")"

deb_file() {
  local matches=("$WORK/debs/alloy_${1//:/%3a}_"*.deb)
  [[ "${#matches[@]}" -eq 1 && -f "${matches[0]}" ]] || return 1
  printf '%s\n' "${matches[0]}"
}

check_deb() {
  local file="$1" deb="$2"
  [[ "$(dpkg-deb -f "$file" Package)" == "alloy" && "$(dpkg-deb -f "$file" Version)" == "$deb" ]]
}

mkdir -p "$WORK/debs" "$WORK/extract"
if [[ "$MODE" == "to" ]]; then
  say "Downloading alloy $TO_DEB and, for a rollback, alloy $FROM_DEB"
  (cd "$WORK/debs" && apt-get -q download "alloy=$TO_DEB" "alloy=$FROM_DEB") || \
    refuse "apt-get download failed"
else
  cp -p "$ROLLBACK_RECORD"/debs/*.deb "$WORK/debs/" 2>/dev/null || \
    refuse "$ROLLBACK_RECORD/debs holds no packages"
fi
if ! TO_FILE="$(deb_file "$TO_DEB")" || ! check_deb "$TO_FILE" "$TO_DEB"; then
  refuse "the downloaded package is not alloy $TO_DEB"
fi
if ! FROM_FILE="$(deb_file "$FROM_DEB")" || ! check_deb "$FROM_FILE" "$FROM_DEB"; then
  refuse "the downloaded package is not alloy $FROM_DEB"
fi
dpkg-deb -x "$TO_FILE" "$WORK/extract" || refuse "dpkg-deb could not unpack alloy $TO_DEB"
NEW_BINARY="$WORK/extract/usr/bin/alloy"
if [[ ! -x "$NEW_BINARY" || "$(binary_version "$NEW_BINARY")" != "$TO_VERSION" ]]; then
  refuse "the alloy $TO_DEB package does not contain an alloy $TO_VERSION binary"
fi
if ! validate_output="$("$NEW_BINARY" validate "$CONFIG_PATH" 2>&1)"; then
  printf '%s\n' "$validate_output" >&2
  refuse "Alloy $TO_VERSION rejects the live configuration $CONFIG_PATH"
fi
rm -rf "$WORK/extract"
config_hashes >"$WORK/config.sha256"

restart_note=no
if [[ "$WAS_ACTIVE" -eq 1 ]]; then restart_note="yes, interrupts every Alloy pipeline once"; fi
summary="alloy $FROM_DEB -> $TO_DEB; Alloy active=$WAS_ACTIVE enabled=$WAS_ENABLED held=$WAS_HELD; restart: $restart_note; ready check: $READY_URL"
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  say "Check passed, nothing was changed: $summary"
  exit 0
fi

# ─────────────────────────────── Change ─────────────────────────────────────

# This run's own record, for --rollback too: a --rollback keeps RECORD_DIR as it
# is, so its packages and metadata stay what that upgrade left.
install -d -m 700 "$RECORD_ROOT"
RECORD="$RECORD_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mv "$WORK" "$RECORD"
WORK="$RECORD"
WORK_IS_RECORD=1
chmod 700 "$WORK"
TO_FILE="$WORK/debs/${TO_FILE##*/}"
FROM_FILE="$WORK/debs/${FROM_FILE##*/}"
META="$WORK/upgrade.meta"
{
  printf 'status=started\nmode=%s\n' "$MODE"
  [[ "$MODE" != "rollback" ]] || printf 'rollback_of=%s\n' "$ROLLBACK_RECORD"
  printf 'from_version=%s\nfrom_deb=%s\nto_version=%s\nto_deb=%s\n' \
    "$FROM_VERSION" "$FROM_DEB" "$TO_VERSION" "$TO_DEB"
  printf 'was_held=%s\nwas_active=%s\nwas_enabled=%s\nmain_pid=%s\n' \
    "$WAS_HELD" "$WAS_ACTIVE" "$WAS_ENABLED" "$(main_pid)"
  printf 'config_file=%s\nready_url=%s\nstarted_at_utc=%s\n' \
    "$CONFIG_PATH" "$READY_URL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$META"
CONFFILES="$WORK/conffiles"
install -d -m 700 "$CONFFILES"
cp -a "$ALLOY_DEFAULTS" "$CONFFILES/default-alloy"
cp -a "$ALLOY_ETC" "$CONFFILES/etc-alloy"

alloy_stays_up() {
  local first="" current _
  for _ in 1 2 3 4 5; do
    sleep 1
    systemctl is-active --quiet alloy || return 1
    current="$(main_pid)"
    [[ -n "$current" && "$current" != "0" ]] || return 1
    [[ -n "$first" ]] || first="$current"
    [[ "$current" == "$first" ]] || return 1
  done
}

alloy_ready() {
  local attempt
  for ((attempt = 0; attempt < READY_TIMEOUT; attempt++)); do
    if curl -fsS -o /dev/null --max-time 2 "$READY_URL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Brings the service back to how this run found it, on the package now
# installed, and checks that package. PID_BEFORE is MainPID before dpkg ran.
# FORCE_RESTART=1 restarts Alloy even when the package scripts already did: they
# ran before the config files were restored, so that process loaded other files.
service_as_found() {
  local version="$1" deb="$2" pid_before="$3" force_restart="${4:-0}" pid_now
  if [[ "$WAS_ACTIVE" -eq 1 ]]; then
    pid_now="$(main_pid)"
    if [[ "$force_restart" -eq 1 ]]; then
      say "Restarting Alloy so it runs on the restored config files; every Alloy pipeline pauses until it is ready"
      systemctl restart alloy || return 1
    elif systemctl is-active --quiet alloy && [[ "$pid_now" != "0" && "$pid_now" != "$pid_before" ]]; then
      say "The package scripts already restarted Alloy (MainPID $pid_before -> $pid_now); not restarting it again"
    else
      say "Restarting Alloy; every Alloy pipeline pauses until it is ready"
      systemctl restart alloy || return 1
    fi
    alloy_stays_up || return 1
    alloy_ready || return 1
  elif systemctl is-active --quiet alloy; then
    systemctl stop alloy || return 1
  fi
  [[ "$(installed_deb)" == "$deb" && "$(binary_version alloy)" == "$version" ]]
}

# Puts back the files copied before the change. CONFIG_RESTORED=1 records that
# the files on disk changed under a running Alloy, so it has to be restarted.
restore_config_files() {
  [[ "$(config_hashes)" != "$(cat "$WORK/config.sha256")" ]] || return 0
  CONFIG_RESTORED=1
  say "Restoring $ALLOY_DEFAULTS and $ALLOY_ETC; the files the failed run left are in $WORK/after-failure" >&2
  install -d -m 700 "$WORK/after-failure"
  mv "$ALLOY_DEFAULTS" "$WORK/after-failure/default-alloy" 2>/dev/null || true
  mv "$ALLOY_ETC" "$WORK/after-failure/etc-alloy" 2>/dev/null || true
  cp -a "$CONFFILES/default-alloy" "$ALLOY_DEFAULTS" &&
    cp -a "$CONFFILES/etc-alloy" "$ALLOY_ETC" &&
    [[ "$(config_hashes)" == "$(cat "$WORK/config.sha256")" ]]
}

rollback() {
  local problems=() pid_before
  ROLLING_BACK=1
  printf '%s: %s; rolling back to alloy %s\n' "$PROG" "$FAIL_REASON" "$FROM_DEB" >&2
  pid_before="$(main_pid)"
  if [[ "$PACKAGE_TOUCHED" -eq 1 ]] &&
     ! DEBIAN_FRONTEND=noninteractive dpkg --force-confold -i "$FROM_FILE"; then
    problems+=("dpkg could not reinstall alloy $FROM_DEB from $FROM_FILE")
  fi
  restore_config_files || problems+=("$ALLOY_DEFAULTS or $ALLOY_ETC differs from the copy in $CONFFILES")
  systemctl daemon-reload || problems+=("systemctl daemon-reload failed")
  if [[ "$WAS_HELD" -eq 1 ]]; then
    apt-mark hold alloy >/dev/null || problems+=("apt-mark hold alloy failed")
  else
    apt-mark unhold alloy >/dev/null || problems+=("apt-mark unhold alloy failed")
  fi
  service_as_found "$FROM_VERSION" "$FROM_DEB" "$pid_before" "$CONFIG_RESTORED" || \
    problems+=("Alloy is not back as found: expected alloy $FROM_DEB, active=$WAS_ACTIVE, ready at $READY_URL")
  if [[ "${#problems[@]}" -eq 0 ]]; then
    printf 'status=rolled_back\nreason=%s\n' "$FAIL_REASON" >>"$META"
    rm -rf "$CONFFILES"
    printf '%s: rolled back; alloy %s is installed and Alloy is as it was. Record: %s\n' \
      "$PROG" "$FROM_DEB" "$RECORD" >&2
    return 0
  fi
  printf 'status=rollback_incomplete\nreason=%s\n' "$FAIL_REASON" >>"$META"
  printf 'CRITICAL: rollback_incomplete: %s\n' "${problems[@]}" >&2
  printf 'CRITICAL: record: %s\n' "$RECORD" >&2
  printf 'CRITICAL: %s/upgrade.meta names the packages and the hold and service state this run found; the config files from before this run are in %s; the packages are in %s/debs.\n' \
    "$RECORD" "$CONFFILES" "$RECORD" >&2
  printf 'CRITICAL: check: dpkg-query -W alloy; alloy --version; systemctl status alloy; curl -fsS %s; journalctl -u alloy -n 50\n' \
    "$READY_URL" >&2
  return 1
}

failed() {
  FAIL_REASON="$1"
  exit 1
}

say "Moving $summary"
MUTATED=1
if [[ "$WAS_HELD" -eq 1 ]]; then
  apt-mark unhold alloy >/dev/null || failed "apt-mark unhold alloy failed"
fi
pid_before="$(main_pid)"
PACKAGE_TOUCHED=1
DEBIAN_FRONTEND=noninteractive dpkg --force-confold -i "$TO_FILE" || failed "dpkg could not install alloy $TO_DEB"
systemctl daemon-reload || failed "systemctl daemon-reload failed"
[[ "$(config_hashes)" == "$(cat "$WORK/config.sha256")" ]] || \
  failed "the package changed $ALLOY_DEFAULTS or a file in $ALLOY_ETC"
service_as_found "$TO_VERSION" "$TO_DEB" "$pid_before" || \
  failed "Alloy $TO_VERSION did not come back as found (active=$WAS_ACTIVE, one main process for 5 s, ready at $READY_URL within ${READY_TIMEOUT} s)"
if [[ "$FINAL_HOLD" -eq 1 ]]; then
  apt-mark hold alloy >/dev/null || failed "apt-mark hold alloy failed"
else
  apt-mark unhold alloy >/dev/null || failed "apt-mark unhold alloy failed"
fi
COMMITTED=1
rm -rf "$CONFFILES"
printf 'status=committed\nfinished_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$META"
if [[ "$MODE" == "to" ]]; then
  say "Done: alloy $TO_DEB is installed and held; Alloy is as it was (active=$WAS_ACTIVE)."
  say "Record: $RECORD"
  say "Roll back with: sudo $SCRIPT_DIR/upgrade-linux.sh --rollback $RECORD"
else
  say "Done: alloy $TO_DEB is installed again (held=$FINAL_HOLD); Alloy is as it was (active=$WAS_ACTIVE)."
  say "Record: $RECORD"
fi
