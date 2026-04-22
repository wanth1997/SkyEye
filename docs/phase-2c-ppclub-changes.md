# Phase 2C — PPClub backend `/metrics` endpoint

Add a Prometheus `/metrics` endpoint to the PPClub FastAPI backend and let the Alloy agent scrape it.

## Why

Alloy on PPClub EC2 already pushes:
- **journald** → central Loki  (Phase 2A)
- **node_exporter** → central Prometheus  (Phase 2B)

Adding `/metrics` on the backend lets us see HTTP-level signals:
- `http_requests_total{method, handler, status}` — request rate, 4xx/5xx breakdown
- `http_request_duration_seconds_bucket{...}` — p50/p95/p99 latency
- `process_resident_memory_bytes`, `process_cpu_seconds_total` — app-level resource use

Once live, Prometheus rules we already committed (`prometheus/rules/app.yml`) start evaluating: `BackendDown`, `High5xxRate`, `Critical5xxRate`, `LatencyP99High`, `UnhandledException`.

## Risk profile

- **Additive**: adds one middleware + one HTTP route to FastAPI
- **Downtime**: 3-5 sec (systemctl restart of `ppclub-backend.service`)
- **Reversible**: remove the 4 lines, uninstall pip package, restart
- **Library**: `prometheus-fastapi-instrumentator` — widely used, MIT-licensed, sub-1k LOC

## Step 1: Install the Python package

On PPClub EC2, inside the backend venv:

```bash
cd /home/ubuntu/PPClub/backend
source .venv/bin/activate

pip install 'prometheus-fastapi-instrumentator>=6.1.0,<7.0'
pip freeze | grep -i prometheus  # sanity
```

Pin the version to `>=6.1,<7` — major-version bumps may change defaults.

Update `requirements.txt` (or equivalent lock file):

```
prometheus-fastapi-instrumentator>=6.1.0,<7.0
```

Commit to PPClub repo on whatever branch you use for backend deployments.

## Step 2: Edit `app/main.py`

Find the FastAPI app construction — a line that looks like:

```python
app = FastAPI(
    title="...",
    ...
)
```

Immediately after that line (and **before** any `app.include_router(...)` or `app.add_middleware(...)` calls), insert:

```python
from prometheus_fastapi_instrumentator import Instrumentator

Instrumentator(
    excluded_handlers=["/metrics", "/api/health"],
    should_group_status_codes=False,   # keep 200/201/401/404 separate
    should_ignore_untemplated=True,     # avoid cardinality blow-up on /events/{slug}
).instrument(app).expose(app, include_in_schema=False)
```

**Why each flag**:
- `excluded_handlers`: don't record metrics about `/metrics` itself or health probes (feedback loop / noise)
- `should_group_status_codes=False`: 200 vs 201 vs 401 vs 404 are different meaningful signals, not "2xx"
- `should_ignore_untemplated=True`: paths like `/events/abc-123` all collapse to the route template `/events/{id}` — otherwise cardinality explodes

Location matters: **before** `include_router` ensures the middleware wraps all routes.

## Step 3: Dry-run locally (optional but recommended)

Before restarting the running service:

```bash
cd /home/ubuntu/PPClub/backend
.venv/bin/python -c "from app.main import app; print('import OK')"
# Should print: import OK
```

Start on a different port and curl it:

```bash
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8091 &
sleep 2
curl -s http://127.0.0.1:8091/metrics | head -20
# Should print Prometheus exposition format: # HELP, # TYPE, metric lines

# Kill the dry-run instance
kill %1
```

If `/metrics` returns Prometheus format, the code change is wired correctly.

## Step 4: Restart the production backend

```bash
sudo systemctl restart ppclub-backend.service

# Wait a couple seconds for uvicorn to be ready
sleep 3

# Verify
curl -s http://127.0.0.1:8090/metrics | head -5
curl -s http://127.0.0.1:8090/api/health   # should still work as before
```

Caddy will retry in-flight requests during the ~3 sec window. Expected user impact: zero.

## Step 5: Tell Alloy to scrape it

Back on the repo, re-run setup.sh with one new env var:

```bash
cd /home/ubuntu/skyeye-agent
git pull   # get Phase 2C agent template changes

# Keep existing Phase 2A/2B vars
export PRODUCT=ppclub
export SERVER_ID=ppclub-prod
export JOURNAL_MATCHES='_SYSTEMD_UNIT=ppclub-backend.service _SYSTEMD_UNIT=caddy.service'
export LOKI_PUSH_URL=https://loki-push.wanbrain.com/loki/api/v1/push
export PROM_PUSH_URL=https://prom-push.wanbrain.com/api/v1/write

# NEW for Phase 2C
export APP_METRICS_TARGET=localhost:8090

# CF_ACCESS creds via prompt (same Service Token)
sudo -E bash agents/alloy/setup.sh
```

setup.sh will now print `==> APP_METRICS_TARGET set ... — appending app scrape section` and restart alloy with the new config.

## Step 6: Verify

On the host:

```bash
# Alloy scraping the new target
curl -s http://127.0.0.1:12345/metrics 2>/dev/null \
  | grep -E '^prometheus_target_scrape_.*ppclub-backend|^up{.*ppclub-backend' \
  | head
```

From central Grafana (Explore → Prometheus):

```
up{job="ppclub-backend"}                           # == 1
http_requests_total{product="ppclub"}              # per-route rate
rate(http_requests_total{product="ppclub"}[5m])    # request rate
histogram_quantile(0.95,
  sum by (le, handler) (
    rate(http_request_duration_seconds_bucket{product="ppclub"}[5m])
  )
)                                                  # p95 latency per route
```

Prometheus alert rules (`prometheus/rules/app.yml`) now have data to evaluate — `BackendDown` and `High5xxRate` will go from "pending" to evaluable.

## Rollback

```bash
# On PPClub EC2
cd /home/ubuntu/PPClub/backend

# Option A: git revert the main.py change, uninstall, restart
git revert <the-commit>
source .venv/bin/activate && pip uninstall -y prometheus-fastapi-instrumentator
sudo systemctl restart ppclub-backend

# Option B (agent-only disable, keep code): drop APP_METRICS_TARGET from setup
unset APP_METRICS_TARGET
sudo -E bash /home/ubuntu/skyeye-agent/agents/alloy/setup.sh
# Alloy stops scraping. /metrics on backend still serves but nobody reads it.
```

Option B is zero-downtime and lets you toggle scraping without touching the backend.
