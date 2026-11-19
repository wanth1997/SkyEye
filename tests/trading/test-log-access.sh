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
GETFACL_CALLS="$TEST_ROOT/getfacl.calls"
SETFACL_CALLS="$TEST_ROOT/setfacl.calls"
mkdir -p "$RAW_LOG_DIR" "$FAKE_BIN" "$ACCESS_STATE"
printf 'one\n' >"$RAW_LOG_DIR/current.raw.log"
printf 'two\n' >"$RAW_LOG_DIR/previous.raw.log"
printf 'ignore\n' >"$RAW_LOG_DIR/not-a-raw-log.txt"
: >"$SETFACL_LOG"
: >"$GETFACL_CALLS"
: >"$SETFACL_CALLS"

cat >"$FAKE_BIN/getfacl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'call\n' >>"$GETFACL_CALLS"
targets=()
seen_dashdash=0
for argument in "$@"; do
  if [[ "$seen_dashdash" -eq 1 ]]; then
    targets+=("$argument")
  elif [[ "$argument" == "--" ]]; then
    seen_dashdash=1
  elif [[ "$argument" != -* ]]; then
    targets+=("$argument")
  fi
done
for target in "${targets[@]}"; do
  basename="${target##*/}"
  state=""
  if [[ -f "$ACCESS_STATE/$basename" ]]; then
    state="$(cat "$ACCESS_STATE/$basename")"
    [[ -n "$state" ]] || state="ok"
  fi
  printf '%s\n' 'user::rw-'
  case "$state" in
    ok)
      printf '%s\n' 'user:alloy:r--' 'group::---' 'mask::r--'
      ;;
    masked)
      printf 'user:alloy:r--\t\t\t#effective:---\n'
      printf '%s\n' 'group::---' 'mask::---'
      ;;
    *)
      printf '%s\n' 'group::---' 'mask::---'
      ;;
  esac
  printf '%s\n\n' 'other::---'
done
EOF

cat >"$FAKE_BIN/setfacl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'call\n' >>"$SETFACL_CALLS"
targets=()
seen_dashdash=0
expect_mod=0
mod_count=0
mod_spec=""
for argument in "$@"; do
  if [[ "$expect_mod" -eq 1 ]]; then
    mod_count=$((mod_count + 1))
    mod_spec="$argument"
    expect_mod=0
    continue
  fi
  if [[ "$seen_dashdash" -eq 1 ]]; then
    targets+=("$argument")
  elif [[ "$argument" == "--" ]]; then
    seen_dashdash=1
  elif [[ "$argument" == "-m" ]]; then
    expect_mod=1
  elif [[ "$argument" != -* ]]; then
    targets+=("$argument")
  fi
done
if [[ "$expect_mod" -eq 1 || "$mod_count" -ne 1 || "$mod_spec" != "u:alloy:r--" ]]; then
  printf 'fake setfacl: expected exactly one -m u:alloy:r-- operand (count=%s, spec=%s)\n' \
    "$mod_count" "$mod_spec" >&2
  exit 1
fi
for target in "${targets[@]}"; do
  basename="${target##*/}"
  printf '%s\n' "$target" >>"$SETFACL_LOG"
  printf 'ok\n' >"$ACCESS_STATE/$basename"
done
EOF
chmod 755 "$FAKE_BIN/getfacl" "$FAKE_BIN/setfacl"

export ACCESS_STATE SETFACL_LOG GETFACL_CALLS SETFACL_CALLS
export TQ_REPO_ROOT="$FAKE_REPO"
export TQ_RAW_LOG_GLOB="$RAW_LOG_DIR/*.raw.log"
export TQ_ALLOY_USER=alloy

assert_line_count() {
  local label="$1"
  local file="$2"
  local expected="$3"
  local actual
  actual="$(wc -l <"$file" | tr -d ' ')"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s: expected %s lines in %s, got %s\n' "$label" "$expected" "$file" "$actual" >&2
    exit 1
  fi
}

PATH="$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER"

assert_line_count "initial repair files" "$SETFACL_LOG" 2
assert_line_count "initial getfacl calls" "$GETFACL_CALLS" 1
assert_line_count "initial setfacl calls" "$SETFACL_CALLS" 1
rg -q '/current[.]raw[.]log$' "$SETFACL_LOG"
rg -q '/previous[.]raw[.]log$' "$SETFACL_LOG"
if rg -q 'not-a-raw-log' "$SETFACL_LOG"; then
  printf 'FAIL: access helper touched a file outside the configured glob\n' >&2
  exit 1
fi

printf 'case: files with ACL already present trigger one getfacl and zero setfacl calls\n'
: >"$GETFACL_CALLS"
: >"$SETFACL_CALLS"
PATH="$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER"
assert_line_count "already-OK setfacl log unchanged" "$SETFACL_LOG" 2
assert_line_count "already-OK getfacl calls" "$GETFACL_CALLS" 1
assert_line_count "already-OK setfacl calls" "$SETFACL_CALLS" 0

printf 'case: a single newly missing file triggers setfacl on that file only\n'
: >"$GETFACL_CALLS"
: >"$SETFACL_CALLS"
printf 'three\n' >"$RAW_LOG_DIR/new-run.raw.log"
PATH="$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER"
assert_line_count "new-run total repaired" "$SETFACL_LOG" 3
assert_line_count "new-run getfacl calls" "$GETFACL_CALLS" 1
assert_line_count "new-run setfacl calls" "$SETFACL_CALLS" 1
rg -q '/new-run[.]raw[.]log$' "$SETFACL_LOG"

printf 'case: a mask-restricted file is repaired while already-OK files and outside files are untouched\n'
: >"$SETFACL_LOG"
: >"$GETFACL_CALLS"
: >"$SETFACL_CALLS"
printf 'masked\n' >"$RAW_LOG_DIR/masked-run.raw.log"
printf 'masked\n' >"$ACCESS_STATE/masked-run.raw.log"
PATH="$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER"
assert_line_count "masked-run repaired files" "$SETFACL_LOG" 1
assert_line_count "masked-run getfacl calls" "$GETFACL_CALLS" 1
assert_line_count "masked-run setfacl calls" "$SETFACL_CALLS" 1
rg -q '/masked-run[.]raw[.]log$' "$SETFACL_LOG"
if rg -q 'current[.]raw[.]log|previous[.]raw[.]log|new-run[.]raw[.]log|not-a-raw-log' "$SETFACL_LOG"; then
  printf 'FAIL: access helper touched an already-OK or outside file when repairing mask-restricted file\n' >&2
  exit 1
fi
: >"$SETFACL_CALLS"
PATH="$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER"
assert_line_count "masked-run re-run setfacl calls" "$SETFACL_CALLS" 0

printf 'case: a matched filename containing spaces is handled cleanly by batched getfacl/setfacl\n'
: >"$SETFACL_LOG"
: >"$GETFACL_CALLS"
: >"$SETFACL_CALLS"
printf 'spaced\n' >"$RAW_LOG_DIR/run with spaces.raw.log"
PATH="$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER"
assert_line_count "spaced file repaired" "$SETFACL_LOG" 1
assert_line_count "spaced file getfacl calls" "$GETFACL_CALLS" 1
assert_line_count "spaced file setfacl calls" "$SETFACL_CALLS" 1
rg -q '/run with spaces[.]raw[.]log$' "$SETFACL_LOG"

printf 'case: truncated getfacl output fails closed without running setfacl\n'
TRUNCATED_GETFACL_BIN="$TEST_ROOT/truncated-getfacl-bin"
mkdir -p "$TRUNCATED_GETFACL_BIN"
cat >"$TRUNCATED_GETFACL_BIN/getfacl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'user::rw-' 'group::---' 'mask::---' 'other::---'
EOF
chmod 755 "$TRUNCATED_GETFACL_BIN/getfacl"
: >"$SETFACL_CALLS"
if PATH="$TRUNCATED_GETFACL_BIN:$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER" \
  >"$TEST_ROOT/trunc.out" 2>"$TEST_ROOT/trunc.err"
then
  printf 'FAIL: access helper accepted truncated getfacl output\n' >&2
  exit 1
fi
assert_line_count "truncated getfacl setfacl calls" "$SETFACL_CALLS" 0
rg -q 'unable to inspect a configured raw log ACL' "$TEST_ROOT/trunc.err" || {
  printf 'FAIL: access helper did not report truncated getfacl failure:\n' >&2
  cat "$TEST_ROOT/trunc.err" >&2
  exit 1
}

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

printf 'case: fake setfacl rejects any modification other than exactly one u:alloy:r--\n'
: >"$SETFACL_LOG"
rm -f "$ACCESS_STATE/probe-spec-check.raw.log"
for wrong_spec in 'u:other:r--' 'u:alloy:rw-' 'u:alloy:r-x' ''; do
  if "$FAKE_BIN/setfacl" -m "$wrong_spec" -- "$RAW_LOG_DIR/probe-spec-check.raw.log" >/dev/null 2>&1; then
    printf 'FAIL: fake setfacl accepted wrong -m operand: %s\n' "$wrong_spec" >&2
    exit 1
  fi
done
if "$FAKE_BIN/setfacl" -m 'u:other:r--' -m 'u:alloy:r--' -- "$RAW_LOG_DIR/probe-spec-check.raw.log" >/dev/null 2>&1; then
  printf 'FAIL: fake setfacl accepted duplicate -m operands (extra user first)\n' >&2
  exit 1
fi
if "$FAKE_BIN/setfacl" -m 'u:alloy:r--' -m 'u:other:r--' -- "$RAW_LOG_DIR/probe-spec-check.raw.log" >/dev/null 2>&1; then
  printf 'FAIL: fake setfacl accepted duplicate -m operands (extra user second)\n' >&2
  exit 1
fi
if [[ -e "$ACCESS_STATE/probe-spec-check.raw.log" ]]; then
  printf 'FAIL: fake setfacl recorded repair despite invalid -m operand(s)\n' >&2
  exit 1
fi
assert_line_count "wrong -m operand setfacl log" "$SETFACL_LOG" 0

if bash -O lastpipe -c : 2>/dev/null; then
  printf 'case: empty failed find is reported even with Bash lastpipe enabled (C10)\n'
  if PATH="$FAILING_FIND_BIN:$FAKE_BIN:/usr/bin:/bin" bash -O lastpipe "$ACCESS_HELPER" \
    >"$TEST_ROOT/lastpipe-fail.out" 2>"$TEST_ROOT/lastpipe-fail.err"
  then
    printf 'FAIL: access helper exited 0 on failed empty find with lastpipe enabled\n' >&2
    exit 1
  fi
  rg -q '^SkyEye trading log access: listing configured raw logs with find failed [(]rc=1[)]' \
    "$TEST_ROOT/lastpipe-fail.err" || {
    printf 'FAIL: access helper with lastpipe did not report failed find:\n' >&2
    cat "$TEST_ROOT/lastpipe-fail.err" >&2
    exit 1
  }
fi

printf 'case: >500 short matching paths use 1 getfacl call, 1 awk pass, and 1 setfacl call\n'
MANY_REPO="$TEST_ROOT/many"
MANY_LOGS="$MANY_REPO/l"
MANY_STATE="$TEST_ROOT/many-state"
MANY_AWK_BIN="$TEST_ROOT/many-awk-bin"
AWK_CALLS="$TEST_ROOT/awk.calls"
REAL_AWK="$(command -v awk)"
mkdir -p "$MANY_LOGS" "$MANY_STATE" "$MANY_AWK_BIN"
cat >"$MANY_AWK_BIN/awk" <<EOF
#!/usr/bin/env bash
printf 'call\n' >>"$AWK_CALLS"
exec "$REAL_AWK" "\$@"
EOF
chmod 755 "$MANY_AWK_BIN/awk"
for (( i = 1; i <= 505; i++ )); do
  printf -v idx '%03d' "$i"
  : >"$MANY_LOGS/$idx.raw.log"
done
: >"$SETFACL_LOG"
: >"$GETFACL_CALLS"
: >"$SETFACL_CALLS"
: >"$AWK_CALLS"
ACCESS_STATE="$MANY_STATE" TQ_REPO_ROOT="$MANY_REPO" TQ_RAW_LOG_GLOB="$MANY_LOGS/*.raw.log" \
  PATH="$MANY_AWK_BIN:$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER"
assert_line_count "505 paths repaired" "$SETFACL_LOG" 505
assert_line_count "505 paths getfacl calls" "$GETFACL_CALLS" 1
assert_line_count "505 paths awk calls" "$AWK_CALLS" 1
assert_line_count "505 paths setfacl calls" "$SETFACL_CALLS" 1
: >"$GETFACL_CALLS"
: >"$SETFACL_CALLS"
: >"$AWK_CALLS"
ACCESS_STATE="$MANY_STATE" TQ_REPO_ROOT="$MANY_REPO" TQ_RAW_LOG_GLOB="$MANY_LOGS/*.raw.log" \
  PATH="$MANY_AWK_BIN:$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER"
assert_line_count "505 already-OK getfacl calls" "$GETFACL_CALLS" 1
assert_line_count "505 already-OK awk calls" "$AWK_CALLS" 1
assert_line_count "505 already-OK setfacl calls" "$SETFACL_CALLS" 0

# C13: size both batching fixtures from the host's measured ARG_MAX minus env and
# measured per-path encoded byte length, verifying direct-call fit for ASCII and
# ARG_MAX overflow for UTF-8 before running the assertions.
PLATFORM_ARG_MAX="$(getconf ARG_MAX 2>/dev/null || printf '262144')"
PLATFORM_PATH_MAX="$(getconf PATH_MAX "$TEST_ROOT" 2>/dev/null || printf '1024')"
ENV_BYTES="$(env | wc -c | tr -d ' ')"
ENV_LINES="$(env | wc -l | tr -d ' ')"
ENV_OVERHEAD=$((ENV_BYTES + ENV_LINES * 16 + 8192))
AVAIL_ARG_BYTES=$((PLATFORM_ARG_MAX - ENV_OVERHEAD))
if [[ "$AVAIL_ARG_BYTES" -lt 65536 ]]; then
  AVAIL_ARG_BYTES=65536
fi

ASCII_REPO="$TEST_ROOT/ascii-repo"
ASCII_DIR="$ASCII_REPO"
ASCII_SEG="$(printf 'a%.0s' {1..200})"
ASCII_MAX_PATH=$((PLATFORM_PATH_MAX - 150))
[[ "$ASCII_MAX_PATH" -le 1850 ]] || ASCII_MAX_PATH=1850
while [[ $(( ${#ASCII_DIR} + ${#ASCII_SEG} + 32 )) -le "$ASCII_MAX_PATH" ]]; do
  ASCII_DIR="$ASCII_DIR/$ASCII_SEG"
done
ASCII_STATE="$TEST_ROOT/ascii-state"
mkdir -p "$ASCII_DIR" "$ASCII_STATE"
ascii_sample_bytes=$(( $(printf '%s\0' "$ASCII_DIR/0001.raw.log" | wc -c | tr -d ' ') + 16 ))
target_ascii_bytes=$((AVAIL_ARG_BYTES * 60 / 100))
ASCII_COUNT=$((target_ascii_bytes / ascii_sample_bytes))
[[ "$ASCII_COUNT" -ge 2 ]] || ASCII_COUNT=2

printf 'case: large ASCII argument list (%s paths, ~%s bytes) fits in 1 getfacl, 1 awk, 1 setfacl (C3/C13)\n' \
  "$ASCII_COUNT" "$((ASCII_COUNT * ascii_sample_bytes))"
ascii_paths=()
for (( i = 1; i <= ASCII_COUNT; i++ )); do
  printf -v idx '%04d' "$i"
  p="$ASCII_DIR/$idx.raw.log"
  : >"$p"
  ascii_paths+=("$p")
done
# Verify a direct single invocation actually fits on this host before asserting 1 batch.
if ! ACCESS_STATE="$ASCII_STATE" "$FAKE_BIN/getfacl" -cp -- "${ascii_paths[@]}" >/dev/null 2>&1; then
  printf 'FAIL: C13 invariant: direct single getfacl call did not fit for %s ASCII paths\n' "$ASCII_COUNT" >&2
  exit 1
fi
: >"$SETFACL_LOG"
: >"$GETFACL_CALLS"
: >"$SETFACL_CALLS"
: >"$AWK_CALLS"
ACCESS_STATE="$ASCII_STATE" TQ_REPO_ROOT="$ASCII_REPO" TQ_RAW_LOG_GLOB="$ASCII_DIR/*.raw.log" \
  PATH="$MANY_AWK_BIN:$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER"
assert_line_count "large ASCII repaired files" "$SETFACL_LOG" "$ASCII_COUNT"
assert_line_count "large ASCII getfacl calls" "$GETFACL_CALLS" 1
assert_line_count "large ASCII awk calls" "$AWK_CALLS" 1
assert_line_count "large ASCII setfacl calls" "$SETFACL_CALLS" 1

UTF8_REPO="$TEST_ROOT/utf8-repo"
UTF8_DIR="$UTF8_REPO"
UTF8_SEG="$(printf '中%.0s' {1..60})"
UTF8_SEG_BYTES="$(printf '%s' "$UTF8_SEG" | wc -c | tr -d ' ')"
UTF8_MAX_PATH=$((PLATFORM_PATH_MAX - 150))
while [[ $(( $(printf '%s' "$UTF8_DIR" | wc -c | tr -d ' ') + UTF8_SEG_BYTES + 32 )) -le "$UTF8_MAX_PATH" ]]; do
  UTF8_DIR="$UTF8_DIR/$UTF8_SEG"
done
UTF8_STATE="$TEST_ROOT/utf8-state"
mkdir -p "$UTF8_DIR" "$UTF8_STATE"
utf8_sample_bytes="$(printf '%s\0' "$UTF8_DIR/0001.raw.log" | wc -c | tr -d ' ')"
UTF8_COUNT=$(( (PLATFORM_ARG_MAX + 65536) / utf8_sample_bytes + 1 ))

printf 'case: UTF-8 paths (%s paths) exceeding ARG_MAX (%s) in bytes succeed with 1 awk pass (C3/C13)\n' \
  "$UTF8_COUNT" "$PLATFORM_ARG_MAX"
for (( i = 1; i <= UTF8_COUNT; i++ )); do
  printf -v idx '%04d' "$i"
  : >"$UTF8_DIR/$idx.raw.log"
done
utf8_bytes="$(find "$UTF8_DIR" -maxdepth 1 -type f -name '*.raw.log' -print0 | wc -c | tr -d ' ')"
if [[ "$utf8_bytes" -le "$PLATFORM_ARG_MAX" ]]; then
  printf 'FAIL: C13 invariant: UTF-8 fixture (%s bytes) did not exceed ARG_MAX (%s)\n' "$utf8_bytes" "$PLATFORM_ARG_MAX" >&2
  exit 1
fi
: >"$SETFACL_LOG"
: >"$GETFACL_CALLS"
: >"$SETFACL_CALLS"
: >"$AWK_CALLS"
ACCESS_STATE="$UTF8_STATE" TQ_REPO_ROOT="$UTF8_REPO" TQ_RAW_LOG_GLOB="$UTF8_DIR/*.raw.log" \
  PATH="$MANY_AWK_BIN:$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER"
assert_line_count "UTF-8 over ARG_MAX repaired files" "$SETFACL_LOG" "$UTF8_COUNT"
assert_line_count "UTF-8 over ARG_MAX awk calls" "$AWK_CALLS" 1
: >"$SETFACL_CALLS"
ACCESS_STATE="$UTF8_STATE" TQ_REPO_ROOT="$UTF8_REPO" TQ_RAW_LOG_GLOB="$UTF8_DIR/*.raw.log" \
  PATH="$MANY_AWK_BIN:$FAKE_BIN:/usr/bin:/bin" "$ACCESS_HELPER"
assert_line_count "UTF-8 over ARG_MAX already-OK setfacl calls" "$SETFACL_CALLS" 0

printf 'PASS: Linux raw-log ACL repair contract\n'
