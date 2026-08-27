# Trading Cross-Run Accumulated Real P&L Development Plan

> **Task ID:** `skyeye-trading-accumulated-pnl-20260827`
>
> **Status:** Final after owner resolution of round-2 findings
>
> **Base:** `fad0e46cae9f7b7db8ac609f19e7204efc031b6d`

## Goal

Replace the live Trading dashboard's current-run-only P&L chart with a 30-day
cross-run accumulated Real P&L chart. Every authoritative completed cycle contributes
its `cycle_real_pnl_usdt` delta exactly once. Completed prior days are compacted to a
single close point at the following Asia/Taipei midnight; the current day retains its
individual cycle points. The prior close is therefore the next day's opening baseline
and the accumulated value never resets merely because the process or calendar day
changed.

This is operational P&L derived from every qualifying local raw-log event cached by
SkyEye. It is not an exchange statement or tax ledger. Its absolute baseline begins at
the oldest event present in the durable local cache; an initial bootstrap can only
reconstruct raw logs still present on the Trading host.

## Authoritative event contract

Include only records satisfying all of the following:

- `msg=pnl_status`
- `stable=true`
- `cycle_completed=true`
- non-empty `cycle_id`
- parseable RFC3339Nano `time`
- finite numeric `cycle_real_pnl_usdt`

`cycle_real_pnl_usdt` is the rebate-adjusted delta for one completed cycle.
`real_pnl_usdt` is cumulative only inside the current process session and must never
be added across events or runs. `cycle_id` is the immutable deduplication key. An
identical duplicate is ignored; the same ID with a different timestamp or delta is a
contract conflict and fails the history build without replacing the last good output.
Legacy `pnl_status` records missing this contract are not reconstructed from
run-cumulative `real_pnl_usdt`: that fallback would create an unauditable money value.
The builder instead emits a skipped-legacy-event count and the first supported event
timestamp, both surfaced on the dashboard so coverage cannot be mistaken for all-time
history.

The existing Trading monitoring and runtime handoff documents will record these
producer fields and consumer semantics. This documents an already-deployed event
contract; it does not change tnauqquant code or trading behavior.

## Architecture

### Isolated history builder

Add `agents/alloy/trading/pnl-history.sh`, launched once per minute by its own user
LaunchAgent. It remains separate from the 15-second safety/runtime probe so a history
failure cannot suppress process, binding, position, or alert telemetry.

The builder keeps a mode-`0700` cache directory outside Git. For every raw log:

1. derive and validate the run ID from the basename;
2. compare inode, byte size, and mtime with the cached fingerprint;
3. reuse an unchanged per-run summary without opening the raw log;
4. rescan only a new or changed log into an atomic mode-`0600` summary;
5. extract and deduplicate authoritative completion events;
6. retain cached summaries when old raw logs are archived or removed.

After updating changed files, the builder merges the compact summaries, rejects
cross-file cycle conflicts, sorts by event time, and computes one accumulated total.
It emits only:

- a baseline point at the start of the rolling 30-day display window;
- one daily-close point for each completed Asia/Taipei day;
- individual completed-cycle points for the current Asia/Taipei day;
- build timestamp, first-event timestamp, last-event timestamp, cached-cycle count,
  and validity gauges.

Point labels contain only one stable bounded ordinal (`point`). P&L and event time are
separate metric values joined by `point`; timestamps never become labels. Metrics
never contain `run_id`, `cycle_id`, paths, PIDs, order identities, or client action
identities. The display cardinality is bounded to
`history_days + 1 + max_current_day_cycles`; the default limits are 30 days and 500
current-day cycles. Exceeding the bound or finding a conflict fails closed and
preserves the last atomic `.prom` file.

At the current host evidence (67 raw logs, about 34 MB total, largest about 3.1 MB),
bootstrap reads about 34 MB once. Steady state stats all known paths once per minute
and rescans only the growing current log, so work is bounded by that log's size rather
than all retained history. The compact cache is one record per completed cycle.

### Prometheus and dashboard

The existing Alloy textfile collector scrapes the new
`tnauqquant-pnl-history.prom`; no new ingestion port, Loki query, remote-write path,
or high-cardinality event series is introduced.

Replace panel ID 2 in `Trading · Live Operations` rather than adding a competing
dashboard. Keep the existing pinned dashboard and datasource UIDs. The panel uses an
pair of instant Prometheus table queries over bounded point/value and point/timestamp
metrics, joins on `point`, converts epoch seconds to a real time field, sorts ascending,
and draws a Timeseries step-after line. A compact history-age stat is placed beside
the existing bottom-row status cards so a failed/frozen builder is visible. The
current-run cycle metric remains emitted for diagnostics/backward compatibility but
is no longer the operator's primary P&L chart.

The existing industrial operations visual language is retained: restrained blue
line/points, clear time and USDT axes, no decorative animation, and explicit panel
copy describing the all-cached-events baseline and daily compaction.

## File plan

### Create

- `agents/alloy/trading/pnl-history.sh`
- `agents/alloy/trading/com.wanbrain.skyeye-trading-pnl-history.plist.tmpl`
- `tests/trading/test-pnl-history.sh`

### Modify

- `agents/alloy/trading/setup-macos.sh`
  - validate/install/render both scripts and both LaunchAgents
- `agents/alloy/trading/deployment.env.example`
  - add `TQ_PNL_HISTORY_CACHE_DIR`, `TQ_PNL_HISTORY_DAYS=30`, and
    `TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES=500`
- `agents/alloy/trading/README.md`
  - document history semantics, cache, failure behavior, and bounded cardinality
- `tests/trading/test-log-pipeline.sh`
  - validate the second script/plist, new env values, render, and `plutil` contract
- `grafana/dashboards/Trading/tnauqquant-trading-overview.json`
  - replace panel ID 2's current-run XY source with accumulated history points and
    add a history-age stat without changing the dashboard UID
- `tests/trading/test-central-config.sh`
  - scope existing assertions to the live dashboard and lock the new panel query,
    transforms, axes, step rendering, and production labels
- `docs/trading-monitoring-development-plan.md`
- `docs/trading-runtime-contract-agent-spec.md`
  - record the existing authoritative completed-cycle event dependency
- `docs/project-brief.md`
- `docs/work-log.md`

No changes are made to Trading source, P&L calculation, alert routing, retention,
Loki labels, stable datasource UIDs, or live services.

## Ordered implementation

1. Add failing tests for the history builder, setup/render contract, and replacement
   panel; capture RED evidence before implementation.
2. Implement the isolated cached builder with atomic cache/output writes, lock,
   contract validation, deduplication, local-day compaction, bounds, and permissions.
3. Extend the installer and LaunchAgent templates without starting any service.
4. Replace live panel ID 2 and make the Grafana contract tests pass.
5. Update event contracts, operator documentation, project brief, and newest-first
   work log.
6. Run fresh verification, inspect the scoped diff, commit, fetch/rebase onto current
   `origin/master`, and rerun affected verification if the base changes.
7. Send the immutable commit range to the read-only Herdr reviewer. Triage and commit
   accepted findings; request delta review for behavioral changes.

## Builder test matrix

- two runs on the same day accumulate instead of resetting;
- a prior-day close is emitted at the next local midnight and equals the next day's
  opening baseline;
- positive and negative cycle deltas sum correctly;
- exact duplicate cycle records contribute once;
- conflicting duplicate cycle IDs fail without replacing last good output;
- unstable, incomplete, missing-ID, nonnumeric, and malformed events are excluded or
  fail according to the authoritative-record boundary;
- an unchanged historical log reuses its summary; only a changed log summary mtime
  advances;
- removing an already-cached raw log does not remove its P&L history;
- bootstrap reconstructs available logs and permissions are `0700`/`0600`;
- output contains no run ID, cycle ID, path, PID, order ID, or client action ID label;
- timestamp is a metric value joined by stable point ordinal, never a label;
- legacy completed-looking records are counted as skipped and the first supported
  timestamp is emitted;
- current-day point bound is enforced;
- an empty source emits validity metadata but no fabricated P&L point.

## Verification

```bash
bash tests/trading/test-pnl-history.sh
bash tests/trading/test-probe.sh
bash tests/trading/test-log-pipeline.sh
bash tests/trading/test-central-config.sh
bash -n agents/alloy/trading/pnl-history.sh agents/alloy/trading/setup-macos.sh
plutil -lint agents/alloy/trading/com.wanbrain.skyeye-trading-pnl-history.plist.tmpl
alloy validate agents/alloy/trading/config-macos.alloy.tmpl
docker compose config --quiet
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" prom/prometheus:v2.54.1 \
  promtool check config /etc/prometheus/prometheus.yml
docker run --rm -v "$PWD/alertmanager:/etc/alertmanager:ro" prom/alertmanager:v0.27.0 \
  amtool check-config /etc/alertmanager/alertmanager.yml
find grafana/dashboards -name '*.json' -exec jq empty {} +
```

If Docker is unavailable, record container checks as environment-blocked; do not
claim they passed. Static tests, `bash -n`, `plutil`, local `alloy validate`, and `jq`
remain mandatory. No authenticated Grafana browser is available in this workspace,
so deployment remains outside scope and production must canary the provisioned panel
before treating it as authoritative.

## Rollout and rollback

Deployment is a separate operator action. Render and validate first, then install the
builder without touching the Trading process. Canary requirements are: expected
cached-cycle count, a manually computed cross-run sample matching the accumulated
metric, acceptable one-minute builder runtime, bounded metric series, history age,
and unchanged Trading PID/config/manifest/log metadata.

Rollback restores the previous dashboard/probe installer revision and unloads only
the history LaunchAgent. Preserve the cache for audit/retry; do not delete raw logs or
change the Trading process.

## Non-goals

- No exchange statement, tax ledger, deposit/withdrawal accounting, or data older
  than available raw logs/cache.
- No per-cycle remote metric series for all 30 days; completed prior days are
  intentionally compacted to daily closes for bounded cardinality.
- No Loki recording rule or repeated 30-day query-time parsing.
- No alerts or paging changes in this delivery.
- No push, pull request, merge, deployment, or worktree cleanup without separate user
  authorization.

## Plan review round 1 dispositions

- `B1` — **ACCEPTED:** replace live panel ID 2; retain the old metric only for
  compatibility/diagnostics.
- `B2` — **ACCEPTED:** replace the Loki design with an incremental per-run cache and
  state the observed 34 MB bootstrap/changed-log steady-state cost.
- `B3` — **ACCEPTED:** remove query-time LogQL series; emit only bounded compacted
  Prometheus points without cycle/run identity labels.
- `B4` — **ACCEPTED:** remove interval-window arithmetic; accumulated values are
  computed once by the tested builder.
- `B5` — **ACCEPTED:** add the completed-cycle event dependency to both designated
  Trading contract documents.
- `N1` — **ACCEPTED:** modify the existing tagged dashboard, so no new naming/tag
  decision is required.
- `N2` — **ACCEPTED:** use Asia/Taipei day boundaries consistently.
- `N3` — **ACCEPTED:** no browser-side cumulative transform remains.
- `N4` — **ACCEPTED:** baseline is all cached qualifying events before the 30-day
  window, not zero at an arbitrary Grafana range edge.
- `N5` — **ACCEPTED:** keep assertions scoped to the existing single dashboard.

## Plan review round 2 dispositions and owner resolution

The paired workflow reached its two-round plan-review limit with three remaining
blocking findings. On 2026-08-27 the owner explicitly approved the recommended
resolution below, making this the final implementation plan without a third plan
review.

- `B6` — **ACCEPTED:** do not infer legacy per-cycle deltas from run-cumulative
  values. Exclude unsupported legacy records and expose skipped count plus coverage
  start on the dashboard.
- `B7` — **ACCEPTED:** remove timestamp labels. Emit P&L and timestamp as two values
  keyed by the same stable bounded `point` ordinal.
- `B8` — **ACCEPTED:** replace XY with a Timeseries panel using a real transformed
  time field and supported `stepAfter` interpolation.
- `N6` — **ACCEPTED:** add a visible history-age stat.
- `N7` — **ACCEPTED:** treat the 67-file/34-MB measurement as a dated 2026-08-27 host
  observation and remeasure during deployment canary.
- `N8` — **ACCEPTED:** use a distinct dot-prefixed history temp pattern and test that
  no temp file remains visible to the textfile collector.
- `N9` — **ACCEPTED:** require the three new history variables in setup and validate
  the complete builder environment at runtime.
- `N10` — **ACCEPTED:** report Alloy validation as environment-blocked if unavailable.
- `N11` — **ACCEPTED:** document that the existing 15-second today's-cycle counter
  still scans same-day logs; this task eliminates full-history parsing for the new
  accumulated chart, not that independent current-day metric.
