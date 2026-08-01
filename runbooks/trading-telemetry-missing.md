# Trading telemetry missing

Used by `TradingTelemetryMissing` when the central inventory has no probe timestamp series for 3 minutes.

## Symptoms

The whole metric series is absent. Possible causes include a stopped probe, stopped Alloy, network/Cloudflare failure, asleep/offline Mac or revoked service token. The alert intentionally does not depend on an agent-reported `run_expected` value.

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

## Post-incident

- Record whether the failure was probe, Alloy, host, network, Access policy or token.
- Revoke the old host-specific token after rotation.
- If the server was intentionally retired, remove/disable its central inventory before stopping telemetry.
