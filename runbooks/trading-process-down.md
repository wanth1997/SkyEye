# Trading process identity or availability

Used by `TradingProcessDown`, `TradingDuplicateProcess` and `TradingUnexpectedProcess`.

## Symptoms

- **Down:** a run is expected, but no exact `quant -config <configured-path>` process exists for 2 minutes.
- **Duplicate:** more than one exact process exists. Treat this as the highest process-level risk.
- **Unexpected:** a process exists after the run is disabled or safely completed.

All Trading alerts remain `notification_mode=shadow` until the owner promotes the production target.

## Immediate actions

Do not auto-restart, kill, archive run state or launch another process. First identify the run and confirm real exchange exposure.

On the Trading Mac:

```bash
cd "$TQ_REPO_ROOT"
ps ax -o pid=,lstart=,command= | grep '[q]uant'
jq . "run-state/$TQ_STRATEGY/current.json"
if [ -f "run-state/$TQ_STRATEGY/current.done.json" ]; then
  jq . "run-state/$TQ_STRATEGY/current.done.json"
fi
sed -n '1,240p' "$(brew --prefix)/var/lib/alloy/trading-textfile/tnauqquant.prom"
```

Verify the manifest PID, executable, config hash, log path and current process all describe the same run. For duplicate processes, determine which PID owns each exchange action before deciding which process may be stopped.

For a safe marker (`max_cycles_complete` or `reduce_only_complete`), verify the marker binding and flat inventory before following the archive procedure in the Trading repo's `docs/trading-run-contract.md`.

## Central verification

```promql
tnauqquant_process_count{product="tnauqquant",server_id="tnauqquant-prod-1"}
tnauqquant_run_expected{product="tnauqquant",server_id="tnauqquant-prod-1"}
tnauqquant_done_marker{product="tnauqquant",server_id="tnauqquant-prod-1"}
```

Recovery is proven only when the process count and current runtime contract agree. Process count `0` is correct after a verified safe completion; process count `1` is correct while running.

## Post-incident

- Preserve the bound raw log, manifest and marker before archive.
- Record whether the alert was Down, Duplicate or Unexpected and the real exchange inventory at diagnosis time.
- Do not promote paging if a safe completion produced a false ProcessDown.
