#!/usr/bin/env bash
#
# Behaviour tests for agents/alloy/upgrade-linux.sh. Each case runs a copy of
# the script in its own sandbox; only its path constants are rewritten, so the
# real script carries no test hooks. PATH holds nothing but the sandbox bin
# directory, whose dpkg, apt, systemctl and curl are shims, so no real package
# or unit is reachable. Versions come from alloy-versions.env.
#
# VERBOSE=1 also prints every check that passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_DIR="$REPO_ROOT/agents/alloy"
UPGRADE="$AGENT_DIR/upgrade-linux.sh"
VERBOSE="${VERBOSE:-0}"

for tool in perl shasum; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'FAIL: %s is required; this suite must not pass by skipping\n' "$tool" >&2
    exit 1
  }
done
[[ -x "$UPGRADE" ]] || {
  printf 'FAIL: %s is missing or not executable\n' "$UPGRADE" >&2
  exit 1
}

# The upgrade under test moves from an unlisted installed version to the first
# listed one. The second listed version stands in for "something else".
# shellcheck source=agents/alloy/alloy-versions.env
LISTED="$(. "$AGENT_DIR/alloy-versions.env" && printf '%s' "$SKYEYE_ALLOY_LINUX_VERSIONS")"
read -r TARGET OTHER _ <<<"$LISTED"
[[ -n "$TARGET" && -n "$OTHER" ]] || {
  printf 'FAIL: alloy-versions.env must list two linux versions\n' >&2
  exit 1
}
FROM=1.16.0
[[ " $LISTED " != *" $FROM "* ]] || {
  printf 'FAIL: the fixture needs %s to be unlisted\n' "$FROM" >&2
  exit 1
}
TARGET_DEB="$TARGET-1"
FROM_DEB="$FROM-1"
OTHER_DEB="$OTHER-1"
UNLISTED=1.17.1

REAL_BASH="$BASH"
REAL_SHASUM="$(command -v shasum)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-upgrade-linux.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

CASE=""
BOX=""
RC=0
CHECKS=0
FAILURES=0

check() {
  local description="$1"
  shift
  CHECKS=$((CHECKS + 1))
  if "$@"; then
    if [[ "$VERBOSE" == "1" ]]; then
      printf 'ok: %s: %s\n' "$CASE" "$description"
    fi
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL: %s: %s\n' "$CASE" "$description"
    sed 's/^/  | /' "$BOX/log/out" 2>/dev/null | tail -n 20
  fi
}

# ─────────────────────────────── Shims ──────────────────────────────────────

# The shim bodies expand at run time, inside the sandbox.
# shellcheck disable=SC2016
shim() {
  {
    printf '#!/bin/bash\nctl="$BOX/ctl"; calls="$BOX/log/calls.log"\n'
    printf 'installed_deb() { cat "$ctl/deb" 2>/dev/null; }\n'
    printf 'bump_pid() { echo $(($(cat "$ctl/pid") + 1)) >"$ctl/pid"; }\n'
    cat
  } >"$BOX/bin/$1"
  chmod 755 "$BOX/bin/$1"
}

write_shims() {
  shim id <<'EOF'
[ "$1" = -u ] && cat "$ctl/uid"
EOF

  shim sleep <<'EOF'
exit 0
EOF

  shim sha256sum <<'EOF'
exec "$REAL_SHASUM" -a 256 "$@"
EOF

  shim dpkg-query <<'EOF'
[ -e "$ctl/deb" ] || exit 1
printf '%s\t%s\n' "$(cat "$ctl/status")" "$(installed_deb)"
EOF

  shim alloy <<'EOF'
if [ "$1" = --version ]; then
  version="$(cat "$ctl/binary-version" 2>/dev/null || installed_deb | sed 's/-[^-]*$//')"
  printf 'alloy, version v%s (branch: HEAD, revision: shim)\n' "$version"
  exit 0
fi
exit 1
EOF

  shim apt-cache <<'EOF'
[ "$1 $2" = "madison alloy" ] || exit 1
while read -r version; do
  [ -n "$version" ] && printf ' alloy | %s | https://apt.grafana.com stable/main amd64 Packages\n' "$version"
done <"$ctl/madison"
EOF

  shim apt-get <<'EOF'
printf 'apt-get %s\n' "$*" >>"$calls"
[ "$1" = -q ] && shift
[ "$1" = download ] || exit 100
shift
for spec in "$@"; do
  version="${spec#alloy=}"
  grep -qxF "$version" "$ctl/madison" || exit 100
  printf 'Package: alloy\nVersion: %s\n' "$version" >"alloy_${version}_amd64.deb"
done
EOF

  shim apt-mark <<'EOF'
printf 'apt-mark %s\n' "$*" >>"$calls"
case "$1" in
  showhold) [ ! -e "$ctl/held" ] || echo alloy ;;
  hold) [ ! -e "$ctl/hold-fails" ] && touch "$ctl/held" ;;
  unhold) rm -f "$ctl/held" ;;
  *) exit 1 ;;
esac
EOF

  shim dpkg-deb <<'EOF'
case "$1" in
  -f)
    sed -n "s/^$3: //p" "$2"
    ;;
  -x)
    version="$(sed -n 's/^Version: //p' "$2")"
    mkdir -p "$3/usr/bin"
    cat >"$3/usr/bin/alloy" <<SCRIPT
#!/bin/bash
if [ "\$1" = --version ]; then
  echo 'alloy, version v${version%-*} (branch: HEAD, revision: shim)'
  exit 0
fi
printf 'extracted-validate %s %s\n' '$version' "\$2" >>"$calls"
if [ -e "$ctl/validate-fails-$version" ]; then
  echo 'Error: fake validation failure' >&2
  exit 1
fi
SCRIPT
    chmod 755 "$3/usr/bin/alloy"
    ;;
  *) exit 2 ;;
esac
EOF

  shim dpkg <<'EOF'
[ "$1 $2" = "--force-confold -i" ] || exit 2
[ "$DEBIAN_FRONTEND" = noninteractive ] || exit 2
version="$(sed -n 's/^Version: //p' "$3")"
printf 'dpkg -i %s\n' "$version" >>"$calls"
if [ -e "$ctl/dpkg-fails-$version" ]; then
  echo 'install ok half-configured' >"$ctl/status"
  exit 1
fi
echo "$version" >"$ctl/deb"
echo 'install ok installed' >"$ctl/status"
[ ! -e "$ctl/dpkg-changes-conffile-$version" ] || printf '# changed by the package\n' >>"$BOX/etc/default/alloy"
if [ -e "$ctl/postinst-restarts" ] && [ -e "$ctl/active" ]; then
  bump_pid
fi
EOF

  shim systemctl <<'EOF'
case "$1" in
  is-active) [ -e "$ctl/active" ] ;;
  is-enabled) [ -e "$ctl/enabled" ] ;;
  show)
    if [ ! -e "$ctl/active" ]; then echo 0; exit 0; fi
    [ ! -e "$ctl/crash-loop-$(installed_deb)" ] || bump_pid
    cat "$ctl/pid"
    ;;
  restart)
    printf 'systemctl restart %s on %s\n' "$2" "$(installed_deb)" >>"$calls"
    if [ -e "$ctl/restart-fails-$(installed_deb)" ]; then
      rm -f "$ctl/active"
      exit 1
    fi
    touch "$ctl/active"
    bump_pid
    ;;
  stop)
    printf 'systemctl stop %s\n' "$2" >>"$calls"
    rm -f "$ctl/active"
    ;;
  daemon-reload)
    printf 'systemctl daemon-reload\n' >>"$calls"
    ;;
  *) exit 1 ;;
esac
EOF

  shim curl <<'EOF'
for url; do :; done
printf 'curl %s on %s\n' "$url" "$(installed_deb)" >>"$calls"
[ -e "$ctl/active" ] && [ ! -e "$ctl/not-ready-$(installed_deb)" ]
EOF
}

new_box() {
  local tool
  CASE="$1"
  BOX="$WORK/$CASE"
  mkdir -p "$BOX/bin" "$BOX/agents" "$BOX/log" "$BOX/ctl" "$BOX/run" "$BOX/tmp" \
    "$BOX/etc/alloy" "$BOX/etc/default" "$BOX/var/lib"
  for tool in awk cat chmod cp cut date dirname find grep head install mkdir mktemp mv perl rm sed sort stat tail touch tr; do
    ln -s "$(command -v "$tool")" "$BOX/bin/$tool"
  done
  write_shims
  : >"$BOX/log/calls.log"
  echo 0 >"$BOX/ctl/uid"
  echo "$FROM_DEB" >"$BOX/ctl/deb"
  echo 'install ok installed' >"$BOX/ctl/status"
  printf '%s\n' "$FROM_DEB" "$TARGET_DEB" "$OTHER_DEB" >"$BOX/ctl/madison"
  echo 4242 >"$BOX/ctl/pid"
  touch "$BOX/ctl/active" "$BOX/ctl/enabled" "$BOX/ctl/held"

  printf 'CONFIG_FILE="%s/etc/alloy"\nCUSTOM_ARGS="--server.http.listen-addr=0.0.0.0:12399 --disable-reporting"\nRESTART_ON_UPGRADE=true\n' \
    "$BOX" >"$BOX/etc/default/alloy"
  printf 'loki.write "central" {}\n' >"$BOX/etc/alloy/config.alloy"
  printf '// trading fragment\n' >"$BOX/etc/alloy/trading-metrics.alloy"
  chmod 640 "$BOX/etc/alloy/config.alloy"

  cp "$AGENT_DIR/install-common.sh" "$AGENT_DIR/alloy-versions.env" "$BOX/agents/"
  sed -e "s#^LOCK_FILE=/run/skyeye-alloy.lock\$#LOCK_FILE=$BOX/run/skyeye-alloy.lock#" \
    -e "s#^ALLOY_DEFAULTS=/etc/default/alloy\$#ALLOY_DEFAULTS=$BOX/etc/default/alloy#" \
    -e "s#^ALLOY_ETC=/etc/alloy\$#ALLOY_ETC=$BOX/etc/alloy#" \
    -e "s#^RECORD_ROOT=/var/lib/skyeye-alloy/upgrade\$#RECORD_ROOT=$BOX/var/lib/skyeye-alloy/upgrade#" \
    "$UPGRADE" >"$BOX/agents/upgrade-linux.sh"
  for constant in LOCK_FILE ALLOY_DEFAULTS ALLOY_ETC RECORD_ROOT; do
    grep -q "^$constant=$BOX/" "$BOX/agents/upgrade-linux.sh" || {
      printf 'FAIL: %s: could not point %s at the sandbox\n' "$CASE" "$constant" >&2
      exit 1
    }
  done
  etc_snapshot >"$BOX/etc.snapshot"
}

run_upgrade() {
  (
    cd "$BOX" || exit 99
    exec env -i PATH="$BOX/bin" TMPDIR="$BOX/tmp" BOX="$BOX" REAL_SHASUM="$REAL_SHASUM" \
      "$REAL_BASH" "$BOX/agents/upgrade-linux.sh" "$@"
  ) </dev/null >"$BOX/log/out" 2>&1
  RC=$?
}

etc_snapshot() {
  find "$BOX/etc" -type f | LC_ALL=C sort | while IFS= read -r path; do
    printf '%s %s %s\n' "$path" "$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path")" \
      "$("$REAL_SHASUM" -a 256 <"$path" | cut -c1-64)"
  done
}

# ─────────────────────────────── Assertions ─────────────────────────────────

rc_is() { [[ "$RC" -eq "$1" ]]; }
said() { grep -qF -- "$1" "$BOX/log/out"; }
called() { grep -qE -- "$1" "$BOX/log/calls.log"; }
not_called() { ! called "$1"; }
count_is() {
  local count
  count="$(grep -cE -- "$1" "$BOX/log/calls.log")"
  [[ "${count:-0}" -eq "$2" ]]
}
deb_is() { [[ "$(cat "$BOX/ctl/deb")" == "$1" ]]; }
held() { [[ -e "$BOX/ctl/held" ]]; }
not_held() { [[ ! -e "$BOX/ctl/held" ]]; }
active() { [[ -e "$BOX/ctl/active" ]]; }
inactive() { [[ ! -e "$BOX/ctl/active" ]]; }
etc_unchanged() { etc_snapshot | cmp -s - "$BOX/etc.snapshot"; }
no_records() { [[ ! -e "$BOX/var/lib/skyeye-alloy" ]]; }
no_scratch() { [[ -z "$(find "$BOX/tmp" -mindepth 1 -maxdepth 1 -print)" ]]; }
no_package_change() { not_called '^(dpkg -i|apt-mark (hold|unhold)|systemctl (restart|stop|daemon-reload))'; }
only_record() {
  local records=("$BOX"/var/lib/skyeye-alloy/upgrade/*)
  [[ "${#records[@]}" -eq 1 && -d "${records[0]}" ]] && RECORD="${records[0]}"
}
record_mode_700() { [[ "$(stat -f '%Lp' "$RECORD" 2>/dev/null || stat -c '%a' "$RECORD")" == "700" ]]; }
meta_status_is() { [[ "$(sed -n 's/^status=//p' "$RECORD/$1" | tail -n 1)" == "$2" ]]; }
record_has_both_debs() {
  [[ -f "$RECORD/debs/alloy_${TARGET_DEB}_amd64.deb" && -f "$RECORD/debs/alloy_${FROM_DEB}_amd64.deb" ]]
}
no_conffile_copy() { [[ ! -e "$RECORD/conffiles" ]]; }

assert_refused() {
  check 'exit code 1' rc_is 1
  check 'says it was refused' said 'refused, nothing was changed'
  check 'no package, hold or service change' no_package_change
  check 'config files unchanged' etc_unchanged
  check 'no record written' no_records
  check 'no scratch directory left' no_scratch
}

# ─────────────────────────────── Usage and gates ────────────────────────────

new_box usage
for arguments in "" "--to" "--to 1.16" "--to $TARGET --rollback /x" "--rollback relative/dir" \
  "--rollback /x --check" "--check" "--to $TARGET --bogus"; do
  # Word splitting is the point: each string is one argument list.
  # shellcheck disable=SC2086
  run_upgrade $arguments
  check "usage error for '$arguments'" rc_is 2
done
check 'nothing was called' no_package_change

new_box unlisted-target-refused
run_upgrade --to "$UNLISTED"
assert_refused
check 'names the tested versions' said "Alloy $UNLISTED is not tested on linux (tested: $LISTED)"
check 'never downloaded' not_called '^apt-get'

new_box not-root
echo 1000 >"$BOX/ctl/uid"
run_upgrade --to "$TARGET"
assert_refused
check 'says to use root' said 'run it as root'

new_box lock-held
exec 8>>"$BOX/run/skyeye-alloy.lock"
perl -MFcntl=:flock -e 'open(my $fh, ">>&=", 8) or exit 2; exit(flock($fh, LOCK_EX | LOCK_NB) ? 0 : 1)' || {
  printf 'FAIL: %s: the test could not take the lock\n' "$CASE" >&2
  exit 1
}
run_upgrade --to "$TARGET"
exec 8>&-
assert_refused
check 'names the lock file' said "holds $BOX/run/skyeye-alloy.lock"

new_box already-at-target
echo "$TARGET_DEB" >"$BOX/ctl/deb"
run_upgrade --to "$TARGET"
check 'exit code 0' rc_is 0
check 'reports the no-op' said "Already at Alloy $TARGET"
check 'never downloaded' not_called '^apt-get'
check 'no package, hold or service change' no_package_change
check 'no record written' no_records

new_box package-not-installed
rm -f "$BOX/ctl/deb"
run_upgrade --to "$TARGET"
assert_refused
check 'says the package is missing' said 'the alloy apt package is not installed'

new_box package-half-installed
echo 'install ok half-configured' >"$BOX/ctl/status"
run_upgrade --to "$TARGET"
assert_refused

new_box binary-disagrees-with-package
echo 1.16.2 >"$BOX/ctl/binary-version"
run_upgrade --to "$TARGET"
assert_refused
check 'names both versions' said "the alloy package is $FROM_DEB but the alloy binary reports 1.16.2"

new_box no-candidate
printf '%s\n' "$FROM_DEB" "$OTHER_DEB" >"$BOX/ctl/madison"
run_upgrade --to "$TARGET"
assert_refused
check 'says apt has no package' said "apt offers no alloy $TARGET-* package"

new_box ambiguous-candidate
printf '%s\n' "$FROM_DEB" "$TARGET_DEB" "$TARGET-2" >"$BOX/ctl/madison"
run_upgrade --to "$TARGET"
assert_refused
check 'says the candidate is ambiguous' said "more than one alloy $TARGET-* package"

new_box previous-not-offered
printf '%s\n' "$TARGET_DEB" "$OTHER_DEB" >"$BOX/ctl/madison"
run_upgrade --to "$TARGET"
assert_refused
check 'says a rollback would be impossible' said "apt no longer offers the installed alloy $FROM_DEB"

new_box new-version-rejects-the-config
touch "$BOX/ctl/validate-fails-$TARGET_DEB"
run_upgrade --to "$TARGET"
assert_refused
check 'validated the live config with the new binary' called "^extracted-validate $TARGET_DEB $BOX/etc/alloy\$"
check 'shows the validation error' said 'fake validation failure'

# ─────────────────────────────── Check only ─────────────────────────────────

new_box check-only
run_upgrade --to "$TARGET" --check
check 'exit code 0' rc_is 0
check 'says the check passed' said 'Check passed, nothing was changed'
check 'names the restart' said 'restart: yes, interrupts every Alloy pipeline once'
check 'names the ready URL from CUSTOM_ARGS' said 'ready check: http://127.0.0.1:12399/-/ready'
check 'downloaded both packages' called "^apt-get -q download alloy=$TARGET_DEB alloy=$FROM_DEB\$"
check 'validated with the new binary' called "^extracted-validate $TARGET_DEB "
check 'no package, hold or service change' no_package_change
check 'config files unchanged' etc_unchanged
check 'no record written' no_records
check 'no scratch directory left' no_scratch
check 'still the old package' deb_is "$FROM_DEB"

# ─────────────────────────────── Upgrade ────────────────────────────────────

new_box upgrade
run_upgrade --to "$TARGET"
check 'exit code 0' rc_is 0
check 'new package installed' deb_is "$TARGET_DEB"
check 'installed with --force-confold' called "^dpkg -i $TARGET_DEB\$"
check 'unheld before and held after' called '^apt-mark unhold alloy$'
check 'held' held
check 'one restart, on the new package' count_is "^systemctl restart alloy on $TARGET_DEB\$" 1
check 'daemon-reload' called '^systemctl daemon-reload$'
check 'ready checked on the new package' called "^curl http://127.0.0.1:12399/-/ready on $TARGET_DEB\$"
check 'Alloy active' active
check 'config files unchanged' etc_unchanged
check 'one record' only_record
check 'record mode 700' record_mode_700
check 'record committed' meta_status_is upgrade.meta committed
check 'record keeps both packages' record_has_both_debs
check 'config copies deleted' no_conffile_copy
check 'prints the rollback command' said "--rollback $RECORD"
check 'no scratch directory left' no_scratch
UPGRADE_BOX="$BOX"
UPGRADE_RECORD="$RECORD"

new_box upgrade-after-package-restart
touch "$BOX/ctl/postinst-restarts"
run_upgrade --to "$TARGET"
check 'exit code 0' rc_is 0
check 'no second restart' count_is '^systemctl restart' 0
check 'says why' said 'The package scripts already restarted Alloy'
check 'ready checked' called "^curl .* on $TARGET_DEB\$"

new_box upgrade-of-an-unheld-package
rm -f "$BOX/ctl/held"
run_upgrade --to "$TARGET"
check 'exit code 0' rc_is 0
check 'held afterwards' held
check 'never unheld' not_called '^apt-mark unhold'

new_box upgrade-while-stopped
rm -f "$BOX/ctl/active"
run_upgrade --to "$TARGET"
check 'exit code 0' rc_is 0
check 'new package installed' deb_is "$TARGET_DEB"
check 'not started' inactive
check 'no restart' count_is '^systemctl restart' 0
check 'no ready check' not_called '^curl'

# ─────────────────────────────── Automatic rollback ─────────────────────────

assert_rolled_back() {
  check 'exit code 1' rc_is 1
  check 'says it rolled back' said 'rolled back; alloy'
  check 'old package back' deb_is "$FROM_DEB"
  check 'reinstalled the old package' called "^dpkg -i $FROM_DEB\$"
  check 'hold restored' held
  check 'Alloy active' active
  check 'ready on the old package' called "^curl .* on $FROM_DEB\$"
  check 'config files as before' etc_unchanged
  check 'one record' only_record
  check 'record says rolled back' meta_status_is upgrade.meta rolled_back
  check 'config copies deleted' no_conffile_copy
}

new_box restart-fails-rolls-back
touch "$BOX/ctl/restart-fails-$TARGET_DEB"
run_upgrade --to "$TARGET"
assert_rolled_back

new_box not-ready-rolls-back
touch "$BOX/ctl/not-ready-$TARGET_DEB"
run_upgrade --to "$TARGET"
assert_rolled_back
check 'waited the full minute' count_is "^curl .* on $TARGET_DEB\$" 60

new_box crash-loop-rolls-back
touch "$BOX/ctl/crash-loop-$TARGET_DEB"
run_upgrade --to "$TARGET"
assert_rolled_back

new_box conffile-change-rolls-back
touch "$BOX/ctl/dpkg-changes-conffile-$TARGET_DEB"
run_upgrade --to "$TARGET"
assert_rolled_back
check 'never restarted the new package' count_is "^systemctl restart alloy on $TARGET_DEB\$" 0
check 'keeps the changed file aside' grep -q 'changed by the package' "$RECORD/after-failure/default-alloy"

new_box dpkg-fails-rolls-back
touch "$BOX/ctl/dpkg-fails-$TARGET_DEB"
run_upgrade --to "$TARGET"
assert_rolled_back

new_box rollback-that-fails-exits-3
touch "$BOX/ctl/restart-fails-$TARGET_DEB" "$BOX/ctl/restart-fails-$FROM_DEB"
run_upgrade --to "$TARGET"
check 'exit code 3' rc_is 3
check 'says CRITICAL' said 'CRITICAL: rollback_incomplete'
check 'reinstalled the old package' deb_is "$FROM_DEB"
# shellcheck disable=SC2016
check 'record says incomplete' bash -c '[[ "$(sed -n "s/^status=//p" "$1"/*/upgrade.meta | tail -n 1)" == rollback_incomplete ]]' _ "$BOX/var/lib/skyeye-alloy/upgrade"
check 'keeps the config copies' test -f "$(echo "$BOX"/var/lib/skyeye-alloy/upgrade/*)/conffiles/default-alloy"

new_box rollback-dpkg-fails-exits-3
touch "$BOX/ctl/dpkg-fails-$TARGET_DEB" "$BOX/ctl/dpkg-fails-$FROM_DEB"
run_upgrade --to "$TARGET"
check 'exit code 3' rc_is 3
check 'names the dpkg failure' said "dpkg could not reinstall alloy $FROM_DEB"

# ─────────────────────────────── --rollback ─────────────────────────────────

new_box rollback-command
cp -a "$UPGRADE_BOX/." "$BOX/"
# The copy keeps the upgraded state, but its paths still name the first box.
sed -i.bak "s#$UPGRADE_BOX#$BOX#g" "$BOX/etc/default/alloy" "$BOX/agents/upgrade-linux.sh" && rm -f "$BOX"/etc/default/alloy.bak "$BOX"/agents/upgrade-linux.sh.bak
RECORD="$BOX/${UPGRADE_RECORD#"$UPGRADE_BOX"/}"
etc_snapshot >"$BOX/etc.snapshot"
: >"$BOX/log/calls.log"
run_upgrade --rollback "$RECORD"
check 'exit code 0' rc_is 0
check 'old package back' deb_is "$FROM_DEB"
check 'from the recorded package, without apt' not_called '^apt-get'
check 'validated with the old binary' called "^extracted-validate $FROM_DEB "
check 'one restart, on the old package' count_is "^systemctl restart alloy on $FROM_DEB\$" 1
check 'hold as before the upgrade' held
check 'config files unchanged' etc_unchanged
check 'rollback recorded' meta_status_is rollback.meta committed
check 'upgrade record kept' meta_status_is upgrade.meta committed
check 'no scratch directory left' no_scratch
: >"$BOX/log/calls.log"
run_upgrade --rollback "$RECORD"
check 'a second rollback is a no-op' rc_is 0
check 'reports the no-op' said 'nothing to do'
check 'nothing changed the second time' no_package_change

new_box rollback-refuses-another-version
cp -a "$UPGRADE_BOX/." "$BOX/"
sed -i.bak "s#$UPGRADE_BOX#$BOX#g" "$BOX/etc/default/alloy" "$BOX/agents/upgrade-linux.sh" && rm -f "$BOX"/etc/default/alloy.bak "$BOX"/agents/upgrade-linux.sh.bak
RECORD="$BOX/${UPGRADE_RECORD#"$UPGRADE_BOX"/}"
echo "$OTHER_DEB" >"$BOX/ctl/deb"
: >"$BOX/log/calls.log"
run_upgrade --rollback "$RECORD"
check 'exit code 1' rc_is 1
check 'names the mismatch' said "the installed alloy $OTHER_DEB is not the $TARGET_DEB"
check 'no package, hold or service change' no_package_change

new_box rollback-refuses-a-rolled-back-record
touch "$BOX/ctl/restart-fails-$TARGET_DEB"
run_upgrade --to "$TARGET"
only_record
: >"$BOX/log/calls.log"
run_upgrade --rollback "$RECORD"
check 'exit code 1' rc_is 1
check 'says the record did not commit' said 'did not commit an upgrade'
check 'no package, hold or service change' no_package_change

new_box rollback-command-fails-returns-to-target
cp -a "$UPGRADE_BOX/." "$BOX/"
sed -i.bak "s#$UPGRADE_BOX#$BOX#g" "$BOX/etc/default/alloy" "$BOX/agents/upgrade-linux.sh" && rm -f "$BOX"/etc/default/alloy.bak "$BOX"/agents/upgrade-linux.sh.bak
RECORD="$BOX/${UPGRADE_RECORD#"$UPGRADE_BOX"/}"
touch "$BOX/ctl/restart-fails-$FROM_DEB"
: >"$BOX/log/calls.log"
run_upgrade --rollback "$RECORD"
check 'exit code 1' rc_is 1
check 'back on the upgraded package' deb_is "$TARGET_DEB"
check 'held as found' held
check 'Alloy active' active
check 'no scratch directory left' no_scratch

# ─────────────────────────────── Summary ────────────────────────────────────

if [[ "$FAILURES" -gt 0 ]]; then
  printf 'FAIL: upgrade-linux.sh: %s of %s checks failed\n' "$FAILURES" "$CHECKS"
  exit 1
fi
printf 'PASS: upgrade-linux.sh: %s checks\n' "$CHECKS"
