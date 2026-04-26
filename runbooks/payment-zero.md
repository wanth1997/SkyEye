# `PaymentSuccessRateLow`

> **Renamed from `ZeroPayment1Hour` / `ZeroPaymentHalfDay`** (2026-04-26).
> Old rule produced false positives because `ppc_payment_success_total` was
> only incremented in the live NotifyURL handler — payments confirmed via
> reconciler / late-payment resurrect / 儲值金 were silently absent. PPClub
> commit added `payment_success.inc()` to those 6 paths, and the alert
> switched from absolute-zero to ratio-based.

## Symptoms

```promql
(hour() >= 1 and hour() <= 15)                              # Asia/Taipei 09-23
and
sum(increase(ppc_payment_created_total{status="ok"}[6h])) >= 5
and
(
  sum(increase(ppc_payment_success_total[6h]))
  /
  sum(increase(ppc_payment_created_total{status="ok"}[6h]))
) < 0.3
```

- During business hours
- ≥5 NewebPay-side OK creates over the last 6h (filters quiet days)
- Success-rate < 30% over 6h (sustained, not single failure)
- 30m `for:` (dampens VACC slow transfer / user retry race)

The rule now reflects **reality of all 6 confirm paths** in PPClub:
1. `payment_notify` NotifyURL handler
2. `scheduler.reconcile_pending_payments` — booking, signup, topup (3 paths)
3. `services/refund.try_resurrect_*` — booking, signup (2 paths)
4. `payments.pay-credit` — 儲值金 endpoint

If user reports successful payment but alert fires anyway, **first** verify metric matches DB:

```bash
# DB: how many bookings actually confirmed in last 6h?
ssh ubuntu@ppclub.tw "cd /home/ubuntu/PPClub/backend && \
  sqlite3 ppc.db \"SELECT payment_method, COUNT(*) FROM bookings \
  WHERE confirmed_at >= datetime('now', '-6 hours') GROUP BY payment_method;\""
```

```promql
# Prometheus: how many counts in same window?
sum by (method) (increase(ppc_payment_success_total[6h]))
```

If DB > Prom, **the metric instrumentation has another gap** — find the missing
confirm site and add `payment_success.labels(method=...).inc()`.

## Likely causes (real failure scenarios)

1. **NewebPay HashKey rotated** — signature verification fails on every notify;
   Check `ppc_unhandled_exception_total{path=~".*notify.*"}` rate
2. **NewebPay API itself is down/degraded** — check `ppc_external_api_duration_seconds{api="newebpay"}` error rate
3. **`/api/v2/payments/notify` handler throwing** before `payment_success.inc()` —
   check journalctl for tracebacks at line ~615
4. **Reconciler also failing** — `ppc_scheduled_job_last_run_timestamp{job="reconcile_pending_payments"}` stale
5. **DB write contention** on `mark_paid` path (SQLite WAL lock, especially during
   schema migrations)

## Immediate actions

From central Grafana Explore (Prometheus):

```
# Is the create rate normal? (should match historical baseline ~0.5-2/hr peak)
rate(ppc_payment_created_total{product="ppclub",status="ok"}[10m])

# Per-method success rate (which method is breaking?)
sum by (method) (increase(ppc_payment_success_total{product="ppclub"}[1h]))
sum by (method) (increase(ppc_payment_created_total{product="ppclub",status="ok"}[1h]))

# NewebPay outbound health
sum(rate(ppc_external_api_duration_seconds_count{product="ppclub",api="newebpay",result="ok"}[5m]))
sum(rate(ppc_external_api_duration_seconds_count{product="ppclub",api="newebpay",result=~"error|timeout"}[5m]))

# Unhandled exceptions at /payments/notify
sum by (path) (rate(ppc_unhandled_exception_total{product="ppclub",path=~".*notify.*"}[15m]))

# Reconciler heartbeat (should be < 60s old)
time() - ppc_scheduled_job_last_run_timestamp{job=~"reconcile_pending_payments"}
```

From central Loki Explore:

```
{product="ppclub"} |= "notify" |= "error"          # last 30 min
{product="ppclub"} |= "NewebPay"  |~ "Status.*FAIL"
{product="ppclub"} |= "[reconcile]"                 # see if reconciler is salvaging
```

SSH to PPClub EC2:

```bash
# Test NewebPay API directly
curl -m 10 -sI https://core.newebpay.com/API/QueryTradeInfo

# Is the callback endpoint reachable externally
curl -m 5 -si https://ppclub.tw/api/v2/payments/notify -X POST -d ''
# Should return 400 or {"status":"error"} — a 5xx or timeout is the problem

# Tail backend log for both notify AND reconciler events
sudo journalctl -u ppclub-backend.service -f | grep -iE "notify|reconcile_confirm|resurrect"
```

## Verify recovery

```
# Per-method success in last 15 min
sum by (method) (increase(ppc_payment_success_total{product="ppclub"}[15m])) > 0

# Overall success rate back above 30%
sum(increase(ppc_payment_success_total{product="ppclub"}[1h]))
/
sum(increase(ppc_payment_created_total{product="ppclub",status="ok"}[1h]))
> 0.5
```

## Post-incident

- Capture `journalctl` around the gap window — what was NewebPay replying
- Diff DB confirmed bookings vs `ppc_payment_success_total` — gap means
  another instrumentation site is missing
- Reconcile against NewebPay merchant portal for the window
- If NewebPay signature rotated: update config + add a `ppc_newebpay_signature_failure_total` counter for faster detection next time

## History

- **2026-04-24** — Phase 2D added `ppc_payment_*` counters and original
  `ZeroPayment1Hour` rule
- **2026-04-?? (between 2D and 2026-04-26)** — rule renamed to
  `ZeroPaymentHalfDay` (12h window, conservative). False positives reported.
- **2026-04-26** — root cause found: 6 confirm paths missing
  `payment_success.inc()`. PPClub commit instruments them; rule renamed
  to `PaymentSuccessRateLow` with ratio-based logic + 6h window + 5-attempt floor.
