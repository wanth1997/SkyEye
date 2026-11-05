#!/usr/bin/env bash
#
# Behaviour tests for agents/alloy/setup.sh: a failed run must leave the old
# config byte-for-byte intact, and a good run must render the same bytes as
# before.
#
# Each case runs a copy of the script in its own sandbox. Only the system paths
# in the copy are rewritten, so the real script carries no test hooks. PATH holds
# nothing but the sandbox bin directory, so no real systemd, apt or chown is
# reachable. `alloy validate` runs the real binary wherever a case needs it.
#
# To see the failures this suite catches, run it against an older script:
#   git show 0d4ae839:agents/alloy/setup.sh > /tmp/old-setup.sh
#   SETUP_UNDER_TEST=/tmp/old-setup.sh bash tests/alloy/test-setup-atomic.sh
#
# VERBOSE=1 also prints every check that passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_DIR="$REPO_ROOT/agents/alloy"
SETUP_UNDER_TEST="${SETUP_UNDER_TEST:-$AGENT_DIR/setup.sh}"
VERBOSE="${VERBOSE:-0}"

SECRET=fake-cf-secret-value
MATCHES='_SYSTEMD_UNIT=a.service _SYSTEMD_UNIT=b.service'
BEARER=fake-bearer-token

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'FAIL: %s is required; this suite must not pass by skipping\n' "$1" >&2
    exit 1
  }
}
for tool in alloy envsubst cmp; do
  require_tool "$tool"
done
[[ -f "$SETUP_UNDER_TEST" ]] || {
  printf 'FAIL: setup script not found: %s\n' "$SETUP_UNDER_TEST" >&2
  exit 1
}

REAL_ALLOY="$(command -v alloy)"
REAL_ENVSUBST="$(command -v envsubst)"
REAL_BASH="$BASH"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-setup-atomic.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

CASE=""
BOX=""
CONFIG=""
RC=0
CHECKS=0
FAILURES=0

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

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
  fi
}

# ─────────────────────────────── Shims ──────────────────────────────────────

# Reads the shim body from stdin. The copy in shims/ is what apt-get "installs".
shim() {
  {
    printf '#!/bin/bash\n. "$BOX/shims.lib"\n'
    cat
  } >"$BOX/shims/$1"
  chmod 755 "$BOX/shims/$1"
  cp "$BOX/shims/$1" "$BOX/bin/$1"
}

write_shims() {
  cat >"$BOX/shims.lib" <<'EOF'
log_dir="$BOX/log"
ctl="$BOX/ctl"
config="$BOX/etc/alloy/config.alloy"

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

# Which config a service restart would load right now.
config_state() {
  if [ ! -e "$config" ]; then
    echo none
  elif [ -e "$BOX/old-config" ] && cmp -s "$config" "$BOX/old-config"; then
    echo old
  else
    echo new
  fi
}

# Records the mode of every file holding the credential at this step.
scan_secret_modes() {
  local f
  for f in "$BOX/etc/alloy"/* "$BOX/etc/alloy"/.[!.]*; do
    [ -f "$f" ] || continue
    grep -q "$SECRET_MARKER" "$f" || continue
    printf '%s %s %s\n' "$1" "$(file_mode "$f")" "${f##*/}" >>"$log_dir/secret-modes.log"
  done
}
EOF

  shim id <<'EOF'
[ "$1" = -u ] && { cat "$ctl/uid" 2>/dev/null || echo 0; }
EOF

  shim chown <<'EOF'
scan_secret_modes chown
printf '%s\n' "$*" >>"$log_dir/chown.log"
[ ! -e "$ctl/chown-fails" ]
EOF

  shim sleep <<'EOF'
exit 0
EOF

  shim getent <<'EOF'
exit 0
EOF

  shim usermod <<'EOF'
exit 0
EOF

  shim systemd-tmpfiles <<'EOF'
exit 0
EOF

  shim journalctl <<'EOF'
echo 'fake journal line'
EOF

  shim wget <<'EOF'
exit 0
EOF

  shim gpg <<'EOF'
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then : >"$2"; fi
  shift
done
EOF

  shim apt-get <<'EOF'
printf '%s\n' "$*" >>"$log_dir/apt.log"
case "$*" in
  *'install -y alloy'*)
    cp "$BOX/shims/alloy" "$BOX/bin/alloy"
    if [ -e "$ctl/apt-ships-sample" ]; then
      mkdir -p "$BOX/etc/alloy"
      printf '// package sample config\n' >"$config"
      chmod 644 "$config"
      cp "$config" "$BOX/old-config"
    fi
    ;;
esac
EOF

  shim envsubst <<'EOF'
call=$(($(cat "$ctl/envsubst.calls" 2>/dev/null || echo 0) + 1))
echo "$call" >"$ctl/envsubst.calls"
if [ -e "$ctl/envsubst-fails-on-$call" ]; then
  printf '// partial render\n'
  exit 1
fi
[ ! -e "$ctl/envsubst-empty" ] || exit 0
"$REAL_ENVSUBST" "$@"
status=$?
scan_secret_modes envsubst
exit "$status"
EOF

  shim alloy <<'EOF'
case "$1" in
  --version)
    echo 'alloy, version v1.16.3 (shim)'
    ;;
  fmt)
    exit 0
    ;;
  validate)
    if [ -e "$ctl/no-validate" ]; then
      echo 'Error: unknown command "validate" for "alloy"' >&2
      exit 1
    fi
    [ "$2" != --help ] || exit 0
    scan_secret_modes validate
    [ ! -e "$ctl/term-on-validate" ] || kill -TERM "$PPID"
    printf '%s live=%s name=%s dir=%s\n' "$(file_mode "$2")" "$(config_state)" \
      "${2##*/}" "$(dirname "$2")" >>"$log_dir/validate.log"
    if [ -e "$ctl/validate-fails" ]; then
      echo 'Error: fake validation failure' >&2
      exit 1
    fi
    [ ! -e "$ctl/real-validate" ] || exec "$REAL_ALLOY" validate "$2"
    ;;
  *)
    exit 1
    ;;
esac
EOF

  shim systemctl <<'EOF'
action=$1
shift
case "$action" in
  is-active)
    if [ "$(config_state)" = new ] && [ -e "$ctl/unhealthy-on-new" ]; then
      exit 3
    fi
    if [ "$(config_state)" = old ] && [ -e "$ctl/unhealthy-on-old" ] && [ -e "$ctl/restarted" ]; then
      exit 3
    fi
    [ -e "$ctl/active" ]
    ;;
  show)
    if [ "$(config_state)" = new ] && [ -e "$ctl/crash-loop-on-new" ]; then
      pid=$(($(cat "$ctl/pid" 2>/dev/null || echo 1000) + 1))
      echo "$pid" >"$ctl/pid"
      echo "MainPID=$pid"
    else
      echo 'MainPID=4242'
    fi
    ;;
  restart)
    state=$(config_state)
    printf 'restart %s sees=%s\n' "$1" "$state" >>"$log_dir/systemctl.log"
    [ "$1" = alloy ] || exit 0
    touch "$ctl/restarted"
    if [ -e "$ctl/term-on-restart" ]; then
      rm -f "$ctl/term-on-restart"
      kill -TERM "$PPID"
    fi
    if [ -e "$ctl/restart-fails-on-$state" ]; then
      rm -f "$ctl/active"
      exit 1
    fi
    touch "$ctl/active"
    ;;
  stop)
    printf 'stop %s\n' "$1" >>"$log_dir/systemctl.log"
    rm -f "$ctl/active"
    ;;
  enable)
    printf 'enable %s\n' "$1" >>"$log_dir/systemctl.log"
    [ ! -e "$ctl/enable-fails" ]
    ;;
  *)
    printf '%s %s\n' "$action" "$*" >>"$log_dir/systemctl.log"
    ;;
esac
EOF
}

new_box() {
  local tool real
  CASE="$1"
  BOX="$WORK/$CASE"
  CONFIG="$BOX/etc/alloy/config.alloy"
  mkdir -p "$BOX/bin" "$BOX/shims" "$BOX/agents" "$BOX/log" "$BOX/ctl" \
    "$BOX/etc/alloy" "$BOX/etc/apt/sources.list.d" "$BOX/var/log/journal"

  for tool in cat chmod cmp cp dirname grep head ln mkdir mktemp mv rm stat touch; do
    real="$(command -v "$tool")"
    ln -s "$real" "$BOX/bin/$tool"
  done
  write_shims
  touch "$BOX/ctl/active"

  cp "$AGENT_DIR"/*.tmpl "$BOX/agents/"
  sed -e "s#^ALLOY_CONFIG=/etc/alloy/config.alloy\$#ALLOY_CONFIG=$CONFIG#" \
    -e "s#/var/log/journal#$BOX/var/log/journal#g" \
    -e "s#/etc/apt#$BOX/etc/apt#g" \
    "$SETUP_UNDER_TEST" >"$BOX/agents/setup.sh"

  grep -q "^ALLOY_CONFIG=$CONFIG\$" "$BOX/agents/setup.sh" || {
    printf 'FAIL: %s: could not point ALLOY_CONFIG at the sandbox\n' "$CASE" >&2
    exit 1
  }
  if grep -v "$BOX" "$BOX/agents/setup.sh" | grep -v '^[[:space:]]*#' |
    grep -qE '(^|[^[:alnum:]])/(etc/(alloy/|apt)|var/log/journal)'; then
    printf 'FAIL: %s: a system path escaped the sandbox rewrite\n' "$CASE" >&2
    exit 1
  fi
}

# Deliberately not valid text or valid Alloy: NUL, high bytes, no final newline.
seed_old_config() {
  printf 'old config, hand edited\r\n\000\377 target = "localhost:8091"' >"$CONFIG"
  chmod 640 "$CONFIG"
  cp "$CONFIG" "$BOX/old-config"
}

# The outer redirect drops bash's "Terminated" notice for the interrupted cases.
run_setup() {
  {
    (
      cd "$BOX" || exit 99
      umask "${RUN_UMASK:-022}"
      exec env -i PATH="$BOX/bin" BOX="$BOX" SECRET_MARKER="$SECRET" \
        REAL_ALLOY="$REAL_ALLOY" REAL_ENVSUBST="$REAL_ENVSUBST" \
        PRODUCT=ppclub SERVER_ID=ppclub-prod JOURNAL_MATCHES="$MATCHES" \
        LOKI_PUSH_URL=https://loki.example/loki/api/v1/push \
        CF_ACCESS_CLIENT_ID=fake.access CF_ACCESS_CLIENT_SECRET="$SECRET" \
        "$@" "$REAL_BASH" "$BOX/agents/setup.sh"
    ) </dev/null >"$BOX/log/out" 2>&1
  } 2>/dev/null
  RC=$?
}

# ─────────────────────────────── Assertions ─────────────────────────────────

rc_is() { [[ "$RC" -eq "$1" ]]; }
rc_failed() { [[ "$RC" -ne 0 ]]; }
mode_is() { [[ "$(file_mode "$1")" == "$2" ]]; }
absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
logged() { grep -q -- "$2" "$BOX/log/$1" 2>/dev/null; }
not_logged() { ! logged "$1" "$2"; }
dir_listing_is() { [[ "$(ls -A "$BOX/etc/alloy" | tr '\n' ' ')" == "$1" ]]; }
no_secret_on_disk() { ! grep -rq "$SECRET" "$BOX/etc/alloy"; }
real_alloy_accepts() { "$REAL_ALLOY" validate "$1" >/dev/null 2>&1; }
log_line_count_is() {
  local count
  count="$(grep -c -- "$2" "$BOX/log/$1" 2>/dev/null)"
  [[ "${count:-0}" -eq "$3" ]]
}

# `enable` must come after the last restart: a failed try must not change boot.
enabled_after_restart() {
  local last_restart enable_line
  last_restart="$(grep -n 'restart alloy' "$BOX/log/systemctl.log" | tail -1 | cut -d: -f1)"
  enable_line="$(grep -n 'enable alloy' "$BOX/log/systemctl.log" | tail -1 | cut -d: -f1)"
  [[ -n "$last_restart" && -n "$enable_line" && "$enable_line" -gt "$last_restart" ]]
}

secret_modes_all_private() {
  local _ mode
  [[ -s "$BOX/log/secret-modes.log" ]] || return 1
  while read -r _ mode _; do
    [[ "$mode" == "600" ]] || return 1
  done <"$BOX/log/secret-modes.log"
}

assert_old_config_intact() {
  check 'old config bytes preserved' cmp -s "$CONFIG" "$BOX/old-config"
  check 'old config mode preserved' mode_is "$CONFIG" 640
}

assert_no_restart() {
  check 'alloy was not restarted' not_logged systemctl.log 'restart alloy'
  check 'alloy was not enabled' not_logged systemctl.log 'enable alloy'
}

# ─────────────────────────────── Input errors ───────────────────────────────

assert_clean_input_error() {
  check "exit code $1" rc_is "$1"
  assert_old_config_intact
  assert_no_restart
  check 'nothing added next to the config' dir_listing_is 'config.alloy '
}

new_box input-missing-product
seed_old_config
run_setup PRODUCT=
assert_clean_input_error 2

new_box input-app-without-prom
seed_old_config
run_setup APP_METRICS_TARGET=localhost:8090
assert_clean_input_error 2

new_box input-app-without-prom-before-apt
seed_old_config
rm -f "$BOX/bin/alloy"
run_setup APP_METRICS_TARGET=localhost:8090
assert_clean_input_error 2
check 'apt-get was not run' absent "$BOX/log/apt.log"

new_box input-bearer-quote
seed_old_config
run_setup APP_METRICS_BEARER_TOKEN='has"quote'
assert_clean_input_error 2

new_box input-missing-template
seed_old_config
rm -f "$BOX/agents/config-metrics.alloy.tmpl"
run_setup PROM_PUSH_URL=https://prom.example/api/v1/write
assert_clean_input_error 2

new_box input-no-envsubst
seed_old_config
rm -f "$BOX/bin/envsubst"
run_setup
assert_clean_input_error 2

new_box input-not-root
seed_old_config
echo 1000 >"$BOX/ctl/uid"
run_setup
assert_clean_input_error 1

new_box input-no-credentials-no-tty
seed_old_config
run_setup CF_ACCESS_CLIENT_SECRET=
check 'run failed' rc_failed
assert_old_config_intact
assert_no_restart

# ─────────────────────────────── Render failure ─────────────────────────────

assert_clean_abort() {
  check 'exit code 1' rc_is 1
  assert_old_config_intact
  assert_no_restart
  check 'staged file removed' dir_listing_is 'config.alloy '
}

new_box render-fails-on-first-template
seed_old_config
touch "$BOX/ctl/envsubst-fails-on-1"
run_setup
assert_clean_abort

new_box render-fails-on-second-template
seed_old_config
touch "$BOX/ctl/envsubst-fails-on-2"
run_setup PROM_PUSH_URL=https://prom.example/api/v1/write
assert_clean_abort

new_box render-empty-output
seed_old_config
touch "$BOX/ctl/envsubst-empty"
run_setup
assert_clean_abort

# ─────────────────────────────── Validate failure ───────────────────────────

new_box validate-rejected
seed_old_config
touch "$BOX/ctl/validate-fails"
rmdir "$BOX/var/log/journal"
run_setup
assert_clean_abort
check 'journald not restarted for a rejected config' \
  not_logged systemctl.log 'restart systemd-journald'

new_box validate-unsupported-by-old-alloy
seed_old_config
touch "$BOX/ctl/no-validate"
run_setup
assert_clean_abort
check 'error names the required version' logged out 'v1.9.0'

new_box validate-rejected-by-real-alloy
seed_old_config
touch "$BOX/ctl/real-validate"
printf '\nnosuch.component "x" {\n}\n' >>"$BOX/agents/config-logs.alloy.tmpl"
run_setup
assert_clean_abort

new_box chown-fails
seed_old_config
touch "$BOX/ctl/chown-fails"
run_setup
check 'run failed' rc_failed
assert_old_config_intact
assert_no_restart
check 'staged file removed' dir_listing_is 'config.alloy '

# ─────────────────────────────── Activation failure ─────────────────────────

assert_rolled_back_and_restarted() {
  check 'exit code 1' rc_is 1
  assert_old_config_intact
  check 'first restart loaded the new config' logged systemctl.log 'restart alloy sees=new'
  check 'second restart loaded the old config' logged systemctl.log 'restart alloy sees=old'
  check 'exactly two restarts' log_line_count_is systemctl.log 'restart alloy' 2
  check 'alloy was not enabled' not_logged systemctl.log 'enable alloy'
  check 'no sidecar left behind' dir_listing_is 'config.alloy '
}

new_box restart-fails
seed_old_config
touch "$BOX/ctl/restart-fails-on-new"
run_setup
assert_rolled_back_and_restarted
check 'journal shown to the operator' logged out 'fake journal line'

new_box health-inactive-after-restart
seed_old_config
touch "$BOX/ctl/unhealthy-on-new"
run_setup
assert_rolled_back_and_restarted

new_box health-crash-loop
seed_old_config
touch "$BOX/ctl/crash-loop-on-new"
run_setup
assert_rolled_back_and_restarted

new_box restart-fails-when-previously-inactive
seed_old_config
rm -f "$BOX/ctl/active"
touch "$BOX/ctl/restart-fails-on-new"
run_setup
check 'exit code 1' rc_is 1
assert_old_config_intact
check 'alloy stopped, as it was before the run' logged systemctl.log 'stop alloy'
check 'old config not restarted' not_logged systemctl.log 'restart alloy sees=old'
check 'alloy was not enabled' not_logged systemctl.log 'enable alloy'

new_box rollback-restart-also-fails
seed_old_config
touch "$BOX/ctl/restart-fails-on-new" "$BOX/ctl/restart-fails-on-old"
run_setup
check 'exit code 3' rc_is 3
assert_old_config_intact
check 'operator told to act' logged out 'CRITICAL'

new_box rollback-old-config-does-not-stay-up
seed_old_config
touch "$BOX/ctl/restart-fails-on-new" "$BOX/ctl/unhealthy-on-old"
run_setup
check 'exit code 3' rc_is 3
assert_old_config_intact
check 'operator told to act' logged out 'CRITICAL'

new_box interrupted-during-restart
seed_old_config
touch "$BOX/ctl/term-on-restart"
run_setup
check 'exit code 143' rc_is 143
assert_old_config_intact
check 'old config restarted' logged systemctl.log 'restart alloy sees=old'
check 'no sidecar left behind' dir_listing_is 'config.alloy '

new_box interrupted-during-validate
seed_old_config
touch "$BOX/ctl/term-on-validate"
run_setup
check 'exit code 143' rc_is 143
assert_old_config_intact
assert_no_restart
check 'staged file removed' dir_listing_is 'config.alloy '
check 'no credential left on disk' no_secret_on_disk

new_box swap-rename-fails
seed_old_config
rm -f "$BOX/bin/mv"
cat >"$BOX/bin/mv" <<EOF
#!/bin/bash
exit 1
EOF
chmod 755 "$BOX/bin/mv"
run_setup
check 'exit code 1' rc_is 1
assert_old_config_intact
assert_no_restart
check 'no sidecar left behind' dir_listing_is 'config.alloy '

new_box failed-run-keeps-older-previous
seed_old_config
printf 'generation before last\n' >"$CONFIG.previous"
cp "$CONFIG.previous" "$BOX/older-previous"
touch "$BOX/ctl/restart-fails-on-new"
run_setup
check 'exit code 1' rc_is 1
assert_old_config_intact
check 'earlier previous untouched' cmp -s "$CONFIG.previous" "$BOX/older-previous"

# ─────────────────────────────── First install ──────────────────────────────

new_box first-install-success
run_setup
check 'exit code 0' rc_is 0
check 'config mode 640' mode_is "$CONFIG" 640
check 'config owner root:alloy' logged chown.log '^root:alloy '
check 'alloy was enabled' enabled_after_restart
check 'no previous config to keep' dir_listing_is 'config.alloy '

new_box first-install-restart-fails
touch "$BOX/ctl/restart-fails-on-new"
run_setup
check 'exit code 1' rc_is 1
check 'new config removed' absent "$CONFIG"
check 'no credential left on disk' no_secret_on_disk
check 'directory left empty' dir_listing_is ''
check 'alloy stopped' logged systemctl.log 'stop alloy'
check 'alloy was not enabled' not_logged systemctl.log 'enable alloy'

new_box first-install-validate-rejected
touch "$BOX/ctl/validate-fails"
run_setup
check 'exit code 1' rc_is 1
check 'no config written' absent "$CONFIG"
check 'no credential left on disk' no_secret_on_disk
assert_no_restart

new_box first-install-private-from-creation
RUN_UMASK=000 run_setup
check 'exit code 0' rc_is 0
check 'credential file private at every step' secret_modes_all_private
check 'final mode 640' mode_is "$CONFIG" 640

new_box apt-install-success
rm -f "$BOX/bin/alloy"
touch "$BOX/ctl/apt-ships-sample"
rm -f "$BOX/ctl/active"
run_setup
check 'exit code 0' rc_is 0
check 'apt-get installed alloy' logged apt.log 'install -y alloy'
check 'package sample kept as previous' cmp -s "$CONFIG.previous" "$BOX/old-config"

new_box apt-install-restart-fails
rm -f "$BOX/bin/alloy"
touch "$BOX/ctl/apt-ships-sample" "$BOX/ctl/restart-fails-on-new"
rm -f "$BOX/ctl/active"
run_setup
check 'exit code 1' rc_is 1
check 'package sample restored' cmp -s "$CONFIG" "$BOX/old-config"
check 'sample mode preserved' mode_is "$CONFIG" 644
check 'alloy stopped, as it was before the run' logged systemctl.log 'stop alloy'

# ─────────────────────────────── Target state ───────────────────────────────

new_box target-is-symlink
printf 'linked config\n' >"$BOX/etc/alloy/real.conf"
cp "$BOX/etc/alloy/real.conf" "$BOX/old-config"
ln -s real.conf "$CONFIG"
run_setup
check 'exit code 1' rc_is 1
check 'linked file untouched' cmp -s "$BOX/etc/alloy/real.conf" "$BOX/old-config"
check 'symlink still in place' test -L "$CONFIG"
assert_no_restart

new_box target-earlier-run-interrupted
seed_old_config
printf 'config from before the crash\n' >"$CONFIG.rollback"
cp "$CONFIG.rollback" "$BOX/crash-copy"
run_setup
check 'exit code 1' rc_is 1
assert_old_config_intact
check 'rollback copy untouched' cmp -s "$CONFIG.rollback" "$BOX/crash-copy"
check 'operator told what to do' logged out 'did not finish'
assert_no_restart

# ─────────────────────────────── Success path ───────────────────────────────

# JOURNAL_SOURCES is written out here rather than derived, so this expected
# output does not share code with the script. Templates are read as they are
# now, so template edits do not break the comparison.
SINGLE_SOURCE='
loki.source.journal "system" {
  matches    = "_SYSTEMD_UNIT=a.service _SYSTEMD_UNIT=b.service"
  max_age    = "5m"
  forward_to = [loki.process.scrub_pii.receiver]
  labels     = {
    product   = "ppclub",
    server_id = "ppclub-prod",
    job       = "journald",
  }
}
'

MULTI_SOURCE='
loki.source.journal "ppclub" {
  matches    = "_SYSTEMD_UNIT=a.service _SYSTEMD_UNIT=b.service"
  max_age    = "5m"
  forward_to = [loki.process.scrub_pii.receiver]
  labels     = {
    product   = "ppclub",
    server_id = "ppclub-prod",
    job       = "journald",
  }
}

loki.source.journal "enyoung" {
  matches    = "_SYSTEMD_UNIT=c.service"
  max_age    = "5m"
  forward_to = [loki.process.scrub_pii.receiver]
  labels     = {
    product   = "enyoung",
    server_id = "ppclub-prod",
    job       = "journald",
  }
}
'

BEARER_BLOCK="  authorization {
    type        = \"Bearer\"
    credentials = \"$BEARER\"
  }"

# expected_render SOURCES PROM_URL APP_TARGET AUTHORIZATION
expected_render() {
  local vars template
  vars='$PRODUCT $SERVER_ID $JOURNAL_MATCHES $LOKI_PUSH_URL $CF_ACCESS_CLIENT_ID $CF_ACCESS_CLIENT_SECRET $PROM_PUSH_URL $APP_METRICS_TARGET $APP_METRICS_AUTHORIZATION $JOURNAL_SOURCES'
  for template in logs ${2:+metrics} ${3:+app}; do
    env -i PRODUCT=ppclub SERVER_ID=ppclub-prod JOURNAL_MATCHES="$MATCHES" \
      LOKI_PUSH_URL=https://loki.example/loki/api/v1/push \
      CF_ACCESS_CLIENT_ID=fake.access CF_ACCESS_CLIENT_SECRET="$SECRET" \
      PROM_PUSH_URL="$2" APP_METRICS_TARGET="$3" APP_METRICS_AUTHORIZATION="$4" \
      JOURNAL_SOURCES="$1" "$REAL_ENVSUBST" "$vars" <"$AGENT_DIR/config-$template.alloy.tmpl"
  done
}

assert_success_shape() {
  check 'exit code 0' rc_is 0
  check 'config bytes equal the independent render' cmp -s "$CONFIG" "$BOX/expected"
  check 'config mode 640' mode_is "$CONFIG" 640
  check 'config owner root:alloy' logged chown.log '^root:alloy '
  check 'previous config kept byte for byte' cmp -s "$CONFIG.previous" "$BOX/old-config"
  check 'validated while the live config was still old' logged validate.log ' live=old '
  check 'staged file was private during validate' logged validate.log '^600 '
  check 'staged file was beside the config' logged validate.log " dir=$BOX/etc/alloy\$"
  check 'staged name is not one Alloy would load' not_logged validate.log '\.alloy dir='
  check 'one restart, on the new config' log_line_count_is systemctl.log 'restart alloy' 1
  check 'alloy enabled after it proved healthy' enabled_after_restart
  check 'only config and previous remain' dir_listing_is 'config.alloy config.alloy.previous '
}

PROM=https://prom.example/api/v1/write
APP=localhost:8090

new_box success-logs-only
seed_old_config
touch "$BOX/ctl/real-validate"
expected_render "$SINGLE_SOURCE" '' '' '' >"$BOX/expected"
run_setup
assert_success_shape

new_box success-with-metrics
seed_old_config
touch "$BOX/ctl/real-validate"
expected_render "$SINGLE_SOURCE" "$PROM" '' '' >"$BOX/expected"
run_setup PROM_PUSH_URL="$PROM"
assert_success_shape

new_box success-with-app
seed_old_config
touch "$BOX/ctl/real-validate"
expected_render "$SINGLE_SOURCE" "$PROM" "$APP" '' >"$BOX/expected"
run_setup PROM_PUSH_URL="$PROM" APP_METRICS_TARGET="$APP"
assert_success_shape

new_box success-with-app-bearer
seed_old_config
touch "$BOX/ctl/real-validate"
expected_render "$SINGLE_SOURCE" "$PROM" "$APP" "$BEARER_BLOCK" >"$BOX/expected"
run_setup PROM_PUSH_URL="$PROM" APP_METRICS_TARGET="$APP" APP_METRICS_BEARER_TOKEN="$BEARER"
assert_success_shape

new_box success-multi-tenant-map
seed_old_config
touch "$BOX/ctl/real-validate"
expected_render "$MULTI_SOURCE" "$PROM" '' '' >"$BOX/expected"
run_setup PROM_PUSH_URL="$PROM" \
  JOURNAL_PRODUCT_MAP='a.service|b\.service=ppclub;c.service=enyoung'
assert_success_shape

new_box success-enable-failure-is-a-warning
seed_old_config
touch "$BOX/ctl/enable-fails"
run_setup
check 'exit code 0' rc_is 0
check 'operator warned' logged out 'WARNING'

# A second good run must rotate previous, with no hard link left between the two.
new_box success-rerun-rotates-previous
seed_old_config
run_setup
cp "$CONFIG" "$BOX/first-run"
run_setup PROM_PUSH_URL="$PROM"
check 'exit code 0' rc_is 0
check 'previous is now the first run' cmp -s "$CONFIG.previous" "$BOX/first-run"
check 'config differs from previous' test ! "$CONFIG" -ef "$CONFIG.previous"

# With CONFIG_FILE=/etc/alloy, Alloy loads every *.alloy in the directory. The
# junk in config.alloy.previous would fail this if it were picked up.
new_box directory-mode-ignores-sidecars
seed_old_config
run_setup
printf 'not alloy {{{\n' >"$CONFIG.rollback"
printf 'not alloy {{{\n' >"$CONFIG.staged.Ab12Cd"
check 'exit code 0' rc_is 0
check 'real alloy validates the directory' real_alloy_accepts "$BOX/etc/alloy"

# ─────────────────────────────── Summary ────────────────────────────────────

if [[ "$FAILURES" -gt 0 ]]; then
  printf 'FAIL: setup.sh atomic install: %s of %s checks failed\n' "$FAILURES" "$CHECKS"
  exit 1
fi
printf 'PASS: setup.sh atomic install: %s checks\n' "$CHECKS"
