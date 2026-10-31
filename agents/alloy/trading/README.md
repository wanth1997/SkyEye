# Trading monitoring agent for macOS and Linux

This directory installs three source-host components:

- Grafana Alloy tails tnauqquant `*.raw.log` files, scrubs sensitive text, and pushes logs/metrics through Cloudflare Access.
- A 15-second launchd/systemd probe reads process/config/run state plus manifest-bound PNL events. macOS writes `tnauqquant.prom`; Linux assigns one validated output basename per strategy.
- A separate 60-second launchd builder incrementally caches authoritative completed-cycle deltas across raw logs and writes the bounded `tnauqquant-pnl-history.prom` series used by the 30-day accumulated Real P&L chart.

Neither component starts, stops, signals, or attaches to the trading process.

## Files

| File | Purpose |
|---|---|
| `config-linux.alloy.tmpl` | Per-strategy Loki fragment that reuses the existing central receiver |
| `config-linux-metrics.alloy.tmpl` | Shared textfile collector for all Linux strategy outputs |
| `deployment-linux-{robinhood,mainnet,ourbit}.env.example` | Credential-free Trading01 instance contracts |
| `setup-linux.sh` | `add` (one-step install/update), `retire`, render-only, and explicit singleton migration |
| `retire-linux.sh` | Per-strategy retirement with an exact rollback record (run via `setup-linux.sh retire`) |
| `linux-common.sh` | Shared test-root, systemctl and path guards for the Linux scripts |
| `skyeye-trading-probe@.service.tmpl` | Linux per-strategy read-only oneshot probe |
| `skyeye-trading-probe@.timer.tmpl` | Linux per-strategy 15-second timer |
| `config-macos.alloy.tmpl` | Logfmt pipeline, source-side scrub, Loki push and Prometheus remote write |
| `deployment.env.example` | Complete host-specific deployment contract without real secrets |
| `probe.sh` | Read-only process/manifest/marker/log probe |
| `pnl-history.sh` | Incremental, cross-run accumulated Real P&L history builder |
| `setup-macos.sh` | Render, validate, install and optionally start Alloy + launchd |
| `com.wanbrain.skyeye-trading-probe.plist.tmpl` | 15-second user launchd job |
| `com.wanbrain.skyeye-trading-pnl-history.plist.tmpl` | Independent 60-second history job |

## Production Mac install

1. Copy and edit the environment file:

   ```bash
   brew_prefix="$(brew --prefix)"
   install -m 600 agents/alloy/trading/deployment.env.example \
     "$brew_prefix/etc/alloy/config.env"
   ```

2. Verify the checked-in non-secret production paths, then replace both Cloudflare placeholders with the dedicated host token. Production keeps `TQ_REQUIRE_RUNTIME_CONTRACT=1`, so missing or invalid `current.json` fails closed instead of selecting a log by mtime.

3. Render without changing services:

   ```bash
   render_dir="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-trading-render.XXXXXX")"
   agents/alloy/trading/setup-macos.sh \
     --env-file "$(brew --prefix)/etc/alloy/config.env" \
     --render-only "$render_dir"
   plutil -lint "$render_dir/com.wanbrain.skyeye-trading-probe.plist"
   plutil -lint "$render_dir/com.wanbrain.skyeye-trading-pnl-history.plist"
   alloy validate "$render_dir/config.alloy"
   ```

4. Install and start after the render validates:

   ```bash
   agents/alloy/trading/setup-macos.sh
   brew services list | grep alloy
   launchctl print "gui/$(id -u)/com.wanbrain.skyeye-trading-probe"
   launchctl print "gui/$(id -u)/com.wanbrain.skyeye-trading-pnl-history"
   ```

## Linux install alongside an existing Alloy config

The Linux path does not replace the base config or define another remote-write
sink. It switches the existing Alloy service to directory mode, installs one
shared `/etc/alloy/trading-metrics.alloy` collector and one
`/etc/alloy/trading-STRATEGY.alloy` Loki fragment per strategy. This preserves
other product pipelines such as ZenIncome. Each strategy has its own env,
systemd instance, exact executable/config/log binding and metrics file.

### Add or remove a Trading target

A target is one strategy on one server. Every Trading alert is shadow-only, so
a routine add or remove needs no canary; the checks below are enough. Changing
`trading.yml`, Alertmanager routing or `notification_mode` still requires the
full shadow → canary process.

**Add** (host first, then central):

1. Host, from a SkyEye checkout, with a mode-`0600` env copied from a
   `deployment-linux-*.env.example` and edited for the strategy:

   ~~~bash
   sudo agents/alloy/trading/setup-linux.sh add --env-file /root/STRATEGY.env
   ~~~

   It validates the combined `/etc/alloy` directory, installs the env and Loki
   fragment, **reloads** Alloy (printing the fragments it re-evaluates),
   enables `skyeye-trading-probe@STRATEGY.timer` and runs the probe once. A
   failure restores the printed rollback record. Re-running is a no-op; a
   changed env updates the instance in place. When only a restart would work
   (first switch to directory mode, reload unsupported, or Alloy stopped) it
   refuses and names the pipelines a restart interrupts; re-run with
   `--restart-alloy` once that is acceptable. `--no-start` stages files only.
   It never starts, stops or signals a trading process: a Mainnet env with
   `TQ_POC_RUN_EXPECTED=0` gets only its read-only probe.
2. Repo:

   ~~~bash
   scripts/trading-target add --server SERVER_ID --strategy STRATEGY [--quote USDT] [--history]
   tests/trading/test-central-config.sh
   ~~~

   Commit, PR, merge. Tests derive their expectations from the inventory, so
   no test edits are needed.
3. Central, on monitoring-prod in `/home/ubuntu/SkyEye`: `scripts/central-deploy`
   (optionally `--dry-run` first). It validates the merged commit in a
   temporary worktree, fast-forwards, reloads Prometheus and prints the live
   `trading_target_info` rows. Glance at the fleet dashboard once. It records
   the last successfully applied commit in `.git/skyeye-central-deploy.applied`,
   so if a reload fails, re-running the same command validates and reloads the
   checkout again (also the first run on a checkout updated by `git pull`). It
   refuses untracked files under `prometheus/`, `alertmanager/`,
   `grafana/dashboards/`, `grafana/provisioning/` and `loki/rules/`, because
   those directories go live unvalidated; the only allowed local file there is
   `alertmanager/secrets/tg_token`.

**Remove** (central first, so `TradingTelemetryMissing` cannot fire):

1. Repo: `scripts/trading-target remove --server SERVER_ID --strategy STRATEGY`,
   then PR and merge.
2. Central: `scripts/central-deploy`.
3. Host: `sudo agents/alloy/trading/setup-linux.sh retire --strategy STRATEGY`.
   It validates `/etc/alloy` without the fragment, disables only that probe,
   moves its env, fragment and metrics file into
   `/etc/skyeye-trading/retired/STRATEGY-<UTC>/` (with `paths.list` and
   `retire.meta`) and reloads Alloy. Shared artifacts, sibling strategies,
   history and Loki data stay. It prints the `add --env-file` command that
   re-installs the archived env; re-running reports "Already retired".

Shared collector, units and `probe.sh` are rewritten only while every
templated probe is stopped and disabled; both commands refuse otherwise.

### Legacy flag form and singleton migration

Without a subcommand, `setup-linux.sh --env-file PATH` keeps its original
behaviour: `--render-only DIR` renders without touching the host, `--no-start`
installs without restarting Alloy or enabling the probe, and the default
restarts Alloy. `--migrate-singleton` removed the pre-2026-09 singleton
`trading.alloy`/`skyeye-trading-probe` on Trading01 during a one-time
maintenance cutover and is not needed for new targets.

The installer requires setfacl. It grants Alloy read/traverse only on the
raw-log directory and traverse-only access on the exact parent chain under the
probe user's home. It does not add Alloy to the user's group. The textfile
directory defaults to `/var/lib/skyeye-trading/textfile`, is setgid
probe-user:alloy mode 2770, and is checked from the probe user's account before
any service is restarted; probe output is 0640.

Trading creates each new raw log as mode `0600`. Before every 15-second probe,
the systemd oneshot runs `ensure-log-access.sh`, which adds only the named
`alloy:r--` ACL to files matching `TQ_RAW_LOG_GLOB` when effective read access
is missing. It never changes log content, ownership, group, or files outside
the configured repository and glob. This avoids silently losing Loki ingest
after a new run creates a fresh log.

Every install prints a private rollback-record directory containing only the
exact files it replaced or removed and their prior timer state. A failed
started installation restores that record automatically, including the
instance's own prior timer state for an `add` update. For a `--no-start`
install, keep the printed record until Alloy and the probe output have been
verified. Rollback touches only the recorded `skyeye-trading-probe@...` timers
and paths, reloads (or, for a restart install, restarts) Alloy, and for the
first migration restores the legacy timer state. It never controls a
tnauqquant trading service.

## Secret and access requirements

- `config.env` must remain mode `0600` and outside Git.
- Use a service token dedicated to this host and restricted to the Loki/Prometheus push Access applications.
- Verify the Grafana Cloudflare email allowlist before pushing Trading PNL or raw errors.
- The Alloy template reads secrets at runtime with `sys.env`; it never renders them into `config.alloy` or the launchd plist.

## Source-side scrub contract

Both macOS and Linux pipelines scrub the complete log line before it reaches the Loki sink:

- order and client action fields become `[ORDER_REF]`;
- attempt, reservation and recovery correlation fields become `[TRACE_REF]`;
- execution grant/mutation/account fields (`grant_id`, `mutation_id`, `mutations`, `account`) become `[EXECUTION_REF]`;
- repo paths, email addresses and tokens use their existing placeholders.

None of these values may become Loki labels. The complete Trading label budget remains `product`, `environment`, `server_id`, `strategy`, `run_id` and `level`. When reconciliation requires the original identifiers, inspect the source raw log under incident-handling authorization instead of weakening the central scrub.

## New server handoff

Another server agent changes environment values only:

- `TQ_ENVIRONMENT=production`
- `TQ_SERVER_ID=tnauqquant-prod-1`
- canonical `TQ_REPO_ROOT`, executable, config, log glob and run-state paths
- `TQ_INSTANCE_ID` matching the Trading config
- one capture-group `TQ_REPO_ROOT_REGEX` matching the canonical root
- a production-host-specific Cloudflare service token
- an executor-to-exchange map such as lighter-robinhood-main=lighter
- sidecar-required set to zero when the strategy has no sidecar
- `TQ_TIMEZONE=Asia/Taipei` for the daily completed-cycle boundary
- an absolute mode-`0700` `TQ_PNL_HISTORY_CACHE_DIR`; the default contract retains 30 display days and caps the current day at 500 completed-cycle points

Central labels, dashboard queries and rules must not be changed to accommodate a different filesystem path.

Before installation, return the non-secret handoff report from section 4.4 of `docs/trading-monitoring-development-plan.md`. Never include Cloudflare or exchange credentials.

## Troubleshooting

```bash
tail -n 100 "$(brew --prefix)/var/log/alloy/trading-probe.err.log"
tail -n 100 "$(brew --prefix)/var/log/alloy/trading-pnl-history.err.log"
launchctl print "gui/$(id -u)/com.wanbrain.skyeye-trading-probe"
launchctl print "gui/$(id -u)/com.wanbrain.skyeye-trading-pnl-history"
brew services info grafana/grafana/alloy
curl -fsS http://127.0.0.1:12345/-/ready
```

The probe output must contain no PID or path labels. `run_id` is allowed only on the single bounded `tnauqquant_current_run_info` series:

```bash
sed -n '1,240p' "$(brew --prefix)/var/lib/alloy/trading-textfile/tnauqquant.prom"
sed -n '1,240p' "$(brew --prefix)/var/lib/alloy/trading-textfile/tnauqquant-pnl-history.prom"
```

The history builder accepts only `msg=pnl_status stable=true cycle_completed=true` records containing all of `time`, process-scoped `cycle_id`, and `cycle_real_pnl_usdt`. Exact duplicates within a raw log are ignored. A conflicting duplicate fails closed and leaves the last good metrics file intact. Older completed-looking records missing the authoritative fields are never guessed from session cumulative values; they increment `tnauqquant_pnl_history_skipped_legacy_events`, while the dashboard shows the first supported event and build age. When valid history exists, `tnauqquant_pnl_history_current_value_usdt` exposes the latest bounded accumulated value for summary panels.

Unchanged logs reuse their mode-`0600` per-run summaries. New or changed logs alone are rescanned, and summaries remain after raw-log rotation so accumulated history does not reset. The output uses stable bounded `point` ordinals; timestamps are metric values rather than labels. It emits neither day-boundary zeroes nor a window baseline before the first supported event, so missing historical coverage is not rendered as zero PnL.

The build lock is stored under the private cache. A fresh lock prevents overlapping jobs; a lock older than 10 minutes is treated as crash/reboot residue and reclaimed. Raw-log basenames are immutable run identities: archive by moving a completed log out of the configured glob, and never copy or rename the same log to another `*.raw.log` name inside that glob, which would represent it as a second run.

If an in-glob copy or rename did occur, stop only `com.wanbrain.skyeye-trading-pnl-history`, move the duplicate raw log outside the glob, and move the matching `<basename>.events` plus `<basename>.meta` from the cache `runs/` directory into a private quarantine directory. Running the builder again reconstructs the output from the remaining summaries. Keep the quarantined files until the corrected Grafana total is verified; do not reset the entire cache, because summaries may be the only retained source for rotated runs.

Official references:

- [Install Alloy on macOS](https://grafana.com/docs/alloy/latest/set-up/install/macos/)
- [Configure Alloy on macOS](https://grafana.com/docs/alloy/latest/configure/macos/)
- [`loki.source.file`](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.file/)
- [`loki.process`](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.process/)
