# Trading telemetry missing or stale

Used by `TradingTelemetryMissing` when an inventory target has no probe timestamp, or its timestamp has stopped advancing for 180 seconds.

## Symptoms

The metric series is absent or its timestamp is frozen. Possible causes include a stopped probe, stopped Alloy, network/Cloudflare failure, asleep/offline host or revoked service token. The alert intentionally does not depend on an agent-reported `run_expected` value.

## Immediate actions

First confirm whether the Trading Mac itself is reachable. This alert does not prove the trading process is stopped.

On the Trading Mac:

```bash
brew services info grafana/grafana/alloy
launchctl print "gui/$(id -u)/com.wanbrain.skyeye-trading-probe"
curl -fsS http://127.0.0.1:12345/-/ready
tail -n 100 "$(brew --prefix)/var/log/alloy/trading-probe.err.log"
tail -n 100 "$(brew --prefix)/var/log/alloy.err.log"
ls -l "$(brew --prefix)/var/lib/alloy/trading-textfile/tnauqquant.prom"
```

If the probe output is fresh but central metrics are missing, inspect Alloy for `401`, `403`, DNS or connection errors. Rotate/re-authorize only that host's dedicated service token; do not copy another host's token.

Restarting Alloy or reloading the probe launchd job is allowed after diagnosis because neither controls the trading process. Never restart Trading merely to clear this alert.

## Verify recovery

```promql
time() - tnauqquant_probe_timestamp_seconds{product="tnauqquant",server_id="tnauqquant-prod-1"}
```

The series must return within 30 seconds and remain below 30 seconds for two probe intervals. Also verify that Loki resumes without a large unexpected historical replay.

## PnL history unavailable

`TradingPnlHistoryUnavailable` is a Medium shadow alert for inventory targets marked `history_capable="true"`. It fires when the independent history builder has no valid output, or when its last successful build is older than 180 seconds. It does not imply that the trading process or the 15-second runtime probe has stopped.

On the Trading Mac:

```bash
launchctl print "gui/$(id -u)/com.wanbrain.skyeye-trading-pnl-history"
tail -n 100 "$(brew --prefix)/var/log/alloy/trading-pnl-history.err.log"
ls -l "$(brew --prefix)/var/lib/alloy/trading-textfile/tnauqquant-pnl-history.prom"
sed -n '1,240p' "$(brew --prefix)/var/lib/alloy/trading-textfile/tnauqquant-pnl-history.prom"
```

Verify recovery centrally:

```promql
time() - tnauqquant_pnl_history_build_timestamp_seconds{product="tnauqquant",server_id="tnauqquant-prod-1"}
```

The age must fall below 180 seconds and `tnauqquant_pnl_history_valid` must equal `1`. Diagnose malformed or conflicting source events before restarting only the history LaunchAgent. Do not delete the private history cache or raw logs: retained per-run summaries may be the only source for rotated runs.

## Post-incident

- Record whether the failure was probe, Alloy, host, network, Access policy or token.
- Revoke the old host-specific token after rotation.
- If the server was intentionally retired, remove/disable its central inventory before stopping telemetry.
