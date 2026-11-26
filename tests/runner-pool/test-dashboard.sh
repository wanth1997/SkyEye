#!/usr/bin/env bash
set -euo pipefail

# Validates grafana/dashboards/Hosts/hosts-runner-pool.json and verifies that
# the new job="pool-status" (which carries no `product` or `server_id` target
# label) does not skew `up` counts on overview-all.json or
# skyeye-stack-health.json.
#
# Runs against the pinned Prometheus image with --pull never --network none.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for tool in docker python3 jq awk; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required; this suite must not pass by failing to run"
done

PROM_IMAGE="$(awk '$1 == "image:" && index($2, "prom/prometheus:") == 1 { print $2; exit }' "$REPO_ROOT/docker-compose.yml")"
[[ -n "$PROM_IMAGE" ]] || fail "cannot find prom/prometheus image in docker-compose.yml"

docker image inspect "$PROM_IMAGE" >/dev/null 2>&1 || \
  fail "$PROM_IMAGE is not on this machine; run docker pull $PROM_IMAGE (this suite never pulls)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-pool-dash.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAILED=0

python3 -I - "$REPO_ROOT" "$WORK" <<'PY' || FAILED=1
import json
import os
import re
import sys

repo_root, work = sys.argv[1:3]
pool_dash_path = os.path.join(repo_root, "grafana/dashboards/Hosts/hosts-runner-pool.json")
overview_path = os.path.join(repo_root, "grafana/dashboards/Overview/overview-all.json")
stack_path = os.path.join(repo_root, "grafana/dashboards/SkyEye/skyeye-stack-health.json")

pool_dash = json.load(open(pool_dash_path, encoding="utf-8"))
overview = json.load(open(overview_path, encoding="utf-8"))
stack = json.load(open(stack_path, encoding="utf-8"))

failed = False
def check(ok, msg):
    global failed
    print(("ok      " if ok else "not ok  ") + msg)
    failed = failed or not ok

# 1. Conventions checks on hosts-runner-pool.json
check(pool_dash.get("uid") == "hosts-runner-pool",
      f'uid is "hosts-runner-pool" (got {pool_dash.get("uid")!r})')
check(pool_dash.get("title") == "主機 — Runner 池",
      f'title matches convention (got {pool_dash.get("title")!r})')
check(pool_dash.get("refresh") == "30s",
      f'refresh is "30s" (got {pool_dash.get("refresh")!r})')
check(set(["layer:host", "product:runner-pool", "provisioned"]).issubset(set(pool_dash.get("tags") or [])),
      "tags include layer:host, product:runner-pool, provisioned")

# Walk panels and targets, validate pinned datasource UIDs
pool_targets = []
pool_by_id = {}
bad_ds = []

def walk(panels):
    for p in panels or []:
        if not isinstance(p, dict):
            continue
        pid = p.get("id")
        if pid is not None:
            pool_by_id[pid] = p
        ds = p.get("datasource")
        if ds is not None and (ds.get("uid") not in ("prometheus", "loki", "alertmanager")):
            bad_ds.append(f"panel {pid}: {ds}")
        for t in p.get("targets") or []:
            if isinstance(t, dict):
                tds = t.get("datasource")
                if tds is None or tds.get("uid") not in ("prometheus", "loki", "alertmanager"):
                    bad_ds.append(f"panel {pid}/{t.get('refId')}: {tds}")
                if "expr" in t:
                    pool_targets.append((pid, p.get("title", ""), t.get("refId", ""), t["expr"]))
        walk(p.get("panels"))

walk(pool_dash.get("panels"))
check(len(pool_targets) > 0, f"discovered {len(pool_targets)} PromQL targets in hosts-runner-pool.json")
check(not bad_ds, "every panel and target uses a pinned datasource UID" + ("" if not bad_ds else f" ({bad_ds[0]})"))
check(any(expr == 'ALERTS{product="runner-pool"}' for _, _, _, expr in pool_targets),
      'dashboard includes an alert panel filtering ALERTS{product="runner-pool"} (including shadow)')

# C8: Panel 10 status-age uses ceil(...) and turns red starting at 121 (strictly > 120s).
age_steps = None
for ov in (pool_by_id[10].get("fieldConfig") or {}).get("overrides") or []:
    if (ov.get("matcher") or {}).get("options") == "狀態年齡":
        for prop in ov.get("properties") or []:
            if prop.get("id") == "thresholds":
                age_steps = (prop.get("value") or {}).get("steps") or []

def grafana_threshold_color(steps, val):
    color = None
    for step in steps:
        bound = step.get("value")
        if bound is None or val >= bound:
            color = step.get("color")
    return color

check(age_steps is not None
      and any(s.get("color") == "red" and s.get("value") == 121 for s in age_steps)
      and grafana_threshold_color(age_steps, 89) == "green"
      and grafana_threshold_color(age_steps, 90) == "yellow"
      and grafana_threshold_color(age_steps, 120) == "yellow"
      and grafana_threshold_color(age_steps, 121) == "red",
      f"panel 10 status-age threshold colors 120 as yellow and 121 (ceil of 120.001s) as red (steps={age_steps!r})")

# 2. Recording rules file to syntax-check ALL hosts-runner-pool.json PromQL queries
rules_lines = ["groups:", "  - name: hosts_runner_pool_syntax", "    rules:"]
for idx, (pid, _, _, expr) in enumerate(pool_targets):
    rules_lines.append(f"      - record: test_pool_panel_{pid}_{idx}")
    rules_lines.append(f"        expr: {json.dumps(' '.join(expr.split()))}")
open(os.path.join(work, "syntax-rules.yml"), "w", encoding="utf-8").write("\n".join(rules_lines) + "\n")

# 3. Behavior test: key hosts-runner-pool queries + Overview / Stack health `up` regression with job="pool-status"
def get_expr(panels_by_id, pid, ref="A"):
    for t in panels_by_id[pid]["targets"]:
        if t.get("refId") == ref:
            return t["expr"]
    raise KeyError((pid, ref))

def yaml_expr(expr):
    return json.dumps(" ".join(expr.split()))

overview_by_id = {p["id"]: p for p in overview["panels"] if "id" in p}
stack_by_id = {p["id"]: p for p in stack["panels"] if "id" in p}

behavior_yml = f"""evaluation_interval: 1m
tests:
  - name: hosts-runner-pool table queries return one row per host and attach wans-windows up to pc
    interval: 1m
    input_series:
      - series: 'pool_status_expected{{job="pool-status",instance="pool-status:9101",host="pc"}}'
        values: '1x5'
      - series: 'pool_status_expected{{job="pool-status",instance="pool-status:9101",host="srv"}}'
        values: '1x5'
      - series: 'pool_status_updated_timestamp_seconds{{job="pool-status",instance="pool-status:9101",host="pc"}}'
        values: '0 35 95 155 215'
      - series: 'pool_status_updated_timestamp_seconds{{job="pool-status",instance="pool-status:9101",host="srv"}}'
        values: '0 35 95 155 215'
      - series: 'pool_status_state{{job="pool-status",instance="pool-status:9101",host="pc",state="accepting"}}'
        values: '1x5'
      - series: 'pool_status_state{{job="pool-status",instance="pool-status:9101",host="pc",state="paused"}}'
        values: '0x5'
      - series: 'pool_status_state{{job="pool-status",instance="pool-status:9101",host="srv",state="draining"}}'
        values: '1x5'
      - series: 'pool_guard_state{{job="pool-status",instance="pool-status:9101",host="pc",state="ok"}}'
        values: '1x5'
      - series: 'pool_guard_state{{job="pool-status",instance="pool-status:9101",host="srv",state="none"}}'
        values: '1x5'
      - series: 'pool_guard_avail_bytes{{job="pool-status",instance="pool-status:9101",host="pc"}}'
        values: '9542041600x5'
      - series: 'up{{job="integrations/windows",instance="WIN-PC",product="github-runner",server_id="wans-windows"}}'
        values: '1x5'
      - series: 'pool_status_exporter_read_timestamp_seconds{{job="pool-status",instance="pool-status:9101"}}'
        values: '0 60 120 180 240'
    promql_expr_test:
      - expr: {yaml_expr(get_expr(pool_by_id, 10, "B"))}
        eval_time: 4m
        exp_samples:
          - labels: '{{host="pc"}}'
            value: 25
          - labels: '{{host="srv"}}'
            value: 25
      - expr: {yaml_expr(get_expr(pool_by_id, 10, "C"))}
        eval_time: 4m
        exp_samples:
          - labels: '{{host="pc"}}'
            value: 1
          - labels: '{{host="srv"}}'
            value: 4
      - expr: {yaml_expr(get_expr(pool_by_id, 10, "D"))}
        eval_time: 4m
        exp_samples:
          - labels: '{{host="pc"}}'
            value: 1
          - labels: '{{host="srv"}}'
            value: 2
      - expr: {yaml_expr(get_expr(pool_by_id, 10, "N"))}
        eval_time: 4m
        exp_samples:
          - labels: '{{host="pc"}}'
            value: 1
      - expr: {yaml_expr(get_expr(pool_by_id, 41, "A"))}
        eval_time: 4m
        exp_samples:
          - labels: '{{job="pool-status",instance="pool-status:9101"}}'
            value: 0

  - name: hosts-runner-pool status-age ceil maps exactly 120s to 120 (yellow) and 120.001s to 121 (red)
    interval: 1m
    input_series:
      # At eval_time=3m (time=180s):
      #   exact120 updated at 60.000 -> age = 120.000s -> ceil = 120 (yellow, < 121)
      #   ms120    updated at 59.999 -> age = 120.001s -> ceil = 121 (red, >= 121)
      - series: 'pool_status_updated_timestamp_seconds{{job="pool-status",instance="pool-status:9101",host="exact120"}}'
        values: '60x5'
      - series: 'pool_status_updated_timestamp_seconds{{job="pool-status",instance="pool-status:9101",host="ms120"}}'
        values: '59.999x5'
    promql_expr_test:
      - expr: {yaml_expr(get_expr(pool_by_id, 10, "B"))}
        eval_time: 3m
        exp_samples:
          - labels: '{{host="exact120"}}'
            value: 120
          - labels: '{{host="ms120"}}'
            value: 121

  - name: hosts-runner-pool Windows-layer panels distinguish fresh up=1, fresh up=0, stale sample and missing
    interval: 1m
    input_series:
      # t=0..2m: fresh up=1; t=3m..4m: fresh up=0; t=5m: fresh up=1 then stops pushing (no stale
      # marker because remote_write pushes): at t=8m (age=180s > 120s, still inside 5m lookback)
      # sample is stale (must return 2, not 1); at t=11m (age=360s > 5m lookback) sample is missing ([]).
      - series: 'up{{job="integrations/windows",instance="WIN-PC",product="github-runner",server_id="wans-windows"}}'
        values: '1 1 1 0 0 1 _x10'
    promql_expr_test:
      # Fresh up == 1 at t=2m -> 1
      - expr: {yaml_expr(get_expr(pool_by_id, 10, "N"))}
        eval_time: 2m
        exp_samples:
          - labels: '{{host="pc"}}'
            value: 1
      - expr: {yaml_expr(get_expr(pool_by_id, 11, "A"))}
        eval_time: 2m
        exp_samples:
          - labels: '{{}}'
            value: 1
      # Fresh up == 0 at t=4m -> 0
      - expr: {yaml_expr(get_expr(pool_by_id, 10, "N"))}
        eval_time: 4m
        exp_samples:
          - labels: '{{host="pc"}}'
            value: 0
      - expr: {yaml_expr(get_expr(pool_by_id, 11, "A"))}
        eval_time: 4m
        exp_samples:
          - labels: '{{}}'
            value: 0
      # Stale sample (last push at t=5m, now t=8m => age=180s > 120s) -> 2 (not 1)
      - expr: {yaml_expr(get_expr(pool_by_id, 10, "N"))}
        eval_time: 8m
        exp_samples:
          - labels: '{{host="pc"}}'
            value: 2
      - expr: {yaml_expr(get_expr(pool_by_id, 11, "A"))}
        eval_time: 8m
        exp_samples:
          - labels: '{{}}'
            value: 2
      # Missing sample (last push at t=5m, now t=11m => beyond 5m lookback) -> []
      - expr: {yaml_expr(get_expr(pool_by_id, 10, "N"))}
        eval_time: 11m
        exp_samples: []
      - expr: {yaml_expr(get_expr(pool_by_id, 11, "A"))}
        eval_time: 11m
        exp_samples: []

  - name: Overview and Stack health up panels handle new job="pool-status" (no product/server_id label) cleanly
    interval: 1m
    input_series:
      # Product targets
      - series: 'up{{job="ppclub-backend",instance="localhost:8000",product="ppclub",server_id="PROD02"}}'
        values: '1x5'
      - series: 'up{{job="integrations/windows",instance="WIN-PC",product="github-runner",server_id="wans-windows"}}'
        values: '1x5'
      # Shared services host (excluded from product counts)
      - series: 'up{{job="integrations/unix",instance="PROD02",product="services",server_id="PROD02"}}'
        values: '1x5'
      # Existing stack job without product label
      - series: 'up{{job="prometheus",instance="localhost:9090"}}'
        values: '1x5'
      # New pool-status job without product/server_id label: up=1 at t=2m, down=0 at t=4m
      - series: 'up{{job="pool-status",instance="pool-status:9101"}}'
        values: '1x3 0x2'
    promql_expr_test:
      # Overview panel 10 (被監測產品數): only ppclub and github-runner = 2 (pool-status NOT counted)
      - expr: {yaml_expr(get_expr(overview_by_id, 10, "A"))}
        eval_time: 2m
        exp_samples:
          - labels: '{{}}'
            value: 2
      # Overview panel 11 (離線產品數): stays 0 even when pool-status is down (up==0) at t=4m
      - expr: {yaml_expr(get_expr(overview_by_id, 11, "A"))}
        eval_time: 4m
        exp_samples:
          - labels: '{{}}'
            value: 0
      # Stack health panel 11 (上線目標數): 5 up at t=2m, 4 up at t=4m when pool-status goes down
      - expr: {yaml_expr(get_expr(stack_by_id, 11, "A"))}
        eval_time: 2m
        exp_samples:
          - labels: '{{}}'
            value: 5
      - expr: {yaml_expr(get_expr(stack_by_id, 11, "A"))}
        eval_time: 4m
        exp_samples:
          - labels: '{{}}'
            value: 4
      # Stack health panel 12 (離線目標數): 0 down at t=2m, 1 down at t=4m when pool-status goes down
      - expr: {yaml_expr(get_expr(stack_by_id, 12, "A"))}
        eval_time: 2m
        exp_samples:
          - labels: '{{}}'
            value: 0
      - expr: {yaml_expr(get_expr(stack_by_id, 12, "A"))}
        eval_time: 4m
        exp_samples:
          - labels: '{{}}'
            value: 1
"""

open(os.path.join(work, "behavior.test.yml"), "w", encoding="utf-8").write(behavior_yml)
sys.exit(1 if failed else 0)
PY

if docker run --rm --pull never --network none -i --entrypoint sh "$PROM_IMAGE" \
  -c 'cat > /tmp/syntax-rules.yml && promtool check rules /tmp/syntax-rules.yml >/dev/null' \
  <"$WORK/syntax-rules.yml"; then
  printf 'ok      promtool check rules parsed all hosts-runner-pool.json panel queries\n'
else
  printf 'not ok  promtool check rules failed on hosts-runner-pool.json panel queries\n'
  FAILED=1
fi

if docker run --rm --pull never --network none -i --entrypoint sh "$PROM_IMAGE" \
  -c 'cat > /tmp/behavior.test.yml && promtool test rules /tmp/behavior.test.yml' \
  <"$WORK/behavior.test.yml"; then
  printf 'ok      promtool behavior tests passed for hosts-runner-pool, overview-all and skyeye-stack-health\n'
else
  printf 'not ok  promtool behavior tests failed\n'
  FAILED=1
fi

if [[ "$FAILED" -ne 0 ]]; then
  printf 'FAIL: runner-pool dashboard checks failed\n'
  exit 1
fi
printf 'PASS: runner-pool dashboard queries and Overview/Stack health up-isolation passed\n'
