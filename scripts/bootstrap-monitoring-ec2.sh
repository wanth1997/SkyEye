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
# A fixed release, installed only if the download matches the sha256 below.
# These hashes are of zips whose .sig verified against the AWS CLI Team key
# (fingerprint FB5D B77F D5C1 18B8 0511  ADA8 A631 0ACC 4672 475C, as printed
# in the AWS CLI install guide) on 2026-11-07; 2.39.3 was released 2026-10-30.
# To move the pin: pick a v2 release at least 7 days old, download both
# awscli-exe-linux-{x86_64,aarch64}-VERSION.zip and .zip.sig, check the key
# fingerprint against the install guide, gpg --verify both, then replace the
# version and both hashes together.
AWSCLI_VERSION=2.39.3
AWSCLI_SHA256_X86_64=14cb35809ad7547dd3c69fa9899a3975fbd850b6a6791f3fe264856490cd9a63
AWSCLI_SHA256_AARCH64=f6eb845fbacb11bee87de3f5fbe8043773cbe89d0414607b44b71e216eb9226b

if command -v aws >/dev/null 2>&1; then
  echo "==> AWS CLI already installed: $(aws --version)"
else
  echo "==> Installing AWS CLI v2 $AWSCLI_VERSION for $ARCH"
  if [[ "$ARCH" == "aarch64" ]]; then
    awscli_sha256="$AWSCLI_SHA256_AARCH64"
  else
    awscli_sha256="$AWSCLI_SHA256_X86_64"
  fi
  awscli_url="https://awscli.amazonaws.com/awscli-exe-linux-$ARCH-$AWSCLI_VERSION.zip"
  awscli_dir=$(mktemp -d)
  trap 'rm -rf "$awscli_dir"' EXIT
  curl -fsSL --proto '=https' "$awscli_url" -o "$awscli_dir/awscliv2.zip"
  awscli_actual=$(sha256sum "$awscli_dir/awscliv2.zip" | cut -d' ' -f1)
  if [[ "$awscli_actual" != "$awscli_sha256" ]]; then
    echo "AWS CLI download does not match the pinned sha256; nothing was installed."
    echo "  url:      $awscli_url"
    echo "  expected: $awscli_sha256"
    echo "  got:      $awscli_actual"
    exit 1
  fi
  unzip -q "$awscli_dir/awscliv2.zip" -d "$awscli_dir"
  sudo "$awscli_dir/aws/install"
  rm -rf "$awscli_dir"
  trap - EXIT
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
