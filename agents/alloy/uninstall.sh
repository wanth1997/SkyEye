#!/usr/bin/env bash
#
# Uninstall Grafana Alloy and clean up SkyEye agent artifacts.
#
# Usage:
#   sudo bash agents/alloy/uninstall.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root." >&2
  exit 1
fi

echo "==> Stopping alloy"
systemctl stop alloy 2>/dev/null || true
systemctl disable alloy 2>/dev/null || true

echo "==> Removing alloy package"
apt-get remove --purge -y alloy 2>/dev/null || true

echo "==> Removing config and apt repo"
rm -rf /etc/alloy /var/lib/alloy
rm -f /etc/apt/sources.list.d/grafana.list /etc/apt/keyrings/grafana.gpg
apt-get update -qq >/dev/null 2>&1 || true

echo "==> Done. Central Loki will still have the previously-pushed logs (they age out per retention policy)."
