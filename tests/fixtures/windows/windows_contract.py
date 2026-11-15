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
    metrics.add_argument("--fixture", required=True)
    metrics.add_argument("--inventory", required=True)
    metrics.add_argument("--allowlist", required=True)
    metrics.add_argument("--server", required=True)
    metrics.add_argument("--product", required=True)
    metrics.set_defaults(run=judge_metrics)

    args = parser.parse_args()
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())
