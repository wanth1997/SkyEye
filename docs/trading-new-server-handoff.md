# TNAUQQuant new server monitoring handoff

This is the self-contained, non-secret contract for the agent onboarding the future Trading Mac. It applies after the development target is accepted in Grafana.

## Fixed identities

| Field | Production value |
|---|---|
| `product` | `tnauqquant` |
| `environment` | `production` |
| `server_id` | `tnauqquant-prod-1` |
| `strategy` | `mexc-toobit-btc` |
| launch mode | `scripts/tq live run --human <config>` inside operator tmux |
| auto-restart | disabled |
| primary PNL | latest `stable=true` `real_pnl_usdt` |
| Alloy version | the development-accepted version; record exact output |

Paths are intentionally not fixed. A different username or repo root changes only the host deployment env, never central labels, rules or dashboard queries.

## Prerequisites

- Trading checkout contains merge `fd317b51c3b617a8bf9b9f04e692649a45acf4c4` or a descendant.
- The untracked Trading `.env` sets `TQ_STRATEGY=mexc-toobit-btc`.
- The canonical Trading launcher creates `run-state/mexc-toobit-btc/current.json` and `current.done.json` using schema v1.
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
TQ_REPO_ROOT=<canonical absolute path>
TQ_REPO_ROOT_REGEX=(<RE2-escaped canonical root>)
TQ_EXECUTABLE=<repo>/quant
TQ_CONFIG_PATH=<canonical live config>
TQ_RAW_LOG_GLOB=<repo>/logs/live-runs/*.raw.log
TQ_RUN_MANIFEST=<repo>/run-state/mexc-toobit-btc/current.json
TQ_DONE_MARKER=<repo>/run-state/mexc-toobit-btc/current.done.json
TQ_INSTANCE_ID=<exact stable config instance_id>
TQ_SIDECAR_SESSION=<managed tmux session>
TQ_SIDECAR_IDENTITY_FILE=<managed identity artifact>
TQ_SIDECAR_HEALTH_URL=<loopback health endpoint>
```

Keep `TQ_POC_RUN_EXPECTED=1` as a fallback. The manifest/marker contract becomes authoritative when present.

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

## Rotation, revocation and retirement

- Rotate a token by authorizing a new token for the two push apps, replacing only this host's `config.env`, restarting Alloy and verifying both streams before revoking the old token.
- On retirement, first change/remove the target inventory and rules so `TradingTelemetryMissing` cannot page, then stop Alloy/probe, revoke the host token and archive host state.
- Never reuse the development token on production or leave the development target active after that Mac stops running Trading.
