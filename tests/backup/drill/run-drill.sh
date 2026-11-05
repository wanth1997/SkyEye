#!/bin/bash
# Restore drill, plan section 5.6: the real scripts against a real Prometheus in a
# Docker named volume, with a fake aws over a local directory as the bucket.
#
# Run as root on a Linux Docker host, usually through run-in-colima.sh:
#   DRILL_LOG_DIR=<dir> DRILL_RULES_FILE=<backup.yml> bash tests/backup/drill/run-drill.sh
#
# Everything lives in compose project skyeye-restore-drill: its own volume, port
# 127.0.0.1:19090 and two work directories, and all of it is removed at the end.
# Only the aws fake stands in for anything; curl, docker, flock and jq are real.
# The first failed step stops the drill.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BACKUP="$REPO_ROOT/scripts/backup-prometheus.sh"
RESTORE="$REPO_ROOT/scripts/restore-prometheus.sh"

PROJECT=skyeye-restore-drill
COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"
VOLUME="${PROJECT}_prometheus_data"
VOLUME_DIR="/var/lib/docker/volumes/$VOLUME"
LIVE="$VOLUME_DIR/_data"
CONTAINER="$PROJECT-prometheus-1"
URL=http://127.0.0.1:19090
# Next to Docker's volumes, because switch needs a rename: one filesystem.
STAGING=/var/lib/docker/skyeye-restore-drill-staging
WORK=/var/tmp/skyeye-restore-drill
LOG_DIR="${DRILL_LOG_DIR:?DRILL_LOG_DIR is required}"
RULES_FILE="${DRILL_RULES_FILE:-$REPO_ROOT/prometheus/rules/backup.yml}"
LOOKBACK_WAIT="${DRILL_LOOKBACK_WAIT:-315}"
RESULTS="$LOG_DIR/results.tsv"

for tool in curl docker flock jq sha256sum timeout awk find stat; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'FAIL: %s is required\n' "$tool" >&2
    exit 1
  }
done
[ "$(id -u)" -eq 0 ] || {
  echo "FAIL: the Docker volume path needs root" >&2
  exit 1
}
[ -f "$RULES_FILE" ] || {
  echo "FAIL: no rule file at $RULES_FILE" >&2
  exit 1
}
if docker ps -a --format '{{.Names}}' | grep -q "^$PROJECT-" || docker volume ls -q | grep -qx "$VOLUME" || [ -e "$WORK" ]; then
  echo "FAIL: leftovers of an earlier drill; nothing was touched" >&2
  exit 1
fi

mkdir -p "$LOG_DIR" "$WORK/bin" "$WORK/fast-sleep" "$WORK/config/rules" "$WORK/s3/skyeye-prometheus-snapshots" "$WORK/fake-log" "$WORK/in" "$STAGING"
ln -s "$REPO_ROOT/tests/backup/shim/aws" "$WORK/bin/aws"
printf '#!/bin/bash\nexit 0\n' >"$WORK/fast-sleep/sleep"
chmod +x "$WORK/fast-sleep/sleep"
BUCKET_DIR="$WORK/s3/skyeye-prometheus-snapshots"
printf 'step\ttitle\tresult\tseconds\n' >"$RESULTS"

export DRILL_CONFIG_DIR="$WORK/config"
export FAKE_S3="$WORK/s3" FAKE_LOG="$WORK/fake-log"
export PATH="$WORK/bin:$PATH"
export SKYEYE_BACKUP_VOL_PATH="$LIVE" SKYEYE_BACKUP_STATE_DIR="$WORK/state" SKYEYE_BACKUP_PROM_URL="$URL"
export SKYEYE_BACKUP_CONTAINER="$CONTAINER" SKYEYE_BACKUP_INSTANCE=drill
export SKYEYE_RESTORE_ROOT="$STAGING" SKYEYE_RESTORE_VOLUME_DIR="$VOLUME_DIR" SKYEYE_RESTORE_PROM_URL="$URL"
export SKYEYE_RESTORE_COMPOSE_FILE="$COMPOSE_FILE" SKYEYE_RESTORE_COMPOSE_PROJECT="$PROJECT"
export SKYEYE_RESTORE_BACKUP_LOCK="$WORK/state/lock" SKYEYE_RESTORE_READY_TIMEOUT=120

compose() {
  docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"
}

cleanup() {
  local rc=$?
  trap - EXIT
  {
    docker logs --tail 200 "$CONTAINER"
  } >"$LOG_DIR/prometheus-tail.log" 2>&1
  compose down -v --remove-orphans >>"$LOG_DIR/cleanup.log" 2>&1
  rm -rf "${WORK:?}" "${STAGING:?}" "${VOLUME_DIR:?}"
  {
    printf 'containers left: '
    docker ps -a --format '{{.Names}}' | grep -c "^$PROJECT-"
    printf 'volumes left: '
    docker volume ls -q | grep -cx "$VOLUME"
    printf 'work dirs left: '
    find "$WORK" "$STAGING" "$VOLUME_DIR" -maxdepth 0 2>/dev/null | wc -l
  } | tee -a "$LOG_DIR/cleanup.log"
  exit "$rc"
}
trap cleanup EXIT

say() { printf '  %s\n' "$*"; }
die() {
  printf '  FAILED: %s\n' "$*"
  exit 1
}

# step <id> <title> <function>: stops the drill on failure.
step() {
  local id="$1" title="$2" fn="$3" log="$LOG_DIR/step-$1.log" start end rc
  printf '== step %s: %s\n' "$id" "$title"
  start=$(date +%s)
  ("$fn") >"$log" 2>&1
  rc=$?
  end=$(date +%s)
  sed 's/^/   /' "$log" | tail -40
  if [ "$rc" -eq 0 ]; then
    printf '%s\t%s\tPASS\t%s\n' "$id" "$title" $((end - start)) >>"$RESULTS"
    printf '   -> PASS in %ss\n' $((end - start))
  else
    printf '%s\t%s\tFAIL\t%s\n' "$id" "$title" $((end - start)) >>"$RESULTS"
    printf '   -> FAIL (rc=%s)\n' "$rc"
    exit 1
  fi
}

query_count() { # promql: number of series in the result
  curl -fsS --max-time 10 "$URL/api/v1/query" --data-urlencode "query=$1" | jq '.data.result | length'
}

query_value() { # promql
  curl -fsS --max-time 10 "$URL/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // empty'
}

gauge() { # metric name, from /metrics
  curl -fsS --max-time 10 "$URL/metrics" | awk -v name="$1" '$1 == name { print $2; exit }'
}

wait_ready() {
  local tries=0
  until curl -fsS --max-time 3 "$URL/-/ready" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 60 ] || return 1
    sleep 2
  done
}

# Block files only: the WAL and head change while Prometheus runs, by design.
live_blocks_hash() {
  (cd "$LIVE" && find . -path ./snapshots -prune -o -path ./wal -prune -o -path ./chunks_head -prune -o \
    -type f ! -name lock ! -name queries.active -print | LC_ALL=C sort | xargs -r sha256sum | sha256sum | cut -d' ' -f1)
}

staged_hash() { # directory
  (cd "$1" && find . -type f | LC_ALL=C sort | xargs -r sha256sum | sha256sum | cut -d' ' -f1)
}

marker_before() { query_count 'last_over_time(drill_marker{phase="before"}[8d])'; }
marker_after() { query_count 'last_over_time(drill_marker{phase="after"}[6h])'; }

restore() { # args; prints the output, returns its exit code
  bash "$RESTORE" "$@"
}

expect_rc() { # expected, command...
  local want="$1" got
  shift
  "$@"
  got=$?
  [ "$got" -eq "$want" ] || die "$* exited $got, expected $want"
}

# --- setup --------------------------------------------------------------------

setup_data() {
  cat >"$WORK/config/prometheus.yml" <<'YAML'
global:
  scrape_interval: 5s
  evaluation_interval: 15s
rule_files:
  - /etc/prometheus/rules/*.yml
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: [127.0.0.1:9090]
YAML
  cp "$RULES_FILE" "$WORK/config/rules/backup.yml"
  chmod -R a+rX "$WORK/config"

  # Three days of drill_marker, ending shortly before the snapshot.
  local now
  now="$(date +%s)"
  awk -v end=$((now - 600)) -v start=$((now - 3 * 86400)) 'BEGIN {
    print "# TYPE drill_marker gauge"
    for (i = 0; i < 20; i++)
      for (t = start; t < end; t += 60)
        printf "drill_marker{phase=\"before\",shard=\"%d\"} 1 %d\n", i, t
    print "# EOF"
  }' >"$WORK/in/drill.om"
  chmod -R a+rX "$WORK/in"
  say "samples: $(($(wc -l <"$WORK/in/drill.om") - 2))"

  compose run --rm --no-deps -v "$WORK/in:/in:ro" --entrypoint /bin/promtool prometheus \
    tsdb create-blocks-from openmetrics -q /in/drill.om /prometheus || die "cannot create blocks"
  compose up -d prometheus || die "cannot start Prometheus"
  wait_ready || die "Prometheus never got ready"

  # Compaction merges the 2h blocks over the first minutes. The hashes below must
  # compare a quiet database, not a compaction.
  local last="" now_state stable=0
  while [ "$stable" -lt 2 ]; do
    sleep 40
    now_state="$(gauge prometheus_tsdb_blocks_loaded) $(gauge prometheus_tsdb_compactions_total)"
    if [ "$now_state" = "$last" ]; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    last="$now_state"
    say "blocks loaded, compactions: $now_state"
  done
  [ "$(marker_before)" -eq 20 ] || die "synthetic data not queryable"
  find "$LIVE" -mindepth 1 -maxdepth 1 | sort | sed 's|.*/||'
}

# --- plan steps ---------------------------------------------------------------

record_snapshot_links() { # the snapshot, seen from inside the upload
  cat >"$WORK/sync-hook" <<HOOK
#!/bin/bash
find "\$1" -type f -exec stat -c '%h %s %n' {} + | sed "s|\$1/||" | sort -k3 >"$WORK/link-counts.txt"
HOOK
  chmod +x "$WORK/sync-hook"
}

step_1_backup() {
  record_snapshot_links
  FAKE_AWS_SYNC_HOOK="$WORK/sync-hook" bash "$BACKUP" || die "backup failed"
  local manifest
  manifest="$(find "$BUCKET_DIR" -name MANIFEST.json)"
  [ "$(printf '%s\n' "$manifest" | wc -l)" -eq 1 ] && [ -n "$manifest" ] || die "expected one manifest"
  GEN1="$(jq -r .snapshot_id "$manifest")"
  printf '%s\n' "$GEN1" >"$WORK/gen1"
  say "generation $GEN1: $(jq '.blocks | length' "$manifest") blocks, $(jq '.files | length' "$manifest") files, $(jq .total_bytes "$manifest") bytes"
  say "image $(jq -r .prometheus_image "$manifest"), commit $(jq -r .script_commit "$manifest")"
  [ -z "$(find "$LIVE/snapshots" -mindepth 1 -maxdepth 1)" ] || die "snapshot not cleaned"

  # Plan section 3: snapshots share blocks by hardlink; only the head is new.
  cp "$WORK/link-counts.txt" "$LOG_DIR/step-1-link-counts.txt"
  local head_files linked_files
  head_files="$(awk '$1 == 1 { split($3, p, "/"); print p[1] }' "$WORK/link-counts.txt" | sort -u | wc -l)"
  linked_files="$(awk '$1 >= 2' "$WORK/link-counts.txt" | wc -l)"
  say "files with link count >= 2: $linked_files; blocks with link count 1: $head_files"
  [ "$linked_files" -gt 0 ] || die "blocks are not hardlinked"
  [ "$head_files" -eq 1 ] || die "expected exactly the head block to be new"
  say "head block files:"
  awk '$1 == 1' "$WORK/link-counts.txt"
}

step_2_after_marker() {
  printf 'drill_marker{phase="after",shard="0"} 1\n' |
    docker exec -i "$CONTAINER" /bin/promtool push metrics --label=job=drill http://127.0.0.1:9090/api/v1/write ||
    die "push failed"
  sleep 1
  [ "$(marker_after)" -eq 1 ] || die "phase=after not queryable"
  say "phase=after is queryable"
}

step_3_download_fails() {
  local gen before started
  gen="$(cat "$WORK/gen1")"
  before="$(live_blocks_hash)"
  started="$(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER")"
  FAKE_AWS_DOWNLOAD=fail_after:3 restore fetch "$gen"
  local rc=$?
  [ "$rc" -eq 6 ] || die "fetch exited $rc, expected 6"
  [ "$(live_blocks_hash)" = "$before" ] || die "live blocks changed"
  [ "$(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER")" = "$started" ] || die "Prometheus was restarted"
  curl -fsS "$URL/-/ready" || die "Prometheus not ready"
  say "live hash unchanged: $before"
}

step_4_chunk_missing() {
  local gen dir chunk
  gen="$(cat "$WORK/gen1")"
  dir="$(dirname "$(find "$BUCKET_DIR" -path "*/$gen/MANIFEST.json")")"
  chunk="$(cd "$dir" && find . -path '*/chunks/*' -type f | sed 's|^\./||' | sort | head -1)"
  mv "$dir/$chunk" "$WORK/chunk.aside"
  say "removed $chunk from the bucket"
  expect_rc 0 restore fetch "$gen"
  restore verify "$gen" 2>&1 | tee "$WORK/out"
  local rc=${PIPESTATUS[0]}
  mv "$WORK/chunk.aside" "$dir/$chunk"
  [ "$rc" -eq 7 ] || die "verify exited $rc, expected 7"
  grep -qF "MISSING $chunk" "$WORK/out" || die "verify did not name $chunk"
  [ ! -e "$STAGING/$gen/VERIFIED" ] || die "approval left behind"
}

step_5_index_truncated() {
  local gen dir index
  gen="$(cat "$WORK/gen1")"
  dir="$(dirname "$(find "$BUCKET_DIR" -path "*/$gen/MANIFEST.json")")"
  index="$(cd "$dir" && find . -name index -type f | sed 's|^\./||' | sort | head -1)"
  cp "$dir/$index" "$WORK/index.aside"
  truncate -s 100 "$dir/$index"
  say "truncated $index in the bucket"
  expect_rc 0 restore fetch "$gen"
  restore verify "$gen" 2>&1 | tee "$WORK/out"
  local rc=${PIPESTATUS[0]}
  mv "$WORK/index.aside" "$dir/$index"
  [ "$rc" -eq 7 ] || die "verify exited $rc, expected 7"
  grep -qF "SHA256 $index" "$WORK/out" || die "verify did not report sha256 for $index"
}

step_6_no_manifest() {
  # A real failed run: every piece uploaded except the manifest.
  FAKE_AWS_CP=fail PATH="$WORK/fast-sleep:$PATH" bash "$BACKUP"
  local rc=$? partial
  [ "$rc" -eq 6 ] || die "backup exited $rc, expected 6"
  partial="$(find "$BUCKET_DIR/generations" -mindepth 2 -maxdepth 2 -type d | while read -r d; do
    [ -f "$d/MANIFEST.json" ] || basename "$d"
  done)"
  [ -n "$partial" ] || die "no prefix without a manifest"
  say "prefix without manifest: $partial"
  restore list | tee "$WORK/out"
  ! grep -q "$partial" "$WORK/out" || die "list shows it"
  grep -q "$(cat "$WORK/gen1")" "$WORK/out" || die "list lost the good generation"
  restore fetch "$partial"
  rc=$?
  [ "$rc" -eq 3 ] || die "fetch exited $rc, expected 3"
  say "failed run left: $(find "$LIVE/snapshots" -mindepth 1 -maxdepth 1 | wc -l) snapshot"
  cat "$WORK/state/metrics/skyeye_backup.prom"
}

step_7_metrics_and_rules() {
  local prom="$WORK/state/metrics/skyeye_backup.prom" pushed_at
  # The exact push of the script, once more, to time the 5 minutes from here.
  timeout 30 docker exec -i "$CONTAINER" /bin/promtool push metrics \
    --label=job=skyeye-backup --label=instance=drill \
    http://127.0.0.1:9090/api/v1/write <"$prom" || die "promtool push failed"
  pushed_at="$(date +%s)"
  sleep 2
  local name
  for name in $(awk '/^skyeye_backup_/ { print $1 }' "$prom"); do
    [ "$(query_count "$name{job=\"skyeye-backup\",instance=\"drill\"}")" -eq 1 ] || die "$name not queryable"
  done
  say "all metrics queryable: $(awk '/^skyeye_backup_/ { print $1 }' "$prom" | wc -l)"
  say "labels: $(curl -fsS "$URL/api/v1/query" --data-urlencode 'query=skyeye_backup_last_exit_code{instance="drill"}' | jq -c '.data.result[0].metric')"

  curl -fsS "$URL/api/v1/rules" | jq -r '.data.groups[] | select(.name == "skyeye-backup") | .rules[] | "\(.name) health=\(.health) state=\(.state)"' | tee "$WORK/out"
  [ "$(grep -c 'health=ok' "$WORK/out")" -eq 4 ] || die "the four backup rules are not healthy"

  # A first run that fails: an attempt with no success series is timestamp 0.
  printf 'skyeye_backup_last_attempt_timestamp_seconds %s\n' "$pushed_at" |
    docker exec -i "$CONTAINER" /bin/promtool push metrics --label=job=skyeye-backup --label=instance=drill-first-failure \
      http://127.0.0.1:9090/api/v1/write || die "push failed"
  # Bounds exceeded.
  printf 'skyeye_backup_last_attempt_timestamp_seconds %s\nskyeye_backup_last_success_timestamp_seconds %s\nskyeye_backup_pending_generations 3\n' "$pushed_at" "$pushed_at" |
    docker exec -i "$CONTAINER" /bin/promtool push metrics --label=job=skyeye-backup --label=instance=drill-accumulating \
      http://127.0.0.1:9090/api/v1/write || die "push failed"

  say "waiting ${LOOKBACK_WAIT}s, past the 5m instant lookback"
  sleep "$LOOKBACK_WAIT"

  local instant kept
  instant="$(query_count 'skyeye_backup_last_attempt_timestamp_seconds{job="skyeye-backup",instance="drill"}')"
  kept="$(query_value 'last_over_time(skyeye_backup_last_attempt_timestamp_seconds{job="skyeye-backup",instance="drill"}[30h])')"
  say "after $(($(date +%s) - pushed_at))s: instant series $instant, last_over_time value $kept"
  if [ "$LOOKBACK_WAIT" -ge 300 ]; then
    [ "$instant" -eq 0 ] || die "the instant query still sees the sample; this wait proves nothing"
  fi
  [ -n "$kept" ] || die "last_over_time lost the sample"

  curl -fsS "$URL/api/v1/query" --data-urlencode 'query=ALERTS{alertname=~"PrometheusBackup.*"}' |
    jq -r '.data.result[].metric | "\(.alertname) instance=\(.instance) state=\(.alertstate) mode=\(.notification_mode)"' | sort | tee "$WORK/out"
  grep -q 'PrometheusBackupStaleCritical instance=drill-first-failure .*mode=shadow' "$WORK/out" || die "a first failure did not reach StaleCritical"
  grep -q 'PrometheusBackupSnapshotsAccumulating instance=drill-accumulating .*mode=shadow' "$WORK/out" || die "pending over the bound did not reach Accumulating"
  ! grep -qE 'PrometheusBackupStale(Critical)? instance=drill ' "$WORK/out" || die "a healthy instance is alerting"
  ! grep -q 'mode=null' "$WORK/out" || die "an alert without the shadow label"
}

fetch_and_verify() { # generation
  expect_rc 0 restore fetch "$1"
  expect_rc 0 restore verify "$1"
}

step_8_switch_to_broken_data() {
  local gen before_blocks
  gen="$(cat "$WORK/gen1")"
  [ "$(marker_after)" -eq 1 ] || die "phase=after is gone before the step"
  fetch_and_verify "$gen"
  chown -R root:root "$STAGING/$gen/data"
  chmod -R go-rwx "$STAGING/$gen/data"
  before_blocks="$(live_blocks_hash)"
  SKYEYE_RESTORE_READY_TIMEOUT=45 restore switch "$gen" --yes
  local rc=$?
  [ "$rc" -eq 9 ] || die "switch exited $rc, expected 9"
  wait_ready || die "Prometheus did not come back"
  [ "$(marker_after)" -eq 1 ] || die "phase=after did not come back"
  [ "$(live_blocks_hash)" = "$before_blocks" ] || say "note: block files changed after restart (compaction)"
  say "phase=after is back after the automatic rollback"
  find "$VOLUME_DIR" -mindepth 1 -maxdepth 1 | sed 's|.*/||'
}

step_9_switch() {
  local gen blocks loaded
  gen="$(cat "$WORK/gen1")"
  fetch_and_verify "$gen"
  blocks="$(jq '.blocks | length' "$STAGING/$gen/MANIFEST.json")"
  restore switch "$gen" --yes | tee "$WORK/out"
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "switch failed"
  grep -q "blocks loaded: $blocks of $blocks" "$WORK/out" || die "the tool did not see all $blocks blocks"
  loaded="$(gauge prometheus_tsdb_blocks_loaded)"
  say "manifest blocks $blocks, /metrics now $loaded"
  [ "$(marker_before)" -eq 20 ] || die "phase=before not queryable"
  [ "$(marker_after)" -eq 0 ] || die "phase=after is still there"
  say "phase=before queryable, phase=after gone"
}

step_10_rollback() {
  expect_rc 0 restore rollback
  wait_ready || die "Prometheus did not come back"
  [ "$(marker_after)" -eq 1 ] || die "phase=after did not come back"
  [ "$(marker_before)" -eq 20 ] || die "phase=before is gone"
  say "phase=after is back"
}

step_11_rename_on_named_volume() {
  # Steps 8 to 10 renamed _data under Docker three times. Show the container follows.
  docker volume inspect "$VOLUME" --format 'mountpoint={{.Mountpoint}} driver={{.Driver}}'
  say "_data inode on the host: $(stat -c %i "$LIVE"), device $(stat -c %d "$LIVE"), staging device $(stat -c %d "$STAGING")"
  local inside
  inside="$(docker exec "$CONTAINER" stat -c %i /prometheus)"
  say "/prometheus inode in the container: $inside"
  [ "$inside" = "$(stat -c %i "$LIVE")" ] || die "the container does not see the renamed directory"
  [ "$(stat -c %d "$LIVE")" = "$(stat -c %d "$STAGING")" ] || die "staging is on another filesystem"
  say "rename works on the named volume; the fallback of moving contents is not needed"
}

# --- beyond the plan: what only real promtool or a real start can show ----------

legacy_prefix_from_fixture() { # date
  local dir="$BUCKET_DIR/$1"
  mkdir -p "$dir"
  tar -xzf "$SCRIPT_DIR/../fixtures/tsdb/multi-segment-block.tgz" -C "$dir"
}

step_read_intact_block() {
  legacy_prefix_from_fixture 2026-10-20
  expect_rc 0 restore fetch --legacy-prefix 2026-10-20
  local stage="$STAGING/legacy-2026-10-20" before
  before="$(staged_hash "$stage/data")"
  expect_rc 0 restore verify --legacy-prefix 2026-10-20
  [ "$(staged_hash "$stage/data")" = "$before" ] || die "verify changed the staged files"
  [ ! -e "$stage/check" ] || die "the view was left behind"
}

step_read_lost_last_segment() {
  legacy_prefix_from_fixture 2026-10-21
  local block last
  block="$(ls "$BUCKET_DIR/2026-10-21")"
  last="$(ls "$BUCKET_DIR/2026-10-21/$block/chunks" | sort | tail -1)"
  rm -f "${BUCKET_DIR:?}/2026-10-21/$block/chunks/$last"
  say "removed chunks/$last, so listing and numbering still agree"
  expect_rc 0 restore fetch --legacy-prefix 2026-10-21
  restore verify --legacy-prefix 2026-10-21 2>&1 | tee "$WORK/out"
  [ "${PIPESTATUS[0]}" -eq 7 ] || die "verify did not reject it"
  grep -Eq "read [0-9]+ of 96000 samples" "$WORK/out" || die "not rejected by the sample count"
}

step_read_truncated_segment() {
  legacy_prefix_from_fixture 2026-10-22
  local block last
  block="$(ls "$BUCKET_DIR/2026-10-22")"
  last="$(ls "$BUCKET_DIR/2026-10-22/$block/chunks" | sort | tail -1)"
  truncate -s 5000 "$BUCKET_DIR/2026-10-22/$block/chunks/$last"
  expect_rc 0 restore fetch --legacy-prefix 2026-10-22
  restore verify --legacy-prefix 2026-10-22 2>&1 | tee "$WORK/out"
  [ "${PIPESTATUS[0]}" -eq 7 ] || die "verify did not reject it"
  grep -Eq "read [0-9]+ of 96000 samples" "$WORK/out" || die "not rejected by the sample count"
}

step_read_tombstones() {
  legacy_prefix_from_fixture 2026-10-23
  local block
  block="$(ls "$BUCKET_DIR/2026-10-23")"
  cp "$SCRIPT_DIR/../fixtures/tsdb/tombstones" "$BUCKET_DIR/2026-10-23/$block/tombstones"
  expect_rc 0 restore fetch --legacy-prefix 2026-10-23
  expect_rc 0 restore verify --legacy-prefix 2026-10-23
  cmp "$SCRIPT_DIR/../fixtures/tsdb/tombstones" "$STAGING/legacy-2026-10-23/data/$block/tombstones" || die "tombstones changed in staging"
  say "a tombstoned series is not a short read, and staging keeps the file"
}

step_read_missing_meta() {
  legacy_prefix_from_fixture 2026-10-24
  local block
  block="$(ls "$BUCKET_DIR/2026-10-24")"
  rm -f "${BUCKET_DIR:?}/2026-10-24/$block/meta.json"
  expect_rc 0 restore fetch --legacy-prefix 2026-10-24
  restore verify --legacy-prefix 2026-10-24 2>&1 | tee "$WORK/out"
  [ "${PIPESTATUS[0]}" -eq 7 ] || die "verify did not reject it"
  grep -q "MISSING $block/meta.json" "$WORK/out" || die "not named"
}

step_legacy_restore() {
  # The real blocks of the first generation, as the old script laid them out.
  local gen dir stage=2026-11-03
  gen="$(cat "$WORK/gen1")"
  dir="$(dirname "$(find "$BUCKET_DIR" -path "*/$gen/MANIFEST.json")")"
  mkdir -p "$BUCKET_DIR/$stage"
  cp -R "$dir"/*/ "$BUCKET_DIR/$stage/"
  expect_rc 0 restore fetch --legacy-prefix "$stage"
  expect_rc 0 restore verify --legacy-prefix "$stage"
  expect_rc 0 restore switch --legacy-prefix "$stage" --yes
  [ "$(marker_before)" -eq 20 ] || die "phase=before not queryable"
  [ "$(marker_after)" -eq 0 ] || die "phase=after is still there"
  expect_rc 0 restore rollback
  wait_ready || die "Prometheus did not come back"
  [ "$(marker_after)" -eq 1 ] || die "phase=after did not come back"
}

step_finalize_keeps_a_day() {
  local gen
  gen="$(cat "$WORK/gen1")"
  fetch_and_verify "$gen"
  expect_rc 0 restore switch "$gen" --yes
  restore finalize --yes
  local rc=$?
  [ "$rc" -eq 2 ] || die "finalize exited $rc, expected 2"
  find "$VOLUME_DIR" -mindepth 1 -maxdepth 1 -name '_data.pre-restore-*' | grep -q . || die "the previous data is gone"
  expect_rc 0 restore rollback
  wait_ready || die "Prometheus did not come back"
}

step_fresh_host() {
  local gen
  gen="$(cat "$WORK/gen1")"
  fetch_and_verify "$gen"
  compose down -v || die "cannot remove the volume"
  [ ! -e "$VOLUME_DIR" ] || die "the volume is still there"
  say "volume and container removed: a rebuilt host"
  expect_rc 0 restore switch "$gen" --yes --fresh
  [ "$(marker_before)" -eq 20 ] || die "phase=before not queryable"
  docker volume inspect "$VOLUME" --format 'volume recreated: {{.Mountpoint}}'
}

step_12_timing() {
  awk -F'\t' 'NR > 1 { printf "%-8s %5ss  %s\n", $1, $4, $2 }' "$RESULTS"
  grep -h 'Prometheus was down for\|downloaded in\|verified .* blocks in' "$LOG_DIR"/step-*.log | sed 's/^[^ ]* //'
}

step setup "seed three days of data, start, wait for compaction" setup_data
step 1 "backup with hardlink evidence" step_1_backup
step 2 'write drill_marker{phase="after"}' step_2_after_marker
step 3 "download fails midway" step_3_download_fails
step 4 "chunk removed from the bucket" step_4_chunk_missing
step 5 "index truncated in the bucket" step_5_index_truncated
step 6 "prefix without manifest" step_6_no_manifest
step 7 "promtool push, shadow rules, last_over_time past 5 minutes" step_7_metrics_and_rules
step 8 "switch to data with broken permissions" step_8_switch_to_broken_data
step 9 "normal switch" step_9_switch
step 10 "rollback" step_10_rollback
step 11 "rename on the Docker named volume" step_11_rename_on_named_volume
step read-a "real read: intact 45-segment block" step_read_intact_block
step read-b "real read: last segment lost" step_read_lost_last_segment
step read-c "real read: last segment truncated" step_read_truncated_segment
step read-d "real read: tombstones are no short read" step_read_tombstones
step read-e "real read: block without meta.json" step_read_missing_meta
step legacy "legacy prefix restores and rolls back" step_legacy_restore
step finalize "finalize refuses inside 24 hours" step_finalize_keeps_a_day
step fresh "--fresh on a rebuilt host" step_fresh_host
step 12 "timing" step_12_timing

printf '\nDRILL PASS. Results: %s\n' "$RESULTS"
