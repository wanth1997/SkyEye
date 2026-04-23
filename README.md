# SkyEye

Self-hosted monitoring stack for wanbrain products. Collects metrics + logs from every product's host via Grafana Alloy + Cloudflare Tunnel, alerts to Telegram + Gmail, stores cold data in S3. Zero public ports.

**Design doc**: [`monitoring-plan-v2.md`](./monitoring-plan-v2.md)
**Operations**: [`docs/operations.md`](./docs/operations.md)
**New product onboarding**: [`docs/onboarding-new-product.md`](./docs/onboarding-new-product.md)

## Deployed state

```
PPClub EC2 (x86_64)                          monitoring-prod EC2 (arm64)
  alloy → journald → Loki push URL              Loki (S3 chunks)
        → node exporter → Prom push URL   ━━▶   Prometheus (TSDB + rules)
        → /metrics (FastAPI) → same CF edge     Alertmanager → Telegram + Gmail
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
18 Prometheus rules across 4 groups:
- `system.yml` — CPU, RAM, disk, OOM, systemd units
- `app.yml` — BackendDown, 5xx rates, latency p99, unhandled exception surge
- `business.yml` — ZeroPaymentHalfDay, RefundSurge, ExternalApiDown, ExternalApiSlow, TlsCertExpired, TlsCertExpiringSoon
- `deadman.yml` — SchedulerNoHeartbeat, PrometheusSelfStale, DailyHeartbeat

Severity → routing:
- **High** → 🚨 Telegram (sound) + Gmail backup (24/7)
- **Medium** → ⚠️ Telegram (silent) (work hours Asia/Taipei 09:00-21:00)
- **Low** → Email daily digest

## Directory map

```
SkyEye/
├── README.md                            this file
├── monitoring-plan-v2.md                design doc (2026-04-22 rewrite)
├── docker-compose.yml                   the stack (5 services)
├── .env.example                         GF_ADMIN_PW — the only env var
│
├── alertmanager/
│   ├── alertmanager.yml                 routes + receivers (High loud / Medium silent / Low digest)
│   └── secrets/                         tg_token, smtp_pass (gitignored, 0644)
│
├── prometheus/
│   ├── prometheus.yml                   remote-write receiver + scrape + blackbox
│   └── rules/                           system / app / business / deadman (18 rules)
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
│   └── install-prometheus-backup-cron.sh
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

- **Morning habit**: check Gmail for the overnight Low digest. If it arrived, the alert pipeline is alive.
- **When paged (Telegram 🚨)**: click the Runbook link in the message.
- **Dashboards**: https://grafana.wanbrain.com → Overview folder (daily), PPClub folder (deep dive), Hosts folder (troubleshoot).

## Change workflow

- Everything is in git. Config changes → edit file → `docker compose up -d --force-recreate <service>` (or `curl -X POST localhost:<port>/-/reload` for Prom/AM live reload).
- Dashboards: edit JSON in `grafana/dashboards/<folder>/<uid>.json`; Grafana picks up via provisioning within 60 s.
- Alloy agents: on the target host, `git pull` + `sudo -E bash agents/alloy/setup.sh`.

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
