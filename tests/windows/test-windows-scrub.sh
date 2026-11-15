#!/usr/bin/env bash
set -euo pipefail

# Runs the Windows scrub end to end: the config is the installer's own render,
# loaded unmodified, and the pinned Alloy and Loki images do the work. Only the
# Event Log source is replaced, because loki.source.windowsevent does nothing
# outside Windows: tests/fixtures/windows/scrub-harness.alloy feeds fixture
# lines, shaped like the ones the first host produced, into the template's own
# loki.process. The runner log goes through the template's own file source.
#
# What Loki stored is then read back: no marker value may survive, text that
# must stay stays, safe lines are byte-identical, each stream carries exactly
# the allowed labels, and old or verbose entries never arrive.
#
# Every value is synthetic and the containers have no network. It must never
# pass by skipping.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=tests/windows/lib.sh
. "$SCRIPT_DIR/lib.sh"

CASES="$WINDOWS_FIXTURES/scrub-cases.tsv"
PRODUCT=github-runner

require_tools
load_windows_alloy_images
require_image "$LOKI_IMAGE"
[[ "$(compose_image 'grafana\/loki')" == "${LOKI_IMAGE%@*}" ]] || \
  die "pinned Loki ${LOKI_IMAGE%@*} no longer matches docker-compose.yml"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-windows-scrub.XXXXXX")"
PREFIX="skyeye-windows-scrub-$$"
cleanup() {
  remove_containers "$PREFIX"
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

contract static --template "$WINDOWS_AGENT_DIR/config.alloy.tmpl" \
  --fragment "$WINDOWS_AGENT_DIR/config-runner-diag.alloy.tmpl" \
  --general "$REPO_ROOT/agents/alloy/config-logs.alloy.tmpl" --cases "$CASES" || FAILED=1

contract samples --cases "$CASES" --out "$WORK/samples" --manifest "$WORK/manifest.json"

LOKI="$PREFIX-loki"
docker create --name "$LOKI" --pull=never --network none "$LOKI_IMAGE" -config.file=/etc/loki/scrub.yml >/dev/null
docker cp "$REPO_ROOT/tests/fixtures/scrub/loki-local.yml" "$LOKI:/etc/loki/scrub.yml" >/dev/null
docker start "$LOKI" >/dev/null
wait_http "$LOKI" http://127.0.0.1:3100/ready ready || die "Loki did not become ready"
assert_loopback_only "$LOKI"

port=12345
for image in "${ALLOY_IMAGES[@]}"; do
  version="${image%@*}"
  version="${version##*:v}"
  server="scrub-windows-v${version//./}"
  port=$((port + 1))
  mkdir -p "$WORK/$server"
  render_windows "$WORK/$server/config.alloy" -Product "$PRODUCT" -ServerId "$server" \
    -SecretsDir /cfg/secrets -RunnerDiagDir /samples/diag \
    -PromPushUrl http://127.0.0.1:9/api/v1/write -LokiPushUrl http://127.0.0.1:3100/loki/api/v1/push
  cp "$WINDOWS_FIXTURES/scrub-harness.alloy" "$WORK/$server/harness.alloy"
  write_fake_access_files "$WORK/$server/secrets"
  chmod -R a+rX "$WORK/$server" "$WORK/samples"

  alloy="$PREFIX-$server"
  new_alloy "$alloy" "$WORK/$server" "$WORK/samples" --network "container:$LOKI" "$image" \
    run --storage.path=/tmp/alloy --disable-reporting "--server.http.listen-addr=127.0.0.1:$port" /cfg
  docker start "$alloy" >/dev/null

  if ! contract judge-scrub --loki "$LOKI" --alloy "$alloy" --alloy-port "$port" --manifest "$WORK/manifest.json" \
    --server "$server" --product "$PRODUCT"; then
    docker logs "$alloy" >"$WORK/alloy.log" 2>&1 || true
    grep -E 'level=(error|warn)' "$WORK/alloy.log" | tail -n 5 | cut -c1-300 || true
    record "the scrub contract is not met on Alloy v$version"
  fi
done

[[ "$FAILED" == "0" ]] || die "Windows scrub contract is not met"
printf 'PASS: Windows scrub contract, Event Log and runner log, on Alloy %s\n' "$SKYEYE_ALLOY_WINDOWS_VERSIONS"
