#!/usr/bin/env python3
"""Prometheus exporter for runner pool host status (POOL_STATUS_<HOST>).

Polls GitHub Actions repository variables for the configured pool repository on
a fixed interval, parses status v1 documents using the pool-pick reader rules
(ai-workflow pool/docs/status.md), and serves cached Prometheus text metrics on
/metrics. Scrapes never contact GitHub.

Standard library only (Python 3.11+).
"""

from __future__ import annotations

import datetime as dt
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
import re
import signal
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_REPO = "wanwanlabs/self-hosted-runner"
DEFAULT_TOKEN_FILE = "/run/secrets/pool-status/github_token"
DEFAULT_API_BASE = "https://api.github.com"
DEFAULT_POLL_INTERVAL = 30.0
DEFAULT_HTTP_TIMEOUT = 10.0
DEFAULT_LISTEN_HOST = "0.0.0.0"
DEFAULT_LISTEN_PORT = 9120
DEFAULT_PER_PAGE = 30
MAX_PAGES = 100
MAX_TOKEN_BYTES = 64 * 1024
MAX_RESPONSE_BYTES = 10 * 1024 * 1024

CLASSES = ("heavy", "light")
STATUS_STATES = ("accepting", "paused", "held", "draining")
GUARD_STATES = ("ok", "paused", "killing", "held", "none")
MIB = 1024 * 1024

HOST_RE = re.compile(r"^(pc|srv([2-9]|[1-9][0-9]+)?)$")
REPO_SLUG_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
NEXT_LINK_RE = re.compile(r';\s*rel="next"(?:\s*;|\s*$)|;\s*rel=next(?:\s*;|\s*$)')

ERROR_REASONS = (
    "token",
    "config",
    "http_401",
    "http_403",
    "http_404",
    "http_5xx",
    "timeout",
    "json",
)

# Host metric families in exact status.md / poolcfg status-metrics order.
STATUS_METRICS = (
    ("pool_status_expected", "1 for every host the exporter is configured to read (POOL_HOSTS)."),
    ("pool_status_updated_timestamp_seconds", "updated_at of POOL_STATUS_<HOST>, GitHub's clock."),
    ("pool_status_readable", "1 if the status reads as v1 the way pool-pick reads it, else 0."),
    ("pool_status_seq", "seq: increases by one on every write."),
    ("pool_status_state", "1 for the host's state, 0 for the others."),
    ("pool_class_slots", "classes.<class>.slots."),
    ("pool_class_busy", "classes.<class>.busy: running runners."),
    ("pool_class_queued", "classes.<class>.queued: jobs seen but not started."),
    ("pool_guard_state", "1 for guard.state, 0 for the others."),
    ("pool_guard_avail_bytes", "guard.avail_mb in bytes; absent when the host has no reading."),
    ("pool_refused_24h", "refused_24h: jobs the policy refused in the last 24 hours."),
    ("pool_cache_token_hits", "cache_token_hits; absent when the host does not report it."),
)

# Status v1 reader schema (status-v1.schema.json with additionalProperties
# omitted so readers ignore unknown fields, per pool/docs/status.md).
READER_SCHEMA = {
    "type": "object",
    "required": [
        "v",
        "host",
        "seq",
        "state",
        "config",
        "image",
        "runner",
        "repos",
        "classes",
        "guard",
        "refused_24h",
    ],
    "properties": {
        "v": {"const": 1},
        "host": {"type": "string", "pattern": r"^(pc|srv([2-9]|[1-9][0-9]+)?)$"},
        "seq": {"type": "integer", "minimum": 0},
        "state": {"enum": list(STATUS_STATES)},
        "reason": {"type": "string", "maxLength": 200},
        "config": {"type": "string", "pattern": r"^[0-9a-f]{64}$"},
        "image": {"type": "string", "pattern": r"^sha256:[0-9a-f]{64}$"},
        "runner": {"type": "string", "pattern": r"^2\.[0-9]+\.[0-9]+$"},
        "repos": {
            "type": "array",
            "uniqueItems": True,
            "maxItems": 200,
            "items": {
                "type": "string",
                "pattern": r"^[A-Za-z0-9]([A-Za-z0-9-]{0,25}[A-Za-z0-9])?$",
            },
        },
        "classes": {
            "type": "object",
            "required": ["heavy", "light"],
            "properties": {
                "heavy": {
                    "type": "object",
                    "required": ["slots", "busy", "queued"],
                    "properties": {
                        "slots": {"type": "integer", "minimum": 0},
                        "busy": {"type": "integer", "minimum": 0},
                        "queued": {"type": "integer", "minimum": 0},
                    },
                },
                "light": {
                    "type": "object",
                    "required": ["slots", "busy", "queued"],
                    "properties": {
                        "slots": {"type": "integer", "minimum": 0},
                        "busy": {"type": "integer", "minimum": 0},
                        "queued": {"type": "integer", "minimum": 0},
                    },
                },
            },
        },
        "guard": {
            "type": "object",
            "required": ["state"],
            "properties": {
                "state": {"enum": list(GUARD_STATES)},
                "avail_mb": {"type": "integer", "minimum": 0},
            },
        },
        "refused_24h": {"type": "integer", "minimum": 0},
        "cache_token_hits": {"type": "integer", "minimum": 0},
    },
}

_TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
}


def log(message: str) -> None:
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"{timestamp} pool-status: {message}", file=sys.stderr, flush=True)


def _reject_json_constant(token: str) -> None:
    raise ValueError(f"unsupported JSON constant: {token}")


def _same_value(a: object, b: object) -> bool:
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    return a == b


def schema_errors(value: object, schema: dict, where: str = "$") -> list[str]:
    """Validate a parsed JSON document against the status v1 reader schema."""
    errors: list[str] = []
    kind = schema.get("type")
    if kind and not _TYPES[kind](value):
        return [f"{where}: must be {kind}"]
    if "const" in schema and not _same_value(value, schema["const"]):
        errors.append(f"{where}: must be {schema['const']!r}")
    if "enum" in schema and not any(_same_value(value, option) for option in schema["enum"]):
        errors.append(f"{where}: value not in allowed enum")
    if isinstance(value, str):
        if "pattern" in schema and not re.fullmatch(schema["pattern"], value):
            errors.append(f"{where}: does not match pattern")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append(f"{where}: exceeds maxLength {schema['maxLength']}")
    if "minimum" in schema and _TYPES["number"](value) and value < schema["minimum"]:
        errors.append(f"{where}: below minimum {schema['minimum']}")
    if isinstance(value, dict):
        for key in schema.get("required", ()):
            if key not in value:
                errors.append(f"{where}: missing {key}")
        properties = schema.get("properties", {})
        for key, item in value.items():
            if key in properties:
                errors.extend(schema_errors(item, properties[key], f"{where}.{key}"))
    if isinstance(value, list):
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append(f"{where}: more than {schema['maxItems']} items")
        if schema.get("uniqueItems") and len({json.dumps(v, sort_keys=True) for v in value}) != len(value):
            errors.append(f"{where}: items must be unique")
        if "items" in schema:
            for index, item in enumerate(value):
                errors.extend(schema_errors(item, schema["items"], f"{where}[{index}]"))
    return errors


def read_status(text: str, host: str | None = None) -> tuple[dict | None, list[str]]:
    """Parse and validate one status document using pool-pick reader rules."""
    try:
        value = json.loads(text, parse_constant=_reject_json_constant)
    except Exception as exc:
        return None, [f"$: not valid JSON ({type(exc).__name__})"]
    try:
        errors = schema_errors(value, READER_SCHEMA)
        if not errors and host is not None and value["host"] != host:
            errors = [f"$.host: {value['host']!r} does not match expected host {host!r}"]
    except Exception as exc:
        return None, [f"$: validation failed ({type(exc).__name__})"]
    return (None if errors else value), errors


def parse_updated_at(text: str) -> int | float:
    """Parse an ISO 8601 timestamp with timezone into Unix seconds."""
    if not isinstance(text, str) or not text:
        raise ValueError("updated_at must be a non-empty string")
    normalized = f"{text[:-1]}+00:00" if text.endswith("Z") else text
    try:
        when = dt.datetime.fromisoformat(normalized)
    except ValueError:
        raise ValueError(f"updated_at {text!r} is not valid ISO 8601") from None
    if when.tzinfo is None:
        raise ValueError(f"updated_at {text!r} has no timezone")
    seconds = when.timestamp()
    return int(seconds) if seconds == int(seconds) else seconds


def parse_hosts(raw: str | None) -> tuple[list[str] | None, str | None]:
    """Validate POOL_HOSTS as a comma-separated list of unique pc / srv<n> ids."""
    if raw is None or not raw.strip(" \t"):
        return None, "POOL_HOSTS is unset or empty"
    hosts: list[str] = []
    seen: set[str] = set()
    for part in raw.split(","):
        host = part.strip(" \t")
        if not HOST_RE.fullmatch(host):
            return None, f"invalid host id in POOL_HOSTS: {host!r}"
        if host in seen:
            return None, f"duplicate host id in POOL_HOSTS: {host!r}"
        seen.add(host)
        hosts.append(host)
    return hosts, None


def parse_repo(raw: str | None) -> tuple[str | None, str | None]:
    """Validate POOL_REPO as owner/repo."""
    value = DEFAULT_REPO if raw is None else raw.strip(" \t")
    if not REPO_SLUG_RE.fullmatch(value) or ".." in value:
        return None, f"invalid POOL_REPO: {value!r}"
    return value, None


def read_token_file(path: str) -> tuple[str | None, str | None]:
    """Read the GitHub token from disk without exposing its contents in errors."""
    try:
        with open(path, "rb") as handle:
            raw = handle.read(MAX_TOKEN_BYTES + 1)
    except OSError as exc:
        return None, f"cannot read token file ({exc.strerror or type(exc).__name__})"
    if len(raw) > MAX_TOKEN_BYTES:
        return None, "token file exceeds maximum allowed size"
    try:
        token = raw.decode("utf-8").strip()
    except UnicodeDecodeError:
        return None, "token file is not valid UTF-8"
    if not token:
        return None, "token file is empty"
    if any(ord(ch) <= 32 or ord(ch) >= 127 for ch in token):
        return None, "token file contains whitespace or non-ASCII control characters"
    return token, None


def has_next_link(link_header: str) -> bool:
    """Return True when an HTTP Link header advertises rel="next"."""
    for params in re.findall(r"<[^>]*>([^,]*)", link_header):
        if NEXT_LINK_RE.search(params):
            return True
    return False


def format_host_metrics(
    hosts: list[str],
    snapshots: dict[str, tuple[int | float, dict | None] | None],
) -> str:
    """Render host metric families in status.md / poolcfg status-metrics format."""
    samples: dict[str, list[str]] = {name: [] for name, _ in STATUS_METRICS}

    def add(name: str, host: str, value: int | float, **labels: str) -> None:
        formatted = ",".join(f'{key}="{val}"' for key, val in {"host": host, **labels}.items())
        samples[name].append(f"{name}{{{formatted}}} {value}")

    for host in hosts:
        add("pool_status_expected", host, 1)
        entry = snapshots.get(host)
        if entry is None:
            continue
        timestamp, doc = entry
        add("pool_status_updated_timestamp_seconds", host, timestamp)
        add("pool_status_readable", host, 0 if doc is None else 1)
        if doc is None:
            continue
        add("pool_status_seq", host, doc["seq"])
        for state in STATUS_STATES:
            add("pool_status_state", host, int(doc["state"] == state), state=state)
        for field in ("slots", "busy", "queued"):
            for cls in CLASSES:
                add(f"pool_class_{field}", host, doc["classes"][cls][field], **{"class": cls})
        for state in GUARD_STATES:
            add("pool_guard_state", host, int(doc["guard"]["state"] == state), state=state)
        if "avail_mb" in doc["guard"]:
            add("pool_guard_avail_bytes", host, doc["guard"]["avail_mb"] * MIB)
        add("pool_refused_24h", host, doc["refused_24h"])
        if "cache_token_hits" in doc:
            add("pool_cache_token_hits", host, doc["cache_token_hits"])

    lines: list[str] = []
    for name, help_text in STATUS_METRICS:
        if samples[name]:
            lines.append(f"# HELP {name} {help_text}")
            lines.append(f"# TYPE {name} gauge")
            lines.extend(samples[name])
    return ("\n".join(lines) + "\n") if lines else ""


class PollError(Exception):
    """Classified failure during a GitHub variables poll.

    reason is one of ERROR_REASONS when mapped to a contracted error counter,
    or None for uncontracted HTTP statuses (e.g. 3xx, 429) that are logged and
    preserve cached state without inventing new metric label values.
    """

    def __init__(self, reason: str | None, detail: str) -> None:
        super().__init__(detail)
        self.reason = reason
        self.detail = detail


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Refuse HTTP redirects so the Bearer token is never forwarded elsewhere."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, f"unexpected redirect {code}", headers, fp)


class GitHubVariablesClient:
    """Fetches paginated repository Actions variables from GitHub's REST API."""

    def __init__(
        self,
        api_base: str = DEFAULT_API_BASE,
        timeout: float = DEFAULT_HTTP_TIMEOUT,
        per_page: int = DEFAULT_PER_PAGE,
    ) -> None:
        self.api_base = api_base.rstrip("/")
        self.timeout = timeout
        self.per_page = per_page
        self._opener = urllib.request.build_opener(_NoRedirectHandler())

    def _fetch_page(self, repo: str, token: str, page: int) -> tuple[dict, str]:
        query = urllib.parse.urlencode({"per_page": self.per_page, "page": page})
        url = f"{self.api_base}/repos/{repo}/actions/variables?{query}"
        request = urllib.request.Request(
            url,
            method="GET",
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "skyeye-pool-status-exporter",
            },
        )
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                raw = response.read(MAX_RESPONSE_BYTES + 1)
                link_header = ", ".join(response.headers.get_all("Link") or [])
        except urllib.error.HTTPError as exc:
            code = exc.code
            if code == 401:
                raise PollError("http_401", "GitHub API returned HTTP 401") from None
            if code == 403:
                raise PollError("http_403", "GitHub API returned HTTP 403") from None
            if code == 404:
                raise PollError("http_404", "GitHub API returned HTTP 404") from None
            if 500 <= code <= 599:
                raise PollError("http_5xx", f"GitHub API returned HTTP {code}") from None
            raise PollError(None, f"GitHub API returned HTTP {code}") from None
        except (
            TimeoutError,
            socket.timeout,
            urllib.error.URLError,
            http.client.HTTPException,
            OSError,
        ) as exc:
            raise PollError("timeout", f"GitHub API request failed ({type(exc).__name__})") from None

        if len(raw) > MAX_RESPONSE_BYTES:
            raise PollError("json", "GitHub API response exceeded size limit")
        try:
            payload = json.loads(raw.decode("utf-8"), parse_constant=_reject_json_constant)
        except Exception as exc:
            raise PollError("json", f"GitHub API response is not valid JSON ({type(exc).__name__})") from None
        if not isinstance(payload, dict) or not isinstance(payload.get("variables"), list):
            raise PollError("json", "GitHub API response missing variables array")
        total_count = payload.get("total_count")
        if total_count is not None and (isinstance(total_count, bool) or not isinstance(total_count, int) or total_count < 0):
            raise PollError("json", "GitHub API response has invalid total_count")
        return payload, link_header

    def fetch_pool_variables(self, repo: str, token_loader) -> dict[str, dict]:
        """Fetch all pages and return only POOL_STATUS_* variables keyed by name.

        token_loader is called before every page HTTP request so mid-poll token
        rotation or removal takes effect immediately.
        """
        collected: dict[str, dict] = {}
        seen_names: set[str] = set()
        expected_total: int | None = None
        page = 1
        while True:
            if page > MAX_PAGES:
                raise PollError("json", f"GitHub API pagination exceeded {MAX_PAGES} pages")
            token = token_loader()
            payload, link_header = self._fetch_page(repo, token, page)
            page_vars = payload["variables"]
            total_count = payload.get("total_count")
            if total_count is not None:
                if expected_total is None:
                    expected_total = total_count
                elif total_count != expected_total:
                    raise PollError(
                        "json",
                        f"GitHub API total_count changed mid-pagination ({expected_total} -> {total_count})",
                    )
            for entry in page_vars:
                if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
                    raise PollError("json", "GitHub API variable entry missing string name")
                name = entry["name"]
                seen_names.add(name)
                if name.startswith("POOL_STATUS_"):
                    collected[name] = entry

            if link_header:
                if not has_next_link(link_header):
                    break
            else:
                if not page_vars:
                    break
                if expected_total is not None:
                    if len(seen_names) >= expected_total:
                        break
                elif len(page_vars) < self.per_page:
                    break
            page += 1

        if expected_total is not None and len(seen_names) != expected_total:
            raise PollError(
                "json",
                f"GitHub API returned {len(seen_names)} unique variables, expected total_count={expected_total}",
            )
        return collected


class PoolStatusExporter:
    """Holds cached metrics state and coordinates periodic GitHub polling."""

    def __init__(
        self,
        hosts_raw: str | None,
        repo_raw: str | None = DEFAULT_REPO,
        token_file: str = DEFAULT_TOKEN_FILE,
        api_base: str = DEFAULT_API_BASE,
        poll_interval: float = DEFAULT_POLL_INTERVAL,
        http_timeout: float = DEFAULT_HTTP_TIMEOUT,
        per_page: int = DEFAULT_PER_PAGE,
        clock=time.time,
    ) -> None:
        self.token_file = token_file
        self.poll_interval = poll_interval
        self.clock = clock
        self.client = GitHubVariablesClient(api_base=api_base, timeout=http_timeout, per_page=per_page)

        hosts, hosts_err = parse_hosts(hosts_raw)
        repo, repo_err = parse_repo(repo_raw)
        if hosts_err is not None:
            self.hosts: list[str] | None = None
            self.repo: str | None = repo
            self.config_error: str | None = hosts_err
        elif repo_err is not None:
            self.hosts = None
            self.repo = None
            self.config_error = repo_err
        else:
            self.hosts = hosts
            self.repo = repo
            self.config_error = None

        self._lock = threading.Lock()
        self._read_timestamp: int = 0
        self._read_errors: dict[str, int] = {reason: 0 for reason in ERROR_REASONS}
        self._snapshots: dict[str, tuple[int | float, dict | None] | None] = {}

    def _record_error(self, reason: str | None, detail: str) -> None:
        if reason is not None:
            with self._lock:
                self._read_errors[reason] += 1
            log(f"poll failed (reason={reason}): {detail}")
        else:
            log(f"poll failed (unclassified): {detail}")

    def _load_token(self) -> str:
        token, token_err = read_token_file(self.token_file)
        if token_err is not None or token is None:
            raise PollError("token", token_err or "token unavailable")
        return token

    def poll_once(self) -> bool:
        """Execute one poll cycle without holding the metrics lock during I/O."""
        if self.config_error is not None or self.hosts is None or self.repo is None:
            self._record_error("config", self.config_error or "invalid configuration")
            return False

        try:
            variables = self.client.fetch_pool_variables(self.repo, self._load_token)
            parsed: dict[str, tuple[int | float, dict | None] | None] = {}
            for host in self.hosts:
                var_name = f"POOL_STATUS_{host.upper()}"
                entry = variables.get(var_name)
                if entry is None:
                    parsed[host] = None
                    continue
                raw_value = entry.get("value")
                raw_updated_at = entry.get("updated_at")
                if not isinstance(raw_value, str) or not isinstance(raw_updated_at, str):
                    raise PollError("json", f"{var_name} missing string value or updated_at")
                try:
                    updated_ts = parse_updated_at(raw_updated_at)
                except ValueError:
                    raise PollError("json", f"{var_name} has invalid updated_at") from None
                doc, errors = read_status(raw_value, host=host)
                if errors:
                    log(f"host={host} status unreadable: {'; '.join(errors)}")
                parsed[host] = (updated_ts, doc)
        except PollError as exc:
            self._record_error(exc.reason, exc.detail)
            return False

        now = int(self.clock())
        with self._lock:
            self._snapshots = parsed
            self._read_timestamp = now
        return True

    def render_metrics(self) -> str:
        """Render cached host metrics plus exporter self-metrics as Prometheus text."""
        with self._lock:
            read_timestamp = self._read_timestamp
            errors = dict(self._read_errors)
            snapshots = dict(self._snapshots)

        chunks: list[str] = []
        if self.hosts is not None:
            host_block = format_host_metrics(self.hosts, snapshots)
            if host_block:
                chunks.append(host_block)

        exporter_lines = [
            "# HELP pool_status_exporter_read_timestamp_seconds Unix timestamp of the last successful GitHub variables read; 0 until the first read succeeds.",
            "# TYPE pool_status_exporter_read_timestamp_seconds gauge",
            f"pool_status_exporter_read_timestamp_seconds {read_timestamp}",
            "# HELP pool_status_exporter_read_errors_total Total failed attempts to read GitHub repository variables, by reason.",
            "# TYPE pool_status_exporter_read_errors_total counter",
        ]
        for reason in ERROR_REASONS:
            exporter_lines.append(f'pool_status_exporter_read_errors_total{{reason="{reason}"}} {errors[reason]}')
        chunks.append("\n".join(exporter_lines) + "\n")
        return "".join(chunks)


class _ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def create_server(exporter: PoolStatusExporter, listen_host: str, listen_port: int) -> ThreadingHTTPServer:
    """Create the HTTP server exposing /metrics from cached exporter state."""

    class MetricsHandler(BaseHTTPRequestHandler):
        server_version = "pool-status-exporter"
        sys_version = ""

        def _send(self, status: int, content_type: str, body: bytes, head_only: bool = False) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head_only:
                self.wfile.write(body)

        def _handle(self, head_only: bool) -> None:
            path = urllib.parse.urlsplit(self.path).path
            if path == "/metrics":
                body = exporter.render_metrics().encode("utf-8")
                self._send(200, "text/plain; version=0.0.4; charset=utf-8", body, head_only=head_only)
            elif path == "/healthz":
                self._send(200, "text/plain; charset=utf-8", b"ok\n", head_only=head_only)
            else:
                self._send(404, "text/plain; charset=utf-8", b"not found\n", head_only=head_only)

        def do_GET(self) -> None:  # noqa: N802
            self._handle(head_only=False)

        def do_HEAD(self) -> None:  # noqa: N802
            self._handle(head_only=True)

        def _method_not_allowed(self) -> None:
            self._send(405, "text/plain; charset=utf-8", b"method not allowed\n")

        do_POST = _method_not_allowed
        do_PUT = _method_not_allowed
        do_DELETE = _method_not_allowed
        do_PATCH = _method_not_allowed

        def log_message(self, format: str, *args) -> None:  # noqa: A002
            return

    return _ReusableThreadingHTTPServer((listen_host, listen_port), MetricsHandler)


def _positive_float_env(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = float(raw)
    except ValueError:
        log(f"invalid {name}={raw!r}; falling back to {default}")
        return default
    if not math.isfinite(value) or value <= 0:
        log(f"non-finite or non-positive {name}={raw!r}; falling back to {default}")
        return default
    return value


def _positive_int_env(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = int(raw)
    except ValueError:
        log(f"invalid {name}={raw!r}; falling back to {default}")
        return default
    if value <= 0:
        log(f"non-positive {name}={raw!r}; falling back to {default}")
        return default
    return value


def _run_poll_loop(
    exporter: PoolStatusExporter,
    stop_event: threading.Event,
    poll_interval: float,
) -> None:
    """Poll repeatedly until stop_event is set; never exit on a single-cycle error."""
    while not stop_event.is_set():
        try:
            exporter.poll_once()
        except Exception as exc:
            log(f"unexpected poll error ({type(exc).__name__}); continuing next cycle")
        if stop_event.wait(poll_interval):
            break


def run_forever() -> int:
    """Start the HTTP server and background poller until SIGTERM/SIGINT."""
    listen_host = os.environ.get("POOL_LISTEN_HOST", DEFAULT_LISTEN_HOST)
    listen_port = _positive_int_env("POOL_LISTEN_PORT", DEFAULT_LISTEN_PORT)
    poll_interval = _positive_float_env("POOL_POLL_INTERVAL_SECONDS", DEFAULT_POLL_INTERVAL)
    http_timeout = _positive_float_env("POOL_HTTP_TIMEOUT_SECONDS", DEFAULT_HTTP_TIMEOUT)
    per_page = _positive_int_env("POOL_PER_PAGE", DEFAULT_PER_PAGE)
    token_file = os.environ.get("POOL_TOKEN_FILE", DEFAULT_TOKEN_FILE)
    api_base = os.environ.get("POOL_API_BASE", DEFAULT_API_BASE)
    hosts_raw = os.environ.get("POOL_HOSTS")
    repo_raw = os.environ.get("POOL_REPO", DEFAULT_REPO)

    exporter = PoolStatusExporter(
        hosts_raw=hosts_raw,
        repo_raw=repo_raw,
        token_file=token_file,
        api_base=api_base,
        poll_interval=poll_interval,
        http_timeout=http_timeout,
        per_page=per_page,
    )
    server = create_server(exporter, listen_host, listen_port)
    stop_event = threading.Event()

    def _handle_signal(signum: int, _frame) -> None:
        log(f"received signal {signum}, shutting down")
        stop_event.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    actual_host, actual_port = server.server_address[:2]
    log(
        f"listening on {actual_host}:{actual_port} "
        f"(hosts={','.join(exporter.hosts) if exporter.hosts else '<invalid>'}, "
        f"repo={exporter.repo or '<invalid>'}, poll={poll_interval}s, token_file={token_file})"
    )

    poller = threading.Thread(
        target=_run_poll_loop,
        args=(exporter, stop_event, poll_interval),
        name="pool-status-poller",
        daemon=True,
    )
    poller.start()
    try:
        server.serve_forever()
    finally:
        stop_event.set()
        server.server_close()
        poller.join(timeout=5.0)
    return 0


if __name__ == "__main__":
    sys.exit(run_forever())
