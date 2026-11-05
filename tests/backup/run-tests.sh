#!/bin/bash
# Entry point: /bin/bash tests/backup/run-tests.sh
#
# central-deploy does not validate scripts/backup-prometheus.sh, and cron runs it as
# root the night after any deploy, so this suite is its only gate. No real aws, curl
# or docker is reachable from a case: see the checks before the first case.
#
# A missing tool is a failure, never a skip. BACKUP_TEST_KEEP=1 keeps the sandboxes.
# BACKUP_RULES_FILE compares the metrics with another rule file. BACKUP_TEST_ONLY=regex
# runs only matching cases while developing, and then the run never ends in PASS.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NEW_BACKUP="$REPO_ROOT/scripts/backup-prometheus.sh"
RESTORE="$REPO_ROOT/scripts/restore-prometheus.sh"
LEGACY_DIR="$SCRIPT_DIR/fixtures/legacy"
SHIM_DIR="$SCRIPT_DIR/shim"

preflight_failed=0
for tool in awk comm cp cut dd diff find grep head jq ln mktemp sed sha256sum sort stat tail timeout tr uniq wc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FAIL: %s is required; this suite must not pass by skipping\n' "$tool" >&2
    preflight_failed=1
  fi
done
if ! command -v flock >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  printf 'FAIL: flock, or python3 to stand in for it, is required\n' >&2
  preflight_failed=1
fi
[ "$preflight_failed" -eq 0 ] || exit 1

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-backup-tests.XXXXXX")"
cleanup() {
  if [ -n "${BACKUP_TEST_KEEP:-}" ]; then
    printf 'kept: %s\n' "$TEST_ROOT"
  else
    rm -rf "${TEST_ROOT:?}"
  fi
}
trap cleanup EXIT

# Tools the fakes do not replace, wherever this host keeps them. Linking them here
# keeps /usr/local/bin and friends, where a real aws could live, off the PATH.
TOOLS_DIR="$TEST_ROOT/tools"
mkdir -p "$TOOLS_DIR"
for tool in jq sha256sum timeout git; do
  path="$(command -v "$tool" || true)"
  [ -z "$path" ] || ln -s "$path" "$TOOLS_DIR/$tool"
done
if command -v flock >/dev/null 2>&1; then
  ln -s "$(command -v flock)" "$TOOLS_DIR/flock"
else
  ln -s "$(command -v python3)" "$TOOLS_DIR/python3"
  ln -s "$SHIM_DIR/flock.py" "$TOOLS_DIR/flock"
fi
REAL_STAT="$(command -v stat)"

inode_size() {
  if "$REAL_STAT" -c '%i %s' "$1" 2>/dev/null; then
    return 0
  fi
  "$REAL_STAT" -f '%i %z' "$1"
}

LEGACY_BACKUP="$TEST_ROOT/legacy-backup-prometheus.sh"
# shellcheck disable=SC2016 # the variable is for the legacy script to expand
sed 's|^VOL_PATH=.*|VOL_PATH="${SKYEYE_BACKUP_VOL_PATH:?}"|' "$LEGACY_DIR/backup-prometheus.sh" >"$LEGACY_BACKUP"
if [ "$(diff "$LEGACY_DIR/backup-prometheus.sh" "$LEGACY_BACKUP" | grep -c '^[<>]')" != 2 ]; then
  printf 'FAIL: the legacy script must differ by the volume path line alone\n' >&2
  exit 1
fi

RULES_FILE="${BACKUP_RULES_FILE:-$REPO_ROOT/prometheus/rules/backup.yml}"
if [ ! -f "$RULES_FILE" ]; then
  # Until PR-1 reaches this branch, its rule file lives on its own branch.
  RULES_FILE="$TEST_ROOT/backup.yml"
  if ! git -C "$REPO_ROOT" show feat/backup-docs-rules:prometheus/rules/backup.yml >"$RULES_FILE" 2>/dev/null; then
    printf 'FAIL: no backup rule file to compare the metrics with\n' >&2
    exit 1
  fi
fi

# shellcheck source=tests/backup/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=tests/backup/cases-legacy-failures.sh
. "$SCRIPT_DIR/cases-legacy-failures.sh"
# shellcheck source=tests/backup/cases-backup.sh
. "$SCRIPT_DIR/cases-backup.sh"
# shellcheck source=tests/backup/cases-restore.sh
. "$SCRIPT_DIR/cases-restore.sh"

# The fakes have to win, or a case could reach AWS, Docker or the network.
new_sandbox preflight
for tool in aws curl docker sudo; do
  resolved="$(sbx -- /bin/bash -c "command -v $tool")"
  if [ "$resolved" != "$SHIM_DIR/$tool" ]; then
    printf 'FAIL: %s resolves to %s, not the fake\n' "$tool" "$resolved" >&2
    exit 1
  fi
done

CASES=0
FAILED=0
WITNESSES=0
OUT_DIR="$TEST_ROOT/out"
mkdir -p "$OUT_DIR"

# One case in a subshell. Exit 0: every check passed. 1: a check failed. 2: it
# checked nothing, which is a broken case and never a pass.
run_impl() { # function, implementation
  (
    IMPL="$2"
    new_sandbox "$1"
    "$1"
    printf '    checks=%s failed=%s\n' "$CHECKS" "$CASE_FAILS"
    if [ "$CHECKS" -eq 0 ]; then
      exit 2
    fi
    [ "$CASE_FAILS" -eq 0 ]
  ) >"$OUT_DIR/$1-$2.log" 2>&1
}

selected() {
  [ -z "${BACKUP_TEST_ONLY:-}" ] || printf '%s\n' "$1" | grep -Eq "$BACKUP_TEST_ONLY"
}

case_new() { # function
  selected "$1" || return 0
  CASES=$((CASES + 1))
  if run_impl "$1" new; then
    printf 'ok    %s\n' "$1"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %s\n' "$1"
    cat "$OUT_DIR/$1-new.log"
  fi
}

# Has to fail on the base commit's script and pass on the new one.
case_both() { # function
  local legacy_rc=0 failed_checks
  selected "$1" || return 0
  CASES=$((CASES + 1))
  run_impl "$1" legacy || legacy_rc=$?
  if [ "$legacy_rc" -ne 1 ]; then
    FAILED=$((FAILED + 1))
    printf 'FAIL  %s: did not fail on the old script (rc=%s), so it proves nothing\n' "$1" "$legacy_rc"
    cat "$OUT_DIR/$1-legacy.log"
    return
  fi
  WITNESSES=$((WITNESSES + 1))
  failed_checks="$(grep -c 'not ok:' "$OUT_DIR/$1-legacy.log")"
  if run_impl "$1" new; then
    printf 'ok    %s (old script: %s failed checks, new script: all pass)\n' "$1" "$failed_checks"
    grep 'not ok:' "$OUT_DIR/$1-legacy.log" | sed 's/^ */        old: /'
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %s\n' "$1"
    cat "$OUT_DIR/$1-new.log"
  fi
}

printf '== plan section 4 scenarios, old script against new\n'
for fn in s1_failed_runs_leave_nothing_behind s2_partial_upload_is_distinguishable \
  s3a_same_day_reruns_stay_separate s3b_rerun_cannot_bless_a_dead_block \
  s4a_failed_download_leaves_live_data_alone s4b_partial_prefix_is_refused \
  s5a_failed_listing_does_not_cost_the_snapshot s5b_prometheus_down_is_visible \
  s5c_admin_api_refusal_is_visible gap_overlapping_runs_do_not_snapshot_twice \
  gap_stuck_upload_ends; do
  case_both "$fn"
done

printf '== backup-prometheus.sh\n'
for fn in $(declare -F | awk '{print $3}' | grep '^b_'); do
  case_new "$fn"
done

printf '== restore-prometheus.sh\n'
for fn in $(declare -F | awk '{print $3}' | grep '^r_'); do
  case_new "$fn"
done

printf '== the suite itself\n'

# Every aws call of every sandbox above, new script and restore tool alike.
suite_never_deletes_from_s3() {
  check_not "no case made a call the fake refuses" \
    sh -c "cat '$TEST_ROOT'/sandbox/*-new/log/aws-forbidden.log 2>/dev/null | grep ."
  check_not "no delete in any call" \
    sh -c "cat '$TEST_ROOT'/sandbox/*-new/log/aws-calls.log | grep -E 's3 (rm|mv|rb) |s3api delete|--delete'"
  check_eq "the verbs are the expected ones" \
    's3 cp;s3 sync;s3api list-objects-v2;' \
    "$(cat "$TEST_ROOT"/sandbox/*-new/log/aws-calls.log | awk '{print $3, $4}' | sort -u | tr '\n' ';')"
  check_not "no delete in the scripts" grep -nE 'aws[^|]* (s3 (rm|mv|rb)|s3api delete)|--delete|delete-object' "$NEW_BACKUP" "$RESTORE"
}

suite_fails_without_a_tool() {
  local bin="$SB/bin" tool out="$LOGDIR/no-jq.out"
  mkdir -p "$bin"
  for tool in awk comm cp cut dd diff dirname find grep head ln mktemp sed sha256sum sort stat tail timeout tr uniq wc; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done
  env -i PATH="$bin" /bin/bash "$SCRIPT_DIR/run-tests.sh" >"$out" 2>&1
  check "no jq fails the suite" [ "$?" -ne 0 ]
  check "and says why" logged "$out" 'FAIL: jq is required'
  check_not "without any case passing" logged "$out" '^ok '
}

case_new suite_never_deletes_from_s3
case_new suite_fails_without_a_tool

printf '\n%s cases, %s of them failing on the old script first, %s failed\n' "$CASES" "$WITNESSES" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
  printf 'FAIL\n'
  exit 1
fi
if [ -n "${BACKUP_TEST_ONLY:-}" ]; then
  printf 'PARTIAL RUN, not a pass: BACKUP_TEST_ONLY is set\n'
  exit 0
fi
printf 'PASS\n'
