# 1. Stop prometheus
sudo docker compose stop prometheus

# 2. Pick a snapshot date
aws s3 ls s3://skyeye-prometheus-snapshots/

# 3. Sync to the volume data dir
SNAP=2026-04-23
sudo rm -rf /var/lib/docker/volumes/skyeye_prometheus_data/_data/*
sudo mkdir -p /var/lib/docker/volumes/skyeye_prometheus_data/_data/
sudo aws s3 sync "s3://skyeye-prometheus-snapshots/${SNAP}/" /var/lib/docker/volumes/skyeye_prometheus_data/_data/

# 4. Fix perms and restart
sudo chown -R nobody:nogroup /var/lib/docker/volumes/skyeye_prometheus_data/_data/
sudo docker compose up -d prometheus
