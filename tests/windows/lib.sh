# shellcheck shell=bash
# The suites that source this use the variables below.
# shellcheck disable=SC2034
# Shared by the suites in this directory. Source it; it is not a suite.
#
# Everything runs in the images the repository already pins, with no network,
# and nothing here may pass by skipping: a missing tool or image is a failure
# that names the command to run.

WINDOWS_AGENT_DIR="$REPO_ROOT/agents/alloy/windows"
WINDOWS_FIXTURES="$REPO_ROOT/tests/fixtures/windows"
WINDOWS_CONTRACT="$WINDOWS_FIXTURES/windows_contract.py"
LOKI_IMAGE="grafana/loki:3.1.1@sha256:e689cc634841c937de4d7ea6157f17e29cf257d6a320f1c293ab18d46cfea986"
FAILED=0

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

record() {
  printf 'FAIL: %s\n' "$*"
  FAILED=1
}

contract() {
  python3 -I "$WINDOWS_CONTRACT" "$@"
}

compose_image() {
  sed -n -E "s/^[[:space:]]*image:[[:space:]]*($1:[^[:space:]]+).*\$/\\1/p" "$REPO_ROOT/docker-compose.yml" | head -n 1
}

require_tools() {
  local tool
  for tool in docker python3 pwsh "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required; this suite must not pass by skipping"
  done
  docker info >/dev/null 2>&1 || die "the Docker daemon is unreachable; this suite must not pass by skipping"
}

require_image() {
  docker image inspect "$1" >/dev/null 2>&1 || die "pinned image is missing, run: docker pull $1"
}

# Sets ALLOY_IMAGES to one digest-pinned image per Alloy version listed for Windows.
load_windows_alloy_images() {
  local version image found
  # shellcheck source=agents/alloy/install-common.sh
  . "$REPO_ROOT/agents/alloy/install-common.sh"
  skyeye_load_alloy_versions || die "$SKYEYE_INSTALL_ERROR"
  [[ -n "${SKYEYE_ALLOY_WINDOWS_VERSIONS:-}" ]] || die "SKYEYE_ALLOY_WINDOWS_VERSIONS is empty"
  ALLOY_IMAGES=()
  for version in $SKYEYE_ALLOY_WINDOWS_VERSIONS; do
    found=""
    for image in $SKYEYE_ALLOY_TEST_IMAGES; do
      if [[ "${image%@*}" == "grafana/alloy:v$version" ]]; then
        found="$image"
      fi
    done
    [[ -n "$found" ]] || die "Alloy $version is listed for Windows but has no test image"
    require_image "$found"
    ALLOY_IMAGES+=("$found")
  done
}

# render_windows OUTFILE [install.ps1 arguments...]: the installer's own render.
render_windows() {
  local out="$1"
  shift
  pwsh -NoLogo -NoProfile -NonInteractive -File "$WINDOWS_AGENT_DIR/install.ps1" -RenderOnly "$out" "$@" \
    >"$out.log" 2>&1 || die "install.ps1 -RenderOnly failed: $(tail -n 3 "$out.log" | tr '\n' ' ')"
  [[ -s "$out" ]] || die "install.ps1 -RenderOnly wrote nothing"
}

# Stand-ins for the two files Alloy reads on the host. Not credentials.
write_fake_access_files() {
  mkdir -p "$1"
  printf 'FAKEID00000000000000000000000000.access' >"$1/cf-access-client-id"
  printf 'FAKE-CF-ACCESS-VALUE-0001' >"$1/cf-access-client-secret"
}

remove_containers() {
  local containers
  containers="$(docker ps -aq --filter "name=^$1-" 2>/dev/null || true)"
  if [[ -n "$containers" ]]; then
    # shellcheck disable=SC2086
    docker rm -f $containers >/dev/null 2>&1 || true
  fi
}

# new_alloy NAME CONFIG_DIR SAMPLES_DIR docker-create-arguments...
# Files are copied in, not bind mounted: not every Docker VM shares $TMPDIR.
new_alloy() {
  local name="$1" config_dir="$2" samples_dir="$3"
  shift 3
  docker create --name "$name" --pull=never "$@" >/dev/null || die "cannot create $name"
  docker cp "$config_dir/." "$name:/cfg" >/dev/null || die "cannot copy the config into $name"
  if [[ -n "$samples_dir" ]]; then
    docker cp "$samples_dir" "$name:/samples" >/dev/null || die "cannot copy the samples into $name"
  fi
}

# wait_http CONTAINER URL PREFIX: until the body starts with PREFIX, 60 seconds.
wait_http() {
  local _
  for _ in $(seq 1 60); do
    [[ "$(docker exec "$1" wget -qO- "$2" 2>/dev/null || true)" == "$3"* ]] && return 0
    sleep 1
  done
  return 1
}

# The Alloy under test has to share the sink's namespace to reach it, and docker
# allows one network mode, so the sink gets --network none and Alloy joins it.
# Prove there is nothing in there but loopback rather than assume it.
assert_loopback_only() {
  local interfaces
  [[ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$1")" == "none" ]] || die "$1 is not running with --network none"
  interfaces="$(docker exec "$1" cat /proc/net/dev | sed -n -E 's/^[[:space:]]*([^:[:space:]]+):.*$/\1/p')"
  [[ "$interfaces" == "lo" ]] || die "the test namespace has more than loopback: $interfaces"
}
