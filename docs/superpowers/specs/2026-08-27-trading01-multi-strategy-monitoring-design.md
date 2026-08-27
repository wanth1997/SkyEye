# Trading01 Multi-Strategy Monitoring Design

## Context

SkyEye currently monitors one `tnauqquant` strategy (`tnauqquant-prod-1 / toobit-mexc-btc`). Its probe, Prometheus rules, Loki rules, and Grafana dashboard encode assumptions that only hold for that two-exchange deployment. Trading01 runs a different `tnauqquant` strategy (`trading01 / lighter-robinhood-btc-canary`) with one Lighter executor while an existing Alloy installation already forwards ZenIncome telemetry.

The Trading01 runtime does emit usable raw telemetry. Its latest run log contains `pnl_status`, `trade_status`, coordinator-book net position, executor volume, risk state, and run lifecycle events. The missing Grafana result is therefore an onboarding and data-contract gap, not an absence of raw logs.

## Goals

- Monitor Trading01 without changing or restarting the trading strategy.
- Preserve the existing ZenIncome Alloy pipeline on Trading01.
- Support both the existing two-exchange strategy and the new single-exchange strategy from one portable probe contract.
- Replace target-specific central alert expressions with inventory-driven, multi-strategy rules.
- Add a reusable per-strategy dashboard and a fleet dashboard showing every strategy's current P&L and operating state.
- Keep all new or generalized trading alerts in shadow routing until canary evidence is reviewed.

## Non-goals

- Repairing or restarting the Trading01 trading process.
- Fabricating the missing runtime completion marker after the process exited.
- Aggregating current-run P&L into a portfolio total. Runs can start at different times, so that sum would not represent a common accounting period.
- Replacing the existing `tnauqquant-trading-overview` dashboard in this rollout.
- Exposing a scrape endpoint on Trading01.

## Source-side telemetry

The Bash probe remains the compatibility boundary between trading runtime logs and SkyEye. It will accept an executor mapping such as `lighter-robinhood-main=lighter` or `toobit-main=toobit,mexc-ui=mexc` instead of hard-coding executor names.

The probe will:

- prefer the latest stable `pnl_status.volume_usd_by_executor` snapshot for current-run volume;
- parse the latest `portfolio_projection=coordinator_book` net position for single-exchange and future layouts;
- preserve the existing two-exchange position parsing for backward compatibility;
- expose risk-stop and sidecar-required state explicitly;
- write textfile metrics with a configurable mode so the Linux probe user and Alloy group can share a least-privilege directory;
- continue to expose manifest/process/binding state even if a stale manifest says `running` after the process has stopped.

Raw log redaction happens inside Alloy before data leaves the host. Order IDs, client action IDs, credentials, email addresses, repository paths, and high-cardinality execution correlation IDs are replaced in the log line and never promoted to Loki labels.

## Linux coexistence model

Trading01's current Alloy configuration already defines the central Prometheus and Loki sinks used by ZenIncome. SkyEye will not replace that file or add a second Alloy service. Instead:

1. Change Alloy's `CONFIG_FILE` from `/etc/alloy/config.alloy` to the supported configuration directory `/etc/alloy`.
2. Install a uniquely named `trading.alloy` fragment that reuses the existing `prometheus.remote_write.central` and `loki.write.central` receivers.
3. Install the trading probe as a systemd oneshot service and timer.
4. Store rendered non-secret probe settings in `/etc/skyeye-trading/config.env`.
5. Use an `ubuntu:alloy` setgid textfile directory with mode `2770` and metric files with mode `0640`.
6. Grant the Alloy user traverse-only ACL access to the exact home-directory chain needed to read world/group-readable raw logs.

The installer validates the full Alloy directory before restarting Alloy and records a backup of the prior service environment. It verifies that the required central receivers exist, so a fragment cannot silently orphan telemetry.

## Central data model

`trading_target_info` is the inventory metric for monitored strategies. Each series identifies `product`, `environment`, `server_id`, `strategy`, `quote_currency`, and `notification_mode`. Both the existing target and Trading01 are declared there.

Raw `tnauqquant_*` metrics stay stable. Prometheus recording rules publish a small engine-neutral `trading_strategy_*` layer used by new dashboards and alerts. This creates a future extension point for another trading engine without forcing every dashboard panel to understand engine-specific metric names.

Target membership comes from inventory rather than a regex embedded in every alert. Alerts join runtime metrics to `trading_target_info`, retain identity labels, and use shadow routing for this rollout. Loki rules cover all production `tnauqquant` strategies rather than one server/strategy pair.

## Dashboards

The reusable detail dashboard has `server_id` and `strategy` variables sourced from `trading_target_info`. Its panels cover:

- current-run P&L and completed cycles;
- last cycle P&L and current volume by exchange;
- process, binding, risk-stop, and telemetry-freshness state;
- signed net position;
- scrubbed strategy logs.

The fleet dashboard is a strategy-level operations table. Each row shows server, strategy, current-run P&L, cycles, volume, signed position, process/binding/risk state, and telemetry age. Statuses have text as well as color, and each row links to the detail dashboard.

The existing dashboard remains provisioned during migration. No datasource UID changes are permitted.

## Rollout and safety

Tests cover log fixtures for both executor layouts, Linux rendering/coexistence, Prometheus rule evaluation, Loki rule shape, and dashboard JSON contracts. Deployment order is central configuration first, then Trading01 source telemetry.

Before and after the remote rollout, record the trading PID state and confirm the installer did not start or restart it. Confirm ZenIncome series remain present. Trading01 is expected to appear as down if its manifest still declares a run but no trading process exists; this is a real state to surface, not normalize away.

New alerts remain `notification_mode=shadow`. Paging is enabled only after a separate canary review establishes expected telemetry cadence and false-positive behavior.
