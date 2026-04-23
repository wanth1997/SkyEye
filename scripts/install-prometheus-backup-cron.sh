#!/usr/bin/env bash
# Install (or reinstall) the daily Prometheus snapshot cron job.
#   - Adds --web.enable-admin-api to prometheus command (if missing)
#   - Installs /etc/cron.d/skyeye-prometheus-backup
#   - Rotates log at /var/log/prometheus-backup.log
#
# Idempotent — safe to re-run.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo)." >&2; exit 1
fi

CRON_FILE=/etc/cron.d/skyeye-prometheus-backup
SCRIPT=/home/ubuntu/SkyEye/scripts/backup-prometheus.sh
LOG=/var/log/prometheus-backup.log
LOGROTATE=/etc/logrotate.d/skyeye-prometheus-backup

if [ ! -x "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT missing or not executable" >&2; exit 2
fi

echo "==> writing $CRON_FILE"
cat > "$CRON_FILE" <<EOF
# Daily Prometheus TSDB snapshot → S3 (03:00 Asia/Taipei = 19:00 UTC)
# Managed by SkyEye/scripts/install-prometheus-backup-cron.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 19 * * * root  $SCRIPT >> $LOG 2>&1
EOF
chmod 0644 "$CRON_FILE"

echo "==> writing $LOGROTATE"
cat > "$LOGROTATE" <<EOF
$LOG {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 0644 root root
}
EOF

touch "$LOG"
chown root:root "$LOG"
chmod 0644 "$LOG"

cat <<EOF

==> Next manual steps (one-time):

  1. Verify prometheus command includes --web.enable-admin-api.
     Currently docker-compose.yml has --web.enable-lifecycle; the
     snapshot endpoint needs --web.enable-admin-api separately.
     Edit docker-compose.yml and add that flag, then:
         sudo docker compose up -d --force-recreate prometheus

  2. Run the backup script once by hand to verify:
         sudo $SCRIPT

  3. Then let cron take over. First automatic run at 19:00 UTC.
EOF
