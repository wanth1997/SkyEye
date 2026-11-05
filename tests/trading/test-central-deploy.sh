#!/usr/bin/env bash
set -euo pipefail

# Exercises scripts/central-deploy against a local bare-repo fixture with
# stubbed docker and curl. Nothing here contacts a real Prometheus or host. The
# exception is the Loki rule check, which only means something against the real
# parser: it runs in the pinned image, networkless, and the suite fails without
# that image. Fake responses are derived from file content, so a check that looks
# at less than the content gets caught.

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
LOKI_LOADED="$WORK/loki-loaded.json"
LOKI_READS="$WORK/loki-reads"
GRAFANA_TOKEN=glsa_fixtureToken_0123456789
mkdir -p "$FAKE_BIN"

LOKI_IMAGE="$(awk '$1 == "image:" && index($2, "grafana/loki:") == 1 { print $2; exit }' \
  "$REPO_ROOT/docker-compose.yml")"
REAL_DOCKER="$(command -v docker)" || fail "the Loki rule cases need a real docker CLI"
"$REAL_DOCKER" image inspect "$LOKI_IMAGE" >/dev/null 2>&1 || \
  fail "the Loki rule cases need the pinned image: docker pull $LOKI_IMAGE"

cat >"$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
arguments="$*"
printf '%s\n' "${arguments%% -c *}" >>"$DOCKER_LOG"
if [[ "$*" != *" grafana/loki:"* || -n "${FAKE_DOCKER_STATUS:-}" ]]; then
  exit "${FAKE_DOCKER_STATUS:-0}"
fi
[[ -z "${FAKE_LOKI_STATUS:-}" ]] || exit "$FAKE_LOKI_STATUS"
# Streamed in, because not every Docker setup can bind-mount a temporary
# directory. COPYFILE_DISABLE keeps macOS tar from adding ._* files, which the
# ruler would read as broken namespaces.
rules=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v) rules="${2%:/loki/rules:ro}"; shift 2 ;;
    --entrypoint) image="$3"; script="$5"; break ;;
    *) shift ;;
  esac
done
loaded="$(mktemp "$LOKI_LOADED.XXXXXX")"
COPYFILE_DISABLE=1 tar -C "$rules" -cf - . | \
  "$REAL_DOCKER" run -i --rm --pull=never --network none --entrypoint /bin/sh "$image" -c \
    'mkdir -p /loki/rules && tar -xf - -C /loki/rules && exec /bin/sh -c "$1"' sh "$script" >"$loaded"
cat "$loaded"
mv "$loaded" "$LOKI_LOADED"
EOF
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_LOG"
case "$*" in
  *-/reload*) exit "${FAKE_RELOAD_STATUS:-0}" ;;
  *query=prometheus_config_last_reload_successful*)
    printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[0,"%s"]}]}}\n' \
      "${FAKE_RELOAD_OK:-1}" ;;
  */prometheus/api/v1/rules*)
    if [[ -n "${FAKE_LOKI_DOWN:-}" ]]; then
      printf 'curl: (7) Failed to connect\n' >&2
      exit 7
    fi
    reads="$(($(cat "$LOKI_READS" 2>/dev/null || printf 0) + 1))"
    printf '%s' "$reads" >"$LOKI_READS"
    if [[ -n "${FAKE_LOKI_STALE:-}" && "$reads" -le "${FAKE_LOKI_STALE_READS:-999}" ]]; then
      exec "$FAKE_BIN/ruler" "$FAKE_LOKI_STALE"
    fi
    exec "$FAKE_BIN/ruler" "$LOKI_LOADED" ;;
  */loki/api/v1/rules*)
    if [[ -n "${FAKE_LOKI_STORE_ERROR:-}" ]]; then
      [[ "$*" != *-fsS* ]] || exit 22
      printf '%s\n' "$FAKE_LOKI_STORE_ERROR"
    fi ;;
  */api/search*|*/api/dashboards/uid/*) exec "$FAKE_BIN/grafana" "$@" ;;
  *query=trading_target_info*)
    printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{"__name__":"trading_target_info","server_id":"trading02","strategy":"deploy-lane-btc","quote_currency":"USDT"},"value":[0,"1"]}]}}\n' ;;
  *) exit 22 ;;
esac
EOF
# The rules as a live ruler reports them: what the throwaway ruler loaded, plus
# the evaluation state it never had.
cat >"$FAKE_BIN/ruler" <<'EOF'
#!/usr/bin/env python3
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    loaded = json.load(handle)
evaluated = {"lastEvaluation": "2026-11-05T10:00:00Z", "evaluationTime": 0.25}
for group in loaded["data"]["groups"]:
    group.update(evaluated)
    for rule in group["rules"]:
        rule.update(evaluated, health="err", lastError="query timed out")
        if rule["type"] == "alerting":
            rule.update(state="firing", alerts=[{"state": "firing"}])
print(json.dumps(loaded))
EOF
# Serves what Grafana would hold: the checkout, or FAKE_GRAFANA_ROOT to stand in
# for content it never loaded. Grafana adds id and version to the stored model.
cat >"$FAKE_BIN/grafana" <<'EOF'
#!/usr/bin/env python3
import json
import os
import sys

if sys.stdin.read() != 'header = "Authorization: Bearer %s"\n' % os.environ["GRAFANA_TOKEN"]:
    sys.exit("curl: (22) The requested URL returned error: 401")
root = os.environ.get("FAKE_GRAFANA_ROOT") or os.environ["LIVE"] + "/grafana/dashboards"
served = {}
for directory, _, names in os.walk(root):
    for name in names:
        path = os.path.join(directory, name)
        if name.endswith(".json"):
            try:
                with open(path, encoding="utf-8") as handle:
                    body = json.load(handle)
            except ValueError:
                continue
            if isinstance(body, dict) and body.get("uid"):
                served[body["uid"]] = (os.path.relpath(path, root), body)
url = sys.argv[-1]
if "/api/search" in url:
    print(json.dumps([] if os.environ.get("FAKE_GRAFANA_ROLELESS") else [{"uid": uid} for uid in served]))
else:
    uid = url.rsplit("/", 1)[1]
    if uid not in served:
        sys.exit("curl: (22) The requested URL returned error: 404")
    relative, body = served[uid]
    print(json.dumps({"dashboard": dict(body, id=7, version=3), "meta": {"provisionedExternalId": relative}}))
EOF
chmod 755 "$FAKE_BIN"/*
printf '%s\n' "$GRAFANA_TOKEN" >"$WORK/grafana-token"
chmod 600 "$WORK/grafana-token"
export DOCKER_LOG CURL_LOG LOKI_LOADED LOKI_READS REAL_DOCKER FAKE_BIN GRAFANA_TOKEN
export SKYEYE_DOCKER="$FAKE_BIN/docker" SKYEYE_CURL="$FAKE_BIN/curl"
export SKYEYE_GRAFANA_TOKEN_FILE="$WORK/grafana-token"
export SKYEYE_ACCEPT_TIMEOUT=0 SKYEYE_ACCEPT_INTERVAL=0

git_q() {
  git -c user.name=fixture -c user.email=fixture@example.invalid \
    -c init.defaultBranch=master -c advice.detachedHead=false "$@"
}

SEED="$WORK/seed"
export LIVE="$WORK/live"
ORIGIN="$WORK/origin.git"
mkdir -p "$SEED/scripts" "$SEED/loki" "$SEED/grafana"
cp -R "$REPO_ROOT/prometheus" "$SEED/prometheus"
cp -R "$REPO_ROOT/alertmanager" "$SEED/alertmanager"
rm -rf "$SEED/alertmanager/secrets"
cp -R "$REPO_ROOT/loki/rules" "$SEED/loki/rules"
cp -R "$REPO_ROOT/grafana/dashboards" "$SEED/grafana/dashboards"
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
  rm -f "$LOKI_READS"
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

printf 'case: the supported local secret files are allowed\n'
mkdir -p "$LIVE/alertmanager/secrets"
for secret in tg_token smtp_password email-addresses.tmpl; do
  printf 'fixture' >"$LIVE/alertmanager/secrets/$secret"
  deploy --dry-run >/dev/null || fail "dry run refused the supported alertmanager/secrets/$secret"
done

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

# Every case below starts from $base, applied, with origin at the same commit.
base="$(live_head)"
cp "$LOKI_LOADED" "$WORK/loki-base.json"
LOKI_BASE="$WORK/loki-base.json"
cp -R "$LIVE/grafana/dashboards" "$WORK/grafana-base"
GRAFANA_BASE="$WORK/grafana-base"
FLEET=grafana/dashboards/Trading/trading-strategy-fleet.json
NODE_DASHBOARD=grafana/dashboards/Hosts/hosts-node-exporter.json
NEW_DASHBOARD=grafana/dashboards/Utilities/new.json
RULE_FILE=loki/rules/fake/tnauqquant.yml
BAD_RULE=loki/rules/fake/bad.yml

restore() {
  git_q -C "$SEED" reset --quiet --hard "$base"
  git_q -C "$SEED" push --quiet --force origin master
  git_q -C "$LIVE" reset --quiet --hard "$base"
  printf '%s\n' "$base" >"$applied_record"
}
recorded() {
  cat "$applied_record" 2>/dev/null || true
}
seed_head() {
  git -C "$SEED" rev-parse HEAD
}
# Sets one field of a dashboard to a JSON value.
set_dashboard() {
  python3 -I - "$SEED/$1" "$2" "$3" <<'PY'
import json
import sys

path, field, value = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
    dashboard = json.load(handle)
dashboard[field] = json.loads(value)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(dashboard, handle, ensure_ascii=False)
PY
}
change_dashboard() {
  set_dashboard "$1" description "\"$2\""
}
# Replaces the first match in the rule file.
edit_rule() {
  python3 -I - "$SEED/$RULE_FILE" "$1" "$2" <<'PY'
import sys

path, old, new = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
    rules = handle.read()
assert old in rules
with open(path, "w", encoding="utf-8") as handle:
    handle.write(rules.replace(old, new, 1))
PY
}
# Same alert names, different query: only a comparison of the query sees this.
change_rule() {
  edit_rule '[1m]' '[2m]'
}
expect_refused() {
  local label="$1" expected="$2" head record
  shift 2
  head="$(live_head)"
  record="$(recorded)"
  reset_logs
  if output="$(deploy "$@" 2>&1)"; then
    fail "$label: was accepted"
  fi
  [[ "$output" == *"$expected"* ]] || fail "$label: did not say '$expected': $output"
  [[ "$output" != *"$GRAFANA_TOKEN"* ]] || fail "$label: printed the token"
  [[ "$(live_head)" == "$head" ]] || fail "$label: moved the checkout"
  [[ "$(recorded)" == "$record" ]] || fail "$label: advanced the applied record"
  if rg -q -- '-/reload' "$CURL_LOG"; then
    fail "$label: reloaded a service"
  fi
}
expect_not_loaded() {
  local label="$1" expected="$2" record target
  shift 2
  record="$(recorded)"
  target="$(seed_head)"
  if output="$(deploy "$@" 2>&1)"; then
    fail "$label: was recorded as applied"
  fi
  [[ "$output" == *"published but not loaded"* ]] || fail "$label: did not report the state: $output"
  [[ "$output" == *"$expected"* ]] || fail "$label: did not say '$expected': $output"
  [[ "$output" == *"git reset --hard $record"* ]] || fail "$label: lost the undo command: $output"
  [[ "$(live_head)" == "$target" ]] || fail "$label: the checkout must stay at the target"
  [[ "$(recorded)" == "$record" ]] || fail "$label: advanced the applied record"
}
expect_applied() {
  local label="$1" target
  shift
  target="$(seed_head)"
  output="$(deploy "$@" 2>&1)" || fail "$label: $output"
  [[ "$(live_head)" == "$target" ]] || fail "$label: checkout did not reach the target"
  [[ "$(recorded)" == "$target" ]] || fail "$label: was not recorded: $output"
  [[ "$(deploy)" == Already\ up\ to\ date* ]] || fail "$label: the next run was not a no-op"
}

printf 'case: an invalid dashboard is refused before the checkout moves\n'
for bad in broken-json zero-byte emptied-existing array empty-object no-title no-uid \
  two-objects nan duplicate-uid duplicate-title; do
  path="$NEW_DASHBOARD"
  case "$bad" in
    broken-json) printf '{"uid":"new","title":' >"$SEED/$path" ;;
    zero-byte) : >"$SEED/$path" ;;
    emptied-existing) path="$FLEET"; : >"$SEED/$path" ;;
    array) printf '[{"uid":"new","title":"New"}]\n' >"$SEED/$path" ;;
    empty-object) printf '{}\n' >"$SEED/$path" ;;
    no-title) printf '{"uid":"new"}\n' >"$SEED/$path" ;;
    no-uid) printf '{"title":"New"}\n' >"$SEED/$path" ;;
    two-objects) printf '{"uid":"new","title":"New"}\n{"uid":"two","title":"Two"}\n' >"$SEED/$path" ;;
    nan) printf '{"uid":"new","title":"New","refresh":NaN}\n' >"$SEED/$path" ;;
    duplicate-uid) printf '{"uid":"trading-strategy-fleet","title":"New"}\n' >"$SEED/$path" ;;
    duplicate-title)
      path=grafana/dashboards/Trading/new.json
      printf '{"uid":"new","title":"%s"}\n' \
        "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["title"])' "$SEED/$FLEET")" \
        >"$SEED/$path" ;;
  esac
  publish "bad dashboard: $bad"
  expect_refused "$bad dashboard, dry run" "$(basename "$path")" --dry-run
  expect_refused "$bad dashboard" "$(basename "$path")"
  restore
done

# The values below are what pinned Grafana 11.2.0 was seen to rewrite or keep.
printf 'case: a dashboard Grafana would rewrite is refused before the checkout moves\n'
for refresh in 1s 4s 0s 0m 500ms 1.5s 30 abc; do
  set_dashboard "$FLEET" refresh "\"$refresh\""
  publish "refresh $refresh"
  for way in --dry-run ""; do
    expect_refused "refresh $refresh ${way:-deploy}" "trading-strategy-fleet.json: refresh \"$refresh\"" ${way:+"$way"}
    [[ "$output" == *'at least 5s'* ]] || fail "refresh $refresh: did not say how to fix it: $output"
  done
  restore
done
for field in title uid; do
  for padded in ' padded' 'padded '; do
    set_dashboard "$FLEET" "$field" "\"$padded\""
    publish "padded $field"
    for way in --dry-run ""; do
      expect_refused "padded $field ${way:-deploy}" \
        "trading-strategy-fleet.json: $field has spaces around it" ${way:+"$way"}
    done
    restore
  done
done

printf 'case: a refresh Grafana keeps as written passes\n'
mkdir -p "$(dirname "$SEED/$NEW_DASHBOARD")"
number=0
for refresh in '"5s"' '"1m"' '"1h"' '"1d"' '"1w"' '"1M"' '"1y"' '""' '"auto"' false true null 30; do
  number=$((number + 1))
  printf '{"uid":"refresh-%s","title":"Refresh %s","refresh":%s}\n' "$number" "$number" "$refresh" \
    >"$SEED/grafana/dashboards/Utilities/refresh-$number.json"
done
publish 'refresh values Grafana keeps'
expect_applied 'refresh values Grafana keeps'
restore

printf 'case: an invalid Loki rule is refused by the real ruler before the checkout moves\n'
for bad in broken-yaml broken-logql promql unknown-field zero-byte duplicate-group; do
  case "$bad" in
    broken-yaml) printf 'groups:\n  - name: x\n   rules: [\n' >"$SEED/$BAD_RULE" ;;
    broken-logql)
      printf '%s\n' 'groups:' '  - name: bad' '    rules:' '      - alert: Bad' \
        "        expr: 'sum(count_over_time({a=\"b\"} | logfmt [1m]'" >"$SEED/$BAD_RULE" ;;
    promql)
      printf '%s\n' 'groups:' '  - name: bad' '    rules:' '      - alert: Bad' \
        "        expr: 'up == 0'" >"$SEED/$BAD_RULE" ;;
    unknown-field)
      printf '%s\n' 'groups:' '  - name: bad' '    rules:' '      - alert: Bad' \
        "        expr: 'sum(count_over_time({a=\"b\"}[1m])) > 0'" '        fro: 5m' >"$SEED/$BAD_RULE" ;;
    zero-byte) : >"$SEED/$BAD_RULE" ;;
    duplicate-group)
      printf '%s\n' 'groups:' '  - name: same' '    rules:' '      - alert: A' \
        "        expr: 'sum(count_over_time({a=\"b\"}[1m])) > 0'" '  - name: same' '    rules:' \
        '      - alert: B' "        expr: 'sum(count_over_time({a=\"b\"}[1m])) > 0'" >"$SEED/$BAD_RULE" ;;
  esac
  publish "bad rule: $bad"
  expect_refused "$bad rule, dry run" 'error parsing /loki/rules/fake/bad.yml' --dry-run
  expect_refused "$bad rule" 'error parsing /loki/rules/fake/bad.yml'
  [[ "$output" == *'the ruler rejected the rule files'* ]] || \
    fail "$bad rule: was not rejected by the rule API: $output"
  restore
done

printf 'case: rule files the ruler would skip or that break other tenants are refused\n'
for stray in loki/rules/fake/nested/rules.yml loki/rules/other/rules.yml; do
  mkdir -p "$(dirname "$SEED/$stray")"
  printf 'groups: []\n' >"$SEED/$stray"
  publish "stray rule file: $stray"
  expect_refused "$stray, dry run" "${stray#loki/rules/}" --dry-run
  restore
done

printf 'case: the Loki check runs the pinned image with no network and never pulls\n'
printf 'note\n' >"$SEED/note.md"
publish 'docs only'
reset_logs
deploy --dry-run >/dev/null
rg -q "run --rm --pull=never --network none -v .*/loki/rules:/loki/rules:ro --entrypoint /bin/sh ${LOKI_IMAGE//./[.]}\$" \
  "$DOCKER_LOG" || fail "Loki check flags changed: $(cat "$DOCKER_LOG")"
FAKE_LOKI_STATUS=125 expect_refused 'absent Loki image' "docker pull $LOKI_IMAGE" --dry-run
restore

printf 'case: a dry run checks the token but not whether the services loaded anything\n'
change_rule
change_dashboard "$FLEET" dry-run
publish 'rule and dashboard'
reset_logs
output="$(deploy --dry-run 2>&1)" || fail "dry run failed: $output"
[[ "$output" == *'would confirm: Loki=1 Grafana=1'* ]] || fail "dry run did not name the confirmations: $output"
[[ "$(live_head)" == "$base" ]] || fail "dry run moved the checkout"
rg -q '/api/search' "$CURL_LOG" || fail "dry run did not test the Grafana token"
if rg -q '/prometheus/api/v1/rules|/api/dashboards/uid/' "$CURL_LOG"; then
  fail "dry run asked the services for content that was never published"
fi
restore

printf 'case: publishing and loading are reported apart, and loading is what gets recorded\n'
change_rule
change_dashboard "$FLEET" loaded
publish 'rule and dashboard'
reset_logs
expect_applied 'loaded change'
rest="$output"
for step in 'Checkout fast-forwarded' 'Published' 'Loki ruler loaded' 'Grafana loaded' 'central-deploy: done'; do
  [[ "$rest" == *"$step"* ]] || fail "'$step' missing or out of order: $output"
  rest="${rest#*"$step"}"
done
if rg -q "$GRAFANA_TOKEN" "$CURL_LOG" "$DOCKER_LOG"; then
  fail "the token reached a process argument"
fi
restore

printf 'case: rules the ruler has not loaded are not recorded, and rerunning retries\n'
change_rule
publish 'rule query change'
reset_logs
FAKE_LOKI_STALE="$LOKI_BASE" expect_not_loaded 'stale ruler' \
  'loaded rules differ from the target in tnauqquant.yml/'
reset_logs
expect_applied 'ruler caught up'
rg -q '/prometheus/api/v1/rules' "$CURL_LOG" || fail "rerun did not ask the ruler again"
restore

printf 'case: the rejection the live ruler reports reaches the operator\n'
change_rule
publish 'rule query change'
FAKE_LOKI_STALE="$LOKI_BASE" FAKE_LOKI_STORE_ERROR='error parsing /loki/rules/fake/x.yml' \
  expect_not_loaded 'rejected by the live ruler' 'rule API: error parsing /loki/rules/fake/x.yml'
restore

printf 'case: an unreachable ruler is not an accepted one\n'
change_rule
publish 'rule query change'
FAKE_LOKI_DOWN=1 expect_not_loaded 'ruler down' 'cannot read the loaded rules: curl: (7)'
restore

printf 'case: the deploy waits for a load that takes more than one poll\n'
change_rule
publish 'rule query change'
reset_logs
FAKE_LOKI_STALE="$LOKI_BASE" FAKE_LOKI_STALE_READS=2 SKYEYE_ACCEPT_TIMEOUT=30 expect_applied 'slow ruler'
[[ "$(cat "$LOKI_READS")" == 3 ]] || fail "expected a third read of the ruler, got $(cat "$LOKI_READS")"
restore

printf 'case: a single rule setting the ruler has not loaded is not recorded\n'
for setting in limit interval for labels annotations name; do
  case "$setting" in
    limit) edit_rule 'interval: 30s' $'interval: 30s\n      limit: 10' ;;
    interval) edit_rule 'interval: 30s' 'interval: 45s' ;;
    for) edit_rule '          labels:' $'          for: 5m\n          labels:' ;;
    labels) edit_rule 'severity: High' 'severity: Low' ;;
    annotations) edit_rule "summary: '" "summary: 'Now: " ;;
    name) edit_rule 'alert: TradingExecutionIncident' 'alert: TradingExecutionIncidentRenamed' ;;
  esac
  publish "rule $setting change"
  FAKE_LOKI_STALE="$LOKI_BASE" expect_not_loaded "stale $setting" \
    'loaded rules differ from the target in tnauqquant.yml/'
  expect_applied "$setting loaded"
  restore
done

printf 'case: dashboards Grafana has not loaded are not recorded, and rerunning retries\n'
change_dashboard "$FLEET" not-yet
publish 'dashboard content change'
FAKE_GRAFANA_ROOT="$GRAFANA_BASE" expect_not_loaded 'stale dashboard' \
  'trading-strategy-fleet still serves other content'
expect_applied 'Grafana caught up'
restore

set_dashboard "$FLEET" refresh '"1m"'
publish 'dashboard refresh change'
FAKE_GRAFANA_ROOT="$GRAFANA_BASE" expect_not_loaded 'stale refresh' \
  'trading-strategy-fleet still serves other content'
restore

mkdir -p "$(dirname "$SEED/$NEW_DASHBOARD")"
printf '{"uid":"new","title":"New"}\n' >"$SEED/$NEW_DASHBOARD"
publish 'new dashboard'
FAKE_GRAFANA_ROOT="$GRAFANA_BASE" expect_not_loaded 'new dashboard' 'new (Utilities/new.json) is not provisioned'
expect_applied 'new dashboard loaded'
restore

git_q -C "$SEED" rm --quiet "$FLEET"
publish 'remove dashboard'
FAKE_GRAFANA_ROOT="$GRAFANA_BASE" expect_not_loaded 'removed dashboard' \
  'trading-strategy-fleet was removed but is still served'
expect_applied 'removed dashboard gone'
restore

git_q -C "$SEED" mv "$FLEET" grafana/dashboards/Overview/trading-strategy-fleet.json
publish 'move dashboard'
FAKE_GRAFANA_ROOT="$GRAFANA_BASE" expect_not_loaded 'moved dashboard' \
  'trading-strategy-fleet is not provisioned from Overview/trading-strategy-fleet.json'
expect_applied 'moved dashboard loaded'
restore

printf 'case: moving a rule or dashboard out of its directory counts as removing it\n'
mkdir -p "$SEED/docs"
git_q -C "$SEED" mv loki/rules/fake/zenincome.yml docs/zenincome.yml
publish 'rule moved to docs'
FAKE_LOKI_STALE="$LOKI_BASE" expect_not_loaded 'rule moved away' 'loaded rules differ from the target in zenincome.yml/'
restore
mkdir -p "$SEED/docs"
git_q -C "$SEED" mv "$FLEET" docs/trading-strategy-fleet.json
publish 'dashboard moved to docs'
FAKE_GRAFANA_ROOT="$GRAFANA_BASE" expect_not_loaded 'dashboard moved away' \
  'trading-strategy-fleet was removed but is still served'
restore

printf 'case: every uid a file held since the last apply must stop being served\n'
set_dashboard "$FLEET" uid '"fleet-renamed"'
publish 'dashboard uid change'
rm -rf "$WORK/grafana-both"
cp -R "$SEED/grafana/dashboards" "$WORK/grafana-both"
cp "$GRAFANA_BASE/Trading/trading-strategy-fleet.json" "$WORK/grafana-both/Trading/old-uid.json"
FAKE_GRAFANA_ROOT="$WORK/grafana-both" expect_not_loaded 'old uid still served' \
  'trading-strategy-fleet was removed but is still served'
expect_applied 'old uid gone'
restore

set_dashboard "$FLEET" uid '"fleet-renamed"'
publish 'dashboard uid change'
FAKE_GRAFANA_ROOT="$GRAFANA_BASE" expect_not_loaded 'new uid never loaded' \
  'fleet-renamed (Trading/trading-strategy-fleet.json) is not provisioned'
git_q -C "$SEED" rm --quiet "$FLEET"
publish 'remove the dashboard whose new uid never loaded'
FAKE_GRAFANA_ROOT="$GRAFANA_BASE" expect_not_loaded 'applied uid still served' \
  'trading-strategy-fleet was removed but is still served'
expect_applied 'both uids gone'
restore

printf 'case: a UI edit to a dashboard that did not change does not block a deploy\n'
change_dashboard "$FLEET" changed
publish 'dashboard content change'
rm -rf "$WORK/grafana-drift"
cp -R "$SEED/grafana/dashboards" "$WORK/grafana-drift"
change_dashboard "$NODE_DASHBOARD" unused
cp "$SEED/$NODE_DASHBOARD" "$WORK/grafana-drift/Hosts/hosts-node-exporter.json"
git_q -C "$SEED" checkout --quiet -- "$NODE_DASHBOARD"
FAKE_GRAFANA_ROOT="$WORK/grafana-drift" expect_applied 'UI edit elsewhere'
restore

printf 'case: without a record every dashboard must match its file\n'
rm -f "$applied_record"
rm -rf "$WORK/grafana-drift"
cp -R "$LIVE/grafana/dashboards" "$WORK/grafana-drift"
rm "$WORK/grafana-drift/Trading/trading-strategy-fleet.json"
FAKE_GRAFANA_ROOT="$WORK/grafana-drift" expect_not_loaded 'no record, not provisioned' \
  'trading-strategy-fleet (Trading/trading-strategy-fleet.json) is not provisioned'
cp "$GRAFANA_BASE/Trading/trading-strategy-fleet.json" "$WORK/grafana-drift/Trading/"
change_dashboard "$NODE_DASHBOARD" 'edited in the UI before central-deploy ever ran'
cp "$SEED/$NODE_DASHBOARD" "$WORK/grafana-drift/Hosts/hosts-node-exporter.json"
git_q -C "$SEED" checkout --quiet -- "$NODE_DASHBOARD"
FAKE_GRAFANA_ROOT="$WORK/grafana-drift" expect_not_loaded 'no record, UI edit' \
  'if that is a UI edit, export hosts-node-exporter to Git'
[[ ! -e "$applied_record" ]] || fail "no record: a record was written"
expect_applied 'no record, every dashboard matches'
restore

printf 'case: a first deploy Grafana did not load stays unrecorded however often it is rerun\n'
rm -f "$applied_record"
change_dashboard "$FLEET" first-deploy
publish 'dashboard content change'
for attempt in first second; do
  FAKE_GRAFANA_ROOT="$GRAFANA_BASE" expect_not_loaded "no record, $attempt run" \
    'trading-strategy-fleet still serves other content'
done
[[ ! -e "$applied_record" ]] || fail "no record: a record was written"
expect_applied 'no record, Grafana caught up'
restore

printf 'case: a checkout pulled by hand without a record is held to the same check\n'
rm -f "$applied_record"
change_dashboard "$FLEET" pulled-by-hand
publish 'dashboard content change'
git_q -C "$LIVE" pull --quiet --ff-only origin master
FAKE_GRAFANA_ROOT="$GRAFANA_BASE" expect_not_loaded 'no record, pulled by hand' \
  'trading-strategy-fleet still serves other content'
[[ ! -e "$applied_record" ]] || fail "no record: a record was written"
restore

printf 'case: a dashboard change without a working token fails before the checkout moves\n'
change_dashboard "$FLEET" needs-token
publish 'dashboard content change'
for way in --dry-run ""; do
  SKYEYE_GRAFANA_TOKEN_FILE="$WORK/no-such-token" \
    expect_refused "missing token ${way:-deploy}" "$WORK/no-such-token" ${way:+"$way"}
  printf '%s\n' "$GRAFANA_TOKEN" >"$WORK/open-token"
  chmod 644 "$WORK/open-token"
  SKYEYE_GRAFANA_TOKEN_FILE="$WORK/open-token" \
    expect_refused "open token ${way:-deploy}" 'must be mode 0600' ${way:+"$way"}
  printf '%s\n' "$GRAFANA_TOKEN" >"$LIVE/.grafana-token"
  chmod 600 "$LIVE/.grafana-token"
  SKYEYE_GRAFANA_TOKEN_FILE="$LIVE/.grafana-token" \
    expect_refused "token in the checkout ${way:-deploy}" 'must be outside the checkout' ${way:+"$way"}
  rm -f "$LIVE/.grafana-token"
  printf 'header = "x: y"\n' >"$WORK/odd-token"
  chmod 600 "$WORK/odd-token"
  SKYEYE_GRAFANA_TOKEN_FILE="$WORK/odd-token" \
    expect_refused "malformed token ${way:-deploy}" 'is not a Grafana token' ${way:+"$way"}
  printf 'glsa_wrong\n' >"$WORK/wrong-token"
  chmod 600 "$WORK/wrong-token"
  SKYEYE_GRAFANA_TOKEN_FILE="$WORK/wrong-token" \
    expect_refused "rejected token ${way:-deploy}" 'returned error: 401' ${way:+"$way"}
  FAKE_GRAFANA_ROLELESS=1 expect_refused "role-less token ${way:-deploy}" 'needs the Viewer role' ${way:+"$way"}
done
restore

printf 'case: a change that touches neither rules nor dashboards does not need Loki or Grafana\n'
printf '# touched\n' >>"$SEED/prometheus/prometheus.yml"
publish 'prometheus only'
reset_logs
SKYEYE_GRAFANA_TOKEN_FILE="$WORK/no-such-token" FAKE_LOKI_DOWN=1 expect_applied 'prometheus only'
if rg -q '/prometheus/api/v1/rules|/api/search' "$CURL_LOG"; then
  fail "a Prometheus-only deploy waited on Loki or Grafana"
fi
restore

printf 'case: Prometheus failing still stops the deploy before any wait on Loki\n'
change_rule
printf '# touched\n' >>"$SEED/prometheus/prometheus.yml"
publish 'prometheus and rule'
reset_logs
if output="$(FAKE_RELOAD_OK=0 FAKE_LOKI_STALE="$LOKI_BASE" SKYEYE_ACCEPT_TIMEOUT=1 deploy 2>&1)"; then
  fail "deploy accepted an unsuccessful Prometheus reload"
fi
[[ "$output" == *'unsuccessful config reload'* ]] || fail "Prometheus failure was not reported first: $output"
[[ "$output" != *'published but not loaded'* ]] || fail "deploy waited on Loki first: $output"
if rg -q '/prometheus/api/v1/rules' "$CURL_LOG"; then
  fail "deploy asked the ruler although Prometheus had failed"
fi
restore

printf 'case: an invalid dashboard pulled by hand cannot be recorded\n'
mkdir -p "$(dirname "$SEED/$NEW_DASHBOARD")"
printf '{' >"$SEED/$NEW_DASHBOARD"
publish 'bad dashboard pulled by hand'
target="$(seed_head)"
git_q -C "$LIVE" pull --quiet --ff-only origin master
expect_refused 'hand-pulled bad dashboard' new.json
expect_refused 'hand-pulled bad dashboard, manual apply' new.json --manual-applied "${target:0:12}"
restore

printf 'case: a manual apply is recorded only after the rules are loaded\n'
change_rule
printf '# recreate needed\n' >>"$SEED/docker-compose.yml"
publish 'recreate change with a rule change'
target="$(seed_head)"
git_q -C "$LIVE" pull --quiet --ff-only origin master
FAKE_LOKI_STALE="$LOKI_BASE" expect_not_loaded 'manual apply, stale ruler' 'loaded rules differ' \
  --manual-applied "${target:0:12}"
expect_applied 'manual apply, loaded' --manual-applied "${target:0:12}"
restore

printf 'case: a diverged checkout is refused\n'
git_q -C "$LIVE" commit --quiet --allow-empty -m 'local divergence'
if deploy >/dev/null 2>&1; then
  fail "deploy accepted a non-fast-forward update"
fi

printf 'PASS: scripts/central-deploy validation, fast-forward and reload\n'
