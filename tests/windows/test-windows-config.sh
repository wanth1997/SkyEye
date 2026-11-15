#!/usr/bin/env bash
set -euo pipefail

# Holds the Windows Alloy template to what it promises, using the installer's
# own render (install.ps1 -RenderOnly) and the pinned Alloy and Prometheus
# images with no network.
#
#   1. The render validates, with and without the runner log fragment.
#   2. It loads under a real `alloy run`. `alloy validate` passes a config that
#      uses a secret as a header value, and Alloy then exits at load with
#      "secrets may not be converted into strings". The suite proves on every
#      run that it catches this: a copy of the render with convert.nonsensitive
#      removed must fail the same check.
#   3. The series that reach Prometheus carry the labels central relies on:
#      windows_os_info takes the external product label and keeps its own as
#      os_product, the dropped metrics are gone, nothing carries an address,
#      MAC, serial number, path or account, and only allowlisted Alloy metrics
#      arrive, under job="integrations/self".
#   4. The drop and keep lists agree with the exporter's metric list.
#
# prometheus.exporter.windows does nothing outside Windows, so step 3 feeds a
# fixture through the template's own relabel (metrics-harness.alloy). The job
# and instance labels of the real exporter are therefore not covered here; the
# template sets neither, which the static checks hold.
#
# It must never pass by skipping.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=tests/windows/lib.sh
. "$SCRIPT_DIR/lib.sh"

TEMPLATE="$WINDOWS_AGENT_DIR/config.alloy.tmpl"
INVENTORY="$WINDOWS_FIXTURES/windows-exporter-v0.31.3-metrics.txt"
ALLOWLIST="$WINDOWS_FIXTURES/alloy-self-allowlist.txt"
PRODUCT=github-runner
SERVER=config-windows

require_tools
load_windows_alloy_images
PROM_IMAGE="$(compose_image 'prom\/prometheus')"
[[ -n "$PROM_IMAGE" ]] || die "cannot find the pinned Prometheus image in docker-compose.yml"
require_image "$PROM_IMAGE"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-windows-config.XXXXXX")"
PREFIX="skyeye-windows-config-$$"
cleanup() {
  remove_containers "$PREFIX"
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ─────────────────────────────── Static contract ────────────────────────────

has() { grep -Eq -- "$1" "$2"; }
count() { grep -Ec -- "$1" "$2" || true; }

has 'is_secret[[:space:]]*=[[:space:]]*true' "$TEMPLATE" || record "the secret file is not read with is_secret = true"
[[ "$(count '"CF-Access-Client-Secret"[[:space:]]*=' "$TEMPLATE")" == "2" ]] || \
  record "expected the secret header in exactly two sinks"
[[ "$(count '"CF-Access-Client-Secret"[[:space:]]*=[[:space:]]*convert\.nonsensitive\(local\.file\.cf_secret\.content\),' "$TEMPLATE")" == "2" ]] || \
  record "a secret header does not go through convert.nonsensitive"
# Series already on central are keyed by these two labels as the exporter sets them.
has '^[[:space:]]*job_name[[:space:]]*=' "$TEMPLATE" && record "the template sets a job_name"
has 'target_label[[:space:]]*=[[:space:]]*"(job|instance)"' "$TEMPLATE" && record "the template relabels job or instance"
has 'enabled_collectors = \["cpu", "logical_disk", "memory", "net", "os", "service", "system", "time"\]' "$TEMPLATE" || \
  record "the collector list changed"
has 'include = "\^\(Alloy\|actions\\\\\.runner\\\\\.\.\*\)\$"' "$TEMPLATE" || \
  record "the service filter is not anchored to Alloy and actions.runner.*"
has 'enabled_list = \["metrics"\]' "$TEMPLATE" || record "the NIC info metrics are not switched off"
for forbidden in 'CF_ACCESS' 'wanbrain' 'wans-windows'; do
  has "$forbidden" "$TEMPLATE" "$WINDOWS_AGENT_DIR/config-runner-diag.alloy.tmpl" && \
    record "the template hardcodes a host value: $forbidden"
done

contract inventory --template "$TEMPLATE" --inventory "$INVENTORY" --allowlist "$ALLOWLIST" || FAILED=1

# ─────────────────────────────── Render ─────────────────────────────────────

mkdir -p "$WORK/plain" "$WORK/cfg" "$WORK/broken" "$WORK/samples/textfile"
render_windows "$WORK/plain/config.alloy" -Product "$PRODUCT" -ServerId "$SERVER"
render_windows "$WORK/cfg/config.alloy" -Product "$PRODUCT" -ServerId "$SERVER" \
  -SecretsDir /cfg/secrets -RunnerDiagDir /samples/diag \
  -PromPushUrl http://127.0.0.1:9090/api/v1/write -LokiPushUrl http://127.0.0.1:9/loki/api/v1/push
has '@@' "$WORK/plain/config.alloy" && record "the default render still has a placeholder"
has 'filename = "C:/ProgramData/SkyEye/secrets/cf-access-client-id"' "$WORK/plain/config.alloy" || \
  record "the default render does not read the client id from C:/ProgramData/SkyEye/secrets"
has 'url = "https://prom-push.wanbrain.com/api/v1/write"' "$WORK/plain/config.alloy" || \
  record "the default render does not push to prom-push.wanbrain.com"
has 'url = "https://loki-push.wanbrain.com/loki/api/v1/push"' "$WORK/plain/config.alloy" || \
  record "the default render does not push to loki-push.wanbrain.com"
[[ "$(count "product   = \"$PRODUCT\"," "$WORK/plain/config.alloy")" == "2" && \
   "$(count "server_id = \"$SERVER\"," "$WORK/plain/config.alloy")" == "2" ]] || \
  record "external_labels are not product and server_id on both sinks"
has 'runner_diag' "$WORK/plain/config.alloy" && record "the runner fragment is rendered without -RunnerDiagDir"
has '__path__ = "/samples/diag/Runner_\*\.log"' "$WORK/cfg/config.alloy" || record "the runner fragment has no Runner_*.log glob"

# The mutation: exactly the two header lines change.
sed 's/convert\.nonsensitive(\(local\.file\.cf_secret\.content\))/\1/' "$WORK/cfg/config.alloy" >"$WORK/broken/config.alloy"
# A template that already lacks the conversion leaves nothing to remove. That
# is recorded, and the run below then shows what such a config does.
changed="$(diff "$WORK/cfg/config.alloy" "$WORK/broken/config.alloy" | grep -c '^>' || true)"
[[ "$changed" == "2" ]] || \
  record "removing convert.nonsensitive changed $changed lines of the render, expected the two secret headers"

cp "$WINDOWS_FIXTURES/metrics-harness.alloy" "$WORK/cfg/harness.alloy"
cp "$WINDOWS_FIXTURES/label-contract.prom" "$WORK/samples/textfile/"
write_fake_access_files "$WORK/cfg/secrets"
write_fake_access_files "$WORK/broken/secrets"
write_fake_access_files "$WORK/plain/secrets"
printf 'global:\n  scrape_interval: 1m\n' >"$WORK/prometheus.yml"
chmod -R a+rX "$WORK"

SEQ=0
# run_to_end IMAGE CONFIG_DIR alloy-arguments...: runs to exit, output in $WORK/last.log
run_to_end() {
  local image="$1" dir="$2" name
  shift 2
  SEQ=$((SEQ + 1))
  name="$PREFIX-once-$SEQ"
  new_alloy "$name" "$dir" "" --network none "$image" "$@"
  docker start -a "$name" >"$WORK/last.log" 2>&1
  local rc=$?
  docker rm -f "$name" >/dev/null 2>&1
  return "$rc"
}

for image in "${ALLOY_IMAGES[@]}"; do
  version="${image%@*}"
  version="${version##*:v}"

  # ───────────────────────────── 1. validate ────────────────────────────────
  run_to_end "$image" "$WORK/plain" validate /cfg/config.alloy || \
    record "Alloy v$version: alloy validate rejects the default render: $(tail -n 3 "$WORK/last.log" | tr '\n' ' ')"
  run_to_end "$image" "$WORK/cfg" validate /cfg/config.alloy || \
    record "Alloy v$version: alloy validate rejects the render with the runner fragment: $(tail -n 3 "$WORK/last.log" | tr '\n' ' ')"

  # ───────────────────────────── 2. the secret-to-string check ──────────────
  # Why validate is not enough: it accepts the broken config.
  run_to_end "$image" "$WORK/broken" validate /cfg/config.alloy || \
    printf 'note: Alloy v%s validate now rejects a secret used as a header; the run check below still applies\n' "$version"

  broken="$PREFIX-broken-${version//./}"
  new_alloy "$broken" "$WORK/broken" "" --network none "$image" \
    run --storage.path=/tmp/alloy --disable-reporting --server.http.listen-addr=127.0.0.1:12346 /cfg/config.alloy
  docker start "$broken" >/dev/null
  for _ in $(seq 1 20); do
    [[ "$(docker inspect -f '{{.State.Running}}' "$broken")" == "true" ]] || break
    sleep 1
  done
  docker logs "$broken" >"$WORK/broken.log" 2>&1 || true
  if [[ "$(docker inspect -f '{{.State.Running}}' "$broken")" == "true" ]]; then
    record "Alloy v$version: a config without convert.nonsensitive still runs; the secret-to-string check has no teeth"
  elif [[ "$(docker inspect -f '{{.State.ExitCode}}' "$broken")" == "0" ]]; then
    record "Alloy v$version: a config without convert.nonsensitive exited 0"
  elif ! grep -q 'secrets may not be converted into strings' "$WORK/broken.log"; then
    record "Alloy v$version: the broken config failed for another reason: $(grep 'level=error' "$WORK/broken.log" | head -n 2 | cut -c1-300 || true)"
  fi
  docker rm -f "$broken" >/dev/null 2>&1

  # ───────────────────────────── 3. run it, and read the series back ────────
  prom="$PREFIX-prom-${version//./}"
  docker create --name "$prom" --pull=never --network none --entrypoint /bin/prometheus "$PROM_IMAGE" \
    --config.file=/tmp/prometheus.yml --storage.tsdb.path=/tmp/tsdb --web.enable-remote-write-receiver \
    --web.listen-address=127.0.0.1:9090 --log.level=error >/dev/null
  docker cp "$WORK/prometheus.yml" "$prom:/tmp/prometheus.yml" >/dev/null
  docker start "$prom" >/dev/null
  wait_http "$prom" http://127.0.0.1:9090/-/ready Prometheus || die "Prometheus did not become ready"
  assert_loopback_only "$prom"

  alloy="$PREFIX-alloy-${version//./}"
  new_alloy "$alloy" "$WORK/cfg" "$WORK/samples" --network "container:$prom" "$image" \
    run --storage.path=/tmp/alloy --disable-reporting --server.http.listen-addr=127.0.0.1:12345 /cfg
  docker start "$alloy" >/dev/null

  contract judge-metrics --prom "$prom" --alloy "$alloy" --fixture "$WINDOWS_FIXTURES/label-contract.prom" \
    --inventory "$INVENTORY" --allowlist "$ALLOWLIST" --server "$SERVER" --product "$PRODUCT" || \
    record "Alloy v$version: the label contract is not met"

  # The same check the broken config failed: still running, nothing failed to load.
  [[ "$(docker inspect -f '{{.State.Running}}' "$alloy")" == "true" ]] || \
    record "Alloy v$version: the render did not stay up under alloy run"
  docker logs "$alloy" >"$WORK/alloy.log" 2>&1 || true
  if grep -q 'failed to evaluate config' "$WORK/alloy.log"; then
    record "Alloy v$version: a component of the render failed to load: $(grep 'failed to evaluate config' "$WORK/alloy.log" | grep -o 'node=.*' | head -n 2 | cut -c1-220 | tr '\n' ' ' || true)"
  fi
  [[ "$(docker exec "$prom" wget -qO- http://127.0.0.1:12345/-/ready 2>/dev/null || true)" == *ready* ]] || \
    record "Alloy v$version: /-/ready does not answer on the render"
  docker rm -f "$alloy" "$prom" >/dev/null 2>&1
done

[[ "$FAILED" == "0" ]] || die "Windows Alloy config contract is not met"
printf 'PASS: Windows Alloy config: validate, real run, secret-to-string mutation, label contract, on Alloy %s\n' \
  "$SKYEYE_ALLOY_WINDOWS_VERSIONS"
