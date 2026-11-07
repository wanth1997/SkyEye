# SkyEye

Self-hosted monitoring stack for wanbrain products. Collects metrics + logs from every product's host via Grafana Alloy + Cloudflare Tunnel, alerts to Telegram, stores cold data in S3. Zero public ports.

**Design doc**: [`monitoring-plan-v2.md`](./monitoring-plan-v2.md)
**Operations**: [`docs/operations.md`](./docs/operations.md)
**New product onboarding**: [`docs/onboarding-new-product.md`](./docs/onboarding-new-product.md)

## Deployed state

```
PPClub EC2 (x86_64)                          monitoring-prod EC2 (arm64)
  alloy → journald → Loki push URL              Loki (S3 chunks)
        → node exporter → Prom push URL   ━━▶   Prometheus (TSDB + rules)
        → /metrics (FastAPI) → same CF edge     Alertmanager → Telegram
        → ppc_* business counters               Grafana (CF Access + Google SSO)
                                                Blackbox (external probes)
  caddy.service                                 cloudflared tunnel
  ppclub-backend.service (uvicorn)
```

### What's observed right now
- **Host layer**: CPU / RAM / disk / network / load (PPClub + monitoring-prod itself)
- **App layer** (PPClub backend): HTTP req rate / 4xx / 5xx / p50-p99 latency per route
- **Business layer** (PPClub): payment created / success / refund / event signup / user signup / phone verify / credit topup / external-API (NewebPay, Hengfu) p99 / scheduler heartbeats / unhandled exceptions
- **Log layer**: PII-scrubbed journald (ppclub-backend + caddy) → central Loki
- **External deps**: blackbox probes on NewebPay, Google OAuth, ppclub.tw, Hengfu (insecure TLS)

### Alert rules active
39 Prometheus rules across 7 files:
- `system.yml` — CPU, RAM, disk, OOM, systemd units
- `app.yml` — BackendDown, 5xx rates, latency p99, unhandled exception surge, payment failure and LinkCourt 401/429 surge shadow alerts
- `business.yml` — PaymentSuccessRateLow, RefundVolumeHigh, ExternalApiDown, ExternalApiSlow, TlsCertExpired, TlsCertExpiringSoon
- `deadman.yml` — SchedulerNoHeartbeat, PrometheusSelfStale, DailyHeartbeat
- `stack-health.yml` — SkyEye components, resource pressure, rule evaluation health
- `trading-targets.yml` / `trading.yml` — production Trading target inventory (edit with `scripts/trading-target add|remove`) and shadow alerts

Severity → routing:
- **High** → 🚨 Telegram (sound) (24/7)
- **Medium** → ⚠️ Telegram (silent) (work hours Asia/Taipei 09:00-21:00)
- **Low** → ℹ️ Telegram (silent, 24h repeat)
- **Shadow** → evaluated and visible, but routed to `shadow-null` with no notification

## Directory map

```
SkyEye/
├── README.md                            this file
├── monitoring-plan-v2.md                design doc (2026-04-22 rewrite)
├── docker-compose.yml                   the stack (6 services)
├── .env.example                         GF_ADMIN_PW — the only env var
│
├── alertmanager/
│   ├── alertmanager.yml                 routes + receivers (High loud / Medium + Low silent / Shadow null)
│   └── secrets/                         tg_token (gitignored, 0644)
│
├── prometheus/
│   ├── prometheus.yml                   remote-write receiver + scrape + blackbox
│   └── rules/                           system / app / business / deadman / stack / trading (39 rules)
│
├── loki/loki-config.yml                 S3 backend, delete API enabled
│
├── blackbox/config.yml                  http_2xx + http_2xx_insecure modules
│
├── grafana/
│   ├── provisioning/                    datasources (pinned UIDs) + dashboard loader
│   └── dashboards/
│       ├── Overview/                    Overview — All products
│       ├── Hosts/                       Hosts — Node exporter (from grafana.com 1860)
│       └── PPClub/                      backend-overview, business
│
├── cloudflared/
│   ├── config.yml                       tunnel ingress (grafana / prom-push / loki-push)
│   ├── credentials.json                 gitignored
│   └── README.md                        tunnel creation SOP
│
├── agents/alloy/                        run on every product host
│   ├── setup.sh                         apt install + render config + restart
│   ├── config-logs.alloy.tmpl           journald → PII scrub → central Loki (Phase 2A)
│   ├── config-metrics.alloy.tmpl        node_exporter → central Prom (Phase 2B)
│   ├── config-app.alloy.tmpl            app /metrics scrape (Phase 2C)
│   └── README.md                        env vars, verify, troubleshoot
│
├── infra/iam/                           one-time AWS bootstrap
│   ├── bootstrap.sh                     IAM role + instance profile + S3 buckets + VPC endpoint
│   ├── trust-policy.json
│   ├── s3-policy.json
│   └── {loki,snapshots}-lifecycle.json
│
├── scripts/
│   ├── bootstrap-monitoring-ec2.sh      Docker + AWS CLI install
│   ├── backup-prometheus.sh             TSDB snapshot → S3 (cron)
│   ├── install-prometheus-backup-cron.sh
│   ├── trading-target                   add/remove/check Trading inventory rows
│   └── central-deploy                   validate → fast-forward → reload on the central host
│
├── runbooks/                            per-alert response guides
│   ├── _template.md
│   ├── backend-down.md
│   ├── high-5xx.md
│   ├── disk-full.md
│   ├── payment-zero.md
│   └── external-api-down.md
│
└── docs/
    ├── operations.md                    day-2 ops: cadence, rotation, recovery
    ├── onboarding-new-product.md        30-min checklist for adding a new service
    ├── grafana-conventions.md           folder taxonomy, naming, UID, tags
    ├── phase-2c-ppclub-changes.md       FastAPI /metrics code patch spec
    ├── phase-2d-ppclub-business-counters.md   business Counter hook points
    └── code-patterns/
        └── python-fastapi.md            Layer 1 (HTTP) + Layer 2 (business) patterns
```

## Daily operation

See [`docs/operations.md`](./docs/operations.md) for the full playbook. Shortest version:

- **Morning habit**: check the Telegram group for the silent `DailyHeartbeat`. If it arrived, the alert pipeline is alive.
- **When paged (Telegram 🚨)**: click the Runbook link in the message.
- **Dashboards**: https://grafana.wanbrain.com → Overview folder (daily), PPClub folder (deep dive), Hosts folder (troubleshoot).

## Change workflow

- Everything is in git. Config changes → edit file → `docker compose up -d --force-recreate <service>` (or `curl -X POST localhost:<port>/-/reload` for Prom/AM live reload). For merged rule/dashboard/Alertmanager changes, `scripts/central-deploy` on the central host validates, fast-forwards, reloads and confirms the load in one step.
- Dashboards: edit JSON in `grafana/dashboards/<folder>/<uid>.json`; Grafana picks up via provisioning within 60 s.
- Alloy agents: on the target host, `git pull` + `sudo -E bash agents/alloy/setup.sh`.

### What `scripts/central-deploy` proves

Before the checkout moves, in a dry run too, it checks the target commit:

- **Dashboards:** every `*.json` must be one JSON object with a `title` and a `uid`, with no uid repeated anywhere and no title repeated in a folder. Grafana silently drops a repeated title, and a repeated uid stops it writing any dashboard. A `title` or `uid` with spaces around it, or a string `refresh` under `5s` or that Grafana cannot parse, is refused too: Grafana rewrites those, so the served copy would never match the file. Write `refresh` as a whole number and one unit (`30s`, `5m`, `1h`), or `""` for none.
- **Loki rules:** the ruler from the pinned `grafana/loki` image loads them in a throwaway container with no network (under a second, about 85 MB). This catches YAML errors, unknown fields, empty files, LogQL syntax errors and duplicate groups. Rule files must sit directly in `loki/rules/fake/`.

The rule check does not catch a valid rule that means the wrong thing: a label typo that never matches, a log query used as an alert (it loads and only fails when evaluated), query limits, or Alertmanager routing and shadow/canary policy. Dashboards are not checked past the fields above; panels, queries and datasources are not.

After a Prometheus reload it reads `prometheus_config_last_reload_successful` and the success timestamp from Prometheus's own `/metrics`: the value must be 1 and the timestamp no older than this run's reload. It does not query them, because the scraped sample can be a whole scrape interval old and still show the failure from before a reload that just succeeded. `--status` reads the same live values.

After the checkout moves, a changed rule or dashboard must be seen loaded before the commit is recorded in `.git/skyeye-central-deploy.applied`:

- **Loki:** the rules the ruler reports at `/prometheus/api/v1/rules` must equal the rules from the throwaway ruler in everything except evaluation state, a group's `limit` included. `loki_ruler_config_last_reload_successful` stays 1 when a file is rejected, so it proves nothing. Loki 3.1.1 accepts `keep_firing_for` but drops it on load, so that field has no effect and is not confirmed.
- **Grafana:** each changed dashboard must be served with the content of its file, from that file, and every uid the file had at the last apply or at HEAD must be gone unless another file now has it. Only changed files are compared, because a UI edit to an unchanged dashboard stays in the database and is not a failure. If an earlier run failed and someone then edits a listed dashboard in the UI, export the edit to Git or undo it.
- **No applied record:** nothing tells a UI edit from a load that never happened, so every rule and every dashboard is compared. A dashboard edited in the UI then blocks the record, and there is no flag to skip it. The message names the uid: export the edit to Git and deploy that, or undo it in Grafana (dashboard settings → Versions), then rerun. This happens once, on the first run that has no record.

If that does not happen within `SKYEYE_ACCEPT_TIMEOUT` seconds (default 150), the run exits 1 with `is published but not loaded`. The checkout stays at the target, nothing is recorded and nothing rolls back, because Prometheus and Alertmanager already run that commit. Loki and Grafana keep serving their previous content. Fix the cause and rerun; the message also prints how to go back.

### One-time setup for `scripts/central-deploy`

A dashboard change needs a Grafana token to read dashboards back, and so does the first run on a checkout with no applied record. Without it the deploy stops before the checkout moves. Create it once:

1. In Grafana, go to Administration → Users and access → Service accounts → Add service account. Name it `central-deploy` and give it the **Viewer** role, which is enough; do not raise it. Then Add service account token and copy the value.
2. On monitoring-prod, store it outside the checkout, mode 0600. Paste the token and press Enter; it is not echoed and stays out of the shell history:

   ```bash
   install -d -m 700 /home/ubuntu/.config/skyeye
   (umask 077 && IFS= read -rs token && printf '%s\n' "$token" >/home/ubuntu/.config/skyeye/grafana-viewer-token)
   ```

3. Confirm it works. This should print one dashboard:

   ```bash
   printf 'header = "Authorization: Bearer %s"\n' "$(cat /home/ubuntu/.config/skyeye/grafana-viewer-token)" |
     curl --config - -fsS 'http://127.0.0.1:3000/api/search?type=dash-db&limit=1'
   ```

`SKYEYE_GRAFANA_TOKEN_FILE` overrides the path. Never commit the token or pass it on a command line. When a token expires, a dry run with a dashboard change fails with a 401; replace the file the same way.

### Changing the Loki image tag

The rule check runs the tag pinned in the target commit and never pulls it (`--pull=never`), so nothing is downloaded onto the host by a deploy. A commit that changes the tag fails closed until the image is on the host, so run `docker pull grafana/loki:<tag>` first. The check needs `/bin/sh`, `wget` and `-target=ruler` in the image; if a new image lacks them, the dry run fails and the check must be updated with the tag.

## Phase history

| Phase | What it added |
|---|---|
| 1 | Central stack up (Prom / Loki / Grafana / AM / cloudflared). Telegram A+C + Gmail SMTP. CF Access SSO. S3 backing store for logs. |
| 2A | Alloy on PPClub — journald + PII scrub → central Loki |
| 2B | Alloy node_exporter → central Prom |
| 2C | FastAPI `/metrics` (instrumentator) → central Prom |
| 2D | Business counters: payment / refund / signup / external API / scheduler / exceptions |
| 2E | Grafana dashboards (Overview / Hosts / PPClub × 2) |
| 3 | Runbooks (5) + blackbox probes + TSDB S3 snapshot cron |

See `git log` for commit-level history. Incidents the system has already caught (and resolved) in its short life:
- **2026-04-23**: Hengfu LE cert expired (their end); 32-min window of expired cert being served; their team fixed after their own monitoring alerted them.
