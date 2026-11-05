# shellcheck shell=bash
# scripts/restore-prometheus.sh, against generations made by the real backup script.

make_generation() {
  seed_live
  run_backup "$T0" FAKE_AWS_SYNC=ok
  [ "$RC" -eq 0 ] || printf '    fixture backup failed rc=%s\n' "$RC"
  GEN="$(latest_generation)"
  GEN_DIR="$(generation_dir "$GEN")"
  STAGE="$SB/restore/$GEN"
  : >"$LOGDIR/docker-calls.log"
}

fetched_generation() {
  make_generation
  run_restore -- fetch "$GEN"
  [ "$RC" -eq 0 ] || printf '    fixture fetch failed rc=%s\n' "$RC"
}

verified_generation() {
  fetched_generation
  run_restore -- verify "$GEN"
  [ "$RC" -eq 0 ] || printf '    fixture verify failed rc=%s\n' "$RC"
  : >"$LOGDIR/docker-calls.log"
}

parked_dirs() {
  find "$SB/volume" -mindepth 1 -maxdepth 1 -name '_data.pre-restore-*'
}

r_list_shows_only_complete_generations() {
  make_generation
  run_backup $((T0 + DAY)) FAKE_AWS_CP=fail
  mkdir -p "$BUCKET_DIR/2026-10-30/$BLOCK_A"
  echo legacy >"$BUCKET_DIR/2026-10-30/$BLOCK_A/index"
  local no_manifest incomplete_dir incomplete
  no_manifest="$(basename "$(find "$BUCKET_DIR/generations/2026-11-02" -mindepth 1 -maxdepth 1 -type d)")"
  incomplete=20261101T210000Z-00000000000000cc
  incomplete_dir="$BUCKET_DIR/generations/2026-11-01/$incomplete"
  mkdir -p "$incomplete_dir"
  jq --arg id "$incomplete" '.snapshot_id = $id' "$GEN_DIR/MANIFEST.json" >"$incomplete_dir/MANIFEST.json"

  run_restore -- list
  check_eq "list succeeds" 0 "$RC"
  check "the complete generation is listed" logged "$OUT" "^$GEN +2026-11-01T19:00:00Z +[0-9]+ +5$"
  check_not "a prefix without manifest is not listed" logged "$OUT" "^$no_manifest"
  check_not "a legacy prefix is not listed" logged "$OUT" '2026-10-30'
  check_not "a manifest over missing objects is not listed" logged "$OUT" "^$incomplete"
  check "the operator is told why" logged "$OUT" "WARN: $incomplete not listed"
}

r_list_failure_is_not_an_empty_list() {
  make_generation
  run_restore FAKE_AWS_LS=fail -- list
  check "a failed listing is an error" [ "$RC" -ne 0 ]
}

r_fetch_refuses_bad_input() {
  make_generation
  local before
  before="$(live_hash)"
  run_restore -- fetch
  check_eq "no id" 2 "$RC"
  run_restore -- fetch ../../etc
  check_eq "a path as id" 2 "$RC"
  run_restore -- fetch 2026-11-01
  check_eq "a legacy date without the flag" 2 "$RC"
  run_restore -- fetch "$GEN" --legacy-prefix 2026-11-01
  check_eq "id and legacy together" 2 "$RC"
  run_restore -- fetch --legacy-prefix ../x
  check_eq "a path as legacy prefix" 2 "$RC"
  run_restore -- bogus
  check_eq "an unknown command" 2 "$RC"
  check_eq "live data is unchanged" "$before" "$(live_hash)"
}

r_fetch_refuses_a_prefix_without_manifest() {
  make_generation
  rm -f "${GEN_DIR:?}/MANIFEST.json"
  run_restore -- fetch "$GEN"
  check_eq "no manifest, no fetch" 3 "$RC"
  check_not "nothing is downloaded" logged "$LOGDIR/aws-calls.log" 'sync .*s3://[^ ]+ /'
}

r_fetch_refuses_an_invalid_manifest() {
  make_generation
  local original="$SB/manifest.original"
  cp "$GEN_DIR/MANIFEST.json" "$original"
  jq '.snapshot_id = "20200101T000000Z-0000000000000000"' "$original" >"$GEN_DIR/MANIFEST.json"
  run_restore -- fetch "$GEN"
  check_eq "a manifest for another generation" 4 "$RC"
  jq '.files[0].path = "../../outside"' "$original" >"$GEN_DIR/MANIFEST.json"
  run_restore -- fetch "$GEN"
  check_eq "a path escaping the staging directory" 4 "$RC"
  printf '{not json' >"$GEN_DIR/MANIFEST.json"
  run_restore -- fetch "$GEN"
  check_eq "a corrupt manifest" 4 "$RC"
}

r_fetch_preflights_disk_space() {
  make_generation
  local total need_kb
  total="$(jq '.total_bytes' "$GEN_DIR/MANIFEST.json")"
  need_kb=$(((total * 2 + 1024 * 1024 * 1024) / 1024 + 1))
  run_restore FAKE_DF_TOTAL_KB=$((need_kb - 2)) FAKE_DF_AVAIL_PCT=100 -- fetch "$GEN"
  check_eq "below twice the size plus 1 GiB" 5 "$RC"
  check_not "nothing is downloaded" logged "$LOGDIR/aws-calls.log" 'sync .*s3://[^ ]+ /'
  run_restore FAKE_DF_TOTAL_KB="$need_kb" FAKE_DF_AVAIL_PCT=100 -- fetch "$GEN"
  check_eq "exactly enough is enough" 0 "$RC"
}

r_fetch_midway_failure_touches_nothing_live() {
  make_generation
  local before
  before="$(live_hash)"
  run_restore FAKE_AWS_DOWNLOAD=fail_after:3 -- fetch "$GEN"
  check_eq "a download cut midway is an error" 6 "$RC"
  check_eq "live data is unchanged" "$before" "$(live_hash)"
  check_eq "Prometheus is not touched" 0 "$(wc -l <"$LOGDIR/docker-calls.log" | tr -d ' ')"
  run_restore -- verify "$GEN"
  check_eq "what it left does not verify" 7 "$RC"
  run_restore -- switch "$GEN" --yes
  check_eq "and cannot be switched to" 2 "$RC"
  check_eq "live data is still unchanged" "$before" "$(live_hash)"
}

r_fetch_again_replaces_a_stale_staging_copy() {
  fetched_generation
  echo stale >"$STAGE/data/stale-file"
  run_restore -- fetch "$GEN"
  check_eq "fetch succeeds" 0 "$RC"
  check_not "the old copy is gone" [ -e "$STAGE/data/stale-file" ]
  run_restore -- verify "$GEN"
  check_eq "and verifies" 0 "$RC"
}

r_fetch_needs_the_same_filesystem() {
  make_generation
  run_restore FAKE_STAT_OTHER_DEVICE="$SB/restore" -- fetch "$GEN"
  check_eq "staging on another filesystem is refused early" 2 "$RC"
  check "the reason is given" logged "$OUT" 'rename, not a copy'
}

r_verify_names_a_missing_chunk() {
  make_generation
  rm -f "${GEN_DIR:?}/$BLOCK_B/chunks/000001"
  run_restore -- fetch "$GEN"
  check_eq "fetch itself has nothing to complain about" 0 "$RC"
  run_restore -- verify "$GEN"
  check_eq "verify rejects it" 7 "$RC"
  check "and names the file" logged "$OUT" "MISSING $BLOCK_B/chunks/000001"
  check_not "no approval is left behind" [ -e "$STAGE/VERIFIED" ]
}

r_verify_rejects_a_truncated_index() {
  make_generation
  local index="$GEN_DIR/$BLOCK_A/index"
  head -c 100 "$index" >"$index.cut"
  mv "$index.cut" "$index"
  run_restore -- fetch "$GEN"
  run_restore -- verify "$GEN"
  check_eq "verify rejects it" 7 "$RC"
  check "by sha256" logged "$OUT" "SHA256 $BLOCK_A/index"
  check "and size" logged "$OUT" "SIZE $BLOCK_A/index"
}

r_verify_rejects_a_same_size_corruption() {
  make_generation
  local index="$GEN_DIR/$BLOCK_A/index" size
  size="$(wc -c <"$index" | tr -d ' ')"
  dd if=/dev/urandom of="$index" bs=1 count="$size" 2>/dev/null
  run_restore -- fetch "$GEN"
  run_restore -- verify "$GEN"
  check_eq "verify rejects it" 7 "$RC"
  check "by sha256 alone" logged "$OUT" "SHA256 $BLOCK_A/index"
  check_not "the size was fine" logged "$OUT" "SIZE $BLOCK_A/index"
}

r_verify_rejects_extra_files() {
  fetched_generation
  echo extra >"$STAGE/data/$BLOCK_A/extra"
  run_restore -- verify "$GEN"
  check_eq "a file the manifest does not have" 7 "$RC"
  check "is named" logged "$OUT" "EXTRA $BLOCK_A/extra"
}

r_verify_checks_each_block_not_just_promtool() {
  # A manifest hand-trimmed along with the block: the hashes all match and promtool
  # exits 0 on a block without meta.json, so only the per-block check can catch this.
  make_generation
  local manifest="$GEN_DIR/MANIFEST.json"
  rm -f "${GEN_DIR:?}/$BLOCK_C/meta.json"
  jq --arg p "$BLOCK_C/meta.json" '.files |= map(select(.path != $p))' "$manifest" >"$manifest.new"
  mv "$manifest.new" "$manifest"
  run_restore -- fetch "$GEN"
  run_restore -- verify "$GEN"
  check_eq "a block without meta.json is rejected" 7 "$RC"
  check "by name" logged "$OUT" "MISSING $BLOCK_C/meta.json"
}

r_verify_rejects_a_block_outside_the_manifest() {
  fetched_generation
  mkdir -p "$STAGE/data/$BLOCK_F/chunks"
  run_restore -- verify "$GEN"
  check_eq "a block directory the manifest does not have" 7 "$RC"
  check "is named" logged "$OUT" "EXTRA block $BLOCK_F"
}

r_verify_runs_promtool_read_only_with_the_pinned_image() {
  make_generation
  jq '.prometheus_image = "attacker/image:latest"' "$GEN_DIR/MANIFEST.json" >"$GEN_DIR/MANIFEST.json.new"
  mv "$GEN_DIR/MANIFEST.json.new" "$GEN_DIR/MANIFEST.json"
  run_restore -- fetch "$GEN"
  run_restore -- verify "$GEN"
  check_eq "verify passes" 0 "$RC"
  local call
  call="$(grep ' run ' "$LOGDIR/docker-calls.log")"
  check "the image comes from the tool, not from S3" logged "$LOGDIR/docker-calls.log" ' prom/prometheus:v2.54.1 tsdb list /db'
  check_not "never the manifest's" logged "$LOGDIR/docker-calls.log" 'attacker/image'
  check "no network" logged "$LOGDIR/docker-calls.log" '--network none'
  check_eq "every block is mounted read-only" 5 "$(printf '%s\n' "$call" | grep -oE ':/db/[0-9A-Z]{26}:ro' | wc -l | tr -d ' ')"
  check_not "the data directory is not mounted as a whole" logged "$LOGDIR/docker-calls.log" '/data:/db'
  check "ownership goes to nobody" logged "$LOGDIR/chown-calls.log" 'chown -R 65534:65534 .*/data$'
}

r_verify_reads_every_sample_of_every_block() {
  fetched_generation
  run_restore -- verify "$GEN"
  check_eq "verify passes" 0 "$RC"
  check_eq "every block is read" 5 "$(wc -l <"$LOGDIR/dump-reads.log" | tr -d ' ')"
  check "the total is announced first" logged "$OUT" 'reading 4100 samples in 5 blocks'
  check "read-only, no network, one CPU, sandbox in the container" logged "$LOGDIR/docker-calls.log" \
    'run --rm --network none --cpus=1 --entrypoint /bin/sh -v .*/check:/check:ro prom/prometheus:v2.54.1 -c promtool tsdb dump --sandbox-dir-root=/tmp /check \| wc -l'
  check_not "the view is gone" [ -e "$STAGE/check" ]
}

r_verify_rejects_a_block_that_reads_short() {
  # What a chunk segment lost at the tail looks like: dump exits 0 with less output.
  fetched_generation
  run_restore "FAKE_DUMP_SHORT=$BLOCK_B" -- verify "$GEN"
  check_eq "the sample count rejects it, not the exit code" 7 "$RC"
  check "with the block and the counts" logged "$OUT" "$BLOCK_B: read 500 of 1000 samples"
  check_not "no approval" [ -e "$STAGE/VERIFIED" ]
  check_not "the view is gone" [ -e "$STAGE/check" ]
  run_restore -- switch "$GEN" --yes
  check_eq "and no switch" 2 "$RC"
}

r_verify_is_not_fooled_by_tombstones() {
  seed_live
  printf 'tombstone' >"$VOL/$BLOCK_A/tombstones"
  run_backup "$T0" FAKE_AWS_SYNC=ok
  GEN="$(latest_generation)"
  STAGE="$SB/restore/$GEN"
  run_restore -- fetch "$GEN"
  run_restore -- verify "$GEN"
  check_eq "a block with deletions is not a short read" 0 "$RC"
  check_eq "tombstones stay in the staged data" tombstone "$(cat "$STAGE/data/$BLOCK_A/tombstones")"
}

r_verify_leaves_the_staged_files_alone() {
  fetched_generation
  local before
  before="$(cd "$STAGE/data" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done | sha256sum)"
  run_restore -- verify "$GEN"
  check_eq "staged files are byte for byte the same" "$before" \
    "$(cd "$STAGE/data" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done | sha256sum)"
  check_eq "nothing was added to the data directory" 5 "$(find "$STAGE/data" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
}

gap_block() { # a block ten hours after the others
  mk_block "$BLOCK_F" 8 $((1790000000000 + 36000000))
}

r_verify_reads_everything_before_stopping_on_a_gap() {
  seed_live
  gap_block
  run_backup "$T0" FAKE_AWS_SYNC=ok FAKE_HEAD_MIN=$((1790000000000 + 36000000)) FAKE_HEAD_MAX=$((1790000000000 + 36900000))
  GEN="$(latest_generation)"
  STAGE="$SB/restore/$GEN"
  run_restore -- fetch "$GEN"
  run_restore -- verify "$GEN"
  check_eq "a gap stops verify" 7 "$RC"
  check "the timeline shows it" logged "$OUT" '^GAP 2026-'
  check_eq "after every block was read" 6 "$(wc -l <"$LOGDIR/dump-reads.log" | tr -d ' ')"
  check "the timeline comes before the read" awk '/^GAP/{g=NR} /==> reading/{r=NR} END{exit !(g && r && g<r)}' "$OUT"
  check_not "no approval" [ -e "$STAGE/VERIFIED" ]
  run_restore "FAKE_DUMP_SHORT=$BLOCK_B" -- verify "$GEN" --accept-gaps
  check_eq "accepting the gap does not skip the read" 7 "$RC"
  check "the read failure stops it" logged "$OUT" "$BLOCK_B: read 500 of 1000"
  check_not "no approval" [ -e "$STAGE/VERIFIED" ]
  : >"$LOGDIR/dump-reads.log"
  run_restore -- verify "$GEN" --accept-gaps
  check_eq "with a clean read, the operator may accept the gap" 0 "$RC"
  check_eq "every block was read again" 6 "$(wc -l <"$LOGDIR/dump-reads.log" | tr -d ' ')"
}

r_verify_read_failure_comes_before_the_gap_message() {
  seed_live
  gap_block
  run_backup "$T0" FAKE_AWS_SYNC=ok FAKE_HEAD_MIN=$((1790000000000 + 36000000)) FAKE_HEAD_MAX=$((1790000000000 + 36900000))
  GEN="$(latest_generation)"
  run_restore -- fetch "$GEN"
  run_restore "FAKE_DUMP_SHORT=$BLOCK_B" -- verify "$GEN"
  check_eq "rejected" 7 "$RC"
  check "by the read" logged "$OUT" "$BLOCK_B: read 500"
  check_not "not by the gap" logged "$OUT" 'timeline has gaps'
}

r_verify_rejects_a_hole_in_the_chunk_numbering() {
  fetched_generation
  cp "$STAGE/data/$BLOCK_A/chunks/000001" "$STAGE/data/$BLOCK_A/chunks/000003"
  cp "$STAGE/MANIFEST.json" "$SB/m"
  jq --arg p "$BLOCK_A/chunks/000003" --arg s "$(sha256sum "$STAGE/data/$BLOCK_A/chunks/000003" | cut -d' ' -f1)" \
    --argjson n "$(wc -c <"$STAGE/data/$BLOCK_A/chunks/000003" | tr -d ' ')" \
    '.files += [{path: $p, size: $n, sha256: $s}]' "$SB/m" >"$STAGE/MANIFEST.json"
  run_restore -- verify "$GEN"
  check_eq "two files, the last numbered 3" 7 "$RC"
  check "named" logged "$OUT" "MISSING $BLOCK_A/chunks: last segment is 000003 of 2 files"
}

r_verify_rejects_a_meta_json_for_another_block() {
  make_generation
  cp "$GEN_DIR/$BLOCK_A/meta.json" "$SB/meta.a"
  local legacy=2026-11-03 block
  mkdir -p "$BUCKET_DIR/$legacy"
  for block in "$BLOCK_A" "$BLOCK_B"; do cp -R "$GEN_DIR/$block" "$BUCKET_DIR/$legacy/$block"; done
  cp "$SB/meta.a" "$BUCKET_DIR/$legacy/$BLOCK_B/meta.json"
  run_restore -- fetch --legacy-prefix "$legacy"
  run_restore -- verify --legacy-prefix "$legacy"
  check_eq "rejected" 7 "$RC"
  check "named" logged "$OUT" "BAD $BLOCK_B/meta.json"
}

r_verify_rejects_a_stray_entry_under_a_legacy_prefix() {
  make_generation
  local legacy=2026-11-03
  mkdir -p "$BUCKET_DIR/$legacy"
  cp -R "$GEN_DIR/$BLOCK_A" "$BUCKET_DIR/$legacy/$BLOCK_A"
  echo stray >"$BUCKET_DIR/$legacy/stray"
  run_restore -- fetch --legacy-prefix "$legacy"
  run_restore -- verify --legacy-prefix "$legacy"
  check_eq "rejected" 7 "$RC"
  check "named" logged "$OUT" 'EXTRA block stray'
}

r_verify_rejects_a_promtool_failure() {
  fetched_generation
  run_restore FAKE_PROMTOOL=fail -- verify "$GEN"
  check_eq "blocks promtool cannot open" 7 "$RC"
  check "show its error" logged "$OUT" 'fake promtool: block corrupted'
  check_not "and are not approved" [ -e "$STAGE/VERIFIED" ]
}

r_switch_preconditions() {
  fetched_generation
  local before
  before="$(live_hash)"
  run_restore -- switch "$GEN" --yes
  check_eq "not verified" 2 "$RC"
  run_restore -- verify "$GEN"
  : >"$LOGDIR/docker-calls.log"
  run_restore -- switch "$GEN"
  check_eq "no --yes" 2 "$RC"
  cp "$STAGE/MANIFEST.json" "$SB/manifest.kept"
  jq '.total_bytes = 1' "$SB/manifest.kept" >"$STAGE/MANIFEST.json"
  run_restore -- switch "$GEN" --yes
  check_eq "staging changed after verify" 2 "$RC"
  cp "$SB/manifest.kept" "$STAGE/MANIFEST.json"
  run_restore FAKE_STAT_OTHER_DEVICE="$SB/restore" -- switch "$GEN" --yes
  check_eq "another filesystem" 2 "$RC"
  check_eq "live data is unchanged" "$before" "$(live_hash)"
  check_eq "Prometheus is not touched" 0 "$(wc -l <"$LOGDIR/docker-calls.log" | tr -d ' ')"
}

running_backup() { # an upload that hangs, until stop_backup
  : >"$LOGDIR/aws-calls.log"
  SBX_EXEC="exec" sbx FAKE_NOW="$T0" FAKE_AWS_SYNC=hang -- /bin/bash "$NEW_BACKUP" >>"$RUNLOG" 2>&1 &
  BACKUP_PID=$!
  check "a backup is uploading" wait_for_log "$LOGDIR/aws-calls.log" 's3 sync'
}

stop_backup() {
  kill -TERM "$BACKUP_PID"
  wait "$BACKUP_PID"
}

r_switch_waits_for_a_running_backup() {
  verified_generation
  running_backup
  local before
  before="$(live_hash)"
  run_restore -- switch "$GEN" --yes
  check_eq "switch does not race the backup" 2 "$RC"
  check_eq "live data is unchanged" "$before" "$(live_hash)"
  stop_backup
}

r_rollback_waits_for_a_running_backup() {
  verified_generation
  run_restore -- switch "$GEN" --yes
  local parked before
  parked="$(parked_dirs)"
  running_backup
  before="$(live_hash)"
  : >"$LOGDIR/docker-calls.log"
  run_restore -- rollback
  check_eq "rollback does not pull _data away from the upload" 2 "$RC"
  check "the reason is given" logged "$OUT" 'a backup is running'
  check_eq "live data stays" "$before" "$(live_hash)"
  check "the previous data stays parked" [ -d "$parked" ]
  check_not "Prometheus is not stopped" logged "$LOGDIR/docker-calls.log" ' stop '
  stop_backup
  run_restore -- rollback
  check_eq "once the backup is over it goes through" 0 "$RC"
}

r_finalize_waits_for_a_running_backup() {
  verified_generation
  run_restore -- switch "$GEN" --yes
  local parked
  parked="$(parked_dirs)"
  running_backup
  NOW=$((T0 + DAY)) run_restore -- finalize --yes
  check_eq "finalize does not run beside a backup" 2 "$RC"
  check "the reason is given" logged "$OUT" 'a backup is running'
  check "the previous data stays" [ -d "$parked" ]
  stop_backup
}

r_finalize_waits_for_a_running_rollback() {
  verified_generation
  local before parked
  before="$(live_hash)"
  run_restore -- switch "$GEN" --yes
  parked="$(parked_dirs)"
  start_restore FAKE_DOCKER_STOP_HOOK="$(pause_hook stop)" -- rollback
  check "the rollback is under way" wait_for_file "$LOGDIR/stop.reached"
  NOW=$((T0 + DAY)) run_restore -- finalize --yes
  check_eq "finalize cannot delete what rollback is moving back" 2 "$RC"
  check "the reason is given" logged "$OUT" 'another restore command'
  check "the previous data is still there" [ -d "$parked" ]
  release_pause stop
  finish_held
  check_eq "the rollback finishes" 0 "$HELD_RC"
  check_eq "live data is the old data" "$before" "$(live_hash)"
}

r_fetch_and_verify_wait_for_a_running_switch() {
  verified_generation
  start_restore FAKE_DOCKER_STOP_HOOK="$(pause_hook stop)" -- switch "$GEN" --yes
  check "the switch is under way" wait_for_file "$LOGDIR/stop.reached"
  run_restore -- fetch "$GEN"
  check_eq "fetch cannot replace the staging directory under a switch" 2 "$RC"
  check "the reason is given" logged "$OUT" 'another restore command'
  check "the approval stays" [ -f "$STAGE/VERIFIED" ]
  run_restore -- verify "$GEN"
  check_eq "neither can verify" 2 "$RC"
  check "the approval still stays" [ -f "$STAGE/VERIFIED" ]
  release_pause stop
  finish_held
  check_eq "the switch finishes" 0 "$HELD_RC"
  check "with the data it checked" [ -f "$VOL/$BLOCK_A/meta.json" ]
}

r_switch_waits_for_a_running_fetch() {
  verified_generation
  start_restore FAKE_AWS_DOWNLOAD_HOOK="$(pause_hook download)" -- fetch "$GEN"
  check "the download is under way" wait_for_file "$LOGDIR/download.reached"
  run_restore -- switch "$GEN" --yes
  check_eq "switch does not read a staging directory being replaced" 2 "$RC"
  check "the reason is given" logged "$OUT" 'another restore command'
  check_not "Prometheus is not stopped" logged "$LOGDIR/docker-calls.log" ' stop '
  run_restore -- fetch "$GEN"
  check_eq "nor do two downloads share it" 2 "$RC"
  release_pause download
  finish_held
  check_eq "the download finishes" 0 "$HELD_RC"
}

r_switch_waits_for_a_running_verify() {
  fetched_generation
  : >"$LOGDIR/docker-calls.log"
  start_restore FAKE_DOCKER_RUN_HOOK="$(pause_hook read)" -- verify "$GEN"
  check "the read is under way" wait_for_file "$LOGDIR/read.reached"
  run_restore -- switch "$GEN" --yes
  check_eq "switch does not run beside a verify" 2 "$RC"
  check "the reason is given" logged "$OUT" 'another restore command'
  check_not "Prometheus is not stopped" logged "$LOGDIR/docker-calls.log" ' stop '
  release_pause read
  finish_held
  check_eq "the verify finishes" 0 "$HELD_RC"
}

# After verify, and before any docker call: nothing may be stopped or moved.
check_refused_without_touching_anything() { # live hash before, changed path
  check_eq "refused" 2 "$RC"
  check "the change is named" logged "$OUT" "CHANGED $2"
  check_eq "live data is unchanged" "$1" "$(live_hash)"
  check_eq "Prometheus is not touched" 0 "$(wc -l <"$LOGDIR/docker-calls.log" | tr -d ' ')"
  check_not "no switch is open" [ -e "$SB/restore/switch.state" ]
}

r_switch_refuses_a_file_deleted_after_verify() {
  verified_generation
  local before
  before="$(live_hash)"
  rm -f "${STAGE:?}/data/$BLOCK_B/chunks/000001"
  run_restore -- switch "$GEN" --yes
  check_refused_without_touching_anything "$before" "$BLOCK_B/chunks/000001"
}

r_switch_refuses_a_file_added_after_verify() {
  verified_generation
  local before
  before="$(live_hash)"
  echo added >"$STAGE/data/$BLOCK_B/added"
  run_restore -- switch "$GEN" --yes
  check_refused_without_touching_anything "$before" "$BLOCK_B/added"
}

r_switch_refuses_a_same_size_change_after_verify() {
  verified_generation
  local before index="$STAGE/data/$BLOCK_A/index" size
  before="$(live_hash)"
  size="$(wc -c <"$index" | tr -d ' ')"
  dd if=/dev/urandom of="$index" bs=1 count="$size" 2>/dev/null
  check_eq "the size is the same" "$size" "$(wc -c <"$index" | tr -d ' ')"
  run_restore -- switch "$GEN" --yes
  check_refused_without_touching_anything "$before" "$BLOCK_A/index"
}

r_switch_refuses_a_legacy_change_after_verify() {
  make_legacy_prefix 2026-11-03
  run_restore -- fetch --legacy-prefix 2026-11-03
  run_restore -- verify --legacy-prefix 2026-11-03
  check_eq "the legacy prefix verifies" 0 "$RC"
  : >"$LOGDIR/docker-calls.log"
  local before chunk="$SB/restore/legacy-2026-11-03/data/$BLOCK_A/chunks/000001" size
  before="$(live_hash)"
  size="$(wc -c <"$chunk" | tr -d ' ')"
  dd if=/dev/urandom of="$chunk" bs=1024 count=$((size / 1024)) 2>/dev/null
  run_restore -- switch --legacy-prefix 2026-11-03 --yes
  check_refused_without_touching_anything "$before" "$BLOCK_A/chunks/000001"
}

r_switch_swaps_by_rename() {
  verified_generation
  run_restore -- switch "$GEN" --yes
  check_eq "switch succeeds" 0 "$RC"
  check "the operator sees the downtime" logged "$OUT" 'Prometheus was down for'
  local parked
  parked="$(parked_dirs)"
  check "the previous data is parked next to _data" [ -f "$parked/live.marker" ]
  check_not "the staged copy moved, not copied" [ -e "$STAGE/data" ]
  check "restored data is live" [ -f "$VOL/$BLOCK_A/meta.json" ]
  check_not "the old data is not mixed in" [ -e "$VOL/live.marker" ]
  check "stop comes before up" awk '/ stop /{s=NR} / up /{u=NR} END{exit !(s && u && s<u)}' "$LOGDIR/docker-calls.log"
  check "the same container is restarted" logged "$LOGDIR/docker-calls.log" 'up -d --no-recreate prometheus'
  check "readiness is checked" logged "$LOGDIR/curl-calls.log" '/-/ready'
  check "the loaded blocks are checked" logged "$LOGDIR/curl-calls.log" '/metrics'
  run_restore -- switch "$GEN" --yes
  check_eq "a second switch needs the first closed" 2 "$RC"
}

r_switch_rolls_back_when_not_ready() {
  verified_generation
  local before
  before="$(live_hash)"
  run_restore FAKE_READY=only_with_marker -- switch "$GEN" --yes
  check_eq "reported as rolled back" 9 "$RC"
  check_eq "live data is byte for byte the old data" "$before" "$(live_hash)"
  check_eq "nothing is left parked" 0 "$(parked_dirs | wc -l | tr -d ' ')"
  check "the restored copy is kept for inspection" [ -f "$STAGE"/data.failed-*/"$BLOCK_A"/meta.json ]
  check_not "the switch is closed" [ -e "$SB/restore/switch.state" ]
  check_eq "Prometheus is up" running "$(cat "$LOGDIR/prom.state")"
}

r_switch_rolls_back_when_blocks_are_missing() {
  verified_generation
  local before
  before="$(live_hash)"
  run_restore FAKE_BLOCKS_LOADED=3 -- switch "$GEN" --yes
  check_eq "fewer blocks than the manifest" 9 "$RC"
  check_eq "live data is the old data" "$before" "$(live_hash)"
  check "the mismatch is shown" logged "$OUT" 'blocks loaded: 3 of 5'
}

r_switch_waits_for_the_blocks_gauge() {
  verified_generation
  run_restore FAKE_GAUGE_AFTER=3 -- switch "$GEN" --yes
  check_eq "a gauge that comes late is not a failure" 0 "$RC"
  check_eq "it is read from /metrics, retried" 4 "$(grep -c '/metrics' "$LOGDIR/curl-calls.log")"
  check_not "and never through the query API" logged "$LOGDIR/curl-calls.log" '/api/v1/query'
}

r_switch_gives_up_on_the_blocks_gauge() {
  verified_generation
  local before
  before="$(live_hash)"
  run_restore FAKE_GAUGE_AFTER=never -- switch "$GEN" --yes
  check_eq "the wait is bounded and rolls back" 9 "$RC"
  check_eq "24 tries" 24 "$(grep -c '/metrics' "$LOGDIR/curl-calls.log")"
  check_eq "live data is the old data" "$before" "$(live_hash)"
}

r_switch_rolls_back_when_prometheus_will_not_start() {
  verified_generation
  local before
  before="$(live_hash)"
  run_restore FAKE_DOCKER_UP=fail -- switch "$GEN" --yes
  check_eq "the second start fails too, so a human is needed" 10 "$RC"
  check_eq "the old data is still back in place" "$before" "$(live_hash)"
}

r_switch_stop_failure_touches_nothing() {
  verified_generation
  local before
  before="$(live_hash)"
  run_restore FAKE_DOCKER_STOP=fail -- switch "$GEN" --yes
  check_eq "reported" 8 "$RC"
  check_eq "live data is unchanged" "$before" "$(live_hash)"
  check "the staged data stays" [ -d "$STAGE/data" ]
  check_not "no switch is open" [ -e "$SB/restore/switch.state" ]
  check_eq "Prometheus is up" running "$(cat "$LOGDIR/prom.state")"
}

r_switch_tolerates_blocks_dropped_by_retention() {
  seed_live
  # 40 days older than the snapshot's head block, so retention drops it at startup.
  mk_block "$BLOCK_A" 8 $((1790000900000 - 40 * 86400000))
  run_backup "$T0" FAKE_AWS_SYNC=ok
  GEN="$(latest_generation)"
  run_restore -- fetch "$GEN"
  run_restore -- verify "$GEN" --accept-gaps
  run_restore FAKE_BLOCKS_LOADED=4 -- switch "$GEN" --yes
  check_eq "one block past retention may be gone" 0 "$RC"
  run_restore -- rollback
  run_restore -- fetch "$GEN"
  run_restore -- verify "$GEN" --accept-gaps
  run_restore FAKE_BLOCKS_LOADED=3 -- switch "$GEN" --yes
  check_eq "but not one more" 9 "$RC"
}

r_interrupted_switch_rolls_back() {
  verified_generation
  local before
  before="$(live_hash)"
  SBX_EXEC="exec" sbx FAKE_NOW="$T0" FAKE_READY=only_with_marker SKYEYE_RESTORE_READY_TIMEOUT=20 -- \
    /bin/bash "$RESTORE" switch "$GEN" --yes >"$LOGDIR/interrupted.out" 2>&1 &
  local pid=$!
  check "the swap happens" wait_for_log "$LOGDIR/docker-calls.log" ' up -d'
  kill -TERM "$pid"
  wait "$pid"
  RC=$?
  check_eq "a dropped session rolls back" 9 "$RC"
  check_eq "live data is the old data" "$before" "$(live_hash)"
  check_not "the switch is closed" [ -e "$SB/restore/switch.state" ]
}

# The stop takes up to 60 s, and a session can drop in it.
r_interrupted_stop_brings_prometheus_back() {
  verified_generation
  local before
  before="$(live_hash)"
  start_restore FAKE_DOCKER_STOP_HOOK="$(pause_hook stop)" -- switch "$GEN" --yes
  check "the stop is under way" wait_for_file "$LOGDIR/stop.reached"
  kill -TERM "$HELD_PID"
  release_pause stop
  finish_held
  check_eq "reported as nothing moved" 8 "$HELD_RC"
  check_eq "Prometheus is up" running "$(cat "$LOGDIR/prom.state")"
  check_eq "on the data it had" "$before" "$(live_hash)"
  check_not "the switch is closed" [ -e "$SB/restore/switch.state" ]
  check "the staged data stays approved" [ -f "$STAGE/VERIFIED" ]
  run_restore -- switch "$GEN" --yes
  check_eq "so the switch can simply run again" 0 "$RC"
}

r_state_write_failure_after_stop_brings_prometheus_back() {
  verified_generation
  local before hook="$SB/block-state"
  before="$(live_hash)"
  printf '#!/bin/bash\nmkdir "%s/restore/switch.state.tmp"\n' "$SB" >"$hook"
  chmod +x "$hook"
  run_restore FAKE_DOCKER_STOP_HOOK="$hook" -- switch "$GEN" --yes
  check_eq "reported as nothing moved" 8 "$RC"
  check_eq "Prometheus is up" running "$(cat "$LOGDIR/prom.state")"
  check_eq "on the data it had" "$before" "$(live_hash)"
  check_not "the switch is closed" [ -e "$SB/restore/switch.state" ]
  check "the staged data stays" [ -f "$STAGE/data/$BLOCK_A/meta.json" ]
}

r_state_write_failure_before_stop_leaves_prometheus_alone() {
  verified_generation
  local before
  before="$(live_hash)"
  mkdir "$SB/restore/switch.state.tmp"
  run_restore -- switch "$GEN" --yes
  check_eq "reported" 8 "$RC"
  check_not "Prometheus is never stopped" logged "$LOGDIR/docker-calls.log" ' stop '
  check_eq "live data is unchanged" "$before" "$(live_hash)"
}

r_rollback_recovers_a_switch_killed_during_stop() {
  verified_generation
  local before
  before="$(live_hash)"
  # What kill -9 leaves in the stop: nothing moved, Prometheus down.
  printf 'id=%s\nparked=%s\nfresh=0\nphase=stopping\nswitched_at=%s\n' "$GEN" \
    "$SB/volume/_data.pre-restore-20261101T190000Z" "$T0" >"$SB/restore/switch.state"
  echo stopped >"$LOGDIR/prom.state"
  run_restore -- rollback
  check_eq "rollback brings it back" 0 "$RC"
  check_eq "Prometheus is up" running "$(cat "$LOGDIR/prom.state")"
  check_eq "on the data it had" "$before" "$(live_hash)"
  check_not "the switch is closed" [ -e "$SB/restore/switch.state" ]
  check "the staged data stays approved" [ -f "$STAGE/VERIFIED" ]
}

r_rollback_undoes_a_good_switch() {
  verified_generation
  local before
  before="$(live_hash)"
  run_restore -- switch "$GEN" --yes
  run_restore -- rollback
  check_eq "rollback succeeds" 0 "$RC"
  check_eq "live data is the old data" "$before" "$(live_hash)"
  check_eq "Prometheus is up" running "$(cat "$LOGDIR/prom.state")"
  run_restore -- rollback
  check_eq "nothing left to roll back" 2 "$RC"
}

r_rollback_recovers_a_killed_switch() {
  verified_generation
  local before stamp=20261101T190000Z
  before="$(live_hash)"
  # What kill -9 leaves between the two renames.
  mv "$VOL" "$SB/volume/_data.pre-restore-$stamp"
  printf 'id=%s\nparked=%s\nfresh=0\nphase=moving\nswitched_at=%s\n' "$GEN" "$SB/volume/_data.pre-restore-$stamp" "$T0" >"$SB/restore/switch.state"
  run_restore -- rollback
  check_eq "rollback finishes the job" 0 "$RC"
  check_eq "live data is the old data" "$before" "$(live_hash)"
}

r_rollback_refuses_when_previous_data_is_gone() {
  verified_generation
  run_restore -- switch "$GEN" --yes
  rm -rf "$(parked_dirs)"
  run_restore -- rollback
  check_eq "a human has to look" 10 "$RC"
  check "live data is left in place" [ -f "$VOL/$BLOCK_A/meta.json" ]
}

r_finalize_keeps_the_previous_data_for_a_day() {
  verified_generation
  run_restore -- switch "$GEN" --yes
  local parked
  parked="$(parked_dirs)"
  mkdir "$SB/volume/_data.pre-restore-unrelated"
  NOW=$((T0 + DAY)) run_restore -- finalize
  check_eq "needs --yes" 2 "$RC"
  NOW=$((T0 + DAY - 1)) run_restore -- finalize --yes
  check_eq "not before 24 hours" 2 "$RC"
  check "the previous data stays" [ -d "$parked" ]
  NOW=$((T0 + DAY)) run_restore -- finalize --yes
  check_eq "after 24 hours it goes" 0 "$RC"
  check_not "it is deleted" [ -e "$parked" ]
  check "nothing else is" [ -d "$SB/volume/_data.pre-restore-unrelated" ]
  check "live data stays" [ -f "$VOL/$BLOCK_A/meta.json" ]
  run_restore -- rollback
  check_eq "after finalize there is no way back to offer" 2 "$RC"
}

r_finalize_refuses_a_forged_path() {
  verified_generation
  run_restore -- switch "$GEN" --yes
  mkdir -p "$SB/precious"
  sed "s|^parked=.*|parked=$SB/precious|" "$SB/restore/switch.state" >"$SB/restore/switch.state.new"
  mv "$SB/restore/switch.state.new" "$SB/restore/switch.state"
  NOW=$((T0 + 2 * DAY)) run_restore -- finalize --yes
  check_eq "only a _data.pre-restore-<time> next to _data" 2 "$RC"
  check "it stays" [ -d "$SB/precious" ]
}

make_legacy_prefix() { # date: an old-format upload of the live blocks
  local date="$1" block
  seed_live
  mkdir -p "$BUCKET_DIR/$date"
  for block in "$BLOCK_A" "$BLOCK_B" "$BLOCK_C" "$BLOCK_D"; do
    cp -R "$VOL/$block" "$BUCKET_DIR/$date/$block"
  done
}

r_legacy_prefix_still_restores() {
  make_legacy_prefix 2026-11-03
  run_restore -- fetch --legacy-prefix 2026-11-03
  check_eq "fetch succeeds" 0 "$RC"
  check "with the warning" logged "$OUT" 'no completeness guarantee'
  run_restore -- verify --legacy-prefix 2026-11-03
  check_eq "verify succeeds" 0 "$RC"
  check "with the warning" logged "$OUT" 'no completeness guarantee'
  run_restore -- switch --legacy-prefix 2026-11-03 --yes
  check_eq "switch succeeds" 0 "$RC"
  check "with the warning" logged "$OUT" 'no completeness guarantee'
  check "the blocks are live" [ -f "$VOL/$BLOCK_B/index" ]
  check_not "the old data is parked" [ -e "$VOL/live.marker" ]
  run_restore -- rollback
  check_eq "and rolls back" 0 "$RC"
  check "to the old data" [ -f "$VOL/live.marker" ]
}

r_legacy_prefix_needs_the_flag_and_block_checks() {
  make_legacy_prefix 2026-11-03
  run_restore -- fetch 2026-11-03
  check_eq "a date is not accepted as an id" 2 "$RC"
  rm -f "${BUCKET_DIR:?}/2026-11-03/$BLOCK_B/meta.json" "${BUCKET_DIR:?}/2026-11-03/$BLOCK_C/index"
  run_restore -- fetch --legacy-prefix 2026-11-03
  run_restore -- verify --legacy-prefix 2026-11-03
  check_eq "a partial legacy block is rejected" 7 "$RC"
  check "by name" logged "$OUT" "MISSING $BLOCK_B/meta.json"
  check "each of them" logged "$OUT" "MISSING $BLOCK_C/index"
  run_restore -- fetch --legacy-prefix 2026-01-01
  check_eq "an empty legacy prefix" 3 "$RC"
}

r_fresh_needs_an_empty_data_directory() {
  verified_generation
  local before
  before="$(live_hash)"
  run_restore -- switch "$GEN" --yes --fresh
  check_eq "existing data blocks --fresh" 2 "$RC"
  check_eq "and stays" "$before" "$(live_hash)"
}

r_fresh_on_a_rebuilt_host() {
  verified_generation
  rm -rf "${VOL:?}"
  : >"$LOGDIR/volume-unknown"
  run_restore -- switch "$GEN" --yes
  check_eq "no data and no --fresh is refused" 2 "$RC"
  run_restore -- switch "$GEN" --yes --fresh
  check_eq "--fresh swaps without parking anything" 0 "$RC"
  check "restored data is live" [ -f "$VOL/$BLOCK_A/meta.json" ]
  check_eq "nothing parked" 0 "$(parked_dirs | wc -l | tr -d ' ')"
  NOW=$((T0 + DAY)) run_restore -- finalize --yes
  check_eq "finalize just closes it" 0 "$RC"
}

r_fresh_stops_if_the_volume_cannot_be_created() {
  verified_generation
  rm -rf "${VOL:?}"
  : >"$LOGDIR/volume-unknown"
  run_restore FAKE_DOCKER_CREATE=fail -- switch "$GEN" --yes --fresh
  check_eq "reported" 8 "$RC"
  check "the verified data stays staged" [ -f "$STAGE/data/$BLOCK_A/meta.json" ]
  check_not "nothing is left open" [ -e "$SB/restore/switch.state" ]
}

r_fresh_failure_returns_to_empty() {
  verified_generation
  rm -rf "${VOL:?}"
  mkdir "$VOL"
  run_restore FAKE_READY=only_with_marker -- switch "$GEN" --yes --fresh
  check_eq "reported" 10 "$RC"
  check "the restored copy is kept" [ -f "$STAGE"/data.failed-*/"$BLOCK_A"/meta.json ]
  check "_data is back, empty" [ -d "$VOL" ]
  check_eq "nothing inside" 0 "$(find "$VOL" -mindepth 1 | wc -l | tr -d ' ')"
}

r_restore_only_reads_from_s3() {
  make_generation
  local before
  before="$(bucket_hash)"
  : >"$LOGDIR/aws-calls.log"
  run_restore -- list
  run_restore -- fetch "$GEN"
  run_restore -- verify "$GEN"
  run_restore -- switch "$GEN" --yes
  run_restore -- rollback
  check_eq "the bucket is unchanged" "$before" "$(bucket_hash)"
  check_not "no write verb" grep -Ev 'aws s3api list-objects-v2 |aws s3 cp .*s3://[^ ]+ /|aws s3 sync .*s3://[^ ]+ /' "$LOGDIR/aws-calls.log"
}

r_help_documents_the_tradeoffs() {
  local out="$SB/help.out"
  sbx -- /bin/bash "$RESTORE" --help >"$out" 2>&1
  check_eq "--help works without any tool" 0 "$?"
  check "WAL" logged "$out" 'hold no WAL'
  check "retention" logged "$out" '30d retention'
  check "UTC prefixes" logged "$out" 'UTC'
  check "legacy" logged "$out" 'legacy-prefix'
  check "purged series" logged "$out" 'tnauqquant-prod-1'
  check "native histograms" logged "$out" 'Native histograms'
}
