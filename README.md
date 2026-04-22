# SkyEye

Self-hosted monitoring stack for wanbrain products (PPClub, enyoung, …).

Central machine (this repo) collects metrics + logs pushed from every product's Grafana Alloy agent via Cloudflare Tunnel. Alerts go to Telegram + Gmail. See [`monitoring-plan-v2.md`](./monitoring-plan-v2.md) for the full design rationale.

## Stack

| Component | Image | Role |
|---|---|---|
| Prometheus | `prom/prometheus:v2.54.1` | TSDB + alert rule engine |
| Alertmanager | `prom/alertmanager:v0.27.0` | Alert routing → Telegram + Email |
| Loki | `grafana/loki:3.1.1` | Log index + chunks → S3 |
| Grafana | `grafana/grafana:11.2.0` | Dashboards + Explore UI |
| cloudflared | `cloudflare/cloudflared:2024.10.0` | Zero-trust ingress (no public ports) |

All services bind only to `127.0.0.1` — the public surface is Cloudflare Tunnel.

## Layout

```
SkyEye/
├── docker-compose.yml            # stack definition
├── .env.example                  # → copy to .env
├── alertmanager/
│   ├── alertmanager.yml          # routes + receivers (Telegram A+C scheme, email)
│   └── secrets/                  # tg_token, smtp_pass (gitignored)
├── prometheus/
│   ├── prometheus.yml            # scrape + remote_write receiver
│   └── rules/                    # system / app / business / deadman
├── loki/
│   └── loki-config.yml           # S3 backend, 30-day retention
├── grafana/
│   ├── provisioning/             # datasources + dashboard loader
│   └── dashboards/               # dashboard JSON (filled in Phase 2/3)
├── cloudflared/
│   ├── config.yml                # ingress rules
│   ├── credentials.json          # tunnel secret (gitignored)
│   └── README.md                 # tunnel creation SOP
├── infra/iam/
│   ├── bootstrap.sh              # one-time AWS setup (IAM + S3 + VPC endpoint)
│   ├── trust-policy.json
│   ├── s3-policy.json
│   ├── loki-lifecycle.json
│   └── snapshots-lifecycle.json
├── scripts/
│   └── bootstrap-monitoring-ec2.sh  # install docker + aws cli on the host
├── runbooks/                     # incident response (Phase 3)
└── docs/
```

## Getting started (Phase 1A)

Prerequisites: Phase 0 of [monitoring-plan-v2.md §5](./monitoring-plan-v2.md) done — Telegram bot, Gmail SMTP App Password, Cloudflare tunnel token, Access service token.

### 1. AWS infrastructure (from a machine with AWS credentials)

```bash
cd infra/iam
./bootstrap.sh
```

This creates:
- IAM role `monitoring-prod-role` + instance profile
- S3 buckets `skyeye-loki-chunks`, `skyeye-prometheus-snapshots` (encrypted, lifecycle, PAB)
- VPC S3 Gateway Endpoint
- Attaches the instance profile to EC2 `i-0ae4722dc931e26a1`

### 2. Host setup (on the monitoring-prod EC2)

```bash
cd /home/ubuntu/SkyEye
bash scripts/bootstrap-monitoring-ec2.sh
# log out + back in to pick up docker group
```

### 3. Secrets

```bash
# .env (only one variable needed — docker-compose reads this automatically)
cp .env.example .env
openssl rand -base64 32 | tr -d '+/=' | head -c 32 > /tmp/pw
echo "GF_ADMIN_PW=$(cat /tmp/pw)" > .env && rm /tmp/pw

# Alertmanager secret files (see alertmanager/secrets/README.md)
#   alertmanager/secrets/tg_token     # Telegram bot token
#   alertmanager/secrets/smtp_pass    # Gmail app password
```

### 4. Cloudflare tunnel

See [`cloudflared/README.md`](./cloudflared/README.md). Output: `cloudflared/credentials.json` (gitignored).

### 5. Start

```bash
docker compose up -d
docker compose ps        # all 5 services should be "running"
docker compose logs -f alertmanager
```

## Verification checklist (Phase 1 exit)

- [ ] `aws s3 ls` from the EC2 works without access keys (IAM role in effect)
- [ ] `curl https://grafana.wanbrain.com` → redirected to Cloudflare Access login
- [ ] After Google SSO → Grafana main page loads without showing Grafana's own login form
- [ ] `docker compose exec prometheus wget -qO- http://alertmanager:9093/-/ready` → `OK`
- [ ] Test alert lands in Telegram within 10s (P1 audible, P2 silent):
  ```bash
  curl -s -H 'Content-Type: application/json' -d '[{
    "labels":{"alertname":"TestP1","severity":"P1","product":"test"},
    "annotations":{"summary":"manual test"}
  }]' http://127.0.0.1:9093/api/v2/alerts
  ```
- [ ] S3 has `index_*` objects after Loki ingests its first log line
- [ ] Daily heartbeat email arrives next morning (proves Gmail SMTP path)

## Day-to-day

- **Reload rules without restart**: `curl -X POST http://127.0.0.1:9090/-/reload`
- **Validate rule syntax**: `docker run --rm -v $PWD/prometheus:/p prom/prometheus:v2.54.1 promtool check rules /p/rules/*.yml`
- **Check pending alerts**: `curl -s http://127.0.0.1:9093/api/v2/alerts | jq`
- **Export a dashboard**: UI → Share → Export → Save JSON → commit to `grafana/dashboards/`

## See also

- [monitoring-plan-v2.md](./monitoring-plan-v2.md) — full design doc
- [cloudflared/README.md](./cloudflared/README.md) — tunnel setup
- [alertmanager/secrets/README.md](./alertmanager/secrets/README.md) — secret file handling
