# Grafana Alloy on Windows (SkyEye)

Host metrics, Alloy's own push metrics, and the System and Application Event Logs from a Windows host, pushed to central through a Cloudflare Access service token that belongs to that host alone. The operating procedure, token placement and alert handling are in [`runbooks/windows-host-onboarding.md`](../../../runbooks/windows-host-onboarding.md). This file describes what the files here do.

| File | Purpose |
|---|---|
| `config.alloy.tmpl` | The config. Placeholders are `@@PRODUCT@@`, `@@SERVER_ID@@`, the two push URLs and `@@SECRETS_DIR@@`. |
| `config-runner-diag.alloy.tmpl` | GitHub Actions runner listener log (`Runner_*.log`). Appended only with `-RunnerDiagDir`. |
| `install.ps1` | Check, Install, Rollback, and `-RenderOnly` for the tests. |
| `uninstall.ps1` | Stops and disables the service and leaves a config with no pipeline. |
| `SkyEyeAlloy.ps1` | Shared library. Everything that touches the host is in a `*-SkyEyeHost*` function, which the tests replace. |

The scripts are plain ASCII and run under Windows PowerShell 5.1 and PowerShell 7. They never prompt, take no credential as a parameter and never open the secret files. Tested Alloy versions are `SKYEYE_ALLOY_WINDOWS_VERSIONS` in [`../alloy-versions.env`](../alloy-versions.env); any other version is refused, and the installer does not install or upgrade Alloy.

## What is collected

**Metrics** (`job="integrations/windows"`, `instance=<hostname>`, as the exporter sets them): collectors `cpu`, `logical_disk`, `memory`, `net`, `os`, `service`, `system`, `time`.

- Services: only `Alloy` and `actions.runner.*`.
- Disks: drive letters; `HarddiskVolumeN` (recovery and EFI partitions) is excluded.
- Dropped before the push: per-core C-state, frequency and interrupt detail, and the info metrics whose labels are a disk serial number, a binary path, the service account, an IP or MAC address, or a process id. The list is `tests/fixtures/windows/windows-exporter-v0.31.3-metrics.txt`.
- `windows_os_info` has a `product` label of its own, which would replace SkyEye's. It is moved to `os_product`.

**Alloy's own metrics** (`job="integrations/self"`): the 17 names in `tests/fixtures/windows/alloy-self-allowlist.txt`, enough to see a failing push from central.

**Logs** (`job="windows-eventlog"`, labels `channel`, `level`, `product`, `server_id` and nothing else):

- System and Application, Critical, Error and Warning, plus a few System events for boot, shutdown, unexpected shutdown and service installation.
- `level` comes from the numeric level, because the level text is localized. The `computer` label is dropped.
- Events older than 24 hours are dropped and the stream is rate limited. With no bookmark, Alloy starts at new events and does not backfill.
- Every line goes through the general scrub rules, then the Windows rules: the user name in a profile path, the account in the `security` block, account SIDs, accounts named in the message (English and zh-TW wording), `DOMAIN\user`, GitHub tokens, credentials passed as an argument, JSON web tokens, credentials in a URL and signed-URL query values.

**Runner log** (`job="github-runner-diag"`, with `-RunnerDiagDir`): `Runner_*.log` only, read from the start of each file with the timestamp taken from the line, `VERB` lines dropped, same scrub. `Worker_*.log` is never read.

## What `install.ps1` does

`-Mode Check` (the default) runs steps 1 to 8 and changes nothing. Without administrator rights it cannot read the secret files or the live config, so it reports those checks as `skipped`, never as `passed`.

| # | Step | On failure |
|---|---|---|
| 1 | Parameters: lowercase slugs, https push URLs, absolute directories | exit 2, nothing changed |
| 2 | Elevation (Install and Rollback only) | STOP |
| 3 | One run at a time: `C:\ProgramData\SkyEye\alloy-install.lock` | STOP |
| 4 | Alloy: service exists, runs as LocalSystem, loads a single config file, version is listed | STOP |
| 5 | Secret files: both exist, plausible size, ACL and owner limited to SYSTEM and Administrators. Read from metadata only | STOP |
| 6 | No `config.alloy.rollback` left by a killed run; the live config's `product` and `server_id` equal the parameters, or it sets none | STOP |
| 7 | Render, then `alloy validate` | STOP |
| 8 | Smoke run: a real `alloy run` of the render on its own port and storage path, with only the push URLs pointed at a closed local port. Catches what validate accepts, such as a secret used as a header | STOP |
| 9 | Swap: `File.Replace`, the old config becomes `config.alloy.rollback`; restart | STOP if the swap itself fails |
| 10 | Health gate, 120 seconds | **rollback** |

Every STOP leaves the host as it was found, and exits 1.

**Health gate.** The service stays on one process for ten seconds and answers `/-/ready`; `prometheus_remote_storage_queue_highest_sent_timestamp_seconds` moves past the restart; no sample failed and retries are not growing; and Loki acknowledges at least one entry. `prometheus_remote_storage_samples_total` is not used: it counts attempts and rises against a dead endpoint. For the Loki part the installer writes a canary warning to the Application log (source `SkyEye`, event id 4242), because a quiet host may log nothing for minutes and the Loki push has otherwise never been used with the host's token.

**Rollback.** The failed config is kept as `config.alloy.failed-<run id>`, `config.alloy.rollback` goes back in place, the service is restarted (or stopped, if it was stopped before the run) and must answer `/-/ready` within 60 seconds. Status `rolled_back`, exit 1. If that does not finish: `rollback_incomplete`, exit 3, and the message says what to compare by hand. After a successful install the old config is kept as `config.alloy.previous`, which is what `-Mode Rollback` returns to, through the same validate and health gate.

When the live config already equals the render, nothing is swapped or restarted; the health gate still runs (`already_current`, or `unhealthy_no_change` with exit 1).

## Result files

In `C:\ProgramData\SkyEye\reports\`:

- `windows-agent-install-<run id>.json` and `.log` for every run (`windows-agent-uninstall-…` for the uninstaller);
- `windows-agent-install-latest-admin.json` and `-latest-user.json`: the latest result per privilege level. There are two because a non-admin cannot replace a file an elevated run created in that directory.

The JSON has `status`, `exit_code`, `stop_point`, `message`, one entry per check with `passed`, `failed` or `skipped`, the delivery numbers the health gate read, and the SHA-256 of the old and new config. It never contains the config text or anything from the secret files.

## Tests

All three run inside `scripts/verify-all`, on macOS, with PowerShell 7 and the pinned Alloy image.

- `tests/windows/test-windows-installer.sh`: the scripts parse, are ASCII, use no PowerShell 7 only syntax and no command that prompts or depends on the session encoding; every STOP and rollback path runs against a fake host.
- `tests/windows/test-windows-config.sh`: validate and a real run of the render, the secret-to-string mutation, and the labels of what reaches Prometheus.
- `tests/windows/test-windows-scrub.sh`: Event Log and runner log fixtures through the real pipeline into a real Loki.
- `tests/windows/test-windows-central.sh`: the alert rules stay in shadow and the dashboard only reads what this config sends.

Not covered off Windows: Windows PowerShell 5.1 itself, the real service, registry, ACL and Event Log calls, and the two Windows-only Alloy components, which do nothing on other platforms. The first real run of those is `-Mode Check` on the host.
