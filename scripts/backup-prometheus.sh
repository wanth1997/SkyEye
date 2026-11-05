#!/usr/bin/env bash
# Snapshot the Prometheus TSDB and publish it to S3 as one immutable generation:
#
#   s3://skyeye-prometheus-snapshots/generations/<YYYY-MM-DD>/<snapshot id>/
#
# A generation is complete only once MANIFEST.json, uploaded last, is confirmed
# in S3. scripts/restore-prometheus.sh ignores every prefix without one, and a
# prefix left by a failed run is simply expired by the bucket lifecycle: nothing
# here deletes S3 objects.
#
# Prerequisites:
#   - prometheus container is running with --web.enable-admin-api and
#     --web.enable-remote-write-receiver
#   - EC2 has IAM role permissions to list and write s3://skyeye-prometheus-snapshots
#   - aws CLI, curl, jq, flock, sha256sum and timeout are installed
#
# Installed as cron by scripts/install-prometheus-backup-cron.sh, runs daily at
# 03:00 Asia/Taipei (= 19:00 UTC) as root, straight from the checkout. A deploy
# neither validates this file nor reruns the installer, so it has to work under
# the existing cron line and create everything it needs itself. Runtime state
# stays outside the checkout: central-deploy refuses a dirty tree.
#
# Exit codes, also reported as skyeye_backup_last_exit_code:
#   0 published                 5 S3 listing does not match the local inventory
#   1 unexpected error          6 MANIFEST.json not published or not confirmed
#   2 snapshot request failed   7 total timeout reached
#   3 snapshot unusable         8 host precondition failed
#   4 upload failed            75 another run holds the lock, nothing was touched
#
# The SKYEYE_BACKUP_* variables exist for tests/backup/. Cron sets none of them.

set -euo pipefail
umask 022

BUCKET="${SKYEYE_BACKUP_BUCKET:-skyeye-prometheus-snapshots}"
REGION="${SKYEYE_BACKUP_REGION:-ap-northeast-1}"
PROM_URL="${SKYEYE_BACKUP_PROM_URL:-http://127.0.0.1:9090}"
PROM_CONTAINER="${SKYEYE_BACKUP_CONTAINER:-skyeye-prometheus-1}"
INSTANCE="${SKYEYE_BACKUP_INSTANCE:-monitoring-prod}"
VOL_PATH="${SKYEYE_BACKUP_VOL_PATH:-/var/lib/docker/volumes/skyeye_prometheus_data/_data}"
STATE_DIR="${SKYEYE_BACKUP_STATE_DIR:-/var/lib/skyeye-backup}"
# Uploads took 8-13 s over the last 59 nights; this only bounds a stuck run.
TOTAL_TIMEOUT="${SKYEYE_BACKUP_TOTAL_TIMEOUT:-5400}"

# Bounds on what failed runs may leave behind.
MAX_PENDING=2                                # one spare; tomorrow's run covers it anyway
MAX_PINNED_BYTES=$((3 * 1024 * 1024 * 1024)) # above one full block rewrite (~1.9 GB)
LOW_WATER_PCT=15                             # below this much free disk, keep only the newest
RETRY_DELAYS=(60 300)

EXIT_SNAPSHOT=2
EXIT_INVENTORY=3
EXIT_UPLOAD=4
EXIT_VERIFY=5
EXIT_MANIFEST=6
EXIT_TIMEOUT=7
EXIT_PRECONDITION=8
EXIT_LOCK_BUSY=75

SNAP_ROOT="$VOL_PATH/snapshots"
PENDING_DIR="$STATE_DIR/pending"
METRICS_DIR="$STATE_DIR/metrics"
METRICS_FILE="$METRICS_DIR/skyeye_backup.prom"
STATE_FILE="$STATE_DIR/state"
LOCK_FILE="$STATE_DIR/lock"
SNAPSHOT_ID_REGEX='^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$'

ATTEMPT_TS=0
DEADLINE=$TOTAL_TIMEOUT
LOCK_HELD=0
CHILD_PID=""
WORK_DIR=""
SNAP_ID=""
UNPUBLISHED_ID="" # the snapshot of this run, until its manifest is confirmed
LAST_SUCCESS=""
LAST_UPLOADED_BYTES=0
CONSECUTIVE_FAILURES=0

# GNU on the host; BSD only so tests/backup/ also runs on a Mac.
if stat -c %i / >/dev/null 2>&1; then
  STAT_INODE_SIZE=(-c '%i %s')
else
  STAT_INODE_SIZE=(-f '%i %z')
fi

log() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"
}

fail() {
  local rc="$1"
  shift
  printf '%s ERR: %s\n' "$(date -u +%FT%TZ)" "$*" >&2
  exit "$rc"
}

# Run a command inside the total time budget. The background job plus wait is
# what lets a signal interrupt it: bash defers traps until a foreground child
# ends, which for a stuck upload would be never. The lock fd is closed so a
# survivor cannot keep tomorrow's run locked out.
limited() {
  local cap="$1" left rc=0
  shift
  left=$((DEADLINE - SECONDS))
  [ "$left" -gt 0 ] || return 124
  if [ "$cap" -gt 0 ] && [ "$cap" -lt "$left" ]; then
    left="$cap"
  fi
  timeout -k 30 "$left" "$@" 9>&- &
  CHILD_PID=$!
  wait "$CHILD_PID" || rc=$?
  CHILD_PID=""
  return "$rc"
}

on_signal() {
  if [ -n "$CHILD_PID" ]; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
    CHILD_PID=""
  fi
  exit "$1"
}

atomic_write() { # path, content on stdin
  local tmp
  tmp="$(mktemp "$1.XXXXXX")" || return 1
  if cat >"$tmp" && chmod 0644 "$tmp" && mv "$tmp" "$1"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

load_state() {
  local value
  [ -f "$STATE_FILE" ] || return 0
  value="$(awk -F= '$1 == "last_success" {print $2}' "$STATE_FILE" 2>/dev/null || true)"
  case "$value" in '' | *[!0-9]*) ;; *) LAST_SUCCESS="$value" ;; esac
  value="$(awk -F= '$1 == "last_uploaded_bytes" {print $2}' "$STATE_FILE" 2>/dev/null || true)"
  case "$value" in '' | *[!0-9]*) ;; *) LAST_UPLOADED_BYTES="$value" ;; esac
  value="$(awk -F= '$1 == "consecutive_failures" {print $2}' "$STATE_FILE" 2>/dev/null || true)"
  case "$value" in '' | *[!0-9]*) ;; *) CONSECUTIVE_FAILURES="$value" ;; esac
}

save_state() {
  printf 'last_success=%s\nlast_uploaded_bytes=%s\nconsecutive_failures=%s\n' \
    "$LAST_SUCCESS" "$LAST_UPLOADED_BYTES" "$CONSECUTIVE_FAILURES" | atomic_write "$STATE_FILE"
}

# --- retention ----------------------------------------------------------------

# Everything deletable must pass this: the name is recorded, well formed, and the
# directory is a real child of the real snapshots/ under the volume.
snapshot_dir_is_ours() {
  local id="$1" dir="$SNAP_ROOT/$1"
  [[ "$id" =~ $SNAPSHOT_ID_REGEX ]] || return 1
  [ -d "$SNAP_ROOT" ] && [ ! -L "$SNAP_ROOT" ] || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ "$(cd -P "$dir/.." && pwd -P)" = "$(cd -P "$VOL_PATH" && pwd -P)/snapshots" ]
}

# Recorded generations, oldest first. Snapshot ids sort by creation time.
recorded_ids() {
  local record id
  for record in "$PENDING_DIR"/*.json; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    id="$(basename "$record" .json)"
    [[ "$id" =~ $SNAPSHOT_ID_REGEX ]] || continue
    [ "$(jq -r '.snapshot_id // empty' "$record" 2>/dev/null)" = "$id" ] || continue
    printf '%s\n' "$id"
  done | LC_ALL=C sort
}

delete_generation() {
  local id="$1"
  if ! snapshot_dir_is_ours "$id"; then
    log "WARN: refusing to delete snapshots/$id: not a plain directory under snapshots/"
    return 1
  fi
  log "==> removing local snapshot $id"
  rm -rf -- "${SNAP_ROOT:?}/$id" || return 1
  rm -f -- "$PENDING_DIR/$id.json"
}

# Inode set under snapshots/ minus the inode set of everything else in the volume:
# du cannot tell hardlinks shared with live blocks from bytes only a snapshot holds.
pinned_bytes() {
  [ -d "$SNAP_ROOT" ] || {
    echo 0
    return 0
  }
  awk 'FILENAME == ARGV[1] { live[$1] = 1; next }
       !($1 in live) { total += $2 }
       END { printf "%.0f\n", total + 0 }' \
    <(find "$VOL_PATH" -path "$SNAP_ROOT" -prune -o -type f -exec stat "${STAT_INODE_SIZE[@]}" {} +) \
    <(find "$SNAP_ROOT" -type f -exec stat "${STAT_INODE_SIZE[@]}" {} + | LC_ALL=C sort -u)
}

# A failing df must not read as low disk: that would delete generations.
disk_below_low_water() {
  df -Pk "$VOL_PATH" | awk -v pct="$LOW_WATER_PCT" 'NR == 2 { below = ($4 * 100 < $2 * pct) } END { exit !below }'
}

# Trim recorded generations to the bounds, oldest first. The pending count and low
# water keep the newest one. The pinned limit is a hard cap and keeps none: a lone
# generation over it goes too, or a run that cannot snapshot would hold it forever.
# Only counted, by the metrics: directories without a record. Never touched: the
# snapshot this run has not published. The next run may give that one up.
enforce_retention() {
  local id pinned ids=() remaining
  [ -d "$PENDING_DIR" ] || return 0
  while IFS= read -r id; do
    if [ -e "$SNAP_ROOT/$id" ] || [ -L "$SNAP_ROOT/$id" ]; then
      ids+=("$id")
    else
      rm -f -- "$PENDING_DIR/$id.json"
    fi
  done < <(recorded_ids)
  remaining=${#ids[@]}

  for id in ${ids[@]+"${ids[@]}"}; do
    [ "$id" != "$UNPUBLISHED_ID" ] || continue
    pinned="$(pinned_bytes)" || pinned=0
    if [ "$pinned" -le "$MAX_PINNED_BYTES" ]; then
      [ "$remaining" -gt 1 ] || break
      [ "$remaining" -gt "$MAX_PENDING" ] || disk_below_low_water || break
    fi
    delete_generation "$id" || continue
    remaining=$((remaining - 1))
  done
}

# --- metrics ------------------------------------------------------------------

metric() { # name, help, value
  printf '# HELP %s %s\n# TYPE %s gauge\n%s %s\n' "$1" "$2" "$1" "$1" "$3"
}

render_metrics() {
  local rc="$1" pending pinned
  metric skyeye_backup_last_attempt_timestamp_seconds 'Start of the last run.' "$ATTEMPT_TS"
  # Left out until a run has succeeded. The rules read an attempt without a
  # success series as timestamp 0, and a value invented here after a lost state
  # file would mask the real sample already in the TSDB.
  if [ -n "$LAST_SUCCESS" ]; then
    metric skyeye_backup_last_success_timestamp_seconds 'Last time a generation manifest was confirmed in S3.' "$LAST_SUCCESS"
  fi
  metric skyeye_backup_last_exit_code 'Exit code of the last run.' "$rc"
  metric skyeye_backup_consecutive_failures 'Failed runs since the last success.' "$CONSECUTIVE_FAILURES"
  if [ -d "$VOL_PATH" ]; then
    pending=0
    if [ -d "$SNAP_ROOT" ]; then
      pending="$(find "$SNAP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
    fi
    metric skyeye_backup_pending_generations 'Directories under snapshots/, recorded by this script or not.' "$pending"
    if pinned="$(pinned_bytes)"; then
      metric skyeye_backup_snapshot_pinned_bytes 'Bytes only snapshots keep on disk.' "$pinned"
    fi
  fi
  metric skyeye_backup_last_uploaded_bytes 'Size of the last published generation.' "$LAST_UPLOADED_BYTES"
  metric skyeye_backup_last_duration_seconds 'Duration of the last run.' "$SECONDS"
}

# monitoring-prod has no host exporter, so the sample goes through the remote-write
# receiver with the promtool already in the Prometheus image.
report_metrics() {
  local rc="$1" text
  text="$(render_metrics "$rc")"
  if ! printf '%s\n' "$text" | atomic_write "$METRICS_FILE"; then
    log "WARN: could not write $METRICS_FILE"
  fi
  if ! printf '%s\n' "$text" | timeout -k 5 30 docker exec -i "$PROM_CONTAINER" /bin/promtool push metrics \
    --label=job=skyeye-backup --label="instance=$INSTANCE" \
    http://127.0.0.1:9090/api/v1/write 9>&-; then
    log "WARN: metrics push failed; the backup result does not depend on it"
  fi
}

on_exit() {
  local rc=$?
  trap - EXIT
  trap '' TERM INT HUP
  set +e
  if [ "$LOCK_HELD" -eq 1 ]; then
    enforce_retention || log "WARN: retention did not complete"
  fi
  if [ "$rc" -eq 0 ]; then
    CONSECUTIVE_FAILURES=0
  elif [ "$rc" -ne "$EXIT_LOCK_BUSY" ]; then
    CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
  fi
  if [ "$LOCK_HELD" -eq 1 ]; then
    save_state || log "WARN: could not write $STATE_FILE"
  fi
  report_metrics "$rc"
  [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
  log "==> finished rc=$rc in ${SECONDS}s"
  exit "$rc"
}

# --- backup steps -------------------------------------------------------------

prepare_host() {
  mkdir -p "$PENDING_DIR" "$METRICS_DIR" || fail "$EXIT_PRECONDITION" "cannot create $STATE_DIR"
  exec 9>"$LOCK_FILE" || fail "$EXIT_PRECONDITION" "cannot open $LOCK_FILE"
  command -v flock >/dev/null 2>&1 || fail "$EXIT_PRECONDITION" "flock is not installed"
  if ! flock -n 9; then
    log "another backup holds $LOCK_FILE; leaving everything as it is"
    exit "$EXIT_LOCK_BUSY"
  fi
  LOCK_HELD=1

  local tool
  for tool in aws curl jq sha256sum timeout; do
    command -v "$tool" >/dev/null 2>&1 || fail "$EXIT_PRECONDITION" "$tool is not installed"
  done
  [ -d "$VOL_PATH" ] || fail "$EXIT_PRECONDITION" "$VOL_PATH not found; is prometheus volume named differently?"
  rm -rf -- "$STATE_DIR"/tmp.*
  WORK_DIR="$(mktemp -d "$STATE_DIR/tmp.XXXXXX")" || fail "$EXIT_PRECONDITION" "cannot create a work directory in $STATE_DIR"
}

request_snapshot() {
  local name
  limited 300 curl -fsS --max-time 280 -XPOST "${PROM_URL}/api/v1/admin/tsdb/snapshot" \
    >"$WORK_DIR/snapshot.json" || fail "$EXIT_SNAPSHOT" "snapshot request to $PROM_URL failed (curl exit $?)"
  name="$(jq -r '.data.name // empty' "$WORK_DIR/snapshot.json" 2>/dev/null || true)"
  [ -n "$name" ] || fail "$EXIT_SNAPSHOT" "snapshot API returned no name; is --web.enable-admin-api set?"
  [[ "$name" =~ $SNAPSHOT_ID_REGEX ]] || fail "$EXIT_SNAPSHOT" "snapshot API returned an unexpected name: $name"
  SNAP_ID="$name"
  UNPUBLISHED_ID="$name"
  [ -d "$SNAP_ROOT/$SNAP_ID" ] || fail "$EXIT_INVENTORY" "expected snapshot dir $SNAP_ROOT/$SNAP_ID not found"
  # Record it before the slow hashing below, so a killed run still leaves a
  # snapshot that retention is allowed to reclaim.
  printf '{"schema":1,"snapshot_id":"%s"}\n' "$SNAP_ID" | atomic_write "$PENDING_DIR/$SNAP_ID.json" ||
    fail "$EXIT_INVENTORY" "cannot record $SNAP_ID in $PENDING_DIR"
}

script_commit() {
  local repo
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # root runs this from a checkout owned by ubuntu.
  git -c "safe.directory=$repo" -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown
}

prometheus_image() {
  timeout -k 5 15 docker inspect --format '{{.Config.Image}}' "$PROM_CONTAINER" 2>/dev/null 9>&- || echo unknown
}

# Inventory the snapshot into pending/<id>.json, the body of the future manifest.
build_inventory() {
  local dir="$SNAP_ROOT/$SNAP_ID" block ulid path sum size id="$SNAP_ID"
  : >"$WORK_DIR/blocks.ndjson"
  for block in "$dir"/*/; do
    [ -d "$block" ] || continue
    ulid="$(basename "$block")"
    [ -f "$block/meta.json" ] && [ -f "$block/index" ] && [ -d "$block/chunks" ] ||
      fail "$EXIT_INVENTORY" "snapshot block $ulid lacks meta.json, index or chunks"
    jq -c --arg ulid "$ulid" '{ulid: $ulid, min_time: .minTime, max_time: .maxTime}' "$block/meta.json" \
      >>"$WORK_DIR/blocks.ndjson" || fail "$EXIT_INVENTORY" "cannot read $ulid/meta.json"
  done
  [ -s "$WORK_DIR/blocks.ndjson" ] || fail "$EXIT_INVENTORY" "snapshot $id has no blocks"

  # shellcheck disable=SC2016 # $1 belongs to the inner shell
  limited 0 sh -c 'cd "$1" && find . -type f -exec sha256sum {} +' sh "$dir" \
    >"$WORK_DIR/sums" || fail "$EXIT_INVENTORY" "cannot hash snapshot $id"
  while read -r sum path; do
    path="${path#./}"
    size="$(wc -c <"$dir/$path" | tr -d ' ')" || fail "$EXIT_INVENTORY" "cannot read $path"
    printf '%s\t%s\t%s\n' "$path" "$size" "$sum"
  done <"$WORK_DIR/sums" | LC_ALL=C sort >"$WORK_DIR/files.tsv"

  jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
      | {path: .[0], size: (.[1] | tonumber), sha256: .[2]})' <"$WORK_DIR/files.tsv" >"$WORK_DIR/files.json" ||
    fail "$EXIT_INVENTORY" "cannot build the file list for $id"
  jq -n \
    --arg id "$id" \
    --arg created_at "${id:0:4}-${id:4:2}-${id:6:2}T${id:9:2}:${id:11:2}:${id:13:2}Z" \
    --arg image "$(prometheus_image)" \
    --arg commit "$(script_commit)" \
    --slurpfile blocks "$WORK_DIR/blocks.ndjson" \
    --slurpfile files "$WORK_DIR/files.json" \
    '{schema: 1, snapshot_id: $id, created_at: $created_at, prometheus_image: $image,
      script_commit: $commit, total_bytes: ($files[0] | map(.size) | add),
      blocks: $blocks, files: $files[0]}' \
    | atomic_write "$PENDING_DIR/$id.json" || fail "$EXIT_INVENTORY" "cannot write the inventory of $id"
}

# Normalized object listing of a prefix. The CLI paginates by itself and prints
# nothing at all for an empty result on some versions.
list_prefix() { # prefix, output file
  limited 300 aws s3api list-objects-v2 --region "$REGION" --bucket "$BUCKET" --prefix "$1" \
    --output json >"$WORK_DIR/listing.json" || return 1
  jq -s -c --arg prefix "$1" '[(.[0].Contents // [])[] | {path: (.Key | ltrimstr($prefix)), size: .Size}]
    | sort_by(.path)' <"$WORK_DIR/listing.json" >"$2"
}

publish_once() {
  local prefix="$1" record="$PENDING_DIR/$SNAP_ID.json" manifest="$WORK_DIR/MANIFEST.json"
  local expected actual

  log "==> uploading $SNAP_ROOT/$SNAP_ID -> s3://$BUCKET/$prefix"
  limited 0 aws s3 sync --region "$REGION" --only-show-errors --no-follow-symlinks \
    "$SNAP_ROOT/$SNAP_ID" "s3://$BUCKET/$prefix" || {
    log "WARN: upload failed (aws exit $?)"
    return "$EXIT_UPLOAD"
  }

  list_prefix "$prefix" "$WORK_DIR/uploaded.json" || {
    log "WARN: could not list s3://$BUCKET/$prefix"
    return "$EXIT_VERIFY"
  }
  expected="$(jq -c '[.files[] | {path, size}] | sort_by(.path)' "$record")"
  actual="$(jq -c 'map(select(.path != "MANIFEST.json"))' "$WORK_DIR/uploaded.json")"
  if [ "$expected" != "$actual" ]; then
    log "WARN: s3://$BUCKET/$prefix does not match the snapshot:"
    jq -n -r --argjson want "$expected" --argjson have "$actual" \
      '(($want - $have)[] | "  missing \(.path) (\(.size) bytes)"), (($have - $want)[] | "  unexpected \(.path) (\(.size) bytes)")'
    return "$EXIT_VERIFY"
  fi

  jq --arg completed_at "$(date -u +%FT%TZ)" \
    '{schema, snapshot_id, created_at, completed_at: $completed_at, prometheus_image, script_commit,
      total_bytes, blocks, files}' "$record" >"$manifest" || return "$EXIT_MANIFEST"
  limited 300 aws s3 cp --region "$REGION" --only-show-errors "$manifest" "s3://$BUCKET/${prefix}MANIFEST.json" || {
    log "WARN: manifest upload failed (aws exit $?)"
    return "$EXIT_MANIFEST"
  }
  list_prefix "$prefix" "$WORK_DIR/published.json" || {
    log "WARN: could not confirm the manifest"
    return "$EXIT_MANIFEST"
  }
  if ! jq -e --argjson size "$(wc -c <"$manifest" | tr -d ' ')" \
    'any(.[]; .path == "MANIFEST.json" and .size == $size)' "$WORK_DIR/published.json" >/dev/null; then
    log "WARN: MANIFEST.json is not in S3 with the size just uploaded"
    return "$EXIT_MANIFEST"
  fi
}

publish_generation() {
  local prefix="$1" rc delay retries=0
  while :; do
    rc=0
    publish_once "$prefix" || rc=$?
    [ "$rc" -ne 0 ] || return 0
    [ "$SECONDS" -lt "$DEADLINE" ] || fail "$EXIT_TIMEOUT" "total timeout of ${TOTAL_TIMEOUT}s reached"
    [ "$retries" -lt "${#RETRY_DELAYS[@]}" ] || exit "$rc"
    delay="${RETRY_DELAYS[$retries]}"
    retries=$((retries + 1))
    [ $((SECONDS + delay)) -lt "$DEADLINE" ] || fail "$EXIT_TIMEOUT" "no time left for another attempt"
    log "==> retrying in ${delay}s"
    limited 0 sleep "$delay" || fail "$EXIT_TIMEOUT" "interrupted while waiting to retry"
  done
}

# The new generation covers every older local snapshot.
remove_covered_generations() {
  local id
  while IFS= read -r id; do
    if [[ ! "$id" > "$SNAP_ID" ]]; then
      delete_generation "$id" || log "WARN: could not remove local snapshot $id"
    fi
  done < <(recorded_ids)
}

main() {
  ATTEMPT_TS="$(date +%s)"
  trap on_exit EXIT
  trap 'on_signal 143' TERM
  trap 'on_signal 130' INT
  trap 'on_signal 129' HUP
  load_state
  prepare_host

  request_snapshot
  build_inventory

  local prefix="generations/${SNAP_ID:0:4}-${SNAP_ID:4:2}-${SNAP_ID:6:2}/$SNAP_ID/"
  publish_generation "$prefix"
  UNPUBLISHED_ID=""

  LAST_SUCCESS="$(date +%s)"
  LAST_UPLOADED_BYTES="$(jq -r '.total_bytes' "$PENDING_DIR/$SNAP_ID.json")"
  remove_covered_generations
  log "==> backup OK: $prefix, $LAST_UPLOADED_BYTES bytes"
}

main "$@"
