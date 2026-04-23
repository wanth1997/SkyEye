# SkyEye runbooks

Each file here matches one Prometheus alert rule. The rule's `runbook_url` annotation points here; when the alert fires, the Telegram / email message links straight to the file.

## Style

- **Symptoms first, causes second, commands third.** In a 3 AM page, you're scrolling, not reading.
- **Copy-paste blocks** — every `bash` / `promql` / `logql` block should run as-is without edits except the obvious `$PRODUCT` placeholder.
- **No prose essays.** A runbook that takes 10 minutes to skim is worse than no runbook. Keep under 200 lines.
- **Link to data**, don't repeat it. The plan lives in `monitoring-plan-v2.md`; architecture diagrams in `docs/`. Runbooks are the emergency kit, not the manual.

## Inventory (2026-04-23)

| Rule | Runbook | Severity |
|---|---|---|
| `BackendDown` | [backend-down.md](./backend-down.md) | High |
| `High5xxRate` / `Critical5xxRate` | [high-5xx.md](./high-5xx.md) | Medium / High |
| `HostDiskLow` / `HostDiskCritical` | [disk-full.md](./disk-full.md) | Medium / High |
| `HostHighCPU` | [high-cpu.md](./high-cpu.md) | Medium |
| `HostOOM` | [oom.md](./oom.md) | High |
| `ZeroPaymentHalfDay` | [payment-zero.md](./payment-zero.md) | High |
| `ExternalApiDown` / `TlsCertExpired` | [external-api-down.md](./external-api-down.md) | High |
| `SchedulerNoHeartbeat` | [scheduler-dead.md](./scheduler-dead.md) | High |

Add a row + a runbook here every time you add a rule with `severity: High` or `Medium`.

## Template

[`_template.md`](./_template.md) — copy as a starting point.
