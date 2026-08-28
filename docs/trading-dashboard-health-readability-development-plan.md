# Trading Dashboard Health and Readability Development Plan

> **Task ID:** `skyeye-trading-dashboard-health-readability-20260828`
>
> **Status:** Final after owner resolution of plan-review round 2
>
> **Base:** `04cc9261f76c06a2c2cbd7c7cf5a08692be26bab`

## Goal

Make Trading monitoring safer to interpret and faster to scan without changing
trading behavior. PnL becomes the primary visual hierarchy. Process, run binding,
risk-stop, probe freshness, and history freshness move into compact Chinese health
summaries that remain explicit when abnormal. The same delivery closes the confirmed
stale-textfile alert gap and removes synthetic pre-coverage zeroes from accumulated
PnL history.

## User-facing design

Use a restrained dark operations-console hierarchy that works with Grafana's native
theme and panels:

1. PnL trend and current PnL numbers are the first reading layer.
2. Normal monitoring signals occupy one compact summary panel instead of several
   equal-size cards.
3. Every status uses Chinese text as well as color; red and yellow remain reserved
   for actionable states.
4. Technical terms remain available in Chinese descriptions, but panel titles use
   operator language such as `資料綁定`, `風控狀態`, and `資料更新`.
5. PnL uses a visible `USDT` suffix. USD remains only on actual USD volume metrics.

### `Trading · 即時營運`

- Keep UID `tnauqquant-trading-overview` and the authoritative 30-day accumulated
  PnL chart.
- Expand the accumulated chart to 18 columns and place two compact panels at right:
  `損益摘要` and `監控摘要`.
- `損益摘要` shows accumulated PnL, current-run PnL, and latest-cycle PnL.
- `監控摘要` shows exact process state, data binding, risk state, probe freshness,
  and history freshness. Exact process count must distinguish stopped, one running,
  and duplicate processes. A Grafana range mapping covers every count from 2 upward
  as `重複程序`, not only the value 2.
- Each health field has a `byName` override with its own `noValue`. Missing process,
  binding, risk, probe, or history data renders `未知` / `無資料`; it must never
  inherit a zero that maps to a confident stopped or healthy state.
- Keep positions, volume, coverage, and five recent scrubbed log lines below the PnL
  layer. Limit the log panel to the most recent six hours even when the dashboard
  range is 30 days.
- Add stable links to the Fleet and the fixed strategy's Detail dashboard.

### `Trading · 策略詳情`

- Keep UID and `server_id` / `strategy` variable contract; give the variables
  Chinese display labels.
- Put current-run PnL, latest completed-cycle PnL/time, and completed-cycle count in
  the top row.
- Replace the four large PROCESS/BINDING/RISK/TELEMETRY cards with one compact
  `監控摘要` stat panel. Per-field overrides preserve distinct unknown states when
  any source series is absent.
- Keep the current-run cycle chart prominent, with positions and PnL components as
  secondary diagnostics.
- Translate visible panel titles, mappings, no-data copy, and descriptions to
  Traditional Chinese while preserving metric names and datasource UIDs.
- Use `suffix: USDT` for PnL values and retain `currencyUSD` for run volume.
- Limit scrubbed logs to the selected day and keep the existing Fleet back-link.

### `Trading · 策略總覽`

- Keep UID and one-row-per-strategy semantics; never sum current-run PnL across
  strategies.
- Replace four large top cards with one three-row-high `監控摘要` containing:
  monitored strategy count, stale/missing data count, process mismatch count, and
  pending-or-firing shadow alert count.
- Derive stale/missing data from the inventory, not by subtracting or inverting
  visible probe series:

  ```promql
  count(
    trading_target_info{product="tnauqquant",environment="production"}
    unless on (product, environment, server_id, strategy)
    (time() - trading_strategy_probe_timestamp_seconds < 180)
  ) or vector(0)
  ```

  The alert and dashboard share the same 180-second freshness threshold, pinned by
  the central contract test. The dashboard reads the generic recording metric while
  the alert deliberately reads the raw probe metric so a recording-rule evaluation
  failure cannot create a false fleet-wide telemetry alert.
- Proposed healthy steady-state contract requiring owner approval:
  `監控策略=2` is neutral; `資料過期=0`, `程序異常=0`, and
  `Shadow 告警=0` are green. Every nonzero value is abnormal.
- Add an `告警` column to the strategy table using active pending-or-firing alert
  count by strategy. This keeps the compact total actionable by identifying which
  strategy owns a nonzero count.
- Move the operations table immediately below the compact summary. Put Strategy,
  Server, current-run PnL, latest-cycle PnL, cycles, and volume before diagnostic
  status columns.
- Use exact process count and Chinese text mappings so duplicate processes are not
  flattened into `RUNNING`.
- Keep row drill-down with both server and strategy URL variables.

All three dashboard JSON files use `editable: false` because Git provisioning is the
durable source. The fixed overview already has this setting; Detail and Fleet change.
The documented workflow becomes: edit a temporary copy in Grafana, export its JSON,
apply the reviewed change to the provisioned Git file, and delete the temporary copy.

## Monitoring correctness

### Frozen probe timestamp

`TradingTelemetryMissing` currently detects only a missing series. A stopped probe
can leave an old textfile that Alloy continues to scrape, so the series remains while
its timestamp freezes. Change the rule to select inventory targets `unless` their
current probe timestamp is fresh within 180 seconds. This must detect both absent
series and continuously scraped constant timestamps. The Fleet summary uses the same
inventory-based expression and threshold.

Add promtool cases for:

- a timestamp that advances every scrape and remains quiet;
- a timestamp value that stays constant while samples continue and alerts;
- a completely absent target that alerts independently.

### PnL history health

Add `history_capable="true"` only to the `tnauqquant-prod-1`
`trading_target_info` inventory record; do not mirror it to the legacy
`tnauqquant_target_info` record. Trading01 omits the label until it implements the
same history contract. Add `TradingPnlHistoryUnavailable` as a `Medium`, shadow-only
alert using this absent-safe expression:

```promql
trading_target_info{history_capable="true"}
unless on (product, environment, server_id, strategy)
(
  (time() - tnauqquant_pnl_history_build_timestamp_seconds < 180)
  and on (product, environment, server_id, strategy)
  (tnauqquant_pnl_history_valid == 1)
)
```

Do not hard-code a server or strategy in the generic rule.

Add a dedicated `#pnl-history-unavailable` runbook anchor and point the new alert's
`runbook_url` to it. Add promtool cases for healthy, frozen, invalid, and absent
history telemetry.

Do not change the existing `TradingPnlTelemetryStale` threshold in this delivery.
The current first-sample SLA is not documented per strategy; changing a High alert
timer without that contract would trade one false interpretation for another.

## Accumulated PnL coverage semantics

The builder currently emits a zero baseline at the start of the rolling window even
when the first authoritative event is later. That visually claims flat PnL during a
period with no supported data.

Change bounded point construction so:

- a rolling-window baseline is emitted only when authoritative events exist before
  the window;
- completed-day close points begin only after at least one supported event has been
  accumulated;
- current-day events remain individual step-after points;
- history with no authoritative event still emits validity metadata and no fake
  point.

After fake zeroes are removed,
`tnauqquant_pnl_history_first_supported_event_timestamp_seconds` is the explicit
coverage anchor. The separate `資料涵蓋範圍` panel must remain visible and must not be
folded into `監控摘要`.

Also emit `tnauqquant_pnl_history_current_value_usdt` when history is valid. It is a
single bounded gauge for the compact PnL summary and does not add event labels.

Extend builder tests to prove that coverage before the first event remains absent,
the latest scalar equals the final bounded point, cross-day carry is unchanged, and
empty history does not emit the scalar.

## Files

### Modify

- `agents/alloy/trading/pnl-history.sh`
- `tests/trading/test-pnl-history.sh`
- `prometheus/rules/trading.yml`
- `prometheus/rules/trading-targets.yml`
- `prometheus/rules/tests/trading.test.yml`
- `runbooks/trading-telemetry-missing.md`
- `grafana/dashboards/Trading/tnauqquant-trading-overview.json`
- `grafana/dashboards/Trading/trading-strategy-detail.json`
- `grafana/dashboards/Trading/trading-strategy-fleet.json`
- `tests/trading/test-central-config.sh`
- `docs/grafana-conventions.md`
- `docs/trading-monitoring-development-plan.md`
- `docs/project-brief.md`
- `docs/work-log.md`

## Ordered implementation

1. Add failing builder, promtool, and dashboard contract tests for the approved
   semantics and capture RED results.
2. Fix bounded history points and emit the latest accumulated scalar.
3. Fix probe freshness alerting and add the shadow-only history-health alert plus
   runbook guidance.
4. Rebuild the three provisioned dashboards with the PnL-first Chinese hierarchy,
   compact health summaries, exact process counts, correct units, links, and bounded
   log ranges.
5. Update dashboard conventions, monitoring design, project brief, and newest-first
   work log.
6. Run fresh full relevant verification, inspect the diff, commit explicit files,
   fetch and rebase onto the latest `origin/master`, then rerun verification if the
   base changes.
7. Send the immutable commit range to the resolved read-only Herdr reviewer. Triage,
   fix, verify, and commit accepted findings; request delta review for behavioral
   corrections.

## Verification

```bash
bash tests/trading/test-pnl-history.sh
bash tests/trading/test-probe.sh
bash tests/trading/test-log-pipeline.sh
bash tests/trading/test-linux-setup.sh
bash tests/trading/test-central-config.sh
bash -n agents/alloy/trading/pnl-history.sh agents/alloy/trading/probe.sh
plutil -lint agents/alloy/trading/com.wanbrain.skyeye-trading-pnl-history.plist.tmpl
find grafana/dashboards -name '*.json' -exec jq empty {} +
docker compose config --quiet
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" \
  --entrypoint promtool prom/prometheus:v2.54.1 \
  check config /etc/prometheus/prometheus.yml
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" \
  --entrypoint promtool prom/prometheus:v2.54.1 \
  test rules /etc/prometheus/rules/tests/trading.test.yml
docker run --rm -v "$PWD/alertmanager:/etc/alertmanager:ro" \
  --entrypoint amtool prom/alertmanager:v0.27.0 \
  check-config /etc/alertmanager/alertmanager.yml
```

Local Docker is currently unavailable. Static checks remain mandatory; container
validation may run against an isolated temporary copy on the central Docker host.
No authenticated browser is available, so JSON structure, provisioned Grafana 11.2
compatibility contracts, and post-deployment visual canary remain separate evidence.

## Risks and rollback

- PromQL inventory matching must retain all four identity labels and remain generic
  across both production targets.
- Grafana transformations are sensitive to field names; tests must pin the PnL
  value/timestamp join, table join key, status mappings, and datasource UIDs.
- For every compact multi-target stat, tests pin each target `legendFormat` together
  with the same-name `byName` no-value override so a later legend rename cannot
  detach unknown-state handling.
- The dashboard contract rewrite must preserve the existing cross-cutting guards:
  every fixed overview query retains production/server/strategy selectors; superseded
  current-run metrics stay absent from the accumulated chart; fixed colors remain
  well formed; generic dashboards remain free of hard-coded targets; and the legacy
  development-target guard stays active.
- Chinese text must not replace stable metric names, label values, dashboard UIDs, or
  URL variable names.
- History changes preserve the last atomic output on build failure and do not touch
  the trading process.
- Rollback is the task commit revert. New alerts remain shadow-only and no paging,
  service restart, or production deployment occurs in this task.

## Non-goals

- No trading strategy, order, exchange, runtime manifest, or PnL calculation changes.
- No notification-mode promotion, production deployment, push, pull request, merge,
  or worktree cleanup.
- No all-time/exchange-statement accounting claim.
- No fabricated history for Trading01 until it exposes the same authoritative
  history contract.
- No strategy-specific first-PnL SLA or High-alert timing change without owner data.
- No Grafana plugin upgrade or unrelated provisioning-directory cleanup.

## Plan review round 1 dispositions

- `B1` — **ACCEPTED:** Fleet stale/missing count now uses inventory `unless` fresh;
  rule and dashboard share a tested 180-second threshold.
- `B2` — **ACCEPTED:** every field in a merged summary gets an explicit per-series
  `noValue`; missing telemetry cannot become a real stopped/healthy value.
- `B3` — **ACCEPTED:** history eligibility is an inventory capability label rather
  than a hard-coded target selector.
- `N1` — **ACCEPTED:** duplicate process uses a 2-to-infinity range mapping.
- `N2` — **ACCEPTED:** coverage start remains a separate visible panel and the sole
  pre-history anchor after fake zero removal.
- `N3` — **ACCEPTED:** conventions document edit-copy/export for non-editable
  provisioned dashboards.
- `N4` — **ACCEPTED:** the dashboard contract rewrite explicitly preserves all
  cross-cutting selectors, negative assertions, color checks, and legacy guards.
- `N5` — **ACCEPTED:** the new alert links to a concrete runbook anchor.

## Plan review round 2 dispositions and owner gate

- `B4` — **ACCEPTED BY OWNER:** the Fleet summary's
  healthy steady state as neutral monitored count plus zero stale, process-mismatch,
  and active-alert counts. A per-strategy alert column makes every nonzero total
  actionable. Production evidence on 2026-08-28 showed both inventory targets with
  fresh probes and exactly one process, so zero is a valid healthy baseline rather
  than a permanent canary exception. The owner approved this contract on 2026-08-28.
- `N6` — **ACCEPTED:** dashboard uses the generic recorded timestamp, alert uses the
  raw timestamp; only the 180-second contract is shared.
- `N7` — **ACCEPTED:** the plan now contains the exact absent-safe history alert
  expression.
- `N8` — **ACCEPTED:** legend and matching per-field no-value override are tested as
  one contract.
- `N9` — **ACCEPTED:** only `trading_target_info` receives `history_capable`.
