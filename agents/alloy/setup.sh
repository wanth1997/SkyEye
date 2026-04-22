#!/usr/bin/env bash
#
# Install / update Grafana Alloy agent on a SkyEye-monitored machine.
#
# Usage:
#   # Set required env vars, then run
#   export PRODUCT=ppclub
#   export SERVER_ID=ppclub-prod
#   export JOURNAL_MATCHES='_SYSTEMD_UNIT=ppclub-backend.service _SYSTEMD_UNIT=caddy.service'
#   export LOKI_PUSH_URL=https://loki-push.wanbrain.com/loki/api/v1/push
#   # (script will prompt for CF Access Client ID / Secret if unset)
#   sudo -E bash agents/alloy/setup.sh
#
# Required:
#   PRODUCT                     free-form string, e.g. ppclub / enyoung
#   SERVER_ID                   unique per host, e.g. ppclub-prod
#   JOURNAL_MATCHES             journalctl filter(s), space-separated OR
#   LOKI_PUSH_URL               e.g. https://loki-push.wanbrain.com/loki/api/v1/push
#   CF_ACCESS_CLIENT_ID         (prompt if unset)
#   CF_ACCESS_CLIENT_SECRET     (prompt if unset, hidden input)
#
# Supports: Ubuntu / Debian (apt); other distros need manual install.

set -euo pipefail

cd "$(dirname "$0")"

ALLOY_CONFIG=/etc/alloy/config.alloy
ENV_FILE=/etc/default/alloy

# ───────────────────────────── 1. Validate env ─────────────────────────────

require_env() {
  local name=$1
  if [ -z "${!name:-}" ]; then
    echo "ERROR: \$${name} is required. See usage at top of script." >&2
    exit 2
  fi
}
require_env PRODUCT
require_env SERVER_ID
require_env JOURNAL_MATCHES
require_env LOKI_PUSH_URL

if [ -z "${CF_ACCESS_CLIENT_ID:-}" ]; then
  read -rp "CF Access Client ID (xxx.access): " CF_ACCESS_CLIENT_ID
fi
if [ -z "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
  read -rsp "CF Access Client Secret (hidden): " CF_ACCESS_CLIENT_SECRET
  echo
fi
require_env CF_ACCESS_CLIENT_ID
require_env CF_ACCESS_CLIENT_SECRET

# ───────────────────────────── 2. Root check ───────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root (use sudo -E so env vars carry over)." >&2
  exit 1
fi

# ───────────────────────────── 3. Install Alloy ────────────────────────────

if command -v alloy >/dev/null 2>&1; then
  echo "==> Alloy already installed: $(alloy --version | head -1)"
else
  echo "==> Installing Grafana Alloy via apt"
  apt-get install -y ca-certificates curl gnupg wget lsb-release >/dev/null
  mkdir -p /etc/apt/keyrings/
  wget -q -O - https://apt.grafana.com/gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg --yes
  chmod 644 /etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt-get update -qq
  apt-get install -y alloy
fi

# ───────────────────────────── 4. Render config ────────────────────────────

echo "==> Rendering $ALLOY_CONFIG"
mkdir -p "$(dirname "$ALLOY_CONFIG")"

# Only listed variables get substituted — unlisted $vars (including Alloy
# regex capture refs like $1) stay intact.
ENVSUBST_VARS='$PRODUCT $SERVER_ID $JOURNAL_MATCHES $LOKI_PUSH_URL $CF_ACCESS_CLIENT_ID $CF_ACCESS_CLIENT_SECRET $PROM_PUSH_URL $APP_METRICS_TARGET'
export PRODUCT SERVER_ID JOURNAL_MATCHES LOKI_PUSH_URL \
       CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET \
       PROM_PUSH_URL APP_METRICS_TARGET

# Always: logs section (Phase 2A)
envsubst "$ENVSUBST_VARS" < config-logs.alloy.tmpl > "$ALLOY_CONFIG"

# Phase 2B: append node metrics section when PROM_PUSH_URL is set
if [ -n "${PROM_PUSH_URL:-}" ]; then
  echo "==> PROM_PUSH_URL set — appending node metrics section"
  envsubst "$ENVSUBST_VARS" < config-metrics.alloy.tmpl >> "$ALLOY_CONFIG"
else
  echo "==> PROM_PUSH_URL unset — log-only mode (Phase 2A)"
fi

# Phase 2C: append app /metrics scrape when APP_METRICS_TARGET is set
if [ -n "${APP_METRICS_TARGET:-}" ]; then
  if [ -z "${PROM_PUSH_URL:-}" ]; then
    echo "ERROR: APP_METRICS_TARGET requires PROM_PUSH_URL to be set too" >&2
    exit 2
  fi
  echo "==> APP_METRICS_TARGET set ($APP_METRICS_TARGET) — appending app scrape section"
  envsubst "$ENVSUBST_VARS" < config-app.alloy.tmpl >> "$ALLOY_CONFIG"
fi

chmod 640 "$ALLOY_CONFIG"
chown root:alloy "$ALLOY_CONFIG" 2>/dev/null || true

# ───────────────────────────── 5. journald access ───────────────────────────

# Alloy user needs read access to /var/log/journal/
if getent group systemd-journal >/dev/null; then
  usermod -a -G systemd-journal alloy || true
fi
# Ensure persistent journal is enabled (otherwise /run/log/journal is volatile)
if [ ! -d /var/log/journal ]; then
  mkdir -p /var/log/journal
  systemd-tmpfiles --create --prefix /var/log/journal
  systemctl restart systemd-journald
fi

# ───────────────────────────── 6. Validate + enable ─────────────────────────

echo "==> Validating config"
alloy fmt "$ALLOY_CONFIG" > /dev/null

echo "==> Enabling + starting alloy.service"
systemctl enable alloy >/dev/null 2>&1 || true
systemctl restart alloy

sleep 3
if ! systemctl is-active --quiet alloy; then
  echo "ERROR: alloy failed to start. Last 30 lines of journal:" >&2
  journalctl -u alloy -n 30 --no-pager >&2
  exit 1
fi

# ───────────────────────────── 7. Post-install hints ───────────────────────

cat <<EOF

==> Alloy is running.

Verify locally:
  systemctl status alloy
  journalctl -u alloy -f

Verify end-to-end in central Grafana (https://grafana.wanbrain.com):
  1. Open Explore → Datasource: Loki
  2. Query: {product="$PRODUCT"}
  3. Should see log lines within ~30 seconds.

If logs are not arriving, on this host:
  journalctl -u alloy --since=2m | grep -iE 'error|fail|denied|refused'

EOF
