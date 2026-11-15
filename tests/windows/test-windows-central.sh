#!/usr/bin/env bash
set -euo pipefail

# The central half of Windows monitoring: the alert rules and the dashboard.
#
#   1. The rules as the pinned Prometheus loads them are all in shadow, and the
#      repository's Alertmanager routing sends each to shadow-null, so adding a
#      Windows host cannot notify anyone.
#   2. Rules and dashboard only read metrics the Windows template sends: the
#      names marked keep in the exporter inventory, and the Alloy allowlist. A
#      panel on a dropped metric would stay empty with no error.
#   3. Every dashboard query is scoped to $product and $server_id, uses the
#      pinned datasource UIDs, and its Loki queries only use the labels the
#      streams have.
#   4. Every Prometheus query of the dashboard runs on fixture series: it
#      returns data for the selected host and nothing for another one.
#
# The dashboard's Loki queries run against real stored entries in
# tests/windows/test-windows-scrub.sh. The rule semantics are in
# prometheus/rules/tests/windows.test.yml.
#
# Containers have no network. It must never pass by skipping.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=tests/windows/lib.sh
. "$SCRIPT_DIR/lib.sh"

DASHBOARD="$REPO_ROOT/grafana/dashboards/Hosts/hosts-windows.json"
INVENTORY="$WINDOWS_FIXTURES/windows-exporter-v0.31.3-metrics.txt"
ALLOWLIST="$WINDOWS_FIXTURES/alloy-self-allowlist.txt"

for tool in docker python3 tar; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required; this suite must not pass by skipping"
done
docker info >/dev/null 2>&1 || die "the Docker daemon is unreachable; this suite must not pass by skipping"
PROM_IMAGE="$(compose_image 'prom\/prometheus')"
AM_IMAGE="$(compose_image 'prom\/alertmanager')"
[[ -n "$PROM_IMAGE" && -n "$AM_IMAGE" ]] || die "cannot find the pinned images in docker-compose.yml"
require_image "$PROM_IMAGE"
require_image "$AM_IMAGE"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-windows-central.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/in"
cp "$REPO_ROOT/prometheus/rules/windows.yml" "$REPO_ROOT/alertmanager/alertmanager.yml" "$WORK/in/"

contract dashboard --dashboard "$DASHBOARD" --series "$WINDOWS_FIXTURES/dashboard-series.txt" \
  --inventory "$INVENTORY" --allowlist "$ALLOWLIST" --server fake-windows --product github-runner \
  --out "$WORK/in/dashboard.test.yml" || FAILED=1

cat >"$WORK/in/run.sh" <<'RUN'
#!/bin/sh
cd /tmp/w || exit 1
URL=http://127.0.0.1:9090
if promtool test rules dashboard.test.yml >dashboard.log 2>&1; then
  echo "ok  dashboard queries"
else
  echo "not ok  a dashboard query returns no data for the host, or data for another host:"
  grep -E 'expr:|name:' dashboard.log | head -n 20
fi
printf 'global:\n  evaluation_interval: 1m\nrule_files:\n  - /tmp/w/windows.yml\n' >prometheus.yml
prometheus --config.file=prometheus.yml --storage.tsdb.path=/tmp/tsdb \
  --web.listen-address=127.0.0.1:9090 --log.level=error >prometheus.log 2>&1 &
for _ in $(seq 1 60); do
  wget -qO- "$URL/-/ready" >/dev/null 2>&1 && break
  sleep 1
done
wget -qO rules.json "$URL/api/v1/rules" || echo "not ok  Prometheus did not load windows.yml: $(tail -n 2 prometheus.log)"
echo "RULES $(cat rules.json 2>/dev/null)"
RUN

# Files travel over stdin: a bind mount of $TMPDIR is empty on a Docker VM.
tar -C "$WORK/in" -cf - . | docker run -i --rm --pull=never --network none --entrypoint /bin/sh "$PROM_IMAGE" \
  -c 'mkdir -p /tmp/w && tar -xf - -C /tmp/w && sh /tmp/w/run.sh' >"$WORK/prom.log"
grep -q '^ok  dashboard queries$' "$WORK/prom.log" || FAILED=1
grep -v '^RULES ' "$WORK/prom.log" | grep -v '^ok  ' || true

contract rules --log "$WORK/prom.log" --repo "$REPO_ROOT" --inventory "$INVENTORY" --allowlist "$ALLOWLIST" \
  --routes "$WORK/in/alerts.txt" || FAILED=1
[[ -s "$WORK/in/alerts.txt" ]] || die "no Windows alert was read from Prometheus"

# The labels are the ones Prometheus loaded, so a rule that loses its shadow
# label here is the same rule that would reach Telegram.
cat >"$WORK/in/routes.sh" <<'ROUTES'
#!/bin/sh
while IFS= read -r labels; do
  # shellcheck disable=SC2086
  if amtool config routes test --config.file=/tmp/w/alertmanager.yml --verify.receivers=shadow-null \
    $labels >/tmp/route.log 2>&1; then
    echo "ok  $labels"
  else
    echo "not ok  $labels reaches $(head -n 1 /tmp/route.log)"
  fi
done </tmp/w/alerts.txt
ROUTES
tar -C "$WORK/in" -cf - alertmanager.yml alerts.txt routes.sh | \
  docker run -i --rm --pull=never --network none --entrypoint /bin/sh "$AM_IMAGE" \
    -c 'mkdir -p /tmp/w && tar -xf - -C /tmp/w && sh /tmp/w/routes.sh' >"$WORK/routes.log"
routed="$(grep -c '^ok  ' "$WORK/routes.log" || true)"
grep '^not ok' "$WORK/routes.log" && FAILED=1
[[ "$routed" == "$(grep -c . "$WORK/in/alerts.txt")" ]] || record "not every Windows alert was routed to shadow-null"

[[ "$FAILED" == "0" ]] || die "Windows rules or dashboard do not meet the central contract"
printf 'PASS: Windows central: %s shadow alerts routed to shadow-null, dashboard queries scoped and answered\n' "$routed"
