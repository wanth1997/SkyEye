#!/usr/bin/env bash
#
# Uninstall Grafana Alloy and clean up SkyEye agent artifacts.
#
# Usage:
#   sudo bash agents/alloy/uninstall.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Shared with setup.sh and the Trading Linux scripts; see setup.sh.
LOCK_FILE=/run/skyeye-alloy.lock

if [ ! -r "$SCRIPT_DIR/install-common.sh" ]; then
  echo "ERROR: install-common.sh is missing; copy the whole agents/alloy directory" >&2
  exit 2
fi
# shellcheck source=agents/alloy/install-common.sh
. "$SCRIPT_DIR/install-common.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root." >&2
  exit 1
fi

if ! skyeye_take_host_lock "$LOCK_FILE"; then
  echo "ERROR: $SKYEYE_INSTALL_ERROR." >&2
  exit 1
fi

echo "==> Stopping alloy"
systemctl stop alloy 2>/dev/null || true
systemctl disable alloy 2>/dev/null || true

echo "==> Removing alloy package"
# setup.sh holds the package it installs, and apt-get -y refuses to remove a
# held package.
apt-mark unhold alloy >/dev/null 2>&1 || true
apt-get remove --purge -y alloy 2>/dev/null || true

echo "==> Removing config and apt repo"
rm -rf /etc/alloy /var/lib/alloy
rm -f /etc/apt/sources.list.d/grafana.list /etc/apt/keyrings/grafana.gpg
apt-get update -qq >/dev/null 2>&1 || true

echo "==> Done. Central Loki will still have the previously-pushed logs (they age out per retention policy)."
