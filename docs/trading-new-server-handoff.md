# TNAUQQuant server monitoring handoff

This is the self-contained, non-secret contract for production Trading hosts. The original section covers the two-exchange macOS target; the Linux coexistence section covers Trading01 and future hosts with an existing Alloy pipeline.

## Fixed identities

| Field | Production value |
|---|---|
| `product` | `tnauqquant` |
| `environment` | `production` |
| `server_id` | `tnauqquant-prod-1` |
| `strategy` | `toobit-mexc-btc` |
| launch mode | `scripts/tq live run --human <config>` inside operator tmux |
| auto-restart | disabled |
| primary PNL | latest `stable=true` `real_pnl_usdt` |
| Alloy version | the development-accepted version; record exact output |

Paths are intentionally not fixed. A different username or repo root changes only the host deployment env, never central labels, rules or dashboard queries.

## Prerequisites

- Trading checkout contains merge `fd317b51c3b617a8bf9b9f04e692649a45acf4c4` or a descendant.
- The untracked Trading `.env` sets `TQ_STRATEGY=toobit-mexc-btc`.
- The canonical Trading launcher creates `run-state/toobit-mexc-btc/current.json` and `current.done.json` using schema v1.
- A host-specific Cloudflare service token is authorized only for `prom-push` and `loki-push`; do not include it in the report or Git.
- The SkyEye operator has registered `tnauqquant-prod-1` centrally in shadow mode.

## Required report before changes

Return the following outputs with home/repo paths left intact, but with no credentials, account IDs or order payloads:

```bash
sw_vers
uname -m
brew --prefix
alloy --version
git -C "$TQ_REPO_ROOT" rev-parse HEAD
realpath "$TQ_REPO_ROOT"
realpath "$TQ_CONFIG_PATH"
shasum -a 256 "$TQ_CONFIG_PATH"
ls -ld "$(dirname "$TQ_RAW_LOG_GLOB")" "$(dirname "$TQ_RUN_MANIFEST")"
```

Also report the config `instance_id`, sidecar tmux session name, sidecar identity-file path and loopback health URL. Do not print `.env`.

## Host deployment env

Copy `agents/alloy/trading/deployment.env.example` to `$(brew --prefix)/etc/alloy/config.env`, mode `0600`, then set:

```text
TQ_ENVIRONMENT=production
TQ_SERVER_ID=tnauqquant-prod-1
TQ_STRATEGY=toobit-mexc-btc
TQ_REPO_ROOT=/Users/wan/projects/tnauqquant
TQ_REPO_ROOT_REGEX=(/Users/wan/projects/tnauqquant)
TQ_EXECUTABLE=/Users/wan/projects/tnauqquant/quant
TQ_CONFIG_PATH=/Users/wan/projects/tnauqquant/config/toobit-mexc.conf
TQ_RAW_LOG_GLOB=/Users/wan/projects/tnauqquant/logs/live-runs/*.raw.log
TQ_RUN_MANIFEST=/Users/wan/projects/tnauqquant/run-state/toobit-mexc-btc/current.json
TQ_DONE_MARKER=/Users/wan/projects/tnauqquant/run-state/toobit-mexc-btc/current.done.json
TQ_INSTANCE_ID=mexc-toobit-btc-initiator-hedge
TQ_SIDECAR_SESSION=goexchange-sidecar
TQ_SIDECAR_IDENTITY_FILE=/Users/wan/projects/tnauqquant/logs/sidecar-runtime.identity
TQ_SIDECAR_HEALTH_URL=http://127.0.0.1:3457/health
TQ_REQUIRE_RUNTIME_CONTRACT=1
TQ_TIMEZONE=Asia/Taipei
```

Keep `TQ_POC_RUN_EXPECTED=1` only as the expected-state default. Production requires the manifest/marker contract and never selects a current run by log mtime.

## Installation and validation

```bash
cd <SkyEye checkout>
chmod 600 "$(brew --prefix)/etc/alloy/config.env"
render_dir=$(mktemp -d "${TMPDIR:-/tmp}/skyeye-trading-render.XXXXXX")
agents/alloy/trading/setup-macos.sh --render-only "$render_dir"
plutil -lint "$render_dir/com.wanbrain.skyeye-trading-probe.plist"
alloy validate "$render_dir/config.alloy"
agents/alloy/trading/setup-macos.sh --no-start
```

After the SkyEye operator approves the report and access policy, run the installer without `--no-start`. It starts only Alloy and the read-only probe.

Verify within 30 seconds:

```bash
brew services info grafana/grafana/alloy
launchctl print "gui/$(id -u)/com.wanbrain.skyeye-trading-probe"
sed -n '1,240p' "$(brew --prefix)/var/lib/alloy/trading-textfile/tnauqquant.prom"
```

Central acceptance requires logs, probe metrics, stable Real PNL equality, correct Running/Completed/Critical state, path scrubbing and zero external notifications while shadowed. Observe one complete Trading cycle before requesting paging.

## Linux coexistence target: Trading01

| Field | Value |
|---|---|
| `product` | `tnauqquant` |
| `environment` | `production` |
| `server_id` | `trading01` |
| `strategy` / `instance_id` | `lighter-robinhood-btc-canary`; `lighter-mainnet-btc-canary` |
| executor mapping | `lighter-robinhood-main=lighter`; `lighter-mainnet-main=lighter` |
| sidecar required | `0` |
| repo root | `/home/ubuntu/tnauqquant` |

Trading01 already runs Alloy for ZenIncome. Do not run the generic Linux installer that overwrites `/etc/alloy/config.alloy`, and do not define another central remote-write or Loki sink. Copy the two `deployment-linux-{robinhood,mainnet}.env.example` files to private mode-`0600` staging paths, verify their dedicated executable/config/log/manifest bindings, then render both coexistence instances:

```bash
render_dir="$(mktemp -d /tmp/skyeye-trading-render.XXXXXX)"
agents/alloy/trading/setup-linux.sh \
  --env-file /tmp/lighter-robinhood-btc-canary.env \
  --render-only "$render_dir/robinhood"
agents/alloy/trading/setup-linux.sh \
  --env-file /tmp/lighter-mainnet-btc-canary.env \
  --render-only "$render_dir/mainnet"

validate_dir="$(mktemp -d /tmp/skyeye-alloy-validate.XXXXXX)"
sudo cp /etc/alloy/*.alloy "$validate_dir/"
rm -f "$validate_dir/trading.alloy"
cp "$render_dir/robinhood/trading-metrics.alloy" "$validate_dir/"
cp "$render_dir/robinhood/trading-lighter-robinhood-btc-canary.alloy" "$validate_dir/"
cp "$render_dir/mainnet/trading-lighter-mainnet-btc-canary.alloy" "$validate_dir/"
alloy validate "$validate_dir"
```

The first install uses `--migrate-singleton --no-start`; the second uses `--no-start`. The installer changes Alloy's `CONFIG_FILE` to `/etc/alloy`, installs a shared textfile fragment plus two exact Loki fragments, and adds only read-only `skyeye-trading-probe@STRATEGY` systemd templates. It validates the combined directory and prints an exact rollback record without restarting Alloy. The textfile directory is setgid `ubuntu:alloy` mode `2770`, each strategy output is `0640`, and Alloy receives only the ACL permissions needed to discover/read each exact raw-log glob. Mainnet begins with `TQ_POC_RUN_EXPECTED=0`; monitoring it does not start the strategy.

Before and after installation record:

```bash
pgrep -af '/home/ubuntu/tnauqquant/quant' || true
tmux list-panes -a -F '#{session_name} #{pane_pid} #{pane_current_command}'
systemctl is-active alloy
systemctl is-active \
  skyeye-trading-probe@lighter-robinhood-btc-canary.timer \
  skyeye-trading-probe@lighter-mainnet-btc-canary.timer
find /var/lib/skyeye-trading/textfile -maxdepth 1 -type f -name 'tnauqquant-*.prom' -print
```

The installer must not start, stop, or restart the trading process. If `current.json` still says `running` after that process exited and no bound done marker exists, leave the files unchanged: SkyEye should surface ProcessDown and stale telemetry in shadow mode.

## Rotation, revocation and retirement

- Rotate a token by authorizing a new token for the two push apps, replacing only this host's `config.env`, restarting Alloy and verifying both streams before revoking the old token.
- On retirement, first change/remove the target inventory and rules so `TradingTelemetryMissing` cannot page, then stop Alloy/probe, revoke the host token and archive host state.
- Never reuse the development token on production or leave the development target active after that Mac stops running Trading.
