# ZenIncome — Layer 1 `/metrics` patch

Drop-in expansion so the funding-rate bot exposes Go runtime metrics to
SkyEye's Alloy agent. ~5 lines of code. No business logic change.

## Scope

- **Target service**: `zenincome-api.service` (the main bot; not the web one)
- **Listen on**: `127.0.0.1:2112` (localhost only — Alloy scrapes via loopback). Port 2112 is the `prometheus/client_golang` canonical default; avoids collision with node_exporter's 9100 on hosts that might later host a full node_exporter process.
- **Exposed**: Go runtime (`go_*`) + process (`process_*`) metrics
- **Phase 2B upgrade**: Layer 2 (HTTP middleware) and Layer 3 (business
  counters) come later in separate patches — see
  [`docs/code-patterns/go.md`](./code-patterns/go.md) for the full pattern

## Risk

- Downtime during `systemctl restart zenincome-api.service`: the brief
  gap (< 2 s) where the bot isn't running. Not urgent, but pick a moment
  when you're OK with a sub-second gap in the WebSocket loop.
- Port 2112 must be free on the target host. Check: `sudo ss -tlnp | grep :2112`
- Firewall / SG: bind `127.0.0.1:2112` means NO external access — Alloy
  on the same host scrapes via loopback. No AWS SG / iptables change needed.

## Step 1: add the dependency

```bash
# On trading01, in the ZenIncome repo working copy
cd /home/ubuntu/go/src/ZenIncome       # or wherever the repo is

go get github.com/prometheus/client_golang/prometheus/promhttp
go mod tidy
```

This will add `github.com/prometheus/client_golang` to `go.mod` / `go.sum`.

## Step 2: patch `main.go` (or the file where `main()` lives)

Add these imports alongside existing ones:

```go
import (
    // ... existing ...
    "net/http"

    "github.com/prometheus/client_golang/prometheus/promhttp"
)
```

Add this helper function (anywhere in the same file, top of file is fine):

```go
// startMetricsServer exposes /metrics on the given addr for SkyEye Alloy
// agent to scrape. Bind to 127.0.0.1 only — external world must not reach it.
func startMetricsServer(addr string) {
    mux := http.NewServeMux()
    mux.Handle("/metrics", promhttp.Handler())

    go func() {
        log.Printf("metrics server listening on %s", addr)
        if err := http.ListenAndServe(addr, mux); err != nil {
            log.Printf("metrics server exited: %v", err)
        }
    }()
}
```

In `main()`, **before** the main business loop / blocking call, add:

```go
func main() {
    // ... existing initialization (config load, connection, etc) ...

    startMetricsServer("127.0.0.1:2112")   // ← NEW

    // ... existing business loop (blocking) ...
}
```

Placement: start it AFTER logging / config is ready (so the goroutine's log.Printf works), BEFORE the main blocking loop (so it actually gets called).

## Step 3: build + restart

```bash
cd /home/ubuntu/go/src/ZenIncome

# Use absolute go path — /usr/local/go/bin/go isn't on ubuntu user's PATH by default
# cmd/server/main.go is the entry point that systemd runs (bin/server).
# The service is named zenincome-api.service for historical reasons; binary
# is bin/server. Don't try to reconcile — it's fine.
/usr/local/go/bin/go build -o bin/server ./cmd/server

sudo systemctl restart zenincome-api.service
sleep 2
systemctl is-active zenincome-api.service
```

## Step 4: verify `/metrics` responds locally

```bash
curl -sf http://127.0.0.1:2112/metrics | head -20
# Expect lines like:
# # HELP go_gc_duration_seconds A summary of the pause duration ...
# # TYPE go_gc_duration_seconds summary
# go_goroutines 42
# process_resident_memory_bytes 5.67e+07
```

If you see Prom exposition format (lines starting with `# HELP` and metric name=value pairs), you're done on the bot side.

If curl fails (connection refused): the `startMetricsServer()` call didn't execute. Check `journalctl -u zenincome-api --since=1m | grep metrics` — you should see `metrics server listening on 127.0.0.1:2112`.

If curl returns the bot's business HTML/JSON instead: your app's main router caught `/metrics` before the metrics mux could. Either move the `startMetricsServer()` call up in main(), or use a distinct port.

## Step 5: tell SkyEye Alloy to scrape it

```bash
cd /home/ubuntu/skyeye-agent
git pull    # stays on master — no template change needed; existing APP_METRICS_TARGET support just works

# Keep everything from Phase 2A/2B
export PRODUCT=zenincome
export SERVER_ID=trading01
export JOURNAL_MATCHES='_SYSTEMD_UNIT=zenincome-api.service _SYSTEMD_UNIT=zenincome-web.service'
export LOKI_PUSH_URL=https://loki-push.wanbrain.com/loki/api/v1/push
export PROM_PUSH_URL=https://prom-push.wanbrain.com/api/v1/write

# NEW — add this one line
export APP_METRICS_TARGET=localhost:2112

# CF creds unchanged

sudo -E bash agents/alloy/setup.sh
```

setup.sh will print `==> APP_METRICS_TARGET set (localhost:2112) — appending app scrape section`.

## Step 6: verify central Prometheus picked it up

From Grafana Explore (Prometheus datasource):

```
up{product="zenincome", job="zenincome-backend"}              # == 1
go_goroutines{product="zenincome"}
go_memstats_alloc_bytes{product="zenincome"}
process_resident_memory_bytes{product="zenincome"}
rate(process_cpu_seconds_total{product="zenincome"}[5m])
```

All should have data within ~30 seconds of setup.sh completing.

## Rollback

### Option A: disable scrape, keep code
```bash
unset APP_METRICS_TARGET
sudo -E bash /home/ubuntu/skyeye-agent/agents/alloy/setup.sh
# /metrics still served by the bot; Alloy just stops scraping it
```

### Option B: revert code
```bash
cd /home/ubuntu/go/src/ZenIncome
git revert HEAD     # or git checkout the specific commit
go build ...
sudo systemctl restart zenincome-api.service
```

## Follow-ups after Layer 1 lands

Covered in [`docs/code-patterns/go.md`](./code-patterns/go.md):

- Layer 2: HTTP middleware for `http_request_*` series (if zenincome-api has inbound HTTP)
- Layer 3: Business counters — `zenincome_signal_received_total`,
  `zenincome_order_placed_total`, `zenincome_websocket_reconnect_total`, etc.
  These are what actually answer "is the bot making money efficiently".

Layer 1 alone gives you "is the bot healthy / alive / leaking?". Layer 3 gives you "is the bot doing its job?". Worth the ladder.
