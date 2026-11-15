"""Sample generation and judging for the suites under tests/windows.

The shell tests render the real template and run it in the pinned images. This
file builds the synthetic input from scrub-cases.tsv and reads back what the
throwaway Loki or Prometheus stored. A leak is a plain substring check on the
stored text, so a result never depends on how a regex is written.
"""
import argparse
import datetime
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.parse

EVENTLOG_LABELS = {"job", "channel", "level", "product", "server_id"}
DIAG_LABELS = {"job", "level", "product", "server_id"}
MAX_STREAMS = 11
INGEST_TIMEOUT_SECONDS = 180
WORKER_MARKER = "FAKE-WORKER-ONLY-0001"


def read_cases(path):
    cases = []
    for raw in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith("#"):
            continue
        ident, source, expect, safe, marks, keep, payload = raw.split("\t")
        cases.append({
            "id": ident,
            "source": source,
            "expect": expect,
            "safe": safe == "yes",
            "markers": [] if marks == "-" else marks.split(","),
            "keep": "" if keep == "-" else keep,
            "payload": payload,
        })
    return cases


# ------------------------------------------------------------------ static

def stage_blocks(text):
    return re.findall(r"^  stage\.replace \{\n.*?^  \}\n", text, re.S | re.M)


def block_expression(block):
    raw = re.search(r"^\s*expression\s*=\s*`(.*)`$", block, re.M)
    if raw:
        return raw.group(1)
    quoted = re.search(r'^\s*expression\s*=\s*"(.*)"$', block, re.M)
    return quoted.group(1).replace("\\\\", "\\") if quoted else None


def component(text, header):
    """The body of one top-level block, e.g. 'loki.process "scrub"'."""
    found = re.search(r"^" + re.escape(header) + r" \{\n(.*?)^\}\n", text, re.S | re.M)
    return found.group(1) if found else None


def check_static(args):
    failures = []
    windows = pathlib.Path(args.template).read_text(encoding="utf-8")
    general = stage_blocks(pathlib.Path(args.general).read_text(encoding="utf-8"))
    scrub = component(windows, 'loki.process "scrub"')
    if scrub is None:
        print('FAIL static: the Windows template has no loki.process "scrub"')
        return 1
    blocks = stage_blocks(scrub)

    # "The same scrub rules as other agent logs" is held literally: the general
    # blocks, byte for byte and in order, come first. The 182 general cases of
    # tests/trading/test-scrub-pipeline.sh then cover them here too.
    if not general or blocks[:len(general)] != general:
        failures.append("the scrub no longer starts with the stage.replace blocks of config-logs.alloy.tmpl")
    if len(blocks) <= len(general):
        failures.append("the scrub has no Windows rule after the shared ones")

    # stage.replace rewrites capture groups only: an expression with none is a no-op.
    for block in blocks[len(general):]:
        expression = block_expression(block)
        if expression is None or re.compile(expression).groups == 0:
            failures.append(f"Windows expression has no capture group: {expression}")

    # Every log source has to end in the scrub, and only the scrub may write.
    everything = windows + pathlib.Path(args.fragment).read_text(encoding="utf-8")
    writers = [target for target in re.findall(r"forward_to\s*=\s*\[([^\]]*)\]", everything) if "loki.write." in target]
    if len(writers) != 1:
        failures.append(f"{len(writers)} components forward to loki.write; only the scrub may")
    if "forward_to = [loki.write.central.receiver]" not in scrub:
        failures.append('loki.process "scrub" does not forward to loki.write.central')

    seen = set()
    for case in read_cases(args.cases):
        if case["id"] in seen:
            failures.append(f"duplicate case id {case['id']}")
        seen.add(case["id"])
        if not re.search(r"(^|[^A-Za-z0-9])" + case["id"] + r"([^A-Za-z0-9]|$)", case["payload"]):
            failures.append(f"{case['id']}: the id is not in the payload")
        for marker in case["markers"]:
            if not re.search(r"FAKE|fake|S-1-5-21-(1111111111|4444444444)|RkFLRS|eyJzdWIiOiJGQUtF", marker):
                failures.append(f"{case['id']}: marker is not synthetic: {marker}")
            if marker not in case["payload"]:
                failures.append(f"{case['id']}: marker missing from payload: {marker}")
        if case["safe"] and case["markers"]:
            failures.append(f"{case['id']}: a safe case cannot carry markers")
        if case["source"] != "diag":
            try:
                json.loads(case["payload"].replace("@T@", "2026-01-01T00:00:00Z").replace("@OLD@", "2026-01-01T00:00:00Z"))
            except ValueError as error:
                failures.append(f"{case['id']}: the Event Log payload is not JSON: {error}")

    for failure in failures:
        print(f"FAIL static: {failure}")
    return 1 if failures else 0


# ------------------------------------------------------------------ samples

def write_samples(args):
    out = pathlib.Path(args.out)
    for name in ("eventlog/System", "eventlog/Application", "diag"):
        (out / name).mkdir(parents=True)
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    base = now - datetime.timedelta(minutes=5)
    old = now - datetime.timedelta(days=3)
    serial = 0
    lines = {"System": [], "Application": [], "diag": []}
    manifest = []
    for case in read_cases(args.cases):
        serial += 1
        if case["source"] == "diag":
            recent = (base + datetime.timedelta(seconds=serial)).strftime("%Y-%m-%d %H:%M:%SZ")
            stale = old.strftime("%Y-%m-%d %H:%M:%SZ")
        else:
            recent = (base + datetime.timedelta(seconds=serial)).strftime("%Y-%m-%dT%H:%M:%S.0000000Z")
            stale = old.strftime("%Y-%m-%dT%H:%M:%S.0000000Z")
        text = case["payload"].replace("@T@", recent).replace("@OLD@", stale).replace("<NL>", "\n")
        lines[case["source"]].append(text)
        manifest.append(dict(case, input=text))
    (out / "eventlog/System/events.jsonl").write_text("\n".join(lines["System"]) + "\n", encoding="utf-8")
    (out / "eventlog/Application/events.jsonl").write_text("\n".join(lines["Application"]) + "\n", encoding="utf-8")
    (out / "diag/Runner_20260101-000000-utc.log").write_text("\n".join(lines["diag"]) + "\n", encoding="utf-8")
    # The template must not pick this up: only Runner_*.log is collected.
    stamp = base.strftime("%Y-%m-%d %H:%M:%SZ")
    (out / "diag/Worker_20260101-000000-utc.log").write_text(f"[{stamp} INFO Worker] {WORKER_MARKER}\n", encoding="utf-8")
    pathlib.Path(args.manifest).write_text(json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0


# ------------------------------------------------------------------ Loki judge

def http_json(container, url):
    done = subprocess.run(["docker", "exec", container, "wget", "-qO-", url], capture_output=True, check=True)
    return json.loads(done.stdout)


def loki_entries(container, server):
    now = time.time_ns()
    params = urllib.parse.urlencode({
        "query": f'{{server_id="{server}"}}', "limit": 5000, "direction": "forward",
        "start": now - 6 * 3600 * 10**9, "end": now + 3600 * 10**9,
    })
    result = http_json(container, f"http://127.0.0.1:3100/loki/api/v1/query_range?{params}")["data"]["result"]
    return [(stream["stream"], line) for stream in result for _, line in stream["values"]]


def has_id(ident, line):
    return re.search(r"(^|[^A-Za-z0-9])" + ident + r"([^A-Za-z0-9]|$)", line) is not None


def judge_scrub(args):
    manifest = json.loads(pathlib.Path(args.manifest).read_text(encoding="utf-8"))
    expected = [case for case in manifest if case["expect"] != "drop"]
    deadline = time.monotonic() + INGEST_TIMEOUT_SECONDS
    entries = []
    while time.monotonic() < deadline:
        entries = loki_entries(args.loki, args.server)
        if all(any(has_id(case["id"], line) for _, line in entries) for case in expected):
            break
        running = subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", args.alloy],
                                 capture_output=True, text=True).stdout.strip()
        if running != "true":
            print("FAIL: the Alloy container stopped before every case arrived")
            return 1
        time.sleep(2)
    # Anything that should have been dropped gets time to show up after all.
    time.sleep(6)
    entries = loki_entries(args.loki, args.server)

    failures = []
    for case in manifest:
        found = [(labels, line) for labels, line in entries if has_id(case["id"], line)]
        if case["expect"] == "drop":
            if found:
                failures.append(f"{case['id']}: must be dropped but arrived")
            continue
        if len(found) != 1:
            failures.append(f"{case['id']}: expected one entry, found {len(found)}")
            continue
        labels, line = found[0]
        if case["source"] == "diag":
            want = {"job": "github-runner-diag", "level": case["expect"], "product": args.product, "server_id": args.server}
        else:
            want = {"job": "windows-eventlog", "channel": case["source"], "level": case["expect"],
                    "product": args.product, "server_id": args.server}
        if labels != want:
            failures.append(f"{case['id']}: stream labels are {labels}, want {want}")
        for marker in case["markers"]:
            if marker in line:
                failures.append(f"{case['id']}: LEAK {marker}")
        if case["keep"] and case["keep"] not in line:
            failures.append(f"{case['id']}: lost the text that must stay: {case['keep']}  ->  {line}")
        if case["safe"] and line != case["input"]:
            failures.append(f"{case['id']}: a safe line was changed: {line}")
        if case["source"] != "diag":
            try:
                if "message" not in json.loads(line):
                    failures.append(f"{case['id']}: the stored line lost its message field")
            except ValueError:
                failures.append(f"{case['id']}: the stored line is no longer JSON: {line}")

    everything = "\n".join(line for _, line in entries)
    for case in manifest:
        for marker in case["markers"]:
            if marker in everything:
                failures.append(f"{case['id']}: LEAK {marker} somewhere in the stored logs")
    if WORKER_MARKER in everything:
        failures.append("a Worker_*.log line was collected")

    streams = {tuple(sorted(labels.items())) for labels, _ in entries}
    for stream in streams:
        names = {name for name, _ in stream}
        allowed = DIAG_LABELS if dict(stream).get("job") == "github-runner-diag" else EVENTLOG_LABELS
        if names != allowed:
            failures.append(f"stream has labels {sorted(names)}, want exactly {sorted(allowed)}")
    if len(streams) > MAX_STREAMS:
        failures.append(f"{len(streams)} streams, the budget is {MAX_STREAMS}")

    # The health gate, the dashboard and AlloyAgentPushFailing read these names.
    # They only exist once entries have moved, which is here.
    done = subprocess.run(["docker", "exec", args.loki, "wget", "-qO-", f"http://127.0.0.1:{args.alloy_port}/metrics"],
                          capture_output=True, text=True)
    sent = sum(float(row.rsplit(" ", 1)[1]) for row in done.stdout.splitlines()
               if row.startswith("loki_write_sent_entries_total{"))
    if sent < len(expected):
        failures.append(f"loki_write_sent_entries_total is {sent:g} after {len(expected)} entries were stored")

    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        return 1
    print(f"ok: {len(expected)} cases scrubbed, {len(manifest) - len(expected)} dropped, {len(streams)} streams")
    return 0


# ------------------------------------------------------------------ metrics judge

def prom_series(container, match):
    params = urllib.parse.urlencode({"match[]": match})
    return http_json(container, f"http://127.0.0.1:9090/api/v1/series?{params}")["data"]


def read_inventory(path):
    rows = []
    for raw in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith("#"):
            continue
        name, verdict = raw.split()
        rows.append((name, verdict))
    return rows


def read_allowlist(path):
    lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
    return [raw.strip() for raw in lines if raw.strip() and not raw.startswith("#")]


def template_rule(text, header, action):
    body = component(text, header)
    for rule in re.findall(r"^  rule \{\n(.*?)^  \}\n", body or "", re.S | re.M):
        if re.search(r'action\s*=\s*"' + action + '"', rule) and "__name__" in rule:
            return re.search(r'regex\s*=\s*"(.*)"', rule).group(1)
    return None


def check_inventory(args):
    """The template's drop and keep lists against the exporter's metric list."""
    failures = []
    text = pathlib.Path(args.template).read_text(encoding="utf-8")
    drop = template_rule(text, 'prometheus.relabel "windows"', "drop")
    keep = template_rule(text, 'prometheus.relabel "alloy"', "keep")
    if not drop or not keep:
        print("FAIL inventory: cannot read the drop or keep rule from the template")
        return 1
    kept = 0
    names = set()
    for name, verdict in read_inventory(args.inventory):
        names.add(name)
        dropped = re.fullmatch(drop, name) is not None
        if dropped != (verdict == "drop"):
            failures.append(f"{name}: the template {'drops' if dropped else 'keeps'} it, the inventory says {verdict}")
        kept += 0 if dropped else 1
    # A name in the drop rule that the exporter does not have is a typo.
    for part in re.findall(r"windows_[a-z_]+(?:\([a-z_|]+\))?", drop):
        if not any(re.fullmatch(part, name) for name in names):
            failures.append(f"the drop rule names nothing in the inventory: {part}")
    allowlist = read_allowlist(args.allowlist)
    for name in allowlist:
        if re.fullmatch(keep, name) is None:
            failures.append(f"{name}: in the allowlist fixture but not kept by the template")
    for name in keep.split("|"):
        if name not in allowlist:
            failures.append(f"{name}: kept by the template but not in the allowlist fixture")
    for failure in failures:
        print(f"FAIL inventory: {failure}")
    if failures:
        return 1
    print(f"ok: {kept} of {len(names)} exporter metric names kept, {len(allowlist)} Alloy metric names kept")
    return 0


def judge_metrics(args):
    wanted = {"product": args.product, "server_id": args.server}
    deadline = time.monotonic() + INGEST_TIMEOUT_SECONDS
    fixture, alloy = [], []
    while time.monotonic() < deadline:
        fixture = prom_series(args.prom, '{__name__=~"windows_.+"}')
        alloy = prom_series(args.prom, '{job="integrations/self"}')
        if fixture and any(row["__name__"] == "prometheus_remote_storage_samples_total" for row in alloy):
            break
        running = subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", args.alloy],
                                 capture_output=True, text=True).stdout.strip()
        if running != "true":
            print("FAIL: the Alloy container stopped before any series arrived")
            return 1
        time.sleep(2)
    time.sleep(6)
    fixture = prom_series(args.prom, '{__name__=~"windows_.+"}')
    alloy = prom_series(args.prom, '{job="integrations/self"}')
    everything = prom_series(args.prom, '{__name__=~".+"}')

    failures = []
    by_name = {}
    for row in fixture:
        by_name.setdefault(row["__name__"], []).append(row)
    if not fixture:
        failures.append("no windows_* series reached Prometheus")

    info = by_name.get("windows_os_info", [])
    if len(info) != 1:
        failures.append(f"expected one windows_os_info series, found {len(info)}")
    else:
        if info[0].get("product") != args.product:
            failures.append(f"windows_os_info has product={info[0].get('product')!r}: the external label lost")
        if info[0].get("os_product") != "Windows 11 Home":
            failures.append(f"windows_os_info has os_product={info[0].get('os_product')!r}")

    verdicts = dict(read_inventory(args.inventory))
    sent = sorted(set(re.findall(r"^(windows_[a-z0-9_]+)", pathlib.Path(args.fixture).read_text(encoding="utf-8"), re.M)))
    for name in sent:
        verdict = verdicts.get(name)
        if verdict is None:
            failures.append(f"{name} is in the fixture but not in the inventory")
        present = name in by_name
        if verdict == "drop" and present:
            failures.append(f"{name} must be dropped but reached Prometheus")
        if verdict == "keep" and not present:
            failures.append(f"{name} must be kept but did not reach Prometheus")

    for row in everything:
        for label, value in wanted.items():
            if row.get(label) != value:
                failures.append(f"{row['__name__']} has {label}={row.get(label)!r}, want {value!r}")
                break
        leaked = {"path_name", "run_as", "serial_number", "address", "mac"} & set(row)
        if leaked:
            failures.append(f"{row['__name__']} carries {sorted(leaked)}")

    allowlist = set(read_allowlist(args.allowlist))
    names = {row["__name__"] for row in alloy}
    if not names:
        failures.append('no series with job="integrations/self": Alloy\'s own metrics did not arrive')
    for name in sorted(names - allowlist):
        failures.append(f"Alloy metric {name} is not on the allowlist but reached Prometheus")
    # The loki_write_* counters only exist once an entry has been sent or dropped,
    # and nothing is logged in this run; the scrub suite checks them.
    for name in ("up", "alloy_build_info", "prometheus_remote_storage_samples_total",
                 "prometheus_remote_storage_samples_failed_total",
                 "prometheus_remote_storage_queue_highest_sent_timestamp_seconds"):
        if name not in names:
            failures.append(f"Alloy metric {name} did not reach Prometheus")

    for failure in sorted(set(failures)):
        print(f"FAIL: {failure}")
    if failures:
        return 1
    print(f"ok: {len(fixture)} fixture series and {len(alloy)} Alloy series carry the expected labels")
    return 0


# ------------------------------------------------------------------ central: rules and dashboard

PROMQL_WORDS = {"by", "without", "on", "ignoring", "group_left", "group_right", "or", "and", "unless",
                "bool", "offset", "inf", "nan"}


def promql_selectors(expr):
    """(metric name, selector text or None) for every series selector in a PromQL expression."""
    bare = re.sub(r'"(?:[^"\\]|\\.)*"', '""', expr)
    bare = re.sub(r"\[[^\]]*\]", "", bare)
    bare = re.sub(r"\b(by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)", " ", bare)
    # Label names inside a selector look like metric names; they are not.
    spans = [match.span() for match in re.finditer(r"\{[^}]*\}", bare)]
    found = []
    for match in re.finditer(r"[A-Za-z_:][A-Za-z0-9_:]*", bare):
        if any(start < match.start() < end for start, end in spans):
            continue
        name = match.group(0)
        rest = bare[match.end():]
        if name in PROMQL_WORDS or re.match(r"\s*\(", rest):
            continue
        selector = re.match(r"\{[^}]*\}", rest)
        found.append((name, selector.group(0) if selector else None))
    return found


def allowed_metric_names(args):
    keep = {name for name, verdict in read_inventory(args.inventory) if verdict == "keep"}
    # ALERTS is written by central Prometheus itself.
    return keep | set(read_allowlist(args.allowlist)) | {"ALERTS"}


def substitute(expr, product, server):
    return (expr.replace("$__rate_interval", "5m").replace("$__interval", "1m")
            .replace("$product", product).replace("$server_id", server))


def dashboard_targets(dashboard):
    for panel in dashboard["panels"]:
        for target in panel.get("targets", []):
            yield panel, target


def check_dashboard(args):
    """Static checks on the Windows dashboard, and a promtool test that runs its queries."""
    failures = []
    path = pathlib.Path(args.dashboard)
    dashboard = json.loads(path.read_text(encoding="utf-8"))
    allowed = allowed_metric_names(args)

    if dashboard.get("uid") != "hosts-windows" or path.name != "hosts-windows.json":
        failures.append("the uid and the file name must both be hosts-windows")
    if dashboard.get("title") != "主機 — Windows":
        failures.append(f"unexpected title {dashboard.get('title')!r}")
    for tag in ("layer:host", "provisioned"):
        if tag not in dashboard.get("tags", []):
            failures.append(f"missing tag {tag}")
    variables = [(v["name"], v["datasource"].get("uid")) for v in dashboard["templating"]["list"]]
    if variables != [("product", "prometheus"), ("server_id", "prometheus")]:
        failures.append(f"variables must be product then server_id on Prometheus, found {variables}")

    ids = [panel["id"] for panel in dashboard["panels"]]
    if len(ids) != len(set(ids)):
        failures.append("panel ids are not unique")
    cells = {}
    for panel in dashboard["panels"]:
        pos = panel["gridPos"]
        if pos["x"] + pos["w"] > 24:
            failures.append(f"panel {panel['id']} is wider than the grid")
        for x in range(pos["x"], pos["x"] + pos["w"]):
            for y in range(pos["y"], pos["y"] + pos["h"]):
                if (x, y) in cells:
                    failures.append(f"panels {cells[(x, y)]} and {panel['id']} overlap")
                cells[(x, y)] = panel["id"]

    scoped = ('product="$product"', 'server_id="$server_id"')
    prom, loki = [], []
    for panel, target in dashboard_targets(dashboard):
        where = f"panel {panel['id']} ({panel['title']})"
        sources = {panel.get("datasource", {}).get("uid"), target.get("datasource", {}).get("uid")}
        if len(sources) != 1 or not sources <= {"prometheus", "loki"}:
            failures.append(f"{where}: datasource must be the pinned uid prometheus or loki, found {sorted(map(str, sources))}")
            continue
        expr = target["expr"]
        if sources == {"prometheus"}:
            prom.append((where, expr))
            selectors = promql_selectors(expr)
            if not selectors:
                failures.append(f"{where}: no metric found in {expr}")
            for name, selector in selectors:
                if name not in allowed:
                    failures.append(f"{where}: {name} is not a metric the Windows template sends")
            raw = re.findall(r"\{[^}]*\}", expr)
            if len(raw) != len(selectors) or any(sel is None for _, sel in selectors):
                failures.append(f"{where}: a metric has no label selector: {expr}")
            for selector in raw:
                if not all(part in selector for part in scoped):
                    failures.append(f"{where}: selector {selector} is not scoped to $product and $server_id")
        else:
            loki.append((where, expr))
            selector = re.match(r"(?:.*?\()*\s*(\{[^}]*\})", expr)
            if not selector or not all(part in selector.group(1) for part in scoped):
                failures.append(f"{where}: the log selector is not scoped to $product and $server_id: {expr}")
                continue
            labels = set(re.findall(r'([a-z_]+)\s*(?:=~|!=|!~|=)\s*"', selector.group(1)))
            grouped = set(re.findall(r"[a-z_]+", " ".join(re.findall(r"\bby\s*\(([^)]*)\)", expr))))
            budget = DIAG_LABELS if 'job="github-runner-diag"' in selector.group(1) else EVENTLOG_LABELS
            if "job" not in labels or not (labels | grouped) <= budget:
                failures.append(f"{where}: uses labels {sorted(labels | grouped)}, the stream has {sorted(budget)}")
    if len(prom) < 20 or len(loki) < 3:
        failures.append(f"only {len(prom)} Prometheus and {len(loki)} Loki queries found; the dashboard was not read")

    # Every Prometheus query runs on fixture series: it must return something for
    # the selected host and nothing for a host that does not exist.
    series = []
    for raw in pathlib.Path(args.series).read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith("#"):
            continue
        selector, values = raw.split("\t")
        name = selector.split("{")[0]
        if name not in allowed:
            failures.append(f"the dashboard fixture invents a metric: {name}")
        series.append((selector, values))
    lines = ["evaluation_interval: 1m", "tests:"]
    for server, expect in ((args.server, True), ("no-such-host", False)):
        lines += [f"  - name: dashboard queries for {server}", "    interval: 1m", "    input_series:"]
        for selector, values in series:
            lines += [f"      - series: {json.dumps(selector)}", f"        values: {json.dumps(values)}"]
        lines.append("    promql_expr_test:")
        for where, expr in prom:
            query = f"count({substitute(expr, args.product, server)}) > bool 0"
            lines += [f"      # {where}", f"      - expr: {json.dumps(query)}", "        eval_time: 10m"]
            if expect or "vector(0)" in expr:
                lines += ["        exp_samples:", "          - labels: '{}'", "            value: 1"]
            else:
                lines.append("        exp_samples: []")
    pathlib.Path(args.out).write_text("\n".join(lines) + "\n", encoding="utf-8")

    for failure in sorted(set(failures)):
        print(f"FAIL dashboard: {failure}")
    if failures:
        return 1
    print(f"ok: dashboard has {len(prom)} Prometheus and {len(loki)} Loki queries, all scoped and on sent metrics")
    return 0


def check_rules(args):
    """The Windows alert rules as the pinned Prometheus loaded them."""
    failures = []
    allowed = allowed_metric_names(args)
    line = next((l for l in pathlib.Path(args.log).read_text(encoding="utf-8").splitlines() if l.startswith("RULES ")), None)
    if line is None:
        print("FAIL rules: Prometheus did not load the rule file")
        return 1
    groups = json.loads(line[6:])["data"]["groups"]
    rules = [rule for group in groups if group["name"] == "windows-host" for rule in group["rules"]]
    if len(rules) < 5:
        failures.append(f"expected at least 5 rules in group windows-host, found {len(rules)}")
    routes = []
    for rule in rules:
        name, labels, notes = rule["name"], rule.get("labels", {}), rule.get("annotations", {})
        # A Windows alert leaves shadow only through the promotion procedure, which
        # changes this test in the same commit.
        if labels.get("notification_mode") != "shadow":
            failures.append(f"{name}: notification_mode is {labels.get('notification_mode')!r}, new alerts start in shadow")
        if labels.get("severity") not in ("Medium", "High"):
            failures.append(f"{name}: severity is {labels.get('severity')!r}")
        if not notes.get("summary"):
            failures.append(f"{name}: no summary")
        prefix = "https://github.com/wanth1997/SkyEye/blob/master/"
        runbook = notes.get("runbook_url", "")
        if not runbook.startswith(prefix) or not (pathlib.Path(args.repo) / runbook[len(prefix):]).is_file():
            failures.append(f"{name}: runbook_url does not point to a file in this repository: {runbook}")
        for metric, _ in promql_selectors(rule["query"]):
            if metric not in allowed:
                failures.append(f"{name}: {metric} is not a metric the Windows template sends")
        fields = [f"alertname={name}", "product=github-runner", "server_id=fixture-windows"]
        fields += [f"{key}={value}" for key, value in sorted(labels.items())]
        routes.append(" ".join(fields))
    pathlib.Path(args.routes).write_text("\n".join(routes) + "\n", encoding="utf-8")
    for failure in failures:
        print(f"FAIL rules: {failure}")
    if failures:
        return 1
    print(f"ok: {len(rules)} Windows rules are in shadow, use sent metrics and link an existing runbook")
    return 0


def judge_dashboard_logs(args):
    """The dashboard's Loki queries against the Loki the scrub suite filled."""
    dashboard = json.loads(pathlib.Path(args.dashboard).read_text(encoding="utf-8"))
    now = time.time_ns()
    failures, count = [], 0
    for panel, target in dashboard_targets(dashboard):
        if target.get("datasource", {}).get("uid") != "loki":
            continue
        count += 1
        params = urllib.parse.urlencode({
            "query": substitute(target["expr"], args.product, args.server), "limit": 100, "step": "60",
            "start": now - 6 * 3600 * 10**9, "end": now + 3600 * 10**9,
        })
        try:
            result = http_json(args.loki, f"http://127.0.0.1:3100/loki/api/v1/query_range?{params}")["data"]["result"]
        except (subprocess.CalledProcessError, ValueError):
            failures.append(f"panel {panel['id']} ({panel['title']}): Loki rejects the query")
            continue
        if not result:
            failures.append(f"panel {panel['id']} ({panel['title']}): the query returns nothing")
        elif target["expr"].rstrip().endswith('"') and "line_format" in target["expr"]:
            shown = [line for stream in result for _, line in stream["values"]]
            if not any(re.match(r"\[(System|Application)\] \S.* #\d+  \S", line) for line in shown):
                failures.append(f"panel {panel['id']} ({panel['title']}): line_format did not fill in: {shown[:1]}")
    if count < 3:
        failures.append(f"only {count} Loki queries found in the dashboard")
    for failure in failures:
        print(f"FAIL dashboard logs: {failure}")
    if failures:
        return 1
    print(f"ok: {count} dashboard log queries return data")
    return 0


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)

    static = commands.add_parser("static")
    static.add_argument("--template", required=True)
    static.add_argument("--fragment", required=True)
    static.add_argument("--general", required=True)
    static.add_argument("--cases", required=True)
    static.set_defaults(run=check_static)

    samples = commands.add_parser("samples")
    samples.add_argument("--cases", required=True)
    samples.add_argument("--out", required=True)
    samples.add_argument("--manifest", required=True)
    samples.set_defaults(run=write_samples)

    scrub = commands.add_parser("judge-scrub")
    scrub.add_argument("--loki", required=True)
    scrub.add_argument("--alloy", required=True)
    scrub.add_argument("--alloy-port", required=True)
    scrub.add_argument("--manifest", required=True)
    scrub.add_argument("--server", required=True)
    scrub.add_argument("--product", required=True)
    scrub.set_defaults(run=judge_scrub)

    inventory = commands.add_parser("inventory")
    inventory.add_argument("--template", required=True)
    inventory.add_argument("--inventory", required=True)
    inventory.add_argument("--allowlist", required=True)
    inventory.set_defaults(run=check_inventory)

    metrics = commands.add_parser("judge-metrics")
    metrics.add_argument("--prom", required=True)
    metrics.add_argument("--alloy", required=True)
    metrics.add_argument("--fixture", required=True)
    metrics.add_argument("--inventory", required=True)
    metrics.add_argument("--allowlist", required=True)
    metrics.add_argument("--server", required=True)
    metrics.add_argument("--product", required=True)
    metrics.set_defaults(run=judge_metrics)

    board = commands.add_parser("dashboard")
    board.add_argument("--dashboard", required=True)
    board.add_argument("--series", required=True)
    board.add_argument("--inventory", required=True)
    board.add_argument("--allowlist", required=True)
    board.add_argument("--server", required=True)
    board.add_argument("--product", required=True)
    board.add_argument("--out", required=True)
    board.set_defaults(run=check_dashboard)

    rules = commands.add_parser("rules")
    rules.add_argument("--log", required=True)
    rules.add_argument("--repo", required=True)
    rules.add_argument("--inventory", required=True)
    rules.add_argument("--allowlist", required=True)
    rules.add_argument("--routes", required=True)
    rules.set_defaults(run=check_rules)

    board_logs = commands.add_parser("judge-dashboard-logs")
    board_logs.add_argument("--loki", required=True)
    board_logs.add_argument("--dashboard", required=True)
    board_logs.add_argument("--server", required=True)
    board_logs.add_argument("--product", required=True)
    board_logs.set_defaults(run=judge_dashboard_logs)

    args = parser.parse_args()
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())
