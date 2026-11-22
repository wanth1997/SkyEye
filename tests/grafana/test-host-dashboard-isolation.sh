#!/usr/bin/env bash
set -euo pipefail

# Regression and behavior test for host-level Grafana dashboards:
# 1. Verifies every metric selector in hosts-node-exporter.json filters by
#    server_id="$server_id" (in addition to instance="$node" and job="$job")
#    and parses cleanly with promtool check rules on the pinned Prometheus image.
# 2. Runs promtool test rules against the actual panel queries extracted from
#    hosts-node-exporter.json and overview-all.json to prove:
#    - Two hosts sharing the same job and instance do not mix data when
#      server_id="PROD02" is selected.
#    - PROD02 host panels return identical values under both product="ppclub"
#      and product="services".
#    - overview-all excludes product="services" from product counts and
#      Traffic Light while preserving per-product host metrics via server_id.

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-host-dash.XXXXXX")"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

FAILED=0

python3 -I - "$REPO_ROOT" "$WORK" <<'PY' || FAILED=1
import json
import os
import re
import sys

repo_root, work = sys.argv[1:3]
hosts_path = os.path.join(repo_root, "grafana/dashboards/Hosts/hosts-node-exporter.json")
overview_path = os.path.join(repo_root, "grafana/dashboards/Overview/overview-all.json")

hosts = json.load(open(hosts_path, encoding="utf-8"))
overview = json.load(open(overview_path, encoding="utf-8"))

failed = False

def check(ok, msg):
    global failed
    print(("ok      " if ok else "not ok  ") + msg)
    failed = failed or not ok

# 1. Walk all panels in hosts-node-exporter.json
host_targets = []
host_by_id = {}

def walk(panels):
    for p in panels or []:
        if isinstance(p, dict):
            pid = p.get("id")
            if pid is not None:
                host_by_id[pid] = p
            for t in p.get("targets") or []:
                if isinstance(t, dict) and "expr" in t:
                    host_targets.append((pid, p.get("title", ""), t.get("refId", ""), t["expr"]))
            walk(p.get("panels"))

walk(hosts.get("panels"))

check(len(host_targets) > 0, f"discovered {len(host_targets)} panel targets in hosts-node-exporter.json")

# Check zero $product references in hosts-node-exporter.json
hosts_raw = open(hosts_path, encoding="utf-8").read()
check("$product" not in hosts_raw, "hosts-node-exporter.json contains zero $product references")

# Check every metric selector in every panel target carries server_id="$server_id", instance="$node", job="$job"
selector_re = re.compile(r"([a-zA-Z_:][a-zA-Z0-9_:]*)\s*\{([^}]*)\}")
bare_metric_re = re.compile(r"\b((?:node|process)_[a-zA-Z0-9_:]*)\b(?!\s*\{)")

total_selectors = 0
missing_server_id = []
missing_instance = []
missing_job = []
bare_metrics = []
non_metric_braces = []

for pid, title, ref, expr in host_targets:
    for m in re.finditer(r"(?<!\$)\{([^}]*)\}", expr):
        prefix = expr[:m.start()]
        if not re.search(r"[a-zA-Z_:][a-zA-Z0-9_:]*\s*$", prefix):
            non_metric_braces.append(f"panel {pid}/{ref}")
    for m in selector_re.finditer(expr):
        total_selectors += 1
        body = m.group(2)
        if not re.search(r'server_id\s*=\s*"\$server_id"', body):
            missing_server_id.append(f"panel {pid}/{ref}: {m.group(0)}")
        if not re.search(r'instance\s*=\s*"\$node"', body):
            missing_instance.append(f"panel {pid}/{ref}: {m.group(0)}")
        if not re.search(r'job\s*=\s*"\$job"', body):
            missing_job.append(f"panel {pid}/{ref}: {m.group(0)}")
    for m in bare_metric_re.finditer(expr):
        bare_metrics.append(f"panel {pid}/{ref}: {m.group(1)}")

check(total_selectors > 0 and not non_metric_braces,
      f"all {total_selectors} brace selectors in hosts-node-exporter.json are metric selectors")
check(not bare_metrics,
      "hosts-node-exporter.json has zero bare node_*/process_* metrics without label selectors"
      + ("" if not bare_metrics else f" ({len(bare_metrics)}: {bare_metrics[0]})"))
check(not missing_server_id,
      f'all {total_selectors} metric selectors across {len(host_targets)} targets include server_id="$server_id"'
      + ("" if not missing_server_id else f" ({len(missing_server_id)} missing, e.g. {missing_server_id[0]})"))
check(not missing_instance,
      f'all {total_selectors} metric selectors preserve instance="$node"'
      + ("" if not missing_instance else f" ({len(missing_instance)} missing, e.g. {missing_instance[0]})"))
check(not missing_job,
      f'all {total_selectors} metric selectors preserve job="$job"'
      + ("" if not missing_job else f" ({len(missing_job)} missing, e.g. {missing_job[0]})"))

# 2. Generate recording-rules YAML to syntax-check ALL 284 hosts-node-exporter queries via promtool
def subst_host(expr):
    return (
        expr.replace("$server_id", "PROD02")
            .replace("$node", "PROD02")
            .replace("$job", "integrations/unix")
            .replace("$__rate_interval", "1m")
    )

rules_lines = ["groups:", "  - name: hosts_node_exporter_syntax", "    rules:"]
for idx, (pid, _, ref, expr) in enumerate(host_targets):
    sub = " ".join(subst_host(expr).split())
    rules_lines.append(f"      - record: test_host_panel_{pid}_{idx}")
    rules_lines.append(f"        expr: {json.dumps(sub)}")

with open(os.path.join(work, "syntax-rules.yml"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(rules_lines) + "\n")

# 3. Build real promtool behavior test from actual panel expressions in both dashboards
def get_expr(panels_by_id, pid, ref="A"):
    for t in panels_by_id[pid]["targets"]:
        if t.get("refId") == ref:
            return t["expr"]
    raise KeyError((pid, ref))

overview_by_id = {p["id"]: p for p in overview["panels"] if "id" in p}

expr_mem_total = subst_host(get_expr(host_by_id, 75, "A"))
expr_cpu_busy = subst_host(get_expr(host_by_id, 20, "A"))
expr_mem_pct = subst_host(get_expr(host_by_id, 16, "B"))
expr_root_pct = subst_host(get_expr(host_by_id, 154, "A"))

expr_ov_prod_cnt = get_expr(overview_by_id, 10, "A")
expr_ov_down_cnt = get_expr(overview_by_id, 11, "A")
expr_ov_cpu = get_expr(overview_by_id, 20, "A").replace("$server_id", "PROD02")
expr_ov_ram = get_expr(overview_by_id, 21, "A").replace("$server_id", "PROD02")
expr_ov_disk = get_expr(overview_by_id, 22, "A").replace("$server_id", "PROD02")
expr_ov_trend = get_expr(overview_by_id, 30, "A")
expr_ov_tl_cpu = get_expr(overview_by_id, 50, "E")
expr_ov_tl_ram = get_expr(overview_by_id, 50, "F")
expr_ov_tl_disk = get_expr(overview_by_id, 50, "G")

def yaml_expr(expr):
    return json.dumps(" ".join(expr.split()))

behavior_yml = f"""evaluation_interval: 30s
tests:
  - name: hosts-node-exporter isolates same-instance hosts by server_id across ppclub and services
    interval: 30s
    input_series:
      # PROD02 transitions product="ppclub" -> product="services" at 5m
      - series: 'node_memory_MemTotal_bytes{{job="integrations/unix",instance="PROD02",product="ppclub",server_id="PROD02"}}'
        values: '100x11'
      - series: 'node_memory_MemAvailable_bytes{{job="integrations/unix",instance="PROD02",product="ppclub",server_id="PROD02"}}'
        values: '40x11'
      - series: 'node_memory_MemTotal_bytes{{job="integrations/unix",instance="PROD02",product="services",server_id="PROD02"}}'
        values: '_x10 100x13'
      - series: 'node_memory_MemAvailable_bytes{{job="integrations/unix",instance="PROD02",product="services",server_id="PROD02"}}'
        values: '_x10 40x13'
      - series: 'node_cpu_seconds_total{{job="integrations/unix",instance="PROD02",product="ppclub",server_id="PROD02",cpu="0",mode="idle"}}'
        values: '0+15x11'
      - series: 'node_cpu_seconds_total{{job="integrations/unix",instance="PROD02",product="services",server_id="PROD02",cpu="0",mode="idle"}}'
        values: '_x10 150+15x13'
      - series: 'node_filesystem_size_bytes{{job="integrations/unix",instance="PROD02",product="ppclub",server_id="PROD02",mountpoint="/",fstype="ext4"}}'
        values: '100x11'
      - series: 'node_filesystem_avail_bytes{{job="integrations/unix",instance="PROD02",product="ppclub",server_id="PROD02",mountpoint="/",fstype="ext4"}}'
        values: '25x11'
      - series: 'node_filesystem_size_bytes{{job="integrations/unix",instance="PROD02",product="services",server_id="PROD02",mountpoint="/",fstype="ext4"}}'
        values: '_x10 100x13'
      - series: 'node_filesystem_avail_bytes{{job="integrations/unix",instance="PROD02",product="services",server_id="PROD02",mountpoint="/",fstype="ext4"}}'
        values: '_x10 25x13'
      # Second host with the EXACT SAME job and instance="PROD02" but a different server_id
      - series: 'node_memory_MemTotal_bytes{{job="integrations/unix",instance="PROD02",product="other",server_id="OTHER-HOST"}}'
        values: '200x23'
      - series: 'node_memory_MemAvailable_bytes{{job="integrations/unix",instance="PROD02",product="other",server_id="OTHER-HOST"}}'
        values: '150x23'
      - series: 'node_cpu_seconds_total{{job="integrations/unix",instance="PROD02",product="other",server_id="OTHER-HOST",cpu="0",mode="idle"}}'
        values: '0+27x23'
      - series: 'node_filesystem_size_bytes{{job="integrations/unix",instance="PROD02",product="other",server_id="OTHER-HOST",mountpoint="/",fstype="ext4"}}'
        values: '100x23'
      - series: 'node_filesystem_avail_bytes{{job="integrations/unix",instance="PROD02",product="other",server_id="OTHER-HOST",mountpoint="/",fstype="ext4"}}'
        values: '75x23'
      # App and host up series for overview-all checks
      - series: 'up{{job="integrations/unix",instance="PROD02",product="ppclub",server_id="PROD02"}}'
        values: '1x11'
      - series: 'up{{job="integrations/unix",instance="PROD02",product="services",server_id="PROD02"}}'
        values: '_x10 1x13'
      - series: 'up{{job="ppclub-backend",instance="localhost:8000",product="ppclub",server_id="PROD02"}}'
        values: '1x23'
      - series: 'up{{job="linkcourt-backend",instance="localhost:8001",product="linkcourt",server_id="PROD02"}}'
        values: '1x23'
      - series: 'up{{job="integrations/unix",instance="PROD02",product="other",server_id="OTHER-HOST"}}'
        values: '1x23'
    promql_expr_test:
      # hosts-node-exporter panel 75 (MemTotal): returns ONLY PROD02 (100), never OTHER-HOST (200)
      - expr: {yaml_expr(expr_mem_total)}
        eval_time: 3m
        exp_samples:
          - labels: 'node_memory_MemTotal_bytes{{instance="PROD02",job="integrations/unix",product="ppclub",server_id="PROD02"}}'
            value: 100
      - expr: {yaml_expr(expr_mem_total)}
        eval_time: 11m
        exp_samples:
          - labels: 'node_memory_MemTotal_bytes{{instance="PROD02",job="integrations/unix",product="services",server_id="PROD02"}}'
            value: 100
      # hosts-node-exporter panel 20 (CPU busy %): 50% for PROD02, not 30% averaged with OTHER-HOST
      - expr: {yaml_expr(expr_cpu_busy)}
        eval_time: 3m
        exp_samples:
          - labels: '{{}}'
            value: 50
      - expr: {yaml_expr(expr_cpu_busy)}
        eval_time: 11m
        exp_samples:
          - labels: '{{}}'
            value: 50
      # hosts-node-exporter panel 16 (RAM used %): 60% for PROD02 only
      - expr: {yaml_expr(expr_mem_pct)}
        eval_time: 3m
        exp_samples:
          - labels: '{{instance="PROD02",job="integrations/unix",product="ppclub",server_id="PROD02"}}'
            value: 60
      - expr: {yaml_expr(expr_mem_pct)}
        eval_time: 11m
        exp_samples:
          - labels: '{{instance="PROD02",job="integrations/unix",product="services",server_id="PROD02"}}'
            value: 60
      # hosts-node-exporter panel 154 (Root FS used %): 75% for PROD02 only
      - expr: {yaml_expr(expr_root_pct)}
        eval_time: 3m
        exp_samples:
          - labels: '{{fstype="ext4",instance="PROD02",job="integrations/unix",mountpoint="/",product="ppclub",server_id="PROD02"}}'
            value: 75
      - expr: {yaml_expr(expr_root_pct)}
        eval_time: 11m
        exp_samples:
          - labels: '{{fstype="ext4",instance="PROD02",job="integrations/unix",mountpoint="/",product="services",server_id="PROD02"}}'
            value: 75
      # overview-all panels 10 & 11: services excluded (ppclub, linkcourt, other = 3)
      - expr: {yaml_expr(expr_ov_prod_cnt)}
        eval_time: 11m
        exp_samples:
          - labels: '{{}}'
            value: 3
      - expr: {yaml_expr(expr_ov_down_cnt)}
        eval_time: 11m
        exp_samples:
          - labels: '{{}}'
            value: 0
      # overview-all panels 20-22: PROD02 gauges identical across ppclub, overlap (5m), and services
      - expr: {yaml_expr(expr_ov_cpu)}
        eval_time: 11m
        exp_samples:
          - labels: '{{server_id="PROD02"}}'
            value: 50
      - expr: {yaml_expr(expr_ov_ram)}
        eval_time: 5m
        exp_samples:
          - labels: '{{server_id="PROD02"}}'
            value: 60
      - expr: {yaml_expr(expr_ov_ram)}
        eval_time: 11m
        exp_samples:
          - labels: '{{server_id="PROD02"}}'
            value: 60
      - expr: {yaml_expr(expr_ov_disk)}
        eval_time: 11m
        exp_samples:
          - labels: '{{server_id="PROD02"}}'
            value: 75
      # overview-all panel 30: CPU % by server_id
      - expr: {yaml_expr(expr_ov_trend)}
        eval_time: 11m
        exp_samples:
          - labels: '{{server_id="PROD02"}}'
            value: 50
          - labels: '{{server_id="OTHER-HOST"}}'
            value: 10
      # overview-all panel 50 E/F/G: Traffic Light attaches PROD02 host stats to ppclub & linkcourt, excludes services
      - expr: {yaml_expr(expr_ov_tl_cpu)}
        eval_time: 11m
        exp_samples:
          - labels: '{{product="ppclub"}}'
            value: 50
          - labels: '{{product="linkcourt"}}'
            value: 50
          - labels: '{{product="other"}}'
            value: 10
      - expr: {yaml_expr(expr_ov_tl_ram)}
        eval_time: 11m
        exp_samples:
          - labels: '{{product="ppclub"}}'
            value: 60
          - labels: '{{product="linkcourt"}}'
            value: 60
          - labels: '{{product="other"}}'
            value: 25
      - expr: {yaml_expr(expr_ov_tl_disk)}
        eval_time: 11m
        exp_samples:
          - labels: '{{product="ppclub"}}'
            value: 75
          - labels: '{{product="linkcourt"}}'
            value: 75
          - labels: '{{product="other"}}'
            value: 25
"""

with open(os.path.join(work, "behavior.test.yml"), "w", encoding="utf-8") as fh:
    fh.write(behavior_yml)

sys.exit(1 if failed else 0)
PY

if docker run --rm --pull never --network none -i --entrypoint sh "$PROM_IMAGE" \
  -c 'cat > /tmp/syntax-rules.yml && promtool check rules /tmp/syntax-rules.yml >/dev/null' \
  <"$WORK/syntax-rules.yml"; then
  printf 'ok      promtool check rules parsed all hosts-node-exporter.json panel queries\n'
else
  printf 'not ok  promtool check rules failed on hosts-node-exporter.json panel queries\n'
  FAILED=1
fi

if docker run --rm --pull never --network none -i --entrypoint sh "$PROM_IMAGE" \
  -c 'cat > /tmp/behavior.test.yml && promtool test rules /tmp/behavior.test.yml' \
  <"$WORK/behavior.test.yml"; then
  printf 'ok      promtool behavior test passed for host isolation and services label\n'
else
  printf 'not ok  promtool behavior test failed\n'
  FAILED=1
fi

if [[ "$FAILED" -ne 0 ]]; then
  printf 'FAIL: host dashboard server_id isolation and services-label checks failed\n'
  exit 1
fi
printf 'PASS: host dashboard server_id isolation and services-label checks passed\n'
