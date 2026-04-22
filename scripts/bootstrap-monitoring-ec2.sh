#!/usr/bin/env bash
# One-time host setup for monitoring-prod EC2.
# Installs Docker, AWS CLI v2, and utilities.
#
# Run as: bash scripts/bootstrap-monitoring-ec2.sh
# (NOT as root — script will sudo where needed)

set -euo pipefail

if [[ "$(id -u)" == "0" ]]; then
  echo "Don't run as root. Run as ubuntu user; sudo will be invoked where needed."
  exit 1
fi

ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" && "$ARCH" != "x86_64" ]]; then
  echo "Unsupported arch: $ARCH"
  exit 1
fi

echo "==> apt update + basic utilities"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg unzip jq git

# ---------- Docker ----------
if command -v docker >/dev/null 2>&1; then
  echo "==> Docker already installed: $(docker --version)"
else
  echo "==> Installing Docker CE (official repo)"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update
  sudo apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  sudo systemctl enable --now docker

  echo "==> Adding $USER to docker group (re-login required to take effect)"
  sudo usermod -aG docker "$USER"
fi

# ---------- AWS CLI v2 ----------
if command -v aws >/dev/null 2>&1; then
  echo "==> AWS CLI already installed: $(aws --version)"
else
  echo "==> Installing AWS CLI v2 for $ARCH"
  TMPDIR=$(mktemp -d)
  pushd "$TMPDIR" >/dev/null
  if [[ "$ARCH" == "aarch64" ]]; then
    curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o awscliv2.zip
  else
    curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
  fi
  unzip -q awscliv2.zip
  sudo ./aws/install
  popd >/dev/null
  rm -rf "$TMPDIR"
fi

# ---------- Sanity ----------
echo ""
echo "==> Installed versions:"
docker --version
docker compose version
aws --version

echo ""
echo "==> Next steps:"
echo "  1. Log out + back in (or run: exec su -l $USER) so docker group takes effect."
echo "  2. Verify: docker ps       # should not ask for sudo"
echo "  3. Verify IAM role attached: aws sts get-caller-identity"
echo "  4. Proceed to Phase 1B — see README.md"
