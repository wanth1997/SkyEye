#!/usr/bin/env bash
# Trigger a Prometheus TSDB snapshot and sync it to S3.
#
# Prerequisites:
#   - prometheus container is running with --web.enable-admin-api
#   - EC2 has IAM role permissions to write to s3://skyeye-prometheus-snapshots
#   - aws CLI installed
#
# Installed as cron by scripts/install-prometheus-backup-cron.sh, runs daily
# at 03:00 Asia/Taipei (= 19:00 UTC).

set -euo pipefail

BUCKET="skyeye-prometheus-snapshots"
REGION="ap-northeast-1"
PROM_URL="http://127.0.0.1:9090"
DATA_VOLUME="skyeye_prometheus_data"

# Volume mountpoint on host (Docker-managed volume)
VOL_PATH="/var/lib/docker/volumes/${DATA_VOLUME}/_data"

if [ ! -d "$VOL_PATH" ]; then
  echo "$(date -u +%FT%TZ) ERR: $VOL_PATH not found; is prometheus volume named differently?" >&2
  exit 1
fi

# 1. Ask prometheus to take a snapshot
SNAP_ID=$(curl -sS -XPOST "${PROM_URL}/api/v1/admin/tsdb/snapshot" | jq -r '.data.name // empty')
if [ -z "$SNAP_ID" ]; then
  echo "$(date -u +%FT%TZ) ERR: snapshot API returned no name — is --web.enable-admin-api set?" >&2
  exit 2
fi

SNAP_DIR="${VOL_PATH}/snapshots/${SNAP_ID}"
if [ ! -d "$SNAP_DIR" ]; then
  echo "$(date -u +%FT%TZ) ERR: expected snapshot dir $SNAP_DIR not found" >&2
  exit 3
fi

# 2. Sync to S3 under /YYYY-MM-DD/
DATE=$(date -u +%Y-%m-%d)
S3_DEST="s3://${BUCKET}/${DATE}/"

echo "$(date -u +%FT%TZ) ==> uploading $SNAP_DIR → $S3_DEST"
aws s3 sync --region "$REGION" --only-show-errors "$SNAP_DIR" "$S3_DEST"

# 3. Clean up local snapshot dir (it's been uploaded)
# Prometheus keeps snapshots forever if you don't prune; it's just hardlinks + WAL slices.
sudo rm -rf "$SNAP_DIR" 2>/dev/null || rm -rf "$SNAP_DIR" || true

SIZE=$(aws s3 ls --region "$REGION" --recursive "s3://${BUCKET}/${DATE}/" --summarize \
  | grep 'Total Size' | awk '{print $3}')
echo "$(date -u +%FT%TZ) ==> backup OK: $DATE, ${SIZE:-?} bytes"
