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
4. **Backup verification** — run steps 1-3 of "Restore Prometheus TSDB from S3 snapshot" below against the newest prefix, then delete the staging directory with `sudo rm -rf /var/lib/skyeye-restore/<date>`. Step 3 can take hours, so leave it running in `tmux`. Prometheus keeps running and live data is not touched. Once `scripts/restore-prometheus.sh` is deployed, run its `fetch` and `verify` on the newest generation instead, then delete `/var/lib/skyeye-restore/<id>` the same way.

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
2. If unrecoverable within 15 min, acknowledge in Telegram (reply to the bot message with context so team sees it), silence the alert for 1 h while you work. Never silence `TradingCriticalSafetyState` alone: see [the Trading silence rule](../runbooks/trading-alert-promotion.md#silence-規則).
3. After resolution, note cause in `runbooks/` or an incident doc. If a new class of problem, add a new rule.

### SkyEye itself stops paging (no alerts, no heartbeat)

Symptom: no silent `DailyHeartbeat` in Telegram for 2+ mornings, `24h Telegram 通知` reads 0.

1. **UptimeRobot** — check your dashboard (https://uptimerobot.com). If ppclub.tw is still being probed, your monitoring stack is silent but the external probe is alive.
2. **SSH monitoring-prod**:
   ```bash
   sudo docker compose -f /home/ubuntu/SkyEye/docker-compose.yml ps
   # All 7 services should be Up (6 until node-exporter is deployed)
   sudo docker compose -f /home/ubuntu/SkyEye/docker-compose.yml logs --tail=50 alertmanager prometheus grafana loki cloudflared
   ```
3. **Tunnel down?** — `sudo docker compose restart cloudflared`. Usually recovers within 30 s.
4. **Config broken?** — `sudo docker compose config --quiet` to validate. Revert last commit if needed.
5. **Disk full on monitoring-prod?** — run runbook `disk-full.md` against the monitoring host itself.

### Restore Prometheus TSDB from S3 snapshot

> **This procedure has never been rehearsed, and no existing backup has ever been proven restorable.** Each `s3://skyeye-prometheus-snapshots/<date>/` prefix has no completion marker, so a prefix can look complete and still be partial. Treat every step's output as evidence, not as a formality.

**`scripts/restore-prometheus.sh` replaces the numbered steps once it is deployed.** As of 2026-11-06 it is on master but not on monitoring-prod, so the numbered steps are the only path on the host. The new backup script publishes to `generations/<date>/<id>/` with a `MANIFEST.json`, and the numbered steps read date prefixes only, so a generation needs the tool. The tool also reads old date prefixes with `--legacy-prefix YYYY-MM-DD`.

```bash
cd /home/ubuntu/SkyEye
sudo scripts/restore-prometheus.sh list
sudo scripts/restore-prometheus.sh fetch <id>
sudo scripts/restore-prometheus.sh verify <id>        # hours: run it in tmux
sudo scripts/restore-prometheus.sh switch <id> --yes  # needs Wan's approval; add --fresh only if _data is missing or empty
```

A failed health check after `switch` rolls back by itself. `rollback` undoes the last switch, and `finalize --yes` deletes the renamed-aside data at least 24 hours later. `--help` is the full reference. The tool passed a drill against a real Prometheus in a local VM, with `aws` faked (`tests/backup/README.md`). Real S3 has not been tested.

**Time estimate.** These are estimates for a 1.9 GB generation, and none has been measured on monitoring-prod. The drill's 2 seconds of downtime was on 200 KB of data and does not scale.

| Stage | Estimate | Basis |
|---|---|---|
| Fetch | Tens of seconds | Uploads took 8-13 seconds in the 2026-11-04 audit; download speed not measured |
| sha256 and file checks | Tens of seconds | Not measured |
| `promtool` full read | 1-4 hours | Earlier estimate, not measured on the host |
| Switch downtime | About 1-2 minutes | Stop limit of 60 seconds, plus startup load |

The total is about 1-4 hours, nearly all of it the full read, or about 5 minutes without it. `switch` hashes the staged data again before it stops Prometheus; that takes tens of seconds and is not downtime.

Live data stays intact until new data is ready:

- Steps 1-3 run while Prometheus keeps serving. They write only to a staging directory, and a failure there costs nothing.
- Step 4 is the only step that touches live data. It renames `_data` aside after step 3 has passed. Nothing is deleted or overwritten, and step 6 renames it back.
- Each step runs as one script that stops at its first failing command. If a step prints `STOP` or does not end in `OK`, do not run the next one.

Before you start:

- Step 4 needs Wan's explicit approval and stops Prometheus, so no alerts are evaluated until it is back. The downtime has not been measured; the estimate above is 1-2 minutes.
- A snapshot has no WAL. Anything after the backup is missing from the restored data and stays only in the renamed-aside copy.
- Blocks past the 30-day retention are deleted when Prometheus starts on the restored data.
- Backups from before 2026-11-02 bring back the purged `tnauqquant-prod-1` series.
- Prefix dates are UTC: the 03:00 Taipei run on 11-02 is under `2026-11-01/`.
- Avoid 19:00 UTC, when the nightly backup runs.

**1. Pick a prefix and check space.** Start `tmux` first, because step 3 takes hours and must survive an SSH drop. Paste the first block in the shell you will use for every step. If the session drops, paste it again; the steps fail harmlessly without it.

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

File checks cannot see a final chunk segment that never reached S3: the listing and the numbering still agree. So this step reads every sample of every block with `promtool tsdb dump`. That command exits 0 with no error when it hits a missing chunk and simply stops early, so the check is the sample count against `meta.json`, not the exit code.

The read is slow. Plan for 1 to 4 hours on a 1.9 GB backup. That is an estimate: synthetic data read at about 40 minutes per billion samples on one fast core, and a backup that size likely holds 1-3 billion samples. The step prints the real total first. It uses one CPU and about 30 MB of memory, and no extra disk, because the blocks are hardlinked and the output goes straight to a counter.

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

# Read every sample, one block at a time, through a hardlinked view: dump needs
# a wal/ directory, and without tombstones it must return exactly numSamples.
echo "Reading $(jq -s 'map(.stats.numSamples) | add' ./*/meta.json) samples in $BLOCKS blocks"
for entry in *; do
  rm -rf "$STAGE/check"
  mkdir -p "$STAGE/check/wal"
  cp -al "$entry" "$STAGE/check/"
  rm -f "$STAGE/check/$entry/tombstones"
  EXPECTED=$(jq -r '.stats.numSamples' "$entry/meta.json")
  ACTUAL=$(docker run --rm --network none --cpus=1 --entrypoint /bin/sh -v "$STAGE/check:/check:ro" "$IMAGE" \
    -c 'promtool tsdb dump --sandbox-dir-root=/tmp /check | wc -l')
  [ "$ACTUAL" -eq "$EXPECTED" ] || stop "$entry: read $ACTUAL of $EXPECTED samples, chunk data is missing"
  echo "$entry: $ACTUAL samples"
done
rm -rf "$STAGE/check"

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
# Read /metrics, not a query: a query has no sample until the first self-scrape,
# about 15 seconds after ready. Give it 2 minutes before calling this a failure.
LOADED=0
for _ in $(seq 1 24); do
  LOADED=$(curl -fsS http://127.0.0.1:9090/metrics | awk '$1 == "prometheus_tsdb_blocks_loaded" {print $2}' || true)
  [ "${LOADED:-0}" -gt 0 ] && break
  sleep 5
done
[ "${LOADED:-0}" -gt 0 ] || stop "no blocks loaded after 2 minutes; check logs and roll back"
SERIES=$(curl -fsS http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=count(up)' \
  --data-urlencode "time=${SNAP}T18:00:00Z" | jq -r '.data.result[0].value[1] // 0')
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

On a rebuilt host the same steps apply: `docker compose up -d` has already started Prometheus, so `_data` holds what it wrote since then, and step 4 renames that aside.

### Full stack rebuild (if this machine dies)

1. Provision new EC2 (arm64, Ubuntu 24.04, 30 GB gp3, same VPC subnet). The current root disk is 30 GB.
2. Update `infra/iam/bootstrap.sh` with new instance ID; re-run (it's idempotent, will attach the existing role to the new instance).
3. `bash scripts/bootstrap-monitoring-ec2.sh` — installs Docker + AWS CLI. The AWS CLI is a pinned release (2.39.3) and is installed only if the download matches the sha256 in the script; a mismatch stops the script before anything is unpacked. The comment above the pin says how to move it.
4. `git clone` this repo, populate `alertmanager/secrets/` and `cloudflared/credentials.json` from 1Password.
5. `docker compose up -d`
6. `cloudflared tunnel route dns skyeye-monitoring-prod <hostnames>` — re-point DNS (if tunnel UUID is the same, DNS may still be valid — skip if so).
7. Restore Prometheus data from latest S3 snapshot (see above). With the tool, use `switch <id> --yes`. Step 5 started Prometheus, so `_data` is not empty and `--fresh` would be refused. The new host's own data stays as `_data.pre-restore-*`.
8. Verify via Grafana Overview.

Estimated recovery: the 45-60 minutes from cold start written here earlier predates the full read in step 7, which takes about 1-4 hours by itself. Neither number has been measured.

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

### Deploy a commit that adds a container

`scripts/central-deploy` refuses a change that needs a container recreate, such as `docker-compose.yml`. Use this order for the `node-exporter` service and its `monitoring-host` job, which arrive with `bd63d1a5` (PR #61). It has run on a local Compose stack and against stubbed docker, not on monitoring-prod.

Set up the Grafana token first: see [the one-time setup](../README.md#one-time-setup-for-scriptscentral-deploy). `HostDiskCritical` and `HostOOM` are non-shadow High, so they reach Telegram as soon as their conditions hold. Check disk and memory in step 0.

```bash
cd /home/ubuntu/SkyEye

# 0. Checks
df -h / ; free -m ; findmnt -no PROPAGATION /     # the last one must print shared
git status --short ; git fetch origin master
git diff --name-only HEAD origin/master           # docker-compose.yml must be the only recreate path
TARGET=$(git rev-parse origin/master)             # must be the newest commit

# 1. Move the checkout first. Compose reads this file.
git merge --ff-only "$TARGET"

# 2. Start the container. Always name the service.
sudo docker compose up -d node-exporter
sudo docker compose ps node-exporter

# 3. Validate, then reload and record
scripts/central-deploy --dry-run --manual-applied "$TARGET"
scripts/central-deploy --manual-applied "$TARGET"
```

**`--manual-applied` does not check containers.** It reports `done` and records the commit even when `node-exporter` never started. It also accepts every recreate path in the range, including `cloudflared/config.yml`, which is why step 0 lists them. Confirm the result yourself:

```bash
q() { curl -fsS --get http://127.0.0.1:9090/api/v1/query --data-urlencode "query=$1" | jq -c '.data.result'; }
q 'up{job="monitoring-host"}'                                # value 1
q 'count(node_filesystem_avail_bytes{job="monitoring-host",server_id="monitoring-prod",mountpoint="/"})'  # value 1
q 'node_filesystem_avail_bytes{job="monitoring-host",server_id="monitoring-prod",mountpoint="/host"}'     # []
q '(1 - node_memory_MemAvailable_bytes{server_id="monitoring-prod"} / node_memory_MemTotal_bytes{server_id="monitoring-prod"}) * 100'  # below 90
q 'ALERTS{server_id="monitoring-prod",alertstate="firing"}'  # []
```

If `up` is 0, no alert fires: no rule watches this job, and `HostDisk*` stops evaluating instead of reporting a problem. It shows only on dashboards: the offline panels on Overview (離線產品數) and Stack health (離線目標數) turn red. `sudo docker compose up -d node-exporter` recovers it without a reload.

If `node-exporter` will not start, read the error first. The `rslave` mount needs `/` to be a shared mount; this has not been tested on EC2. The failure stays with this one service.

**Rollback.** Remove the container before the revert, because compose no longer knows the service afterwards. The target is down between the two steps, and no alert fires.

```bash
sudo docker compose rm -sf node-exporter
# merge the revert PR, then:
git fetch origin master
TARGET=$(git rev-parse origin/master)
git merge --ff-only "$TARGET"
scripts/central-deploy --manual-applied "$TARGET"
```

### Grafana sign-in (Cloudflare Access JWT)

Cloudflare Access signs a JWT for every request it lets through to `grafana.wanbrain.com` and sends it in `Cf-Access-Jwt-Assertion`. Grafana checks the signature against the team keys at `https://wanbrain.cloudflareaccess.com/cdn-cgi/access/certs` and accepts only the AUD tag of the `SkyEye Grafana` application and the team issuer (`GF_AUTH_JWT_*` in `docker-compose.yml`). It ignores `Cf-Access-Authenticated-User-Email`. Grafana used to trust that header from 127.0.0.1 and 172.16.0.0/12, so any process on the host or any container could sign in as anyone, an Admin included (P2-16).

- A new account is Viewer. Raise roles in Grafana (Administration → Users and access → Users). The token carries no role, and Grafana does not overwrite a role.
- An existing account is matched by email, in any case, on its first token sign-in and keeps its id, role, stars and preferences. From then on Grafana links it to the token's `sub`.
- Grafana fetches the keys when a token arrives, not at startup, and keeps them in its database for 5 minutes (`GF_AUTH_JWT_CACHE_TTL`). Once that runs out with the key URL unreachable, every browser sign-in gets 401 until the URL answers again; no restart is needed. Service account tokens, so `central-deploy`, and alerting do not depend on it. After Cloudflare rotates its signing key, sign-in can fail for up to those 5 minutes.
- Recreating the Access application, or adding a path-specific application for this hostname, gives tokens a different AUD and locks everyone out. Change `docker-compose.yml` first.
- Grafana Live (websocket) through Access is not verified. SkyEye panels do not depend on Live.
- `tests/grafana/test-access-jwt.sh` runs this configuration on the pinned image.

#### Deploying the switch from the header proxy

`central-deploy` refuses `docker-compose.yml`, so this is done by hand, with Wan at a browser. Only the Grafana UI stops, from `stop` in step 1 until the health check in step 3 passes: the database copy, the merge and the recreate. With a 1.8 MB database on a local Docker that took 1.5 s. It has not been measured on monitoring-prod, and the copy takes longer as the database grows. Prometheus, Loki, Alertmanager, Telegram and ingestion keep running, and `cloudflared` is not recreated.

**Never send `Cf-Access-Authenticated-User-Email` to monitoring-prod, not even to see a 401.** If the old configuration is still running, that request creates an Admin account.

Before step 1, Wan writes down the users and service accounts (Administration → Users and access), including their own user id.

```bash
cd /home/ubuntu/SkyEye

# 0. Checks
git status --short ; git fetch origin master
git diff --name-only HEAD origin/master           # docker-compose.yml must be the only recreate path
TARGET=$(git rev-parse origin/master)             # must be the newest commit
BEFORE=$(git rev-parse HEAD)                      # for a rollback
grep -c '^GF_ADMIN_PW=' .env                      # 1; checks the key only, never print the value
sudo docker compose exec grafana curl -fsS -o /dev/null -w '%{http_code}\n' \
  https://wanbrain.cloudflareaccess.com/cdn-cgi/access/certs   # 200: Grafana reaches the keys

# 1. Copy the database while Grafana is stopped. The UI is down from here until step 3.
sudo docker compose stop grafana
sudo docker compose cp grafana:/var/lib/grafana/grafana.db /home/ubuntu/grafana.db.pre-jwt
sudo chmod 600 /home/ubuntu/grafana.db.pre-jwt    # holds token hashes; delete it once settled
sudo sqlite3 -readonly /home/ubuntu/grafana.db.pre-jwt 'PRAGMA integrity_check'   # ok

# 2. Move the checkout. Compose reads this file.
git merge --ff-only "$TARGET"

# 3. Recreate Grafana only
sudo docker compose up -d --no-deps grafana
until curl -fsS -o /dev/null http://127.0.0.1:3000/api/health; do sleep 1; done

# 4. Sign-in checks
sudo docker compose exec grafana env | grep -E 'GF_AUTH_(PROXY|JWT)_ENABLED'   # PROXY=false, JWT=true
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/api/user       # 401
curl -s -o /dev/null -w '%{http_code}\n' -H 'Cf-Access-Jwt-Assertion: not-a-jwt' \
  http://127.0.0.1:3000/api/user                                               # 401

# 5. The Viewer service account still reads dashboards. The token goes to curl on
#    stdin, so it never reaches a command line or the output.
gv() {
  printf 'header = "Authorization: Bearer %s"\n' "$(cat /home/ubuntu/.config/skyeye/grafana-viewer-token)" |
    curl --config - -fsS -w '%{stderr}HTTP %{http_code}\n' "http://127.0.0.1:3000$1"
}
gv '/api/search?type=dash-db' | jq -e 'length > 0'                       # HTTP 200, then true
gv /api/dashboards/uid/overview-all | jq -er .meta.provisionedExternalId   # HTTP 200, then Overview/overview-all.json

# 6. Validate and record
scripts/central-deploy --dry-run --manual-applied "$TARGET"
scripts/central-deploy --manual-applied "$TARGET"
```

If sqlite3 is not installed, `sudo` answers `command not found`: skip that check and do not install a package for it. If any other part of step 1 fails, or the check prints anything but `ok`, run `sudo docker compose start grafana` and stop there. The checkout has not moved, and `start` brings back the same container.

`central-deploy` reads Grafana only for a dashboard change or on a first run with no deploy record. This change touches no dashboard, so step 5 is what checks the service account token. The token file is the one from [the one-time setup](../README.md#one-time-setup-for-scriptscentral-deploy). If a line fails, do not run step 6. `HTTP 401` means Grafana does not accept that token: replace it as in the setup and repeat step 5.

After step 4, Wan opens https://grafana.wanbrain.com in a new tab. It must open without a Grafana login page, Profile must show the same user id, the org role must be Admin and the starred dashboards must be there. `sudo docker compose logs --since 10m grafana | grep 'Failed to authenticate request'` then shows nothing new.

Every account the old proxy created is still Admin, and so is every service account made through it. The switch changes neither; reviewing them is a separate decision.

#### Rollback

This brings the old configuration back, header hole included, so use it only to let people in again. Accounts, roles and stars stay as they are; this was checked on a local copy, not on monitoring-prod. `BEFORE` is from step 0; in a new shell, use the parent of the switch commit.

```bash
cd /home/ubuntu/SkyEye
PROJECT=$(sudo docker inspect "$(sudo docker compose ps -q grafana)" \
  --format '{{index .Config.Labels "com.docker.compose.project"}}')
git show "$BEFORE:docker-compose.yml" >/tmp/docker-compose.pre-jwt.yml
sudo docker compose -p "$PROJECT" --project-directory /home/ubuntu/SkyEye \
  -f /tmp/docker-compose.pre-jwt.yml up -d --no-deps grafana
```

Open a revert PR right away. `central-deploy` compares Git, not containers, and will not notice that Grafana runs something else.

#### Locked out

Read the reason first: `sudo docker compose logs --since 10m grafana | grep 'Failed to authenticate request' | tail -5`.

| The log says | Cause | Fix |
|---|---|---|
| `invalid audience claim (aud)` | The AUD in `docker-compose.yml` is not the application's | Roll back, then fix the value in a PR |
| `invalid issuer claim (iss)` | The team domain is wrong | Roll back, then fix the value in a PR |
| `error in cryptographic primitive` | The key URL belongs to another team | Roll back, then fix the value in a PR |
| `no such host`, a timeout or a refused connection | Grafana cannot reach the key URL | Fix DNS or egress; sign-in comes back by itself. Roll back if it lasts |
| `token is expired (exp)` | The browser's Access session ran out | Sign in to Access again |

If Wan gets in but as a new Viewer account (another user id in Profile), or without Admin, set the role with the built-in admin over SSH. This turns on password login for a few minutes on the port that listens on 127.0.0.1 only; it does not bring the header back. The password lives in a 0600 file and never appears on a command line.

```bash
cd /home/ubuntu/SkyEye
install -d -m 700 /home/ubuntu/.config/skyeye
PW=/home/ubuntu/.config/skyeye/grafana-admin-pw CFG=/home/ubuntu/.config/skyeye/grafana-admin.curl
(umask 077 && python3 -c 'import secrets; print(secrets.token_urlsafe(24))' >"$PW")
(umask 077 && printf 'user = "admin:%s"\n' "$(cat "$PW")" >"$CFG")
printf 'services:\n  grafana:\n    environment:\n      - GF_AUTH_BASIC_ENABLED=true\n' >/tmp/grafana-breakglass.yml
sudo docker compose -f docker-compose.yml -f /tmp/grafana-breakglass.yml up -d --no-deps grafana
sudo docker compose exec -T grafana grafana cli admin reset-admin-password --password-from-stdin <"$PW"
G=http://127.0.0.1:3000
curl --config "$CFG" -fsS "$G/api/users/lookup?loginOrEmail=<Wan's Access email>" | jq .id
curl --config "$CFG" -fsS -X PATCH -H 'Content-Type: application/json' -d '{"role":"Admin"}' \
  "$G/api/org/users/<that id>"
sudo docker compose up -d --no-deps grafana       # password login off again
rm "$CFG"
```

The reset replaces the built-in admin password: save the new one to 1Password, then remove `$PW`. If the built-in admin's login is no longer `admin`, put its email in the curl file instead (`admin@localhost` by default).

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

Note: browsers sign in through Cloudflare Access (see [Grafana sign-in](#grafana-sign-in-cloudflare-access-jwt)); the admin password is only for the emergency steps there. Grafana reads `GF_ADMIN_PW` only when it creates its database, so changing `.env` alone does not change an existing password; `grafana cli admin reset-admin-password --password-from-stdin` does, as in those steps.

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

Monthly estimate (AWS, Tokyo). Disk and backup sizes are from the 2026-11-04 audit. Prices are not checked against a bill:
- EC2 t4g.medium on-demand: ~$24
- EBS 30 GB gp3: ~$2.40 (at $0.08/GB)
- S3 (Loki chunks ~5 GB, not re-measured; Prometheus backups ~56 GB for the last 30 generations): ~$1.50 (at $0.025/GB)
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
