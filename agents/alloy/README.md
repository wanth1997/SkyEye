# Grafana Alloy agent (SkyEye)

This directory contains the one-shot installer for **Grafana Alloy** — a single agent binary that collects logs and metrics from a host and pushes them to the central SkyEye monitoring stack via Cloudflare Tunnel.

## What it does

| Phase | Enabled by | Collected |
|---|---|---|
| **2A** (current) | Always | systemd journal (selected units), PII-scrubbed, → central Loki |
| 2B | `PROM_PUSH_URL` set | node_exporter (CPU/RAM/disk/net) → central Prometheus |
| 2C | `APP_SCRAPE_TARGET` set | App `/metrics` scrape → central Prometheus |

Phase 2A is log-only — no code changes on the host, low risk.

## Requirements

- Ubuntu / Debian (apt-based)
- systemd (for journald collection)
- Outbound HTTPS to `*.wanbrain.com` (via Cloudflare Tunnel endpoints)
- root / sudo

## Phase 2A install — log collection only

### 1. Get the files onto the target host

```bash
# If the host can reach GitHub:
git clone https://github.com/wanth1997/SkyEye.git
cd SkyEye

# Otherwise scp the agents/alloy/ directory over from another box.
```

### 2. Prepare the env vars

Required:

| Variable | Example | Notes |
|---|---|---|
| `PRODUCT` | `ppclub` | free-form, becomes a Loki label |
| `SERVER_ID` | `ppclub-prod` | unique per host |
| `JOURNAL_MATCHES` | `_SYSTEMD_UNIT=ppclub-backend.service _SYSTEMD_UNIT=caddy.service` | space-sep OR filter, journalctl syntax |
| `LOKI_PUSH_URL` | `https://loki-push.wanbrain.com/loki/api/v1/push` | central endpoint |
| `CF_ACCESS_CLIENT_ID` | `xxx.access` | from 1Password: "SkyEye CF Access Service Token" |
| `CF_ACCESS_CLIENT_SECRET` | *(long random string)* | script will prompt (hidden) if unset |

### 3. Run

```bash
# Edit and paste secrets straight from 1Password; the '  ' prefix skips bash history
# if HISTCONTROL=ignorespace is set. Alternatively, just let the script prompt for the
# two CF Access values.

export PRODUCT=ppclub
export SERVER_ID=ppclub-prod
export JOURNAL_MATCHES='_SYSTEMD_UNIT=ppclub-backend.service _SYSTEMD_UNIT=caddy.service'
export LOKI_PUSH_URL=https://loki-push.wanbrain.com/loki/api/v1/push
export CF_ACCESS_CLIENT_ID='xxx.access'
  export CF_ACCESS_CLIENT_SECRET='<paste from 1Password>'

sudo -E bash agents/alloy/setup.sh

# Clean the secret out of this shell
unset CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET
```

### 4. Verify

On the target host:

```bash
sudo systemctl status alloy                # should be "active (running)"
sudo journalctl -u alloy --since=2m        # look for "Loki write succeeded" / no errors
```

On your laptop / any browser, open `https://grafana.wanbrain.com`:

1. **Explore** → datasource: **Loki**
2. Query: `{product="ppclub"}`
3. Within ~30 seconds you should see log lines from `ppclub-backend.service` and `caddy.service`

### 5. Verify PII scrub

Trigger a payment flow on PPClub (or just let a normal request come in). In Grafana Loki Explore, query:

```
{product="ppclub"} |= "[EMAIL]"
```

You should see lines where `'Email': '<address>'` has been replaced by `'Email': '[REDACTED]'` or similar. If you see a raw email in any log line, add a regex to `config-logs.alloy.tmpl` and re-run setup.sh.

## Troubleshooting

| Symptom | Check |
|---|---|
| `systemctl status alloy` says "failed" | `journalctl -u alloy -n 50` |
| `401 Unauthorized` in alloy log | CF Access Service Token wrong or Access app policy mis-set |
| `403 Forbidden` in alloy log | Service Token policy not attached to the right app (prom-push / loki-push) |
| No logs in central Loki, no errors locally | `journalctl` on host has no matching `_SYSTEMD_UNIT`? Verify `JOURNAL_MATCHES` |
| `getsockopt: connection refused` | DNS for `loki-push.wanbrain.com` not resolving to Cloudflare edge |

## Uninstall

```bash
sudo bash agents/alloy/uninstall.sh
```

Removes package, config, and apt repo. Does NOT remove previously-pushed logs from central Loki (they age out per retention policy, 30 days).

## Phase 2B — node metrics (CPU / RAM / disk / net)

Add the `PROM_PUSH_URL` env var to enable node_exporter collection and push to the central Prometheus. Re-run `setup.sh` — it re-renders the config, appends the metrics section, and restarts alloy.

```bash
cd /home/ubuntu/skyeye-agent
git pull

# Keep existing Phase 2A vars (if session is fresh, re-export them)
export PRODUCT=ppclub
export SERVER_ID=ppclub-prod
export JOURNAL_MATCHES='_SYSTEMD_UNIT=ppclub-backend.service _SYSTEMD_UNIT=caddy.service'
export LOKI_PUSH_URL=https://loki-push.wanbrain.com/loki/api/v1/push

# NEW: Phase 2B — enable metrics push
export PROM_PUSH_URL=https://prom-push.wanbrain.com/api/v1/write

# CF_ACCESS_CLIENT_ID / SECRET prompt as before (same Service Token)
sudo -E bash agents/alloy/setup.sh
```

### Verify

On the host:

```bash
# Alloy should report the remote_write target
sudo journalctl -u alloy --since=1m --no-pager | grep -i 'remote_write\|prometheus'

# Metrics throughput — Alloy 1.x uses prometheus_remote_storage_* (not
# _remote_write_* which was the classic prometheus exporter name).
curl -s http://127.0.0.1:12345/metrics 2>/dev/null \
  | grep -E '^prometheus_remote_storage_samples_total|^prometheus_remote_storage_samples_failed_total|^prometheus_remote_storage_samples_retried_total|^prometheus_remote_storage_highest_timestamp' \
  | head
```

From central Grafana (Explore → Prometheus):

```
up{product="ppclub"}                    # should be 1
node_cpu_seconds_total{product="ppclub"}  # host CPU
node_memory_MemAvailable_bytes{product="ppclub"}
node_filesystem_avail_bytes{product="ppclub", mountpoint="/"}
```

## Phase 2C — app `/metrics` scrape

Once the app exposes `/metrics` on localhost (see [docs/phase-2c-ppclub-changes.md](../../docs/phase-2c-ppclub-changes.md) for the FastAPI side), add:

```bash
export APP_METRICS_TARGET=localhost:8090
sudo -E bash agents/alloy/setup.sh
```

setup.sh appends `config-app.alloy.tmpl` to the config, adding a `prometheus.scrape "app"` block that forwards to the same `prometheus.remote_write.central` used by node metrics.

### Verify

```
up{job="ppclub-backend"}                            # == 1 when scrape succeeds
http_requests_total{product="ppclub"}               # non-empty
```
