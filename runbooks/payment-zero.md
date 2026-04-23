# `ZeroPayment1Hour`

## Symptoms

```promql
(hour() >= 1 and hour() <= 14)                  # Asia/Taipei 09-22
and
sum(increase(ppc_payment_success_total[1h])) == 0
```

- During business hours, no successful payments for 1 full hour
- P1 Telegram delivery

Pay attention to **baseline** — at 9:00 AM Taipei the first-hour counter may legitimately be 0 if no morning customers. Cross-reference against `ppc_payment_created_total` (lots of create, zero success = real problem; zero create too = probably not an incident, just quiet).

## Likely causes

1. NewebPay callback endpoint is failing — payments are happening but we're not recording success
2. NewebPay API itself is down (check `ppc_external_api_duration_seconds{api="newebpay"}` error rate)
3. PPClub backend is up but `/api/v2/payments/notify` handler throws — check unhandled exception counter
4. Signature verification on callback changed — common after NewebPay rotates their hash key
5. DB write on `mark_paid` path is slow / deadlocked — look for SQLite contention

## Immediate actions

From central Grafana Explore (Prometheus):

```
# Is the create rate normal?
rate(ppc_payment_created_total{product="ppclub"}[10m]) > 0

# NewebPay outbound health
sum(rate(ppc_external_api_duration_seconds_count{product="ppclub",api="newebpay",result="ok"}[5m]))
sum(rate(ppc_external_api_duration_seconds_count{product="ppclub",api="newebpay",result=~"error|timeout"}[5m]))

# Unhandled exceptions at /payments/notify
sum by (path) (rate(ppc_unhandled_exception_total{product="ppclub",path=~".*notify.*"}[15m]))
```

From central Loki Explore:

```
{product="ppclub"} |= "notify" |= "error"          # last 30 min
{product="ppclub"} |= "NewebPay"  |~ "Status.*FAIL"
```

SSH to PPClub EC2:

```bash
# Test NewebPay API directly
curl -m 10 -sI https://core.newebpay.com/API/QueryTradeInfo

# Is the callback endpoint reachable externally
curl -m 5 -si https://ppclub.tw/api/v2/payments/notify -X POST -d ''
# Should return 400 or 422 — a 5xx or timeout is the problem

# Tail backend log for callbacks
sudo journalctl -u ppclub-backend.service -f | grep -i notify
```

## Verify recovery

```
# At least one success in the last 15 min
sum(increase(ppc_payment_success_total{product="ppclub"}[15m])) > 0
```

## Post-incident

- Capture `journalctl` around the gap window — what was NewebPay replying
- Diff `ppc_payment_created_total` vs `ppc_payment_success_total` to size the backlog
- Reconcile: compare PPClub DB `paid=false` rows against NewebPay merchant portal for the window
- If NewebPay signature rotated: update config + add a `ppc_newebpay_signature_failure_total` counter for faster detection next time
