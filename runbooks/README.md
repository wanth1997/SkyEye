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
| `BackendDown` | [backend-down.md](./backend-down.md) | P1 |
| `High5xxRate` / `Critical5xxRate` | [high-5xx.md](./high-5xx.md) | P2 / P1 |
| `HostDiskLow` / `HostDiskCritical` | [disk-full.md](./disk-full.md) | P2 / P1 |
| `ZeroPayment1Hour` | [payment-zero.md](./payment-zero.md) | P1 |
| `ExternalApiDown` | [external-api-down.md](./external-api-down.md) | P1 |

Add a row + a runbook here every time you add a rule with `severity: P1` or `P2`.

## Template

[`_template.md`](./_template.md) — copy as a starting point.
