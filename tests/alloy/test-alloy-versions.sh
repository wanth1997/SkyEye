#!/usr/bin/env bash
#
# Holds agents/alloy/alloy-versions.env to what it promises. Every listed Alloy
# version has a digest-pinned image on this machine, every agent config
# template validates on every version listed for its platform, the apt pin is a
# listed Linux version, and the installers' parser reads each image's real
# `alloy --version` output.
#
# The images run with no network and are never pulled. A missing image fails
# with the docker pull command to run; this suite must not pass by skipping.
# The macOS template is validated with the Linux image of the same version, so
# darwin-only behaviour is not covered.
#
# VERBOSE=1 also prints every check that passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_DIR="$REPO_ROOT/agents/alloy"
VERBOSE="${VERBOSE:-0}"
CHECKS=0
FAILURES=0

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

check() {
  local description="$1"
  shift
  CHECKS=$((CHECKS + 1))
  if "$@"; then
    if [[ "$VERBOSE" == "1" ]]; then
      printf 'ok: %s\n' "$description"
    fi
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL: %s\n' "$description"
  fi
}

for tool in docker envsubst sed; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required; this suite must not pass by skipping"
done
docker info >/dev/null 2>&1 || die "the Docker daemon is unreachable; this suite must not pass by skipping"

# shellcheck source=agents/alloy/install-common.sh
. "$AGENT_DIR/install-common.sh"
skyeye_load_alloy_versions || die "$SKYEYE_INSTALL_ERROR"

PREFIX="skyeye-alloy-versions-$$"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-alloy-versions.XXXXXX")"
cleanup() {
  local containers
  containers="$(docker ps -aq --filter "name=^$PREFIX-" 2>/dev/null || true)"
  if [[ -n "$containers" ]]; then
    # shellcheck disable=SC2086
    docker rm -f $containers >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# listed WORD LIST: LIST is one space-separated string, as in alloy-versions.env.
listed() {
  local wanted="$1" list="$2" candidate
  for candidate in $list; do
    [[ "$candidate" == "$wanted" ]] && return 0
  done
  return 1
}

image_version() {
  local tag="${1%@*}"
  printf '%s\n' "${tag##*:v}"
}

image_for() {
  local image
  for image in $SKYEYE_ALLOY_TEST_IMAGES; do
    if [[ "$(image_version "$image")" == "$1" ]]; then
      printf '%s\n' "$image"
      return 0
    fi
  done
  return 1
}

ALL_VERSIONS=""
for version in $SKYEYE_ALLOY_LINUX_VERSIONS $SKYEYE_ALLOY_MACOS_VERSIONS; do
  listed "$version" "$ALL_VERSIONS" || ALL_VERSIONS="$ALL_VERSIONS $version"
done

# ─────────────────────────────── The matrix itself ──────────────────────────

pinned_by_digest() { [[ "$1" =~ ^grafana/alloy:v[0-9]+[.][0-9]+[.][0-9]+@sha256:[0-9a-f]{64}$ ]]; }
image_is_local() { docker image inspect "$1" >/dev/null 2>&1; }

for image in $SKYEYE_ALLOY_TEST_IMAGES; do
  check "$image is pinned by digest" pinned_by_digest "$image"
  check "$image has a listed version" listed "$(image_version "$image")" "$ALL_VERSIONS"
done
has_image() { image_for "$1" >/dev/null; }
for version in $ALL_VERSIONS; do
  check "Alloy $version has a test image" has_image "$version"
done

apt_upstream=""
if [[ "$SKYEYE_ALLOY_APT_VERSION" =~ ^([0-9]+[.][0-9]+[.][0-9]+)-[0-9]+$ ]]; then
  apt_upstream="${BASH_REMATCH[1]}"
fi
check "apt pin $SKYEYE_ALLOY_APT_VERSION is a listed Linux version" \
  listed "$apt_upstream" "$SKYEYE_ALLOY_LINUX_VERSIONS"

missing=0
for image in $SKYEYE_ALLOY_TEST_IMAGES; do
  if ! image_is_local "$image"; then
    printf 'FAIL: pinned image is missing, run: docker pull %s\n' "$image"
    missing=1
  fi
done
[[ "$missing" -eq 0 ]] || die "the version checks need every pinned image"

# ─────────────────────────────── Parser ─────────────────────────────────────

parses_to() { [[ "$(skyeye_alloy_parse_version "$1")" == "$2" ]]; }

check 'parser reads a release banner' parses_to 'alloy, version v1.18.1 (branch: HEAD, revision: 6012ec4)' 1.18.1
check 'parser reads a pre-release' parses_to 'alloy, version v1.19.0-rc.1 (branch: HEAD)' 1.19.0-rc.1
check 'parser reads only the first line' parses_to $'alloy, version v1.16.3 (x)\nalloy, version v9.9.9' 1.16.3
check 'parser rejects another program' parses_to 'otelcol, version v1.18.1' ''
check 'parser rejects a partial version' parses_to 'alloy, version v1.18 (x)' ''
check 'parser rejects junk after the version' parses_to 'alloy, version v1.18.1x' ''

refused_on() { ! SKYEYE_ALLOY_UNTESTED_VERSION="${3:-}" skyeye_alloy_version_ok "$1" "$2" test 2>/dev/null; }
accepted_on() { SKYEYE_ALLOY_UNTESTED_VERSION="${3:-}" skyeye_alloy_version_ok "$1" "$2" test 2>/dev/null; }
check 'an unlisted version is refused' refused_on linux 9.9.9
check 'an override must name the exact version' refused_on linux 9.9.9 9.9
check 'an exact override is accepted' accepted_on linux 9.9.9 9.9.9
check 'an empty version is refused even with an override' refused_on linux '' ''

for image in $SKYEYE_ALLOY_TEST_IMAGES; do
  version="$(image_version "$image")"
  banner="$(docker run --rm --network none --pull=never "$image" --version 2>&1)"
  check "parser reads the real banner of $version" parses_to "$banner" "$version"
done

# ─────────────────────────────── Templates per version ──────────────────────

# Rendered the way the installers render them, with placeholder values.
render_configs() {
  local substituted template
  mkdir -p "$WORK/general" "$WORK/linux" "$WORK/macos"
  substituted="$(sed -n "s/^ENVSUBST_VARS='\(.*\)'\$/\1/p" "$AGENT_DIR/setup.sh")"
  [[ -n "$substituted" ]] || die "cannot read ENVSUBST_VARS from agents/alloy/setup.sh"
  (
    export PRODUCT=verify SERVER_ID=verify-host JOURNAL_MATCHES=_SYSTEMD_UNIT=verify.service
    export LOKI_PUSH_URL=https://loki.invalid/loki/api/v1/push
    export PROM_PUSH_URL=https://prometheus.invalid/api/v1/write
    export CF_ACCESS_CLIENT_ID=verify-placeholder CF_ACCESS_CLIENT_SECRET=verify-placeholder
    export APP_METRICS_TARGET=127.0.0.1:9 APP_METRICS_AUTHORIZATION=''
    export JOURNAL_SOURCES='loki.source.journal "system" {
  matches    = "_SYSTEMD_UNIT=verify.service"
  forward_to = [loki.process.scrub_pii.receiver]
}'
    for template in config-logs config-metrics config-app; do
      envsubst "$substituted" <"$AGENT_DIR/$template.alloy.tmpl" >>"$WORK/general/config.alloy" || exit 1
    done
  ) || die "cannot render the general config"
  cp "$WORK/general/config.alloy" "$WORK/linux/host.alloy"
  for template in config-linux config-linux-metrics; do
    sed -e 's/@@COMPONENT_ID@@/verify_strategy/g' -e 's/@@[A-Z_]*@@/verify/g' \
      "$AGENT_DIR/trading/$template.alloy.tmpl" >"$WORK/linux/$template.alloy"
  done
  cp "$AGENT_DIR/trading/config-macos.alloy.tmpl" "$WORK/macos/config.alloy"
}
render_configs

CONTAINER_SEQ=0
# validates_on IMAGE NAME TARGET: TARGET is a path below /cfg in the container.
validates_on() {
  local image="$1" name="$2" target="$3" container
  CONTAINER_SEQ=$((CONTAINER_SEQ + 1))
  container="$PREFIX-$CONTAINER_SEQ"
  docker create --name "$container" --network none --pull=never "$image" validate "/cfg/$target" >/dev/null || return 1
  if ! docker cp "$WORK/$name/." "$container:/cfg" >/dev/null; then
    docker rm -f "$container" >/dev/null 2>&1
    return 1
  fi
  docker start -a "$container" >"$WORK/$name-$CONTAINER_SEQ.log" 2>&1
  local rc=$?
  docker rm -f "$container" >/dev/null 2>&1
  if [[ "$rc" -ne 0 && "$VERBOSE" == "1" ]]; then
    cat "$WORK/$name-$CONTAINER_SEQ.log"
  fi
  return "$rc"
}
rejected_on() { ! validates_on "$@"; }

for version in $SKYEYE_ALLOY_LINUX_VERSIONS; do
  image="$(image_for "$version")"
  check "Alloy $version validates the general config" validates_on "$image" general config.alloy
  check "Alloy $version validates the Linux Trading directory" validates_on "$image" linux .
done
for version in $SKYEYE_ALLOY_MACOS_VERSIONS; do
  check "Alloy $version validates the macOS Trading config" \
    validates_on "$(image_for "$version")" macos config.alloy
done
# Why the Linux-only versions are not macOS versions. If one of these starts to
# pass, the template changed: it may now be added to SKYEYE_ALLOY_MACOS_VERSIONS.
for version in $SKYEYE_ALLOY_LINUX_VERSIONS; do
  listed "$version" "$SKYEYE_ALLOY_MACOS_VERSIONS" && continue
  check "Alloy $version still rejects the macOS Trading config" \
    rejected_on "$(image_for "$version")" macos config.alloy
done

if [[ "$FAILURES" -gt 0 ]]; then
  printf 'FAIL: Alloy version matrix: %s of %s checks failed\n' "$FAILURES" "$CHECKS"
  exit 1
fi
printf 'PASS: Alloy version matrix: %s checks\n' "$CHECKS"
