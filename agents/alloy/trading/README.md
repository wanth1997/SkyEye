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
| `deployment-linux-{robinhood,mainnet,ourbit,popdex,popdex-02,popdex-multi-accounts}.env.example` | Credential-free Trading01 instance examples, including retired lanes. See `scripts/trading-target list` for the current inventory (`popdex` is `popdex-btc`, `popdex-02` is the ETH lane, and `popdex-multi-accounts` is the two-account random-rotation BTC lane on PopDEX). `popdex-02` leaves `TQ_EXECUTABLE` empty until an operator verifies it on the host, so `setup-linux.sh` refuses it as checked in; `popdex-multi-accounts` prefills `TQ_EXECUTABLE` and `TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex` for host verification |
| `setup-linux.sh` | `add` (one-step install/update), `retire`, `account` (per-strategy executor allowlist), render-only, and explicit singleton migration |
| `account-linux.sh` | Add, remove, or list executors (`TQ_EXECUTOR_MAP` only) on an installed Linux Trading lane (run via `setup-linux.sh account` or `scripts/trading-account`) |
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
   quantities are counted in, for example `ETH` for `popdex-02`; leave the
   line out for BTC. See [Position units](#position-units-tq_base_asset).
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

For the original Trading01 Alloy upgrade and shared probe replacement, see
[the Trading01 PopDEX rollout](../../../docs/trading01-popdex-rollout.md).

Adding `popdex-02` to Trading01 follows
[the popdex-02 onboarding](../../../docs/trading01-popdex-02-onboarding.md): the
lane is installed with `TQ_STRATEGY_DISABLED=1`, and `TQ_EXECUTABLE` is filled
in on the host after a read-only check.

Adding `popdex-multi-accounts` (two-account `routing.mode: random` PopDEX BTC
lane replacing `popdex-btc`) follows
[the popdex-multi-accounts onboarding](../../../docs/trading01-popdex-multi-accounts-onboarding.md).
Multi-account same-exchange lanes reuse the comma-separated `TQ_EXECUTOR_MAP`
syntax with distinct executors mapped to the same exchange (for example
`TQ_EXECUTOR_MAP=popdex-main=popdex,popdex-rot2=popdex`): strategy-level equity,
P&L, cycles, exchange volume and net position stay merged, and four
low-cardinality per-executor breakdown metrics
(`tnauqquant_current_executor_equity_usdt`,
`tnauqquant_current_executor_real_pnl_usdt`,
`tnauqquant_current_executor_cycles_completed`,
`tnauqquant_current_run_executor_volume_usd`) are emitted strictly for
allowlisted executors in `TQ_EXECUTOR_MAP`. Single-account and distinct-exchange
lanes keep identical behavior and `.prom` output. Because `probe.sh` is shared,
deploying this change to Trading01 stops and disables all
`skyeye-trading-probe@*` units first as described under
[Probe CPU limits and shared probe rollout](#probe-cpu-limits-and-shared-probe-rollout).

Re-running `setup-macos.sh` on the Mac mini (`macmini-m2`) to install the
current probe, P&L history builder and Trading log scrub, and pinning its Alloy
1.18.1 with `brew pin`, follows
[the Mac mini rollout](../../../docs/macmini-m2-alloy-rollout.md). Its first
run restarts Alloy once, because the host has no env record yet.

### Add or remove an account (executor)

For an already-installed **Linux** Trading lane (installed via `setup-linux.sh`
under `/etc/skyeye-trading/instances/<strategy>.env`), `skyeye-trading-probe@.service`
re-reads its `EnvironmentFile=` on every 15-second probe invocation, and Alloy
templates do not reference `TQ_EXECUTOR_MAP`. Prometheus recording rules and the
Grafana per-account breakdown table group dynamically by the `executor` label.
Adding or removing an account therefore only atomically updates
`TQ_EXECUTOR_MAP` in the instance env — **no repo PR, review, Alloy reload,
staged host checkout, or `scripts/central-deploy` is needed**.

> **Scope:** Linux Trading lanes installed via `setup-linux.sh` only (for
> example Trading01). macOS (Mac mini) and Windows lanes are out of scope.

Run one command from a local SkyEye checkout (or run
`sudo agents/alloy/trading/setup-linux.sh account ...` directly on the host):

~~~bash
# Read-only: inspect TQ_EXECUTOR_MAP and executors currently emitting .prom series
scripts/trading-account list --server trading01 --strategy popdex-multi-accounts

# Preview without touching the host
scripts/trading-account add --server trading01 --strategy popdex-multi-accounts \
  --executor popdex-rot3 --dry-run

# Add an executor on a single-exchange lane (--exchange is inferred automatically)
scripts/trading-account add --server trading01 --strategy popdex-multi-accounts \
  --executor popdex-rot3

# Add an executor with an explicit --exchange (required on multi-exchange lanes)
scripts/trading-account add --server trading01 --strategy popdex-multi-accounts \
  --executor popdex-rot3 --exchange popdex

# Remove an executor (refuses removing the last remaining executor)
scripts/trading-account remove --server trading01 --strategy popdex-multi-accounts \
  --executor popdex-rot3
~~~

Transport options on `scripts/trading-account`:

- Default remote mode: uploads only `account-linux.sh`, `linux-common.sh`, and
  `install-common.sh` to a mode-`0700` temporary directory under `/tmp` owned by
  the SSH user, executes `sudo <tmp>/.../account-linux.sh` (passing `ssh -t`
  when local stdin/stdout is an interactive TTY so passworded `sudo` can
  prompt), and removes the temporary directory on exit (reporting the account
  result and exact residual path separately if remote cleanup fails). Remote
  mode runs in that SSH user's private temporary directory under the assumption
  that the SSH account itself is not compromised.
- `--ssh-target HOST` (or `SKYEYE_SSH_TARGET`): SSH destination when it differs
  from `--server`.
- `--local`: run directly on the local Linux host without SSH.

**Required ordering with `tnauqquant`** (SkyEye never starts, stops, restarts,
or reads credentials/full configs of `tnauqquant@*`):

1. **Add an account**: run `scripts/trading-account add ...` **first** to add
   the executor to SkyEye's `TQ_EXECUTOR_MAP` allowlist, **then** add the
   account in `tnauqquant` config/env and restart the `tnauqquant` lane.
   (Adding SkyEye first prevents the probe from dropping the new account's
   volume or cycles once `tnauqquant` starts trading with it. Before
   `tnauqquant` restarts with the new account, `tnauqquant_current_executor_equity_usdt`
   stays fail-closed while strategy-level totals keep publishing normally.)
2. **Remove an account**: remove the account from `tnauqquant` config/env and
   restart the `tnauqquant` lane **first** so it stops trading on that executor,
   **then** run `scripts/trading-account remove ...` to drop it from SkyEye's
   allowlist. (Removing SkyEye first while `tnauqquant` still trades on that
   executor would drop that executor's volume from merged totals.)

**Built-in safety guards and verification:**

- Refuses mutating commands (`add`/`remove`) during **UTC 18:10–19:30**
  (checked at preflight, inside the host lock before backup, and again right
  before the atomic rename; rollback rename remains permitted in the window);
  read-only `list` remains available anytime.
- Serializes with `setup-linux.sh` / `retire-linux.sh` via the shared
  `/run/skyeye-alloy.lock` held from instance read through verification or
  rollback.
- Refuses missing instances, non-mode-`0600` or symlinked env files, duplicate
  or ambiguous `EnvironmentFile=` assignments (including leading whitespace),
  symlinked/non-regular/oversized (>4 MiB) `.prom` files, unreadable or missing
  systemd probe units, invalid names, duplicate adds, removing a missing or last
  executor, ambiguous exchange inference, or `--server` / `TQ_SERVER_ID`
  mismatch.
- Never modifies Alloy, Alloy fragments, `/etc/default/alloy`, ACLs, systemd
  units, or shared `probe.sh`.
- Backs up the existing env under `/etc/skyeye-trading/account-backup/`, edits
  only the single `TQ_EXECUTOR_MAP=` line (preserving every other byte and
  original line endings), and atomically replaces the instance env preserving
  owner/group and mode `0600`.
- **Active probe timer**: records the post-write probe invocation baseline so
  any in-flight probe started before the write is excluded, waits for a new
  timer-triggered probe run (default timeout 45s) with advancing
  `tnauqquant_probe_timestamp_seconds`, and checks executor labels on that same
  snapshot.
- **Inactive probe timer (disabled or stopped)**: preserves the timer state and
  verifies env content/mode and timer state only; live probe `.prom` output is
  not verified.
- Any verification failure, unexpected error, or interruption (`HUP`/`INT`/`TERM`)
  ignores subsequent `HUP`/`INT`/`TERM` signals while automatically restoring
  the backed-up env atomically and verifying the restore with `cmp`; if rollback
  itself cannot complete (or timer state cannot be verified), it exits `3` with
  exact manual recovery and verification commands.

**When you still need the full `trading-target` or shared probe workflow:**

- **New strategy or retiring a strategy**: use `scripts/trading-target add|remove`,
  `setup-linux.sh add|retire`, PR/merge, and `scripts/central-deploy` (see
  [Add or remove a Trading target](#add-or-remove-a-trading-target)).
- **Updating shared `probe.sh` or shared systemd unit templates**: stop and
  disable all `skyeye-trading-probe@*` units first as described in
  [Probe CPU limits and shared probe rollout](#probe-cpu-limits-and-shared-probe-rollout).
- **Changing Prometheus rules, dashboards, or alert routing**: PR/merge +
  `scripts/central-deploy`.

### Tighten an installed raw log glob

Every `deployment-linux-*.env.example` sets `TQ_RAW_LOG_GLOB` to
`DIR/[0-9]{8}_[0-9]{6}_<config stem>.raw.log` (written out as eight and six
`[0-9]`), the name the runtime contract gives a raw log. Envs installed from
older examples end in `*<config stem>.raw.log`, which also selects any file in
the directory whose name only ends the same way (`20261119_120000_foo_<stem>.raw.log`,
`backup_..._<stem>.raw.log`). The probe, `ensure-log-access.sh` and the Loki
fragment all take `TQ_RAW_LOG_GLOB` as written, so changing that one line and
re-running `add` changes all three. Installed envs are never rewritten from the
repo; this procedure does it on the host.

On Trading01 that is `lighter-robinhood-btc-canary` and `popdex-btc`. The
`popdex-02` example already uses the strict glob. The retired lanes' archived
envs under `/etc/skyeye-trading/retired/` keep the old glob: to re-onboard
`ourbit-spot` or `lighter-mainnet-btc-canary`, start from the current example
(or replace that line) instead of re-adding the archive verbatim.

`add` with an env that differs only in this line updates the env and the Loki
fragment in place, **reloads** Alloy and keeps the probe timer as it was. Each
`add` is its own transaction, so a lane that was added keeps the strict glob if
a later lane fails. The label set of the Loki target does not change, so Alloy
keeps its read position for files it already tails.

Run as root on Trading01 from a staged SkyEye checkout of the merge commit,
with the Alloy version checked (see above), all three steps in one `bash`
shell. Steps 1 and 3 check both lanes on every run, including a re-run after a
partial one; a lane whose env already has the strict glob is only left out of
the `add` in step 2. Nothing else on the host is touched.

1. Helpers and pre-check (read-only: reads the envs, manifests, file names and
   times and the probe textfiles, writes only `$WORK`):

   ~~~bash
   CHECKOUT=<checkout>; SETUP="$CHECKOUT/agents/alloy/trading/setup-linux.sh"
   . "$CHECKOUT/agents/alloy/trading/linux-common.sh"   # installed_env_value, as setup-linux.sh reads an env
   WORK=/root/skyeye-strict-glob-$(date -u +%Y%m%dT%H%M%SZ); install -d -m 700 "$WORK"
   LANES="lighter-robinhood-btc-canary popdex-btc"; INST=/etc/skyeye-trading/instances
   TEXT=/var/lib/skyeye-trading/textfile; D8='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
   v() { installed_env_value "$1" "$INST/$2.env"; }
   stem() { local c; c="$(v TQ_CONFIG_PATH "$1")" || return 1; c="${c##*/}"; printf '%s\n' "${c%.*}"; }
   logdir() { local g; g="$(v TQ_RAW_LOG_GLOB "$1")" || return 1; printf '%s\n' "${g%/*}"; }
   legacy() { printf '%s/*%s.raw.log\n' "$(logdir "$1")" "$(stem "$1")"; }
   strict() { printf '%s/%s_%s_%s.raw.log\n' "$(logdir "$1")" "$D8" "${D8%??????????}" "$(stem "$1")"; }
   newest() { compgen -G "$1" | while IFS= read -r f; do stat -c '%Y %n' "$f"; done | sort -n | tail -n 1 | cut -d' ' -f2-; }
   timer() { local e=disabled a=inactive
     systemctl is-enabled --quiet "skyeye-trading-probe@$1.timer" && e=enabled
     systemctl is-active --quiet "skyeye-trading-probe@$1.timer" && a=active; echo "$e/$a"; }
   ts() { awk 'index($1, "tnauqquant_probe_timestamp_seconds{") == 1 { printf "%d\n", $2 }' "$TEXT/tnauqquant-$1.prom"; }
   # The manifest names the newest lane log (by the old, wider pattern), the strict
   # glob selects it, and the probe's last sample is bound to that run.
   bound() {
     local s="$1" m n p b id
     m="$(jq -er '.log_path | strings | select(. != "")' "$(v TQ_RUN_MANIFEST "$s")" 2>/dev/null)" ||
       { echo "STOP: $s manifest is missing, unreadable or has no log_path"; return 1; }
     n="$(newest "$(legacy "$s")")"
     [ "$n" = "$m" ] || { echo "STOP: $s newest log ${n##*/} is not the manifest log ${m##*/}"; return 1; }
     compgen -G "$(strict "$s")" | grep -qxF "$m" || { echo "STOP: $s manifest log ${m##*/} does not match the strict glob"; return 1; }
     p="$(cat "$TEXT/tnauqquant-$s.prom")"   # one probe sample: the probe replaces the file whole
     b="$(awk 'index($1, "tnauqquant_log_binding_ok{") == 1 { print $2 }' <<<"$p")"
     id="$(sed -n 's/^tnauqquant_current_run_info{.*run_id="\([^"]*\)"}.*/\1/p' <<<"$p")"
     [ "$b" = 1 ] && [ "$id.raw.log" = "${m##*/}" ] ||
       { echo "STOP: $s probe sample has log_binding_ok=${b:-none} run_id=${id:-none}, manifest log ${m##*/}"; return 1; }
     echo "$s bound ${m##*/}"
   }
   # A run that rotates between the reads above is observed again, up to three times.
   again() { local i out; for i in 1 2 3; do out="$("$@")" && { echo "$out"; return 0; }; [ "$i" = 3 ] || sleep 20; done; echo "$out"; return 1; }
   for s in $LANES; do
     g="$(v TQ_RAW_LOG_GLOB "$s")" && [ -n "$g" ] && st="$(stem "$s")" && [ -n "$st" ] ||
       { echo "STOP: $s env has no readable TQ_RAW_LOG_GLOB or TQ_CONFIG_PATH"; continue; }
     case "$g" in
       "$(strict "$s")") action=ALREADY-STRICT ;;
       "$(legacy "$s")") action=APPLY ;;
       *) echo "STOP: $s has TQ_RAW_LOG_GLOB=$g, neither the old nor the strict form"; continue ;;
     esac
     ok=1
     again bound "$s" || ok=0
     while IFS= read -r f; do
       if [ $(( $(date +%s) - $(stat -c %Y "$f") )) -lt 86400 ]; then
         echo "STOP: $s would drop ${f##*/}, modified in the last 24h"; ok=0
       else echo "$s drops ${f##*/} (older than 24h)"; fi
     done < <(comm -23 <(compgen -G "$(legacy "$s")" | sort) <(compgen -G "$(strict "$s")" | sort))
     echo "$s timer $(timer "$s")"
     [ "$ok" = 1 ] && echo "$s PRECHECK-OK $action"
   done | tee "$WORK/precheck.out"
   ~~~

   Go on only if both lanes print `PRECHECK-OK` (`APPLY` or `ALREADY-STRICT`)
   and no line starts with `STOP`. If step 1 is interrupted, rerun step 1 from
   the start. Any `STOP`: change nothing and report the output. Do not widen
   the strict glob or rename a log to make it pass; a newest log the strict
   glob misses means the producer writes names outside the contract, which is a
   tnauqquant question. A `drops ... (older than 24h)` line is expected only
   for a stray file; list it in the report.

2. Apply. Each env copy differs from the installed one in that one line; `add`
   runs without `--enable-probe` so the timer keeps its state:

   ~~~bash
   ready=1
   [ -s "$WORK/precheck.out" ] && ! grep -q '^STOP' "$WORK/precheck.out" || ready=0
   for s in $LANES; do
     [ "$(grep -c -Fx -e "$s PRECHECK-OK APPLY" -e "$s PRECHECK-OK ALREADY-STRICT" "$WORK/precheck.out" 2>/dev/null)" = 1 ] || ready=0
   done
   if [ "$ready" != 1 ]; then echo "STOP: pre-check did not complete cleanly for both lanes; rerun step 1 from the start; nothing applied"; else
   failed=0
   for s in $LANES; do
     if [ "$failed" = 1 ]; then echo "RESULT $s NOT_ATTEMPTED"; continue; fi
     if grep -qxF "$s PRECHECK-OK ALREADY-STRICT" "$WORK/precheck.out"; then echo "RESULT $s not added (already strict)"; continue; fi
     grep -qxF "$s PRECHECK-OK APPLY" "$WORK/precheck.out" || { echo "RESULT $s STOP: missing APPLY result; not added"; failed=1; continue; }
     install -m 600 "$INST/$s.env" "$WORK/$s.env.before"
     (umask 077; NEW="$(strict "$s")" awk 'index($0, "TQ_RAW_LOG_GLOB=") == 1 { print "TQ_RAW_LOG_GLOB=" ENVIRON["NEW"]; next } { print }' \
       "$WORK/$s.env.before" >"$WORK/$s.env")
     [ "$(diff "$WORK/$s.env.before" "$WORK/$s.env" | grep -c '^[<>]')" = 2 ] ||
       { echo "RESULT $s STOP: the env copy changed more than one line; not added"; failed=1; continue; }
     "$SETUP" add --env-file "$WORK/$s.env" </dev/null 2>&1 | tee "$WORK/add-$s.out"; rc=${PIPESTATUS[0]}
     if [ "$rc" = 0 ] && grep -q '^Alloy action: reload' "$WORK/add-$s.out"; then echo "RESULT $s added"; continue; fi
     rec="$(sed -n 's/^Rollback record: //p' "$WORK/add-$s.out" | tail -n 1)"
     if grep -q "restoring 'systemctl reload alloy' failed" "$WORK/add-$s.out" ||
       { [ -n "$rec" ] && grep -qx 'alloy_recovery=reload_pending' "$rec/transaction.meta" 2>/dev/null; }; then
       echo "RESULT $s FAILED rc=$rc reload_pending: Alloy may still run the failed config"
     else
       echo "RESULT $s FAILED rc=$rc"
     fi
     failed=1
   done | tee "$WORK/apply.out"; fi
   ~~~

   Report every `RESULT` line: it is that lane's outcome (including
   `NOT_ATTEMPTED` for any lane after a failure), and a lane `added` before a
   later failure stays on the strict glob. On `FAILED`, report the `rc` and any
   `reload_pending` text; do not assume rollback restored the timer — step 3's
   observed timer state is the evidence. `FAILED ... reload_pending` means the
   restoring reload failed and Alloy may still run the configuration of the
   failed attempt; report that before anything else, as the `add` output names
   the remaining recovery action. `shared probe artifacts changed` means the
   checkout's `probe.sh` or units differ from the installed ones; this
   procedure does not stop the other probes, so report it and do not switch to
   the stop-every-probe update under
   [Position units](#position-units-tq_base_asset). Do not re-run with
   `--restart-alloy` and do not `retire` anything to recover. After any
   `RESULT`, including a failure, run step 3 and report its output too.

3. Post-check, for both lanes. The probe timer fires every 15 seconds; each
   lane needs two probe runs after its `add`, at least 15 seconds apart:

   ~~~bash
   fresh() { local a=$(( $(date +%s) - $1 )); [ "${a#-}" -lt 60 ]; }
   sleep 20
   for s in $LANES; do
     g="$(v TQ_RAW_LOG_GLOB "$s")"
     [ "$g" = "$(strict "$s")" ] || echo "STOP: $s env still has TQ_RAW_LOG_GLOB=$g"
     grep -qF "\"$g\"" "/etc/alloy/trading-$s.alloy" || echo "STOP: $s Loki fragment does not tail its env's glob"
     tm="$(timer "$s")"; echo "$s timer $tm"
     [ "$s timer $tm" = "$(grep "^$s timer " "$WORK/precheck.out")" ] || echo "STOP: $s timer changed to $tm"
     since="$(stat -c %Y "$WORK/add-$s.out" 2>/dev/null || stat -c %Y "$WORK/precheck.out")"
     t1="$(ts "$s")"; f1=0; [ -n "$t1" ] && fresh "$t1" && f1=1
     sleep 20; t2="$(ts "$s")"
     [ "$f1" = 1 ] && [ "$t1" -gt "$since" ] && [ -n "$t2" ] && [ $(( t2 - t1 )) -lt 15 ] && { sleep 20; t2="$(ts "$s")"; }
     [ "$f1" = 1 ] && [ -n "$t2" ] && [ "$t1" -gt "$since" ] && [ $(( t2 - t1 )) -ge 15 ] && fresh "$t2" ||
       echo "STOP: $s probe timestamps ${t1:-none} then ${t2:-none} are not two fresh runs >=15s apart after $since"
     again bound "$s"
     m="$(newest "$g")"
     getfacl -cp -- "$m" 2>/dev/null | grep -q "^user:$(v TQ_ALLOY_USER "$s"):r" || echo "STOP: $s Alloy has no read ACL on ${m##*/}"
     # The last complete line of the newest log strictly after SINCE's second (epoch ns), none, or ERROR <why>.
     if [ -z "$m" ] || ! b="$(tail -c 65536 "$m" && printf .)"; then
       echo "loki_event $s ERROR tail_failed"
     else
       b="${b%.}"
       case "$b" in *$'\n') line="${b%$'\n'}" ;; *$'\n'*) line="${b%$'\n'*}" ;; *) line= ;; esac
       if [[ "$b" != *$'\n'* ]]; then
         echo "loki_event $s none"
       else
         t="$(grep -oE '(^|[[:space:]])time=[^[:space:]]+' <<<"${line##*$'\n'}" | head -n 1 | sed -E 's/^[[:space:]]*time=//; s/"//g')"
         if [ -z "$t" ] || ! n="$(date -u -d "$t" +%s%N 2>/dev/null)" || [[ ! "$n" =~ ^[0-9]+$ ]]; then
           echo "loki_event $s ERROR unparseable_time"
         elif [ $(( n / 1000000000 )) -gt "$since" ]; then
           echo "loki_event $s $n"
         else
           echo "loki_event $s none"
         fi
       fi
     fi
   done | tee "$WORK/postcheck.out"
   journalctl -u alloy --since "@$(stat -c %Y "$WORK/precheck.out")" --no-pager | grep -E 'level=(error|warn)' | tail -n 20
   ~~~

   Every lane must print `timer`, `bound` and a `loki_event` line (without
   `ERROR`) and no `STOP`, and the `journalctl` line should print nothing about
   a `skyeye_trading_` component. Then on monitoring-prod (read-only), at least
   60 seconds later, define `loki_event` and paste the two `loki_event ...`
   lines as printed:

   ~~~bash
   curl -fsS --get http://127.0.0.1:9090/api/v1/query --data-urlencode \
     'query=abs(time() - tnauqquant_probe_timestamp_seconds{server_id="trading01",strategy=~"lighter-robinhood-btc-canary|popdex-btc"}) < 180' |
     jq -c '[.data.result[].metric.strategy] | sort'
   loki_event() {
     local n
     case "$2" in
       ERROR) echo "LOKI-ERROR $1: source ${3:-error}"; return ;;
       none) echo "LOKI-PENDING $1: no source log line after the add cutoff"; return ;;
       '' | *[!0-9]*) echo "LOKI-ERROR $1: invalid timestamp $2"; return ;;
     esac
     n="$(curl -fsS --get http://127.0.0.1:3100/loki/api/v1/query_range \
       --data-urlencode "query={product=\"tnauqquant\",server_id=\"trading01\",strategy=\"$1\"}" \
       --data-urlencode "start=$(( $2 - 1000000000 ))" --data-urlencode "end=$(( $2 + 1000000000 ))" \
       --data-urlencode limit=5000 | jq -r --arg ns "$2" '[.data.result[].values[] | select(.[0] == $ns)] | length')"
     case "$n" in '' | *[!0-9]*) echo "LOKI-ERROR $1" ;; 0) echo "LOKI-MISSING $1: no line at $2" ;; *) echo "LOKI-ACCEPTED $1" ;; esac
   }
   ~~~

   The first command must print both strategies (the `TradingTelemetryMissing`
   comparison). `LOKI-ACCEPTED` means Loki has the source line written after
   the `add` cutoff second. `LOKI-PENDING`: the lane wrote no complete line
   strictly after that second, which is not an Alloy fault; re-run step 3's
   lane loop and paste again after 2 minutes, up to three times in all, then
   record it as pending and report. `LOKI-MISSING` after three tries means the
   lane writes but Loki does not receive it: report it with step 3's output.
   `LOKI-ERROR`: the source read/parse or the Loki query failed; report it.

Rollback for one lane: `"$SETUP" add --env-file "$WORK/<lane>.env.before"`,
the untouched copy from step 2. It restores the old line in place the same way
(Alloy reload, timer kept).

### Position units (`TQ_BASE_ASSET`)

The producer logs position quantities as `*_qty_btc` and the done marker as
`*_btc` on every lane, including lanes whose base asset is not BTC: the names
predate those lanes. The probe publishes the numbers as they are, in
`tnauqquant_current_position_btc` and `tnauqquant_current_net_position_btc`,
and neither those names nor their `# HELP` text change (history, queries and a
shared textfile collector depend on them). What the number is counted in comes
from the env:

- `TQ_BASE_ASSET`: one to 16 ASCII upper-case letters or digits
  (`ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789`, whatever the locale). With no
  `TQ_BASE_ASSET` line the lane is `BTC`. A line with an empty value, any
  other character (lower case, full-width `ＥＴＨ`, punctuation) or a form
  other than a literal `TQ_BASE_ASSET=VALUE` (`export TQ_BASE_ASSET=…`,
  `TQ_BASE_ASSET=$VAR`) is refused by `setup-linux.sh` render and `add`
  before anything is written. systemd reads the file without a shell, so
  only the literal form reaches the probe as written.
- The probe refuses an empty or invalid value too; a probe that refuses
  publishes nothing new, so its telemetry goes stale. `setup-macos.sh` does
  not check the value: leave it out on Mac lanes (they are BTC). An invalid
  value there makes every probe run fail.
- The probe adds `base_asset="<value>"` to the two position metrics only. Every
  other series keeps its labels.
- The central recordings `trading_strategy_current_position_btc` and
  `trading_strategy_current_net_position_btc` keep `base_asset`. A raw series
  without it comes from a probe older than this setting, which cannot say what
  it counts in; the recording calls it `BTC`. That is right for BTC lanes and
  wrong for a non-BTC lane, which is why hosts go first (below).
- Strategy detail names the asset in each value of "目前持倉 · 多空方向"; the
  fleet table shows it in the "單位" column next to "淨部位". Quantities in
  different assets are never added together.

A lane is not BTC only if its env says so; nothing in SkyEye lists lanes by
asset. Today that is `popdex-02` (`TQ_BASE_ASSET=ETH` in its example).

**Order: hosts with a non-BTC lane first, central after.** `scripts/central-deploy`
deploys the latest `origin/master`, so once this change is merged nobody runs it
(for any change) until step 6 below has passed on Trading01. If central goes
first, the recordings store the non-BTC lane's quantities as `base_asset="BTC"`
until its host runs the new probe; Prometheus keeps those samples, so that
stretch of `popdex-02` history reads BTC on both dashboards until it ages out
of retention. For that stretch read the raw `tnauqquant_current_*position_btc`
series and count them as ETH. Host first has no such window: the current
central recordings already keep the label, and the current panels drop it and
show the old BTC unit, as before.

**Updating Trading01.** `probe.sh` is shared by every templated probe on the
host, so `setup-linux.sh` replaces it only while every `skyeye-trading-probe@*`
is stopped and disabled (`shared probe artifacts changed` otherwise). Run as
root from a staged checkout of the merge commit, with the Alloy version checked
(see above) and outside UTC 18:15–19:30. The other lanes' probes publish
nothing between steps 2 and 4.

1. Record each probe timer's state and the start time:

   ~~~bash
   SETUP=<checkout>/agents/alloy/trading/setup-linux.sh
   WORK=/root/skyeye-base-asset-$(date -u +%Y%m%dT%H%M%SZ); install -d -m 700 "$WORK"
   date +%s >"$WORK/start-epoch"
   for env in /etc/skyeye-trading/instances/*.env; do
     s="$(basename "$env" .env)"; e=disabled; a=inactive
     systemctl is-enabled --quiet "skyeye-trading-probe@$s.timer" && e=enabled
     systemctl is-active --quiet "skyeye-trading-probe@$s.timer" && a=active
     printf '%s %s %s\n' "$s" "$e" "$a"
     install -m 600 "$env" "$WORK/$s.env"
   done | tee "$WORK/timers.before"
   ~~~

2. Stop and disable every one of them, then confirm none is enabled or active:

   ~~~bash
   while read -r s _ _ <&3; do
     systemctl disable --now "skyeye-trading-probe@$s.timer"
     systemctl stop "skyeye-trading-probe@$s.service"
   done 3<"$WORK/timers.before"
   systemctl is-active --quiet 'skyeye-trading-probe@*' && echo "STOP: a probe is still active"
   systemctl is-enabled --quiet 'skyeye-trading-probe@*.timer' && echo "STOP: a probe timer is still enabled"
   ~~~

   Any `STOP`: do not go on to step 3; restore the timers as in step 4.

3. Add `TQ_BASE_ASSET=ETH` to the popdex-02 copy only (BTC lanes get no line),
   then `add` every existing strategy with its own env from the new checkout.
   A timer recorded `enabled active` gets `--enable-probe`; any other state is
   added without it:

   ~~~bash
   printf 'TQ_BASE_ASSET=ETH\n' >>"$WORK/popdex-02.env"
   while read -r s e a <&3; do
     flag=; [ "$e $a" = "enabled active" ] && flag=--enable-probe
     "$SETUP" add --env-file "$WORK/$s.env" $flag </dev/null 2>&1 | tee "$WORK/add-$s.out"
     [ "${PIPESTATUS[0]}" = 0 ] || { echo "STOP: add $s failed"; break; }
   done 3<"$WORK/timers.before"
   ~~~

   Any `STOP` or `Alloy action: restart`: stop here and report. Do not
   `retire` anything to recover.
4. Put every timer back as step 1 recorded it. After a full step 3 the
   `enabled active` ones are already back; any that is not (or after a STOP)
   gets `systemctl enable --now skyeye-trading-probe@<s>.timer`. A timer
   recorded `enabled inactive` gets `systemctl enable` without `--now`; a
   `disabled` one stays disabled. Run step 1's loop again into
   `$WORK/timers.after` (it rewrites the env copies, which is harmless) and
   `diff` it with `timers.before`: no output.
5. Check every textfile was rewritten by the new probe. Each instance recorded
   `enabled active` (all four on Trading01 today) must show a modification time
   after `start-epoch`, and `popdex-02`'s file, if it has position series, must
   carry `base_asset="ETH"`:

   ~~~bash
   start=$(cat "$WORK/start-epoch"); sleep 30
   for f in /var/lib/skyeye-trading/textfile/tnauqquant-*.prom; do
     printf '%s %s\n' "$f" "$([ "$(stat -c %Y "$f")" -gt "$start" ] && echo NEW || echo OLD)"
   done
   grep -h '^tnauqquant_current_.*position_btc{' /var/lib/skyeye-trading/textfile/tnauqquant-*.prom
   ~~~

   An `OLD` file of an `enabled active` instance: report it before step 6.
6. On central, before `scripts/central-deploy`, query
   `count by (strategy, base_asset) (tnauqquant_current_net_position_btc{server_id="trading01"})`:
   every lane with a position shows its `base_asset`, `popdex-02` as `ETH`.
   If `popdex-02` has no position series yet (the lane has not run), there is
   nothing to mislabel; step 5's `NEW` for its file is enough. Then deploy
   central.

[The Trading01 PopDEX rollout](../../../docs/trading01-popdex-rollout.md)
stopped and restored the probes the same way, but its lane list, new-lane `add`
and R3 rollback (which retires `popdex-btc`) belong to that onboarding only and
do not apply here.

### Probe CPU limits and shared probe rollout

`probe.sh` is stateless: it keeps no offset or cache file on disk, so every 15-second run computes metrics directly from the raw logs and needs no manual cache reset. To keep per-run CPU low on full-day logs, it reads the active manifest log once through `LC_ALL=C grep -a -n -F` (`pnl_status`, `ui_warmup_async_ready`, `coordinator_book` and `trade_status`) into one `awk` pass and reuses that pass for `tnauqquant_completed_cycles_today`.

`skyeye-trading-probe@.service.tmpl` sets `Nice=10`, `CPUWeight=20` and `CPUQuota=20%` per instance (4 lanes = up to 80% of one core in aggregate on a 2-vCPU host) so probe runs yield to `tnauqquant` trading processes. On Ubuntu (`mawk` + GNU `grep`), a synthetic full-day log matching `popdex-02` (~54 MiB / 80k lines) runs in 0.279 CPU-s (~1.4s probe-script wall-time estimate under `CPUQuota=20%`), and a 205 MiB / 300k-line log runs in ~1.24 CPU-s (~6.2s probe-script wall-time estimate under `CPUQuota=20%`); total unit duration (including `ExecStartPre`) is measured during the rollout.

**Rolling out shared `probe.sh` and `skyeye-trading-probe@.service` changes on Trading01.** Both files are shared by every templated probe, so `setup-linux.sh` refuses to replace them while any `skyeye-trading-probe@*` service or timer is active or enabled. Run as `root` outside UTC 18:15–19:30, after checking `alloy --version | head -1`:

1. Record every installed strategy's timer state (`enabled`/`active`), copy `/etc/skyeye-trading/instances/*.env` into a mode-`0700` work directory (`$WORK`), and record `start-epoch` (same loop as step 1 under [Position units](#position-units-tq_base_asset)).
2. Stop and disable all `skyeye-trading-probe@*.timer` and stop all `skyeye-trading-probe@*.service`; verify neither `systemctl is-active --quiet 'skyeye-trading-probe@*'` nor `systemctl is-enabled --quiet 'skyeye-trading-probe@*.timer'` succeeds.
3. Re-run `setup-linux.sh add --env-file "$WORK/$s.env"` for each strategy (passing `--enable-probe` only for lanes recorded `enabled active`). The first `add` replaces the shared `probe.sh` and `skyeye-trading-probe@.service`, runs `systemctl daemon-reload`, and reloads Alloy (`Alloy action: reload`). No one-time cleanup is needed.
4. Restore any non-`enabled active` timers from `timers.before` and confirm `diff timers.before timers.after` is empty.
5. Verify limits and freshness after two timer intervals (~35s):
   - `systemctl show skyeye-trading-probe@<s>.service -p Nice -p CPUWeight -p CPUQuotaPerSecUSec` shows `Nice=10`, `CPUWeight=20`, `CPUQuotaPerSecUSec=200ms`.
   - Every active lane's `/var/lib/skyeye-trading/textfile/tnauqquant-<s>.prom` has mtime after `start-epoch` and `tnauqquant_probe_timestamp_seconds` advances every ~15s.

**Rollback:** stop and disable all `skyeye-trading-probe@*.timer` and stop all `skyeye-trading-probe@*.service` (do not disable the service units), re-run `setup-linux.sh add` per strategy from the previous `origin/master` checkout (or restore `probe.sh` and `skyeye-trading-probe@.service` from the rollback record printed by the first `add` and run `systemctl daemon-reload`), then restore timers from `timers.before`. Neither rollout nor rollback touches any trading process or central config.

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
