# Trading dashboard summary and balance

Combine the strategy detail dashboard's four execution incident counters with
its six monitoring states. Financial cards occupy the first row, followed by one
full-width, three-unit-high status strip. Preserve the 15-minute incident window,
red threshold at one event, and existing unknown/risk-reporting status mappings.
Keep the fleet dashboard unchanged.

P&L composition retains realized P&L, cash P&L and rebate. Remove displayed risk
P&L only; keep its telemetry and alerts.

“目前餘額” uses `equity_now` from the latest manifest-bound stable `pnl_status`
record. The Trading producer sums every executor's account equity and rejects
partial snapshots (`engine/reconcile.go`, `fetchEquitySnapshot`). This already
covers two exchanges or one exchange; Grafana must not sum it again. Expose
`tnauqquant_current_equity_usdt` through inventory-filtered
`trading_strategy_current_equity_usdt`.

The tooltip identifies the value as latest stable total account equity in USDT,
rather than available margin or continuous exchange balance. Missing/invalid
values produce no metric and an explicit waiting state. Zero is valid. Do not
infer a value from P&L or an earlier run. Reuse the existing stable-snapshot
parser; no exchange API polling or credentials are needed.

Use Grafana's Mixed datasource for the merged stat panel. Keep per-query pinned
Prometheus/Loki datasource references. Incident queries return `vector(0)` during
quiet periods; query errors remain errors.

Verify single/paired strategy samples, missing/invalid/zero/unstable equity,
manifest and inventory isolation, panel layout and existing Trading regressions.
No trading process, strategy configuration or alert-routing changes.
