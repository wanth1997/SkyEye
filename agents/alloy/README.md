# Grafana Alloy agent (SkyEye)

This directory contains the one-shot installer for **Grafana Alloy** — a single agent binary that collects logs and metrics from a host and pushes them to the central SkyEye monitoring stack via Cloudflare Tunnel.

For tnauqquant on macOS, use the dedicated parameterized agent under
`agents/alloy/trading/`. It tails raw log files and runs a read-only launchd
probe; it does not use the Linux journald installer documented below.

## What it does

| Phase | Enabled by | Collected |
|---|---|---|
| **2A** (current) | Always | systemd journal (selected units), PII-scrubbed, → central Loki |
| 2B | `PROM_PUSH_URL` set | node_exporter (CPU/RAM/disk/net) → central Prometheus |
| 2C | `APP_METRICS_TARGET` set | App `/metrics` scrape → central Prometheus |

Phase 2A is log-only — no code changes on the host, low risk.

## Requirements

- Ubuntu / Debian (apt-based)
- systemd (for journald collection)
- Outbound HTTPS to `*.wanbrain.com` (via Cloudflare Tunnel endpoints)
- root / sudo
- `envsubst` (Debian/Ubuntu package `gettext-base`)
- Grafana Alloy v1.9.0 or newer if it is already installed. Older versions have no `alloy validate`, so `setup.sh` stops and asks you to upgrade.

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

## How setup.sh handles failure

`setup.sh` renders into a private file beside the config, runs `alloy validate` on it, and only then renames it over `/etc/alloy/config.alloy`. If Alloy does not come up on the new config, the old one is put back.

| What went wrong | What happens | Exit |
|---|---|---|
| Bad input, or a missing template or `envsubst` | Nothing is written and apt does not run | 2 |
| Not root, config is a symlink, or an earlier run did not finish | Nothing is written | 1 |
| Render or `alloy validate` fails, or Alloy has no `validate` | The live config is not touched and Alloy is not restarted | 1 |
| Restart or health check fails, and Alloy was running | Old config restored, Alloy restarted and checked again | 1 |
| Restart or health check fails, and Alloy was stopped | Old config restored, Alloy stopped again | 1 |
| Restart or health check fails, and there was no old config | New config deleted so no credentials stay on disk, Alloy stopped | 1 |
| The rollback itself fails | A `CRITICAL` message says what to check by hand | 3 |

On a host where apt just installed Alloy, the package's sample config counts as the old config. Alloy is only enabled at boot after a run succeeds.

**What stays on disk.** After a successful run, `/etc/alloy/config.alloy.previous` holds the config that was replaced. To go back to it:

```bash
sudo cp -p /etc/alloy/config.alloy.previous /etc/alloy/config.alloy
sudo systemctl restart alloy
```

The next successful run overwrites this file, and it holds the credentials of the old config. A failed run leaves it alone.

`/etc/alloy/config.alloy.rollback` only exists during a run. If you find one, that run was killed: it holds the config from before that run. Compare it with `config.alloy`, then move it over the config or delete it. `setup.sh` refuses to run until you do.

**What the health check does not cover.** The check confirms that `alloy.service` stays active on one process for 5 seconds. It says nothing about the pipeline. A wrong CF Access Client ID or Secret leaves Alloy active while every push gets a 401, so it does not trigger a rollback and `setup.sh` reports success. Always do the end-to-end check in Grafana after a run.

**Hand edits are not merged.** `setup.sh` re-renders the whole config from the templates, and `APP_METRICS_TARGET` takes one target. Extra scrape targets added by hand are dropped by a re-run, and because that run succeeds, nothing rolls back. Compare the running config with the render before re-running on a host that was edited by hand.

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

If the app protects `/metrics` with a bearer token, export the same token before
running setup:

```bash
export APP_METRICS_BEARER_TOKEN='<paste app metrics token>'
sudo -E bash agents/alloy/setup.sh
unset APP_METRICS_BEARER_TOKEN
```

### Verify

```
up{job="ppclub-backend"}                            # == 1 when scrape succeeds
http_requests_total{product="ppclub"}               # non-empty
```
