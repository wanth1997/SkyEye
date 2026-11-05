#!/usr/bin/env bash
set -euo pipefail

# Runs what SkyEye shows about itself instead of reading it: the Stack health
# queries from the dashboard JSON, a real Prometheus for the metrics those queries
# and the rule-speed alerts read, and the labels it loads through the real routing
# tree. Containers have no network and no secret reaches them. Every check runs
# even after one fails, so a failure lists everything that is wrong.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DASHBOARD="$REPO_ROOT/grafana/dashboards/SkyEye/skyeye-stack-health.json"
FAILED=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

record() {
  printf 'not ok  %s\n' "$*"
  FAILED=1
}

image() {
  sed -n -E "s/^[[:space:]]*image:[[:space:]]*($1:[^[:space:]]+).*\$/\\1/p" \
    "$REPO_ROOT/docker-compose.yml" | head -n 1
}

command -v docker >/dev/null 2>&1 || fail "docker is required; this suite must not pass by skipping"
PROM_IMAGE="$(image 'prom\/prometheus')"
AM_IMAGE="$(image 'prom\/alertmanager')"
[[ -n "$PROM_IMAGE" && -n "$AM_IMAGE" ]] || fail "cannot find the pinned images"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-stack-signals.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp "$REPO_ROOT/prometheus/rules/stack-health.yml" "$REPO_ROOT/prometheus/rules/system.yml" "$WORK/"
cp "$REPO_ROOT/alertmanager/alertmanager.yml" "$WORK/alertmanager.yml"

# Panels are found by id: a renamed title must not hide a wrong query.
python3 -I - "$DASHBOARD" "$WORK/dashboard.test.yml" "$WORK/panel-22.promql" <<'PY'
import json, sys
dashboard, output, live = sys.argv[1:4]
panels = {p["id"]: p for p in json.load(open(dashboard, encoding="utf-8"))["panels"]}
def query(panel):
    return panels[panel]["targets"][0]["expr"]
def case(name, panel, series, value):
    return {"name": name, "interval": "1m",
            "input_series": [{"series": s, "values": v} for s, v in series],
            "promql_expr_test": [{"expr": query(panel), "eval_time": "2m",
                                  "exp_samples": [{"labels": "{}", "value": value}]}]}
up = lambda *values: [(f'up{{job="{i}"}}', f"{v}x5") for i, v in enumerate(values)]
probe = lambda *values: [(f'probe_success{{target="{i}"}}', f"{v}x5") for i, v in enumerate(values)]
summary = [(f'prometheus_rule_evaluation_duration_seconds{{quantile="{q}"}}', f"{v}x5")
           for q, v in (("0.5", 0.01), ("0.9", 0.1), ("0.99", 0.25))]
tests = [
    case("panel 12 counts offline targets", 12, up(0, 0, 1), 2),
    case("panel 12 stays 0 when every target is up", 12, up(1, 1), 0),
    case("panel 54 counts failing probes", 54, probe(0, 0, 1), 2),
    case("panel 54 stays 0 when every probe passes", 54, probe(1, 1), 0),
    case("panel 22 reads the p99 of the summary", 22, summary, 0.25),
]
json.dump({"evaluation_interval": "1m", "tests": tests}, open(output, "w", encoding="utf-8"), ensure_ascii=False)
open(live, "w", encoding="utf-8").write(query(22))
PY

cat >"$WORK/prometheus.yml" <<'CONFIG'
global:
  scrape_interval: 1s
rule_files:
  - /tmp/w/stack-health.yml
  - /tmp/w/system.yml
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:9090']
CONFIG

cat >"$WORK/run.sh" <<'RUN'
#!/bin/sh
cd /tmp/w
promtool test rules dashboard.test.yml >&2 || echo 'not ok  dashboard queries return the wrong value'

URL=http://127.0.0.1:9090
prometheus --config.file=/tmp/w/prometheus.yml --storage.tsdb.path=/tmp/p \
  --web.listen-address=127.0.0.1:9090 --log.level=error >/tmp/p.log 2>&1 &
# The first run of a 30s group lands up to 30 seconds after start, and the summary
# holds no value before it. NaN fails ">= 0", so this waits for a real number.
live() { # live NAME QUERY
  deadline=$(($(date +%s) + 45))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -n "$(promtool query instant $URL "($2) >= 0" 2>/dev/null)" ] && return
    sleep 1
  done
  echo "not ok  $1 has no data on the pinned Prometheus"
}
live 'panel 22' "$(cat panel-22.promql)"
live 'PrometheusRuleEvalSlow input' \
  'prometheus_rule_group_last_duration_seconds / prometheus_rule_group_interval_seconds'
live 'PrometheusRuleIterationsMissed input' 'prometheus_rule_group_iterations_missed_total'
wget -qO /tmp/w/rules.json "$URL/api/v1/rules"
echo "RULES $(cat /tmp/w/rules.json)"
RUN

# Files travel over stdin: a bind mount of $TMPDIR is empty on a Docker VM.
tar -C "$WORK" -cf - . | docker run -i --rm --network none --entrypoint /bin/sh "$PROM_IMAGE" \
  -c 'mkdir -p /tmp/w && tar -xf - -C /tmp/w && sh /tmp/w/run.sh' >"$WORK/live.log"
while IFS= read -r line; do
  [[ "$line" == 'not ok'* ]] && record "${line#not ok  }"
done <"$WORK/live.log"

# The labels are the ones Prometheus loaded, so a rule that loses its shadow label
# here is the same rule that would reach Telegram.
python3 -I - "$WORK/live.log" "$WORK/alerts.txt" <<'PY'
import json, sys
log, output = sys.argv[1:3]
line = next(l for l in open(log, encoding="utf-8") if l.startswith("RULES "))
rules = {r["name"]: r for g in json.loads(line[6:])["data"]["groups"] for r in g["rules"]}
with open(output, "w", encoding="utf-8") as out:
    for name in ("PrometheusRuleEvalSlow", "PrometheusRuleIterationsMissed", "SystemdUnitFailed"):
        labels = rules.get(name, {}).get("labels", {})
        fields = [f"alertname={name}"] + [f"{k}={v}" for k, v in sorted(labels.items())]
        out.write(" ".join(fields) + "\n")
PY

cat >"$WORK/routes.sh" <<'ROUTES'
#!/bin/sh
while IFS= read -r labels; do
  amtool config routes test --config.file=/tmp/w/alertmanager.yml --verify.receivers=shadow-null \
    $labels >/tmp/route.log 2>&1 || echo "not ok  $labels reaches $(head -n 1 /tmp/route.log)"
done </tmp/w/alerts.txt
ROUTES
tar -C "$WORK" -cf - alertmanager.yml alerts.txt routes.sh | \
  docker run -i --rm --network none --entrypoint /bin/sh "$AM_IMAGE" \
    -c 'mkdir -p /tmp/w && tar -xf - -C /tmp/w && sh /tmp/w/routes.sh' >"$WORK/routes.log"
while IFS= read -r line; do
  [[ "$line" == 'not ok'* ]] && record "${line#not ok  }"
done <"$WORK/routes.log"

[[ "$FAILED" -eq 0 ]] || exit 1
printf 'PASS: Stack health queries, rule inputs and shadow routing\n'
