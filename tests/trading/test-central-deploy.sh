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

printf 'case: nothing to deploy is a no-op\n'
reset_logs
output="$(deploy)"
[[ "$output" == Already\ up\ to\ date* ]] || fail "up-to-date run did not report a no-op: $output"
[[ ! -s "$DOCKER_LOG" && ! -s "$CURL_LOG" ]] || fail "up-to-date run validated or reloaded"

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

printf 'case: a rejected reload is reported with the undo command\n'
"$SEED/scripts/trading-target" --file "$SEED/prometheus/rules/trading-targets.yml" \
  remove --server trading02 --strategy deploy-lane-btc >/dev/null
publish 'remove deploy-lane-btc'
before="$(live_head)"
if output="$(FAKE_RELOAD_OK=0 deploy 2>&1)"; then
  fail "deploy accepted an unsuccessful Prometheus reload"
fi
[[ "$output" == *"git reset --hard $before"* ]] || fail "reload failure did not print the undo command"
git -C "$LIVE" reset --quiet --hard "$before"

printf 'case: Alertmanager changes are checked with amtool and reloaded\n'
reset_logs
printf '\n' >>"$SEED/alertmanager/alertmanager.yml"
publish 'touch alertmanager'
deploy >/dev/null
rg -q 'prom/alertmanager:v0[.]27[.]0 check-config /etc/alertmanager/alertmanager.yml' "$DOCKER_LOG" || \
  fail "Alertmanager change was not validated with the pinned amtool"
rg -q -- '-X POST http://127.0.0.1:9093/-/reload' "$CURL_LOG" || fail "Alertmanager was not reloaded"

printf 'case: changes that need a container recreate are refused\n'
printf '# recreate needed\n' >>"$SEED/docker-compose.yml"
publish 'compose change'
before="$(live_head)"
if output="$(deploy 2>&1)"; then
  fail "deploy accepted a docker-compose.yml change"
fi
[[ "$output" == *docker-compose.yml* ]] || fail "refusal did not name the manual path"
[[ "$(live_head)" == "$before" ]] || fail "refused deploy moved the checkout"

printf 'case: a diverged checkout is refused\n'
git_q -C "$LIVE" commit --quiet --allow-empty -m 'local divergence'
if deploy >/dev/null 2>&1; then
  fail "deploy accepted a non-fast-forward update"
fi

printf 'PASS: scripts/central-deploy validation, fast-forward and reload\n'
