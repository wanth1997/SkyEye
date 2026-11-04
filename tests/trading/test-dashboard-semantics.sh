#!/usr/bin/env bash
set -euo pipefail

# Evaluates the queries the Trading dashboards actually ship, read from their
# JSON, against stale financial data, a future-stamped probe and a promoted alert.
# A fresh probe must not make an old balance look current, a future time must not
# read as fresh, and promotion must not empty the alert count.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DASHBOARDS="$REPO_ROOT/grafana/dashboards/Trading"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fail "docker is required; this suite must not pass by skipping"
IMAGE="$(sed -n -E 's/^[[:space:]]*image:[[:space:]]*(prom\/prometheus:[^[:space:]]+).*$/\1/p' \
  "$REPO_ROOT/docker-compose.yml" | head -n 1)"
[[ -n "$IMAGE" ]] || fail "cannot find the pinned Prometheus image"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-dashboard-semantics.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp "$REPO_ROOT/prometheus/rules/trading.yml" "$WORK/trading.yml"
cp "$REPO_ROOT/prometheus/rules/tests/fixtures/trading-targets.yml" "$WORK/inventory.yml"

python3 -I - "$DASHBOARDS" "$WORK/dashboard.test.yml" <<'PY'
import json, sys
dashboards, output = sys.argv[1:3]
SERVER, STRATEGY = "macmini-m2", "toobit-mexc-btc"
LABELS = f'product="tnauqquant",environment="production",server_id="{SERVER}",strategy="{STRATEGY}"'

def targets(name, title):
    data = json.load(open(f"{dashboards}/{name}", encoding="utf-8"))
    panel = next(p for p in data["panels"] if p["title"] == title)
    return {t["refId"]: t["expr"] for t in panel["targets"]}

def expr(queries, ref):
    if ref not in queries:
        sys.exit(f"FAIL: dashboard has no query {ref}")
    return queries[ref].replace("$server_id", SERVER).replace("$strategy", STRATEGY)

detail = targets("trading-strategy-detail.json", "監控摘要")
fleet = targets("trading-strategy-fleet.json", "策略損益與運行狀態 · 點選策略查看詳情")
summary = targets("trading-strategy-fleet.json", "監控摘要")

def case(query, labels, value):
    quoted = query.replace("'", "''")
    return [f"      - expr: '{quoted}'", "        eval_time: 10m", "        exp_samples:",
            f"          - labels: '{labels}'", f"            value: {value}"]

scoped = f'{{{LABELS}}}'
out = ["rule_files:", "  - inventory.yml", "  - trading.yml", "evaluation_interval: 30s", "tests:",
       "  - name: a fresh probe does not make frozen financial data look current", "    interval: 30s",
       "    input_series:",
       f"      - series: 'tnauqquant_probe_timestamp_seconds{scoped}'", "        values: '0+30x40'",
       f"      - series: 'tnauqquant_pnl_sample_timestamp_seconds{scoped}'", "        values: '0x40'",
       f"      - series: 'tnauqquant_position_sample_timestamp_seconds{{{LABELS},source=\"venue\"}}'", "        values: '0x40'",
       "    promql_expr_test:"]
out += case(expr(detail, "F"), f'{{{LABELS}}}', 1)
out += case(expr(detail, "K"), f'{{{LABELS}}}', 600)
out += case(expr(detail, "L"), "{}", 600)
out += case(expr(fleet, "I"), f'{{strategy="{STRATEGY}"}}', 1)
out += case(expr(fleet, "O"), f'{{strategy="{STRATEGY}"}}', 600)
out += case(expr(fleet, "P"), f'{{strategy="{STRATEGY}"}}', 600)
out += ["  - name: a frozen probe stamped in the future is stale on every freshness view", "    interval: 30s",
        "    input_series:",
        f"      - series: 'tnauqquant_probe_timestamp_seconds{scoped}'", "        values: '4200x40'",
        "    promql_expr_test:"]
out += case(expr(detail, "F"), f'{{{LABELS}}}', 0)
out += case(expr(fleet, "I"), f'{{strategy="{STRATEGY}"}}', 0)
out += case(expr(fleet, "J"), f'{{strategy="{STRATEGY}"}}', 3600)
# Every fixture target is stale here, whatever the size of the fixture.
inventory = 'trading_target_info{product="tnauqquant",environment="production"}'
out += case(f'({expr(summary, "B")}) - scalar(count({inventory}))', "{}", 0)
open(output, "w", encoding="utf-8").write("\n".join(out) + "\n")

# Separate file without trading.yml: its own alerts would inflate the count.
promoted = ["rule_files:", "  - inventory.yml", "evaluation_interval: 30s", "tests:",
            "  - name: a promoted alert still counts on the dashboard", "    interval: 30s", "    input_series:",
            f"      - series: 'ALERTS{{alertname=\"TradingDuplicateProcess\",alertstate=\"firing\",notification_mode=\"page\",severity=\"High\",{LABELS}}}'",
            "        values: '1x40'", "    promql_expr_test:"]
promoted += case(expr(summary, "E"), "{}", 1)
# Query L also returns a zero row per inventory strategy, so sum the column.
promoted += case(f'sum({expr(fleet, "L")})', "{}", 1)
open(output.replace("dashboard.test", "promoted.test"), "w", encoding="utf-8").write("\n".join(promoted) + "\n")
PY

tar -C "$WORK" -cf - . | docker run -i --rm --network none --entrypoint /bin/sh "$IMAGE" \
  -c 'mkdir -p /tmp/w && tar -xf - -C /tmp/w && cd /tmp/w && promtool test rules dashboard.test.yml promoted.test.yml' || \
  fail "dashboard queries hide stale financial data, future timestamps or promoted alerts"
printf 'PASS: Trading dashboard freshness and promoted alert semantics\n'
