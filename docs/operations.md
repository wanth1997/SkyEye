# SkyEye operations playbook

Day-2 reference: what to do when, by whom, and how often. If you're reading this for the first time, read top-to-bottom; for incidents, jump to the matching section.

## Daily rhythm (2 minutes)

Morning check (9:00-10:00 Taipei):

1. **Telegram group** — expect one silent `DailyHeartbeat` message per 24 h. If absent for 2+ days, the alert pipeline has a problem somewhere (Prom ↔ AM ↔ Telegram). Investigate even if Grafana looks fine.
2. **Grafana Overview** (https://grafana.wanbrain.com) — 30-second glance:
   - `Active alerts (High/Medium)` = 0 — green
   - `Products UP` == product count — nothing has fallen off
   - `24h Telegram 通知` ≥ 1 — pipeline lived through the night
3. **Scroll Telegram group** — anything overnight you may have slept through.

If all three are fine, you're done. Total: under 2 minutes.

## Weekly (15 minutes, Monday)

1. **Dashboard hygiene** — open `grafana/dashboards/` in git, check nothing drifted (UI edits bypass provisioning for a poll cycle; if someone touched UI and didn't export, the file gets reverted on restart).
2. **Review the week's alert volume** — anything that fired > 3 times probably wants tuning:
   ```
   count by (alertname) (changes(ALERTS_FOR_STATE[7d]))
   ```
3. **Silences** — check `http://127.0.0.1:9093/#/silences`; delete any that outlived their purpose.
4. **Loki retention** — quick check `aws s3 ls s3://skyeye-loki-chunks/ --summarize`. Should stay under ~5 GB.

## Monthly (30 minutes)

1. **Alert rule review** — do we need any new rules? Any that have never fired? (Use `count_over_time(ALERTS_FOR_STATE[30d])` to find.)
2. **Disk forecast** — in Grafana Hosts dashboard, look at 30-day disk growth trend per host.
3. **Image pins** — verify versions in `docker-compose.yml` are current-ish. Bump quarterly, not monthly.
4. **Backup verification** — run steps 1-3 of "Restore Prometheus TSDB from S3 snapshot" below against the newest prefix, then delete the staging directory with `sudo rm -rf /var/lib/skyeye-restore/<date>`. Prometheus keeps running and live data is not touched.

## Quarterly (1-2 hours)

1. **Secret rotation** (see "Rotating secrets" below):
   - Telegram bot token
   - CF Access Service Token
   - Grafana admin password (unless strictly via SSO)
2. **Image bumps** — update pinned versions in `docker-compose.yml`, rebuild, verify.
3. **Alert tuning** — based on monthly review, refine `for:` clauses and thresholds. Kill dead rules.
4. **Dashboard audit** — remove dashboards no one opens (check `Usage` in Grafana).
5. **OS patching** — monitoring-prod Ubuntu 24.04 upgrades; PPClub Ubuntu 20.04 (EOL, **plan upgrade this quarter**).

## Yearly

1. **SSL cert on ppclub.tw** — ACME auto-renew via Caddy; 14-day alert gives 16-day buffer. If alert ever fires, the renew path is broken.
2. **Service Token refresh** — create a new CF Access Service Token, re-run agent setup on each host, delete old token after confirming all agents swapped.
3. **Review `monitoring-plan-v2.md`** — revisit assumptions (traffic, retention, budget).

---

## Emergency playbook

### A Telegram 🚨 High fires

1. Click the runbook link in the message → runbooks/*.md on GitHub. Follow the steps.
2. If unrecoverable within 15 min, acknowledge in Telegram (reply to the bot message with context so team sees it), silence the alert for 1 h while you work.
3. After resolution, note cause in `runbooks/` or an incident doc. If a new class of problem, add a new rule.

### SkyEye itself stops paging (no alerts, no heartbeat)

Symptom: no silent `DailyHeartbeat` in Telegram for 2+ mornings, `24h Telegram 通知` reads 0.

1. **UptimeRobot** — check your dashboard (https://uptimerobot.com). If ppclub.tw is still being probed, your monitoring stack is silent but the external probe is alive.
2. **SSH monitoring-prod**:
   ```bash
   sudo docker compose -f /home/ubuntu/SkyEye/docker-compose.yml ps
   # All 6 containers should be Up
   sudo docker compose -f /home/ubuntu/SkyEye/docker-compose.yml logs --tail=50 alertmanager prometheus grafana loki cloudflared
   ```
3. **Tunnel down?** — `sudo docker compose restart cloudflared`. Usually recovers within 30 s.
4. **Config broken?** — `sudo docker compose config --quiet` to validate. Revert last commit if needed.
5. **Disk full on monitoring-prod?** — run runbook `disk-full.md` against the monitoring host itself.

### Restore Prometheus TSDB from S3 snapshot

> **This procedure has never been rehearsed, and no existing backup has ever been proven restorable.** Each `s3://skyeye-prometheus-snapshots/<date>/` prefix has no completion marker, so a prefix can look complete and still be partial. Treat every step's output as evidence, not as a formality.

Live data stays intact until new data is ready:

- Steps 1-3 run while Prometheus keeps serving. They write only to a staging directory, and a failure there costs nothing.
- Step 4 is the only step that touches live data. It renames `_data` aside after step 3 has passed. Nothing is deleted or overwritten, and step 6 renames it back.
- Each step runs as one script that stops at its first failing command. If a step prints `STOP` or does not end in `OK`, do not run the next one.

Before you start:

- Step 4 needs Wan's explicit approval and stops Prometheus, so no alerts are evaluated until it is back. The downtime has not been measured.
- A snapshot has no WAL. Anything after the backup is missing from the restored data and stays only in the renamed-aside copy.
- Blocks past the 30-day retention are deleted when Prometheus starts on the restored data.
- Backups from before 2026-11-02 bring back the purged `tnauqquant-prod-1` series.
- Prefix dates are UTC: the 03:00 Taipei run on 11-02 is under `2026-11-01/`.
- Avoid 19:00 UTC, when the nightly backup runs.

**1. Pick a prefix and check space.** Paste the first block in the shell you will use for every step. If the session drops, paste it again; the steps fail harmlessly without it.

```bash
SNAP=2026-11-01    # newest prefix unless you have a reason; list them below
aws s3 ls --region ap-northeast-1 s3://skyeye-prometheus-snapshots/ | tail -5

restore_step() {
  sudo bash -euo pipefail -c "
    SNAP='$SNAP'
    BUCKET=s3://skyeye-prometheus-snapshots
    REGION=ap-northeast-1
    VOLUME=/var/lib/docker/volumes/skyeye_prometheus_data
    STAGE=/var/lib/skyeye-restore/\$SNAP
    stop() { echo \"STOP: \$*\" >&2; exit 1; }
    [[ \$SNAP =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\$ ]] || stop 'SNAP must be YYYY-MM-DD'
    cd /home/ubuntu/SkyEye
    $(cat)"
}
```

```bash
restore_step <<'EOF'
[ ! -e "$STAGE" ] || stop "$STAGE already exists; inspect it, then remove it or continue from step 2"
LISTING=$(aws s3 ls --region "$REGION" --recursive --summarize "$BUCKET/$SNAP/")
OBJECTS=$(awk '/Total Objects:/ {print $3}' <<<"$LISTING")
BYTES=$(awk '/Total Size:/ {print $3}' <<<"$LISTING")
[ "$OBJECTS" -gt 0 ] || stop "$BUCKET/$SNAP/ is empty"
mkdir -p "$STAGE/data"
# Step 4 must be a rename. Across filesystems mv turns into a slow copy.
[ "$(stat -c %d "$STAGE")" = "$(stat -c %d "$VOLUME")" ] || stop "staging is not on the volume's filesystem"
NEED=$((BYTES * 2 + 1024 * 1024 * 1024))
AVAIL=$(df -B1 --output=avail "$STAGE" | tail -1 | tr -d ' ')
[ "$AVAIL" -ge "$NEED" ] || stop "need $NEED bytes free, have $AVAIL"
echo "OK: $OBJECTS objects, $BYTES bytes, $AVAIL bytes free"
EOF
```

**2. Download to staging.** Safe to re-run; `sync` picks up where it stopped.

```bash
restore_step <<'EOF'
[ -d "$STAGE/data" ] || stop "run step 1 first"
aws s3 sync --region "$REGION" --only-show-errors "$BUCKET/$SNAP/" "$STAGE/data/"
echo "OK: downloaded to $STAGE/data"
EOF
```

**3. Verify staging.** `promtool` silently skips a block with no `meta.json`, and Prometheus only logs a line for it, so each block is checked file by file first. A block missing `index` or `chunks` would stop Prometheus from starting.

```bash
restore_step <<'EOF'
rm -f "$STAGE/VERIFIED"
cd "$STAGE/data"

# Staging must match what S3 holds now.
LISTING=$(aws s3 ls --region "$REGION" --recursive --summarize "$BUCKET/$SNAP/")
OBJECTS=$(awk '/Total Objects:/ {print $3}' <<<"$LISTING")
BYTES=$(awk '/Total Size:/ {print $3}' <<<"$LISTING")
[ "$(find . -type f | wc -l)" -eq "$OBJECTS" ] || stop "file count differs from S3 ($OBJECTS)"
[ "$(find . -type f -printf '%s\n' | awk '{s += $1} END {printf "%d", s}')" -eq "$BYTES" ] || stop "size differs from S3 ($BYTES)"

# Every top-level entry must be a whole block.
BLOCKS=0
for entry in *; do
  [[ -d $entry && $entry =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]] || stop "unexpected entry: $entry"
  [ -s "$entry/meta.json" ] || stop "$entry: no meta.json"
  jq -e --arg ulid "$entry" '.ulid == $ulid' "$entry/meta.json" >/dev/null || stop "$entry: bad meta.json"
  [ -s "$entry/index" ] || stop "$entry: no index"
  [ -d "$entry/chunks" ] || stop "$entry: no chunks"
  SEGMENTS=$(find "$entry/chunks" -type f | wc -l)
  [ "$SEGMENTS" -gt 0 ] || stop "$entry: no chunks"
  LAST=$(find "$entry/chunks" -type f -printf '%f\n' | sort | tail -1)
  [ "$((10#$LAST))" -eq "$SEGMENTS" ] || stop "$entry: chunk segments missing, last is $LAST of $SEGMENTS"
  BLOCKS=$((BLOCKS + 1))
done
[ "$BLOCKS" -gt 0 ] || stop "no blocks"

# promtool writes a sandbox directory into the data dir, so this mount cannot be :ro.
chown -R 65534:65534 "$STAGE/data"
IMAGE=$(grep -oE 'prom/prometheus:[^[:space:]]+' /home/ubuntu/SkyEye/docker-compose.yml | head -1)
LISTED=$(docker run --rm --network none --entrypoint /bin/promtool -v "$STAGE/data:/data" "$IMAGE" tsdb list -r /data)
echo "$LISTED"
[ "$(tail -n +2 <<<"$LISTED" | wc -l)" -eq "$BLOCKS" ] || stop "promtool lists a different block count than $BLOCKS"

# A block that never reached S3 leaves no trace except a hole in the timeline.
jq -rs 'sort_by(.minTime) | reduce .[] as $b ({end: null, out: [], newest: 0};
    (if .end != null and $b.minTime - .end > 3600000
     then .out += ["GAP \(.end / 1000 | floor | todate) -> \($b.minTime / 1000 | floor | todate)"] else . end)
    | .end = ([.end, $b.maxTime] | max) | .newest = .end)
  | .out + ["NEWEST \(.newest / 1000 | floor | todate)"] | .[]' ./*/meta.json | tee "$STAGE/timeline"
if grep -q '^GAP' "$STAGE/timeline"; then
  stop "timeline has gaps; a gap can be a real outage or a missing block. Compare with an older prefix"
fi
touch "$STAGE/VERIFIED"
echo "OK: $BLOCKS blocks verified. NEWEST should be close to ${SNAP}T19:00Z"
EOF
```

If a check fails, this prefix is not usable: repeat from step 1 with an older one. Only if you can account for a reported gap as a real Prometheus outage, record why and run `sudo touch /var/lib/skyeye-restore/$SNAP/VERIFIED`. Overlapping blocks are expected after a same-day rerun and are not reported here.

**4. Switch (needs approval).** Prometheus is down from here until step 5 passes.

```bash
restore_step <<'EOF'
[ -f "$STAGE/VERIFIED" ] || stop "step 3 has not passed"
[ -d "$STAGE/data" ] || stop "$STAGE/data is gone; already switched?"
[ -d "$VOLUME/_data" ] || stop "no live data directory at $VOLUME/_data"
# The bracket stops pgrep from matching this script's own command line.
! pgrep -f '[b]ackup-prometheus.sh' >/dev/null || stop "backup is running; wait for it"
PARKED=$VOLUME/_data.pre-restore-$(date -u +%Y%m%dT%H%M%SZ)
docker compose stop prometheus
[ -z "$(docker compose ps -q --status running prometheus)" ] || stop "prometheus is still running"
echo "$PARKED" > "$STAGE/PARKED"
mv "$VOLUME/_data" "$PARKED"
mv "$STAGE/data" "$VOLUME/_data"
chown --reference="$PARKED" "$VOLUME/_data"
chmod --reference="$PARKED" "$VOLUME/_data"
docker compose up -d prometheus
echo "OK: live data is at $PARKED; continue with step 5"
EOF
```

**5. Check the restored Prometheus.** If this fails, go straight to step 6.

```bash
restore_step <<'EOF'
for _ in $(seq 1 60); do
  curl -fsS http://127.0.0.1:9090/-/ready >/dev/null 2>&1 && break
  sleep 5
done
curl -fsS http://127.0.0.1:9090/-/ready >/dev/null || stop "not ready after 5 minutes; check logs and roll back"
query() { curl -fsS http://127.0.0.1:9090/api/v1/query --data-urlencode "query=$1" ${2:+--data-urlencode "time=$2"}; }
LOADED=$(query prometheus_tsdb_blocks_loaded | jq -r '.data.result[0].value[1] // 0')
SERIES=$(query 'count(up)' "${SNAP}T18:00:00Z" | jq -r '.data.result[0].value[1] // 0')
[ "$LOADED" -gt 0 ] || stop "no blocks loaded"
[ "$SERIES" -gt 0 ] || stop "no data at ${SNAP}T18:00Z"
echo "OK: $LOADED blocks loaded, $SERIES up series at ${SNAP}T18:00Z"
EOF
```

`LOADED` can be below the block count from step 3 once blocks past retention are dropped. Then check Grafana Overview and one product dashboard over the restored range.

**6. Roll back.** Use this if step 4 or 5 fails, or if the restored data is wrong. It restores the renamed-aside data, and anything Prometheus received since step 4 stays only in the `_data.failed-restore-*` copy.

```bash
restore_step <<'EOF'
PARKED=$(cat "$STAGE/PARKED")
[ -d "$PARKED" ] || stop "$PARKED not found; nothing to roll back to"
docker compose stop prometheus
[ -z "$(docker compose ps -q --status running prometheus)" ] || stop "prometheus is still running"
if [ -e "$VOLUME/_data" ]; then
  mv "$VOLUME/_data" "$VOLUME/_data.failed-restore-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mv "$PARKED" "$VOLUME/_data"
docker compose up -d prometheus
echo "OK: previous data is live again; wait for /-/ready and check Grafana"
EOF
```

**7. Clean up, later.** Keep `_data.pre-restore-*` for at least 24 hours, and until Wan agrees the restore is good: it is the only way back, and it holds both the data since the backup and `snapshots/`. Deleting it is the one irreversible step, so list what is there and remove each path by hand:

```bash
sudo ls -d /var/lib/docker/volumes/skyeye_prometheus_data/_data.* /var/lib/skyeye-restore/*
```

On a rebuilt host the same steps apply: `docker compose up -d` has created an empty `_data`, and step 4 renames that aside.

### Full stack rebuild (if this machine dies)

1. Provision new EC2 (arm64, Ubuntu 24.04, 40 GB gp3, same VPC subnet).
2. Update `infra/iam/bootstrap.sh` with new instance ID; re-run (it's idempotent, will attach the existing role to the new instance).
3. `bash scripts/bootstrap-monitoring-ec2.sh` — installs Docker + AWS CLI.
4. `git clone` this repo, populate `alertmanager/secrets/` and `cloudflared/credentials.json` from 1Password.
5. `docker compose up -d`
6. `cloudflared tunnel route dns skyeye-monitoring-prod <hostnames>` — re-point DNS (if tunnel UUID is the same, DNS may still be valid — skip if so).
7. Restore Prometheus data from latest S3 snapshot (see above).
8. Verify via Grafana Overview.

Estimated recovery: 45-60 minutes from cold start.

### Upgrade cloudflared

Use this for quarterly image bumps and for Cloudflare security notices. Run it on monitoring-prod after the pin change in `docker-compose.yml` has merged.

The tunnel runs a single replica, so the restart drops connections for a few seconds. Alloy remote-write and Loki push retry, so a short gap in metrics and logs is expected and fine.

1. Pull the repo and the new image:
   ```bash
   cd /home/ubuntu/SkyEye
   git pull
   sudo docker compose pull cloudflared
   ```
2. Recreate the container. A plain `restart` keeps running the old image; `up -d` replaces it:
   ```bash
   sudo docker compose up -d cloudflared
   ```
3. Check the running version matches the pin:
   ```bash
   sudo docker compose exec cloudflared cloudflared --version
   # or: sudo docker compose logs --tail=30 cloudflared   (look for "Version <pin>" and "Registered tunnel connection")
   ```
4. In the Cloudflare dashboard (Zero Trust → Networks → Tunnels), `skyeye-monitoring-prod` shows **Healthy**.
5. https://grafana.wanbrain.com loads, and the Overview `Products UP` panel recovers within a few minutes.

**Rollback:** set the `cloudflared` image back to the previous pin in `docker-compose.yml` (revert the commit), then `sudo docker compose pull cloudflared && sudo docker compose up -d cloudflared` and repeat steps 3-5.

---

## Rotating secrets

Frequency: every 180 days, or immediately on suspected leak.

### Telegram bot token

```
Telegram → @BotFather → /revoke → select your bot → new token shown
```

Update `alertmanager/secrets/tg_token` with new value, restart AM:

```bash
read -rs NEW < /dev/tty
printf '%s' "$NEW" | sudo tee /home/ubuntu/SkyEye/alertmanager/secrets/tg_token > /dev/null
unset NEW
sudo docker compose restart alertmanager
```

Old token is instantly invalidated. Save new token to 1Password.

### CF Access Service Token (`skyeye-agent-push`)

This is the token every Alloy agent uses. Rotating it means every product host needs its agent config re-rendered.

1. In CF Zero Trust → Access → Service Auth → find `skyeye-agent-push` → **rotate** (generates new secret, same name).
2. For each product host:
   ```bash
   ssh host && cd /home/ubuntu/skyeye-agent && git pull
   # re-export the new CF_ACCESS_CLIENT_ID / SECRET
   sudo -E bash agents/alloy/setup.sh
   ```
3. Verify in central Grafana that `up{product="X"}` stays 1 during and after.

### Grafana admin password

```
OR openssl rand -base64 48 | tr -d '+/=' | head -c 32
```

Update `.env` on monitoring-prod, `docker compose up -d --force-recreate grafana`. Save to 1Password.

Note: `auth.proxy` + CF Access is the primary path; admin password is only used for emergency API/CLI access.

---

## Adding a new product

See [`onboarding-new-product.md`](./onboarding-new-product.md). 30-minute checklist, no AI assistance needed after the first product.

## Retiring a product

1. Stop the Alloy agent on the target host: `sudo bash /home/ubuntu/skyeye-agent/agents/alloy/uninstall.sh`
2. Metrics / logs for that product age out per retention (30 days).
3. Silence any stale alerts: `http://127.0.0.1:9093/#/silences` — matcher `product=PRODUCT`.
4. Delete the product's dashboard folder: `git rm -r grafana/dashboards/<ProductName>/`
5. If the product's alert rules have product-specific selectors that no longer make sense, trim.

---

## Cost notes

Month-1 bill (AWS, Tokyo):
- EC2 t4g.medium on-demand: ~$24
- EBS 40 GB gp3: $3.20
- S3 (Loki chunks ~5 GB, snapshots ~300 MB): <$1
- Cloudflare Tunnel: $0
- **Total: ~$28/mo**

Reserved-instance discount (1-yr, no upfront) drops EC2 to ~$15 → **$19/mo**.

New product added = $0 incremental (agent runs on the product's own host).

## FAQ

**Q: Why are there Low alerts that are always firing?**
A: `DailyHeartbeat` is a `vector(1)` rule — intentional. Its daily silent Telegram message proves the full Prom→AM→Telegram path is alive. If it stops arriving, something's broken.

**Q: Why does the scrape `job` label say `integrations/unix` instead of `node-exporter`?**
A: Alloy's `prometheus.exporter.unix` integration sets its own job name. Our rules don't filter by `job` so it doesn't matter.

**Q: Why does `exported_job` exist on some metrics?**
A: Label collision. `job` is reserved by Prometheus scrape_configs, so any app-side metric with a `job` label gets its label renamed to `exported_job` on ingestion. If you add a scheduler-like metric, avoid naming a label `job`.

**Q: My alert didn't reach Telegram.**
A: Check `alertmanager_notifications_total{integration="telegram"}` — if it incremented, AM sent but your client didn't surface it (scroll up in the group, check notification settings). If it didn't increment, check `alertmanager_notifications_failed_total` and AM logs.

**Q: Can I add a new alert rule without redeploying?**
A: Yes. Edit `prometheus/rules/*.yml`, then `curl -X POST http://127.0.0.1:9090/-/reload`. Changes are live within seconds.

**Q: I made a UI edit in Grafana and it disappeared.**
A: Provisioning reloads JSON from disk every 60 s. Your UI edits are temporary. To persist: Share → Export → Save to file → overwrite `grafana/dashboards/<Folder>/<uid>.json` → git commit.
