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

## Likely causes

1. Backend / proxy logs rotated but old files not removed (logrotate config missing)
2. Docker image / volume bloat on the monitoring machine (`docker system df`)
3. Prometheus TSDB exceeded configured size (should be bounded at 4 GB but misconfig possible)
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
- On the monitoring machine, bump EBS size (`aws ec2 modify-volume`) before the next near-miss
- Add a `HostDiskGrowthRate` Low informational alert if you find repeat offense: `deriv(node_filesystem_avail_bytes[1h]) < -500 * 1024 * 1024` (shrinking > 500 MB/hour)
