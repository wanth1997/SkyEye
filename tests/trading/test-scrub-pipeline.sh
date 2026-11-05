#!/usr/bin/env bash
set -euo pipefail

# Runs the real scrub stages end to end: configs come from setup-linux.sh and
# setup-macos.sh --render-only and from setup.sh's envsubst, only the source and
# sink are local, and the pinned Alloy and Loki images do the work. Every value is
# synthetic and the containers have no network, so this reaches no real system.
#
# Unlike the grep checks in test-log-pipeline.sh, this fails when a regex does not
# do what it reads like it does. It must never pass by skipping.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRADING_DIR="$REPO_ROOT/agents/alloy/trading"
FIXTURES="$REPO_ROOT/tests/fixtures/scrub"
CONTRACT="$FIXTURES/scrub_contract.py"
LINUX_TEMPLATE="$TRADING_DIR/config-linux.alloy.tmpl"
MACOS_TEMPLATE="$TRADING_DIR/config-macos.alloy.tmpl"
GENERAL_TEMPLATE="$REPO_ROOT/agents/alloy/config-logs.alloy.tmpl"
RULES="$REPO_ROOT/loki/rules/fake/tnauqquant.yml"

ALLOY_NEW="grafana/alloy:v1.18.1@sha256:0f4434c92b3e6cdac38bb129b344e1790c246f7b6e2eaffcc16a5fa363240e33"
ALLOY_OLD="grafana/alloy:v1.16.3@sha256:84b76d56c5943025515438fd45cbb5995386a0260d072c9b671dfd7f539f9c01"
LOKI_IMAGE="grafana/loki:3.1.1@sha256:e689cc634841c937de4d7ea6157f17e29cf257d6a320f1c293ab18d46cfea986"
LOKI_PUSH_URL="http://127.0.0.1:3100/loki/api/v1/push"

# Accepted residuals, CASE:MARKER. A stateless per-line regex cannot reach these.
# The test fails if a case leaks anything else, and also if one of these stops
# leaking, so this list cannot go stale.
#   A15  Digest parameters after the scheme
#   M02  a value split across physical lines; only the first line carries the key
TRADING_RESIDUALS=("A15:FAKE-CREDENTIAL-0015" "M02:FAKE-CREDENTIAL-0604B")
GENERAL_RESIDUALS=("A15:FAKE-CREDENTIAL-0015")
# Order, trace and execution rules are deliberately Trading-only, so these values
# must pass through general untouched.
TRADING_ONLY_PREFIXES=("FAKE-ORDER-" "FAKE-TRACE-" "FAKE-ACCOUNT-")

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for tool in docker python3 envsubst brew; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required; this suite must not pass by skipping"
done
docker info >/dev/null 2>&1 || fail "the Docker daemon is unreachable; this suite must not pass by skipping"
for image in "$ALLOY_NEW" "$ALLOY_OLD" "$LOKI_IMAGE"; do
  docker image inspect "$image" >/dev/null 2>&1 || fail "pinned image is missing, run: docker pull $image"
done
for required_file in "$CONTRACT" "$FIXTURES/cases.tsv" "$FIXTURES/loki-local.yml" "$RULES"; do
  [[ -f "$required_file" ]] || fail "required file is missing: $required_file"
done
compose_loki="$(sed -n -E 's/^[[:space:]]*image:[[:space:]]*(grafana\/loki:[^[:space:]]+).*$/\1/p' \
  "$REPO_ROOT/docker-compose.yml" | head -n 1)"
[[ "$compose_loki" == "${LOKI_IMAGE%@*}" ]] || \
  fail "pinned Loki ${LOKI_IMAGE%@*} no longer matches docker-compose.yml ($compose_loki)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-scrub.XXXXXX")"
PREFIX="skyeye-scrub-$$"
LOKI="$PREFIX-loki"
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
trap 'exit 130' INT TERM

contract() {
  python3 -I "$CONTRACT" "$@"
}

failed=0
contract static --cases "$FIXTURES/cases.tsv" \
  --linux "$LINUX_TEMPLATE" --macos "$MACOS_TEMPLATE" --general "$GENERAL_TEMPLATE" || failed=1

contract samples --cases "$FIXTURES/cases.tsv" --out "$WORK/samples" --manifest "$WORK/manifest.json"

FAKE_REPO="$WORK/fake-repo"
mkdir -p "$FAKE_REPO/config"
printf 'instance_id: "rv-synth"\n' >"$FAKE_REPO/config/rv.yaml"

write_linux_env() {
  local server_id="$1"
  local target="$2"
  cat >"$target" <<EOF
TQ_PRODUCT=tnauqquant
TQ_ENVIRONMENT=production
TQ_SERVER_ID=$server_id
TQ_STRATEGY=rv-synth
TQ_INSTANCE_ID=rv-synth
TQ_REPO_ROOT=$FAKE_REPO
TQ_REPO_ROOT_REGEX='(/opt/fake/tnauqquant)'
TQ_EXECUTABLE=$FAKE_REPO/quant
TQ_CONFIG_PATH=$FAKE_REPO/config/rv.yaml
TQ_RAW_LOG_GLOB=/samples/trading/*.raw.log
TQ_RUN_MANIFEST=$FAKE_REPO/current.json
TQ_DONE_MARKER=$FAKE_REPO/current.done.json
TQ_POC_RUN_EXPECTED=1
TQ_REQUIRE_RUNTIME_CONTRACT=1
TQ_TIMEZONE=Asia/Taipei
TQ_TEXTFILE_DIR=$WORK/textfile
TQ_TEXTFILE_NAME=tnauqquant-rv-synth.prom
TQ_EXECUTOR_MAP=rv-main=fake
TQ_SIDECAR_REQUIRED=0
TQ_TEXTFILE_MODE=640
TQ_PROBE_USER=$(id -un)
TQ_PROBE_GROUP=$(id -gn)
TQ_ALLOY_USER=$(id -un)
TQ_ALLOY_GROUP=$(id -gn)
EOF
  chmod 600 "$target"
}

# The Linux fragment only forwards to loki.write.central, which the host's base
# Alloy config defines. This is that base, pointed at the local Loki.
render_linux() {
  local name="$1"
  local env_file="$WORK/$name.env"
  write_linux_env "$name" "$env_file"
  "$TRADING_DIR/setup-linux.sh" --render-only "$WORK/render-$name" --env-file "$env_file" >/dev/null
  mkdir -p "$WORK/cfg/$name"
  cp "$WORK/render-$name/trading-rv-synth.alloy" "$WORK/cfg/$name/"
  cat >"$WORK/cfg/$name/base.alloy" <<EOF
loki.write "central" {
  endpoint {
    url = "$LOKI_PUSH_URL"
  }
}
EOF
}

# macOS reads everything from the environment, so its render is used byte for byte
# and the source and sink are chosen by the env file passed to the container.
render_macos() {
  local env_file="$WORK/macos.env"
  cat >"$env_file" <<EOF
export TQ_PRODUCT=tnauqquant
export TQ_ENVIRONMENT=production
export TQ_SERVER_ID=rv-render
export TQ_STRATEGY=rv-synth
export TQ_INSTANCE_ID=rv-synth
export TQ_REPO_ROOT=$FAKE_REPO
export TQ_REPO_ROOT_REGEX='(/opt/fake/tnauqquant)'
export TQ_EXECUTABLE=$FAKE_REPO/quant
export TQ_CONFIG_PATH=$FAKE_REPO/config/rv.yaml
export TQ_RAW_LOG_GLOB='/samples/trading/*.raw.log'
export TQ_RUN_MANIFEST=$FAKE_REPO/current.json
export TQ_DONE_MARKER=$FAKE_REPO/current.done.json
export TQ_POC_RUN_EXPECTED=1
export TQ_REQUIRE_RUNTIME_CONTRACT=1
export TQ_TIMEZONE=Asia/Taipei
export TQ_TEXTFILE_DIR=/samples/textfile
export TQ_PNL_HISTORY_CACHE_DIR=$WORK/pnl-history-cache
export TQ_PNL_HISTORY_DAYS=30
export TQ_PNL_HISTORY_MAX_CURRENT_DAY_CYCLES=500
export LOKI_PUSH_URL=$LOKI_PUSH_URL
export PROM_PUSH_URL=http://127.0.0.1:9/api/v1/write
export CF_ACCESS_CLIENT_ID=FAKE-CF-ID
export CF_ACCESS_CLIENT_SECRET=FAKE-CF-SECRET
EOF
  chmod 600 "$env_file"
  "$TRADING_DIR/setup-macos.sh" --render-only "$WORK/render-macos" --env-file "$env_file" >/dev/null
  sed -n -E "s/^export ([A-Z_]+)='?([^']*)'?$/\1=\2/p" "$env_file" >"$WORK/macos.docker-env"
}

# setup.sh needs root and systemd, so run the exact envsubst it runs, with its own
# variable list. JOURNAL_SOURCES is the one seam: a file source replaces journald.
render_general() {
  local name="$1"
  local variables
  variables="$(sed -n -E "s/^ENVSUBST_VARS='(.*)'$/\1/p" "$REPO_ROOT/agents/alloy/setup.sh")"
  [[ "$variables" == *'$JOURNAL_SOURCES'* ]] || fail "cannot read ENVSUBST_VARS from setup.sh"
  mkdir -p "$WORK/cfg/$name"
  SERVER_ID="$name" \
    LOKI_PUSH_URL="$LOKI_PUSH_URL" \
    CF_ACCESS_CLIENT_ID=FAKE-CF-ID \
    CF_ACCESS_CLIENT_SECRET=FAKE-CF-SECRET \
    JOURNAL_SOURCES="$(cat <<EOF
loki.source.file "general_rv" {
  targets = [
    {
      __path__  = "/samples/general/*.log",
      product   = "rv-general",
      server_id = "$name",
      job       = "journald",
    },
  ]
  tail_from_end = false
  forward_to    = [loki.process.scrub_pii.receiver]
  file_match {
    enabled     = true
    sync_period = "2s"
  }
}
EOF
)" \
    envsubst "$variables" <"$GENERAL_TEMPLATE" >"$WORK/cfg/$name/config.alloy"
}

render_linux scrub-linux-v1181
render_linux scrub-linux-v1163
render_linux scrub-noscrub-v1181
contract strip-scrub "$WORK/cfg/scrub-noscrub-v1181/trading-rv-synth.alloy"
render_macos
mkdir -p "$WORK/cfg/scrub-macos-v1181" "$WORK/cfg/scrub-macos-v1163"
cp "$WORK/render-macos/config.alloy" "$WORK/cfg/scrub-macos-v1181/config.alloy"
# Alloy v1.16.3 does not know this stage.timestamp attribute. The Mac mini runs
# v1.18.1, and the attribute has no bearing on stage.replace, so the older column
# of the matrix drops that one line and nothing else.
grep -v 'action_on_duplicate_timestamp' "$WORK/render-macos/config.alloy" \
  >"$WORK/cfg/scrub-macos-v1163/config.alloy"
[[ "$(($(wc -l <"$WORK/render-macos/config.alloy") - $(wc -l <"$WORK/cfg/scrub-macos-v1163/config.alloy")))" == "1" ]] || \
  fail "expected to drop exactly one line from the macOS v1.16.3 config"
render_general scrub-general-v1181
render_general scrub-general-v1163

# setup-*.sh install at mode 600 and the images do not all run as root.
chmod -R a+rX "$WORK/cfg" "$WORK/samples"

# Copied in rather than bind mounted: not every Docker VM shares the temp directory.
new_container() {
  local container="$1"
  local name="$2"
  shift 2
  docker create --name "$container" "$@" >/dev/null
  docker cp "$WORK/cfg/$name/." "$container:/etc/rv" >/dev/null
  docker cp "$WORK/samples" "$container:/samples" >/dev/null
}

macos_args() {
  local name="$1"
  [[ "$name" == scrub-macos-* ]] || return 0
  printf '%s\n' --env-file "$WORK/macos.docker-env" -e "TQ_SERVER_ID=$name"
}

image_for() {
  case "$1" in
    *-v1181) printf '%s\n' "$ALLOY_NEW" ;;
    *-v1163) printf '%s\n' "$ALLOY_OLD" ;;
    *) fail "no Alloy version in pipeline name: $1" ;;
  esac
}

PIPELINES=(
  scrub-noscrub-v1181
  scrub-linux-v1181
  scrub-linux-v1163
  scrub-macos-v1181
  scrub-macos-v1163
  scrub-general-v1181
  scrub-general-v1163
)

for name in "${PIPELINES[@]}"; do
  extra=()
  while IFS= read -r arg; do
    extra+=("$arg")
  done < <(macos_args "$name")
  container="$PREFIX-validate-$name"
  new_container "$container" "$name" --network none ${extra[@]+"${extra[@]}"} \
    "$(image_for "$name")" validate /etc/rv
  if ! docker start -a "$container" >"$WORK/validate-$name.log" 2>&1; then
    printf 'FAIL %s: alloy validate rejected the rendered config\n' "$name"
    tail -n 5 "$WORK/validate-$name.log"
    failed=1
  fi
  docker rm -f "$container" >/dev/null
done

docker create --name "$LOKI" --network none "$LOKI_IMAGE" -config.file=/etc/loki/scrub.yml >/dev/null
docker cp "$FIXTURES/loki-local.yml" "$LOKI:/etc/loki/scrub.yml" >/dev/null
docker start "$LOKI" >/dev/null
for _ in $(seq 1 60); do
  [[ "$(docker exec "$LOKI" wget -qO- http://127.0.0.1:3100/ready 2>/dev/null || true)" == ready* ]] && break
  sleep 1
done
[[ "$(docker exec "$LOKI" wget -qO- http://127.0.0.1:3100/ready 2>/dev/null || true)" == ready* ]] || \
  fail "Loki did not become ready"

# Alloy has to share Loki's namespace to reach it, and docker allows only one
# network mode, so Loki gets --network none and Alloy joins it. Prove there is
# nothing in there but loopback rather than assume it.
[[ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$LOKI")" == "none" ]] || \
  fail "Loki is not running with --network none"
interfaces="$(docker exec "$LOKI" cat /proc/net/dev | sed -n -E 's/^[[:space:]]*([^:[:space:]]+):.*$/\1/p')"
[[ "$interfaces" == "lo" ]] || fail "the test namespace has more than loopback: $interfaces"

port=12345
wait_args=()
for name in "${PIPELINES[@]}"; do
  extra=()
  while IFS= read -r arg; do
    extra+=("$arg")
  done < <(macos_args "$name")
  container="$PREFIX-$name"
  port=$((port + 1))
  new_container "$container" "$name" --network "container:$LOKI" ${extra[@]+"${extra[@]}"} \
    "$(image_for "$name")" run --storage.path=/tmp/alloy --disable-reporting \
    "--server.http.listen-addr=127.0.0.1:$port" /etc/rv
  docker start "$container" >/dev/null
  case "$name" in
    scrub-general-*) wait_args+=(--pipeline "$name=$container=general") ;;
    *) wait_args+=(--pipeline "$name=$container=trading") ;;
  esac
done

contract wait --loki "$LOKI" --manifest "$WORK/manifest.json" "${wait_args[@]}" || failed=1

judge_args=(
  --loki "$LOKI"
  --manifest "$WORK/manifest.json"
  --rules "$RULES"
  --baseline scrub-noscrub-v1181
  --trading scrub-linux-v1181
  --trading scrub-linux-v1163
  --trading scrub-macos-v1181
  --trading scrub-macos-v1163
  --general scrub-general-v1181
  --general scrub-general-v1163
)
for residual in "${TRADING_RESIDUALS[@]}"; do
  judge_args+=(--trading-residual "$residual")
done
for residual in "${GENERAL_RESIDUALS[@]}"; do
  judge_args+=(--general-residual "$residual")
done
for prefix in "${TRADING_ONLY_PREFIXES[@]}"; do
  judge_args+=(--trading-only-prefix "$prefix")
done
contract judge "${judge_args[@]}" || failed=1

[[ "$failed" == "0" ]] || fail "scrub pipeline contract is not met"
printf 'PASS: scrub pipeline contract, Linux and macOS on Alloy v1.18.1 and v1.16.3, general on both\n'
