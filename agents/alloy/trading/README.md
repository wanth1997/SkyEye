# Trading monitoring agent for macOS and Linux

This directory installs three source-host components:

- Grafana Alloy tails tnauqquant `*.raw.log` files, scrubs sensitive text, and pushes logs/metrics through Cloudflare Access.
- A 15-second launchd probe reads process/config/run state plus manifest-bound PNL events and writes `tnauqquant.prom` for Alloy's textfile collector.
- A separate 60-second launchd builder incrementally caches authoritative completed-cycle deltas across raw logs and writes the bounded `tnauqquant-pnl-history.prom` series used by the 30-day accumulated Real P&L chart.

Neither component starts, stops, signals, or attaches to the trading process.

## Files

| File | Purpose |
|---|---|
| config-linux.alloy.tmpl | Coexistence fragment that reuses an existing Linux Alloy deployment's central receivers |
| deployment-linux.env.example | Trading01/Lighter Linux contract without central credentials |
| setup-linux.sh | Render, validate and install the Alloy fragment plus systemd probe timer |
| skyeye-trading-probe.service.tmpl | Linux read-only oneshot probe |
| skyeye-trading-probe.timer.tmpl | 15-second Linux timer |
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
sink. It switches the existing Alloy service to directory mode and installs
/etc/alloy/trading.alloy, which references the existing central Prometheus and
Loki receivers. This preserves other product pipelines such as ZenIncome.

1. Copy and edit the non-secret environment contract:

   ~~~bash
   sudo install -d -m 755 /etc/skyeye-trading
   sudo install -m 600 agents/alloy/trading/deployment-linux.env.example \
     /etc/skyeye-trading/config.env
   ~~~

2. Render and validate without changing services:

   ~~~bash
   render_dir="$(mktemp -d /tmp/skyeye-trading-render.XXXXXX)"
   agents/alloy/trading/setup-linux.sh \
     --env-file /etc/skyeye-trading/config.env \
     --render-only "$render_dir"

   validate_dir="$(mktemp -d /tmp/skyeye-alloy-validate.XXXXXX)"
   cp /etc/alloy/*.alloy "$validate_dir/"
   cp "$render_dir/trading.alloy" "$validate_dir/"
   alloy validate "$validate_dir"
   ~~~

3. Install after the combined directory validates:

   ~~~bash
   sudo agents/alloy/trading/setup-linux.sh \
     --env-file /etc/skyeye-trading/config.env
   systemctl status alloy skyeye-trading-probe.timer
   journalctl -u skyeye-trading-probe.service -n 50 --no-pager
   ~~~

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

To roll back, disable skyeye-trading-probe.timer, remove
/etc/alloy/trading.alloy, restore the printed /etc/default/alloy backup,
validate the remaining Alloy configuration, and restart Alloy. This rollback
does not touch the trading process.

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
