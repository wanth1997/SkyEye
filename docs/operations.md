# SkyEye operations playbook

Day-2 reference: what to do when, by whom, and how often. If you're reading this for the first time, read top-to-bottom; for incidents, jump to the matching section.

## Daily rhythm (2 minutes)

Morning check (9:00-10:00 Taipei):

1. **Gmail inbox** — expect one `[SkyEye P3] DailyHeartbeat` email per 24 h. If absent for 2+ days, the alert pipeline has a problem somewhere (Prom ↔ AM ↔ Gmail). Investigate even if Grafana looks fine.
2. **Grafana Overview** (https://grafana.wanbrain.com) — 30-second glance:
   - `Active alerts (P1/P2)` = 0 — green
   - `Products UP` == product count — nothing has fallen off
   - `Emails sent (last 24h)` ≥ 1 — pipeline lived through the night
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
4. **Backup verification** — download a recent prom-snapshot from S3 and spot-check it (see "Restore from snapshot" below).

## Quarterly (1-2 hours)

1. **Secret rotation** (see "Rotating secrets" below):
   - Telegram bot token
   - Gmail App Password
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

### A Telegram 🚨 P1 fires

1. Click the runbook link in the message → runbooks/*.md on GitHub. Follow the steps.
2. If unrecoverable within 15 min, acknowledge in Telegram (reply to the bot message with context so team sees it), silence the alert for 1 h while you work.
3. After resolution, note cause in `runbooks/` or an incident doc. If a new class of problem, add a new rule.

### SkyEye itself stops paging (no alerts, no heartbeat)

Symptom: no Gmail for 2+ mornings, `Emails sent (last 24h)` reads 0.

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

```bash
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
```

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

### Gmail App Password

1. Revoke old: https://myaccount.google.com/apppasswords → remove the existing `SkyEye Alertmanager` entry.
2. Generate new, same name.
3. Write to `alertmanager/secrets/smtp_pass`, restart AM.

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

**Q: Why are there P3 alerts that are always firing?**
A: `DailyHeartbeat` is a `vector(1)` rule — intentional. Its daily email digest is proof the full Prom→AM→Gmail path is alive. If you stop getting the P3 email, something's broken.

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
