# `HostOOM`

## Symptoms

```promql
increase(node_vmstat_oom_kill[5m]) > 0   # for 1 minute
```

Linux's OOM killer activated at least once in the last 5 minutes. Something on the host hit the memory ceiling and got killed.

- High — Telegram (loud) immediately.
- The killed process may or may not have been the backend. Check before assuming.

## Likely causes

1. **Backend memory leak** — `process_resident_memory_bytes` has been climbing monotonically for hours / days.
2. **Prometheus cardinality blow-up on the monitoring host** — new label added carelessly (user_id, order_id) explodes series count and RSS.
3. **Large file / chunk load** — one-off request loading a huge blob into memory.
4. **Container without memory limits** — one service eats everything.
5. **Unexpected process started** — someone ran a data-heavy ad-hoc script.

## Immediate actions

On the affected host:

```bash
# Which process got killed? (OOM killer logs to dmesg / kern.log)
sudo dmesg | grep -i 'killed process' | tail -5
sudo journalctl -k --since="20m ago" | grep -iE 'oom|killed process' | tail

# Current memory state
free -h
# Check top offenders NOW (post-kill)
ps auxf --sort=-%mem | head -15
```

From central Grafana:

```
# Pre-kill RSS trend of the backend
process_resident_memory_bytes{product="$PRODUCT",job="ppclub-backend"}[30m]

# Host memory trend
(1 - node_memory_MemAvailable_bytes{product="$PRODUCT"} / node_memory_MemTotal_bytes{product="$PRODUCT"}) * 100
```

In central Loki:

```
{product="$PRODUCT"} |= "MemoryError"
{product="$PRODUCT"} |~ "killed process|out of memory"
```

## If the backend was the victim

```bash
sudo systemctl status ppclub-backend.service
# systemd should have restarted it (Restart=on-failure default)
# Verify it's back up
curl -sf http://127.0.0.1:8090/api/health
```

## If it was Prometheus (on the monitoring host)

```bash
cd /home/ubuntu/SkyEye
# Check series cardinality before restart — find the offender
curl -s http://127.0.0.1:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[:10]'
# Anything in the top 10 that shouldn't be there?
```

If a runaway metric is found, remove the rule / scrape / instrumentation adding it, reload Prom (`curl -X POST :9090/-/reload`). Do NOT restart Prom until source is gone — it'll OOM again on replay.

## Verify recovery

```
increase(node_vmstat_oom_kill[30m]) == 0   # no new OOMs in last 30 min
node_memory_MemAvailable_bytes{product="$PRODUCT"} / node_memory_MemTotal_bytes{product="$PRODUCT"} > 0.2
```

## Post-incident

- **Always** figure out which process was killed — don't assume.
- If it was a legit workload (traffic spike): bump EC2 instance size.
- If it was a leak: `pmap -x <pid>` before kill was the useful snapshot — next time enable and save.
- If it was a Prom cardinality incident: add a recording rule / drop rule to prevent recurrence, document the offending label.
- Add a pre-OOM Medium warning at ~90% memory so you get 15 minutes heads-up next time:
  ```promql
  (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 90
  ```
  (Already in `system.yml` as `HostMemoryHigh`; verify it's tuned.)
