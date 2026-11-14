# SkyEye runbooks

Each file here matches one Prometheus alert rule. The rule's `runbook_url` annotation points here; when the alert fires, the Telegram message links straight to the file.

## Style

- **Symptoms first, causes second, commands third.** In a 3 AM page, you're scrolling, not reading.
- **Copy-paste blocks** — every `bash` / `promql` / `logql` block should run as-is without edits except the obvious `$PRODUCT` placeholder.
- **No prose essays.** A runbook that takes 10 minutes to skim is worse than no runbook. Keep under 200 lines.
- **Link to data**, don't repeat it. The plan lives in `monitoring-plan-v2.md`; architecture diagrams in `docs/`. Runbooks are the emergency kit, not the manual.

## Inventory (2026-08-01)

| Rule | Runbook | Severity |
|---|---|---|
| `BackendDown` | [backend-down.md](./backend-down.md) | High |
| `High5xxRate` / `Critical5xxRate` | [high-5xx.md](./high-5xx.md) | Medium / High |
| `PaymentCreate5xxWarning` / `PaymentCreate5xxCritical` | [high-5xx.md](./high-5xx.md) | Medium / High (shadow) |
| `PaymentOrderGenerationFailure` | [high-5xx.md](./high-5xx.md) | High (shadow) |
| `LinkCourt401Surge` / `LinkCourt401SurgeByHandler` / `LinkCourt429Surge` | [linkcourt-auth-surge.md](./linkcourt-auth-surge.md) | Medium (shadow) |
| `HostDiskLow` / `HostDiskCritical` | [disk-full.md](./disk-full.md) | Medium / High |
| `HostHighCPU` | [high-cpu.md](./high-cpu.md) | Medium |
| `HostOOM` | [oom.md](./oom.md) | High |
| `PrometheusBackupStale` / `PrometheusBackupStaleCritical` / `PrometheusBackupSignalMissing` / `PrometheusBackupSnapshotsAccumulating` | [backup-failed.md](./backup-failed.md) | Medium / High / Medium / Medium (shadow) |
| `PaymentSuccessRateLow` | [payment-zero.md](./payment-zero.md) | High |
| `ExternalApiDown` / `TlsCertExpired` | [external-api-down.md](./external-api-down.md) | High |
| `SchedulerNoHeartbeat` | [scheduler-dead.md](./scheduler-dead.md) | High |
| `SkyEyeWatchdog` / `AlertmanagerDown` | [skyeye-watchdog.md](./skyeye-watchdog.md) | None (external dead man's switch) / High |
| `AllRemoteAgentsSilent` | [all-remote-agents-silent.md](./all-remote-agents-silent.md) | High (shadow) |

Add a row + a runbook here every time you add a rule with `severity: High` or `Medium`.

## Procedures

- [`trading-alert-promotion.md`](./trading-alert-promotion.md) — Trading silence rule, SMTP fill-in, real canary and the promotion checklist.
- [`alertmanager-upgrade.md`](./alertmanager-upgrade.md) — Manual Alertmanager image upgrade (v0.27.0 → v0.34.2): pre-pull, `up -d`, `--manual-applied`, post-checks and rollback.
- [`skyeye-watchdog.md`](./skyeye-watchdog.md) — External dead man's switch: hosted check, `deadman_url` secret, deploy, the one-time Alertmanager stop test and planned-downtime pauses.

## Template

[`_template.md`](./_template.md) — copy as a starting point.
