#!/usr/bin/env bash
# Restore the Prometheus TSDB from a generation published by backup-prometheus.sh.
# Run as root on monitoring-prod. Nothing here runs by itself, and only switch,
# rollback and finalize touch live data. Run with --help for the commands.
#
# Exit codes:
#   0 done                      6 download failed
#   2 refused, nothing touched  7 verification failed
#   3 generation not found or   8 could not stop or swap, Prometheus left as it was
#     it has no MANIFEST.json   9 health check failed, rolled back to the previous data
#   4 MANIFEST.json invalid    10 rollback failed, a human has to look now
#   5 not enough disk space
#
# The SKYEYE_RESTORE_* variables exist for tests/backup/ and the restore drill.

set -euo pipefail
umask 022

BUCKET="${SKYEYE_RESTORE_BUCKET:-skyeye-prometheus-snapshots}"
REGION="${SKYEYE_RESTORE_REGION:-ap-northeast-1}"
PROM_URL="${SKYEYE_RESTORE_PROM_URL:-http://127.0.0.1:9090}"
RESTORE_ROOT="${SKYEYE_RESTORE_ROOT:-/var/lib/skyeye-restore}"
VOLUME_DIR="${SKYEYE_RESTORE_VOLUME_DIR:-/var/lib/docker/volumes/skyeye_prometheus_data}"
COMPOSE_FILE="${SKYEYE_RESTORE_COMPOSE_FILE:-/home/ubuntu/SkyEye/docker-compose.yml}"
COMPOSE_PROJECT="${SKYEYE_RESTORE_COMPOSE_PROJECT:-skyeye}"
PROM_IMAGE="${SKYEYE_RESTORE_IMAGE:-prom/prometheus:v2.54.1}"
BACKUP_LOCK="${SKYEYE_RESTORE_BACKUP_LOCK:-/var/lib/skyeye-backup/lock}"
READY_TIMEOUT="${SKYEYE_RESTORE_READY_TIMEOUT:-300}"
FETCH_TIMEOUT="${SKYEYE_RESTORE_FETCH_TIMEOUT:-7200}"

COMPOSE_SERVICE=prometheus
PROM_UID_GID=65534:65534
RETENTION_MS=$((30 * 24 * 3600 * 1000)) # --storage.tsdb.retention.time in docker-compose.yml
MIN_KEEP_SECONDS=86400
GAP_MS=3600000 # blocks further apart than this may be an outage or a block that never arrived
GAUGE_TRIES=24
GAUGE_DELAY=5

EXIT_REFUSED=2
EXIT_NOT_FOUND=3
EXIT_BAD_MANIFEST=4
EXIT_NO_SPACE=5
EXIT_DOWNLOAD=6
EXIT_VERIFY=7
EXIT_SWITCH=8
EXIT_ROLLED_BACK=9
EXIT_ROLLBACK_FAILED=10

GENERATION_ID_REGEX='^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$'
ULID_REGEX='^[0-9A-HJKMNP-TV-Z]{26}$'
LEGACY_PREFIX_REGEX='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
PARKED_NAME_REGEX='^_data\.pre-restore-[0-9]{8}T[0-9]{6}Z$'

LIVE_DIR="$VOLUME_DIR/_data"
SWITCH_STATE="$RESTORE_ROOT/switch.state"

TARGET=""  # generation id, or legacy-<date> for the staging directory of an old prefix
LEGACY=0
S3_PREFIX=""
STAGE=""
ASSUME_YES=0
FRESH=0
ACCEPT_GAPS=0
TMP_FILES=()
MID_SWITCH=0

# GNU on the host; BSD only so tests/backup/ also runs on a Mac.
if stat -c %d / >/dev/null 2>&1; then
  STAT_DEVICE=(-c %d)
else
  STAT_DEVICE=(-f %d)
fi

usage() {
  cat <<'EOF'
Usage: restore-prometheus.sh <command>

  list                        Generations with a MANIFEST.json whose objects are all in S3.
  fetch <id>                  Download to /var/lib/skyeye-restore/<id>/data. Needs free
                              disk of twice the generation plus 1 GiB.
  verify <id> [--accept-gaps] Check every file against the manifest and every block for its
                              files, print the timeline, then read every sample with promtool.
                              Takes hours on a full generation: run it in tmux. Prometheus keeps
                              running; the read uses one CPU and no extra disk. A gap of over
                              an hour stops it after all blocks were read. --accept-gaps is for
                              a gap known to be a real outage. It never skips the read.
  switch <id> --yes [--fresh] Stop Prometheus, rename _data to _data.pre-restore-<time>, move
                              the verified data in, start, and check /-/ready and
                              prometheus_tsdb_blocks_loaded. A failed check rolls back by itself.
  rollback                    Undo the last switch.
  finalize --yes              Delete _data.pre-restore-<time>, at least 24 hours after the switch.

fetch, verify and switch also take --legacy-prefix YYYY-MM-DD instead of <id>, for the
date prefixes written before generations existed. Those have no completeness guarantee:
nothing recorded what a full upload contained, so a partial block that passes the
per-block checks cannot be told from a good one.

--fresh is for a rebuilt host where _data is missing or empty, so there is nothing to keep.

verify counts dumped samples against stats.numSamples of each block, because promtool exits 0
with no error on a block it could not read to the end. Native histograms print fewer lines
than they have samples, which would reject a good generation. They are not enabled here; if
they ever are, this check has to change.

What a restore means:
  - Snapshots hold no WAL. Whatever arrived after the backup is not in the restored data;
    rollback is the way back to it, and it drops what arrived after the switch instead.
  - Blocks past the 30d retention are deleted after startup, more of them the older the generation.
  - Ids and S3 dates are UTC: the 03:00 Taipei backup of 11-02 sits under 2026-11-01.
  - Restoring a backup from before 2026-11-02 brings back the purged tnauqquant-prod-1 series.

Delete a staging directory by hand once done with it: rm -rf /var/lib/skyeye-restore/<id>
EOF
}

log() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"
}

die() {
  local rc="$1"
  shift
  printf 'ERR: %s\n' "$*" >&2
  exit "$rc"
}

legacy_warning() {
  [ "$LEGACY" -eq 1 ] || return 0
  printf 'WARN: legacy prefix %s has no completeness guarantee: no manifest says what a full upload held.\n' "$S3_PREFIX" >&2
}

tmp_file() { # variable name
  local path
  path="$(mktemp "${TMPDIR:-/tmp}/skyeye-restore.XXXXXX")"
  TMP_FILES+=("$path")
  printf -v "$1" '%s' "$path"
}

device_of() {
  stat "${STAT_DEVICE[@]}" "$1"
}

state_get() {
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$SWITCH_STATE"
}

state_write() { # id parked fresh phase switched_at
  local tmp="$SWITCH_STATE.tmp"
  printf 'id=%s\nparked=%s\nfresh=%s\nphase=%s\nswitched_at=%s\n' "$1" "$2" "$3" "$4" "$5" >"$tmp"
  mv "$tmp" "$SWITCH_STATE"
}

parse_target() {
  local legacy_prefix=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --legacy-prefix)
        [ $# -ge 2 ] || die "$EXIT_REFUSED" "--legacy-prefix needs YYYY-MM-DD"
        legacy_prefix="$2"
        shift 2
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --fresh)
        FRESH=1
        shift
        ;;
      --accept-gaps)
        ACCEPT_GAPS=1
        shift
        ;;
      -*) die "$EXIT_REFUSED" "unknown option: $1" ;;
      *)
        [ -z "$TARGET" ] || die "$EXIT_REFUSED" "more than one generation given"
        TARGET="$1"
        shift
        ;;
    esac
  done
  if [ -n "$legacy_prefix" ]; then
    [ -z "$TARGET" ] || die "$EXIT_REFUSED" "give a generation id or --legacy-prefix, not both"
    [[ "$legacy_prefix" =~ $LEGACY_PREFIX_REGEX ]] || die "$EXIT_REFUSED" "--legacy-prefix must be YYYY-MM-DD"
    LEGACY=1
    TARGET="legacy-$legacy_prefix"
    S3_PREFIX="$legacy_prefix/"
  else
    [ -n "$TARGET" ] || die "$EXIT_REFUSED" "missing generation id; see list"
    [[ "$TARGET" =~ $GENERATION_ID_REGEX ]] || die "$EXIT_REFUSED" "not a generation id: $TARGET"
    S3_PREFIX="generations/${TARGET:0:4}-${TARGET:4:2}-${TARGET:6:2}/$TARGET/"
  fi
  STAGE="$RESTORE_ROOT/$TARGET"
}

s3_objects() { # prefix, output file: [{Key, Size}]
  local raw
  tmp_file raw
  aws s3api list-objects-v2 --region "$REGION" --bucket "$BUCKET" --prefix "$1" --output json >"$raw" || return 1
  jq -s -c '[(.[0].Contents // [])[] | {Key, Size}]' <"$raw" >"$2"
}

manifest_is_valid() { # file, id
  jq -e --arg id "$2" '
    .schema == 1 and .snapshot_id == $id
    and (.total_bytes | type) == "number"
    and (.blocks | type) == "array" and (.blocks | length) > 0
    and (.files | type) == "array" and (.files | length) > 0
    and all(.blocks[]; (.ulid | type) == "string" and (.ulid | test("^[0-9A-HJKMNP-TV-Z]{26}$"))
                       and (.max_time | type) == "number")
    and all(.files[]; (.path | type) == "string"
                      and (.path | test("^[0-9A-Za-z_.-]+(/[0-9A-Za-z_.-]+)*$"))
                      and ((.path | split("/") | any(. == ".." or . == ".")) | not)
                      and (.size | type) == "number"
                      and (.sha256 | type) == "string" and (.sha256 | test("^[0-9a-f]{64}$")))
  ' "$1" >/dev/null 2>&1
}

# --- list ---------------------------------------------------------------------

cmd_list() {
  local objects keys key id prefix manifest missing found=0
  tmp_file objects
  tmp_file keys
  tmp_file manifest
  s3_objects generations/ "$objects" || die "$EXIT_DOWNLOAD" "cannot list s3://$BUCKET/generations/"
  jq -r '.[].Key | select(test("^generations/[0-9]{4}-[0-9]{2}-[0-9]{2}/[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}/MANIFEST\\.json$"))' \
    "$objects" | LC_ALL=C sort >"$keys"

  printf '%-36s %-21s %14s %7s\n' GENERATION CREATED BYTES BLOCKS
  while IFS= read -r key; do
    prefix="${key%MANIFEST.json}"
    id="$(basename "$prefix")"
    if ! aws s3 cp --region "$REGION" --only-show-errors "s3://$BUCKET/$key" "$manifest" || ! manifest_is_valid "$manifest" "$id"; then
      printf 'WARN: %s not listed: MANIFEST.json is unreadable or invalid\n' "$id" >&2
      continue
    fi
    # S3 may have expired part of it: the manifest alone does not make it complete.
    missing="$(jq -r --arg prefix "$prefix" --slurpfile objects "$objects" '
      ($objects[0] | map({key: .Key, value: .Size}) | from_entries) as $have
      | [.files[] | select($have[$prefix + .path] != .size)] | length' "$manifest")"
    if [ "$missing" != 0 ]; then
      printf 'WARN: %s not listed: %s objects missing or of the wrong size\n' "$id" "$missing" >&2
      continue
    fi
    jq -r '[.snapshot_id, .created_at, .total_bytes, (.blocks | length)] | @tsv' "$manifest" |
      awk -F'\t' '{ printf "%-36s %-21s %14s %7s\n", $1, $2, $3, $4 }'
    found=$((found + 1))
  done <"$keys"
  [ "$found" -gt 0 ] || printf 'no complete generation in s3://%s/generations/\n' "$BUCKET" >&2
}

# --- fetch --------------------------------------------------------------------

check_same_filesystem() {
  local anchor="$VOLUME_DIR"
  [ -e "$anchor" ] || anchor="$(dirname "$VOLUME_DIR")"
  [ "$(device_of "$RESTORE_ROOT")" = "$(device_of "$anchor")" ] ||
    die "$EXIT_REFUSED" "$RESTORE_ROOT is not on the filesystem of $VOLUME_DIR; switch must be a rename, not a copy"
}

check_free_space() { # bytes of the generation
  local total="$1" need avail
  need=$((total * 2 + 1024 * 1024 * 1024))
  avail="$(df -Pk "$RESTORE_ROOT" | awk 'NR == 2 { printf "%.0f", $4 * 1024 }')"
  [ -n "$avail" ] || die "$EXIT_NO_SPACE" "cannot read free space of $RESTORE_ROOT"
  [ "$avail" -ge "$need" ] || die "$EXIT_NO_SPACE" "need $need bytes free in $RESTORE_ROOT, have $avail"
}

cmd_fetch() {
  parse_target "$@"
  mkdir -p "$RESTORE_ROOT"
  check_same_filesystem
  legacy_warning

  local total objects manifest
  tmp_file manifest
  if [ "$LEGACY" -eq 1 ]; then
    tmp_file objects
    s3_objects "$S3_PREFIX" "$objects" || die "$EXIT_DOWNLOAD" "cannot list s3://$BUCKET/$S3_PREFIX"
    total="$(jq 'map(.Size) | add // 0' "$objects")"
    [ "$total" -gt 0 ] || die "$EXIT_NOT_FOUND" "s3://$BUCKET/$S3_PREFIX is empty"
  else
    aws s3 cp --region "$REGION" --only-show-errors "s3://$BUCKET/${S3_PREFIX}MANIFEST.json" "$manifest" ||
      die "$EXIT_NOT_FOUND" "s3://$BUCKET/$S3_PREFIX has no MANIFEST.json: not found, or not a complete generation"
    manifest_is_valid "$manifest" "$TARGET" || die "$EXIT_BAD_MANIFEST" "MANIFEST.json of $TARGET is invalid"
    total="$(jq '.total_bytes' "$manifest")"
  fi
  check_free_space "$total"

  rm -rf -- "${STAGE:?}/data" "$STAGE/VERIFIED" "$STAGE/MANIFEST.json" "$STAGE/blocks.json"
  mkdir -p "$STAGE/data"
  chmod 0700 "$STAGE"
  [ "$LEGACY" -eq 1 ] || cp "$manifest" "$STAGE/MANIFEST.json"

  log "==> downloading s3://$BUCKET/$S3_PREFIX ($total bytes) to $STAGE/data"
  SECONDS=0
  timeout -k 30 "$FETCH_TIMEOUT" aws s3 sync --region "$REGION" --only-show-errors --exclude MANIFEST.json \
    "s3://$BUCKET/$S3_PREFIX" "$STAGE/data/" || die "$EXIT_DOWNLOAD" "download failed (aws exit $?); live data was not touched"
  log "==> downloaded in ${SECONDS}s; next: verify"
}

# --- verify -------------------------------------------------------------------

verify_files() { # manifest; prints one line per problem
  local manifest="$1" data="$STAGE/data" path size sum got_size got_sum have want
  while IFS=$'\t' read -r path size sum; do
    if [ ! -f "$data/$path" ] || [ -L "$data/$path" ]; then
      printf 'MISSING %s\n' "$path"
      continue
    fi
    got_size="$(wc -c <"$data/$path" | tr -d ' ')"
    got_sum="$(sha256sum "$data/$path" | awk '{print $1}')"
    [ "$got_size" = "$size" ] || printf 'SIZE %s: %s bytes, manifest says %s\n' "$path" "$got_size" "$size"
    [ "$got_sum" = "$sum" ] || printf 'SHA256 %s: %s, manifest says %s\n' "$path" "$got_sum" "$sum"
  done < <(jq -r '.files[] | [.path, (.size | tostring), .sha256] | @tsv' "$manifest")

  tmp_file have
  tmp_file want
  (cd "$data" && find . -type f | sed 's|^\./||') | LC_ALL=C sort >"$have"
  jq -r '.files[].path' "$manifest" | LC_ALL=C sort >"$want"
  LC_ALL=C comm -23 "$have" "$want" | sed 's/^/EXTRA /'
  (cd "$data" && find . ! -type f ! -type d | sed 's|^\./|NOT-A-FILE |')
}

# promtool tsdb list skips a block without meta.json and still exits 0, so the
# files of every block are checked here first.
verify_blocks() { # ulids file; prints one line per problem
  local ulid dir entry segments last
  while IFS= read -r ulid; do
    dir="$STAGE/data/$ulid"
    [[ "$ulid" =~ $ULID_REGEX ]] || printf 'BAD block name %s\n' "$ulid"
    if [ ! -d "$dir" ]; then
      printf 'MISSING block %s\n' "$ulid"
      continue
    fi
    [ -s "$dir/meta.json" ] || printf 'MISSING %s/meta.json\n' "$ulid"
    [ -s "$dir/index" ] || printf 'MISSING %s/index\n' "$ulid"
    segments=0
    [ ! -d "$dir/chunks" ] || segments="$(find "$dir/chunks" -type f | wc -l | tr -d ' ')"
    if [ "$segments" -eq 0 ]; then
      printf 'MISSING %s/chunks\n' "$ulid"
    else
      last="$(find "$dir/chunks" -type f | sed 's|.*/||' | LC_ALL=C sort | tail -1)"
      if [[ ! "$last" =~ ^[0-9]+$ ]] || [ "$((10#$last))" -ne "$segments" ]; then
        printf 'MISSING %s/chunks: last segment is %s of %s files\n' "$ulid" "$last" "$segments"
      fi
    fi
    if [ -f "$dir/meta.json" ] && ! jq -e --arg ulid "$ulid" \
      '.ulid == $ulid and (.minTime | type) == "number" and (.maxTime | type) == "number"
       and (.stats.numSamples | type) == "number"' "$dir/meta.json" >/dev/null 2>&1; then
      printf 'BAD %s/meta.json: unreadable, incomplete, or for another block\n' "$ulid"
    fi
  done <"$1"
  while IFS= read -r entry; do
    grep -qxF "$entry" "$1" || printf 'EXTRA block %s\n' "$entry"
  done < <(cd "$STAGE/data" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | LC_ALL=C sort)
}

# promtool opens a sandbox inside the database directory, so a read-only mount of
# the directory fails. The tmpfs takes the sandbox and each block stays read-only.
verify_with_promtool() { # ulids file; prints one line per problem
  local ulid listed errors args=()
  # shellcheck disable=SC2054 # the comma belongs to the --tmpfs option
  args=(run --rm --network none --tmpfs /db:rw,mode=1777)
  while IFS= read -r ulid; do
    args+=(-v "$STAGE/data/$ulid:/db/$ulid:ro")
  done <"$1"
  tmp_file listed
  tmp_file errors
  if ! docker "${args[@]}" --entrypoint /bin/promtool "$PROM_IMAGE" tsdb list /db >"$listed" 2>"$errors"; then
    printf 'PROMTOOL cannot open the blocks:\n'
    sed 's/^/  /' "$errors"
    return 0
  fi
  awk 'NR > 1 { print $1 }' "$listed" | LC_ALL=C sort | LC_ALL=C comm -3 - "$1" | sed 's/^[[:space:]]*/PROMTOOL did not list the same block: /'
}

print_timeline() {
  (cd "$STAGE/data" && jq -rs --argjson gap "$GAP_MS" 'sort_by(.minTime)
    | reduce .[] as $b ({end: null, out: [], newest: 0};
        (if .end != null and $b.minTime - .end > $gap
         then .out += ["GAP \(.end / 1000 | floor | todate) -> \($b.minTime / 1000 | floor | todate)"] else . end)
        | .end = ([.end, $b.maxTime] | max) | .newest = .end)
    | .out + ["NEWEST \(.newest / 1000 | floor | todate)"] | .[]' ./*/meta.json) | tee "$STAGE/timeline"
}

# File checks cannot see a final chunk segment that never reached S3 under a legacy
# prefix: the listing and the numbering still agree. Only reading it shows that, and
# promtool tsdb dump exits 0 with an empty stderr when it runs out of chunk data and
# just stops, so the check is the line count against meta.json, not the exit code.
# Each block is read through a hardlinked view, leaving the staged files as they are:
# dump needs a wal/ directory, and tombstones would hide samples from the count.
read_every_sample() { # ulids file
  local ulid expected actual view="$STAGE/check"
  log "==> reading $(cd "$STAGE/data" && jq -s 'map(.stats.numSamples) | add' ./*/meta.json) samples in $(wc -l <"$1" | tr -d ' ') blocks"
  while IFS= read -r ulid; do
    rm -rf -- "${view:?}"
    mkdir -p "$view/wal"
    cp -al "$STAGE/data/$ulid" "$view/"
    rm -f -- "${view:?}/$ulid/tombstones"
    expected="$(jq -r '.stats.numSamples' "$STAGE/data/$ulid/meta.json")"
    actual="$(docker run --rm --network none --cpus=1 --entrypoint /bin/sh -v "$view:/check:ro" "$PROM_IMAGE" \
      -c 'promtool tsdb dump --sandbox-dir-root=/tmp /check | wc -l' | tr -d ' ')" || actual=""
    if [ "$actual" != "$expected" ]; then
      rm -rf -- "${view:?}"
      die "$EXIT_VERIFY" "$ulid: read ${actual:-no} of $expected samples, chunk data is missing; live data was not touched"
    fi
    log "$ulid: $actual samples"
  done <"$1"
  rm -rf -- "${view:?}"
}

cmd_verify() {
  parse_target "$@"
  [ -d "$STAGE/data" ] || die "$EXIT_REFUSED" "nothing fetched at $STAGE/data"
  legacy_warning
  rm -f "$STAGE/VERIFIED" "$STAGE/blocks.json" "$STAGE/timeline"

  local manifest="$STAGE/MANIFEST.json" problems ulids stamp
  tmp_file problems
  tmp_file ulids
  SECONDS=0
  if [ "$LEGACY" -eq 1 ]; then
    (cd "$STAGE/data" && find . -mindepth 1 -maxdepth 1 -type d | sed 's|^\./||') | LC_ALL=C sort >"$ulids"
    [ -s "$ulids" ] || die "$EXIT_VERIFY" "no block directories in $STAGE/data"
    stamp=legacy
  else
    [ -f "$manifest" ] || die "$EXIT_REFUSED" "no MANIFEST.json at $STAGE; fetch again"
    manifest_is_valid "$manifest" "$TARGET" || die "$EXIT_BAD_MANIFEST" "MANIFEST.json of $TARGET is invalid"
    jq -r '.blocks[].ulid' "$manifest" | LC_ALL=C sort >"$ulids"
    stamp="$(sha256sum "$manifest" | awk '{print $1}')"
    verify_files "$manifest" >>"$problems"
    if [ "$(jq -r '.prometheus_image // ""' "$manifest")" != "$PROM_IMAGE" ]; then
      log "WARN: generation was taken with $(jq -r '.prometheus_image // "an unknown image"' "$manifest"); checking with $PROM_IMAGE"
    fi
  fi
  verify_blocks "$ulids" >>"$problems"
  if [ -s "$problems" ]; then
    cat "$problems" >&2
    die "$EXIT_VERIFY" "$TARGET failed verification; live data was not touched"
  fi

  # Before promtool, which runs as the image's own user.
  chown -R "$PROM_UID_GID" "$STAGE/data" || die "$EXIT_VERIFY" "cannot chown $STAGE/data"
  verify_with_promtool "$ulids" >>"$problems"
  if [ -s "$problems" ]; then
    cat "$problems" >&2
    die "$EXIT_VERIFY" "$TARGET failed verification; live data was not touched"
  fi

  print_timeline
  read_every_sample "$ulids"
  if grep -q '^GAP' "$STAGE/timeline"; then
    if [ "$ACCEPT_GAPS" -eq 0 ]; then
      die "$EXIT_VERIFY" "every block reads, but the timeline has gaps: an outage, or a block that never arrived. Compare with an older generation; for a real outage verify again with --accept-gaps"
    fi
    log "WARN: gaps accepted by the operator"
  fi

  (cd "$STAGE/data" && jq -s -c 'map({ulid, max_time: .maxTime})' ./*/meta.json) >"$STAGE/blocks.json"
  printf '%s\n' "$stamp" >"$STAGE/VERIFIED"
  log "==> verified $(wc -l <"$ulids" | tr -d ' ') blocks in ${SECONDS}s; next: switch $TARGET --yes"
}

# --- switch, rollback, finalize -----------------------------------------------

compose() {
  docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" "$@" 8>&-
}

prometheus_stop() {
  compose stop -t 60 "$COMPOSE_SERVICE" || return 1
  [ -z "$(compose ps -q --status running "$COMPOSE_SERVICE")" ]
}

prometheus_start() {
  # --no-recreate: restart the same container; a compose or env change is not ours to apply.
  compose up -d --no-recreate "$COMPOSE_SERVICE"
}

wait_ready() {
  local end=$((SECONDS + READY_TIMEOUT))
  while [ "$SECONDS" -lt "$end" ]; do
    if curl -fsS --max-time 5 "$PROM_URL/-/ready" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# /metrics, not the query API: the API has nothing until the first self-scrape,
# 14 to 19 s after /-/ready, while /metrics has the gauge at once. Read right after
# ready, before the first compaction a minute later. Blocks older than the newest by
# more than the retention go at startup, so only those may be absent: the snapshot's
# head block is newer than any block the live database had when it applied retention.
blocks_loaded_ok() { # blocks.json
  local loaded="" total keep tries=0
  total="$(jq 'length' "$1")"
  keep="$(jq --argjson retention "$RETENTION_MS" \
    '(map(.max_time) | max) as $newest | map(select($newest - .max_time < $retention)) | length' "$1")"
  while [ "$tries" -lt "$GAUGE_TRIES" ]; do
    loaded="$(curl -fsS --max-time 5 "$PROM_URL/metrics" 2>/dev/null |
      awk '$1 == "prometheus_tsdb_blocks_loaded" { print $2; exit }')" || loaded=""
    case "$loaded" in '' | *[!0-9]*) loaded="" ;; *) break ;; esac
    tries=$((tries + 1))
    sleep "$GAUGE_DELAY"
  done
  if [ -z "$loaded" ]; then
    log "WARN: prometheus_tsdb_blocks_loaded did not appear within $((GAUGE_TRIES * GAUGE_DELAY))s"
    return 1
  fi
  log "==> blocks loaded: $loaded of $total in the generation, at least $keep expected after retention"
  [ "$loaded" -gt 0 ] && [ "$loaded" -ge "$keep" ]
}

do_rollback() {
  local id parked fresh phase stage failed_to stamp
  id="$(state_get id)"
  parked="$(state_get parked)"
  fresh="$(state_get fresh)"
  phase="$(state_get phase)"
  stage="$RESTORE_ROOT/$id"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  failed_to="$stage/data.failed-$stamp"

  log "==> rolling back the switch to $id"
  prometheus_stop || {
    printf 'ERR: cannot stop Prometheus for the rollback\n' >&2
    return 1
  }
  if [ "$fresh" = 1 ]; then
    if [ -d "$LIVE_DIR" ]; then
      mv "$LIVE_DIR" "$failed_to" || return 1
    fi
    mkdir "$LIVE_DIR" && chown "$PROM_UID_GID" "$LIVE_DIR" || return 1
  elif [ -d "$parked" ]; then
    if [ -e "$LIVE_DIR" ]; then
      mv "$LIVE_DIR" "$failed_to" || return 1
    fi
    mv "$parked" "$LIVE_DIR" || return 1
  elif [ "$phase" = moving ] && [ -d "$LIVE_DIR" ]; then
    log "==> the live directory was never moved"
  else
    printf 'ERR: %s is gone and %s cannot be trusted\n' "$parked" "$LIVE_DIR" >&2
    return 1
  fi
  rm -f "$SWITCH_STATE" "$stage/VERIFIED"
  prometheus_start || {
    printf 'ERR: previous data is back in place, but Prometheus did not start\n' >&2
    return 1
  }
  wait_ready || {
    printf 'ERR: previous data is back in place, but Prometheus is not ready after %ss\n' "$READY_TIMEOUT" >&2
    return 1
  }
  [ ! -e "$failed_to" ] || log "==> restored data kept at $failed_to"
  log "==> previous data is live again"
}

recover_failed_switch() { # reason
  printf 'ERR: %s\n' "$1" >&2
  MID_SWITCH=0
  do_rollback || die "$EXIT_ROLLBACK_FAILED" "rollback failed; see above. State is in $SWITCH_STATE"
  die "$EXIT_ROLLED_BACK" "restored data was not healthy; rolled back to the previous data"
}

cmd_switch() {
  parse_target "$@"
  [ "$ASSUME_YES" -eq 1 ] || die "$EXIT_REFUSED" "switch stops Prometheus and replaces its data; add --yes"
  [ ! -e "$SWITCH_STATE" ] || die "$EXIT_REFUSED" "a switch to $(state_get id) is still open; rollback or finalize it first"
  [ -d "$STAGE/data" ] || die "$EXIT_REFUSED" "nothing staged at $STAGE/data; fetch and verify first"
  [ -f "$STAGE/VERIFIED" ] && [ -f "$STAGE/blocks.json" ] || die "$EXIT_REFUSED" "$TARGET has not passed verify"
  local stamp_now=legacy
  if [ "$LEGACY" -eq 0 ]; then
    stamp_now="$(sha256sum "$STAGE/MANIFEST.json" | awk '{print $1}')"
  fi
  [ "$(cat "$STAGE/VERIFIED")" = "$stamp_now" ] || die "$EXIT_REFUSED" "$STAGE changed after verify; verify again"
  check_same_filesystem
  legacy_warning

  if [ "$FRESH" -eq 1 ]; then
    if [ -d "$LIVE_DIR" ] && [ -n "$(find "$LIVE_DIR" -mindepth 1 -maxdepth 1 | head -1)" ]; then
      die "$EXIT_REFUSED" "$LIVE_DIR holds data; drop --fresh so it is kept as _data.pre-restore-*"
    fi
  else
    [ -d "$LIVE_DIR" ] || die "$EXIT_REFUSED" "no live data at $LIVE_DIR; on a rebuilt host use --fresh"
  fi

  mkdir -p "$(dirname "$BACKUP_LOCK")"
  exec 8>"$BACKUP_LOCK"
  flock -n 8 || die "$EXIT_REFUSED" "a backup is running; wait for it"

  if [ "$FRESH" -eq 1 ]; then
    # Docker chowns _data to root when it creates a volume over an existing _data, and
    # Prometheus, which runs as nobody, then cannot start. So the volume comes first.
    compose create --no-recreate "$COMPOSE_SERVICE" ||
      die "$EXIT_SWITCH" "could not create the Prometheus volume; data not touched"
  fi

  local stamp parked="" blocks="$STAGE/blocks.json" switched_at
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  switched_at="$(date +%s)"
  [ "$FRESH" -eq 1 ] || parked="$VOLUME_DIR/_data.pre-restore-$stamp"

  SECONDS=0
  log "==> stopping Prometheus"
  prometheus_stop || die "$EXIT_SWITCH" "could not stop Prometheus; data not touched, check it with docker compose ps"

  state_write "$TARGET" "$parked" "$FRESH" moving "$switched_at"
  MID_SWITCH=1
  if [ "$FRESH" -eq 1 ]; then
    [ ! -d "$LIVE_DIR" ] || rmdir "$LIVE_DIR" || recover_failed_switch "cannot remove the empty $LIVE_DIR"
  else
    mv "$LIVE_DIR" "$parked" || recover_failed_switch "cannot rename $LIVE_DIR"
  fi
  mv "$STAGE/data" "$LIVE_DIR" || recover_failed_switch "cannot move $STAGE/data into place"
  state_write "$TARGET" "$parked" "$FRESH" switched "$switched_at"
  log "==> data swapped after ${SECONDS}s; starting Prometheus"

  prometheus_start || recover_failed_switch "Prometheus did not start"
  wait_ready || recover_failed_switch "Prometheus not ready after ${READY_TIMEOUT}s"
  blocks_loaded_ok "$blocks" || recover_failed_switch "restored blocks did not load"
  MID_SWITCH=0
  rm -f "$STAGE/VERIFIED"

  log "==> switched to $TARGET; Prometheus was down for ${SECONDS}s"
  if [ -n "$parked" ]; then
    log "==> previous data is at $parked; rollback restores it, finalize deletes it after 24h"
  fi
}

cmd_rollback() {
  [ $# -eq 0 ] || die "$EXIT_REFUSED" "rollback takes no arguments"
  [ -f "$SWITCH_STATE" ] || die "$EXIT_REFUSED" "no open switch to roll back"
  do_rollback || die "$EXIT_ROLLBACK_FAILED" "rollback failed; see above. State is in $SWITCH_STATE"
}

cmd_finalize() {
  [ "${1:-}" != --yes ] || ASSUME_YES=1
  [ "$ASSUME_YES" -eq 1 ] || die "$EXIT_REFUSED" "finalize deletes the previous data for good; add --yes"
  [ -f "$SWITCH_STATE" ] || die "$EXIT_REFUSED" "no open switch to finalize"
  local parked switched_at phase name now age
  parked="$(state_get parked)"
  switched_at="$(state_get switched_at)"
  phase="$(state_get phase)"
  [ "$phase" = switched ] || die "$EXIT_REFUSED" "the last switch did not finish; rollback instead"
  now="$(date +%s)"
  age=$((now - switched_at))
  [ "$age" -ge "$MIN_KEEP_SECONDS" ] ||
    die "$EXIT_REFUSED" "switched ${age}s ago; keep the previous data for at least ${MIN_KEEP_SECONDS}s"
  if [ -n "$parked" ]; then
    name="$(basename "$parked")"
    [[ "$name" =~ $PARKED_NAME_REGEX ]] && [ "$(dirname "$parked")" = "$VOLUME_DIR" ] &&
      [ -d "$parked" ] && [ ! -L "$parked" ] || die "$EXIT_REFUSED" "refusing to delete $parked"
    log "==> deleting $parked"
    rm -rf -- "$parked"
  fi
  rm -f "$SWITCH_STATE"
  log "==> finalized"
}

on_exit() {
  local rc=$?
  trap - EXIT
  trap '' TERM INT HUP
  set +e
  # An operator's dropped session must not leave Prometheus down on half a swap.
  if [ "$MID_SWITCH" -eq 1 ]; then
    MID_SWITCH=0
    printf 'ERR: interrupted during switch\n' >&2
    if do_rollback; then rc=$EXIT_ROLLED_BACK; else rc=$EXIT_ROLLBACK_FAILED; fi
  fi
  [ "${#TMP_FILES[@]}" -eq 0 ] || rm -f "${TMP_FILES[@]}"
  exit "$rc"
}

main() {
  trap on_exit EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP

  local tool command="${1:-}"
  [ $# -eq 0 ] || shift
  case "$command" in
    '' | -h | --help | help)
      usage
      return 0
      ;;
    list | fetch | verify | switch | rollback | finalize) ;;
    *)
      usage >&2
      die "$EXIT_REFUSED" "unknown command: $command"
      ;;
  esac
  for tool in aws curl docker flock jq sha256sum timeout; do
    command -v "$tool" >/dev/null 2>&1 || die "$EXIT_REFUSED" "$tool is not installed"
  done
  "cmd_$command" "$@"
}

main "$@"
