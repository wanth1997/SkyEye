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
# The modes are mixed so a filter on either one leaves the count short.
alerts = [("TradingCriticalSafetyState", "page"), ("TradingProcessDown", "page"),
          ("TradingRiskStopped", "page"), ("TradingDuplicateProcess", "shadow")]
promoted = ["rule_files:", "  - inventory.yml", "evaluation_interval: 30s", "tests:",
            "  - name: promoted and shadow alerts both count on the dashboard", "    interval: 30s", "    input_series:"]
for alert, mode in alerts:
    promoted += [f"      - series: 'ALERTS{{alertname=\"{alert}\",alertstate=\"firing\",notification_mode=\"{mode}\",severity=\"High\",{LABELS}}}'",
                 "        values: '1x40'"]
promoted += ["    promql_expr_test:"]
promoted += case(expr(summary, "E"), "{}", len(alerts))
# Query L also returns a zero row per inventory strategy, so sum the column.
promoted += case(f'sum({expr(fleet, "L")})', "{}", len(alerts))
open(output.replace("dashboard.test", "promoted.test"), "w", encoding="utf-8").write("\n".join(promoted) + "\n")

# Position quantities are in each lane's base asset. An ETH lane and a BTC lane
# must stay separate rows, each naming its own asset, on both dashboards. The
# fixture has no ETH target, so an inventoried one stands in for it. The BTC
# lane runs a probe from before TQ_BASE_ASSET and sends no label at all.
ETH_SERVER, ETH_STRATEGY = "trading01", "lighter-mainnet-btc-canary"
ETH_LABELS = f'product="tnauqquant",environment="production",server_id="{ETH_SERVER}",strategy="{ETH_STRATEGY}"'
position = targets("trading-strategy-detail.json", "目前持倉 · 多空方向")

def lane(queries, ref, server, strategy):
    if ref not in queries:
        sys.exit(f"FAIL: dashboard has no query {ref}")
    return queries[ref].replace("$server_id", server).replace("$strategy", strategy)

def rows(query, samples):
    quoted = query.replace("'", "''")
    out = [f"      - expr: '{quoted}'", "        eval_time: 1m", "        exp_samples:"]
    for labels, value in samples:
        out += [f"          - labels: '{labels}'", f"            value: {value}"]
    return out

units = ["rule_files:", "  - inventory.yml", "  - trading.yml", "evaluation_interval: 30s", "tests:",
         "  - name: ETH and BTC lanes keep their own position units", "    interval: 30s", "    input_series:",
         f"      - series: 'tnauqquant_current_net_position_btc{{{ETH_LABELS},base_asset=\"ETH\"}}'", "        values: '-0.1x5'",
         f"      - series: 'tnauqquant_current_position_btc{{{ETH_LABELS},base_asset=\"ETH\",exchange=\"popdex\",side=\"short\"}}'", "        values: '0.1x5'",
         f"      - series: 'tnauqquant_current_net_position_btc{scoped}'", "        values: '0.25x5'",
         f"      - series: 'tnauqquant_current_position_btc{{{LABELS},exchange=\"toobit\",side=\"long\"}}'", "        values: '0.25x5'",
         "    promql_expr_test:"]
units += rows(expr(fleet, "E"), [(f'{{strategy="{ETH_STRATEGY}",base_asset="ETH"}}', -0.1),
                                 (f'{{strategy="{STRATEGY}",base_asset="BTC"}}', 0.25)])
units += rows(lane(position, "B", ETH_SERVER, ETH_STRATEGY), [('{exchange="popdex",base_asset="ETH"}', -0.1)])
units += rows(lane(position, "D", ETH_SERVER, ETH_STRATEGY),
              [(f'trading_strategy_current_net_position_btc{{{ETH_LABELS},base_asset="ETH"}}', -0.1)])
units += rows(lane(position, "A", SERVER, STRATEGY), [('{exchange="toobit",base_asset="BTC"}', 0.25)])
units += rows(lane(position, "D", SERVER, STRATEGY),
              [(f'trading_strategy_current_net_position_btc{{{LABELS},base_asset="BTC"}}', 0.25)])
open(output.replace("dashboard.test", "units.test"), "w", encoding="utf-8").write("\n".join(units) + "\n")

# Multi-account breakdown table queries stay scoped to the selected strategy,
# show each allowlisted executor row, and keep merged top-level equity/volume intact.
MULTI_SERVER, MULTI_STRATEGY = "trading01", "lighter-robinhood-btc-canary"
MULTI_LABELS = f'product="tnauqquant",environment="production",server_id="{MULTI_SERVER}",strategy="{MULTI_STRATEGY}"'
breakdown = targets("trading-strategy-detail.json", "各帳號明細 · 多帳號策略")
equity_panel = targets("trading-strategy-detail.json", "目前餘額")
volume_panel = targets("trading-strategy-detail.json", "本輪成交額 · 依交易所")
multi = ["rule_files:", "  - inventory.yml", "  - trading.yml", "evaluation_interval: 30s", "tests:",
         "  - name: multi-account detail panel reports merged totals and per-executor breakdown", "    interval: 30s",
         "    input_series:",
         f"      - series: 'tnauqquant_current_equity_usdt{{{MULTI_LABELS}}}'", "        values: '10005.4231x5'",
         f"      - series: 'tnauqquant_current_run_exchange_volume_usd{{{MULTI_LABELS},exchange=\"popdex\"}}'", "        values: '79700.75x5'",
         f"      - series: 'tnauqquant_current_executor_equity_usdt{{{MULTI_LABELS},exchange=\"popdex\",executor=\"popdex-main\"}}'", "        values: '5002.1x5'",
         f"      - series: 'tnauqquant_current_executor_equity_usdt{{{MULTI_LABELS},exchange=\"popdex\",executor=\"popdex-rot2\"}}'", "        values: '5003.32x5'",
         f"      - series: 'tnauqquant_current_executor_real_pnl_usdt{{{MULTI_LABELS},exchange=\"popdex\",executor=\"popdex-main\"}}'", "        values: '2.1x5'",
         f"      - series: 'tnauqquant_current_executor_real_pnl_usdt{{{MULTI_LABELS},exchange=\"popdex\",executor=\"popdex-rot2\"}}'", "        values: '3.32x5'",
         f"      - series: 'tnauqquant_current_executor_cycles_completed{{{MULTI_LABELS},exchange=\"popdex\",executor=\"popdex-main\"}}'", "        values: '4x5'",
         f"      - series: 'tnauqquant_current_executor_cycles_completed{{{MULTI_LABELS},exchange=\"popdex\",executor=\"popdex-rot2\"}}'", "        values: '3x5'",
         f"      - series: 'tnauqquant_current_run_executor_volume_usd{{{MULTI_LABELS},exchange=\"popdex\",executor=\"popdex-main\"}}'", "        values: '41200.5x5'",
         f"      - series: 'tnauqquant_current_run_executor_volume_usd{{{MULTI_LABELS},exchange=\"popdex\",executor=\"popdex-rot2\"}}'", "        values: '38500.25x5'",
         "    promql_expr_test:"]
multi += rows(lane(equity_panel, "A", MULTI_SERVER, MULTI_STRATEGY),
              [(f'trading_strategy_current_equity_usdt{{{MULTI_LABELS}}}', 10005.4231)])
multi += rows(lane(volume_panel, "A", MULTI_SERVER, MULTI_STRATEGY),
              [(f'trading_strategy_current_run_exchange_volume_usd{{{MULTI_LABELS},exchange="popdex"}}', 79700.75)])
multi += rows(lane(breakdown, "A", MULTI_SERVER, MULTI_STRATEGY),
              [('{exchange="popdex",executor="popdex-main"}', 5002.1),
               ('{exchange="popdex",executor="popdex-rot2"}', 5003.32)])
multi += rows(lane(breakdown, "B", MULTI_SERVER, MULTI_STRATEGY),
              [('{executor="popdex-main"}', 2.1), ('{executor="popdex-rot2"}', 3.32)])
multi += rows(lane(breakdown, "C", MULTI_SERVER, MULTI_STRATEGY),
              [('{executor="popdex-main"}', 4), ('{executor="popdex-rot2"}', 3)])
multi += rows(lane(breakdown, "D", MULTI_SERVER, MULTI_STRATEGY),
              [('{executor="popdex-main"}', 41200.5), ('{executor="popdex-rot2"}', 38500.25)])
open(output.replace("dashboard.test", "multi.test"), "w", encoding="utf-8").write("\n".join(multi) + "\n")

# No position number on these panels may carry a fixed BTC unit, and every
# detail value must name its asset.
for name, title in [("trading-strategy-detail.json", "目前持倉 · 多空方向"),
                    ("trading-strategy-fleet.json", "策略損益與運行狀態 · 點選策略查看詳情")]:
    data = json.load(open(f"{dashboards}/{name}", encoding="utf-8"))
    panel = next(p for p in data["panels"] if p["title"] == title)
    if "BTC" in json.dumps(panel["fieldConfig"], ensure_ascii=False):
        sys.exit(f"FAIL: {name} {title} still fixes a BTC unit")
for target in next(p for p in json.load(open(f"{dashboards}/trading-strategy-detail.json", encoding="utf-8"))["panels"]
                   if p["title"] == "目前持倉 · 多空方向")["targets"]:
    if "{{base_asset}}" not in target.get("legendFormat", ""):
        sys.exit(f"FAIL: position query {target['refId']} does not name its base asset")
PY

tar -C "$WORK" -cf - . | docker run -i --rm --network none --entrypoint /bin/sh "$IMAGE" \
  -c 'mkdir -p /tmp/w && tar -xf - -C /tmp/w && cd /tmp/w && promtool test rules dashboard.test.yml promoted.test.yml units.test.yml multi.test.yml' || \
  fail "dashboard queries hide stale financial data, future timestamps, promoted alerts, position units or multi-account breakdown"
printf 'PASS: Trading dashboard freshness, promoted alert, position unit and multi-account breakdown semantics\n'
