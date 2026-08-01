# Trading critical safety, binding or log event

Used by `TradingCriticalSafetyState`, `TradingRunBindingInvalid`, `TradingCriticalLogEvent` and `TradingCriticalWarnEvent`.

## Symptoms

- Marker reason is `risk_halt`, `max_cycles_drain_failed` or `unknown`.
- Manifest, process, config, log or marker binding is invalid.
- An ERROR/FATAL or allowlisted critical WARN reached Loki.

`risk_halt` may leave the process alive. Process presence does not make the state safe.

## Immediate actions

Do not archive or overwrite current state. Do not assume the ERROR is harmless or restart the run.

```bash
cd "$TQ_REPO_ROOT"
ps ax -o pid=,lstart=,command= | grep '[q]uant'
jq . "run-state/$TQ_STRATEGY/current.json"
jq . "run-state/$TQ_STRATEGY/current.done.json"
shasum -a 256 "$TQ_CONFIG_PATH"
tail -n 200 "$(jq -r '.log_path' "run-state/$TQ_STRATEGY/current.json")"
```

Compare `run_id`, `strategy`, `instance_id`, PID and config SHA-256 between manifest and marker. Then inspect the actual long/short inventory on both exchanges and decide whether an operator-led neutralization or shutdown is required.

The marker is first-critical-wins. Never replace it with a safe marker to make the alert disappear.

## Central verification

```promql
tnauqquant_done_marker{product="tnauqquant",server_id="tnauqquant-prod-1"}
min({__name__=~"tnauqquant_(process_identity_ok|strategy_identity_ok|log_binding_ok|marker_binding_ok)",product="tnauqquant",server_id="tnauqquant-prod-1"})
```

```logql
{product="tnauqquant",server_id="tnauqquant-prod-1",level=~"ERROR|FATAL"}
```

Resolve only after the exposure decision is complete and the run state is archived according to the Trading contract. An ERROR alert resolves when the one-minute window passes; that does not resolve the underlying incident by itself.

## Post-incident

- Preserve the scrubbed Loki event, source raw log, manifest, marker and config hash.
- Record exchange inventory and the operator decision.
- Add an explicit message taxonomy rule if a recurring critical WARN is not yet allowlisted.
