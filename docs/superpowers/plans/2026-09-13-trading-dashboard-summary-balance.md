# Trading Dashboard Summary and Balance Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task.

**Goal:** Merge detail status panels, remove displayed risk P&L, and show total balance.

**Architecture:** Reuse the latest stable manifest-bound P&L snapshot. Record its already-aggregated equity through the Trading inventory interface. Combine Loki incidents and Prometheus status with Grafana's Mixed datasource.

**Tech Stack:** Bash, jq, Prometheus 2.54.1, Loki 3.1.1, Grafana 11.2 JSON.

## Constraints

- Preserve datasource UIDs, selector variables and alert routing.
- Develop inside this worktree; do not edit the Trading producer.
- Balance means latest stable total account equity in USDT, scoped to one strategy.

## Task 1: Expose equity

Files: `agents/alloy/trading/probe.sh`, `tests/trading/test-probe.sh`,
`prometheus/rules/trading.yml`, `prometheus/rules/tests/trading.test.yml`.

- [x] Add single/paired equity assertions; run `bash tests/trading/test-probe.sh`
  and verify the new assertion fails before implementation.
- [x] Initialize `CURRENT_EQUITY=""`. In the validated stable P&L block, parse
  `current_equity="$(logfmt_value "$CURRENT_PNL_LINE" equity_now)"`, assign only
  when `is_number "$current_equity"` succeeds, and emit
  `tnauqquant_current_equity_usdt` only when present.
- [x] Add `trading_strategy_current_equity_usdt` using the current-real-P&L
  production selector and inventory join. Cover unknown targets in rule tests.
- [x] Verify zero, missing, malformed and unstable samples in the existing probe
  suite, then require PASS from probe tests and `promtool test rules`.

## Task 2: Compact detail dashboard

Files: `grafana/dashboards/Trading/trading-strategy-detail.json`,
`tests/trading/test-central-config.sh`.

- [x] Financial cards move to y=0. Add balance id=14 at x=15, y=0, w=9, h=4:
  `trading_strategy_current_equity_usdt{server_id="$server_id",strategy="$strategy"}`.
- [x] Summary id=1 moves to x=0, y=4, w=24, h=3, datasource
  `{"type":"mixed","uid":"-- Mixed --"}`. Keep Prometheus refs A–F, append
  Loki refs G–J with zero fallback and per-query incident thresholds.
- [x] Remove panel id=2 and composition target D; shift plots/logs up one grid
  unit and increment dashboard version to 4.
- [x] Update existing layout/source assertions and run
  `bash tests/trading/test-central-config.sh`; require PASS.

## Task 3: Verify and publish for review

Files: `docs/project-brief.md`, `docs/work-log.md`.

- [x] Run repository configuration validation and relevant Trading regressions.
  Where local Docker is unavailable, use isolated temporary copies with remote
  Docker tools; never mount candidate files into live services.
- [x] Check candidate LogQL against the running Loki query API. Attempt browser
  verification and record any unavailable browser session.
- [x] Update project context and prepend actual verification/deployment status to
  the work log.

Delivery: commit, fetch/rebase origin/master, push and open a PR to master.
Production deployment remains a separate step.
