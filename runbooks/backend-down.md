# `BackendDown`

## Symptoms

```promql
up{job=~".+-backend"} == 0   # for 2 minutes
```

- Users see 502 / 504 from `https://ppclub.tw`
- `Alertmanager` delivers P1 Telegram + email
- Caddy access log shows upstream timeouts / refused

## Likely causes

1. `ppclub-backend.service` crashed (Python exception at startup, DB lock, port conflict)
2. Backend is up but pegged — worker unresponsive, `/metrics` scrape times out
3. Network path Alloy → `localhost:8090` broken (IPv6 binding mismatch, firewall rule)
4. uvicorn OOM'd during a request storm
5. Systemd unit disabled / file permissions broken after a deploy

## Immediate actions

SSH to PPClub EC2, then:

```bash
# 1. Is systemd happy
systemctl status ppclub-backend.service
# Active: active → runtime issue (go to #4)
# Active: failed → crash, see journal

# 2. Recent journal for cause-of-death
sudo journalctl -u ppclub-backend.service -n 100 --no-pager

# 3. Can we reach /metrics locally
curl -m 5 -sf http://127.0.0.1:8090/metrics >/dev/null && echo UP || echo DOWN
curl -m 5 -sf http://127.0.0.1:8090/api/health

# 4. If stuck but running — look at worker
ps auxf | grep uvicorn
ss -tlnp 2>/dev/null | grep 8090

# 5. Stop the bleeding
sudo systemctl restart ppclub-backend.service
sleep 3
systemctl is-active ppclub-backend.service
curl -sf http://127.0.0.1:8090/api/health

# 6. If restart fails repeatedly
sudo journalctl -u ppclub-backend.service --since="5m ago" | tail -100
# Look for: ModuleNotFoundError, OperationalError (SQLite lock), port in use
```

## Verify recovery

```
up{job="ppclub-backend"}              # should be 1
rate(http_requests_total{product="ppclub"}[1m])  # should go > 0 as traffic returns
```

Alert will clear automatically after 2 min of `up == 1`.

## Post-incident

- Save `journalctl -u ppclub-backend.service --since="30m ago"` to a file before machine restart / log rotation
- If OOM: check `dmesg | tail` and inspect `node_memory_MemAvailable_bytes` in the hour before
- If SQLite lock: check for long-running process holding the file (`lsof /home/ubuntu/PPClub/backend/ppc.db`) — usually a stale worker
- Link back to deploy time in Grafana annotations to see if alert correlates with a code change
