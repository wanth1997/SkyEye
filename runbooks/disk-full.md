# `HostDiskLow` / `HostDiskCritical`

## Symptoms

```promql
# Medium
(node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100 < 20

# High
(node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100 < 5
```

- Medium fires quietly (< 20%); High is audible (< 5%).
- At < 5%, SQLite writes can start failing; Loki on the monitoring machine can fall over.
- monitoring-prod reports no host metrics (no `node_filesystem` series as of 2026-11-04), so these alerts do not fire for the monitoring machine itself. Check `df -h /` there by hand.

## Likely causes

1. Backend / proxy logs rotated but old files not removed (logrotate config missing)
2. Docker image / volume bloat on the monitoring machine (`docker system df`)
   — container stdout logs are capped by `x-logging` in `docker-compose.yml` (5 × 50 MB each); a large `/var/lib/docker/containers/*/*-json.log` means that container was created before the cap or outside compose, so recreate it with `sudo docker compose up -d <service>`
3. Prometheus volume on the monitoring machine grew past 4 GB. `--storage.tsdb.retention.size=4GB` counts loaded blocks and the head only, not `snapshots/`: every failed nightly backup leaves a snapshot there that is never cleaned up, even by later successful runs, and that retention cannot reclaim
4. PPClub `ppc.db` SQLite grew unexpectedly (audit trail / session table)
5. Core dumps in `/var/crash` or `/var/lib/systemd/coredump`

## Immediate actions

SSH to the alerting host, then:

```bash
# Which dir is eating space
df -h /
sudo du -x --max-depth=2 / 2>/dev/null | sort -rh | head -20

# Common offenders
sudo du -sh /var/log /var/lib/docker /var/cache/apt /var/crash /tmp 2>/dev/null
sudo docker system df 2>/dev/null

# If it's journald
sudo journalctl --disk-usage
sudo journalctl --vacuum-size=500M    # keeps last 500 MB

# If it's docker
sudo docker image prune -a -f
sudo docker volume ls | grep -v skyeye  # don't touch skyeye_* volumes blindly

# If it's the Prometheus volume on the monitoring machine
# Live blocks go first: du counts a hardlink once, so the snapshots line shows
# only what snapshots hold on their own. du on snapshots/ alone overstates it.
sudo sh -c 'cd /var/lib/docker/volumes/skyeye_prometheus_data/_data && ls -la snapshots/ && du -sm --total 0* snapshots | tail -2'
# Removing a snapshot is irreversible and needs approval: follow backup-failed.md.
# Never delete from _data itself.

# If it's apt cache
sudo apt-get clean

# If it's PPClub SQLite
ls -lh /home/ubuntu/PPClub/backend/ppc.db
# It should be tens-hundreds of MB. If it's multi-GB, VACUUM may reclaim:
sqlite3 /home/ubuntu/PPClub/backend/ppc.db 'PRAGMA wal_checkpoint(TRUNCATE); VACUUM;'
# First arrange for zero writes — stop the service if needed.
```

If space is desperately low (<1 GB remaining):

```bash
# Gain immediate runway — truncate log files in place (don't delete or logrotate gets confused)
# On the monitoring machine, keep the backup log first: it is the only record of why a backup failed.
sudo tail -n 200 /var/log/prometheus-backup.log > ~/prometheus-backup.log.saved 2>/dev/null || true
sudo find /var/log -type f -name '*.log' -exec truncate -s 0 {} \;
sudo truncate -s 0 $(sudo journalctl --disk-usage | grep -oE '/var/log/journal/[^ ]+' | head -1) 2>/dev/null || true
```

## Verify recovery

```
(node_filesystem_avail_bytes{product="$PRODUCT",mountpoint="/"} / node_filesystem_size_bytes{product="$PRODUCT",mountpoint="/"}) * 100
# should be > 25% to clear Medium, > 10% for High buffer
```

## Post-incident

- Figure out why it grew: pure traffic, or a leak / runaway log
- Add logrotate if missing (`/etc/logrotate.d/<service>`)
- If `snapshots/` was the cause, the backups were failing too: follow [backup-failed.md](./backup-failed.md)
- On the monitoring machine, bump EBS size (`aws ec2 modify-volume`) before the next near-miss
- Add a `HostDiskGrowthRate` Low informational alert if you find repeat offense: `deriv(node_filesystem_avail_bytes[1h]) < -500 * 1024 * 1024` (shrinking > 500 MB/hour)
