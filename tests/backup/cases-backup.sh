# shellcheck shell=bash
# scripts/backup-prometheus.sh: what a published generation is, what it may delete,
# and what it reports. These run against the new script only.

OLD_ID_1=20261020T190000Z-00000000000000a1
OLD_ID_2=20261021T190000Z-00000000000000a2
OLD_ID_3=20261022T190000Z-00000000000000a3
APRIL_ID=20260423T050734Z-1833eb911e7fbdde

b_generation_layout_and_manifest() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=ok
  check_eq "backup succeeds" 0 "$RC"
  local id dir manifest
  id="$(latest_generation)"
  dir="$BUCKET_DIR/generations/2026-11-01/$id"
  manifest="$dir/MANIFEST.json"
  check "prefix is generations/<date>/<id>/" [ -f "$manifest" ]
  check "the id is the snapshot name" jq -e --arg id "$id" '.snapshot_id == $id and .schema == 1' "$manifest"
  check "times come from the id and the clock" jq -e '.created_at == "2026-11-01T19:00:00Z" and .completed_at == "2026-11-01T19:00:00Z"' "$manifest"
  check "image is recorded" jq -e '.prometheus_image == "prom/prometheus:v2.54.1"' "$manifest"
  check "commit is recorded" jq -e '.script_commit | test("^([0-9a-f]{40}|unknown)$")' "$manifest"
  check_eq "all five blocks are listed" 5 "$(jq '.blocks | length' "$manifest")"
  check "block times come from meta.json" jq -e --arg u "$BLOCK_A" '.blocks[] | select(.ulid == $u) | .max_time == 1790000000000 and .min_time == 1789992800000' "$manifest"
  check_eq "manifest lists every uploaded object" \
    "$(cd "$dir" && find . -type f ! -name MANIFEST.json | sed 's|^\./||' | LC_ALL=C sort)" \
    "$(jq -r '.files[].path' "$manifest" | LC_ALL=C sort)"
  local path size sum wrong=0
  while IFS=$'\t' read -r path size sum; do
    [ "$(wc -c <"$dir/$path" | tr -d ' ')" = "$size" ] || wrong=$((wrong + 1))
    [ "$(sha256sum "$dir/$path" | cut -d' ' -f1)" = "$sum" ] || wrong=$((wrong + 1))
  done < <(jq -r '.files[] | [.path, (.size | tostring), .sha256] | @tsv' "$manifest")
  check_eq "sizes and hashes match the objects" 0 "$wrong"
  check_eq "total_bytes is the sum of the files" "$(jq '[.files[].size] | add' "$manifest")" "$(jq '.total_bytes' "$manifest")"
  check_eq "MANIFEST.json is the last object uploaded" "skyeye-prometheus-snapshots/generations/2026-11-01/$id/MANIFEST.json" "$(tail -1 "$LOGDIR/s3-put-order.log")"
  check_eq "snapshot is cleaned" 0 "$(snapcount)"
  check_eq "pending record is cleaned" 0 "$(pending_records)"
  check_eq "local state records the success" "$T0" "$(metric_value skyeye_backup_last_success_timestamp_seconds)"
  check_eq "uploaded bytes are reported" "$(jq '.total_bytes' "$manifest")" "$(metric_value skyeye_backup_last_uploaded_bytes)"
}

b_success_needs_the_manifest_confirmed() {
  seed_live
  run_backup "$T0" FAKE_AWS_CP=fail
  check_eq "a manifest that cannot be uploaded fails the run" 6 "$RC"
  check_not "no success is claimed" logged "$RUNLOG" 'backup OK'
  check_eq "no success metric" "" "$(metric_value skyeye_backup_last_success_timestamp_seconds)"
  check_eq "the snapshot stays" 1 "$(snapcount)"
  check_eq "nothing counts as complete" 0 "$(manifest_count)"
}

b_manifest_with_wrong_size_is_not_confirmed() {
  seed_live
  run_backup "$T0" FAKE_AWS_CP=truncate
  check_eq "a truncated manifest fails the run" 6 "$RC"
  check_not "no success is claimed" logged "$RUNLOG" 'backup OK'
  check_eq "the snapshot stays" 1 "$(snapcount)"
}

b_listing_mismatch_blocks_the_manifest() {
  seed_live
  run_backup "$T0" "FAKE_AWS_SYNC=skip_match:$BLOCK_B/index"
  check_eq "an object missing after a clean sync fails the run" 5 "$RC"
  check_eq "no manifest is uploaded" 0 "$(manifest_count)"
  check "the log names the missing object" logged "$RUNLOG" "missing $BLOCK_B/index"
}

b_extra_object_in_the_prefix_blocks_the_manifest() {
  seed_live
  local hook="$SB/plant-object"
  cat >"$hook" <<HOOK
#!/bin/bash
id="\$(basename "\$1")"
mkdir -p "$BUCKET_DIR/generations/2026-11-01/\$id"
echo planted >"$BUCKET_DIR/generations/2026-11-01/\$id/planted"
HOOK
  chmod +x "$hook"
  run_backup "$T0" FAKE_AWS_SYNC_HOOK="$hook"
  check_eq "an object the snapshot does not have fails the run" 5 "$RC"
  check "the log names it" logged "$RUNLOG" 'unexpected planted'
  check_eq "no manifest is uploaded" 0 "$(manifest_count)"
}

b_parallel_upload_failure_is_a_failure() {
  seed_live
  run_backup "$T0" "FAKE_AWS_SYNC=fail_match:chunks/000001"
  check_eq "objects lost out of order fail the run" 4 "$RC"
  check_eq "no manifest over meta.json without its chunks" 0 "$(manifest_count)"
}

b_retries_use_the_planned_delays() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=fail_times:2
  check_eq "the third attempt succeeds" 0 "$RC"
  check_eq "waits 1 then 5 minutes" "60 300" "$(tr '\n' ' ' <"$LOGDIR/sleep.log" | sed 's/ $//')"
  check_eq "sync runs three times" 3 "$(grep -c 's3 sync' "$LOGDIR/aws-calls.log")"
  check_eq "all in one generation" 1 "$(manifest_count)"
  check_eq "one snapshot is enough" 1 "$(grep -c 'admin/tsdb/snapshot' "$LOGDIR/curl-calls.log")"
}

b_gives_up_after_three_attempts() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=fail_all
  check_eq "reports the upload stage" 4 "$RC"
  check_eq "three attempts" 3 "$(grep -c 's3 sync' "$LOGDIR/aws-calls.log")"
}

b_transient_listing_failure_recovers() {
  seed_live
  run_backup "$T0" FAKE_AWS_LS=fail_times:1
  check_eq "the retry completes the generation" 0 "$RC"
  check_eq "one manifest" 1 "$(manifest_count)"
}

b_transient_manifest_failure_recovers() {
  seed_live
  run_backup "$T0" FAKE_AWS_CP=fail_times:1
  check_eq "the retry completes the generation" 0 "$RC"
  check_eq "one manifest" 1 "$(manifest_count)"
}

b_unexpected_snapshot_name_is_refused() {
  seed_live
  mkdir -p "$SB/volume/outside"
  echo keep >"$SB/volume/outside/file"
  run_backup "$T0" FAKE_CURL=evil_name
  check_eq "rejected as a snapshot failure" 2 "$RC"
  check "nothing outside snapshots/ is touched" [ -f "$SB/volume/outside/file" ]
  check_eq "nothing is recorded" 0 "$(pending_records)"
}

b_missing_or_empty_snapshot_fails() {
  seed_live
  run_backup "$T0" FAKE_CURL=missing_dir
  check_eq "a snapshot dir that is not there fails" 3 "$RC"
  run_backup $((T0 + 60)) FAKE_CURL=no_blocks
  check_eq "a snapshot with no blocks fails" 3 "$RC"
  check_eq "nothing is published" 0 "$(manifest_count)"
}

b_broken_block_in_snapshot_fails() {
  seed_live
  run_backup "$T0" "FAKE_SNAPSHOT_DROP=$BLOCK_B/index"
  check_eq "a snapshot block without index fails before any upload" 3 "$RC"
  check_not "nothing is uploaded" logged "$LOGDIR/aws-calls.log" 's3 sync'
  check_eq "the snapshot is still recorded for retention" 1 "$(pending_records)"
}

b_pending_record_precedes_the_upload() {
  seed_live
  local hook="$SB/capture-record"
  cat >"$hook" <<HOOK
#!/bin/bash
cp "$STATE/pending/\$(basename "\$1").json" "$LOGDIR/record-at-upload.json"
HOOK
  chmod +x "$hook"
  run_backup "$T0" FAKE_AWS_SYNC_HOOK="$hook"
  check "the record has the inventory before anything is uploaded" \
    jq -e '(.files | length) > 0 and (.files[0].sha256 | length) == 64 and (.blocks | length) == 5' "$LOGDIR/record-at-upload.json"
}

b_limit_pending_generations() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=fail_all
  local first second
  first="$(ls "$VOL/snapshots")"
  run_backup $((T0 + DAY)) FAKE_AWS_SYNC=fail_all
  check_eq "two failures keep two" 2 "$(snapcount)"
  second="$(ls "$VOL/snapshots" | tail -1)"
  run_backup $((T0 + 2 * DAY)) FAKE_AWS_SYNC=fail_all
  check_eq "the third failure stays at the limit" 2 "$(snapcount)"
  check_not "the oldest went" [ -e "$VOL/snapshots/$first" ]
  check "the one before the newest stayed" [ -d "$VOL/snapshots/$second" ]
  check_eq "records match the directories" 2 "$(pending_records)"
  check_eq "the metric reports the bound" 2 "$(metric_value skyeye_backup_pending_generations)"
}

sparse_generation() { # id, bytes: a pending generation holding that many pinned bytes
  record_pending "$1"
  dd if=/dev/zero of="$VOL/snapshots/$1/$BLOCK_A/chunks/000001" bs=1 count=0 seek="$2" 2>/dev/null
}

b_limit_pinned_bytes_over_three_gib() {
  seed_live
  sparse_generation "$OLD_ID_1" $((3 * 1024 * 1024 * 1024 + 512 * 1024 * 1024))
  run_backup "$T0" FAKE_AWS_SYNC=fail_all
  check_not "over 3 GiB the oldest goes" [ -e "$VOL/snapshots/$OLD_ID_1" ]
  check_eq "the newest stays" 1 "$(snapcount)"
}

b_limit_pinned_bytes_under_three_gib() {
  seed_live
  sparse_generation "$OLD_ID_1" $((2 * 1024 * 1024 * 1024 + 512 * 1024 * 1024))
  run_backup "$T0" FAKE_AWS_SYNC=fail_all
  check "under 3 GiB it stays" [ -d "$VOL/snapshots/$OLD_ID_1" ]
  check_eq "both remain" 2 "$(snapcount)"
  check "the metric counts it, not du" [ "$(metric_value skyeye_backup_snapshot_pinned_bytes)" -ge $((2 * 1024 * 1024 * 1024 + 512 * 1024 * 1024)) ]
}

b_limit_lone_snapshot_over_three_gib_goes_when_the_next_snapshot_fails() {
  seed_live
  sparse_generation "$OLD_ID_1" $((3 * 1024 * 1024 * 1024 + 512 * 1024 * 1024))
  mkdir -p "$VOL/snapshots/$APRIL_ID/$BLOCK_A"
  echo april >"$VOL/snapshots/$APRIL_ID/$BLOCK_A/index"
  run_backup "$T0" FAKE_CURL=down
  check_eq "the run failed at the snapshot" 2 "$RC"
  check_not "the 3 GiB limit has no spare: the only generation goes" [ -e "$VOL/snapshots/$OLD_ID_1" ]
  check_not "with its record" [ -e "$STATE/pending/$OLD_ID_1.json" ]
  check "an unrecorded directory still stays" [ -f "$VOL/snapshots/$APRIL_ID/$BLOCK_A/index" ]
  check "the metric is back under the limit" [ "$(metric_value skyeye_backup_snapshot_pinned_bytes)" -le $((3 * 1024 * 1024 * 1024)) ]
}

b_limit_lone_snapshot_under_three_gib_stays_when_the_next_snapshot_fails() {
  seed_live
  sparse_generation "$OLD_ID_1" $((2 * 1024 * 1024 * 1024 + 512 * 1024 * 1024))
  run_backup "$T0" FAKE_CURL=down
  check_eq "the run failed at the snapshot" 2 "$RC"
  check "under the limit it is kept" [ -d "$VOL/snapshots/$OLD_ID_1" ]
}

# Only the next run may give it up: this one is still trying to publish it.
b_limit_unpublished_snapshot_of_this_run_outlives_three_gib() {
  seed_live
  local hook="$SB/bloat-snapshot"
  printf '#!/bin/bash\ndd if=/dev/zero of="$1/bloat" bs=1 count=0 seek=%s 2>/dev/null\n' \
    $((3 * 1024 * 1024 * 1024 + 512 * 1024 * 1024)) >"$hook"
  chmod +x "$hook"
  run_backup "$T0" FAKE_AWS_SYNC=fail_all FAKE_AWS_SYNC_HOOK="$hook"
  check_eq "the upload failed" 4 "$RC"
  check_eq "over the limit, its own snapshot stays" 1 "$(snapcount)"
  check "and the metric says so" [ "$(metric_value skyeye_backup_snapshot_pinned_bytes)" -gt $((3 * 1024 * 1024 * 1024)) ]
  run_backup $((T0 + DAY)) FAKE_CURL=down
  check_eq "the next run failed at the snapshot" 2 "$RC"
  check_eq "now it is an old generation over the limit" 0 "$(snapcount)"
}

b_limit_low_water_keeps_the_newest() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=fail_all FAKE_DF_AVAIL_PCT=1
  check_eq "at 1% free the newest still stays" 1 "$(snapcount)"
}

b_limit_low_water_mark() {
  seed_live
  record_pending "$OLD_ID_1"
  run_backup "$T0" FAKE_AWS_SYNC=fail_all FAKE_DF_AVAIL_PCT=15
  check "at 15% free the older one stays" [ -d "$VOL/snapshots/$OLD_ID_1" ]
  run_backup $((T0 + 60)) FAKE_AWS_SYNC=fail_all FAKE_DF_AVAIL_PCT=14
  check_not "below 15% free only the newest stays" [ -e "$VOL/snapshots/$OLD_ID_1" ]
  check_eq "one left" 1 "$(snapcount)"
}

b_failing_df_deletes_nothing() {
  seed_live
  record_pending "$OLD_ID_1"
  run_backup "$T0" FAKE_AWS_SYNC=fail_all FAKE_DF_FAIL=1
  check "an unknown free space is not low disk" [ -d "$VOL/snapshots/$OLD_ID_1" ]
}

b_success_removes_older_pending() {
  seed_live
  record_pending "$OLD_ID_1"
  record_pending "$OLD_ID_2"
  run_backup "$T0" FAKE_AWS_SYNC=ok
  check_eq "backup succeeds" 0 "$RC"
  check_eq "older generations are covered" 0 "$(snapcount)"
  check_eq "their records go too" 0 "$(pending_records)"
}

b_success_keeps_a_newer_pending() {
  seed_live
  local future=20991231T235959Z-00000000000000ff
  record_pending "$future"
  run_backup "$T0" FAKE_AWS_SYNC=ok
  check "a generation newer than this run is not covered by it" [ -d "$VOL/snapshots/$future" ]
}

b_deletes_only_recorded_regex_named_dirs_in_snapshots() {
  seed_live
  # Left by the old script, or by anyone with access to the snapshot API.
  mkdir -p "$VOL/snapshots/$APRIL_ID/$BLOCK_A"
  echo april >"$VOL/snapshots/$APRIL_ID/$BLOCK_A/index"
  # A record, but not a name this script produces.
  mkdir -p "$VOL/snapshots/manual-copy" "$STATE/pending"
  echo keep >"$VOL/snapshots/manual-copy/file"
  printf '{"snapshot_id":"manual-copy"}\n' >"$STATE/pending/manual-copy.json"
  # A record whose content names something else.
  mkdir -p "$VOL/snapshots/$OLD_ID_1"
  echo keep >"$VOL/snapshots/$OLD_ID_1/file"
  printf '{"snapshot_id":"%s"}\n' "$OLD_ID_2" >"$STATE/pending/$OLD_ID_1.json"
  # A recorded name that is a symlink out of snapshots/.
  mkdir -p "$SB/outside"
  echo keep >"$SB/outside/file"
  ln -s "$SB/outside" "$VOL/snapshots/$OLD_ID_3"
  printf '{"snapshot_id":"%s"}\n' "$OLD_ID_3" >"$STATE/pending/$OLD_ID_3.json"

  run_backup "$T0" FAKE_AWS_SYNC=fail_all FAKE_DF_AVAIL_PCT=1
  run_backup $((T0 + DAY)) FAKE_AWS_SYNC=ok
  check_eq "backup succeeds" 0 "$RC"
  check "an unrecorded directory stays" [ -f "$VOL/snapshots/$APRIL_ID/$BLOCK_A/index" ]
  check "a directory named outside the regex stays" [ -f "$VOL/snapshots/manual-copy/file" ]
  check "a record for another id deletes nothing" [ -f "$VOL/snapshots/$OLD_ID_1/file" ]
  check "the symlink is not followed" [ -f "$SB/outside/file" ]
  check "the symlink itself stays" [ -L "$VOL/snapshots/$OLD_ID_3" ]
  check_eq "the leftovers count in the metric" 3 "$(metric_value skyeye_backup_pending_generations)"
  check "their bytes count in the metric" [ "$(metric_value skyeye_backup_snapshot_pinned_bytes)" -gt 0 ]
}

b_snapshots_symlink_is_not_deleted_through() {
  seed_live
  rmdir "$VOL/snapshots"
  mkdir -p "$SB/elsewhere/$OLD_ID_1" "$STATE/pending"
  echo keep >"$SB/elsewhere/$OLD_ID_1/file"
  ln -s "$SB/elsewhere" "$VOL/snapshots"
  printf '{"snapshot_id":"%s"}\n' "$OLD_ID_1" >"$STATE/pending/$OLD_ID_1.json"
  run_backup "$T0" FAKE_AWS_SYNC=ok
  check "snapshots/ being a symlink stops deletion" [ -f "$SB/elsewhere/$OLD_ID_1/file" ]
}

b_stale_record_is_dropped() {
  seed_live
  mkdir -p "$STATE/pending"
  printf '{"snapshot_id":"%s"}\n' "$OLD_ID_1" >"$STATE/pending/$OLD_ID_1.json"
  run_backup "$T0" FAKE_AWS_SYNC=fail_all
  check_not "a record without a directory goes" [ -e "$STATE/pending/$OLD_ID_1.json" ]
}

b_pinned_bytes_are_not_du() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=fail_all FAKE_HEAD_KB=8
  local hardlinked_only
  hardlinked_only="$(metric_value skyeye_backup_snapshot_pinned_bytes)"
  check_eq "only the head block is pinned while blocks are live" "$(pinned_bytes)" "$hardlinked_only"
  check "hardlinks to live blocks do not count" [ "$hardlinked_only" -lt $((64 * 1024)) ]
  tsdb_day "$BLOCK_A" "$BLOCK_A" "$BLOCK_A" "$BLOCK_E" 8
  run_backup $((T0 + DAY)) FAKE_CURL=down
  check "a block gone from live counts as pinned" [ "$(metric_value skyeye_backup_snapshot_pinned_bytes)" -gt $((256 * 1024)) ]
  check_eq "same as counting the inodes" "$(pinned_bytes)" "$(metric_value skyeye_backup_snapshot_pinned_bytes)"
}

b_metrics_match_the_rules() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=fail_all
  check_eq "attempt timestamp" "$T0" "$(metric_value skyeye_backup_last_attempt_timestamp_seconds)"
  check_eq "no success series before the first success" "" "$(metric_value skyeye_backup_last_success_timestamp_seconds)"
  check_eq "first failure" 1 "$(metric_value skyeye_backup_consecutive_failures)"
  run_backup $((T0 + DAY)) FAKE_AWS_SYNC=ok
  check_eq "success timestamp" $((T0 + DAY)) "$(metric_value skyeye_backup_last_success_timestamp_seconds)"
  check_eq "failures reset" 0 "$(metric_value skyeye_backup_consecutive_failures)"
  check_eq "exit code" 0 "$(metric_value skyeye_backup_last_exit_code)"
  local name
  while IFS= read -r name; do
    check "the script emits $name, which the rules read" logged "$STATE/metrics/skyeye_backup.prom" "^$name "
  done < <(grep -oE 'skyeye_backup_[a-z_]+' "$RULES_FILE" | sort -u)
  local declared
  for declared in last_attempt_timestamp_seconds last_success_timestamp_seconds last_exit_code \
    consecutive_failures pending_generations snapshot_pinned_bytes last_uploaded_bytes last_duration_seconds; do
    check "plan metric $declared is emitted" logged "$STATE/metrics/skyeye_backup.prom" "^skyeye_backup_$declared "
  done
  check_not "no labels in the file" logged "$STATE/metrics/skyeye_backup.prom" '^skyeye_backup_[a-z_]+\{'
  check "the push labels are job and instance" logged "$LOGDIR/docker-calls.log" \
    'docker exec -i skyeye-prometheus-1 /bin/promtool push metrics --label=job=skyeye-backup --label=instance=monitoring-prod http://127.0.0.1:9090/api/v1/write'
  run_backup $((T0 + 2 * DAY)) FAKE_CURL=down
  check_eq "a failure keeps the last success" $((T0 + DAY)) "$(metric_value skyeye_backup_last_success_timestamp_seconds)"
}

b_lost_state_file_invents_nothing() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=ok
  rm -f "${STATE:?}/state"
  run_backup $((T0 + DAY)) FAKE_CURL=down
  check_eq "no invented success sample that would hide the real one" "" "$(metric_value skyeye_backup_last_success_timestamp_seconds)"
  # shellcheck disable=SC2016 # the file is meant to hold this literally
  printf 'last_success=$(touch %s/pwned)\nconsecutive_failures=x\n' "$SB" >"$STATE/state"
  run_backup $((T0 + 2 * DAY)) FAKE_CURL=down
  check_not "the state file is data, not code" [ -e "$SB/pwned" ]
  check_eq "a corrupt counter restarts" 1 "$(metric_value skyeye_backup_consecutive_failures)"
}

b_metrics_push_failure_keeps_the_exit_code() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=ok FAKE_DOCKER_PUSH=fail
  check_eq "success stays success" 0 "$RC"
  check "the file is still written" [ -f "$STATE/metrics/skyeye_backup.prom" ]
  check "the warning reaches the log" logged "$RUNLOG" 'metrics push failed'
  run_backup $((T0 + DAY)) FAKE_CURL=down FAKE_DOCKER_PUSH=fail
  check_eq "failure stays that failure" 2 "$RC"
}

b_metrics_push_cannot_hang_the_run() {
  seed_live
  local shim="$SB/fast-timeout" real_timeout
  real_timeout="$(command -v timeout)"
  mkdir -p "$shim"
  # The 30 s bound is what is under test; only its length is scaled down.
  cat >"$shim/timeout" <<SHIM
#!/bin/bash
case " \$* " in
  *" push metrics "*) shift 3; exec "$real_timeout" -k 1 1 "\$@" ;;
esac
exec "$real_timeout" "\$@"
SHIM
  chmod +x "$shim/timeout"
  SBX_PATH="$shim:$SHIM_DIR:$TOOLS_DIR:/usr/bin:/bin" run_backup "$T0" FAKE_DOCKER_PUSH=hang
  check_eq "a stuck push does not change the result" 0 "$RC"
}

b_trap_reports_on_term() {
  seed_live
  SBX_EXEC="exec" sbx FAKE_NOW="$T0" FAKE_AWS_SYNC=hang -- /bin/bash "$NEW_BACKUP" >>"$RUNLOG" 2>&1 &
  local pid=$!
  check "the run reaches the upload" wait_for_log "$LOGDIR/aws-calls.log" 's3 sync'
  kill -TERM "$pid"
  wait "$pid"
  RC=$?
  check_eq "exits on TERM without waiting for the upload" 143 "$RC"
  check_eq "metrics are written" 143 "$(metric_value skyeye_backup_last_exit_code)"
  check_eq "the failure is counted" 1 "$(metric_value skyeye_backup_consecutive_failures)"
  check "the metrics are pushed" logged "$LOGDIR/pushed.prom" '^skyeye_backup_last_exit_code 143'
  check_eq "the pending snapshot stays" 1 "$(snapcount)"
}

b_trap_reports_unexpected_failure() {
  seed_live
  local bin="$SB/broken-jq"
  mkdir -p "$bin"
  # A step with no error handling of its own: the set -e path, not a fail call.
  cat >"$bin/jq" <<SHIM
#!/bin/bash
case "\$*" in "-r .total_bytes "*) exit 42 ;; esac
exec "$(command -v jq)" "\$@"
SHIM
  chmod +x "$bin/jq"
  SBX_PATH="$bin:$SHIM_DIR:$TOOLS_DIR:/usr/bin:/bin" run_backup "$T0"
  check_eq "the failure surfaces as itself" 42 "$RC"
  check_eq "and reaches the metric" 42 "$(metric_value skyeye_backup_last_exit_code)"
}

b_trap_reports_when_state_dir_is_unusable() {
  seed_live
  : >"$SB/not-a-dir"
  run_backup "$T0" SKYEYE_BACKUP_STATE_DIR="$SB/not-a-dir/state"
  check_eq "reported as a host problem" 8 "$RC"
  check "metrics are still pushed" logged "$LOGDIR/pushed.prom" '^skyeye_backup_last_exit_code 8'
  check_not "no snapshot without a place to record it" logged "$LOGDIR/curl-calls.log" 'snapshot'
}

b_trap_reports_a_missing_tool() {
  seed_live
  local bin="$SB/minimal-bin" tool
  mkdir -p "$bin"
  for tool in awk basename cat chmod cut dirname env find flock git mkdir mktemp mv rm sed sha256sum sort tail timeout tr uname wc; do
    if [ -e "$TOOLS_DIR/$tool" ]; then
      ln -s "$TOOLS_DIR/$tool" "$bin/$tool"
    elif command -v "$tool" >/dev/null 2>&1; then
      ln -s "$(command -v "$tool")" "$bin/$tool"
    fi
  done
  [ ! -e "$TOOLS_DIR/python3" ] || ln -s "$TOOLS_DIR/python3" "$bin/python3"
  ln -s "$REAL_STAT" "$bin/stat"
  ln -s /bin/sh "$bin/sh"
  for tool in aws curl date df docker sleep; do ln -s "$SHIM_DIR/$tool" "$bin/$tool"; done
  SBX_PATH="$bin" run_backup "$T0"
  check_eq "no jq is a host problem" 8 "$RC"
  check "the log names it" logged "$RUNLOG" 'jq is not installed'
  check_eq "reported without jq" 8 "$(metric_value skyeye_backup_last_exit_code)"
  check_not "no snapshot is taken" logged "$LOGDIR/curl-calls.log" 'snapshot'
}

b_lock_busy_touches_nothing() {
  seed_live
  SBX_EXEC="exec" sbx FAKE_NOW="$T0" FAKE_AWS_SYNC=hang -- /bin/bash "$NEW_BACKUP" >>"$RUNLOG" 2>&1 &
  local pid=$!
  check "the first run reaches the upload" wait_for_log "$LOGDIR/aws-calls.log" 's3 sync'
  local before
  before="$(ls "$VOL/snapshots")"
  run_backup $((T0 + 60))
  check_eq "the second run exits with its own code" 75 "$RC"
  check_eq "snapshots are untouched" "$before" "$(ls "$VOL/snapshots")"
  check_eq "it does not count as a failure" 0 "$(metric_value skyeye_backup_consecutive_failures)"
  check_eq "it still reports" $((T0 + 60)) "$(metric_value skyeye_backup_last_attempt_timestamp_seconds)"
  kill -TERM "$pid"
  wait "$pid"
}

b_works_under_the_existing_cron_line() {
  seed_live
  check "the file cron runs is executable" [ -x "$NEW_BACKUP" ]
  # The installed cron line starts the file directly, with cron's own PATH.
  SBX_PATH="$SHIM_DIR:$TOOLS_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    sbx FAKE_NOW="$T0" SHELL=/bin/bash SKYEYE_BACKUP_STATE_DIR="$SB/fresh/var/lib/skyeye-backup" \
    -- "$NEW_BACKUP" >>"$RUNLOG" 2>&1
  RC=$?
  check_eq "runs without any setup" 0 "$RC"
  check "creates its own state directory" [ -d "$SB/fresh/var/lib/skyeye-backup/pending" ]
  check "the log keeps the line the runbook looks for" logged "$RUNLOG" '==> backup OK: generations/'
}

b_defaults_match_the_plan() {
  check "state stays out of the checkout" grep -q 'SKYEYE_BACKUP_STATE_DIR:-/var/lib/skyeye-backup}' "$NEW_BACKUP"
  check "volume path" grep -q 'SKYEYE_BACKUP_VOL_PATH:-/var/lib/docker/volumes/skyeye_prometheus_data/_data}' "$NEW_BACKUP"
  check "bucket" grep -q 'SKYEYE_BACKUP_BUCKET:-skyeye-prometheus-snapshots}' "$NEW_BACKUP"
  check "90 minute total timeout" grep -q 'SKYEYE_BACKUP_TOTAL_TIMEOUT:-5400}' "$NEW_BACKUP"
  check "pending limit" grep -Eq '^MAX_PENDING=2( |$)' "$NEW_BACKUP"
  check "low water mark" grep -Eq '^LOW_WATER_PCT=15( |$)' "$NEW_BACKUP"
}
