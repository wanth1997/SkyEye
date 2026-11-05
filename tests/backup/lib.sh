# shellcheck shell=bash disable=SC2034 # the sourced cases use these variables
# Sandbox and assertion helpers for tests/backup/. Sourced by run-tests.sh.
#
# Bash 3.2 compatible: the suite has to run under /bin/bash on a Mac and on Linux.

T0=1793559600 # 2026-11-01T19:00:00Z, the cron minute
DAY=86400

CHECKS=0
CASE_FAILS=0
IMPL=new

# --- assertions ---------------------------------------------------------------

check() { # description, command...
  local description="$1"
  shift
  CHECKS=$((CHECKS + 1))
  if ! "$@"; then
    CASE_FAILS=$((CASE_FAILS + 1))
    printf '    not ok: %s\n' "$description"
  fi
}

check_eq() { # description, expected, actual
  CHECKS=$((CHECKS + 1))
  if [ "$2" != "$3" ]; then
    CASE_FAILS=$((CASE_FAILS + 1))
    printf '    not ok: %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
  fi
}

check_not() { # description, command...
  local description="$1"
  shift
  CHECKS=$((CHECKS + 1))
  if "$@"; then
    CASE_FAILS=$((CASE_FAILS + 1))
    printf '    not ok: %s\n' "$description"
  fi
}

logged() { # file, extended regex
  [ -f "$1" ] && grep -Eq -- "$2" "$1"
}

# --- sandbox ------------------------------------------------------------------

new_sandbox() { # name
  SB="$TEST_ROOT/sandbox/$1-$IMPL"
  VOL="$SB/volume/_data"
  STATE="$SB/state"
  LOGDIR="$SB/log"
  RUNLOG="$LOGDIR/run.log"
  BUCKET_DIR="$SB/s3/skyeye-prometheus-snapshots"
  mkdir -p "$VOL/snapshots" "$BUCKET_DIR" "$LOGDIR" "$SB/home" "$SB/tmp" "$SB/restore"
  : >"$RUNLOG"
}

# Runs a command with an empty environment and a PATH that resolves aws, curl and
# docker to the fakes. VAR=val ... -- command...  SBX_PATH replaces that PATH.
# SBX_EXEC=exec, for a background job, makes $! the command and not a subshell.
sbx() {
  local envs=()
  while [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  ${SBX_EXEC:-} env -i PATH="${SBX_PATH:-$SHIM_DIR:$TOOLS_DIR:/usr/bin:/bin}" HOME="$SB/home" LANG=C TMPDIR="$SB/tmp" \
    SANDBOX="$SB" REAL_STAT="$REAL_STAT" \
    AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true \
    FAKE_VOL="$VOL" FAKE_S3="$SB/s3" FAKE_LOG="$LOGDIR" \
    SKYEYE_BACKUP_VOL_PATH="$VOL" SKYEYE_BACKUP_STATE_DIR="$STATE" \
    SKYEYE_RESTORE_ROOT="$SB/restore" SKYEYE_RESTORE_VOLUME_DIR="$SB/volume" \
    SKYEYE_RESTORE_BACKUP_LOCK="$STATE/lock" SKYEYE_RESTORE_READY_TIMEOUT=2 \
    SKYEYE_RESTORE_COMPOSE_FILE="$SB/docker-compose.yml" \
    ${envs[@]+"${envs[@]}"} "$@"
}

under_test() {
  if [ "$IMPL" = legacy ]; then
    printf '%s\n' "$LEGACY_BACKUP"
  else
    printf '%s\n' "$NEW_BACKUP"
  fi
}

run_backup() { # now, VAR=val...   sets RC
  local now="$1"
  shift
  sbx FAKE_NOW="$now" "$@" -- timeout 30 /bin/bash "$(under_test)" >>"$RUNLOG" 2>&1
  RC=$?
}

# run_restore VAR=val ... -- args...   sets RC and OUT (a file with stdout and stderr)
run_restore() {
  local envs=()
  while [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  OUT="$LOGDIR/restore.out"
  sbx FAKE_NOW="${NOW:-$T0}" ${envs[@]+"${envs[@]}"} -- timeout 30 /bin/bash "$RESTORE" "$@" >"$OUT" 2>&1
  RC=$?
  sed 's/^/    | /' "$OUT"
}

# --- TSDB fixture -------------------------------------------------------------

mk_block() { # ulid sizeKB [maxTime]
  local b="$VOL/$1" max="${3:-1790000000000}"
  mkdir -p "$b/chunks"
  dd if=/dev/urandom of="$b/chunks/000001" bs=1024 count="$2" 2>/dev/null
  dd if=/dev/urandom of="$b/index" bs=1024 count=16 2>/dev/null
  printf '{"ulid":"%s","minTime":%s,"maxTime":%s,"stats":{"numSamples":1000}}\n' "$1" "$((max - 7200000))" "$max" >"$b/meta.json"
  : >"$b/tombstones"
}

BLOCK_A=01AAAAAAAAAAAAAAAAAAAAAAAA
BLOCK_B=01BBBBBBBBBBBBBBBBBBBBBBBB
BLOCK_C=01CCCCCCCCCCCCCCCCCCCCCCCC
BLOCK_D=01DDDDDDDDDDDDDDDDDDDDDDDD
BLOCK_E=01EEEEEEEEEEEEEEEEEEEEEEEE
BLOCK_F=01FFFFFFFFFFFFFFFFFFFFFFFF

seed_live() {
  mk_block "$BLOCK_A" 256
  mk_block "$BLOCK_B" 256
  mk_block "$BLOCK_C" 64
  mk_block "$BLOCK_D" 64
  echo not-in-any-snapshot >"$VOL/live.marker"
  mkdir -p "$VOL/wal"
  echo wal >"$VOL/wal/00000001"
}

# Live TSDB moves on: retention drops the oldest block, compaction merges two young
# ones into a new one.
tsdb_day() { # dropped, mergeA, mergeB, new, sizeKB
  rm -rf "${VOL:?}/$1" "${VOL:?}/$2" "${VOL:?}/$3"
  mk_block "$4" "$5"
}

record_pending() { # id: a generation as an earlier failed run left it
  mkdir -p "$STATE/pending" "$VOL/snapshots/$1/$BLOCK_A/chunks"
  printf '{"schema":1,"snapshot_id":"%s"}\n' "$1" >"$STATE/pending/$1.json"
  printf 'x' >"$VOL/snapshots/$1/$BLOCK_A/index"
}

snapcount() {
  find "$VOL/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

pending_records() {
  find "$STATE/pending" -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

# Bytes only snapshots keep, computed apart from the script's own metric.
pinned_bytes() {
  local live="$LOGDIR/live.inodes" snap="$LOGDIR/snap.inodes"
  (cd "$VOL" && find . -path ./snapshots -prune -o -type f -print) >"$LOGDIR/live.files"
  : >"$live"
  while IFS= read -r f; do inode_size "$VOL/$f" >>"$live"; done <"$LOGDIR/live.files"
  find "$VOL/snapshots" -type f >"$LOGDIR/snap.files"
  : >"$snap"
  while IFS= read -r f; do inode_size "$f" >>"$snap"; done <"$LOGDIR/snap.files"
  sort -u "$snap" | awk -v live="$live" 'BEGIN { while ((getline line < live) > 0) { split(line, a, " "); l[a[1]] = 1 } }
    !($1 in l) { s += $2 } END { printf "%.0f\n", s + 0 }'
}

live_hash() {
  (cd "$VOL" && find . -path ./snapshots -prune -o -type f -print | LC_ALL=C sort |
    while IFS= read -r f; do sha256sum "$f"; done | sha256sum | cut -d' ' -f1)
}

bucket_hash() {
  (cd "$SB/s3" && find . -type f | LC_ALL=C sort |
    while IFS= read -r f; do sha256sum "$f"; done | sha256sum | cut -d' ' -f1)
}

manifests() {
  find "$BUCKET_DIR" -name MANIFEST.json | LC_ALL=C sort
}

manifest_count() {
  manifests | wc -l | tr -d ' '
}

latest_generation() { # id of the newest manifest
  basename "$(dirname "$(manifests | tail -1)")"
}

generation_dir() { # id
  dirname "$(find "$BUCKET_DIR" -path "*/$1/MANIFEST.json")"
}

# Prefixes the tooling of the implementation under test presents as restorable.
complete_prefixes() {
  if [ "$IMPL" = legacy ]; then
    find "$BUCKET_DIR" -mindepth 1 -maxdepth 1 -type d
  else
    manifests | while IFS= read -r m; do dirname "$m"; done
  fi
}

every_block_intact() { # prefix
  local block ok=0
  for block in "$1"/*/; do
    [ -d "$block" ] || continue
    if [ ! -f "$block/meta.json" ] || [ ! -f "$block/index" ] || [ ! -f "$block/chunks/000001" ]; then
      printf '    %s is incomplete\n' "$block"
      ok=1
    fi
  done
  return "$ok"
}

metric_value() { # name
  awk -v name="$1" '$1 == name { print $2 }' "$STATE/metrics/skyeye_backup.prom" 2>/dev/null
}

wait_for_log() { # file, regex
  local tries=0
  while [ "$tries" -lt 100 ]; do
    logged "$1" "$2" && return 0
    tries=$((tries + 1))
    /bin/sleep 0.1
  done
  return 1
}

# The legacy restore steps, with only the volume path and prefix swapped.
legacy_restore_script() { # date
  sed -e "s|/var/lib/docker/volumes/skyeye_prometheus_data/_data|$VOL|g" \
    -e "s|^SNAP=.*|SNAP=$1|" "$LEGACY_DIR/restore-steps.sh" >"$LOGDIR/restore-steps.sh"
  if grep -q '/var/lib/docker' "$LOGDIR/restore-steps.sh"; then
    echo "ABORT: real path left in the legacy restore steps" >&2
    exit 99
  fi
  printf '%s\n' "$LOGDIR/restore-steps.sh"
}
