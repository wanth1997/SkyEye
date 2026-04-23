# `HostHighCPU`

## Symptoms

```promql
100 - (avg by (instance, product) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85   # for 10 minutes
```

- CPU pegged above 85% across all cores for 10+ minutes.
- May correlate with slower HTTP response times (check `http_request_duration_seconds` p95).
- P2 — Telegram (silent) during work hours.

## Likely causes

1. Legitimate traffic spike — compare `rate(http_requests_total{product="X"}[5m])` against the usual baseline.
2. Runaway background job (scheduler stuck in tight loop, rare event replay).
3. Python GC thrashing — usually accompanied by rising `process_resident_memory_bytes`.
4. External API becoming slow — many requests stacking, each holding a worker.
5. Log-flood by the app — `journalctl` writes I/O-burning and disk.
6. Noisy neighbour on a shared EC2 instance (rare; check cloud-provider status if you use burstable instances).

## Immediate actions

From central Grafana:

```
# Per-core, per-mode — see if it's user / system / iowait
rate(node_cpu_seconds_total{product="$PRODUCT"}[5m])

# Is it correlated with traffic?
sum by (product) (rate(http_requests_total{product="$PRODUCT"}[5m]))

# Is GC out of control
rate(process_cpu_seconds_total{product="$PRODUCT"}[5m])
process_resident_memory_bytes{product="$PRODUCT"}
```

SSH to the host:

```bash
# Who's eating CPU
top -b -n 1 -c | head -20
# Is it uvicorn workers? Scheduler? Something else entirely?

# If it's the backend process, dump a py-spy top for 10 seconds
# (only if py-spy is installed)
pgrep -f uvicorn | head -1 | xargs -I{} sudo py-spy top --pid {} --duration 10

# Scheduler stuck?
journalctl -u ppclub-backend.service --since="15m ago" | grep -i scheduler | tail
```

## Stop the bleeding (if critical)

```bash
# Last-resort: restart the backend. Drops in-flight requests.
sudo systemctl restart ppclub-backend.service
# Watch: does CPU drop immediately → runaway process / tight loop
#        does CPU stay high after restart → external driver (traffic, dependency loop)
```

## Verify recovery

```
100 - (avg by (product) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) < 60
```

## Post-incident

- Capture `py-spy dump --pid <uvicorn>` before restarting if possible — gives a stack snapshot.
- If it was traffic: does that pattern happen again predictably? Consider pre-scaling or async'ing the hot path.
- If it was a runaway job: add guard rails (timeout, max iterations) to the function.
- If it was GC: see if a memory leak emerged around the same time (`process_resident_memory_bytes` rising monotonically).
