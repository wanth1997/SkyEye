# Python FastAPI — SkyEye instrumentation pattern

Covers two layers, in increasing effort:

1. **HTTP-level** — drop-in via `prometheus-fastapi-instrumentator`. Gives you request rate / 4xx / 5xx / p50-p99 latency per route. 4 lines of code.
2. **Business-level** — centralized `app/metrics.py`. Gives you counters for payment / signup / external API latency / etc. 1 file + 1 line per hook.

Both expose on the same `/metrics` endpoint.

## Layer 1 — HTTP instrumentation (always do this first)

### Install

```bash
pip install 'prometheus-fastapi-instrumentator>=6.1.0,<7.0'
```

Append to `requirements.txt`:

```
prometheus-fastapi-instrumentator>=6.1.0,<7.0
```

### Patch `app/main.py`

Immediately after `app = FastAPI(...)` construction, **BEFORE** any `add_middleware(CORSMiddleware, ...)` or `include_router(...)` calls:

```python
from prometheus_fastapi_instrumentator import Instrumentator

Instrumentator(
    excluded_handlers=["/metrics", "/api/health"],
    should_group_status_codes=False,   # 200 / 201 / 401 / 404 kept separate
    should_ignore_untemplated=True,     # /users/{id} collapses to route template
).instrument(app).expose(app, include_in_schema=False)
```

**Flag rationale**:
- `excluded_handlers`: don't self-observe `/metrics` and don't inflate numbers with `/health` polling.
- `should_group_status_codes=False`: 401 and 404 are semantically different signals, worth keeping apart.
- `should_ignore_untemplated=True`: dynamic path params (`/events/abc-123`) get aggregated to route (`/events/{id}`). Without this, cardinality explodes: one series per unique path.

**Placement rationale** (before CORSMiddleware):
- CORS preflight (OPTIONS) and CORS-rejected requests do NOT count. Usually desired — preflight 2-3x inflates the request number.
- If you later decide you DO want to see preflight, move the `Instrumentator(...)` call AFTER `app.add_middleware(CORSMiddleware, ...)`.

### Configure Alloy to scrape it

```bash
export APP_METRICS_TARGET=localhost:8090   # whatever port uvicorn binds
sudo -E bash agents/alloy/setup.sh
```

### Verify

```
up{job="$PRODUCT-backend"}                 # == 1 from central Prometheus
http_requests_total{product="$PRODUCT"}    # non-empty within 30s
```

## Layer 2 — Business counter pattern

### The `app/metrics.py` file

Create this file once. It's the **only** place where Counters / Histograms / Gauges are *declared* — other modules import and use them.

```python
"""
Prometheus business metrics for {{product}}.

Declaration-only module. Importers get the metric object and call
.inc() / .observe() / .set() at the instrumentation point.

LABEL CARDINALITY RULES:
  ✓ labels may be: method, result, endpoint, event_type, reason, bucket
  ✗ NEVER use:    user_id, email, phone, order_id, session_id, raw URL

Violating this will OOM Prometheus — one series per unique label combo.
"""
from prometheus_client import Counter, Histogram, Gauge

# ---- Payment ----
payment_created = Counter(
    "ppc_payment_created_total",
    "Payment create requests submitted to NewebPay",
    ["method", "status"],   # method: atm|credit_card|linepay; status: ok|api_error|validation_error
)
payment_success = Counter(
    "ppc_payment_success_total",
    "Payments completed (NewebPay callback confirmed)",
    ["method"],
)
refund = Counter(
    "ppc_refund_total",
    "Refund attempts",
    ["reason", "result"],
)

# ---- Events ----
event_signup = Counter(
    "ppc_event_signup_total",
    "Activity signups attempted",
    ["result"],
)

# ---- User lifecycle ----
signup = Counter(
    "ppc_signup_total",
    "New user signups",
    ["method"],
)
phone_verify = Counter(
    "ppc_phone_verify_total",
    "Phone verification attempts",
    ["result"],
)

# ---- Credit ----
credit_topup = Counter(
    "ppc_credit_topup_total",
    "Credit top-ups",
    ["amount_bucket"],
)

# ---- External dependencies ----
external_api_duration = Histogram(
    "ppc_external_api_duration_seconds",
    "Duration of external API calls",
    ["api", "endpoint", "result"],
    buckets=(0.1, 0.3, 0.5, 1, 2, 5, 10),
)

# ---- Scheduler (deadman) ----
scheduled_job_last_run = Gauge(
    "ppc_scheduled_job_last_run_timestamp",
    "Unix timestamp of last successful run of a scheduled job",
    ["job"],
)

# ---- App health ----
unhandled_exception = Counter(
    "ppc_unhandled_exception_total",
    "Unhandled exceptions caught by global exception handler",
    ["path", "exc_type"],
)


# ---- Helper: amount bucketing ----
def amount_bucket(amount_twd: int) -> str:
    """Collapse an amount into a bounded set of label values (low cardinality)."""
    if amount_twd < 500:   return "0-500"
    if amount_twd < 1000:  return "500-1000"
    if amount_twd < 5000:  return "1000-5000"
    return "5000+"
```

### Using counters at hook points

```python
# In app/newebpay.py
from app.metrics import payment_created, external_api_duration

def create_payment(method: str, ...):
    with external_api_duration.labels(
        api="newebpay", endpoint="CreatePayment", result="pending"
    ).time():
        try:
            response = requests.post(newebpay_url, ...)
            payment_created.labels(method=method, status="ok").inc()
            return response
        except requests.Timeout:
            payment_created.labels(method=method, status="timeout").inc()
            raise
        except Exception:
            payment_created.labels(method=method, status="api_error").inc()
            raise
```

### Scheduler deadman pattern

```python
# In app/scheduler.py
import time
from app.metrics import scheduled_job_last_run

def my_hourly_job():
    try:
        # ... job logic ...
        scheduled_job_last_run.labels(job="expire_old_reservations").set(time.time())
    except Exception:
        # Don't update on failure — the deadman alert (time() - last_run > 3600) fires
        raise
```

### Global exception handler

```python
# In app/main.py
from app.metrics import unhandled_exception

@app.exception_handler(Exception)
async def global_exc_handler(request, exc):
    unhandled_exception.labels(
        path=request.url.path[:100],       # truncate to cap cardinality
        exc_type=type(exc).__name__,
    ).inc()
    # ... existing 500 response construction ...
```

## Label cardinality — do NOT ignore

Counters * unique label combinations = series count. Every series costs memory in Prometheus and storage in S3.

| Good label | Why | Cardinality |
|---|---|---|
| `method` | Fixed set: atm / credit_card / linepay | 3 |
| `status` | Fixed set: ok / failed / timeout / api_error | 4-6 |
| `endpoint` (external API) | Fixed set per provider | ~10 |
| `amount_bucket` | Bucketed to 4 buckets | 4 |

| Bad label | Why | Cardinality |
|---|---|---|
| `user_id` | Unbounded | ~millions over time |
| `email` | Same, also PII | ~millions |
| `order_id` | Unbounded | ~millions |
| `url` with IDs in it | Same, `/users/1/orders/2/...` | high × high |

If Prometheus starts dropping samples or OOMing, label cardinality is the first place to look.

## Things to skip

- **Don't instrument every function.** Focus on user-visible events (HTTP requests, business outcomes, external dependency calls) and known-slow paths. Internal plumbing usually isn't worth the noise.
- **Don't use Summary** (the 4th Prometheus type). Histograms are better for aggregation across replicas, and Prom computes quantiles server-side with `histogram_quantile()`.
- **Don't track latency with a Counter.** Use a Histogram; you get both count and bucketed timing.

## Reference

- [prometheus_client](https://github.com/prometheus/client_python) docs
- [prometheus-fastapi-instrumentator](https://github.com/trallnag/prometheus-fastapi-instrumentator)
- [Loki label best-practices](https://grafana.com/docs/loki/latest/best-practices/) — same cardinality logic applies
