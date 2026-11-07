#!/usr/bin/env bash
#
# Behaviour tests for agents/alloy/trading/setup-macos.sh: nothing live changes
# until every staged file validates, only what changed is applied (reload for a
# config change, restart for an env change, bootstrap for a plist change), and
# any failure puts files, Alloy and both launchd jobs back as they were.
#
# Each case runs a copy of the agent directory in its own sandbox with
# PATH=<sandbox>/bin only, so no real brew, launchctl or Alloy service is
# reachable. brew, launchctl and curl are shims that keep their state in files;
# `alloy fmt` and `alloy validate` run the real binary. The script runs under
# /bin/bash, the 3.2 shell macOS ships.
#
# Not covered, because it needs a logged-in macOS session and a running Alloy
# that would push to the configured URLs: real launchd bootstrap, brew services
# and Alloy's /-/reload. The reload semantics the script relies on (200 for a
# good config; 400 with the old config still running for a bad one) were
# checked by hand against Alloy 1.17.1.
#
# VERBOSE=1 also prints every check that passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_DIR="$REPO_ROOT/agents/alloy"
VERBOSE="${VERBOSE:-0}"
RUN_BASH=/bin/bash
PROBE_LABEL=com.wanbrain.skyeye-trading-probe
HISTORY_LABEL=com.wanbrain.skyeye-trading-pnl-history

for tool in alloy perl plutil shasum "$RUN_BASH"; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'FAIL: %s is required; this suite must not pass by skipping\n' "$tool" >&2
    exit 1
  }
done
REAL_ALLOY="$(command -v alloy)"

# The script must reach brew, launchctl and curl through PATH, or the sandbox
# could not stand in for them.
if grep -nE '(^|[^[:alnum:]_.])/(usr/)?(local/)?s?bin/(brew|launchctl|curl)' \
  "$AGENT_DIR/trading/setup-macos.sh"; then
  printf 'FAIL: setup-macos.sh calls brew, launchctl or curl by absolute path\n' >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-macos-setup.XXXXXX")"
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
  fi
}

# ─────────────────────────────── Sandbox ────────────────────────────────────

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
ctl="$BOX/ctl"
state="$BOX/state"
calls="$BOX/log/calls.log"
config="$BOX/brew/etc/alloy/config.alloy"

# Which config.alloy a reload or restart would load right now.
config_state() {
  if [ ! -e "$config" ]; then
    echo none
  elif [ -e "$BOX/old-config" ] && cmp -s "$config" "$BOX/old-config"; then
    echo old
  else
    echo new
  fi
}
EOF

  shim sleep <<'EOF'
exit 0
EOF

  shim brew <<'EOF'
case "$1" in
  --prefix)
    echo "$BOX/brew"
    ;;
  tap)
    echo "brew tap $2" >>"$calls"
    ;;
  info)
    echo "brew info $*" >>"$calls"
    printf '{"formulae":[{"name":"alloy","versions":{"stable":"%s","head":null}}],"casks":[]}\n' \
      "$(cat "$ctl/brew-stable" 2>/dev/null || echo 1.18.1)"
    ;;
  install)
    echo "brew install $2" >>"$calls"
    cp "$BOX/shims/alloy" "$BOX/bin/alloy"
    ;;
  services)
    case "$2" in
      restart)
        seen="$(config_state)"
        echo "brew services restart sees=$seen" >>"$calls"
        [ ! -e "$ctl/restart-fails" ] || exit 1
        touch "$state/loaded_homebrew.mxcl.alloy"
        if [ -e "$ctl/unready-on-new" ] && [ "$seen" = new ]; then
          rm -f "$state/ready"
        else
          touch "$state/ready"
        fi
        ;;
      stop)
        echo "brew services stop" >>"$calls"
        rm -f "$state/loaded_homebrew.mxcl.alloy" "$state/ready"
        ;;
      *)
        echo "unexpected brew $*" >>"$calls"
        exit 2
        ;;
    esac
    ;;
  *)
    echo "unexpected brew $*" >>"$calls"
    exit 2
    ;;
esac
EOF

  shim launchctl <<'EOF'
case "$1" in
  print)
    [ -e "$state/loaded_${2##*/}" ]
    ;;
  bootout)
    label="${2##*/}"
    echo "launchctl bootout $label" >>"$calls"
    [ -e "$state/loaded_$label" ] || exit 3
    rm -f "$state/loaded_$label"
    ;;
  bootstrap)
    label="$(basename "$3" .plist)"
    echo "launchctl bootstrap $label" >>"$calls"
    if [ -e "$ctl/bootstrap-fails-once-$label" ]; then
      rm -f "$ctl/bootstrap-fails-once-$label"
      echo 'Bootstrap failed: 5: Input/output error' >&2
      exit 5
    fi
    touch "$state/loaded_$label"
    cp "$3" "$state/bootstrapped_$label"
    ;;
  enable)
    echo "launchctl enable ${2##*/}" >>"$calls"
    ;;
  *)
    echo "unexpected launchctl $*" >>"$calls"
    exit 2
    ;;
esac
EOF

  shim curl <<'EOF'
url=""
method=GET
for argument in "$@"; do
  case "$argument" in
    http://* | https://*) url="$argument" ;;
    POST) method=POST ;;
  esac
done
echo "curl $method $url" >>"$calls"
case "$url" in
  */-/ready)
    [ -e "$state/ready" ] || exit 7
    ;;
  */-/reload)
    seen="$(config_state)"
    echo "alloy reload sees=$seen" >>"$calls"
    if [ -e "$ctl/reload-rejects-new" ] && [ "$seen" = new ]; then
      echo 'error during the initial load: fixture rejects this config'
      exit 22
    fi
    echo 'config reloaded'
    ;;
  *)
    exit 2
    ;;
esac
EOF

  shim alloy <<'EOF'
case "$1" in
  --version)
    if [ -e "$ctl/version-output" ]; then
      cat "$ctl/version-output"
    else
      echo "alloy, version v$(cat "$ctl/version" 2>/dev/null || echo 1.18.1) (branch: HEAD, revision: shim)"
    fi
    ;;
  fmt)
    exec "$REAL_ALLOY" "$@"
    ;;
  validate)
    {
      printf 'alloy validate live=%s\n' "$(config_state)"
      ls -A "$BOX/brew/etc/alloy" "$BOX/home/Library/LaunchAgents" 2>/dev/null | sed 's/^/  listing /'
    } >>"$calls"
    exec "$REAL_ALLOY" "$@"
    ;;
  *)
    exit 1
    ;;
esac
EOF
}

new_box() {
  local tool
  CASE="$1"
  BOX="$WORK/$CASE"
  mkdir -p "$BOX/bin" "$BOX/shims" "$BOX/ctl" "$BOX/state" "$BOX/log" "$BOX/tmp" \
    "$BOX/home" "$BOX/brew/etc/alloy" "$BOX/brew/var" "$BOX/repo/logs" "$BOX/agents"
  for tool in basename cat chmod cmp cp date dirname env find grep head id install ls \
    mkdir mktemp mv perl plutil rm sed shasum stat touch tr; do
    ln -s "$(command -v "$tool")" "$BOX/bin/$tool"
  done
  ln -s "$RUN_BASH" "$BOX/bin/bash"
  write_shims
  : >"$BOX/log/calls.log"

  mkdir -p "$BOX/agents/alloy"
  cp "$AGENT_DIR/install-common.sh" "$AGENT_DIR/alloy-versions.env" "$BOX/agents/alloy/"
  cp -Rp "$AGENT_DIR/trading" "$BOX/agents/alloy/trading"
  TRADING="$BOX/agents/alloy/trading"
  LIVE_CONFIG="$BOX/brew/etc/alloy/config.alloy"
  LIVE_PROBE="$BOX/brew/libexec/skyeye-trading/probe.sh"
  LIVE_HISTORY="$BOX/brew/libexec/skyeye-trading/pnl-history.sh"
  LIVE_PROBE_PLIST="$BOX/home/Library/LaunchAgents/$PROBE_LABEL.plist"
  LIVE_HISTORY_PLIST="$BOX/home/Library/LaunchAgents/$HISTORY_LABEL.plist"
  STATE_DIR="$BOX/brew/var/skyeye-trading"
  ENV_FILE="$BOX/brew/etc/alloy/config.env"

  printf 'instance_id: "fixture"\n' >"$BOX/repo/config.yaml"
  cat >"$ENV_FILE" <<EOF
TQ_PRODUCT=tnauqquant
TQ_ENVIRONMENT=production
TQ_SERVER_ID=macmini-fixture
TQ_STRATEGY=toobit-mexc-btc
TQ_INSTANCE_ID=fixture
TQ_REPO_ROOT=$BOX/repo
TQ_REPO_ROOT_REGEX='($BOX/repo)'
TQ_EXECUTABLE=$BOX/repo/quant
TQ_CONFIG_PATH=$BOX/repo/config.yaml
TQ_RAW_LOG_GLOB='$BOX/repo/logs/*.raw.log'
TQ_RUN_MANIFEST=$BOX/repo/current.json
TQ_DONE_MARKER=$BOX/repo/current.done.json
TQ_POC_RUN_EXPECTED=1
TQ_REQUIRE_RUNTIME_CONTRACT=1
TQ_TIMEZONE=Asia/Taipei
TQ_TEXTFILE_DIR=$BOX/brew/var/lib/alloy/trading-textfile
TQ_PNL_HISTORY_CACHE_DIR=$BOX/brew/var/lib/alloy/pnl-history-cache
TQ_PNL_HISTORY_DAYS=30
TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES=500
LOKI_PUSH_URL=https://loki.invalid/loki/api/v1/push
PROM_PUSH_URL=https://prometheus.invalid/api/v1/write
CF_ACCESS_CLIENT_ID=sandbox-client.access
CF_ACCESS_CLIENT_SECRET=sandbox-secret-value
EOF
  chmod 600 "$ENV_FILE"
}

# run_setup [NAME=value ...] [-- script arguments]
run_setup() {
  local assignments=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    assignments+=("$1")
    shift
  done
  [[ "${1:-}" != "--" ]] || shift
  (
    cd "$BOX" || exit 99
    exec env -i PATH="$BOX/bin" HOME="$BOX/home" TMPDIR="$BOX/tmp" BOX="$BOX" \
      REAL_ALLOY="$REAL_ALLOY" ${assignments[@]+"${assignments[@]}"} \
      "$RUN_BASH" "$TRADING/setup-macos.sh" "$@"
  ) </dev/null >"$BOX/log/out" 2>&1
  RC=$?
}

# A host where a previous run installed and started everything.
install_host() {
  run_setup
  if [[ "$RC" -ne 0 ]]; then
    printf 'FAIL: %s: the initial install failed (rc=%s):\n' "$CASE" "$RC" >&2
    cat "$BOX/log/out" >&2
    exit 1
  fi
  cp "$LIVE_CONFIG" "$BOX/old-config"
  cp "$LIVE_PROBE_PLIST" "$BOX/old-probe-plist"
  : >"$BOX/log/calls.log"
}

# Every file a run could change, with its mode. The lock file is excluded: it
# exists from the first run on and holds no content.
snapshot() {
  local path
  find "$BOX/brew" "$BOX/home" \( -type f -o -type l \) ! -name setup.lock | LC_ALL=C sort |
    while IFS= read -r path; do
      printf '%s %s %s\n' "$path" "$(stat -f '%Lp' "$path")" "$(shasum -a 256 <"$path" | cut -c1-64)"
    done
}

# ─────────────────────────────── Assertions ─────────────────────────────────

rc_is() { [[ "$RC" -eq "$1" ]]; }
absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
mode_is() { [[ "$(stat -f '%Lp' "$1")" == "$2" ]]; }
logged() { grep -q -- "$2" "$BOX/log/$1" 2>/dev/null; }
not_logged() { ! logged "$1" "$2"; }
file_lacks() { ! grep -q -- "$2" "$1"; }
count_is() {
  local count
  count="$(grep -cE -- "$1" "$BOX/log/calls.log")"
  [[ "${count:-0}" -eq "$2" ]]
}
snapshot_unchanged() { snapshot | cmp -s - "$BOX/snapshot"; }
no_service_changes() {
  ! grep -qE '^(brew (install|services)|launchctl (bootout|bootstrap|enable)|alloy reload)' "$BOX/log/calls.log"
}
no_staged_files() {
  [[ -z "$(find "$BOX/brew" "$BOX/home" "$BOX/tmp" -name '*.staged.*' -print)" &&
     -z "$(find "$BOX/tmp" -mindepth 1 -maxdepth 1 -name 'skyeye-alloy-validate.*' -print)" ]]
}
# While validate ran, Alloy's directory held no *.alloy but config.alloy and
# LaunchAgents held no *.plist but the two real ones.
staged_names_never_loadable() {
  ! grep '^  listing ' "$BOX/log/calls.log" | sed 's/^  listing //' |
    grep -vxE "config[.]alloy|${PROBE_LABEL}[.]plist|${HISTORY_LABEL}[.]plist" | grep -qE '[.](alloy|plist)$'
}
latest_record() {
  find "$STATE_DIR/install-backup" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort | tail -1
}
record_lists() {
  local record
  record="$(latest_record)"
  [[ -n "$record" ]] || return 1
  [[ "$(wc -l <"$record/present.list" | tr -d ' ')" == "$1" &&
     "$(wc -l <"$record/absent.list" | tr -d ' ')" == "$2" ]]
}
record_status_is() {
  local record
  record="$(latest_record)"
  [[ -n "$record" ]] && grep -qx "status=$1" "$record/transaction.meta"
}
loaded() { [[ -e "$BOX/state/loaded_$1" ]]; }
alloy_ready_state() { [[ -e "$BOX/state/ready" ]]; }

change_template() {
  printf '\n// changed by %s\n' "$CASE" >>"$TRADING/config-macos.alloy.tmpl"
}
change_env() {
  printf '# rotated by %s\n' "$CASE" >>"$ENV_FILE"
}
change_probe_plist_template() {
  sed -i '' 's#^<dict>$#<dict>\
  <!-- changed by test -->#' "$TRADING/$PROBE_LABEL.plist.tmpl"
}

assert_refused_untouched() {
  check "exit code ${1:-1}" rc_is "${1:-1}"
  check 'no live file changed' snapshot_unchanged
  check 'no service was touched' no_service_changes
  check 'no staged file left behind' no_staged_files
}

# ─────────────────────────────── Fresh install ──────────────────────────────

new_box fresh-install
run_setup
check 'exit code 0' rc_is 0
check 'config is the template' cmp -s "$LIVE_CONFIG" "$TRADING/config-macos.alloy.tmpl"
check 'config mode 600' mode_is "$LIVE_CONFIG" 600
check 'probe mode 755' mode_is "$LIVE_PROBE" 755
check 'history mode 755' mode_is "$LIVE_HISTORY" 755
check 'probe plist mode 600' mode_is "$LIVE_PROBE_PLIST" 600
check 'history plist mode 600' mode_is "$LIVE_HISTORY_PLIST" 600
check 'plist runs the installed probe' grep -q "$BOX/brew/libexec/skyeye-trading/probe.sh" "$LIVE_PROBE_PLIST"
check 'plist names no secret' file_lacks "$LIVE_PROBE_PLIST" sandbox-secret-value
check 'validated before anything was live' logged calls.log '^alloy validate live=none$'
check 'staged names are never loadable' staged_names_never_loadable
check 'alloy started once' count_is '^brew services restart' 1
check 'alloy not reloaded' count_is '^alloy reload' 0
check 'probe job bootstrapped' logged calls.log "^launchctl bootstrap $PROBE_LABEL\$"
check 'history job bootstrapped' logged calls.log "^launchctl bootstrap $HISTORY_LABEL\$"
check 'nothing booted out' count_is '^launchctl bootout' 0
check 'record lists five added files' record_lists 0 5
check 'record committed' record_status_is committed
check 'environment record written' test -s "$STATE_DIR/installed-env.sha256"
check 'lock file mode 600' mode_is "$STATE_DIR/setup.lock" 600
check 'no staged file left behind' no_staged_files

new_box rerun-is-a-no-op
install_host
snapshot >"$BOX/snapshot"
run_setup
check 'exit code 0' rc_is 0
check 'reported as installed' logged out 'Already installed and running'
check 'no service was touched' no_service_changes
check 'no live file changed' snapshot_unchanged

# ─────────────────────────────── Only what changed ──────────────────────────

new_box config-change-reloads
install_host
change_template
run_setup
check 'exit code 0' rc_is 0
check 'config is the new template' cmp -s "$LIVE_CONFIG" "$TRADING/config-macos.alloy.tmpl"
check 'validated while the old config was live' logged calls.log '^alloy validate live=old$'
check 'one reload, of the new config' count_is '^alloy reload sees=new$' 1
check 'no restart' count_is '^brew services restart' 0
check 'no job reloaded' count_is '^launchctl b' 0
check 'record holds only the config' record_lists 1 0
check 'record keeps the old config' cmp -s "$(latest_record)/previous$LIVE_CONFIG" "$BOX/old-config"

new_box env-change-restarts
install_host
cp "$STATE_DIR/installed-env.sha256" "$BOX/old-env-record"
change_env
run_setup
check 'exit code 0' rc_is 0
check 'one restart' count_is '^brew services restart' 1
check 'no reload' count_is '^alloy reload' 0
check 'no job reloaded' count_is '^launchctl b' 0
check 'environment record updated' test "$(cat "$STATE_DIR/installed-env.sha256")" != "$(cat "$BOX/old-env-record")"
: >"$BOX/log/calls.log"
run_setup
check 'the run after is a no-op' logged out 'Already installed and running'

new_box env-and-config-change-restarts
install_host
change_env
change_template
run_setup
check 'exit code 0' rc_is 0
check 'one restart, on the new config' count_is '^brew services restart sees=new$' 1
check 'no reload' count_is '^alloy reload' 0

new_box extra-args-change-restarts
install_host
printf -- '--disable-reporting\n' >"$BOX/brew/etc/alloy/extra-args.txt"
run_setup
check 'exit code 0' rc_is 0
check 'one restart' count_is '^brew services restart' 1

new_box restart-flag
install_host
run_setup -- --restart-alloy
check 'exit code 0' rc_is 0
check 'one restart' count_is '^brew services restart' 1
check 'no job reloaded' count_is '^launchctl b' 0

new_box no-environment-record-restarts
install_host
rm -f "$STATE_DIR/installed-env.sha256"
run_setup
check 'exit code 0' rc_is 0
check 'one restart' count_is '^brew services restart' 1
check 'reason given' logged out 'no record of the config.env'
check 'environment record written' test -s "$STATE_DIR/installed-env.sha256"

new_box plist-change-bootstraps-only-that-job
install_host
change_probe_plist_template
run_setup
check 'exit code 0' rc_is 0
check 'probe job booted out' count_is "^launchctl bootout $PROBE_LABEL\$" 1
check 'probe job bootstrapped' count_is "^launchctl bootstrap $PROBE_LABEL\$" 1
check 'history job untouched' count_is "^launchctl .*$HISTORY_LABEL" 0
check 'alloy untouched' count_is '^(brew services|alloy reload)' 0
check 'launchd loaded the new plist' cmp -s "$BOX/state/bootstrapped_$PROBE_LABEL" "$LIVE_PROBE_PLIST"

new_box script-change-touches-no-service
install_host
printf '\n# changed by test\n' >>"$TRADING/probe.sh"
run_setup
check 'exit code 0' rc_is 0
check 'probe is the new script' cmp -s "$LIVE_PROBE" "$TRADING/probe.sh"
check 'no service was touched' no_service_changes
check 'record holds only the probe' record_lists 1 0

new_box unloaded-job-is-loaded
install_host
rm -f "$BOX/state/loaded_$HISTORY_LABEL"
run_setup
check 'exit code 0' rc_is 0
check 'history job bootstrapped' count_is "^launchctl bootstrap $HISTORY_LABEL\$" 1
check 'probe job untouched' count_is "^launchctl .*$PROBE_LABEL" 0
check 'alloy untouched' count_is '^(brew services|alloy reload)' 0

new_box listen-address-from-extra-args
printf -- '--server.http.listen-addr=0.0.0.0:23456\n' >"$BOX/brew/etc/alloy/extra-args.txt"
run_setup
check 'exit code 0' rc_is 0
check 'readiness read from the configured port' logged calls.log '^curl GET http://127.0.0.1:23456/-/ready$'
check 'default port never used' not_logged calls.log '12345'

# ─────────────────────────────── Validation failures ────────────────────────

new_box alloy-validate-rejects
install_host
snapshot >"$BOX/snapshot"
printf '\nnosuch.component "x" {\n}\n' >>"$TRADING/config-macos.alloy.tmpl"
run_setup
assert_refused_untouched
check 'alloy validate named' logged out 'alloy validate rejected'

new_box alloy-validate-rejects-on-a-fresh-host
printf '\nnosuch.component "x" {\n}\n' >>"$TRADING/config-macos.alloy.tmpl"
run_setup
check 'exit code 1' rc_is 1
check 'no config installed' absent "$LIVE_CONFIG"
check 'no probe installed' absent "$LIVE_PROBE"
check 'no plist installed' absent "$LIVE_PROBE_PLIST"
check 'no service was touched' no_service_changes
check 'no staged file left behind' no_staged_files

new_box probe-does-not-parse
install_host
snapshot >"$BOX/snapshot"
printf '\nif then fi (\n' >>"$TRADING/probe.sh"
run_setup
assert_refused_untouched
check 'probe named' logged out 'probe.sh does not parse'

new_box plist-does-not-lint
install_host
snapshot >"$BOX/snapshot"
sed -i '' 's#^</dict>$##' "$TRADING/$PROBE_LABEL.plist.tmpl"
run_setup
assert_refused_untouched
check 'plist named' logged out 'probe launchd plist is invalid'

new_box destination-symlink-refused
install_host
mv "$LIVE_CONFIG" "$BOX/brew/etc/alloy/real-config"
ln -s real-config "$LIVE_CONFIG"
snapshot >"$BOX/snapshot"
change_template
run_setup
assert_refused_untouched
check 'symlink kept' test -L "$LIVE_CONFIG"

# ─────────────────────────────── Rollback ───────────────────────────────────

new_box reload-rejected-rolls-back
install_host
change_template
touch "$BOX/ctl/reload-rejects-new"
run_setup
check 'exit code 1' rc_is 1
check 'old config restored byte for byte' cmp -s "$LIVE_CONFIG" "$BOX/old-config"
check 'old config mode kept' mode_is "$LIVE_CONFIG" 600
check 'reload of the new config tried first' logged calls.log '^alloy reload sees=new$'
check 'old config reloaded after' logged calls.log '^alloy reload sees=old$'
check 'never restarted' count_is '^brew services restart' 0
check "Alloy's error shown" logged out 'fixture rejects this config'
check 'record marked rolled back' record_status_is rolled_back
check 'record path printed' logged out 'Record: '
check 'no staged file left behind' no_staged_files

new_box restart-not-ready-rolls-back
install_host
cp "$STATE_DIR/installed-env.sha256" "$BOX/old-env-record"
change_env
change_template
touch "$BOX/ctl/unready-on-new"
run_setup
check 'exit code 1' rc_is 1
check 'old config restored' cmp -s "$LIVE_CONFIG" "$BOX/old-config"
check 'restarted on the new config' logged calls.log '^brew services restart sees=new$'
check 'restarted again on the old config' logged calls.log '^brew services restart sees=old$'
check 'alloy ready again' alloy_ready_state
check 'environment record unchanged' cmp -s "$STATE_DIR/installed-env.sha256" "$BOX/old-env-record"
check 'record marked rolled back' record_status_is rolled_back

new_box first-start-fails-stops-alloy
touch "$BOX/ctl/unready-on-new"
run_setup
check 'exit code 1' rc_is 1
check 'new files removed' absent "$LIVE_CONFIG"
check 'new plists removed' absent "$LIVE_PROBE_PLIST"
check 'alloy stopped, as it was' logged calls.log '^brew services stop$'
check 'alloy not loaded' test ! -e "$BOX/state/loaded_homebrew.mxcl.alloy"
check 'no environment record' absent "$STATE_DIR/installed-env.sha256"

new_box bootstrap-fails-restores-old-plist
install_host
change_probe_plist_template
touch "$BOX/ctl/bootstrap-fails-once-$PROBE_LABEL"
run_setup
check 'exit code 1' rc_is 1
check 'old plist restored' cmp -s "$LIVE_PROBE_PLIST" "$BOX/old-probe-plist"
check 'probe job loaded again' loaded "$PROBE_LABEL"
check 'launchd holds the old plist' cmp -s "$BOX/state/bootstrapped_$PROBE_LABEL" "$BOX/old-probe-plist"
check 'history job untouched' count_is "^launchctl .*$HISTORY_LABEL" 0
check 'alloy untouched' count_is '^(brew services|alloy reload)' 0
check 'record marked rolled back' record_status_is rolled_back

new_box rollback-that-fails-says-so
install_host
change_template
touch "$BOX/ctl/reload-rejects-new"
cp "$BOX/old-config" "$BOX/keep-old-config"
rm -f "$BOX/old-config"
run_setup
check 'exit code 3' rc_is 3
check 'operator told to act' logged out 'CRITICAL: rollback did not finish'
check 'files still restored' cmp -s "$LIVE_CONFIG" "$BOX/keep-old-config"
check 'record marked incomplete' record_status_is rollback_incomplete

# ─────────────────────────────── --no-start ─────────────────────────────────

new_box no-start-refused-while-running
install_host
snapshot >"$BOX/snapshot"
change_template
run_setup -- --no-start
assert_refused_untouched
check 'reason given' logged out 'only runs while Alloy and both launchd jobs are stopped'

new_box no-start-on-a-fresh-host
run_setup -- --no-start
check 'exit code 0' rc_is 0
check 'config installed' cmp -s "$LIVE_CONFIG" "$TRADING/config-macos.alloy.tmpl"
check 'plists installed' test -f "$LIVE_PROBE_PLIST" -a -f "$LIVE_HISTORY_PLIST"
check 'nothing started' no_service_changes
check 'no environment record' absent "$STATE_DIR/installed-env.sha256"
check 'said so' logged out 'without starting services'
run_setup -- --no-start
check 'a second --no-start is a no-op' logged out 'Already installed (no changes; nothing started'
: >"$BOX/log/calls.log"
run_setup
check 'the next run starts everything' rc_is 0
check 'alloy started' count_is '^brew services restart' 1
check 'both jobs bootstrapped' count_is '^launchctl bootstrap' 2

new_box no-start-with-restart-flag
install_host
snapshot >"$BOX/snapshot"
run_setup -- --no-start --restart-alloy
assert_refused_untouched

# ─────────────────────────────── Version and lock ───────────────────────────

new_box untested-alloy-refused
install_host
snapshot >"$BOX/snapshot"
echo 1.16.3 >"$BOX/ctl/version"
change_template
run_setup
assert_refused_untouched
check 'names the versions' logged out 'installed Alloy 1.16.3 is not tested on macos (tested: 1.18.1)'

new_box override-must-match-exactly
install_host
snapshot >"$BOX/snapshot"
echo 1.16.3 >"$BOX/ctl/version"
change_template
run_setup SKYEYE_ALLOY_UNTESTED_VERSION=1.16
assert_refused_untouched

new_box override-exact-continues
install_host
echo 1.16.3 >"$BOX/ctl/version"
change_template
run_setup SKYEYE_ALLOY_UNTESTED_VERSION=1.16.3
check 'exit code 0' rc_is 0
check 'operator warned' logged out 'WARNING: installed Alloy 1.16.3 is not tested'

new_box brew-would-install-untested-alloy
rm -f "$BOX/bin/alloy"
echo 1.21.3 >"$BOX/ctl/brew-stable"
run_setup
check 'exit code 1' rc_is 1
check 'nothing installed by brew' not_logged calls.log '^brew install'
check 'names the version' logged out "Homebrew's grafana/grafana/alloy 1.21.3 is not tested on macos"
check 'no config installed' absent "$LIVE_CONFIG"

new_box brew-installs-tested-alloy
rm -f "$BOX/bin/alloy"
run_setup
check 'exit code 0' rc_is 0
check 'brew installed alloy' logged calls.log '^brew install grafana/grafana/alloy$'

new_box lock-held-by-another-run
install_host
snapshot >"$BOX/snapshot"
change_template
exec 8>>"$STATE_DIR/setup.lock"
perl -MFcntl=:flock -e 'open(my $fh, ">>&=", 8) or exit 2; exit(flock($fh, LOCK_EX | LOCK_NB) ? 0 : 1)' || {
  printf 'FAIL: %s: the test could not take the lock\n' "$CASE" >&2
  exit 1
}
run_setup
exec 8>&-
assert_refused_untouched
check 'names the lock file' logged out "holds $STATE_DIR/setup.lock"

new_box foreign-alloy-refused
touch "$BOX/state/ready"
run_setup
check 'exit code 1' rc_is 1
check 'reason given' logged out 'is not loaded in gui/'
check 'nothing started' no_service_changes

# ─────────────────────────────── Summary ────────────────────────────────────

if [[ "$FAILURES" -gt 0 ]]; then
  printf 'FAIL: setup-macos.sh transaction: %s of %s checks failed\n' "$FAILURES" "$CHECKS"
  exit 1
fi
printf 'PASS: setup-macos.sh transaction: %s checks\n' "$CHECKS"
