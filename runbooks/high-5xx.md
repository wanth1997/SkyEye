# 5xx and payment creation failures

Rules: `High5xxRate`, `Critical5xxRate`, `PaymentCreate5xxWarning`,
`PaymentCreate5xxCritical`, `PaymentOrderGenerationFailure`.

## Symptoms

- General 5xx rules: an application is returning an elevated proportion of 5xx responses.
- Payment create rules: `/api/v2/payments/topup` or `/api/v2/payments/create`
  returned repeated 5xx responses even if overall traffic is healthy.
- Order generation rule: the service rejected a tenant outside the supported
  range or exhausted its bounded uniqueness retries.

## Triage in Grafana

```promql
# Payment failures by product and endpoint
sum by (product, handler, status) (
  increase(http_requests_total{
    method="POST",
    status=~"5..",
    handler=~"/api/v2/payments/(topup|create)"
  }[10m])
)

# Order-number failures and collision retries
sum by (product, kind, result) (
  increase(ppc_payment_order_generation_total[15m])
)

# Top 5xx routes
topk(10, sum by (product, handler, status) (
  increase(http_requests_total{status=~"5.."}[10m])
))

# Exceptions and external dependencies
sum by (product, path, exc_type) (
  increase(ppc_unhandled_exception_total[10m])
)
sum by (product, api, result) (
  increase(ppc_external_api_duration_seconds_count{result=~"error|timeout"}[10m])
)
```

In Loki:

```logql
{product="ppclub"} |= "500 Internal Server Error"
{product="ppclub"} |= "Traceback"
```

## LinkCourt production checks

```bash
# Health, active release, and recent application errors
curl -fsS http://127.0.0.1:8090/api/health
readlink -f /opt/apps/linkcourt/current
sudo journalctl -u linkcourt.service --since="15 min ago" \
  | grep -iE 'traceback|error|exception|payment_order' | tail -100

# Runtime and database health
systemctl --no-pager --full status linkcourt.service
sudo -u postgres psql -d ppclub_prod -c 'SELECT 1;'
```

Do not print payment credentials, bank transfer data, or complete order numbers
into chat or incident notes.

## Classify before recovery

1. `capacity_error`: a tenant id cannot fit the external gateway envelope.
   Stop provisioning that tenant; do not bypass the guard or length limit.
2. `exhausted`: all uniqueness retries collided. Preserve existing rows and
   investigate the table constraint and random source before retrying.
3. Payment endpoint 5xx with no order-generation failure: inspect the traceback,
   gateway capability/credentials, database availability, and provider status.
4. If a pending order row exists, preserve it. Never rewrite historical order
   numbers. If no row was created, the user may safely start a new request after
   the root cause is fixed; manual-transfer reconciliation remains manual.
5. If a new LinkCourt release caused the incident, use the documented release
   rollback procedure. Do not run an ad-hoc `git revert` in the live release.

## Verify recovery

```promql
sum by (product, handler) (
  increase(http_requests_total{
    method="POST",
    status=~"5..",
    handler=~"/api/v2/payments/(topup|create)"
  }[10m])
) == 0

sum by (product, kind, result) (
  increase(ppc_payment_order_generation_total{
    result=~"capacity_error|exhausted"
  }[10m])
) == 0
```

Confirm the application health endpoint remains healthy and watch the relevant
rule for at least one full evaluation window. Production payment smoke tests
must be read-only unless an operator explicitly authorizes a real transaction.

## Post-incident

- Record affected product, endpoint, time window, release, and aggregate counts.
- Preserve one sanitized traceback per unique failure.
- Add a regression test for the exact boundary that escaped detection.
- After shadow canary validation, promote the rule through a reviewed change by
  removing `notification_mode: shadow`; do not edit Alertmanager live.
