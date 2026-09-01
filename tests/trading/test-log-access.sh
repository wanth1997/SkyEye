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

printf 'PASS: Linux raw-log ACL repair contract\n'
