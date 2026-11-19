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
| `deployment-linux-{robinhood,mainnet,ourbit,popdex,popdex-02}.env.example` | Credential-free Trading01 instance contracts (`popdex` is `popdex-btc` and `popdex-02` is the ETH lane, both on the PopDEX venue). `popdex-02` leaves `TQ_EXECUTABLE` and `TQ_EXECUTOR_MAP` empty until an operator verifies them on the host, so `setup-linux.sh` refuses it as checked in |
| `setup-linux.sh` | `add` (one-step install/update), `retire`, render-only, and explicit singleton migration |
| `retire-linux.sh` | Per-strategy retirement with an exact rollback record (run via `setup-linux.sh retire`) |
| `linux-common.sh` | Shared test-root, systemctl and path guards for the Linux scripts |
| `skyeye-trading-probe@.service.tmpl` | Linux per-strategy read-only oneshot probe |
| `skyeye-trading-probe@.timer.tmpl` | Linux per-strategy 15-second timer |
| `config-macos.alloy.tmpl` | Logfmt pipeline, source-side scrub, Loki push and Prometheus remote write |
| `deployment.env.example` | Complete host-specific deployment contract without real secrets |
| `probe.sh` | Read-only process/manifest/marker/log probe |
| `pnl-history.sh` | Incremental, cross-run accumulated Real P&L history builder |
| `setup-macos.sh` | Render, validate and install Alloy + launchd, applying only what changed, with rollback |
| `com.wanbrain.skyeye-trading-probe.plist.tmpl` | 15-second user launchd job |
| `com.wanbrain.skyeye-trading-pnl-history.plist.tmpl` | Independent 60-second history job |

The installers also need `../install-common.sh` and `../alloy-versions.env`, so copy the whole `agents/alloy` directory to a host. Both installers refuse an Alloy version that `alloy-versions.env` does not list (macOS: 1.18.1; Linux: 1.16.3, 1.18.1), and only one SkyEye install, retire or uninstall runs at a time on a host; see [Alloy versions](../README.md#alloy-versions) and [One run at a time](../README.md#one-run-at-a-time).

**Before re-running any installer on a host, check its Alloy version read-only** with `alloy --version | head -1`. If the version is not listed, stop and report it instead of re-running; do not use `SKYEYE_ALLOY_UNTESTED_VERSION` on a production host. The operator confirms each host's version before a rollout.

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

### What a Mac install or re-run does

`setup-macos.sh` stages every file next to its destination (`.NAME.staged.XXXXXX`, a name neither Alloy nor launchd loads), then checks the staged files: `bash -n` for both scripts, `plutil -lint` for both plists, and `alloy validate` on the staged `config.alloy` together with every other `*.alloy` in `$(brew --prefix)/etc/alloy`, because the brew service loads that whole directory. If any check fails, no live file or service is touched.

It then replaces only the files whose content or mode changed, and applies only what that needs:

| What changed | What it does to Alloy and launchd |
|---|---|
| Nothing | Prints `Already installed and running` and touches nothing |
| `config.alloy` only | `POST /-/reload`; Alloy keeps running and its environment |
| `config.env` or `extra-args.txt` since the last install, no record of them (the first run of this version of the script), or `--restart-alloy` | `brew services restart` |
| Alloy's brew service not loaded | Starts it |
| A plist, or a job that is not loaded | `bootout` (if loaded), `bootstrap`, `enable` for that job only |
| `probe.sh` or `pnl-history.sh` only | Nothing: the next run of the job executes the new file |

After a reload or (re)start it waits up to 60 seconds for `/-/ready` (at the `--server.http.listen-addr` in the current `extra-args.txt`, `127.0.0.1:12345` by default). If the reload is rejected, Alloy is not ready, or a job does not load, every replaced file is restored byte for byte and Alloy and the jobs are put back as they were (reload again, restart again, or stop). The exit code is then 1. If that rollback cannot finish, the exit code is 3 and a `CRITICAL: rollback_incomplete` message lists what to check.

`config.env` and `extra-args.txt` are yours: the installer never writes them and never keeps a copy, because `config.env` holds the service token. So when a run restarted Alloy because one of them changed, or because there is no record of them, and the install then fails, it cannot put Alloy back as it was. It restores its own files, restarts Alloy once more, and always exits 3 with `CRITICAL: rollback_incomplete`. The message says whether Alloy answers at the new address. It cannot check the old address. It also removes `installed-env.sha256`, so the next run restarts Alloy. To recover by hand, put `config.env` and `extra-args.txt` back the way Alloy last ran with them (or fix them), then run `brew services restart grafana/grafana/alloy` and check `curl -fsS http://<listen-addr>/-/ready`.

Every run that changes something prints `Rollback record: $(brew --prefix)/var/skyeye-trading/install-backup/<UTC>-<pid>/`, which holds the replaced files under `previous/`, with `present.list`, `absent.list` and `transaction.meta`. None of them holds a credential. A successful (re)start also records a hash of `config.env` and `extra-args.txt` in `$(brew --prefix)/var/skyeye-trading/installed-env.sha256`, so the next run knows whether a reload is enough.

`--no-start` installs files without applying them, so it runs only while Alloy and both launchd jobs are stopped, as on a new host. Anywhere else it refuses, because the files would go live at the next restart without anyone watching. Re-run without it instead; a config-only change is then a reload.

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
   `deployment-linux-*.env.example` and edited for the strategy. Check
   `alloy --version | head -1` first (see above); `add` refuses an unlisted
   version before it touches anything:

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
   An instance that is already installed keeps both facts about its probe
   timer, whether it is enabled at boot and whether it is running, while
   `add` updates its env or fragment, and the output says so. A timer someone
   disabled (for example a Mainnet probe) stays disabled. A timer that was
   enabled but stopped (`systemctl stop`) is enabled again without `--now`,
   and the probe does not run. A timer that was started but not enabled at
   boot is started again and stays not enabled. Only `--enable-probe` (not
   with `--no-start`) enables and starts a stopped or disabled instance, for
   example after an `add --no-start`. A new instance is always enabled and
   run once.
   Identity and path values (`TQ_STRATEGY`, `TQ_INSTANCE_ID`, the executable,
   config, log, manifest and textfile settings) must be literal `NAME=value`,
   `NAME="value"` or `NAME='value'` assignments with no `$`, backquote or
   backslash, because `retire` and sibling installs read them back without
   executing the env; `add` refuses anything else.
   It never starts, stops or signals a trading process: a Mainnet env with
   `TQ_POC_RUN_EXPECTED=0` gets only its read-only probe.
   A strategy the operator stopped on purpose sets `TQ_STRATEGY_DISABLED=1`
   in its env (default `0`). The probe then reports `run_expected=0` whatever
   `current.json` or the done marker says, so a stop that left a `running`
   manifest behind does not read as ProcessDown, and a process that starts
   anyway raises `TradingUnexpectedProcess`. Process, config, log and marker
   facts are still reported. `add` and the probe refuse any value other than
   `0` or `1`. Set it back to `0` with `add` before the strategy is started
   again.
   `TQ_BASE_ASSET` (default `BTC`) names the asset the strategy's position
   quantities are counted in, for example `ETH` for `popdex-02`. See
   [Position units](#position-units-tq_base_asset).
2. Repo:

   ~~~bash
   scripts/trading-target add --server SERVER_ID --strategy STRATEGY [--quote USDT] [--history]
   tests/trading/test-central-config.sh
   ~~~

   Commit, PR, merge. Tests derive their expectations from the inventory, so
   no test edits are needed.
3. Central, on monitoring-prod in `/home/ubuntu/SkyEye`: `scripts/central-deploy`
   (optionally `--dry-run` first). It validates the merged commit in a
   temporary worktree, including every dashboard and the Loki rules,
   fast-forwards, reloads Prometheus and prints the live `trading_target_info`
   rows. For a changed rule or dashboard it then waits for Loki and Grafana to
   load it, up to about 150 seconds; a dashboard change needs the Grafana token
   from [the one-time setup](../../../README.md#one-time-setup-for-scriptscentral-deploy).
   Glance at the fleet dashboard once. It records the last successfully applied
   commit in `.git/skyeye-central-deploy.applied`, so if a reload or a load
   fails, re-running the same command validates, reloads and confirms the
   checkout again (also the first run on a checkout updated by `git pull`). See
   [what it proves](../../../README.md#what-scriptscentral-deploy-proves).
   A change that needs a container recreate (such as `docker-compose.yml`) is
   refused when it differs from HEAD or from that record, so a `git pull` by
   hand cannot slip one past it. Apply it by hand (`docker compose up -d
   SERVICE`), then run `scripts/central-deploy --manual-applied TARGET_SHA`
   with the checkout at that commit; it validates, reloads and only then
   records the commit. It
   refuses untracked files under `prometheus/`, `alertmanager/`,
   `grafana/dashboards/`, `grafana/provisioning/` and `loki/rules/`, because
   those directories go live unvalidated; the only allowed local file there is
   `alertmanager/secrets/tg_token`.

**Remove** (central first, so `TradingTelemetryMissing` cannot fire):

1. Repo: `scripts/trading-target remove --server SERVER_ID --strategy STRATEGY`,
   then PR and merge.
2. Central: `scripts/central-deploy`.
3. Host: `sudo agents/alloy/trading/setup-linux.sh retire --strategy STRATEGY`.
   It validates `/etc/alloy` without the fragment, disables and stops only
   that probe, then moves its env, fragment, metrics file and any probe temp
   file still present (the set is taken after the probe stops) into
   `/etc/skyeye-trading/retired/STRATEGY-<UTC>/` (with `paths.list` and
   `retire.meta`) and reloads Alloy. Shared artifacts, sibling strategies,
   history and Loki data stay. It prints the `add --env-file` command that
   re-installs the archived env; re-running reports "Already retired".

**Move** a strategy to another server: finish every Remove step on the old
server, then run the Add steps on the new one. Strategy slugs must be unique
across servers, because fleet views key rows by strategy alone, so
`scripts/trading-target add` refuses the new server while the old row exists.
The strategy has no monitoring between the retire and the new probe.

Shared collector, units and `probe.sh` are rewritten only while every
templated probe is stopped and disabled; both commands refuse otherwise.

Adding `popdex-btc` to Trading01 also moves its Alloy off 1.16.0 and replaces
the shared probe under the running Robinhood and Mainnet probes; follow
[the Trading01 PopDEX rollout](../../../docs/trading01-popdex-rollout.md).

Adding `popdex-02` to Trading01 follows
[the popdex-02 onboarding](../../../docs/trading01-popdex-02-onboarding.md): the
lane is installed with `TQ_STRATEGY_DISABLED=1`, and two env values are filled
in on the host after a read-only check.

Re-running `setup-macos.sh` on the Mac mini (`macmini-m2`) to install the
current probe, P&L history builder and Trading log scrub, and pinning its Alloy
1.18.1 with `brew pin`, follows
[the Mac mini rollout](../../../docs/macmini-m2-alloy-rollout.md). Its first
run restarts Alloy once, because the host has no env record yet.

### Position units (`TQ_BASE_ASSET`)

The producer logs position quantities as `*_qty_btc` and the done marker as
`*_btc` on every lane, including lanes whose base asset is not BTC: the names
predate those lanes. The probe publishes the numbers as they are, in
`tnauqquant_current_position_btc` and `tnauqquant_current_net_position_btc`,
and those names do not change (history and queries depend on them). What the
number is counted in comes from the env:

- `TQ_BASE_ASSET`: one to 16 upper-case letters or digits, default `BTC` when
  unset or empty. `add` and the probe refuse any other form; a probe that
  refuses publishes nothing new, so its telemetry goes stale.
- The probe adds `base_asset="<value>"` to the two position metrics only. Every
  other series keeps its labels.
- The central recordings `trading_strategy_current_position_btc` and
  `trading_strategy_current_net_position_btc` keep `base_asset`, and record a
  series without it (a probe from before this setting, which only ran BTC
  lanes) as `BTC`.
- Strategy detail names the asset in each value of "目前持倉 · 多空方向"; the
  fleet table shows it in the "單位" column next to "淨部位". Quantities in
  different assets are never added together.

A lane is not BTC only if its env says so; nothing in SkyEye lists lanes by
asset. Today that is `popdex-02` (`TQ_BASE_ASSET=ETH` in its example).

**Rolling it out to a host.** The value only takes effect with a probe that
reads it, and `probe.sh` is shared by every templated probe on the host, so
`setup-linux.sh` replaces it only while every `skyeye-trading-probe@*` is
stopped and disabled (`shared probe artifacts changed` otherwise). On
Trading01 that is the stop-all procedure of
[the Trading01 PopDEX rollout](../../../docs/trading01-popdex-rollout.md),
Phase 3, run from a checkout that has this setting: before it, add
`TQ_BASE_ASSET=ETH` to the staged popdex-02 env (BTC lanes need no edit), then
`add` every strategy again with its own env and restore each timer to how it
was. The other probes publish nothing while they are stopped.

Order does not matter for correctness; each half alone looks like this:

- Host first, central not yet deployed: series carry `base_asset` and the
  current recordings already keep it, but the current panels drop it, so
  `popdex-02` still shows its ETH quantity under BTC, as before.
- Central first, host not yet updated: the recordings label every lane `BTC`
  (no probe sends the label yet), so the panels show `BTC` for `popdex-02` too,
  now spelled out per value. Nothing breaks; the ETH lane is still mislabelled
  until its host is updated.

Both done: `popdex-02` shows ETH and BTC lanes show BTC. A probe left on the
old version keeps showing BTC, which is right for every lane except a non-BTC
one.

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
tnauqquant trading service. `add` and `retire` restart Alloy during rollback
only when the run was given `--restart-alloy` (`add --no-start` leaves Alloy
alone). If the restoring reload also fails, the command exits non-zero with
the files and timer state restored, appends `alloy_recovery=reload_pending` to
the record and prints the remaining action: `sudo systemctl reload alloy`, or a
restart once interrupting every Alloy pipeline is acceptable.

## Secret and access requirements

- `config.env` must remain mode `0600` and outside Git.
- Use a service token dedicated to this host and restricted to the Loki/Prometheus push Access applications.
- Verify the Grafana Cloudflare email allowlist before pushing Trading PNL or raw errors.
- The Alloy template reads secrets at runtime with `sys.env`; it never renders them into `config.alloy` or the launchd plist.

## Source-side scrub contract

Both macOS and Linux pipelines scrub the complete log line before it reaches the Loki sink:

- order, client action and client order ID fields (`order_id`, `client_action_id`, and `client_id` with prefixes such as `ack_`, `bid_` and `ask_`, in snake or camel case) become `[ORDER_REF]`;
- attempt, reservation and recovery correlation fields become `[TRACE_REF]`;
- execution grant/mutation/account fields (`grant_id`, `mutation_id`, `mutations`, `account`) become `[EXECUTION_REF]`;
- repo paths, email addresses and tokens use their existing placeholders.

None of these values may become Loki labels. The complete Trading label budget remains `product`, `environment`, `server_id`, `strategy`, `run_id` and `level`. When reconciliation requires the original identifiers, inspect the source raw log under incident-handling authorization instead of weakening the central scrub.

## New server handoff

Another server agent changes environment values only:

- `TQ_ENVIRONMENT=production`
- `TQ_SERVER_ID=macmini-m2`
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
