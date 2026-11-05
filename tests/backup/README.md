# Backup and restore tests

`central-deploy` does not validate `scripts/backup-prometheus.sh`, and cron runs it as
root at 19:00 UTC on monitoring-prod. This directory is its only gate.

## Test suite

```bash
/bin/bash tests/backup/run-tests.sh
```

It needs no Docker, AWS credentials or network: `shim/` replaces `aws`, `curl`, `docker`
and `sudo`, and the run stops if any of them resolves to the real tool. A missing tool
fails the suite; nothing is skipped.

- `cases-legacy-failures.sh` has the failure scenarios of the backup plan. Each case has
  to fail on `fixtures/legacy/backup-prometheus.sh`, the script before this rewrite, and
  pass on the new one. A case that passes on the old script fails the suite.
- `cases-backup.sh` and `cases-restore.sh` cover the new scripts.
- `BACKUP_TEST_ONLY=<regex>` runs matching cases and never ends in PASS.
  `BACKUP_TEST_KEEP=1` keeps the sandboxes.

Until `prometheus/rules/backup.yml` is on this branch, the metric names are compared
with the file on `feat/backup-docs-rules`.

## Restore drill

The real scripts against a real Prometheus in a Docker named volume, in the Colima VM.
Only `aws` is fake: the bucket is a local directory.

```bash
DRILL_LOG_DIR=<dir under home> DRILL_JQ_DEBS=<dir> \
  /bin/bash tests/backup/drill/run-in-colima.sh drill
```

It takes about 15 minutes. It uses compose project `skyeye-restore-drill`, its own volume
and `127.0.0.1:19090`, refuses to start over leftovers of an earlier run, and removes
everything at the end. Each step writes `step-<id>.log` and a line of `results.tsv` in
`DRILL_LOG_DIR`.

The VM has no jq. `DRILL_JQ_DEBS` holds the jq, libjq1 and libonig5 packages of its Ubuntu
release; they are unpacked into a temporary directory, not installed. The same script
runs the test suite on Linux with `run-in-colima.sh tests`.

The drill cannot show what a fake bucket hides: real S3 multipart uploads, permissions
and checksums. Those need `fetch` and `verify` against a real generation.

## Restore

`scripts/restore-prometheus.sh --help` is the usage reference.
