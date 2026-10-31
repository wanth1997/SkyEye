#!/usr/bin/env bash
set -euo pipefail

# Exercises scripts/central-deploy against a local bare-repo fixture with
# stubbed docker and curl. Nothing here contacts a real Prometheus or host.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-central-deploy-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAKE_BIN="$WORK/bin"
DOCKER_LOG="$WORK/docker.log"
CURL_LOG="$WORK/curl.log"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
exit "${FAKE_DOCKER_STATUS:-0}"
EOF
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_LOG"
case "$*" in
  *-/reload*) exit "${FAKE_RELOAD_STATUS:-0}" ;;
  *query=prometheus_config_last_reload_successful*)
    printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[0,"%s"]}]}}\n' \
      "${FAKE_RELOAD_OK:-1}" ;;
  *query=trading_target_info*)
    printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{"__name__":"trading_target_info","server_id":"trading02","strategy":"deploy-lane-btc","quote_currency":"USDT"},"value":[0,"1"]}]}}\n' ;;
  *) exit 22 ;;
esac
EOF
chmod 755 "$FAKE_BIN"/*
export DOCKER_LOG CURL_LOG
export SKYEYE_DOCKER="$FAKE_BIN/docker" SKYEYE_CURL="$FAKE_BIN/curl"

git_q() {
  git -c user.name=fixture -c user.email=fixture@example.invalid \
    -c init.defaultBranch=master -c advice.detachedHead=false "$@"
}

SEED="$WORK/seed"
LIVE="$WORK/live"
ORIGIN="$WORK/origin.git"
mkdir -p "$SEED/scripts"
cp -R "$REPO_ROOT/prometheus" "$SEED/prometheus"
cp -R "$REPO_ROOT/alertmanager" "$SEED/alertmanager"
rm -rf "$SEED/alertmanager/secrets"
cp "$REPO_ROOT/docker-compose.yml" "$SEED/docker-compose.yml"
cp "$REPO_ROOT/scripts/central-deploy" "$REPO_ROOT/scripts/trading-target" "$SEED/scripts/"
git_q init --quiet "$SEED"
git_q -C "$SEED" add -A
git_q -C "$SEED" commit --quiet -m seed
git_q init --quiet --bare "$ORIGIN"
git_q -C "$SEED" remote add origin "$ORIGIN"
git_q -C "$SEED" push --quiet origin master
git_q clone --quiet "$ORIGIN" "$LIVE"

deploy() {
  "$LIVE/scripts/central-deploy" "$@"
}
live_head() {
  git -C "$LIVE" rev-parse HEAD
}
publish() {
  git_q -C "$SEED" add -A
  git_q -C "$SEED" commit --quiet -m "$1"
  git_q -C "$SEED" push --quiet origin master
}
reset_logs() {
  : >"$DOCKER_LOG"
  : >"$CURL_LOG"
}

printf 'case: first pickup of an already-merged checkout validates and reloads\n'
reset_logs
output="$(deploy)"
[[ "$output" != Already\ up\ to\ date* ]] || fail "first pickup skipped validation and reload: $output"
rg -q 'check config /etc/prometheus/prometheus.yml' "$DOCKER_LOG" || \
  fail "first pickup did not validate the checkout"
rg -q -- '-X POST http://127.0.0.1:9090/-/reload' "$CURL_LOG" || \
  fail "first pickup did not reload Prometheus"

printf 'case: an applied checkout is a no-op\n'
reset_logs
output="$(deploy)"
[[ "$output" == Already\ up\ to\ date* ]] || fail "applied checkout did not report a no-op: $output"
[[ ! -s "$DOCKER_LOG" && ! -s "$CURL_LOG" ]] || fail "applied checkout validated or reloaded"

"$SEED/scripts/trading-target" --file "$SEED/prometheus/rules/trading-targets.yml" \
  add --server trading02 --strategy deploy-lane-btc >/dev/null
publish 'add deploy-lane-btc'
before="$(live_head)"

printf 'case: dry run validates the target commit without moving the checkout\n'
reset_logs
deploy --dry-run >/dev/null
[[ "$(live_head)" == "$before" ]] || fail "dry run moved the checkout"
rg -q 'prom/prometheus:v2[.]54[.]1 check config /etc/prometheus/prometheus.yml' "$DOCKER_LOG" || \
  fail "dry run did not run promtool check config with the pinned image"
rg -q 'test rules .*/etc/prometheus/rules/tests/trading.test.yml' "$DOCKER_LOG" || \
  fail "dry run did not run the rule tests"
rg -q 'test rules /tmp/trading-derived.test.yml' "$DOCKER_LOG" || \
  fail "dry run did not run the derived inventory test"
if rg -q 'amtool' "$DOCKER_LOG"; then
  fail "amtool ran although Alertmanager config did not change"
fi
if rg -q -- '-/reload' "$CURL_LOG"; then
  fail "dry run reloaded a service"
fi
[[ "$(git -C "$LIVE" worktree list --porcelain | grep -c '^worktree ')" == "1" ]] || {
  git -C "$LIVE" worktree list >&2
  fail "dry run left its validation worktree registered"
}

printf 'case: failed validation leaves the checkout untouched\n'
reset_logs
if FAKE_DOCKER_STATUS=1 deploy >/dev/null 2>&1; then
  fail "deploy succeeded although promtool failed"
fi
[[ "$(live_head)" == "$before" ]] || fail "failed validation moved the checkout"
if rg -q -- '-/reload' "$CURL_LOG"; then
  fail "failed validation still reloaded Prometheus"
fi

printf 'case: a dirty checkout is refused\n'
printf '# local edit\n' >>"$LIVE/prometheus/prometheus.yml"
if deploy >/dev/null 2>&1; then
  fail "deploy accepted local changes to tracked files"
fi
git -C "$LIVE" checkout --quiet -- prometheus/prometheus.yml

printf 'case: untracked files in loaded config paths are refused before anything moves\n'
for untracked in prometheus/rules/review-untracked.yml alertmanager/secrets/extra-secret; do
  reset_logs
  mkdir -p "$(dirname "$LIVE/$untracked")"
  printf 'groups: []\n' >"$LIVE/$untracked"
  if output="$(deploy 2>&1)"; then
    fail "deploy accepted the untracked loaded file $untracked"
  fi
  [[ "$output" == *"$untracked"* ]] || fail "refusal did not name $untracked: $output"
  [[ "$(live_head)" == "$before" ]] || fail "refused deploy moved the checkout"
  [[ ! -s "$DOCKER_LOG" && ! -s "$CURL_LOG" ]] || fail "refused deploy validated or reloaded"
  rm -f "$LIVE/$untracked"
done

printf 'case: the supported local secret file is allowed\n'
mkdir -p "$LIVE/alertmanager/secrets"
printf 'fixture-token' >"$LIVE/alertmanager/secrets/tg_token"
deploy --dry-run >/dev/null || fail "dry run refused the supported alertmanager/secrets/tg_token"

printf 'case: deploy fast-forwards, reloads Prometheus and shows the live inventory\n'
reset_logs
output="$(deploy)"
[[ "$(live_head)" == "$(git -C "$SEED" rev-parse HEAD)" ]] || fail "deploy did not fast-forward"
rg -q -- '-X POST http://127.0.0.1:9090/-/reload' "$CURL_LOG" || fail "deploy did not reload Prometheus"
if rg -q -- '9093/-/reload' "$CURL_LOG"; then
  fail "deploy reloaded Alertmanager although its config did not change"
fi
[[ "$output" == *"server_id=trading02 strategy=deploy-lane-btc"* ]] || \
  fail "deploy did not print the live inventory: $output"

printf 'case: a failed reload is retried by the next run without a manual reset\n'
"$SEED/scripts/trading-target" --file "$SEED/prometheus/rules/trading-targets.yml" \
  remove --server trading02 --strategy deploy-lane-btc >/dev/null
publish 'remove deploy-lane-btc'
before="$(live_head)"
target="$(git -C "$SEED" rev-parse HEAD)"
if output="$(FAKE_RELOAD_OK=0 deploy 2>&1)"; then
  fail "deploy accepted an unsuccessful Prometheus reload"
fi
[[ "$output" == *"git reset --hard $before"* ]] || fail "reload failure did not print the undo command"
[[ "$(live_head)" == "$target" ]] || fail "fixture expected the checkout to advance before the reload"
reset_logs
if FAKE_RELOAD_STATUS=22 deploy >/dev/null 2>&1; then
  fail "a rerun with a rejected Prometheus reload reported success"
fi
rg -q -- '-X POST http://127.0.0.1:9090/-/reload' "$CURL_LOG" || \
  fail "a rerun at the already-merged target did not retry the reload"
reset_logs
output="$(deploy)"
[[ "$output" != Already\ up\ to\ date* ]] || fail "retry treated the pending reload as done: $output"
rg -q 'test rules /tmp/trading-derived.test.yml' "$DOCKER_LOG" || \
  fail "retry did not revalidate the checkout before reloading"
rg -q -- '-X POST http://127.0.0.1:9090/-/reload' "$CURL_LOG" || fail "retry did not reload Prometheus"
[[ "$(live_head)" == "$target" ]] || fail "retry moved the checkout"
reset_logs
output="$(deploy)"
[[ "$output" == Already\ up\ to\ date* ]] || fail "successful retry was not recorded as applied: $output"

printf 'case: Alertmanager changes are checked with amtool and reloaded\n'
reset_logs
printf '\n' >>"$SEED/alertmanager/alertmanager.yml"
publish 'touch alertmanager'
deploy >/dev/null
rg -q 'prom/alertmanager:v0[.]27[.]0 check-config /etc/alertmanager/alertmanager.yml' "$DOCKER_LOG" || \
  fail "Alertmanager change was not validated with the pinned amtool"
rg -q -- '-X POST http://127.0.0.1:9093/-/reload' "$CURL_LOG" || fail "Alertmanager was not reloaded"

printf 'case: changes that need a container recreate are refused\n'
applied_record="$(git -C "$LIVE" rev-parse --absolute-git-dir)/skyeye-central-deploy.applied"
printf '# recreate needed\n' >>"$SEED/docker-compose.yml"
publish 'compose change'
before="$(live_head)"
[[ "$(cat "$applied_record")" == "$before" ]] || fail "fixture expected the last apply at $before"
if output="$(deploy 2>&1)"; then
  fail "deploy accepted a docker-compose.yml change"
fi
[[ "$output" == *docker-compose.yml* ]] || fail "refusal did not name the manual path"
[[ "$(live_head)" == "$before" ]] || fail "refused deploy moved the checkout"
if deploy --manual-applied "$(git -C "$SEED" rev-parse --short=12 HEAD)" >/dev/null 2>&1; then
  fail "--manual-applied was accepted before the checkout reached the target"
fi
[[ "$(live_head)" == "$before" ]] || fail "--manual-applied moved the checkout"

printf 'case: a recreate change pulled by hand after an apply is refused and not recorded\n'
"$SEED/scripts/trading-target" --file "$SEED/prometheus/rules/trading-targets.yml" \
  add --server trading02 --strategy deploy-lane-eth >/dev/null
publish 'add deploy-lane-eth'
target="$(git -C "$SEED" rev-parse HEAD)"
git_q -C "$LIVE" pull --quiet --ff-only origin master
[[ "$(live_head)" == "$target" ]] || fail "fixture expected the manual pull to reach $target"
for attempt in 1 2; do
  reset_logs
  if output="$(deploy 2>&1)"; then
    fail "deploy recorded a hand-pulled docker-compose.yml change as applied (attempt $attempt)"
  fi
  [[ "$output" == *docker-compose.yml* ]] || fail "refusal did not name docker-compose.yml: $output"
  [[ "$output" == *"--manual-applied ${target:0:12}"* ]] || \
    fail "refusal did not say how to record a manual apply: $output"
  [[ ! -s "$DOCKER_LOG" && ! -s "$CURL_LOG" ]] || fail "refused deploy validated or reloaded"
  [[ "$(cat "$applied_record")" == "$before" ]] || fail "refused deploy advanced the applied record"
done
if deploy --dry-run >/dev/null 2>&1; then
  fail "dry run accepted the hand-pulled docker-compose.yml change"
fi

printf 'case: a manual apply is recorded only for the named target and after validation\n'
if deploy --manual-applied "${before:0:12}" >/dev/null 2>&1; then
  fail "--manual-applied accepted a commit other than the target"
fi
[[ "$(cat "$applied_record")" == "$before" ]] || fail "a rejected --manual-applied advanced the record"
reset_logs
if FAKE_DOCKER_STATUS=1 deploy --manual-applied "${target:0:12}" >/dev/null 2>&1; then
  fail "--manual-applied recorded a target that failed validation"
fi
[[ "$(cat "$applied_record")" == "$before" ]] || fail "failed validation advanced the record"
reset_logs
output="$(deploy --manual-applied "${target:0:12}" 2>&1)" || \
  fail "deploy refused the acknowledged manual apply: $output"
[[ "$output" == *"applied by hand at ${target:0:12}"* ]] || \
  fail "manual apply did not say which recreate-only change it records: $output"
rg -q 'test rules /tmp/trading-derived.test.yml' "$DOCKER_LOG" || \
  fail "manual apply was recorded without validating the target"
rg -q -- '-X POST http://127.0.0.1:9090/-/reload' "$CURL_LOG" || \
  fail "manual apply did not reload Prometheus for the inventory change"
[[ "$(cat "$applied_record")" == "$target" ]] || fail "acknowledged manual apply was not recorded"
output="$(deploy)"
[[ "$output" == Already\ up\ to\ date* ]] || fail "recorded manual apply was not a no-op: $output"

printf 'case: a diverged checkout is refused\n'
git_q -C "$LIVE" commit --quiet --allow-empty -m 'local divergence'
if deploy >/dev/null 2>&1; then
  fail "deploy accepted a non-fast-forward update"
fi

printf 'PASS: scripts/central-deploy validation, fast-forward and reload\n'
