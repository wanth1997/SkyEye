# `High5xxRate` / `Critical5xxRate`

## Symptoms

```promql
# Medium — 5% over 5 minutes
sum by (product) (rate(http_requests_total{status=~"5.."}[5m]))
  / sum by (product) (rate(http_requests_total[5m])) > 0.05

# High — 10% over 2 minutes
# (same numerator/denominator, threshold 0.10)
```

- Upstream apps return a surge of 5xx responses
- Users see error pages; Caddy may log `context canceled` for upstream reads

## Likely causes

1. Database unreachable / too slow (SQLite lock contention, migration running)
2. External dependency (NewebPay, Hengfu, Google OAuth) timing out → handler raises → 500
3. New deploy introduced a regression (code bug, dependency mismatch)
4. Resource exhaustion — uvicorn workers saturated, RAM pressure causing swap
5. An untemplated path (crawler hitting a route that doesn't exist and hits default 500 instead of 404) — check whether offenders concentrate on one handler

## Immediate actions

From central Grafana (Explore):

```
# Top offenders — which route
topk(5, sum by (handler, status) (rate(http_requests_total{product="ppclub",status=~"5.."}[5m])))

# Are exceptions being raised
sum by (path, exc_type) (rate(ppc_unhandled_exception_total{product="ppclub"}[5m]))

# External dep correlation
sum by (api) (rate(ppc_external_api_duration_seconds_count{product="ppclub",result=~"error|timeout"}[5m]))

# Check if it started right after a change
# (overlay PPClub deploy annotations in Grafana)
```

From central Loki:

```
{product="ppclub"} |= "500 Internal Server Error" | logfmt  # 過濾看 handler
{product="ppclub"} |= "Traceback"
```

SSH to PPClub EC2:

```bash
# Recent exceptions
sudo journalctl -u ppclub-backend.service --since="15m ago" | grep -iE 'traceback|error|exception' | tail -50

# Is DB responsive
time sqlite3 /home/ubuntu/PPClub/backend/ppc.db 'SELECT COUNT(*) FROM bookings;'
# If > 1s, suspect lock contention

# Is uvicorn saturated
ps auxf | grep uvicorn
# RSS and %CPU per worker

# If a specific handler is the culprit, see if it correlates with external API
rate(ppc_external_api_duration_seconds_count{api=<X>,result="error"}[5m])
```

Emergency stop-the-bleeding:

- If a specific route is the entire 5xx mass, add a temporary Caddy match that returns 503 before hitting backend — lets the rest of the app breathe
- If DB is locked and nobody's been writing for 5+ min: `sudo fuser -v /home/ubuntu/PPClub/backend/ppc.db`, kill the stuck writer, restart `ppclub-backend.service`
- If recent deploy caused this: `git revert HEAD && systemctl restart ppclub-backend.service`

## Verify recovery

```
sum by (product) (rate(http_requests_total{status=~"5.."}[5m]))
  / sum by (product) (rate(http_requests_total[5m])) < 0.01
```

Watch for 5-10 min after recovery before considering stable — alerts have a 5-min `for` clause.

## Post-incident

- Save a `ppc_unhandled_exception_total` breakdown from the incident window
- Capture a full traceback for each unique `exc_type` observed
- If DB lock: investigate what held the lock (batch job? new feature? SQLite WAL checkpoint gone stale?)
- Consider adding a circuit breaker around the offending external call (rather than letting it take down the whole handler)
