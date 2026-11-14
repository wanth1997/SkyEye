#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACCESS_HELPER="$REPO_ROOT/agents/alloy/trading/ensure-log-access.sh"

[[ -x "$ACCESS_HELPER" ]] || {
  printf 'FAIL: Linux raw-log access helper is missing or not executable\n' >&2
  exit 1
}

TEST_ROOT="$(mktemp -d /tmp/skyeye-log-access.XXXXXX)"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

FAKE_REPO="$TEST_ROOT/tnauqquant"
RAW_LOG_DIR="$FAKE_REPO/logs/live-runs"
FAKE_BIN="$TEST_ROOT/bin"
ACCESS_STATE="$TEST_ROOT/access-state"
SETFACL_LOG="$TEST_ROOT/setfacl.log"
mkdir -p "$RAW_LOG_DIR" "$FAKE_BIN" "$ACCESS_STATE"
printf 'one\n' >"$RAW_LOG_DIR/current.raw.log"
printf 'two\n' >"$RAW_LOG_DIR/previous.raw.log"
printf 'ignore\n' >"$RAW_LOG_DIR/not-a-raw-log.txt"
: >"$SETFACL_LOG"

cat >"$FAKE_BIN/getfacl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  target="$argument"
done
basename="${target##*/}"
printf '%s\n' 'user::rw-'
if [[ -f "$ACCESS_STATE/$basename" ]]; then
  printf '%s\n' 'user:alloy:r--' 'mask::r--'
else
  printf '%s\n' 'group::---' 'mask::---'
fi
printf '%s\n' 'other::---'
EOF

cat >"$FAKE_BIN/setfacl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  target="$argument"
done
basename="${target##*/}"
printf '%s\n' "$target" >>"$SETFACL_LOG"
: >"$ACCESS_STATE/$basename"
EOF
chmod 755 "$FAKE_BIN/getfacl" "$FAKE_BIN/setfacl"

export ACCESS_STATE SETFACL_LOG
export TQ_REPO_ROOT="$FAKE_REPO"
export TQ_RAW_LOG_GLOB="$RAW_LOG_DIR/*.raw.log"
export TQ_ALLOY_USER=alloy

PATH="$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER"

[[ "$(wc -l <"$SETFACL_LOG" | tr -d ' ')" == "2" ]]
rg -q '/current[.]raw[.]log$' "$SETFACL_LOG"
rg -q '/previous[.]raw[.]log$' "$SETFACL_LOG"
if rg -q 'not-a-raw-log' "$SETFACL_LOG"; then
  printf 'FAIL: access helper touched a file outside the configured glob\n' >&2
  exit 1
fi

PATH="$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER"
[[ "$(wc -l <"$SETFACL_LOG" | tr -d ' ')" == "2" ]]

printf 'three\n' >"$RAW_LOG_DIR/new-run.raw.log"
PATH="$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER"
[[ "$(wc -l <"$SETFACL_LOG" | tr -d ' ')" == "3" ]]
rg -q '/new-run[.]raw[.]log$' "$SETFACL_LOG"

mkdir -p "$TEST_ROOT/outside"
if TQ_RAW_LOG_GLOB="$TEST_ROOT/outside/*.raw.log" \
  PATH="$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER" \
  >"$TEST_ROOT/unsafe.out" 2>"$TEST_ROOT/unsafe.err"
then
  printf 'FAIL: access helper accepted a glob outside TQ_REPO_ROOT\n' >&2
  exit 1
fi

# GNU find saves its starting directory and returns to it before exiting.
# Started from a directory its user cannot open (runuser from a root shell in
# /root, mode 700), it lists every file and then exits 1 with this message.
# This test runs as one user, so the model marks one directory as unopenable.
GNU_FIND_BIN="$TEST_ROOT/gnu-find-bin"
DENIED_CWD="$TEST_ROOT/root-home"
mkdir -p "$GNU_FIND_BIN" "$DENIED_CWD"
DENIED_CWD="$(cd "$DENIED_CWD" && pwd -P)"
cat >"$GNU_FIND_BIN/find" <<'EOF'
#!/usr/bin/env bash
start_dir="$(pwd -P)"
case "$start_dir/" in
  "$FAKE_DENIED_CWD"/*)
    /usr/bin/find "$@"
    printf 'find: Failed to restore initial working directory: %s: Permission denied\n' \
      "$start_dir" >&2
    exit 1
    ;;
esac
exec /usr/bin/find "$@"
EOF
chmod 755 "$GNU_FIND_BIN/find"

printf 'case: the helper works from a working directory its user cannot open\n'
printf 'four\n' >"$RAW_LOG_DIR/denied-cwd.raw.log"
if ! (cd "$DENIED_CWD" && FAKE_DENIED_CWD="$DENIED_CWD" \
  PATH="$GNU_FIND_BIN:$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER") \
  >"$TEST_ROOT/denied-cwd.out" 2>"$TEST_ROOT/denied-cwd.err"
then
  printf 'FAIL: access helper failed when started from an unopenable directory:\n' >&2
  cat "$TEST_ROOT/denied-cwd.err" >&2
  exit 1
fi
rg -q '/denied-cwd[.]raw[.]log$' "$SETFACL_LOG" || {
  printf 'FAIL: access helper started from an unopenable directory did not repair the new log\n' >&2
  exit 1
}

printf 'case: a failed find is reported, not silent\n'
FAILING_FIND_BIN="$TEST_ROOT/failing-find-bin"
mkdir -p "$FAILING_FIND_BIN"
cat >"$FAILING_FIND_BIN/find" <<'EOF'
#!/usr/bin/env bash
printf "find: '%s': Permission denied\n" "$1" >&2
exit 1
EOF
chmod 755 "$FAILING_FIND_BIN/find"
if PATH="$FAILING_FIND_BIN:$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER" \
  >"$TEST_ROOT/find-fail.out" 2>"$TEST_ROOT/find-fail.err"
then
  printf 'FAIL: access helper accepted a failed find\n' >&2
  exit 1
fi
rg -q "^find: '.*/logs/live-runs': Permission denied$" "$TEST_ROOT/find-fail.err" || {
  printf 'FAIL: access helper hid find'"'"'s own error:\n' >&2
  cat "$TEST_ROOT/find-fail.err" >&2
  exit 1
}
rg -q '^SkyEye trading log access: listing configured raw logs with find failed [(]rc=1[)]' \
  "$TEST_ROOT/find-fail.err" || {
  printf 'FAIL: access helper did not name the failed find step:\n' >&2
  cat "$TEST_ROOT/find-fail.err" >&2
  exit 1
}

printf 'PASS: Linux raw-log ACL repair contract\n'
