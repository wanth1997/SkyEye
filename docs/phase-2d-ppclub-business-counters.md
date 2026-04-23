# Phase 2D — PPClub business counters

Adds domain-level metrics on top of Phase 2C's HTTP-level instrumentation:
payment / refund / signup / external API / scheduler / unhandled exception.

Once this lands, `prometheus/rules/business.yml` rules that were waiting
for `ppc_payment_success_total`, `ppc_refund_total`, etc. become evaluable,
and business dashboards can start showing meaningful graphs.

## Philosophy

Counters are **additive-only** code changes. This Phase:
- **Does not** change any existing business logic
- **Does not** change response shapes or introduce new exception types
- **Does** add one import + one or two `counter.inc()` calls per hook

Think of each hook as a side-effect observer: "whenever X happens, count it".

## Risk

| Aspect | Level |
|---|---|
| Code change size | ~30 lines across 8 files (import + inc call pattern) |
| Logic change | Zero |
| Downtime | 3-5 sec (systemctl restart) |
| Rollback | `git revert` — counters are self-contained |

## Step 1 — Create `app/metrics.py` (SINGLE source of truth)

**New file**: `/home/ubuntu/PPClub/backend/app/metrics.py`

Full content — copy exactly:

```python
"""
Prometheus business metrics for PPClub.

Declaration-only module. Importers get the metric object and call
.inc() / .observe() / .set() at the instrumentation point.

LABEL CARDINALITY RULES (non-negotiable):
  ✓ labels may be:  method, result, endpoint, event_type, reason, bucket
  ✗ NEVER use:      user_id, email, phone, order_id, session_id, raw URL

Violating this OOMs Prometheus — one time series per unique label combo.
See docs/code-patterns/python-fastapi.md in the SkyEye repo for rationale.
"""
from prometheus_client import Counter, Histogram, Gauge

# ─────────────────────────── Payment ───────────────────────────

payment_created = Counter(
    "ppc_payment_created_total",
    "Payment create requests submitted to NewebPay",
    ["method", "status"],
    # method: atm|credit_card|linepay|other
    # status: ok|api_error|timeout|validation_error
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
    # reason: user_request|expired|duplicate|admin
    # result: ok|failed|already_refunded|api_error
)

# ─────────────────────────── Events ───────────────────────────

event_signup = Counter(
    "ppc_event_signup_total",
    "Activity signups attempted",
    ["result"],
    # result: ok|full|late|cancelled|validation_error
)

# ─────────────────────── User lifecycle ───────────────────────

signup = Counter(
    "ppc_signup_total",
    "New user signups",
    ["method"],
    # method: google|email|phone|other
)

phone_verify = Counter(
    "ppc_phone_verify_total",
    "Phone verification attempts",
    ["result"],
    # result: ok|bad_code|expired|rate_limited|sms_api_error
)

# ─────────────────────────── Credit ───────────────────────────

credit_topup = Counter(
    "ppc_credit_topup_total",
    "Credit top-ups",
    ["amount_bucket"],
)

# ──────────────────── External dependencies ────────────────────

external_api_duration = Histogram(
    "ppc_external_api_duration_seconds",
    "Duration of external API calls",
    ["api", "endpoint", "result"],
    # api:      newebpay|hengfu|google|sms
    # endpoint: short name of the remote op (QueryTradeInfo, DeviceDetails, ...)
    # result:   ok|error|timeout
    buckets=(0.1, 0.3, 0.5, 1, 2, 5, 10),
)

# ──────────────────── Scheduler (deadman) ──────────────────────

scheduled_job_last_run = Gauge(
    "ppc_scheduled_job_last_run_timestamp",
    "Unix timestamp of last SUCCESSFUL run of a scheduled job",
    ["job"],
)

# ─────────────────────── App health ────────────────────────────

unhandled_exception = Counter(
    "ppc_unhandled_exception_total",
    "Unhandled exceptions caught by global exception handler",
    ["path", "exc_type"],
)

# ─────────────────────── Helpers ───────────────────────────────

def amount_bucket(amount_twd) -> str:
    """Collapse an amount into a bounded set of label values (low cardinality)."""
    try:
        n = int(amount_twd)
    except (TypeError, ValueError):
        return "invalid"
    if n < 500:    return "0-500"
    if n < 1000:   return "500-1000"
    if n < 5000:   return "1000-5000"
    return "5000+"
```

## Step 2 — Instrument hook points

Each subsection below is one hook. Follow the pattern; exact lines will
vary with the current code state. **The rule**: do not change existing
business logic, only add observation.

### 2.1 Payment created — `app/newebpay.py`

Find the function that sends the create-payment request to NewebPay
(probably called `create_payment` or similar). At the place where the
HTTP response comes back and is classified as success/failure, insert:

```python
from app.metrics import payment_created, external_api_duration

def create_payment(..., method: str, ...):
    # Existing code ...

    # === NEW: wrap the outbound HTTP call in a timer
    with external_api_duration.labels(
        api="newebpay", endpoint="CreatePayment", result="pending"
    ).time():
        try:
            response = newebpay_api_post(...)    # ← whatever existing call is
            status = "ok"
        except requests.Timeout:
            status = "timeout"
            raise
        except Exception:
            status = "api_error"
            raise
        finally:
            payment_created.labels(method=method, status=status).inc()
    # === END NEW

    # Existing code continues to process response ...
```

If the function already has try/except, fold the counter into the existing
structure — don't create nested try blocks.

### 2.2 Payment success callback — `app/routers_v2/payments.py`

Find the route handler that receives NewebPay's payment-confirmation callback
(the "付款成功" notify). Inside, at the point where we've verified the
callback's signature and determined the payment is truly successful, insert:

```python
from app.metrics import payment_success

@router.post(".../callback")
async def newebpay_callback(...):
    # Existing signature verification and payload parsing ...

    if status == "SUCCESS" or is_success_in_existing_terms:
        # === NEW
        payment_success.labels(method=resolved_method).inc()
        # === END NEW

        # Existing order-marking / email / etc ...
```

Only count once per successful callback. If the same callback is delivered
twice (NewebPay retries), count both — the ZeroPayment1Hour rule doesn't
care about dupes, and duplicate callbacks are already rare enough to not
distort the rate.

### 2.3 Refund — `app/services/refund.py`

Find the main refund function. Wrap its outcome:

```python
from app.metrics import refund, external_api_duration

def do_refund(..., reason: str):
    try:
        with external_api_duration.labels(
            api="newebpay", endpoint="Refund", result="pending"
        ).time():
            existing_refund_logic(...)

        refund.labels(reason=reason, result="ok").inc()
    except AlreadyRefundedError:                     # whatever the existing class is
        refund.labels(reason=reason, result="already_refunded").inc()
        raise
    except Exception:
        refund.labels(reason=reason, result="failed").inc()
        raise
```

If the code doesn't have a typed `AlreadyRefundedError` today, just use
`Exception` for the general failure case and skip the `already_refunded`
branch — don't introduce a new exception type.

### 2.4 Activity signup — `app/routers_v2/openplay.py`

Find the signup endpoint. Instrument the outcome:

```python
from app.metrics import event_signup

@router.post(".../signup")
async def signup_for_event(...):
    try:
        existing_logic(...)
        event_signup.labels(result="ok").inc()
    except EventFullError:
        event_signup.labels(result="full").inc()
        raise
    except Exception:
        event_signup.labels(result="validation_error").inc()
        raise
```

### 2.5 Credit top-up — `app/routers/credit.py`

Find the top-up endpoint. The `amount_bucket` helper is already in metrics.py:

```python
from app.metrics import credit_topup, amount_bucket

@router.post(".../topup")
async def credit_topup_endpoint(amount: int, ...):
    # Existing logic ...
    credit_topup.labels(amount_bucket=amount_bucket(amount)).inc()
    # ...
```

If the existing flow has distinct success/failure paths (e.g. payment flow
inside topup), count AFTER the amount is confirmed as top-up-initiated,
not on raw request receipt — otherwise we double-count with payment_created.

### 2.6 Signup — `app/routers_v2/auth.py`

```python
from app.metrics import signup

@router.post(".../signup")
async def register(...):
    # Existing code creates user ...
    signup.labels(method=resolved_method).inc()    # google|email|phone|...
    # ...
```

Place AFTER the user row is committed to DB, so we count completed
registrations not failed ones.

### 2.7 Phone verify — `app/routers_v2/phone.py`

```python
from app.metrics import phone_verify

@router.post(".../verify")
async def verify_phone(code: str, ...):
    try:
        # Existing verification logic
        phone_verify.labels(result="ok").inc()
    except BadCodeError:
        phone_verify.labels(result="bad_code").inc()
        raise
    except RateLimitError:
        phone_verify.labels(result="rate_limited").inc()
        raise
    # Use whatever exception types exist; don't add new ones.
```

### 2.8 Hengfu API calls — `app/hengfu_hardware.py`

Same pattern as NewebPay external API timing:

```python
from app.metrics import external_api_duration

def get_device_details(device_id: int):
    with external_api_duration.labels(
        api="hengfu", endpoint="DeviceDetails", result="pending"
    ).time():
        try:
            response = requests.get(...)
            # mark label after success — see note below
            return response.json()
        except Exception:
            raise
```

**Note on result label**: `external_api_duration` has a `result` label on
the timer. If you want it to reflect the ACTUAL outcome per call (`ok` /
`error` / `timeout`), you must re-create the timer with the final label.
Simpler pattern: wrap in a helper.

```python
# Put this at the bottom of app/metrics.py (optional refinement)
from contextlib import contextmanager
import time

@contextmanager
def timed_external(api: str, endpoint: str):
    """Context manager that records duration + result label in one go."""
    start = time.monotonic()
    result = "ok"
    try:
        yield
    except Exception as e:
        result = "timeout" if isinstance(e, (TimeoutError,)) else "error"
        raise
    finally:
        external_api_duration.labels(
            api=api, endpoint=endpoint, result=result
        ).observe(time.monotonic() - start)
```

Usage:

```python
from app.metrics import timed_external

with timed_external("hengfu", "DeviceDetails"):
    response = requests.get(...)
```

Either pattern works. The helper is cleaner if you have many external calls.

### 2.9 Scheduler heartbeats — `app/scheduler.py`

For every scheduled job, set the gauge on successful completion:

```python
import time
from app.metrics import scheduled_job_last_run

def expire_stale_reservations():    # or whatever each job is named
    try:
        # existing job body
        scheduled_job_last_run.labels(job="expire_stale_reservations").set(time.time())
    except Exception:
        # Deliberately do NOT update on failure — deadman alert (time() - last_run > 3600) fires.
        raise
```

**Job naming**: use a stable, descriptive string per job; it becomes the
`job` label (e.g. `job="expire_stale_reservations"`). Keep it constant
across restarts. No timestamps, no PIDs.

If there are multiple distinct scheduled jobs, repeat for each.

### 2.10 Global exception handler — `app/main.py`

The plan says the global exception handler is at around L94. Find it
(it looks like `@app.exception_handler(Exception)` or similar). Add:

```python
from app.metrics import unhandled_exception

@app.exception_handler(Exception)
async def global_exc_handler(request, exc):
    # === NEW ===
    unhandled_exception.labels(
        path=request.url.path[:100],       # truncate to cap cardinality
        exc_type=type(exc).__name__,
    ).inc()
    # === END NEW ===

    # Existing 500 response construction ...
```

## Step 3 — Deploy

```bash
cd /home/ubuntu/PPClub/backend

# Dry-run: ensure everything imports cleanly
.venv/bin/python -c "from app.main import app; from app.metrics import payment_created; print('import OK')"

# Test on an alt port
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8091 &
DRY=$!
sleep 3
# /metrics should now include ppc_* lines (mostly at 0 until real traffic flows)
curl -s http://127.0.0.1:8091/metrics | grep -E '^ppc_' | head -20
kill $DRY; wait $DRY 2>/dev/null

# Prod restart
sudo systemctl restart ppclub-backend.service
sleep 3
systemctl is-active ppclub-backend.service
curl -sf http://127.0.0.1:8090/metrics | grep -cE '^ppc_'
```

No change needed on SkyEye / Alloy side — the `/metrics` endpoint already
returns these new counters and the same Alloy scrape picks them up.

## Step 4 — Verify (central)

Give it ~2 minutes for Prom to accumulate some series, then:

```
# Series count
count by (__name__) ({__name__=~"ppc_.*"})

# Each counter should exist (value may be 0 if no traffic yet)
sum(ppc_payment_created_total{product="ppclub"})
sum(ppc_refund_total{product="ppclub"})
sum(ppc_event_signup_total{product="ppclub"})
sum(ppc_signup_total{product="ppclub"})

# Scheduler heartbeat — each job should eventually have a recent timestamp
time() - ppc_scheduled_job_last_run_timestamp{product="ppclub"}

# Business rules become live
ALERTS{alertname=~"ZeroPayment1Hour|RefundSurge|ExternalApiDown"}
```

## Rollback

```bash
cd /home/ubuntu/PPClub
git revert HEAD         # or the specific Phase 2D commit
sudo systemctl restart ppclub-backend.service
```

`ppc_*` series in Prometheus will stop updating and age out per retention
(30 days). No cleanup needed.

## Naming — why `ppc_` prefix

PPClub's existing convention (the HTTP instrumentator picks up `http_*` by
default; process-level are `process_*`). `ppc_` prefix keeps business
metrics visually distinct from standard exports and from future
multi-product renames. If the product gets renamed, migrate the prefix
via a mapping rule — not critical for now.
