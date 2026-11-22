# Onboarding a new product to SkyEye

Target: new service up and visible in central Grafana in **< 30 minutes**.

This assumes the central SkyEye stack (monitoring-prod EC2) is already running and the service team has shell access to their own host.

This page is for Linux hosts. A Windows host uses a different installer, its own Access service token and its own dashboard: follow [`runbooks/windows-host-onboarding.md`](../runbooks/windows-host-onboarding.md).

## Who does what

| Role | Platform | Does |
|---|---|---|
| **SkyEye operator** (you / platform team) | SkyEye repo + Grafana | 1. Add product folder to git. 2. Provide CF Access Service Token. 3. Verify ingestion on the central side. |
| **Service team** (owns the new product's host) | Their EC2 | 1. Install Alloy agent via script. 2. (Optional) add `/metrics` endpoint to their app. 3. Verify locally. |

No Claude agent back-and-forth required after the first product. The SkyEye repo is the playbook.

## Prerequisites

Service team needs to know:
- **Product slug** — e.g., `newsvc`, `enyoung`, `checkout` (all lowercase, kebab-case if needed; becomes the `product` label)
- **Server ID** — unique string per host, e.g., `newsvc-prod`, `newsvc-staging-1`
- **systemd unit name(s)** to collect logs from, e.g., `newsvc-backend.service`
- **CF Access Client ID + Secret** — from 1Password entry `SkyEye CF Access Service Token (skyeye-agent-push)`. Both URLs (`prom-push.wanbrain.com` / `loki-push.wanbrain.com`) already have this token allowed, so you do NOT need to rotate or create a new token per product.
- **App `/metrics` port** (optional, only if backend exposes Prometheus metrics) — e.g., `localhost:9100`

## Step-by-step

### 1. SkyEye side — register the product (5 min, SkyEye operator)

```bash
# In SkyEye repo working copy on your laptop
cd SkyEye
mkdir grafana/dashboards/{ProductName}   # e.g. newsvc — case/title as you want it to appear in Grafana
echo "# Dashboards go here" > grafana/dashboards/{ProductName}/.keep
git add grafana/dashboards/{ProductName}
git commit -m "Register $PRODUCT in SkyEye — create dashboard folder"
git push
```

Done. No Alertmanager / Prometheus / Loki change needed. The `product` label on incoming metrics/logs makes the existing rules (system / app / business) pick them up automatically.

### 2. Service team side — Alloy agent (10 min)

On the target host (not SkyEye):

```bash
cd /home/ubuntu
git clone https://github.com/wanth1997/SkyEye.git skyeye-agent
cd skyeye-agent

# Required env
export PRODUCT=newsvc
export SERVER_ID=newsvc-prod
export JOURNAL_MATCHES='_SYSTEMD_UNIT=newsvc-backend.service'
export LOKI_PUSH_URL=https://loki-push.wanbrain.com/loki/api/v1/push

# Optional: host metrics push (recommended — one extra env var for all of node_exporter)
export PROM_PUSH_URL=https://prom-push.wanbrain.com/api/v1/write

# Optional: app /metrics scrape (only if backend exposes it)
export APP_METRICS_TARGET=localhost:9100

# CF creds — paste from 1Password; script will prompt if unset
#   read -rs CF_ACCESS_CLIENT_SECRET; export CF_ACCESS_CLIENT_SECRET
#   export CF_ACCESS_CLIENT_ID='...'

sudo -E bash agents/alloy/setup.sh
```

Setup script installs Alloy via apt, renders config, starts systemd unit, prints verification hints.

#### Shared host (multiple products on one machine)

If the host runs multiple products (such as Prod02), set `PRODUCT=services` for the host-level `external_labels` and assign each product's own `product` label using `JOURNAL_PRODUCT_MAP` and `APP_METRICS_PRODUCT_MAP`. When switching from the single-product env vars in the same shell, `unset APP_METRICS_TARGET APP_METRICS_BEARER_TOKEN` first. On Prod02, the three `ppclub` targets require Bearer auth via `APP_METRICS_BEARER_TOKEN_PPCLUB` (read with hidden input so the token does not enter shell history):

```bash
# Clear legacy single-product vars when switching from single-product usage
unset APP_METRICS_TARGET APP_METRICS_BEARER_TOKEN

export PRODUCT=services
export SERVER_ID=PROD02
export LOKI_PUSH_URL=https://loki-push.wanbrain.com/loki/api/v1/push
export PROM_PUSH_URL=https://prom-push.wanbrain.com/api/v1/write
export JOURNAL_PRODUCT_MAP='ppclub-backend.service|caddy.service=ppclub;enyoung-menu.service=enyoung;zenincome-api.service|zenincome-web.service=zenincome'
export APP_METRICS_PRODUCT_MAP='localhost:8090|localhost:8091@linkcourt-scheduler|localhost:8092=ppclub;127.0.0.1:2112=zenincome'

# Required for Prod02 ppclub targets (hidden input, sent only to ppclub targets)
read -rsp 'ppclub metrics bearer token: ' APP_METRICS_BEARER_TOKEN_PPCLUB; echo
export APP_METRICS_BEARER_TOKEN_PPCLUB

# Optional dry-run preview + validation before applying (refuses /etc/alloy):
#   bash agents/alloy/setup.sh --render-only /tmp/preview.alloy && alloy validate /tmp/preview.alloy
sudo -E bash agents/alloy/setup.sh

unset APP_METRICS_BEARER_TOKEN_PPCLUB
```

See [Shared hosts in `agents/alloy/README.md`](../agents/alloy/README.md#shared-hosts-multiple-products-on-one-machine) for the full map syntax and verification queries.

### 3. (Optional) Instrument backend code — 10 min

If the backend language is in [`docs/code-patterns/`](./code-patterns/), follow that template. Otherwise skip — logs + host metrics alone already give you a useful monitoring baseline.

Currently documented:
- **FastAPI / Python** — [`docs/code-patterns/python-fastapi.md`](./code-patterns/python-fastapi.md)

### 4. Central verification (5 min, SkyEye operator)

In Grafana Explore (single-product host):

```
Prometheus:   up{product="$PRODUCT"}                        # should be 1
              node_memory_MemAvailable_bytes{product="$PRODUCT"}

Loki:         {product="$PRODUCT"}                          # should stream lines
```

For a shared host (e.g. Prod02 with `PRODUCT=services`, `SERVER_ID=PROD02`), filter app metrics by `server_id` and query Loki by `server_id` (not `{product="services"}`, since each journal source sets its own product label):

```
Prometheus (host):  node_memory_MemAvailable_bytes{product="services", server_id="PROD02"}
Prometheus (app):   up{product="ppclub", job="ppclub-backend", server_id="PROD02"}       # 3 targets, each == 1
                    up{product="zenincome", job="zenincome-backend", server_id="PROD02"} # 1 target, == 1

Loki:               {server_id="PROD02"}                                                 # all host logs
                    {product="ppclub", server_id="PROD02"}                               # per-product logs
```

Open the Hosts dashboard, switch Product variable to the new product (or `services` for a shared host) — host panels populate within 30 s.

## Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `401 Unauthorized` in alloy log | Wrong CF Access Client ID / Secret | Re-export from 1Password; `sudo -E bash setup.sh` (not plain sudo — `-E` preserves env) |
| `403 Forbidden` | Service Token exists but the Access App didn't accept it | In CF Zero Trust → Access → Applications, ensure `prom-push` and `loki-push` apps have policy `Service Token = skyeye-agent-push` |
| Logs push but metrics don't | `PROM_PUSH_URL` unset (script runs in log-only mode) | Export the var + re-run setup |
| `up{product="X"}` returns nothing but node metrics there | Log-only mode, metrics weren't enabled | As above |
| Alerts fire with wrong `product` label | Alloy `external_labels` or per-target labels not matching spec | Single-product host: verify `prometheus.remote_write.central` has `product = "$PRODUCT"` and `loki.source.journal` has `product = "$PRODUCT"`. Shared host: verify `PRODUCT=services` with `JOURNAL_PRODUCT_MAP` and `APP_METRICS_PRODUCT_MAP` setting per-product labels. |

## What you DON'T need to do per product

- No new Alertmanager receivers — High/Medium/Low receivers handle everything, dedup by `product` label
- No new Prometheus rule groups — rules in `system.yml` / `app.yml` / `business.yml` key off labels (`product`, `job=~".*-backend"`)
- No new Cloudflare tunnels — one tunnel (`skyeye-monitoring-prod`) fronts the entire stack
- No new Loki tenant — `auth_enabled: false`, single `fake` tenant; `product` label partitions logs
- No new Service Token — same `skyeye-agent-push` works for every product

## Reference

- Full design: [monitoring-plan-v2.md](../monitoring-plan-v2.md)
- Grafana conventions: [grafana-conventions.md](./grafana-conventions.md)
- Agent setup detail: [agents/alloy/README.md](../agents/alloy/README.md)
