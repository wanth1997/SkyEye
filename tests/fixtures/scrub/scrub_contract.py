"""Sample generation and pass/fail judging for tests/trading/test-scrub-pipeline.sh.

The shell test renders the real configs and runs them. This file builds the
synthetic input from cases.tsv and reads the output back from the throwaway
Loki. Leak detection is a plain substring check on what Loki stored, so a result
never depends on how a regex is written.
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

# flavour -> (level, msg), each chosen to land in one specific Loki rule.
FLAVOURS = {
    "R1": ("ERROR", "coordinator_fence_stalled"),
    "R2": ("ERROR", "rv_generic_failure"),
    "R3": ("WARN", "emergency_exit"),
}
TRADING_LABELS = {"product", "environment", "server_id", "strategy", "run_id", "level"}
# filename stands in for the journald source; the rest is what setup.sh sets.
GENERAL_LABELS = {"product", "server_id", "job", "filename"}
WINDOW = "6h"
INGEST_TIMEOUT_SECONDS = 240


def read_cases(path):
    cases = []
    for raw in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith("#"):
            continue
        ident, group, scope, marks, keep, payload = raw.split("\t")
        cases.append({
            "id": ident,
            "group": group,
            "scope": scope,
            "markers": [] if marks == "-" else marks.split(","),
            "keep": "" if keep == "-" else keep,
            "payload": payload,
        })
    return cases


def stamp(base, serial):
    moment = base + datetime.timedelta(milliseconds=serial)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.%f000Z")


def write_samples(args):
    out = pathlib.Path(args.out)
    (out / "trading").mkdir(parents=True)
    (out / "general").mkdir(parents=True)
    (out / "textfile").mkdir()
    base = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=5)
    serial = 0
    trading, general = [], []

    def add_trading(run_id, case, lines):
        (out / "trading" / f"{run_id}.raw.log").write_text("\n".join(lines) + "\n", encoding="utf-8")
        trading.append({"ident": run_id, "case": case["id"], "group": case["group"], "markers": case["markers"],
                        "keep": case["keep"], "input": lines})

    for case in read_cases(args.cases):
        if case["scope"] == "raw":
            serial += 1
            lines = [text.replace("@T@", stamp(base, serial)) for text in case["payload"].split("<NL>")]
            add_trading(f"{case['id']}-raw-full", case, lines)
            continue
        if case["scope"] == "both":
            for flavour, (level, msg) in FLAVOURS.items():
                for position in ("head", "tail"):
                    serial += 1
                    prefix = f"time={stamp(base, serial)} level={level}"
                    if position == "head":
                        line = f"{prefix} msg={msg} case={case['id']} {case['payload']}"
                    else:
                        line = f"{prefix} case={case['id']} {case['payload']} msg={msg}"
                    add_trading(f"{case['id']}-{flavour}-{position}", case, [line])
        (out / "general" / f"{case['id']}.log").write_text(case["payload"] + "\n", encoding="utf-8")
        general.append({"ident": case["id"], "case": case["id"], "group": case["group"], "markers": case["markers"],
                        "keep": case["keep"], "input": [case["payload"]]})

    manifest = {"trading": trading, "general": general}
    pathlib.Path(args.manifest).write_text(json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0


def stage_blocks(path):
    text = pathlib.Path(path).read_text(encoding="utf-8")
    return re.findall(r"^  stage\.replace \{\n.*?^  \}\n", text, re.S | re.M)


def block_expression(block):
    raw = re.search(r"^\s*expression\s*=\s*`(.*)`$", block, re.M)
    if raw:
        return raw.group(1)
    quoted = re.search(r'^\s*expression\s*=\s*"(.*)"$', block, re.M)
    return quoted.group(1).replace("\\\\", "\\") if quoted else None


def block_replacement(block):
    return re.search(r'^\s*replace\s*=\s*"(.*)"$', block, re.M).group(1)


def check_static(args):
    failures = []
    linux, macos, general = (stage_blocks(path) for path in (args.linux, args.macos, args.general))

    # The first Trading stage is the host-specific repo root; only its wiring
    # differs between the two templates.
    if len(linux) < 2 or linux[1:] != macos[1:]:
        failures.append("Linux and macOS stage.replace blocks differ")

    # stage.replace only rewrites capture groups: none is a silent no-op, and a
    # second one overwrites the key as well as the value.
    for name, blocks in (("Linux", linux[1:]), ("macOS", macos[1:]), ("general", general)):
        for block in blocks:
            expression = block_expression(block)
            groups = re.compile(expression).groups
            if groups != 1:
                failures.append(f"{name} expression has {groups} capture groups, needs exactly 1: {expression}")

    placeholders = {block_replacement(block) for block in general}
    for trading_only in ("[ORDER_REF]", "[TRACE_REF]", "[EXECUTION_REF]"):
        if trading_only in placeholders:
            failures.append(f"general applies the Trading-only rule {trading_only}")

    shared = ("[TOKEN]", "[SECRET]")
    if [b for b in general if block_replacement(b) in shared] != [b for b in linux[1:] if block_replacement(b) in shared]:
        failures.append("general credential stages differ from the Trading ones")

    # Everything in the fixture has to be obviously synthetic.
    seen = set()
    for case in read_cases(args.cases):
        if case["id"] in seen:
            failures.append(f"duplicate case id {case['id']}")
        seen.add(case["id"])
        for marker in case["markers"]:
            if not re.fullmatch(r"FAKE-\S+|0900-?000-?00\d", marker):
                failures.append(f"{case['id']}: marker is not synthetic: {marker}")
            if marker not in case["payload"]:
                failures.append(f"{case['id']}: marker missing from payload: {marker}")
        if case["group"] == "safe" and case["markers"]:
            failures.append(f"{case['id']}: a safe case cannot carry markers")

    for failure in failures:
        print(f"FAIL static: {failure}")
    return 1 if failures else 0


class Loki:
    def __init__(self, container):
        self.container = container

    def get(self, path, params):
        url = f"http://127.0.0.1:3100{path}?{urllib.parse.urlencode(params, doseq=True)}"
        done = subprocess.run(["docker", "exec", self.container, "wget", "-qO-", url], capture_output=True, check=True)
        return json.loads(done.stdout)

    def instant(self, query):
        return self.get("/loki/api/v1/query", {"query": query})["data"]["result"]

    def streams(self, query):
        # Lines with no parsable time carry the Alloy clock, which in a Docker VM can
        # run slightly ahead of this host, so the window extends past now.
        now = time.time_ns()
        return self.get("/loki/api/v1/query_range", {
            "query": query, "limit": 50000, "direction": "forward",
            "start": now - 6 * 3600 * 10**9, "end": now + 3600 * 10**9,
        })["data"]["result"]

    def count(self, server):
        rows = self.instant(f'sum(count_over_time({{server_id="{server}"}}[{WINDOW}]))')
        return int(float(rows[0]["value"][1])) if rows else 0

    def label_names(self, server):
        series = self.get("/loki/api/v1/series", {"match[]": f'{{server_id="{server}"}}'})["data"]
        return {name for row in series for name in row}


def wait_for_ingest(args):
    """Wait until every pipeline has delivered every line, or report which did not."""
    manifest = json.loads(pathlib.Path(args.manifest).read_text(encoding="utf-8"))
    expected = {}
    for spec in args.pipeline:
        server, container, kind = spec.split("=")
        expected[server] = (container, sum(len(entry["input"]) for entry in manifest[kind]))
    loki = Loki(args.loki)
    pending = dict(expected)
    deadline = time.monotonic() + INGEST_TIMEOUT_SECONDS
    failures = []
    while pending and time.monotonic() < deadline:
        for server, (container, lines) in list(pending.items()):
            if loki.count(server) >= lines:
                del pending[server]
                continue
            state = subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", container],
                                   capture_output=True, text=True)
            if state.stdout.strip() != "true":
                tail = subprocess.run(["docker", "logs", "--tail", "5", container], capture_output=True, text=True)
                failures.append(f"{server}: Alloy exited early: {tail.stderr.strip()[-600:]}")
                del pending[server]
        if pending:
            time.sleep(2)
    for server, (_, lines) in pending.items():
        failures.append(f"{server}: only {loki.count(server)} of {lines} lines reached Loki")
    for failure in failures:
        print(f"FAIL ingest: {failure}")
    return 1 if failures else 0


def rule_expressions(path):
    text = pathlib.Path(path).read_text(encoding="utf-8")
    return re.findall(r"- alert: (\S+)\n\s+expr: \|-\n\s+(.+)\n", text)


def adapt_rule(expression, server):
    """Keep the filter chain as deployed. Only the grouping, window and server change."""
    edits = (
        ('{product="tnauqquant", environment="production"',
         f'{{product="tnauqquant", environment="production", server_id="{server}"'),
        ("sum by (product,environment,server_id,strategy)", "sum by (run_id)"),
        ("[1m]", f"[{WINDOW}]"),
    )
    for old, new in edits:
        if old not in expression:
            raise SystemExit(f"FAIL rules: expression no longer contains {old}: {expression}")
        expression = expression.replace(old, new)
    return expression


def lines_by_ident(loki, server, label):
    lines = {}
    for stream in loki.streams(f'{{server_id="{server}"}}'):
        ident = stream["stream"].get(label, "?")
        if label == "filename":
            ident = pathlib.PurePosixPath(ident).stem
        lines.setdefault(ident, []).extend(value[1] for value in stream["values"])
    return lines


def rule_hits(loki, server, rules):
    hits = {}
    for name, expression in rules:
        rows = loki.instant(adapt_rule(expression, server))
        hits[name] = {row["metric"].get("run_id", "?"): int(float(row["value"][1])) for row in rows}
    return hits


def parsed_msgs(loki, server):
    msgs = {}
    query = f'{{server_id="{server}"}} | logfmt | line_format "msg<{{{{.msg}}}}>"'
    for stream in loki.streams(query):
        run_id = stream["stream"].get("run_id", "?")
        msgs.setdefault(run_id, []).extend(value[1] for value in stream["values"])
    # Lines sharing a timestamp come back in no fixed order.
    return {run_id: sorted(values) for run_id, values in msgs.items()}


def parse_residuals(pairs):
    residual = {}
    for pair in pairs:
        case, marker = pair.split(":", 1)
        residual.setdefault(case, set()).add(marker)
    return residual


def compare_common(entries, lines, passes_through=lambda entry: False):
    """Checks shared by both pipelines. Returns (failures, {case: leaked markers})."""
    failures, leaks, changed, missing, lost = [], {}, [], [], []
    for entry in entries:
        got = lines.get(entry["ident"])
        if got is None or len(got) != len(entry["input"]):
            missing.append(entry["ident"])
            continue
        text = "\n".join(got)
        leaked = {marker for marker in entry["markers"] if marker in text}
        if leaked:
            leaks.setdefault(entry["case"], set()).update(leaked)
        if entry["group"] == "safe" and sorted(got) != sorted(entry["input"]):
            changed.append(entry["case"])
        if entry["keep"] and entry["keep"] not in text and not passes_through(entry):
            lost.append(entry["case"])
    if missing:
        failures.append(f"{len(missing)} entries missing or wrong line count: {' '.join(sorted(missing)[:12])}")
    if changed:
        failures.append(f"safe cases changed: {' '.join(sorted(set(changed)))}")
    if lost:
        failures.append(f"text that must survive was lost: {' '.join(sorted(set(lost)))}")
    return failures, leaks


def compare_residuals(leaks, residual):
    failures = []
    unexpected = sorted(case for case, markers in leaks.items() if markers - residual.get(case, set()))
    if unexpected:
        failures.append(f"leak in {len(unexpected)} cases: {' '.join(unexpected)}")
    stale = sorted(case for case, markers in residual.items() if leaks.get(case, set()) != markers)
    if stale:
        failures.append(f"known residual list is out of date: {' '.join(stale)}")
    return failures


def judge_trading(loki, server, entries, residual, rules, baseline):
    lines = lines_by_ident(loki, server, "run_id")
    failures, leaks = compare_common(entries, lines)
    failures += compare_residuals(leaks, residual)

    labels = loki.label_names(server)
    if labels != TRADING_LABELS:
        failures.append(f"Loki labels differ: {sorted(labels ^ TRADING_LABELS)}")

    hits = rule_hits(loki, server, rules)
    for name, expected in baseline["hits"].items():
        got = hits[name]
        wrong = sorted(ident for ident in set(got) | set(expected) if got.get(ident) != expected.get(ident))
        if wrong:
            cases = sorted({ident.split("-")[0] for ident in wrong})
            failures.append(f"{name}: {len(wrong)} hits differ from the unscrubbed baseline, cases {' '.join(cases)}")

    msgs = parsed_msgs(loki, server)
    wrong = sorted(ident for ident, expected in baseline["msgs"].items() if msgs.get(ident) != expected)
    if wrong:
        cases = sorted({ident.split("-")[0] for ident in wrong})
        failures.append(f"msg differs from the baseline on {len(wrong)} entries, cases {' '.join(cases)}")
    return failures


def judge_general(loki, server, entries, residual, trading_only):
    def is_trading_only(marker):
        return marker.startswith(trading_only)

    def passes_through(entry):
        return bool(entry["markers"]) and all(is_trading_only(marker) for marker in entry["markers"])

    lines = lines_by_ident(loki, server, "filename")
    failures, leaks = compare_common(entries, lines, passes_through)

    # Order, trace and execution fields are out of scope for general by decision,
    # so they must pass through. Anything else in the marker set must not.
    still_leaking = {}
    for case, markers in leaks.items():
        credential = {marker for marker in markers if not is_trading_only(marker)}
        if credential:
            still_leaking[case] = credential
    failures += compare_residuals(still_leaking, residual)

    applied = []
    for entry in entries:
        kept = [marker for marker in entry["markers"] if is_trading_only(marker)]
        text = "\n".join(lines.get(entry["ident"], []))
        if any(marker not in text for marker in kept):
            applied.append(entry["case"])
        if passes_through(entry) and sorted(lines.get(entry["ident"], [])) != sorted(entry["input"]):
            applied.append(entry["case"])
    if applied:
        failures.append(f"Trading-only rules touched general lines: {' '.join(sorted(set(applied)))}")

    extra = loki.label_names(server) - GENERAL_LABELS
    if extra:
        failures.append(f"unexpected Loki labels: {sorted(extra)}")
    return failures


def judge(args):
    manifest = json.loads(pathlib.Path(args.manifest).read_text(encoding="utf-8"))
    loki = Loki(args.loki)
    rules = rule_expressions(args.rules)
    if len(rules) < 3:
        print(f"FAIL rules: expected the three log rules, found {len(rules)}")
        return 1

    baseline = {"hits": rule_hits(loki, args.baseline, rules), "msgs": parsed_msgs(loki, args.baseline)}
    failed = 0
    for name, hits in baseline["hits"].items():
        if not hits:
            print(f"FAIL baseline: {name} matched nothing, so the comparison would prove nothing")
            failed = 1
        print(f"baseline {name}: {sum(hits.values())} lines")

    trading_residual = parse_residuals(args.trading_residual)
    general_residual = parse_residuals(args.general_residual)
    trading_only = tuple(args.trading_only_prefix)
    for server in args.trading:
        failures = judge_trading(loki, server, manifest["trading"], trading_residual, rules, baseline)
        for failure in failures:
            print(f"FAIL {server}: {failure}")
        if not failures:
            print(f"ok {server}")
        failed = failed or bool(failures)
    for server in args.general:
        failures = judge_general(loki, server, manifest["general"], general_residual, trading_only)
        for failure in failures:
            print(f"FAIL {server}: {failure}")
        if not failures:
            print(f"ok {server}")
        failed = failed or bool(failures)
    return 1 if failed else 0


def strip_scrub(args):
    """Negative control: the same pipeline with every stage.replace removed."""
    path = pathlib.Path(args.path)
    text, count = re.subn(r"^  stage\.replace \{\n.*?^  \}\n", "", path.read_text(encoding="utf-8"), flags=re.S | re.M)
    if count < 2:
        print(f"FAIL baseline: removed only {count} stage.replace blocks")
        return 1
    path.write_text(text, encoding="utf-8")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    samples = commands.add_parser("samples")
    samples.add_argument("--cases", required=True)
    samples.add_argument("--out", required=True)
    samples.add_argument("--manifest", required=True)
    samples.set_defaults(run=write_samples)

    static = commands.add_parser("static")
    static.add_argument("--cases", required=True)
    static.add_argument("--linux", required=True)
    static.add_argument("--macos", required=True)
    static.add_argument("--general", required=True)
    static.set_defaults(run=check_static)

    strip = commands.add_parser("strip-scrub")
    strip.add_argument("path")
    strip.set_defaults(run=strip_scrub)

    wait = commands.add_parser("wait")
    wait.add_argument("--loki", required=True)
    wait.add_argument("--manifest", required=True)
    wait.add_argument("--pipeline", action="append", required=True, help="server=container=trading|general")
    wait.set_defaults(run=wait_for_ingest)

    verdict = commands.add_parser("judge")
    verdict.add_argument("--loki", required=True)
    verdict.add_argument("--manifest", required=True)
    verdict.add_argument("--rules", required=True)
    verdict.add_argument("--baseline", required=True)
    verdict.add_argument("--trading", action="append", required=True)
    verdict.add_argument("--general", action="append", required=True)
    verdict.add_argument("--trading-residual", action="append", required=True, help="CASE:MARKER")
    verdict.add_argument("--general-residual", action="append", required=True, help="CASE:MARKER")
    verdict.add_argument("--trading-only-prefix", action="append", required=True)
    verdict.set_defaults(run=judge)

    args = parser.parse_args()
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())
