# `SchedulerNoHeartbeat`

## Symptoms

```promql
time() - ppc_scheduled_job_last_run_timestamp > 3600   # for 5 minutes
```

A specific scheduler job hasn't updated its heartbeat gauge for an hour. The job's label lands under `exported_job` (Prometheus renames collision with reserved `job` label).

- High — Telegram (loud).
- Usually affects ONE job; if ALL 4 PPClub scheduled jobs go silent, the scheduler itself (not a single job) is dead.

## PPClub scheduled jobs today

| exported_job | What it does |
|---|---|
| `reconcile_pending_payments` | Closes payment records stuck in "pending" past the window |
| `reconcile_pending_refunds` | Same for refunds |
| `cancel_expired_bookings` | Releases court slots from abandoned carts |
| `auto_power_courts` | Turns court lights/AC on/off via Hengfu |

## Likely causes

1. The specific job raised an uncaught exception — `ppc_unhandled_exception_total` should show a spike around when the heartbeat stopped.
2. APScheduler / thread pool jammed — one long-running job holding the executor.
3. DB lock contention preventing scheduler writes.
4. `ppclub-backend.service` restarted and scheduler didn't re-register (check `systemctl status`).
5. Hengfu / external dep timeout causing `auto_power_courts` to hang indefinitely (no timeout set).

## Immediate actions

From central Grafana:

```
# Which job(s) are stale?
time() - ppc_scheduled_job_last_run_timestamp{product="ppclub"}
# (sort descending — anything > 3600 is the subject of the alert)

# Did unhandled exceptions spike around the same time?
sum by (path, exc_type) (increase(ppc_unhandled_exception_total{product="ppclub"}[2h]))

# Is the scheduler's typical external dep misbehaving
sum by (api, result) (rate(ppc_external_api_duration_seconds_count{product="ppclub"}[5m]))
```

In central Loki:

```
{product="ppclub", unit="ppclub-backend.service"} |~ "scheduler|job"   # last 1h
{product="ppclub"} |= "Traceback" |~ "reconcile|cancel_expired|auto_power"
```

On PPClub EC2:

```bash
# Is the backend even up
systemctl status ppclub-backend.service

# Scheduler-related log
sudo journalctl -u ppclub-backend.service --since="1h ago" | grep -iE 'scheduler|apscheduler|\\[job\\]' | tail -30

# Is something stuck? Show uvicorn worker activity
ps auxf | grep uvicorn
# Then py-spy top on the worker for 10s, look for the stuck frame
```

## Stop-the-bleeding

```bash
# If a single job is genuinely jammed and others are fine
# → backend restart will re-register all jobs
sudo systemctl restart ppclub-backend.service
sleep 5
systemctl is-active ppclub-backend.service

# Verify scheduler re-kicked
# (in Grafana, should see the heartbeat age of all 4 jobs reset to ~seconds within 30 s)
```

## Verify recovery

```
time() - ppc_scheduled_job_last_run_timestamp{product="ppclub"} < 300   # everyone fresh within 5 min
```

## Post-incident

- **If ONE job keeps dying**: look at that function. Add an explicit timeout around any external call it makes. Wrap its body in try/except that logs and raises so exceptions show up in `ppc_unhandled_exception_total`.
- **If APScheduler itself was stuck**: one misbehaving job can block the thread pool. Switch that job to a separate executor, or make it async.
- **If restart is the only fix repeatedly**: there's a leak or corruption that accumulates over hours. Add instrumentation inside the job (start/end duration), find the accumulator.
- Note: `auto_power_courts` calls Hengfu which we already know uses `verify=False`. If Hengfu starts responding slowly (as opposed to erroring), this job can stall. Consider a `requests.get(timeout=10)` on every Hengfu call.
