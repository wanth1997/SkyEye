# Trading monitoring agent for macOS and Linux

This directory installs two source-host components:

- Grafana Alloy tails tnauqquant `*.raw.log` files, scrubs sensitive text, and pushes logs/metrics through Cloudflare Access.
- A 15-second launchd probe reads process/config/run state plus manifest-bound PNL events and writes `tnauqquant.prom` for Alloy's textfile collector.

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
| `setup-macos.sh` | Render, validate, install and optionally start Alloy + launchd |
| `com.wanbrain.skyeye-trading-probe.plist.tmpl` | 15-second user launchd job |

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
   alloy validate "$render_dir/config.alloy"
   ```

4. Install and start after the render validates:

   ```bash
   agents/alloy/trading/setup-macos.sh
   brew services list | grep alloy
   launchctl print "gui/$(id -u)/com.wanbrain.skyeye-trading-probe"
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
directory is setgid probe-user:alloy mode 2770; probe output is 0640.

To roll back, disable skyeye-trading-probe.timer, remove
/etc/alloy/trading.alloy, restore the printed /etc/default/alloy backup,
validate the remaining Alloy configuration, and restart Alloy. This rollback
does not touch the trading process.

## Secret and access requirements

- `config.env` must remain mode `0600` and outside Git.
- Use a service token dedicated to this host and restricted to the Loki/Prometheus push Access applications.
- Verify the Grafana Cloudflare email allowlist before pushing Trading PNL or raw errors.
- The Alloy template reads secrets at runtime with `sys.env`; it never renders them into `config.alloy` or the launchd plist.

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

Central labels, dashboard queries and rules must not be changed to accommodate a different filesystem path.

Before installation, return the non-secret handoff report from section 4.4 of `docs/trading-monitoring-development-plan.md`. Never include Cloudflare or exchange credentials.

## Troubleshooting

```bash
tail -n 100 "$(brew --prefix)/var/log/alloy/trading-probe.err.log"
launchctl print "gui/$(id -u)/com.wanbrain.skyeye-trading-probe"
brew services info grafana/grafana/alloy
curl -fsS http://127.0.0.1:12345/-/ready
```

The probe output must contain no PID or path labels. `run_id` is allowed only on the single bounded `tnauqquant_current_run_info` series:

```bash
sed -n '1,240p' "$(brew --prefix)/var/lib/alloy/trading-textfile/tnauqquant.prom"
```

Official references:

- [Install Alloy on macOS](https://grafana.com/docs/alloy/latest/set-up/install/macos/)
- [Configure Alloy on macOS](https://grafana.com/docs/alloy/latest/configure/macos/)
- [`loki.source.file`](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.file/)
- [`loki.process`](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.process/)
