# Trading01 Multi-Strategy Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task by task.

**Goal:** Onboard Trading01's Lighter strategy into SkyEye and add reusable multi-strategy monitoring without disrupting its existing ZenIncome telemetry or trading process.

**Architecture:** A portable source probe maps executor-specific raw logs into stable `tnauqquant_*` metrics. A Linux Alloy fragment reuses Trading01's existing central sinks. Prometheus inventory and recording rules expose engine-neutral `trading_strategy_*` metrics consumed by generic shadow alerts and two provisioned Grafana dashboards.

**Tech Stack:** Bash, Grafana Alloy, systemd, Prometheus/PromQL, Loki/LogQL, Grafana dashboard JSON, Docker Compose, Shell test fixtures.

## Global Constraints

- Work only in the dedicated `feat/trading01-monitoring` worktree.
- Do not start, stop, restart, or edit the Trading01 trading strategy.
- Preserve Trading01's existing ZenIncome Alloy components and central sinks.
- Keep fixed Grafana datasource UIDs: `prometheus`, `loki`, and `alertmanager`.
- Scrub sensitive and high-cardinality identifiers before logs leave the source host.
- Keep all new/generalized trading alerts on shadow routing.
- Do not sum current-run P&L across strategies.

### Task 1: Generalize and test the source probe

**Files:**

- Modify: `agents/alloy/trading/probe.sh`
- Modify: `agents/alloy/trading/deployment.env.example`
- Modify: `tests/trading/test-probe.sh`
- Modify: `tests/trading/test-log-pipeline.sh`

1. Add failing probe fixtures for `lighter-robinhood-main`, a coordinator-book net short/long/flat position, stable executor-volume snapshots, `risk_stopped`, optional sidecar state, and file mode `0640`.
2. Run `bash tests/trading/test-probe.sh` and confirm the new expectations fail.
3. Add validated `TQ_EXECUTOR_MAP`, `TQ_SIDECAR_REQUIRED`, and `TQ_TEXTFILE_MODE` inputs.
4. Parse `volume_usd_by_executor` from the newest stable `pnl_status`; map executor names to bounded exchange labels.
5. Parse generic signed net position from the latest coordinator-book snapshot while preserving the existing two-exchange metrics.
6. Emit risk-stop, sidecar-required, and existing lifecycle/process metrics atomically with the configured file mode.
7. Extend log-pipeline tests to assert execution correlation IDs are redacted and never used as labels.
8. Run `bash tests/trading/test-probe.sh && bash tests/trading/test-log-pipeline.sh` and require both to pass.

### Task 2: Add a coexistence-safe Linux Alloy deployment

**Files:**

- Create: `agents/alloy/trading/config-linux.alloy.tmpl`
- Create: `agents/alloy/trading/deployment-linux.env.example`
- Create: `agents/alloy/trading/setup-linux.sh`
- Create: `agents/alloy/trading/skyeye-trading-probe.service.tmpl`
- Create: `agents/alloy/trading/skyeye-trading-probe.timer.tmpl`
- Create: `tests/trading/test-linux-setup.sh`
- Modify: `agents/alloy/trading/README.md`

1. Add failing render tests around an existing synthetic Alloy base containing `prometheus.remote_write.central` and `loki.write.central`.
2. Assert the rendered fragment has unique component names, reuses both central receivers, tails only the configured raw-log glob, scrubs sensitive values, and has no embedded secret.
3. Assert the installer uses Alloy directory mode, validates before restart, provisions the systemd timer, creates an `ubuntu:alloy` setgid textfile directory, and grants only traverse ACL on the configured home chain.
4. Implement `setup-linux.sh` with explicit `--env-file`, `--render-only`, and `--no-start` modes plus rollback of the Alloy environment file on validation failure.
5. Add a oneshot probe service and timer; do not add a service for the trading runtime.
6. Document coexistence, permissions, rollback, and manual validation.
7. Run `bash tests/trading/test-linux-setup.sh` and `alloy validate` against the rendered synthetic config directory.

### Task 3: Make central recording and alert rules inventory-driven

**Files:**

- Modify: `prometheus/rules/trading-targets.yml`
- Modify: `prometheus/rules/trading.yml`
- Modify: `prometheus/rules/tests/trading.test.yml`
- Modify: `loki/rules/fake/tnauqquant.yml`
- Modify: `tests/trading/test-central-config.sh`

1. Add failing structural tests requiring both targets in `trading_target_info`, engine-neutral `trading_strategy_*` recording rules, no hard-coded single target in generic rules, and shadow routing.
2. Add failing promtool cases for both the two-exchange target and Trading01, including process down, stale telemetry, binding ambiguity, optional sidecar, and risk stop.
3. Implement the inventory and recording rules while retaining labels needed by Grafana and alerts.
4. Rewrite alert expressions to join inventory and ensure every generalized alert remains shadow.
5. Generalize Loki rule selectors to all production `tnauqquant` strategy labels and keep them shadow.
6. Run `promtool test rules prometheus/rules/tests/trading.test.yml`, `promtool check rules` for the modified files, and `bash tests/trading/test-central-config.sh`.

### Task 4: Provision reusable detail and fleet dashboards

**Files:**

- Create: `grafana/dashboards/Trading/trading-strategy-detail.json`
- Create: `grafana/dashboards/Trading/trading-strategy-fleet.json`
- Modify: `tests/trading/test-central-config.sh`
- Modify: `docs/grafana-conventions.md`

1. Add failing dashboard contract checks for unique UIDs, fixed datasource UIDs, `server_id`/`strategy` variables, inventory-backed fleet rows, status text/color mappings, per-strategy navigation, and no cross-strategy P&L total.
2. Build the detail dashboard using `trading_strategy_*` queries and dynamic exchange legends.
3. Build the fleet dashboard as a dense operations table with one row per strategy and a link to the detail dashboard.
4. Preserve the existing `tnauqquant-trading-overview.json` dashboard unchanged.
5. Run `find grafana/dashboards -name '*.json' -exec jq empty {} +` and `bash tests/trading/test-central-config.sh`.

### Task 5: Documentation, full verification, and publication

**Files:**

- Modify: `docs/trading-monitoring-development-plan.md`
- Modify: `docs/trading-new-server-handoff.md`
- Modify: `docs/project-brief.md`
- Modify: `docs/work-log.md`

1. Document the generic strategy contract, Linux onboarding path, fleet/detail dashboard use, and shadow-to-paging promotion gate.
2. Record the completed architecture change in the project brief and prepend a concise work-log entry.
3. Run all project validation commands from `AGENTS.md`, all `tests/trading/*.sh`, Prometheus rule tests, Alloy validation, and shell syntax checks.
4. Review `git diff --check`, `git diff --stat`, and the complete scoped diff.
5. Create small focused commits, fetch and rebase onto `origin/master`, rerun verification, push `feat/trading01-monitoring`, and open a pull request to `master`.

### Task 6: Canary deployment and end-to-end verification

**Files:**

- Deploy only committed/provisioned artifacts; do not edit live source files as the source of truth.

1. Record Trading01's trading PID/tmux state, current raw-log path, existing ZenIncome `up` series, and Alloy health before deployment.
2. Deploy the merged central configuration; validate Docker Compose, Prometheus rules, Loki ruler state, and Grafana provisioning.
3. Run the Linux installer on Trading01 using its existing Alloy sinks and the Lighter executor mapping. Validate the full `/etc/alloy` directory before allowing Alloy to restart.
4. Confirm the trading PID/tmux state is unchanged and ZenIncome series continue reporting.
5. Confirm Trading01 metrics and scrubbed logs reach the central services, both new dashboards return data, and alerts remain shadow.
6. If the stopped process still has a running manifest, confirm the fleet dashboard reports the inconsistency as down/stale; do not fabricate a completion marker.
7. Record deployment evidence and rollback instructions in the work log.
