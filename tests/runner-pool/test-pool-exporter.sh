#!/usr/bin/env bash
set -euo pipefail

# Offline test suite for the runner pool status exporter (pool-status):
#   1. Status v1 fixture parity against ai-workflow@2d8984f fixtures
#      (valid .prom match, multi-host family ordering, unknown-field tolerance,
#      invalid docs keeping only heartbeat, fullmatch patterns, no leaked fields).
#   2. Local fake GitHub HTTP server end-to-end checks:
#      cached /metrics (scrapes never hit GitHub), pagination (Link + total_count),
#      401/403/404/5xx/timeout/bad-JSON/redirect errors preserving cached state,
#      disappearing variables, variable-name vs host mismatch, hot token reload,
#      missing/empty token, invalid/missing POOL_HOSTS, and no token in logs.
#   3. Real pinned Python container (--network none, --read-only, --user 65534:65534)
#      verifying uid/gid 65534 reads 0640 group-65534 token, cannot read 0600,
#      and serves valid metrics from a localhost fake GitHub server.
#   4. Compose service contract, Prometheus scrape config, and secret gitignore checks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXPORTER="$REPO_ROOT/pool-status/exporter.py"
FIXTURES="$REPO_ROOT/tests/fixtures/runner-pool"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-pool-exporter.XXXXXX")"
VOL="skyeye-pool-exporter-test-$$"
cleanup() {
  docker volume rm -f "$VOL" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── 1 & 2. Fixture parity + fake GitHub server end-to-end tests ─────────────
printf '==> pool-status unit, fixture parity, and fake GitHub server tests\n'
python3 -B -I - "$REPO_ROOT" "$EXPORTER" "$FIXTURES" "$WORK" <<'PY'
import importlib.util
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

repo_root = Path(sys.argv[1])
exporter_path = Path(sys.argv[2])
fixtures_dir = Path(sys.argv[3])
work_dir = Path(sys.argv[4])

spec = importlib.util.spec_from_file_location("pool_status_exporter", exporter_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

UPDATED_AT = "2026-11-25T00:00:00Z"
TIMESTAMP = 1795564800


def assert_eq(actual, expected, context):
    if actual != expected:
        raise AssertionError(f"{context}\n--- expected ---\n{expected!r}\n--- actual ---\n{actual!r}")


def assert_true(cond, context):
    if not cond:
        raise AssertionError(context)


def samples_only(text):
    return [line for line in text.splitlines() if line and not line.startswith("#")]


def sample_map(text):
    out = {}
    for line in samples_only(text):
        metric, value = line.rsplit(" ", 1)
        out[metric] = value
    return out


# 1a. SOURCE.md records ai-workflow SHA 2d8984f
source_md = (fixtures_dir / "SOURCE.md").read_text(encoding="utf-8")
assert_true("2d8984f" in source_md, "SOURCE.md must record ai-workflow commit SHA 2d8984f")

# 1b. Every valid fixture matches its .prom byte-for-byte
valid_jsons = sorted(fixtures_dir.glob("status-valid-*.json"))
valid_proms = sorted(fixtures_dir.glob("status-valid-*.prom"))
assert_eq(len(valid_jsons), 5, "expected 5 valid status fixtures")
assert_eq([p.stem for p in valid_proms], [p.stem for p in valid_jsons], "valid .prom stems must match .json")

for path in valid_jsons:
    raw = path.read_text(encoding="utf-8")
    doc, errors = mod.read_status(raw)
    assert_eq(errors, [], f"{path.name} should parse without errors")
    host = doc["host"]
    ts = mod.parse_updated_at(UPDATED_AT)
    rendered = mod.format_host_metrics([host], {host: (ts, doc)})
    expected = path.with_suffix(".prom").read_text(encoding="utf-8")
    assert_eq(rendered, expected, f"fixture parity failed for {path.name}")
    for forbidden in (doc["config"], doc["image"], doc["runner"], *doc["repos"], doc.get("reason", "\0")):
        assert_true(forbidden not in rendered, f"forbidden value leaked in {path.name}: {forbidden!r}")

# 1c. Multi-host rendering: each # HELP / # TYPE once, hosts in POOL_HOSTS order
pc_doc, _ = mod.read_status((fixtures_dir / "status-valid-pc-accepting.json").read_text(encoding="utf-8"), host="pc")
srv_doc, _ = mod.read_status((fixtures_dir / "status-valid-srv-draining.json").read_text(encoding="utf-8"), host="srv")
multi = mod.format_host_metrics(["pc", "srv"], {"pc": (TIMESTAMP, pc_doc), "srv": (TIMESTAMP, srv_doc)})
for name, _ in mod.STATUS_METRICS:
    assert_eq(multi.count(f"# HELP {name} "), 1, f"multi-host HELP count for {name}")
    assert_eq(multi.count(f"# TYPE {name} gauge\n"), 1, f"multi-host TYPE count for {name}")
lines = multi.splitlines()
idx_pc_expected = lines.index('pool_status_expected{host="pc"} 1')
idx_srv_expected = lines.index('pool_status_expected{host="srv"} 1')
assert_true(idx_pc_expected < idx_srv_expected, "hosts must appear in POOL_HOSTS order")
assert_true('pool_guard_avail_bytes{host="pc"} 9542041600' in lines, "pc avail_bytes missing")
assert_true('pool_guard_avail_bytes{host="srv"}' not in multi, "srv without avail_mb must omit avail_bytes")
assert_true('pool_cache_token_hits{host="srv"} 0' in lines, "srv cache_token_hits missing")
assert_true('pool_cache_token_hits{host="pc"}' not in multi, "pc without cache_token_hits must omit metric")

# 1d. Unknown fields are ignored (top-level + nested classes/guard)
extra_raw = (fixtures_dir / "status-invalid-extra-field.json").read_text(encoding="utf-8")
extra_doc, extra_errs = mod.read_status(extra_raw, host="pc")
assert_eq(extra_errs, [], "status-invalid-extra-field.json must be readable by reader rules")
assert_eq(
    mod.format_host_metrics(["pc"], {"pc": (TIMESTAMP, extra_doc)}),
    (fixtures_dir / "status-valid-pc-accepting.prom").read_text(encoding="utf-8"),
    "extra top-level field must match pc-accepting.prom",
)
nested_doc = json.loads((fixtures_dir / "status-valid-srv-accepting.json").read_text(encoding="utf-8"))
nested_doc["classes"]["medium"] = {"slots": 1, "busy": 0, "queued": 0}
nested_doc["guard"]["temp_c"] = 68
parsed_nested, nested_errs = mod.read_status(json.dumps(nested_doc), host="srv")
assert_eq(nested_errs, [], "unknown nested fields must be ignored")
assert_eq(
    mod.format_host_metrics(["srv"], {"srv": (TIMESTAMP, parsed_nested)}),
    (fixtures_dir / "status-valid-srv-accepting.prom").read_text(encoding="utf-8"),
    "nested unknown fields must match srv-accepting.prom",
)

# 1e. Invalid fixtures keep only expected, updated_timestamp, readable=0
for bad_name in (
    "status-invalid-bool-seq.json",
    "status-invalid-missing-classes.json",
    "status-invalid-not-json.json",
    "status-invalid-state.json",
    "status-invalid-unknown-version.json",
):
    bad_raw = (fixtures_dir / bad_name).read_text(encoding="utf-8")
    bad_doc, bad_errs = mod.read_status(bad_raw, host="pc")
    assert_true(bad_doc is None and len(bad_errs) > 0, f"{bad_name} must be unreadable")
    out = mod.format_host_metrics(["pc"], {"pc": (TIMESTAMP, None)})
    assert_eq(
        samples_only(out),
        [
            'pool_status_expected{host="pc"} 1',
            f'pool_status_updated_timestamp_seconds{{host="pc"}} {TIMESTAMP}',
            'pool_status_readable{host="pc"} 0',
        ],
        f"unreadable sample set for {bad_name}",
    )

# 1f. Pattern fullmatch rejects trailing newlines and non-standard JSON constants
for field, bad_val in (
    ("host", "pc\n"),
    ("config", "a" * 64 + "\n"),
    ("image", "sha256:" + "4" * 64 + "\n"),
    ("runner", "2.330.0\n"),
):
    mutated = json.loads((fixtures_dir / "status-valid-pc-accepting.json").read_text(encoding="utf-8"))
    mutated[field] = bad_val
    doc, errs = mod.read_status(json.dumps(mutated), host="pc")
    assert_true(doc is None and errs, f"trailing newline in {field} must fail fullmatch")

nan_doc = (fixtures_dir / "status-valid-pc-accepting.json").read_text(encoding="utf-8").replace("1234", "NaN")
assert_true(mod.read_status(nan_doc, host="pc")[0] is None, "NaN must be rejected")

# 1g. updated_at variants
assert_eq(mod.parse_updated_at("2026-11-25T00:00:00Z"), TIMESTAMP, "Z timestamp")
assert_eq(mod.parse_updated_at("2026-11-25T08:00:00+08:00"), TIMESTAMP, "+08:00 timestamp")
assert_eq(mod.parse_updated_at("2026-11-25T00:00:01.5Z"), 1795564801.5, "fractional timestamp")
for bad_ts in ("2026-11-25T00:00:00", "not-a-time", ""):
    try:
        mod.parse_updated_at(bad_ts)
        raise AssertionError(f"bad updated_at should fail: {bad_ts!r}")
    except ValueError:
        pass

# 1h. POOL_HOSTS validation
assert_eq(mod.parse_hosts("pc,srv")[0], ["pc", "srv"], "valid pc,srv")
assert_eq(mod.parse_hosts("pc, srv, srv2, srv10")[0], ["pc", "srv", "srv2", "srv10"], "valid spaced list")
for bad_hosts in (None, "", "   ", "pc,", ",srv", "pc,,srv", "PC", "pc2", "srv0", "srv1", "pc,pc", "pc\n", "bad"):
    hosts_val, err = mod.parse_hosts(bad_hosts)
    assert_true(hosts_val is None and err is not None, f"POOL_HOSTS={bad_hosts!r} must be rejected")

# 1i. C9: _positive_float_env accepts only finite positive numbers
def test_c9_positive_float_env_rejects_non_finite():
    key = "_SKYEYE_TEST_FLOAT_ENV"
    try:
        for bad_val in ("NaN", "nan", "inf", "+inf", "-inf", "Infinity", "-Infinity", "0", "-1.5", "abc"):
            os.environ[key] = bad_val
            assert_eq(mod._positive_float_env(key, 30.0), 30.0, f"bad float env {bad_val!r} must fall back")
        os.environ[key] = "0.25"
        assert_eq(mod._positive_float_env(key, 30.0), 0.25, "finite positive float accepted")
        os.environ[key] = "30"
        assert_eq(mod._positive_float_env(key, 10.0), 30.0, "integer string float accepted")
    finally:
        os.environ.pop(key, None)

test_c9_positive_float_env_rejects_non_finite()


# ── Fake GitHub HTTP server ─────────────────────────────────────────────────
class FakeGitHubState:
    def __init__(self):
        self.lock = threading.Lock()
        self.reset()

    def reset(self):
        with self.lock:
            self.requests = []
            self.mode = "ok"
            self.status_code = 200
            self.delay = 0.0
            self.pages = {}
            self.links = {}
            self.raw_body = None
            self.redirect_location = None
            self.on_page = None
            self.switch_to_raw_after_first_ok = None
            self.default_page = None

    def set_pages(self, pages, links=None, on_page=None, switch_to_raw_after_first_ok=None, default_page=None):
        with self.lock:
            self.mode = "ok"
            self.status_code = 200
            self.delay = 0.0
            self.pages = dict(pages)
            self.links = dict(links or {})
            self.raw_body = None
            self.redirect_location = None
            self.on_page = on_page
            self.switch_to_raw_after_first_ok = switch_to_raw_after_first_ok
            self.default_page = default_page


gh_state = FakeGitHubState()


class FakeGitHubHandler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        page = int(query.get("page", ["1"])[0])
        with gh_state.lock:
            gh_state.requests.append({
                "path": parsed.path,
                "query": query,
                "auth": self.headers.get("Authorization"),
                "accept": self.headers.get("Accept"),
                "api_version": self.headers.get("X-GitHub-Api-Version"),
            })
            mode = gh_state.mode
            status_code = gh_state.status_code
            delay = gh_state.delay
            pages = dict(gh_state.pages)
            links = dict(gh_state.links)
            raw_body = gh_state.raw_body
            redirect_location = gh_state.redirect_location
            on_page = gh_state.on_page
            default_page = gh_state.default_page
            if mode == "ok" and gh_state.switch_to_raw_after_first_ok is not None:
                gh_state.mode = "raw"
                gh_state.raw_body = gh_state.switch_to_raw_after_first_ok
                gh_state.switch_to_raw_after_first_ok = None

        if delay > 0:
            time.sleep(delay)

        if mode == "redirect":
            self.send_response(302)
            self.send_header("Location", redirect_location or "http://127.0.0.1:1/leak")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if mode == "error":
            body = json.dumps({"message": f"simulated {status_code}"}).encode("utf-8")
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if mode == "page2_error" and page == 2:
            body = b'{"message":"boom"}'
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if mode == "raw":
            body = raw_body if isinstance(raw_body, bytes) else raw_body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if on_page is not None:
            on_page(page)
        if page in pages:
            payload = pages[page]
        elif default_page is not None:
            payload = default_page
        else:
            payload = {"total_count": 0, "variables": []}
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        if page in links:
            self.send_header("Link", links[page])
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):  # noqa: A002
        return


gh_server = ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHubHandler)
gh_server.daemon_threads = True
gh_port = gh_server.server_address[1]
gh_base = f"http://127.0.0.1:{gh_port}"
gh_thread = threading.Thread(target=gh_server.serve_forever, daemon=True)
gh_thread.start()

pc_json = (fixtures_dir / "status-valid-pc-accepting.json").read_text(encoding="utf-8")
srv_json = (fixtures_dir / "status-valid-srv-accepting.json").read_text(encoding="utf-8")
token_path = work_dir / "github_token"
FAKE_TOKEN_1 = "ghp_test_token_alpha_0123456789"
FAKE_TOKEN_2 = "ghp_test_token_beta_9876543210"
token_path.write_text(FAKE_TOKEN_1, encoding="utf-8")

try:
    # 2a. Startup state before first poll: read_timestamp=0 and all 8 error reasons=0
    clock_now = [1795565000.0]
    exp = mod.PoolStatusExporter(
        hosts_raw="pc,srv",
        repo_raw="wanwanlabs/self-hosted-runner",
        token_file=str(token_path),
        api_base=gh_base,
        poll_interval=30.0,
        http_timeout=0.2,
        clock=lambda: clock_now[0],
    )
    initial = sample_map(exp.render_metrics())
    assert_eq(initial["pool_status_exporter_read_timestamp_seconds"], "0", "startup read_timestamp must be 0")
    for reason in mod.ERROR_REASONS:
        assert_eq(
            initial[f'pool_status_exporter_read_errors_total{{reason="{reason}"}}'],
            "0",
            f"startup error counter for {reason} must be 0",
        )
    assert_eq(initial['pool_status_expected{host="pc"}'], "1", "expected pc at startup")
    assert_eq(initial['pool_status_expected{host="srv"}'], "1", "expected srv at startup")

    # 2b. Happy path + HTTP server scrape never hits GitHub
    gh_state.set_pages({
        1: {
            "total_count": 4,
            "variables": [
                {"name": "UNRELATED_VAR", "value": "hello", "updated_at": UPDATED_AT},
                {"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT},
                {"name": "POOL_STATUS_SRV", "value": srv_json, "updated_at": UPDATED_AT},
                {"name": "POOL_STATUS_SRV9", "value": srv_json, "updated_at": UPDATED_AT},
            ],
        }
    })
    assert_true(exp.poll_once(), "happy path poll must succeed")
    assert_eq(len(gh_state.requests), 1, "happy path should make 1 GitHub request")
    req = gh_state.requests[0]
    assert_eq(req["path"], "/repos/wanwanlabs/self-hosted-runner/actions/variables", "API path")
    assert_eq(req["query"], {"per_page": ["30"], "page": ["1"]}, "API query")
    assert_eq(req["auth"], f"Bearer {FAKE_TOKEN_1}", "Bearer auth header")
    assert_eq(req["accept"], "application/vnd.github+json", "Accept header")
    assert_eq(req["api_version"], "2022-11-28", "X-GitHub-Api-Version header")

    srv_http = mod.create_server(exp, "127.0.0.1", 0)
    srv_port = srv_http.server_address[1]
    srv_thread = threading.Thread(target=srv_http.serve_forever, daemon=True)
    srv_thread.start()
    try:
        for _ in range(3):
            with urllib.request.urlopen(f"http://127.0.0.1:{srv_port}/metrics", timeout=2) as resp:
                assert_eq(resp.status, 200, "/metrics status")
                assert_true("text/plain" in resp.headers.get("Content-Type", ""), "/metrics content-type")
                body = resp.read().decode("utf-8")
        assert_eq(len(gh_state.requests), 1, "scraping /metrics must NOT hit GitHub")
        assert_true(FAKE_TOKEN_1 not in body, "token must never appear in /metrics")
        assert_true('host="srv9"' not in body, "unconfigured host srv9 must be ignored")
        assert_true("UNRELATED_VAR" not in body, "unrelated var must be ignored")
        metrics = sample_map(body)
        assert_eq(metrics["pool_status_exporter_read_timestamp_seconds"], "1795565000", "read_timestamp updated")
        assert_eq(metrics['pool_status_readable{host="pc"}'], "1", "pc readable")
        assert_eq(metrics['pool_status_readable{host="srv"}'], "1", "srv readable")
        assert_eq(metrics['pool_status_seq{host="pc"}'], "1234", "pc seq")
        assert_eq(metrics['pool_status_seq{host="srv"}'], "88", "srv seq")

        # HEAD /metrics, GET /healthz, 404, 405
        head_req = urllib.request.Request(f"http://127.0.0.1:{srv_port}/metrics", method="HEAD")
        with urllib.request.urlopen(head_req, timeout=2) as resp:
            assert_eq(resp.status, 200, "HEAD /metrics status")
            assert_eq(resp.read(), b"", "HEAD /metrics empty body")
        with urllib.request.urlopen(f"http://127.0.0.1:{srv_port}/healthz", timeout=2) as resp:
            assert_eq(resp.status, 200, "/healthz status")
        for url, method, want_code in (
            (f"http://127.0.0.1:{srv_port}/nope", "GET", 404),
            (f"http://127.0.0.1:{srv_port}/metrics", "POST", 405),
        ):
            try:
                urllib.request.urlopen(urllib.request.Request(url, method=method), timeout=2)
                raise AssertionError(f"{method} {url} should return {want_code}")
            except urllib.error.HTTPError as exc:
                assert_eq(exc.code, want_code, f"{method} {url} status")
    finally:
        srv_http.shutdown()
        srv_http.server_close()

    # 2c. Pagination via Link: rel="next" (>30 variables across 2 pages)
    filler = [{"name": f"FILLER_{i:02d}", "value": "x", "updated_at": UPDATED_AT} for i in range(29)]
    gh_state.reset()
    gh_state.set_pages(
        pages={
            1: {"total_count": 32, "variables": filler + [{"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT}]},
            2: {"total_count": 32, "variables": [{"name": "POOL_STATUS_SRV", "value": srv_json, "updated_at": UPDATED_AT}, {"name": "TAIL", "value": "y", "updated_at": UPDATED_AT}]},
        },
        links={
            1: f'<{gh_base}/repos/wanwanlabs/self-hosted-runner/actions/variables?per_page=30&page=2>; rel="next", <{gh_base}/repos/wanwanlabs/self-hosted-runner/actions/variables?per_page=30&page=2>; rel="last"',
            2: f'<{gh_base}/repos/wanwanlabs/self-hosted-runner/actions/variables?per_page=30&page=1>; rel="prev", <{gh_base}/repos/wanwanlabs/self-hosted-runner/actions/variables?per_page=30&page=1>; rel="first"',
        },
    )
    clock_now[0] = 1795565030.0
    assert_true(exp.poll_once(), "Link pagination poll must succeed")
    assert_eq(len(gh_state.requests), 2, "Link pagination must fetch 2 pages")
    m = sample_map(exp.render_metrics())
    assert_eq(m['pool_status_readable{host="pc"}'], "1", "page 1 host pc present")
    assert_eq(m['pool_status_readable{host="srv"}'], "1", "page 2 host srv present")

    # 2d. Pagination via total_count without Link header
    gh_state.reset()
    gh_state.set_pages(
        pages={
            1: {"total_count": 31, "variables": filler + [{"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT}]},
            2: {"total_count": 31, "variables": [{"name": "POOL_STATUS_SRV", "value": srv_json, "updated_at": UPDATED_AT}]},
        },
    )
    clock_now[0] = 1795565060.0
    assert_true(exp.poll_once(), "total_count pagination poll must succeed")
    assert_eq(len(gh_state.requests), 2, "total_count pagination must fetch 2 pages")
    m = sample_map(exp.render_metrics())
    assert_eq(m['pool_status_readable{host="srv"}'], "1", "page 2 host srv via total_count")

    # 2e. Page 2 error fails entire poll and preserves previous snapshot + read_timestamp
    gh_state.reset()
    gh_state.set_pages(
        pages={1: {"total_count": 31, "variables": filler + [{"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT}]}},
        links={1: f'<{gh_base}/repos/wanwanlabs/self-hosted-runner/actions/variables?per_page=30&page=2>; rel="next"'},
    )
    gh_state.mode = "page2_error"
    clock_now[0] = 1795565090.0
    assert_true(not exp.poll_once(), "page 2 HTTP 500 must fail poll")
    m = sample_map(exp.render_metrics())
    assert_eq(m["pool_status_exporter_read_timestamp_seconds"], "1795565060", "read_timestamp preserved on page 2 error")
    assert_eq(m['pool_status_exporter_read_errors_total{reason="http_5xx"}'], "1", "http_5xx incremented")
    assert_eq(m['pool_status_readable{host="srv"}'], "1", "cached srv preserved on error")

    # 2f. Variable disappears: expected stays 1, updated_timestamp and readable disappear
    gh_state.reset()
    gh_state.set_pages({
        1: {"total_count": 1, "variables": [{"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT}]},
    })
    clock_now[0] = 1795565120.0
    assert_true(exp.poll_once(), "missing variable poll succeeds")
    m = sample_map(exp.render_metrics())
    assert_eq(m['pool_status_expected{host="srv"}'], "1", "missing var still emits expected=1")
    assert_true('pool_status_updated_timestamp_seconds{host="srv"}' not in m, "missing var omits updated_timestamp")
    assert_true('pool_status_readable{host="srv"}' not in m, "missing var omits readable")
    assert_eq(m['pool_status_readable{host="pc"}'], "1", "present var pc still readable")

    # 2g. Variable name vs document host mismatch -> readable=0, heartbeat preserved,
    #     while the other valid host in the same poll stays fully readable
    gh_state.reset()
    gh_state.set_pages({
        1: {
            "total_count": 2,
            "variables": [
                {"name": "POOL_STATUS_PC", "value": srv_json, "updated_at": UPDATED_AT},
                {"name": "POOL_STATUS_SRV", "value": srv_json, "updated_at": UPDATED_AT},
            ],
        }
    })
    clock_now[0] = 1795565150.0
    assert_true(exp.poll_once(), "mismatched host doc poll succeeds")
    m = sample_map(exp.render_metrics())
    assert_eq(m['pool_status_expected{host="pc"}'], "1", "pc expected")
    assert_eq(m['pool_status_updated_timestamp_seconds{host="pc"}'], str(TIMESTAMP), "pc heartbeat kept")
    assert_eq(m['pool_status_readable{host="pc"}'], "0", "mismatched host is unreadable")
    assert_true('pool_status_seq{host="pc"}' not in m, "unreadable host omits seq")
    assert_eq(m['pool_status_readable{host="srv"}'], "1", "valid host srv stays readable in same poll")
    assert_eq(m['pool_status_seq{host="srv"}'], "88", "valid host srv keeps seq in same poll")

    # Also verify a mismatched single variable does not leak host="srv" when POOL_STATUS_SRV is absent
    gh_state.reset()
    gh_state.set_pages({
        1: {
            "total_count": 1,
            "variables": [{"name": "POOL_STATUS_PC", "value": srv_json, "updated_at": UPDATED_AT}],
        }
    })
    clock_now[0] = 1795565160.0
    assert_true(exp.poll_once(), "mismatched single variable poll succeeds")
    m = sample_map(exp.render_metrics())
    assert_eq(m['pool_status_readable{host="pc"}'], "0", "mismatched single var unreadable")
    assert_true('pool_status_seq{host="srv"}' not in m, "mismatched host must not leak srv metrics")

    # 2h. All error modes: 401, 403, 404, 500, 503, redirect, timeout, bad JSON envelope
    # Restore a clean snapshot first so we also prove cache preservation on every error
    gh_state.reset()
    gh_state.set_pages({
        1: {
            "total_count": 2,
            "variables": [
                {"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT},
                {"name": "POOL_STATUS_SRV", "value": srv_json, "updated_at": UPDATED_AT},
            ],
        }
    })
    clock_now[0] = 1795565200.0
    assert_true(exp.poll_once(), "baseline snapshot before error matrix")

    expected_counts = {r: 0 for r in mod.ERROR_REASONS}
    expected_counts["http_5xx"] = 1  # from page2_error above

    for code, reason in ((401, "http_401"), (403, "http_403"), (404, "http_404"), (500, "http_5xx"), (503, "http_5xx")):
        gh_state.reset()
        gh_state.mode = "error"
        gh_state.status_code = code
        clock_now[0] += 30.0
        assert_true(not exp.poll_once(), f"HTTP {code} must fail")
        expected_counts[reason] += 1
        m = sample_map(exp.render_metrics())
        assert_eq(m["pool_status_exporter_read_timestamp_seconds"], "1795565200", f"read_timestamp unchanged on {code}")
        assert_eq(m[f'pool_status_exporter_read_errors_total{{reason="{reason}"}}'], str(expected_counts[reason]), f"{reason} count")

    # C7: Uncontracted HTTP statuses (302 redirect refused, 429 rate limit) fail the
    # poll, preserve cache and read_timestamp, keep http_5xx and all 8 counters
    # unchanged, and never add new reason labels.
    for uncontracted_mode, uncontracted_code in (("redirect", 302), ("error", 429)):
        gh_state.reset()
        gh_state.mode = uncontracted_mode
        gh_state.status_code = uncontracted_code
        gh_state.redirect_location = "http://127.0.0.1:1/should-never-be-called"
        clock_now[0] += 30.0
        assert_true(not exp.poll_once(), f"HTTP {uncontracted_code} must fail poll")
        rendered_uncontracted = exp.render_metrics()
        m = sample_map(rendered_uncontracted)
        assert_eq(m["pool_status_exporter_read_timestamp_seconds"], "1795565200", f"read_timestamp unchanged on {uncontracted_code}")
        assert_eq(m['pool_status_readable{host="pc"}'], "1", f"cached pc preserved on {uncontracted_code}")
        assert_eq(m['pool_status_readable{host="srv"}'], "1", f"cached srv preserved on {uncontracted_code}")
        for reason in mod.ERROR_REASONS:
            assert_eq(
                m[f'pool_status_exporter_read_errors_total{{reason="{reason}"}}'],
                str(expected_counts[reason]),
                f"{reason} counter must stay unchanged on HTTP {uncontracted_code}",
            )
        exported_reasons = re.findall(r'^pool_status_exporter_read_errors_total\{reason="([^"]+)"\}', rendered_uncontracted, re.M)
        assert_eq(tuple(exported_reasons), mod.ERROR_REASONS, "reason label set must stay strictly the 8 contracted values")

    # Timeout
    gh_state.reset()
    gh_state.delay = 0.45
    assert_true(not exp.poll_once(), "slow response must time out")
    expected_counts["timeout"] += 1
    m = sample_map(exp.render_metrics())
    assert_eq(m['pool_status_exporter_read_errors_total{reason="timeout"}'], str(expected_counts["timeout"]), "timeout counted")

    # Bad JSON envelopes: invalid syntax, missing variables list, non-string updated_at, RecursionError
    deep_nested_json = "[" * 2500 + "]" * 2500
    for bad_body in (
        "<html>bad gateway</html>",
        json.dumps({"total_count": 1}),
        json.dumps({"total_count": 1, "variables": [{"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": "no-tz"}]}),
        deep_nested_json,
    ):
        gh_state.reset()
        gh_state.mode = "raw"
        gh_state.raw_body = bad_body
        assert_true(not exp.poll_once(), f"bad API JSON must fail: {bad_body[:30]}")
        expected_counts["json"] += 1
        m = sample_map(exp.render_metrics())
        assert_eq(m["pool_status_exporter_read_timestamp_seconds"], "1795565200", "read_timestamp preserved on bad JSON")
        assert_eq(m['pool_status_readable{host="pc"}'], "1", "cached pc preserved on bad JSON")
        assert_eq(m['pool_status_exporter_read_errors_total{reason="json"}'], str(expected_counts["json"]), "json error counted")

    # C3: Mismatched listings (fewer or more unique variables than total_count, or
    # total_count drift across pages) must fail as json error and preserve cached
    # hosts, heartbeats, and read_timestamp.
    for case_name, pages_cfg, links_cfg in (
        (
            "empty_variables_with_total_count_2",
            {1: {"total_count": 2, "variables": []}},
            {},
        ),
        (
            "extra_variables_over_total_count",
            {
                1: {
                    "total_count": 1,
                    "variables": [
                        {"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT},
                        {"name": "OTHER_VAR", "value": "x", "updated_at": UPDATED_AT},
                    ],
                }
            },
            {},
        ),
        (
            "truncated_link_missing_rel_next",
            {1: {"total_count": 32, "variables": filler + [{"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT}]}},
            {1: f'<{gh_base}/repos/wanwanlabs/self-hosted-runner/actions/variables?per_page=30&page=1>; rel="first"'},
        ),
        (
            "short_page2_under_total_count",
            {
                1: {"total_count": 32, "variables": filler + [{"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT}]},
                2: {"total_count": 32, "variables": [{"name": "ONLY_ONE", "value": "y", "updated_at": UPDATED_AT}]},
            },
            {
                1: f'<{gh_base}/repos/wanwanlabs/self-hosted-runner/actions/variables?per_page=30&page=2>; rel="next"',
                2: f'<{gh_base}/repos/wanwanlabs/self-hosted-runner/actions/variables?per_page=30&page=1>; rel="prev"',
            },
        ),
        (
            "total_count_changed_mid_pagination",
            {
                1: {"total_count": 32, "variables": filler + [{"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT}]},
                2: {"total_count": 31, "variables": [{"name": "POOL_STATUS_SRV", "value": srv_json, "updated_at": UPDATED_AT}]},
            },
            {1: f'<{gh_base}/repos/wanwanlabs/self-hosted-runner/actions/variables?per_page=30&page=2>; rel="next"'},
        ),
    ):
        gh_state.reset()
        gh_state.set_pages(pages_cfg, links=links_cfg)
        clock_now[0] += 30.0
        assert_true(not exp.poll_once(), f"C3 {case_name}: mismatched listing must fail")
        expected_counts["json"] += 1
        m = sample_map(exp.render_metrics())
        assert_eq(m["pool_status_exporter_read_timestamp_seconds"], "1795565200", f"C3 {case_name}: read_timestamp preserved")
        assert_eq(m['pool_status_updated_timestamp_seconds{host="pc"}'], str(TIMESTAMP), f"C3 {case_name}: pc heartbeat preserved")
        assert_eq(m['pool_status_updated_timestamp_seconds{host="srv"}'], str(TIMESTAMP), f"C3 {case_name}: srv heartbeat preserved")
        assert_eq(m['pool_status_readable{host="pc"}'], "1", f"C3 {case_name}: cached pc preserved")
        assert_eq(m['pool_status_readable{host="srv"}'], "1", f"C3 {case_name}: cached srv preserved")
        assert_eq(m['pool_status_exporter_read_errors_total{reason="json"}'], str(expected_counts["json"]), f"C3 {case_name}: json counter")

    # C11: Fallback pagination without Link or total_count continues past a full page
    # of duplicate names (pc, pc, srv, empty) and fails with reason="json" (preserving
    # cache) when repeated full pages exceed MAX_PAGES.
    exp_p1 = mod.PoolStatusExporter(
        hosts_raw="pc,srv",
        repo_raw="wanwanlabs/self-hosted-runner",
        token_file=str(token_path),
        api_base=gh_base,
        poll_interval=30.0,
        http_timeout=1.0,
        per_page=1,
        clock=lambda: clock_now[0],
    )
    gh_state.reset()
    gh_state.set_pages({
        1: {"variables": [{"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT}]},
        2: {"variables": [{"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT}]},
        3: {"variables": [{"name": "POOL_STATUS_SRV", "value": srv_json, "updated_at": UPDATED_AT}]},
        4: {"variables": []},
    })
    clock_now[0] = 1795565250.0
    assert_true(exp_p1.poll_once(), "C11 fallback pagination (pc, pc, srv, empty) must succeed")
    assert_eq(len(gh_state.requests), 4, "C11 fallback pagination must fetch all 4 pages")
    m_p1 = sample_map(exp_p1.render_metrics())
    assert_eq(m_p1["pool_status_exporter_read_timestamp_seconds"], "1795565250", "C11 read_timestamp updated")
    assert_eq(m_p1['pool_status_readable{host="pc"}'], "1", "C11 pc readable")
    assert_eq(m_p1['pool_status_readable{host="srv"}'], "1", "C11 srv readable")

    # Exceeding MAX_PAGES on endless full duplicate pages -> json error, cache preserved
    gh_state.reset()
    gh_state.set_pages(
        pages={},
        default_page={"variables": [{"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT}]},
    )
    clock_now[0] = 1795565280.0
    assert_true(not exp_p1.poll_once(), "C11 exceeding MAX_PAGES must fail")
    assert_eq(len(gh_state.requests), mod.MAX_PAGES, "C11 must stop at MAX_PAGES requests")
    m_p1_after = sample_map(exp_p1.render_metrics())
    assert_eq(m_p1_after["pool_status_exporter_read_timestamp_seconds"], "1795565250", "C11 MAX_PAGES preserves read_timestamp")
    assert_eq(m_p1_after['pool_status_readable{host="pc"}'], "1", "C11 MAX_PAGES preserves cached pc")
    assert_eq(m_p1_after['pool_status_readable{host="srv"}'], "1", "C11 MAX_PAGES preserves cached srv")
    assert_eq(m_p1_after['pool_status_exporter_read_errors_total{reason="json"}'], "1", "C11 MAX_PAGES increments json counter")

    # C2: Deeply nested host status document (RecursionError) keeps host heartbeat with
    # readable=0 while the other host stays readable, and recovers on the next valid poll.
    gh_state.reset()
    gh_state.set_pages({
        1: {
            "total_count": 2,
            "variables": [
                {"name": "POOL_STATUS_PC", "value": deep_nested_json, "updated_at": UPDATED_AT},
                {"name": "POOL_STATUS_SRV", "value": srv_json, "updated_at": UPDATED_AT},
            ],
        }
    })
    clock_now[0] = 1795565300.0
    assert_true(exp.poll_once(), "C2 host RecursionError poll must still succeed")
    m = sample_map(exp.render_metrics())
    assert_eq(m["pool_status_exporter_read_timestamp_seconds"], "1795565300", "C2 host RecursionError updates read_timestamp")
    assert_eq(m['pool_status_updated_timestamp_seconds{host="pc"}'], str(TIMESTAMP), "C2 host RecursionError keeps pc heartbeat")
    assert_eq(m['pool_status_readable{host="pc"}'], "0", "C2 host RecursionError marks pc unreadable")
    assert_eq(m['pool_status_readable{host="srv"}'], "1", "C2 host RecursionError keeps srv readable")

    # Next poll with valid pc recovers pc to readable=1
    gh_state.reset()
    gh_state.set_pages({
        1: {
            "total_count": 2,
            "variables": [
                {"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT},
                {"name": "POOL_STATUS_SRV", "value": srv_json, "updated_at": UPDATED_AT},
            ],
        }
    })
    clock_now[0] = 1795565330.0
    assert_true(exp.poll_once(), "C2 recovery after host RecursionError must succeed")
    m = sample_map(exp.render_metrics())
    assert_eq(m['pool_status_readable{host="pc"}'], "1", "C2 pc recovered to readable=1")

    # C1: Re-read token before every HTTP page request:
    # (a) token rotated between page 1 and page 2 -> page 2 uses new token
    token_path.write_text(FAKE_TOKEN_1, encoding="utf-8")
    def rotate_after_page1(page_num):
        if page_num == 1:
            tmp_rot = work_dir / "github_token.rot"
            tmp_rot.write_text(FAKE_TOKEN_2, encoding="utf-8")
            os.replace(tmp_rot, token_path)

    gh_state.reset()
    gh_state.set_pages(
        pages={
            1: {"total_count": 31, "variables": filler + [{"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT}]},
            2: {"total_count": 31, "variables": [{"name": "POOL_STATUS_SRV", "value": srv_json, "updated_at": UPDATED_AT}]},
        },
        links={1: f'<{gh_base}/repos/wanwanlabs/self-hosted-runner/actions/variables?per_page=30&page=2>; rel="next"'},
        on_page=rotate_after_page1,
    )
    clock_now[0] = 1795565360.0
    assert_true(exp.poll_once(), "C1 mid-pagination token rotation must succeed")
    assert_eq(len(gh_state.requests), 2, "C1 rotation fetched both pages")
    assert_eq(gh_state.requests[0]["auth"], f"Bearer {FAKE_TOKEN_1}", "C1 page 1 used token 1")
    assert_eq(gh_state.requests[1]["auth"], f"Bearer {FAKE_TOKEN_2}", "C1 page 2 re-read token 2")

    # (b) token removed or emptied between page 1 and page 2 -> stops before page 2,
    #     records reason="token", preserves previous read_timestamp and cached snapshot
    for mid_action in ("remove", "empty"):
        token_path.write_text(FAKE_TOKEN_1, encoding="utf-8")
        def break_token_after_page1(page_num, action=mid_action):
            if page_num == 1:
                if action == "remove":
                    token_path.unlink()
                else:
                    token_path.write_text("", encoding="utf-8")

        gh_state.reset()
        gh_state.set_pages(
            pages={
                1: {"total_count": 31, "variables": filler + [{"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT}]},
                2: {"total_count": 31, "variables": [{"name": "POOL_STATUS_SRV", "value": srv_json, "updated_at": UPDATED_AT}]},
            },
            links={1: f'<{gh_base}/repos/wanwanlabs/self-hosted-runner/actions/variables?per_page=30&page=2>; rel="next"'},
            on_page=break_token_after_page1,
        )
        clock_now[0] += 30.0
        assert_true(not exp.poll_once(), f"C1 mid-pagination token {mid_action} must fail poll")
        assert_eq(len(gh_state.requests), 1, f"C1 token {mid_action} must stop before requesting page 2")
        expected_counts["token"] += 1
        m = sample_map(exp.render_metrics())
        assert_eq(m["pool_status_exporter_read_timestamp_seconds"], "1795565360", f"C1 token {mid_action} preserves read_timestamp")
        assert_eq(m['pool_status_readable{host="srv"}'], "1", f"C1 token {mid_action} preserves cached srv")
        assert_eq(m['pool_status_exporter_read_errors_total{reason="token"}'], str(expected_counts["token"]), f"C1 token {mid_action} increments token counter")

    # C2: Polling thread loop survives an unexpected exception on one cycle and continues
    loop_calls = []
    loop_stop = threading.Event()
    class FlakyExporter:
        def poll_once(self):
            loop_calls.append(len(loop_calls) + 1)
            if len(loop_calls) == 1:
                raise RuntimeError("simulated unexpected failure")
            loop_stop.set()
            return True

    loop_thread = threading.Thread(target=mod._run_poll_loop, args=(FlakyExporter(), loop_stop, 0.02), daemon=True)
    loop_thread.start()
    loop_thread.join(timeout=2.0)
    assert_true(not loop_thread.is_alive(), "C2 poller loop should exit cleanly once stop_event is set")
    assert_eq(loop_calls, [1, 2], "C2 poller loop must survive cycle 1 RuntimeError and run cycle 2")

    # 2i. Token hot-reload without restart (atomic replace)
    tmp_tok = work_dir / "github_token.tmp"
    tmp_tok.write_text(f"{FAKE_TOKEN_2}\n", encoding="utf-8")
    os.replace(tmp_tok, token_path)
    gh_state.reset()
    gh_state.set_pages({1: {"total_count": 1, "variables": [{"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT}]}})
    clock_now[0] = 1795565500.0
    assert_true(exp.poll_once(), "poll after token rotation must succeed")
    assert_eq(gh_state.requests[0]["auth"], f"Bearer {FAKE_TOKEN_2}", "exporter must re-read rotated token")

    # 2j. Token empty / whitespace-only -> reason="token", 0 GitHub requests
    for bad_token_content in ("", "   \n\t\n", "tok with space"):
        token_path.write_text(bad_token_content, encoding="utf-8")
        gh_state.reset()
        assert_true(not exp.poll_once(), f"bad token {bad_token_content!r} must fail")
        assert_eq(len(gh_state.requests), 0, "bad token must not hit GitHub")
        expected_counts["token"] += 1
        m = sample_map(exp.render_metrics())
        assert_eq(m['pool_status_exporter_read_errors_total{reason="token"}'], str(expected_counts["token"]), "token error counted")

    # 2k. Subprocess lifecycle tests: missing token -> recovers when file appears; bad POOL_HOSTS -> config error; no token in logs
    def free_port():
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]

    def fetch_metrics(port):
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=2) as resp:
            assert_eq(resp.status, 200, "subprocess /metrics status")
            return resp.read().decode("utf-8")

    def wait_until(predicate, timeout_s=5.0):
        deadline = time.monotonic() + timeout_s
        last = None
        while time.monotonic() < deadline:
            try:
                last = predicate()
                if last:
                    return last
            except Exception:
                pass
            time.sleep(0.05)
        raise AssertionError(f"condition not met within {timeout_s}s (last={last!r})")

    # Missing token at startup, then file appears without restart
    missing_tok = work_dir / "absent_token"
    if missing_tok.exists():
        missing_tok.unlink()
    gh_state.reset()
    gh_state.set_pages({1: {"total_count": 2, "variables": [
        {"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT},
        {"name": "POOL_STATUS_SRV", "value": srv_json, "updated_at": UPDATED_AT},
    ]}})
    p_port = free_port()
    env = {
        "PATH": os.environ.get("PATH", ""),
        "POOL_HOSTS": "pc,srv",
        "POOL_TOKEN_FILE": str(missing_tok),
        "POOL_API_BASE": gh_base,
        "POOL_POLL_INTERVAL_SECONDS": "0.15",
        "POOL_HTTP_TIMEOUT_SECONDS": "1",
        "POOL_LISTEN_HOST": "127.0.0.1",
        "POOL_LISTEN_PORT": str(p_port),
    }
    proc = subprocess.Popen(
        [sys.executable, "-B", "-u", str(exporter_path)],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        def wait_token_err():
            text = fetch_metrics(p_port)
            if int(sample_map(text)['pool_status_exporter_read_errors_total{reason="token"}']) >= 1:
                return text
            return None

        def wait_read_ok():
            text = fetch_metrics(p_port)
            if int(sample_map(text)["pool_status_exporter_read_timestamp_seconds"]) > 0:
                return text
            return None

        body = wait_until(wait_token_err)
        m = sample_map(body)
        assert_eq(m["pool_status_exporter_read_timestamp_seconds"], "0", "missing token read_timestamp=0")
        assert_eq(len(gh_state.requests), 0, "missing token must not call GitHub")
        # Now place token file -> recovers without restart
        missing_tok.write_text(FAKE_TOKEN_1, encoding="utf-8")
        body2 = wait_until(wait_read_ok)
        m2 = sample_map(body2)
        assert_eq(m2['pool_status_readable{host="pc"}'], "1", "recovered pc after token placed")
        assert_eq(m2['pool_status_readable{host="srv"}'], "1", "recovered srv after token placed")
    finally:
        proc.terminate()
        stdout_txt, stderr_txt = proc.communicate(timeout=5)
    assert_eq(proc.returncode, 0, f"exporter should exit 0 on SIGTERM (stderr={stderr_txt})")
    assert_true(FAKE_TOKEN_1 not in stdout_txt and FAKE_TOKEN_1 not in stderr_txt, "token leaked into logs!")

    # C2/C12 subprocess test: fake API atomically switches all subsequent responses to
    # deeply nested JSON (RecursionError) when serving the first valid response, so the
    # baseline read_timestamp is deterministically the last success before failure; the
    # polling thread must stay alive, preserve cached metrics, and auto-recover.
    pc_next_doc = json.loads(pc_json)
    pc_next_doc["seq"] = 1235
    pc_next_json = json.dumps(pc_next_doc)
    gh_state.reset()
    gh_state.set_pages(
        pages={1: {"total_count": 2, "variables": [
            {"name": "POOL_STATUS_PC", "value": pc_json, "updated_at": UPDATED_AT},
            {"name": "POOL_STATUS_SRV", "value": srv_json, "updated_at": UPDATED_AT},
        ]}},
        switch_to_raw_after_first_ok=deep_nested_json,
    )
    p_port = free_port()
    env = {
        "PATH": os.environ.get("PATH", ""),
        "POOL_HOSTS": "pc,srv",
        "POOL_TOKEN_FILE": str(missing_tok),
        "POOL_API_BASE": gh_base,
        "POOL_POLL_INTERVAL_SECONDS": "0.15",
        "POOL_HTTP_TIMEOUT_SECONDS": "1",
        "POOL_LISTEN_HOST": "127.0.0.1",
        "POOL_LISTEN_PORT": str(p_port),
    }
    proc = subprocess.Popen(
        [sys.executable, "-B", "-u", str(exporter_path)],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        def wait_initial_seq():
            text = fetch_metrics(p_port)
            if sample_map(text).get('pool_status_seq{host="pc"}') == "1234":
                return text
            return None

        b1 = wait_until(wait_initial_seq)
        m1 = sample_map(b1)
        ts1 = m1["pool_status_exporter_read_timestamp_seconds"]
        json_err_1 = int(m1['pool_status_exporter_read_errors_total{reason="json"}'])
        assert_true(int(ts1) > 0, "C2 subprocess baseline read_timestamp > 0")

        # Wait for at least one failing RecursionError poll after observing baseline ts1
        target_json_err = max(1, json_err_1 + 1)

        def wait_json_err():
            text = fetch_metrics(p_port)
            if int(sample_map(text)['pool_status_exporter_read_errors_total{reason="json"}']) >= target_json_err:
                return text
            return None

        b2 = wait_until(wait_json_err)
        m2 = sample_map(b2)
        assert_eq(m2["pool_status_exporter_read_timestamp_seconds"], ts1, "C2 subprocess read_timestamp preserved on RecursionError")
        assert_eq(m2['pool_status_seq{host="pc"}'], "1234", "C2 subprocess cached pc preserved on RecursionError")

        # Switch back to valid updated payload -> poller thread must still be alive and recover
        gh_state.set_pages({1: {"total_count": 2, "variables": [
            {"name": "POOL_STATUS_PC", "value": pc_next_json, "updated_at": UPDATED_AT},
            {"name": "POOL_STATUS_SRV", "value": srv_json, "updated_at": UPDATED_AT},
        ]}})

        def wait_recovered_seq():
            text = fetch_metrics(p_port)
            if sample_map(text).get('pool_status_seq{host="pc"}') == "1235":
                return text
            return None

        b3 = wait_until(wait_recovered_seq)
        assert_eq(sample_map(b3)['pool_status_seq{host="pc"}'], "1235", "C2 subprocess recovered after RecursionError")
    finally:
        proc.terminate()
        stdout_txt, stderr_txt = proc.communicate(timeout=5)
    assert_eq(proc.returncode, 0, f"C2 subprocess exporter should exit 0 on SIGTERM (stderr={stderr_txt})")
    assert_true(FAKE_TOKEN_1 not in stdout_txt and FAKE_TOKEN_1 not in stderr_txt, "token leaked in C2 subprocess logs!")

    # Bad POOL_HOSTS -> HTTP 200, reason="config", read_timestamp=0, zero host metrics, 0 GitHub calls
    for bad_hosts_env in (None, "", "pc,invalid_host", "pc,pc"):
        gh_state.reset()
        p_port = free_port()
        env = {
            "PATH": os.environ.get("PATH", ""),
            "POOL_TOKEN_FILE": str(missing_tok),
            "POOL_API_BASE": gh_base,
            "POOL_POLL_INTERVAL_SECONDS": "0.15",
            "POOL_HTTP_TIMEOUT_SECONDS": "1",
            "POOL_LISTEN_HOST": "127.0.0.1",
            "POOL_LISTEN_PORT": str(p_port),
        }
        if bad_hosts_env is not None:
            env["POOL_HOSTS"] = bad_hosts_env
        proc = subprocess.Popen(
            [sys.executable, "-B", "-u", str(exporter_path)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            def wait_config_err():
                text = fetch_metrics(p_port)
                if int(sample_map(text)['pool_status_exporter_read_errors_total{reason="config"}']) >= 1:
                    return text
                return None

            body = wait_until(wait_config_err)
            m = sample_map(body)
            assert_eq(m["pool_status_exporter_read_timestamp_seconds"], "0", f"bad POOL_HOSTS={bad_hosts_env!r} read_ts=0")
            assert_true("pool_status_expected" not in body, f"bad POOL_HOSTS={bad_hosts_env!r} must emit no host metrics")
            assert_eq(len(gh_state.requests), 0, f"bad POOL_HOSTS={bad_hosts_env!r} must not call GitHub")
        finally:
            proc.terminate()
            stdout_txt, stderr_txt = proc.communicate(timeout=5)
        assert_eq(proc.returncode, 0, f"bad POOL_HOSTS exporter should exit 0 on SIGTERM (stderr={stderr_txt})")
        assert_true(FAKE_TOKEN_1 not in stdout_txt and FAKE_TOKEN_1 not in stderr_txt, "token leaked on config error")
finally:
    gh_server.shutdown()
    gh_server.server_close()

print("PASS: fixture parity and fake GitHub server checks")
PY

# ── 3. Compose, Prometheus config, and secret-directory checks ──────────────
printf '==> compose contract, Prometheus config, and secret gitignore checks\n'
COMPOSE_JSON="$(GF_ADMIN_PW=verify-placeholder docker compose --env-file /dev/null \
  -p "skyeye-pool-test-$$" --project-directory "$REPO_ROOT" \
  -f "$REPO_ROOT/docker-compose.yml" config --format json)"

PYTHON_IMAGE="$(python3 -B -I - "$REPO_ROOT" <<'PY' "$COMPOSE_JSON"
import json, re, sys
from pathlib import Path

repo_root = Path(sys.argv[1])
cfg = json.loads(sys.argv[2])
svc = cfg["services"].get("pool-status")
assert isinstance(svc, dict), "pool-status service missing in docker-compose.yml"

image = svc.get("image", "")
assert re.fullmatch(r"python:[0-9]+\.[0-9]+\.[0-9]+-[a-z0-9.-]+@sha256:[0-9a-f]{64}", image), \
    f"pool-status image must pin version and digest, got {image!r}"
assert svc.get("user") == "65534:65534", f"expected user 65534:65534, got {svc.get('user')!r}"
assert svc.get("read_only") is True, f"expected read_only: true, got {svc.get('read_only')!r}"
assert not svc.get("ports"), f"pool-status must not publish ports, got {svc.get('ports')!r}"

vols = svc.get("volumes", [])
secret_mounts = [v for v in vols if v.get("target") == "/run/secrets/pool-status"]
assert len(secret_mounts) == 1, f"expected /run/secrets/pool-status mount, got {vols!r}"
assert secret_mounts[0].get("read_only") is True, "secret mount must be read-only"
assert secret_mounts[0].get("source", "").endswith("/pool-status/secrets"), \
    f"unexpected secret source: {secret_mounts[0]!r}"

env = svc.get("environment", {})
assert env.get("POOL_HOSTS") == "pc,srv", f"unexpected POOL_HOSTS: {env.get('POOL_HOSTS')!r}"
assert env.get("POOL_TOKEN_FILE") == "/run/secrets/pool-status/github_token", \
    f"unexpected POOL_TOKEN_FILE: {env.get('POOL_TOKEN_FILE')!r}"
for k, v in env.items():
    assert "ghp_" not in str(v) and "github_pat_" not in str(v), f"secret token in env {k}"

# Verify Prometheus scrape config for job_name: pool-status has no target labels
prom_text = (repo_root / "prometheus" / "prometheus.yml").read_text(encoding="utf-8")
match = re.search(r"(?ms)^  - job_name: pool-status\n(.*?)(?=^  - job_name:|\Z)", prom_text)
assert match is not None, "job_name: pool-status missing in prometheus/prometheus.yml"
job_block = match.group(1)
assert "targets: ['pool-status:9120']" in job_block, f"unexpected pool-status target:\n{job_block}"
assert "labels:" not in job_block, f"pool-status job must not add target labels:\n{job_block}"
assert "relabel_configs:" not in job_block, f"pool-status job must not add relabel_configs:\n{job_block}"

# Verify secret directory hygiene
secrets_dir = repo_root / "pool-status" / "secrets"
assert (secrets_dir / "README.md").is_file(), "pool-status/secrets/README.md missing"
assert (secrets_dir / ".gitignore").is_file(), "pool-status/secrets/.gitignore missing"

print(image)
PY
)"

git -C "$REPO_ROOT" check-ignore -q pool-status/secrets/github_token || \
  fail "pool-status/secrets/github_token must be gitignored"
! git -C "$REPO_ROOT" check-ignore -q pool-status/secrets/README.md || \
  fail "pool-status/secrets/README.md must not be gitignored"
! git -C "$REPO_ROOT" check-ignore -q pool-status/secrets/.gitignore || \
  fail "pool-status/secrets/.gitignore must not be gitignored"
printf 'PASS: compose, Prometheus job, and secret gitignore checks\n'

# ── 4. Pinned container test: uid/gid 65534, read_only, 0640 group 65534 ────
printf '==> pinned container uid/gid 65534 + read_only + 0640/65534 token test\n'
docker volume create "$VOL" >/dev/null

# Prepare volume with exact production permission model:
#   dir:  1000:65534 mode 2750
#   file: 1000:65534 mode 0640 (github_token) and 0600 (unreadable_0600)
docker run --rm --network none -v "$VOL:/secrets" --entrypoint /bin/sh "$PYTHON_IMAGE" -c '
set -eu
chown 1000:65534 /secrets
chmod 2750 /secrets
printf "%s" "ghp_container_test_token_65534" > /secrets/github_token
chown 1000:65534 /secrets/github_token
chmod 0640 /secrets/github_token
printf "%s" "ghp_unreadable_0600_token" > /secrets/unreadable_0600
chown 1000:65534 /secrets/unreadable_0600
chmod 0600 /secrets/unreadable_0600
'

PC_FIXTURE="$(cat "$FIXTURES/status-valid-pc-accepting.json")"
SRV_FIXTURE="$(cat "$FIXTURES/status-valid-srv-draining.json")"

docker run --rm -i --network none --read-only \
  --user 65534:65534 \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  -v "$REPO_ROOT/pool-status/exporter.py:/app/exporter.py:ro" \
  -v "$VOL:/run/secrets/pool-status:ro" \
  -e PYTHONDONTWRITEBYTECODE=1 \
  -e PYTHONUNBUFFERED=1 \
  -e "PC_FIXTURE=$PC_FIXTURE" \
  -e "SRV_FIXTURE=$SRV_FIXTURE" \
  "$PYTHON_IMAGE" python3 -B -I - <<'PY'
import errno
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Confirm process runs as 65534:65534
assert os.getuid() == 65534, f"expected uid 65534, got {os.getuid()}"
assert os.getgid() == 65534, f"expected gid 65534, got {os.getgid()}"

# Confirm S6 container verification command: test -r succeeds on 0640 group 65534, fails on 0600
r_ok = subprocess.run(["test", "-r", "/run/secrets/pool-status/github_token"])
assert r_ok.returncode == 0, "uid/gid 65534 must read 0640 group 65534 github_token"
r_no = subprocess.run(["test", "-r", "/run/secrets/pool-status/unreadable_0600"])
assert r_no.returncode != 0, "uid/gid 65534 must NOT read 0600 owner 1000 file"

# Confirm read-only root filesystem (C10):
# /tmp is world-writable (01777) for uid 65534, so EROFS proves --read-only is
# genuinely enforced (unlike / where uid 65534 gets EACCES even when writable).
tmp_mode = os.stat("/tmp").st_mode & 0o777
assert tmp_mode == 0o777, f"expected /tmp to be world-writable (0777), got {oct(tmp_mode)}"
try:
    with open("/tmp/ro-probe", "w", encoding="utf-8") as handle:
        handle.write("x")
    raise AssertionError("expected EROFS when writing /tmp/ro-probe on read-only rootfs")
except OSError as exc:
    assert exc.errno == errno.EROFS, f"expected EROFS on /tmp/ro-probe, got {exc}"

with open("/proc/mounts", encoding="utf-8") as mounts:
    root_opts = [
        line.split()[3].split(",")
        for line in mounts
        if len(line.split()) >= 4 and line.split()[1] == "/"
    ]
assert root_opts and "ro" in root_opts[-1], f"expected ro mount option on /, got {root_opts!r}"

# Run local fake GitHub server + real exporter.py inside the hardened container
seen_auth = []
pc_doc = os.environ["PC_FIXTURE"]
srv_doc = os.environ["SRV_FIXTURE"]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        seen_auth.append(self.headers.get("Authorization"))
        payload = {
            "total_count": 2,
            "variables": [
                {"name": "POOL_STATUS_PC", "value": pc_doc, "updated_at": "2026-11-25T00:00:00Z"},
                {"name": "POOL_STATUS_SRV", "value": srv_doc, "updated_at": "2026-11-25T00:00:00Z"},
            ],
        }
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):  # noqa: A002
        return


gh = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
gh.daemon_threads = True
gh_port = gh.server_address[1]
threading.Thread(target=gh.serve_forever, daemon=True).start()


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def run_case(token_file, want_readable):
    port = free_port()
    env = {
        "PATH": os.environ.get("PATH", ""),
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONUNBUFFERED": "1",
        "POOL_HOSTS": "pc,srv",
        "POOL_TOKEN_FILE": token_file,
        "POOL_API_BASE": f"http://127.0.0.1:{gh_port}",
        "POOL_POLL_INTERVAL_SECONDS": "0.2",
        "POOL_HTTP_TIMEOUT_SECONDS": "2",
        "POOL_LISTEN_HOST": "127.0.0.1",
        "POOL_LISTEN_PORT": str(port),
    }
    proc = subprocess.Popen(
        [sys.executable, "-B", "-u", "/app/exporter.py"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        deadline = time.monotonic() + 5.0
        body = ""
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=1) as resp:
                    body = resp.read().decode("utf-8")
                if want_readable and 'pool_status_readable{host="pc"} 1' in body:
                    break
                if not want_readable and 'pool_status_exporter_read_errors_total{reason="token"} 1' in body:
                    break
            except Exception:
                pass
            time.sleep(0.05)
        if want_readable:
            assert 'pool_status_readable{host="pc"} 1' in body, body
            assert 'pool_status_readable{host="srv"} 1' in body, body
            assert 'pool_status_exporter_read_errors_total{reason="token"} 0' in body, body
            assert "ghp_container_test_token_65534" not in body, "token leaked in /metrics"
        else:
            assert 'pool_status_exporter_read_timestamp_seconds 0' in body, body
            assert 'pool_status_exporter_read_errors_total{reason="token"} 0' not in body, body
    finally:
        proc.terminate()
        out, err = proc.communicate(timeout=5)
    assert proc.returncode == 0, f"exporter failed: {err}"
    assert "ghp_container_test_token_65534" not in out + err, "token leaked in container logs"


try:
    run_case("/run/secrets/pool-status/github_token", want_readable=True)
    assert seen_auth and seen_auth[0] == "Bearer ghp_container_test_token_65534", seen_auth
    run_case("/run/secrets/pool-status/unreadable_0600", want_readable=False)
finally:
    gh.shutdown()
    gh.server_close()

print("PASS: container uid/gid 65534 + read_only + 0640 group 65534 checks")
PY

printf 'PASS: pool-status exporter suite passed\n'
