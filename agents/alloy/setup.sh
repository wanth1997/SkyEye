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
#   APP_METRICS_BEARER_TOKEN    optional; bearer token for protected app metrics
#
# Supports: Ubuntu / Debian (apt); other distros need manual install.
#
# The live config is only replaced after the new one passed `alloy validate`,
# and is restored if Alloy then fails to start. See "How setup.sh handles
# failure" in README.md for the exit codes and what stays on disk.

set -euo pipefail

cd "$(dirname "$0")"

ALLOY_CONFIG=/etc/alloy/config.alloy
ENV_FILE=/etc/default/alloy

# These live next to the config so every rename stays on one filesystem. None
# may end in .alloy: with CONFIG_FILE=/etc/alloy, Alloy loads every *.alloy in
# the directory, dotfiles included.
ALLOY_PREVIOUS="$ALLOY_CONFIG.previous"   # config replaced by the last good run
ALLOY_ROLLBACK="$ALLOY_CONFIG.rollback"   # exists only while this run is in flight

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

if [ -n "${APP_METRICS_TARGET:-}" ] && [ -z "${PROM_PUSH_URL:-}" ]; then
  echo "ERROR: APP_METRICS_TARGET requires PROM_PUSH_URL to be set too" >&2
  exit 2
fi

if ! command -v envsubst >/dev/null 2>&1; then
  echo "ERROR: envsubst not found (Debian/Ubuntu package: gettext-base)" >&2
  exit 2
fi

TEMPLATES=(config-logs.alloy.tmpl)
if [ -n "${PROM_PUSH_URL:-}" ]; then
  TEMPLATES+=(config-metrics.alloy.tmpl)
fi
if [ -n "${APP_METRICS_TARGET:-}" ]; then
  TEMPLATES+=(config-app.alloy.tmpl)
fi
for template in "${TEMPLATES[@]}"; do
  if [ ! -r "$template" ]; then
    echo "ERROR: template $template is missing or unreadable" >&2
    exit 2
  fi
done

if [ -z "${CF_ACCESS_CLIENT_ID:-}" ]; then
  read -rp "CF Access Client ID (xxx.access): " CF_ACCESS_CLIENT_ID
fi
if [ -z "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
  read -rsp "CF Access Client Secret (hidden): " CF_ACCESS_CLIENT_SECRET
  echo
fi
require_env CF_ACCESS_CLIENT_ID
require_env CF_ACCESS_CLIENT_SECRET

APP_METRICS_AUTHORIZATION=""
if [ -n "${APP_METRICS_BEARER_TOKEN:-}" ]; then
  case "$APP_METRICS_BEARER_TOKEN" in
    *$'\n'*|*\"*)
      echo "ERROR: APP_METRICS_BEARER_TOKEN must not contain newlines or double quotes" >&2
      exit 2
      ;;
  esac
  APP_METRICS_AUTHORIZATION="  authorization {
    type        = \"Bearer\"
    credentials = \"${APP_METRICS_BEARER_TOKEN}\"
  }"
fi

# ───────────────────────────── 2. Root check ───────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root (use sudo -E so env vars carry over)." >&2
  exit 1
fi

# ───────────────────────────── 3. Check target state ───────────────────────

# mv replaces a symlink instead of writing through it, and moves into a directory.
if [ -L "$ALLOY_CONFIG" ] || { [ -e "$ALLOY_CONFIG" ] && [ ! -f "$ALLOY_CONFIG" ]; }; then
  echo "ERROR: $ALLOY_CONFIG must be a regular file; refusing to replace it." >&2
  exit 1
fi
if [ -e "$ALLOY_ROLLBACK" ]; then
  echo "ERROR: $ALLOY_ROLLBACK exists, so an earlier run did not finish." >&2
  echo "       It holds the config from before that run. Compare it with" >&2
  echo "       $ALLOY_CONFIG, then move it over the config or delete it, and re-run." >&2
  exit 1
fi

# ───────────────────────────── 4. Install Alloy ────────────────────────────

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

# `alloy fmt` only parses, so it passes configs that cannot run. `validate`
# shipped in v1.9.0; older versions exit non-zero with "unknown command".
if ! alloy validate --help >/dev/null 2>&1; then
  echo "ERROR: this Alloy has no validate command: $(alloy --version | head -1)" >&2
  echo "       Upgrade to Alloy v1.9.0 or newer, then re-run. $ALLOY_CONFIG was not changed." >&2
  exit 1
fi

# ───────────────────────────── 5. Render config ────────────────────────────

STAGED_CONFIG=""
HAD_PREVIOUS=0
ALLOY_WAS_ACTIVE=0
CONFIG_SWAPPED=0   # 1 from the swap until the new config has proven healthy

# Alloy runs under Restart=always, so a single is-active sample can land on a
# crash loop's up phase. Require one unbroken main process across the window.
alloy_stays_up() {
  local first="" current _
  for _ in 1 2 3 4 5; do
    sleep 1
    systemctl is-active --quiet alloy || return 1
    current="$(systemctl show -p MainPID alloy)" || return 1
    if [ -z "$first" ]; then
      first=$current
    fi
    [ "$current" = "$first" ] || return 1
  done
}

# Puts the host back the way this run found it. Runs from the EXIT trap, where
# set -e is off, so each step reports its own failure. Do not add a bare
# `return`: in a trap handler it yields the status from before the trap ran.
rollback() {
  if [ "$HAD_PREVIOUS" -eq 0 ]; then
    echo "==> No previous config: removing $ALLOY_CONFIG and stopping alloy" >&2
    rm -f "$ALLOY_CONFIG" && systemctl stop alloy
  else
    echo "==> Restoring the previous $ALLOY_CONFIG" >&2
    mv -f "$ALLOY_ROLLBACK" "$ALLOY_CONFIG" || return 1
    if [ "$ALLOY_WAS_ACTIVE" -eq 1 ]; then
      systemctl restart alloy && alloy_stays_up
    else
      systemctl stop alloy
    fi
  fi
}

on_exit() {
  local status=$?
  trap - EXIT
  trap '' HUP INT TERM
  if [ "$CONFIG_SWAPPED" -eq 1 ]; then
    if rollback; then
      echo "ERROR: install failed; the host is back to its state before this run." >&2
    else
      status=3
      echo "CRITICAL: rollback did not finish. Check $ALLOY_CONFIG and 'systemctl status alloy' by hand." >&2
      echo "          If $ALLOY_ROLLBACK still exists, it holds the previous config." >&2
    fi
  fi
  rm -f "$STAGED_CONFIG"
  exit "$status"
}
trap on_exit EXIT

echo "==> Rendering staged config"
mkdir -p "$(dirname "$ALLOY_CONFIG")"

# mktemp creates the file 0600 whatever the umask, so credentials are private
# from the first byte. The rename below needs it on the config's filesystem.
STAGED_CONFIG="$(mktemp "$ALLOY_CONFIG.staged.XXXXXX")"

# Build JOURNAL_SOURCES — one loki.source.journal block per product.
#   JOURNAL_PRODUCT_MAP unset → single source covering all JOURNAL_MATCHES,
#                                tagged product=$PRODUCT.
#   JOURNAL_PRODUCT_MAP set   → parse 'units_spec=product;units_spec=product'
#                                and emit one source per product. Each source's
#                                matches filter is built from units_spec (the
#                                part before the `=`), which supports | as a
#                                unit separator (e.g. "a.service|b.service").
#                                Backslash-escapes in units_spec are stripped
#                                (so \.service is treated as .service).
#
# Example for a shared host:
#   export JOURNAL_PRODUCT_MAP='ppclub-backend.service|caddy.service=ppclub;enyoung-menu.service=enyoung'
JOURNAL_SOURCES=""
if [ -n "${JOURNAL_PRODUCT_MAP:-}" ]; then
  echo "==> JOURNAL_PRODUCT_MAP set — multi-tenant: one journal source per product"
  IFS=';' read -ra PAIRS <<< "$JOURNAL_PRODUCT_MAP"
  for pair in "${PAIRS[@]}"; do
    pair="${pair# }"
    units_spec="${pair%=*}"        # e.g. "a.service|b.service"
    product_val="${pair##*=}"      # e.g. "ppclub"

    # Strip any backslash escapes left over from regex-style syntax
    units_spec_clean="${units_spec//\\/}"

    # Split on | and build the journalctl matches string:
    #   "_SYSTEMD_UNIT=a.service _SYSTEMD_UNIT=b.service"
    IFS='|' read -ra UNITS <<< "$units_spec_clean"
    matches_str=""
    for u in "${UNITS[@]}"; do
      matches_str+=" _SYSTEMD_UNIT=${u}"
    done
    matches_str="${matches_str# }"

    JOURNAL_SOURCES+="
loki.source.journal \"${product_val}\" {
  matches    = \"${matches_str}\"
  max_age    = \"5m\"
  forward_to = [loki.process.scrub_pii.receiver]
  labels     = {
    product   = \"${product_val}\",
    server_id = \"${SERVER_ID}\",
    job       = \"journald\",
  }
}
"
  done
else
  # Single-tenant: one source covering JOURNAL_MATCHES, tagged $PRODUCT
  JOURNAL_SOURCES="
loki.source.journal \"system\" {
  matches    = \"${JOURNAL_MATCHES}\"
  max_age    = \"5m\"
  forward_to = [loki.process.scrub_pii.receiver]
  labels     = {
    product   = \"${PRODUCT}\",
    server_id = \"${SERVER_ID}\",
    job       = \"journald\",
  }
}
"
fi

# Only listed variables get substituted — unlisted $vars (including Alloy
# regex capture refs like $1) stay intact.
ENVSUBST_VARS='$PRODUCT $SERVER_ID $JOURNAL_MATCHES $LOKI_PUSH_URL $CF_ACCESS_CLIENT_ID $CF_ACCESS_CLIENT_SECRET $PROM_PUSH_URL $APP_METRICS_TARGET $APP_METRICS_AUTHORIZATION $JOURNAL_SOURCES'
export PRODUCT SERVER_ID JOURNAL_MATCHES LOKI_PUSH_URL \
       CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET \
       PROM_PUSH_URL APP_METRICS_TARGET APP_METRICS_AUTHORIZATION JOURNAL_SOURCES

# Always: logs section (Phase 2A)
envsubst "$ENVSUBST_VARS" < config-logs.alloy.tmpl > "$STAGED_CONFIG"

# Phase 2B: append node metrics section when PROM_PUSH_URL is set
if [ -n "${PROM_PUSH_URL:-}" ]; then
  echo "==> PROM_PUSH_URL set — appending node metrics section"
  envsubst "$ENVSUBST_VARS" < config-metrics.alloy.tmpl >> "$STAGED_CONFIG"
else
  echo "==> PROM_PUSH_URL unset — log-only mode (Phase 2A)"
fi

# Phase 2C: append app /metrics scrape when APP_METRICS_TARGET is set
if [ -n "${APP_METRICS_TARGET:-}" ]; then
  echo "==> APP_METRICS_TARGET set ($APP_METRICS_TARGET) — appending app scrape section"
  envsubst "$ENVSUBST_VARS" < config-app.alloy.tmpl >> "$STAGED_CONFIG"
fi

# `alloy validate` accepts an empty file, which would run with no pipeline.
if [ ! -s "$STAGED_CONFIG" ]; then
  echo "ERROR: rendered config is empty; $ALLOY_CONFIG was not changed." >&2
  exit 1
fi

# ───────────────────────────── 6. Validate ─────────────────────────────────

echo "==> Validating staged config"
if ! alloy validate "$STAGED_CONFIG"; then
  echo "ERROR: alloy validate rejected the rendered config; $ALLOY_CONFIG was not changed." >&2
  exit 1
fi

# Set on the staged file so the config is never live with the wrong owner. The
# alloy user cannot read a root:root 640 file, so a chown failure is fatal.
chown root:alloy "$STAGED_CONFIG"
chmod 640 "$STAGED_CONFIG"

# ───────────────────────────── 7. journald access ───────────────────────────

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

# ───────────────────────────── 8. Swap + restart ────────────────────────────

# The hard link keeps the old inode, so a rollback restores content, mode and
# owner exactly. Signals are ignored for these few commands so that
# CONFIG_SWAPPED always matches what is on disk when the EXIT trap reads it.
swap_in_staged_config() {
  trap '' HUP INT TERM
  if [ -f "$ALLOY_CONFIG" ]; then
    ln "$ALLOY_CONFIG" "$ALLOY_ROLLBACK"
    HAD_PREVIOUS=1
  fi
  if ! mv -f "$STAGED_CONFIG" "$ALLOY_CONFIG"; then
    rm -f "$ALLOY_ROLLBACK"
    echo "ERROR: could not move the staged config into place; $ALLOY_CONFIG was not changed." >&2
    exit 1
  fi
  CONFIG_SWAPPED=1
  # An explicit trap, unlike bash's default, lets a running `systemctl restart`
  # finish first, so the rollback's own restart cannot overlap it.
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

activation_failed() {
  echo "ERROR: $1. Last 30 lines of journal:" >&2
  journalctl -u alloy -n 30 --no-pager >&2 || true
  exit 1
}

if systemctl is-active --quiet alloy; then
  ALLOY_WAS_ACTIVE=1
fi

swap_in_staged_config

echo "==> Restarting alloy.service"
systemctl restart alloy || activation_failed "systemctl restart alloy failed"
alloy_stays_up || activation_failed "alloy did not stay up on the new config"

# The new config is proven; a failure from here on must not undo it.
CONFIG_SWAPPED=0
if [ "$HAD_PREVIOUS" -eq 1 ]; then
  if mv -f "$ALLOY_ROLLBACK" "$ALLOY_PREVIOUS"; then
    echo "==> Previous config kept at $ALLOY_PREVIOUS"
  else
    echo "WARNING: could not rename $ALLOY_ROLLBACK to $ALLOY_PREVIOUS; delete or rename it before the next run." >&2
  fi
fi

# Enabled only now, so a failed attempt never changes boot behaviour.
echo "==> Enabling alloy.service"
if ! systemctl enable alloy >/dev/null 2>&1; then
  echo "WARNING: systemctl enable alloy failed; alloy is running but may not start at boot." >&2
fi

# ───────────────────────────── 9. Post-install hints ───────────────────────

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
