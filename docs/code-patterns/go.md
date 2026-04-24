# Go — SkyEye instrumentation pattern

Three layers, in increasing effort. Do Layer 1 first — it's 5 lines and gives you all the Go runtime signals "for free".

1. **Runtime exposition** — `promhttp.Handler()` on `/metrics`. Gives goroutine count, heap size, GC pause, process RSS/CPU/FDs.
2. **HTTP-level** — middleware (if your service has HTTP). Gives request rate / errors / latency per route.
3. **Business-level** — named Counters / Histograms / Gauges at key events (orders placed, signals received, reconnects).

All three export on the same `/metrics` endpoint.

---

## Layer 1 — Runtime exposition (every Go service)

### Install

```bash
go get github.com/prometheus/client_golang/prometheus/promhttp
```

Add to `go.mod`, commit.

### Patch `main.go` (or wherever your service entry-point is)

```go
import (
    "log"
    "net/http"

    "github.com/prometheus/client_golang/prometheus/promhttp"
)

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

func main() {
    // ... existing initialization ...
    startMetricsServer("127.0.0.1:9100")   // bind localhost-only for SkyEye Alloy to scrape
    // ... existing business loop / http.ListenAndServe for your real app ...
}
```

**Why a separate port**:
- No conflict with your real HTTP server (if any)
- `127.0.0.1` bind = only the local Alloy agent can scrape it; external world can't poke it
- Port `9100` is node_exporter's default — safe convention. Pick anything above 1024.

**Why a separate mux**:
- Keeps `/metrics` isolated from your app's routing
- No chance of someone else's middleware (auth, CORS, etc) mangling the metrics response

### Verify on the host

```bash
# Restart your service, then:
curl -s http://127.0.0.1:9100/metrics | head -20
```

You should see lines like `go_goroutines 42`, `go_memstats_alloc_bytes 1.234e+07`, `process_resident_memory_bytes 5.67e+07`, etc.

### Configure SkyEye Alloy to scrape it

```bash
cd /home/ubuntu/skyeye-agent
export APP_METRICS_TARGET=localhost:9100    # new
sudo -E bash agents/alloy/setup.sh
```

### What you immediately get in Grafana

```
up{job="<product>-backend"}                        # 1 = healthy
go_goroutines{product="<product>"}                 # goroutine count
go_memstats_alloc_bytes{product="<product>"}       # current heap
go_gc_duration_seconds{product="<product>"}        # GC pause histogram
process_resident_memory_bytes{product="<product>"} # RSS
process_cpu_seconds_total{product="<product>"}     # CPU usage
process_open_fds{product="<product>"}              # open FDs
```

These alone let you answer:
- Is the bot running? (`up == 1`)
- Is it leaking? (`go_goroutines` / `go_memstats_alloc_bytes` climbing)
- Is GC chewing CPU? (p99 of `go_gc_duration_seconds`)
- Is RSS growing? (`process_resident_memory_bytes` trend)

---

## Layer 2 — HTTP middleware (if your service has incoming HTTP)

For chi / echo / gin / standard `net/http`.

### Chi example

```go
import (
    "github.com/go-chi/chi/v5"
    "github.com/slok/go-http-metrics/metrics/prometheus"
    metricsmw "github.com/slok/go-http-metrics/middleware"
    chimw "github.com/slok/go-http-metrics/middleware/std"
)

func setupRouter() *chi.Mux {
    mdlw := metricsmw.New(metricsmw.Config{
        Recorder: prometheus.NewRecorder(prometheus.Config{}),
    })

    r := chi.NewRouter()
    r.Use(func(next http.Handler) http.Handler {
        return chimw.Handler("", mdlw, next)
    })

    // ... your routes ...
    return r
}
```

Then `http_request_duration_seconds_bucket`, `http_requests_inflight`, `http_response_size_bytes` all show up under `/metrics`.

**Cardinality warning**: `chimw.Handler("", ...)` uses empty group-name. If your app has highly dynamic paths (e.g. `/users/{id}/events/{eventId}`), register each route and pass its *pattern* as `group` name, not the full URL, or you'll blow up cardinality.

---

## Layer 3 — Business counters

Same design as the Python pattern. Declare once, import everywhere.

### `metrics/metrics.go` (new file, single source of truth)

```go
package metrics

import (
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

// ---- Funding-rate bot events ----
var (
    SignalReceived = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "zenincome_signal_received_total",
            Help: "Funding-rate signals received from exchange WebSocket",
        },
        []string{"symbol", "type"},
        // symbol: fUSD|fUST|fBTC|fETH…
        // type:   FRRDELTAFIX|...
    )

    OrderPlaced = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "zenincome_order_placed_total",
            Help: "Orders successfully placed with the exchange",
        },
        []string{"exchange", "symbol", "side"},
    )

    OrderFailed = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "zenincome_order_failed_total",
            Help: "Orders that failed to place (incl. rejected, timeout)",
        },
        []string{"exchange", "symbol", "reason"},
        // reason: rate_limit|ws_down|invalid_signature|api_error|timeout
    )

    WebSocketReconnect = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "zenincome_websocket_reconnect_total",
            Help: "WebSocket reconnect events (per exchange)",
        },
        []string{"exchange"},
    )

    ExchangeAPILatency = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "zenincome_exchange_api_duration_seconds",
            Help:    "Latency of exchange REST API calls",
            Buckets: []float64{0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10},
        },
        []string{"exchange", "endpoint", "result"},
    )
)
```

### Using them at hook points

```go
import "yourmodule/metrics"

// When a funding signal arrives
metrics.SignalReceived.WithLabelValues(symbol, signalType).Inc()

// When placing an order
start := time.Now()
err := exchange.PlaceOrder(order)
metrics.ExchangeAPILatency.
    WithLabelValues("bitfinex", "submit", resultLabel(err)).
    Observe(time.Since(start).Seconds())

if err != nil {
    metrics.OrderFailed.WithLabelValues("bitfinex", symbol, categorize(err)).Inc()
} else {
    metrics.OrderPlaced.WithLabelValues("bitfinex", symbol, side).Inc()
}

// On WebSocket reconnect
metrics.WebSocketReconnect.WithLabelValues("bitfinex").Inc()
```

### Cardinality guard (repeat from Python doc, repeat because it matters)

| Good label | Why | Cardinality |
|---|---|---|
| `symbol` | Fixed set: fUSD, fUST, fBTC… | ~20 |
| `exchange` | Fixed set: bitfinex, bitstamp | ~5 |
| `side` | buy / sell | 2 |
| `result` / `reason` | Fixed enum | < 10 |

| BAD label | Why | Cardinality |
|---|---|---|
| `order_id` | Unbounded (one per order) | millions |
| `client_id` | Unbounded | millions |
| `timestamp` | Continuous | ∞ |
| `ws_message_id` | Unbounded | millions |

---

## Bonus: scheduled-job heartbeat (pattern shared with the Python side)

If the bot has periodic maintenance jobs (reconcile, health check), emit a freshness gauge:

```go
var JobLastRun = promauto.NewGaugeVec(
    prometheus.GaugeOpts{
        Name: "zenincome_scheduled_job_last_run_timestamp",
        Help: "Unix timestamp of last successful run of a scheduled job",
    },
    []string{"job"},
)

// In each job's success path:
metrics.JobLastRun.WithLabelValues("reconcile_open_orders").SetToCurrentTime()
```

Central `SchedulerNoHeartbeat` alert rule (already in `prometheus/rules/deadman.yml`) matches this across products — no new rule needed.

---

## What you do NOT need to do

- **No product label on metrics** — SkyEye's Alloy agent injects `product=<your-slug>` at scrape time. Don't add it yourself (it'll collide).
- **No host / pod / instance label** — Alloy + Prometheus add `instance` automatically.
- **No server-side exporter registration** — Prometheus pulls (via Alloy), you don't push.

---

## Reference

- [prometheus/client_golang](https://github.com/prometheus/client_golang)
- [promauto](https://pkg.go.dev/github.com/prometheus/client_golang/prometheus/promauto) — removes registration boilerplate
- [go-http-metrics](https://github.com/slok/go-http-metrics) — framework-agnostic HTTP middleware
- SkyEye Python parallel: [`python-fastapi.md`](./python-fastapi.md)
