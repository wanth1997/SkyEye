# Trading critical safety, binding or execution event

Used by `TradingCriticalSafetyState`, `TradingRuntimeContractMissing`, `TradingRunBindingInvalid`, `TradingExecutionIncident`, `TradingCriticalLogEvent` and `TradingCriticalWarnEvent`.

## Symptoms

- Marker reason is `risk_halt`, `max_cycles_drain_failed` or `unknown`.
- A run is expected, but its runtime manifest contract is unavailable.
- Manifest, process, config snapshot, log or marker binding is invalid.
- A high-confidence execution-confirmation event reached Loki.
- An `ERROR`, `ERROR+N`, `FATAL` or `FATAL+N` event outside that incident taxonomy reached Loki.

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

Compare `run_id`, `strategy`, `instance_id`, PID and config SHA-256 between manifest and marker. If only `tnauqquant_config_snapshot_match` is `0`, the running process and its manifest-bound log remain observable, but the on-disk config has changed since launch; preserve both hashes and do not rewrite the manifest to hide the drift. Then inspect the actual long/short inventory on both exchanges and decide whether an operator-led neutralization or shutdown is required.

The marker is first-critical-wins. Never replace it with a safe marker to make the alert disappear.

## Execution-confirmation incident

`TradingExecutionIncident` is intentionally message-based rather than level-based. It covers:

- `coordinator_fence_stalled`
- `mexcui_recovery_required`
- `mexcui_recovery_required_refusing_normal_startup`
- `shutdown_with_unconsumed_continuation`
- `coordinated_shutdown_preserved_unresolved_fence`

Treat any of these as an unresolved execution state until both venues' actual inventory and open orders have been reconciled. `disposition=unresolved ui_submission_status=accepted` by itself is not an incident: that is a normal asynchronous submission state and must be paired with one of the allowlisted failure messages before this alert fires.

The generic ERROR-family alert explicitly excludes this taxonomy. This keeps one incident from producing two page candidates when the shadow rules are later promoted.

## Runtime contract missing

`TradingRuntimeContractMissing` means `run_expected=1` while `runtime_contract_available=0`. Preserve the current manifest path and process evidence before any restart. Confirm whether the manifest is absent, unreadable, stale, or inconsistent with the running process. Do not infer safety from `process_count=0`: the previous run may have exited with unresolved exposure.

The dashboards split binding into three signals:

- `Runtime Contract` — whether the manifest contract is available.
- `執行綁定` — process, strategy, log and marker identity agreement.
- `Config 快照` — whether the current on-disk config still matches the launch snapshot.

This separation prevents an older config drift from masking a newly missing runtime contract.

## Central verification

```promql
tnauqquant_done_marker{product="tnauqquant",server_id="tnauqquant-prod-1"}
min({__name__=~"tnauqquant_(process_identity_ok|strategy_identity_ok|config_snapshot_match|log_binding_ok|marker_binding_ok)",product="tnauqquant",server_id="tnauqquant-prod-1"})
```

```logql
{product="tnauqquant",server_id="tnauqquant-prod-1"}
| logfmt
| msg=~"coordinator_fence_stalled|mexcui_recovery_required|mexcui_recovery_required_refusing_normal_startup|shutdown_with_unconsumed_continuation|coordinated_shutdown_preserved_unresolved_fence"

{product="tnauqquant",server_id="tnauqquant-prod-1",level=~"ERROR([+][0-9]+)?|FATAL([+][0-9]+)?"}
| logfmt
| msg!~"coordinator_fence_stalled|mexcui_recovery_required|mexcui_recovery_required_refusing_normal_startup|shutdown_with_unconsumed_continuation|coordinated_shutdown_preserved_unresolved_fence"
```

Execution identifiers (`grant_id`, `mutation_id`, `mutations`, `account`), trace identifiers, order references and local paths are scrubbed on the source host before Loki ingestion. Use the source raw log under the incident-handling authorization when those identifiers are required for reconciliation; never add them as Loki labels.

Resolve only after the exposure decision is complete and the run state is archived according to the Trading contract. A Loki alert resolves when the one-minute window passes; that does not resolve the underlying incident by itself.

## Post-incident

- Preserve the scrubbed Loki event, source raw log, manifest, marker and config hash.
- Record exchange inventory and the operator decision.
- Add an explicit message taxonomy rule if a recurring critical WARN is not yet allowlisted.
