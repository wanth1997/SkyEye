# shellcheck shell=bash
# Every failure scenario of plan section 4, plus the overlap and stuck-upload gaps.
# Each one runs twice: against the script at the base commit, where it has to fail,
# and against the new one, where it has to pass. The first run keeps the second
# honest: a scenario that passes on the old code proves nothing.

s1_failed_runs_leave_nothing_behind() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=fail_all
  check "day 1 failure is reported" [ "$RC" -ne 0 ]
  check_eq "day 1 keeps its snapshot" 1 "$(snapcount)"
  tsdb_day "$BLOCK_A" "$BLOCK_C" "$BLOCK_D" "$BLOCK_E" 128
  run_backup $((T0 + DAY)) FAKE_AWS_SYNC=fail_all
  check_eq "day 2 keeps both snapshots" 2 "$(snapcount)"
  tsdb_day "$BLOCK_B" "$BLOCK_E" "$BLOCK_E" "$BLOCK_F" 256
  run_backup $((T0 + 2 * DAY)) FAKE_AWS_SYNC=ok
  check_eq "day 3 succeeds" 0 "$RC"
  check_eq "day 3 cleans what the failures left" 0 "$(snapcount)"
  run_backup $((T0 + 3 * DAY)) FAKE_AWS_SYNC=ok
  check_eq "day 4 succeeds" 0 "$RC"
  check_eq "nothing is pinned after two clean days" 0 "$(pinned_bytes)"
}

s2_partial_upload_is_distinguishable() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=ok
  run_backup $((T0 + DAY)) FAKE_AWS_SYNC=fail_after:3
  check "the partial day reports failure" [ "$RC" -ne 0 ]
  check_eq "only the full upload has a manifest" 1 "$(manifest_count)"
  if [ "$IMPL" = new ]; then
    local full partial
    full="$(latest_generation)"
    partial="$(basename "$(find "$BUCKET_DIR/generations/2026-11-02" -mindepth 1 -maxdepth 1 -type d)")"
    run_restore -- list
    check "list shows the complete generation" logged "$OUT" "^$full "
    check_not "list hides the partial prefix" logged "$OUT" "$partial"
  fi
}

s3a_same_day_reruns_stay_separate() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=ok
  tsdb_day "$BLOCK_A" "$BLOCK_C" "$BLOCK_D" "$BLOCK_E" 128
  run_backup $((T0 + 3600)) FAKE_AWS_SYNC=ok
  local most_heads
  most_heads="$(find "$BUCKET_DIR" -type d -name '01HEAD*' | while IFS= read -r d; do dirname "$d"; done |
    sort | uniq -c | awk '$1 > m { m = $1 } END { print m + 0 }')"
  check_eq "one head block per prefix, never two overlapping" 1 "$most_heads"
  local parent_and_child
  parent_and_child="$(find "$BUCKET_DIR" -type d -name "$BLOCK_E" | while IFS= read -r d; do
    [ -d "$(dirname "$d")/$BLOCK_C" ] && echo mixed
  done | wc -l | tr -d ' ')"
  check_eq "a compacted block never sits next to its parents" 0 "$parent_and_child"
}

s3b_rerun_cannot_bless_a_dead_block() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=fail_after:2
  tsdb_day "$BLOCK_A" "$BLOCK_C" "$BLOCK_D" "$BLOCK_E" 128
  run_backup $((T0 + 3600)) FAKE_AWS_SYNC=ok
  check_eq "the rerun succeeds" 0 "$RC"
  local prefix any=0
  while IFS= read -r prefix; do
    any=1
    check "every block of $(basename "$prefix") is whole" every_block_intact "$prefix"
  done < <(complete_prefixes)
  check_eq "a complete prefix exists" 1 "$any"
}

s4a_failed_download_leaves_live_data_alone() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=ok
  local before
  before="$(live_hash)"
  : >"$LOGDIR/docker-calls.log"
  if [ "$IMPL" = legacy ]; then
    sbx FAKE_NOW="$T0" FAKE_AWS_DOWNLOAD=fail_all -- /bin/bash "$(legacy_restore_script 2026-11-01)" >>"$RUNLOG" 2>&1
    RC=$?
  else
    run_restore FAKE_AWS_DOWNLOAD=fail_all -- fetch "$(latest_generation)"
  fi
  check "a failed download is reported" [ "$RC" -ne 0 ]
  check_eq "live data is unchanged" "$before" "$(live_hash)"
  check "snapshots/ survives" [ -d "$VOL/snapshots" ]
  check_not "Prometheus is not restarted" logged "$LOGDIR/docker-calls.log" 'compose.* up '
}

s4b_partial_prefix_is_refused() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=fail_after:6
  local before id
  before="$(live_hash)"
  : >"$LOGDIR/docker-calls.log"
  if [ "$IMPL" = legacy ]; then
    sbx FAKE_NOW="$T0" -- /bin/bash "$(legacy_restore_script 2026-11-01)" >>"$RUNLOG" 2>&1
    RC=$?
  else
    id="$(basename "$(find "$BUCKET_DIR/generations/2026-11-01" -mindepth 1 -maxdepth 1 -type d)")"
    run_restore -- fetch "$id"
  fi
  check "restoring a partial prefix is refused" [ "$RC" -ne 0 ]
  check_eq "live data is unchanged" "$before" "$(live_hash)"
  check_not "Prometheus is not restarted" logged "$LOGDIR/docker-calls.log" 'compose.* up '
}

s5a_failed_listing_does_not_cost_the_snapshot() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=ok FAKE_AWS_LS=fail
  if [ "$RC" -ne 0 ]; then
    check_eq "a run reported failed keeps its snapshot" 1 "$(snapcount)"
  fi
  check "the failure reaches a metric" logged "$STATE/metrics/skyeye_backup.prom" '^skyeye_backup_last_exit_code [1-9]'
}

s5b_prometheus_down_is_visible() {
  seed_live
  run_backup "$T0" FAKE_CURL=down
  check "the failure is reported" [ "$RC" -ne 0 ]
  check_eq "the exit code is in a metric" 2 "$(metric_value skyeye_backup_last_exit_code)"
  check_eq "the failure is counted" 1 "$(metric_value skyeye_backup_consecutive_failures)"
}

s5c_admin_api_refusal_is_visible() {
  seed_live
  run_backup "$T0" FAKE_CURL=http503
  check "the failure is reported" [ "$RC" -ne 0 ]
  check_eq "the exit code is in a metric" 2 "$(metric_value skyeye_backup_last_exit_code)"
  check_eq "the failure is counted" 1 "$(metric_value skyeye_backup_consecutive_failures)"
}

gap_overlapping_runs_do_not_snapshot_twice() {
  seed_live
  SBX_EXEC="exec" sbx FAKE_NOW="$T0" FAKE_AWS_SYNC=hang -- timeout 15 /bin/bash "$(under_test)" >>"$RUNLOG" 2>&1 &
  local first=$!
  check "the first run reaches the upload" wait_for_log "$LOGDIR/aws-calls.log" 's3 sync'
  run_backup $((T0 + 60)) FAKE_AWS_SYNC=ok
  kill -TERM "$first" 2>/dev/null
  wait "$first" 2>/dev/null
  check_eq "the second run takes no snapshot" 1 "$(grep -c 'admin/tsdb/snapshot' "$LOGDIR/curl-calls.log")"
}

gap_stuck_upload_ends() {
  seed_live
  sbx FAKE_NOW="$T0" FAKE_AWS_SYNC=hang SKYEYE_BACKUP_TOTAL_TIMEOUT=2 -- timeout 6 /bin/bash "$(under_test)" >>"$RUNLOG" 2>&1
  RC=$?
  check_eq "the total timeout ends the run with its own code" 7 "$RC"
}
