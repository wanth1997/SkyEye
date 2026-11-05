# `PrometheusBackupStale` / `PrometheusBackupStaleCritical` / `PrometheusBackupSignalMissing` / `PrometheusBackupSnapshotsAccumulating`

All four carry `notification_mode: shadow`: they show in Prometheus and in Overview `Active alerts`, and they do not reach Telegram.

**The deployed `scripts/backup-prometheus.sh` does not report `skyeye_backup_*` yet.** Until it does, `PrometheusBackupSignalMissing` firing is expected and the other three stay silent, so `/var/log/prometheus-backup.log` and S3 are the only evidence of a failed backup.

## Symptoms

```promql
# PrometheusBackupStale (Medium, 30h) and PrometheusBackupStaleCritical (High, 54h)
time() - (
  last_over_time(skyeye_backup_last_success_timestamp_seconds{job="skyeye-backup"}[31d])
  or on (job, instance)
  0 * last_over_time(skyeye_backup_last_attempt_timestamp_seconds{job="skyeye-backup"}[31d])
) > 30 * 3600

# PrometheusBackupSignalMissing (Medium)
absent_over_time(skyeye_backup_last_attempt_timestamp_seconds{job="skyeye-backup"}[30h])

# PrometheusBackupSnapshotsAccumulating (Medium)
last_over_time(skyeye_backup_snapshot_pinned_bytes{job="skyeye-backup"}[30h]) > 3 * 1024 * 1024 * 1024
or
last_over_time(skyeye_backup_pending_generations{job="skyeye-backup"}[30h]) > 2
```

| Annotation | Meaning |
|---|---|
| No completed Prometheus backup generation for over 30h | One nightly run (19:00 UTC, 03:00 Taipei) was missed |
| No completed Prometheus backup generation for over 54h | Two runs missed |
| Prometheus backup has reported nothing for 30h | Cron gone, script died before reporting, or reporting is broken. The backup itself may be fine |
| Local Prometheus snapshots exceed the retention bound | Failed runs left snapshots on the host disk |

**Deadline:** S3 lifecycle expires each prefix after 30 days whether or not new ones arrive. About 31 days after backups stop, the last good one is gone, long before the disk fills.

## Likely causes

1. `aws s3 sync` failed: S3, IAM or network. The script exits before its cleanup, so the snapshot stays in `snapshots/`.
2. Prometheus was down or refused the snapshot call (log shows curl exit 7, or `snapshot API returned no name`).
3. Disk full on monitoring-prod (see [disk-full.md](./disk-full.md)).
4. Cron file missing, or `scripts/backup-prometheus.sh` not executable after a checkout change.
5. For `SignalMissing` only: the backup ran and its report did not arrive.
6. For `SnapshotsAccumulating`: earlier failures. A later successful run cleans only its own snapshot, so old ones stay until someone removes them.

## Immediate actions (copy-paste commands)

SSH to monitoring-prod.

```bash
# Did the last run reach the end? Success is a "==> backup OK" line.
sudo tail -n 30 /var/log/prometheus-backup.log

# Is the job installed, and did cron start it?
cat /etc/cron.d/skyeye-prometheus-backup
sudo journalctl -u cron --since '2 days ago' | grep backup-prometheus | tail -5

# What does S3 hold? Prefix dates are UTC.
aws s3 ls --region ap-northeast-1 s3://skyeye-prometheus-snapshots/ | tail -5

# Compare the newest prefixes: a partial upload still shows up as a prefix.
for p in $(aws s3 ls --region ap-northeast-1 s3://skyeye-prometheus-snapshots/ | awk '$1 == "PRE" {print $2}' | tail -3); do
  echo "$p"
  aws s3 ls --region ap-northeast-1 --recursive --summarize "s3://skyeye-prometheus-snapshots/$p" | tail -2
done

# Can the script run at all?
curl -fsS http://127.0.0.1:9090/-/ready
df -h /
```

A failing run exits with its cause in the log. The last line before the failure tells you which step stopped:

| Log | Stopped at |
|---|---|
| `curl: (7) ...` | Prometheus not reachable |
| `snapshot API returned no name` | Admin API refused |
| `expected snapshot dir ... not found` | Snapshot path, check the volume name |
| `==> uploading ...`, no `backup OK`, snapshot still in `snapshots/` | Upload failed |
| `==> uploading ...`, no `backup OK`, snapshot gone | Upload finished and only the final size listing failed, so the backup may be good |

### Re-run the backup

Fix the cause first. Every run takes a new snapshot, and every failed run leaves another one behind, so do not retry in a loop.

Run in the Taipei daytime, after 08:00. The failed 03:00 run wrote to the previous UTC date, so a re-run then gets a fresh prefix. Re-running on the same UTC date mixes into the failed prefix: the run can print `backup OK` while a block stays incomplete.

```bash
# The script has no lock; do not overlap it with another run.
pgrep -af '[b]ackup-prometheus.sh' || \
  sudo /home/ubuntu/SkyEye/scripts/backup-prometheus.sh 2>&1 | sudo tee -a /var/log/prometheus-backup.log
```

### Snapshots on the host disk

`du` on `snapshots/` alone overstates the cost, because a snapshot shares hardlinks with live blocks. Count the live blocks first, and the `snapshots` line shows only what snapshots hold on their own:

```bash
sudo sh -c 'cd /var/lib/docker/volumes/skyeye_prometheus_data/_data && ls -la snapshots/ && du -sm --total 0* snapshots | tail -2'
```

As of 2026-11-04 production holds one old snapshot, `20260423T050734Z-1833eb911e7fbdde` (9.6 MB). It is a known leftover, not a new failure.

Removing a snapshot directory drops only its links and does not touch live blocks, but it cannot be undone and may be the only local copy of that data. Get Wan's approval, confirm a newer run ended in `backup OK`, and remove one exact directory at a time:

```bash
sudo rm -rf /var/lib/docker/volumes/skyeye_prometheus_data/_data/snapshots/<snapshot-id>
```

## Verify recovery

```bash
sudo grep 'backup OK' /var/log/prometheus-backup.log | tail -1
aws s3 ls --region ap-northeast-1 s3://skyeye-prometheus-snapshots/ | tail -1
```

```promql
# Once the script reports: under 108000 (30h)
time() - last_over_time(skyeye_backup_last_success_timestamp_seconds{job="skyeye-backup"}[31d])

# Empty, except SignalMissing while the script does not report
ALERTS{alertname=~"PrometheusBackup.*",alertstate="firing"}
```

`backup OK` means the upload ended, not that the backup can be restored. No existing backup has been proven restorable; to check one, run steps 1-3 of "Restore Prometheus TSDB from S3 snapshot" in [`docs/operations.md`](../docs/operations.md), which leave live data alone.

## Post-incident

- Keep the log excerpt: `/var/log/prometheus-backup.log` is the only record of why a run failed, and it rotates weekly.
- Note which UTC dates failed or are partial, so nobody restores from them.
- Work out the deadline: the oldest good prefix plus 30 days.
- Check `snapshots/` for leftovers from the failed runs.
- If the cause can recur, add it to this runbook.
