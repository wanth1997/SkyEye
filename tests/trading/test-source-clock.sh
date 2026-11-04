#!/usr/bin/env bash
set -euo pipefail

# promtool preloads every sample, so it cannot model data stamped later than the
# evaluation time. This runs real Prometheus with no network and remote-writes
# one host running ahead and one normal host, as Alloy would.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fail "docker is required; this suite must not pass by skipping"
IMAGE="$(sed -n -E 's/^[[:space:]]*image:[[:space:]]*(prom\/prometheus:[^[:space:]]+).*$/\1/p' \
  "$REPO_ROOT/docker-compose.yml" | head -n 1)"
[[ -n "$IMAGE" ]] || fail "cannot find the pinned Prometheus image"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-source-clock.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp "$REPO_ROOT/prometheus/rules/trading.yml" "$WORK/trading.yml"
printf 'groups:\n  - name: trading-target-inventory\n    interval: 1m\n    rules:\n' >"$WORK/inventory.yml"
"$REPO_ROOT/scripts/trading-target" --file "$WORK/inventory.yml" add --server fixture-ahead --strategy fixture-a >/dev/null
"$REPO_ROOT/scripts/trading-target" --file "$WORK/inventory.yml" add --server fixture-normal --strategy fixture-b >/dev/null
cat >"$WORK/prometheus.yml" <<'CONFIG'
global:
  evaluation_interval: 15s
rule_files:
  - /tmp/w/inventory.yml
  - /tmp/w/trading.yml
CONFIG
cat >"$WORK/run.sh" <<'RUN'
#!/bin/sh
URL=http://127.0.0.1:9090
prometheus --config.file=/tmp/w/prometheus.yml --storage.tsdb.path=/tmp/p \
  --web.listen-address=127.0.0.1:9090 --web.enable-remote-write-receiver --log.level=error >/tmp/p.log 2>&1 &
sleep 4
LABELS='product="tnauqquant",environment="production"'
push() { # push SERVER STRATEGY VALUE TIME
  echo "tnauqquant_probe_timestamp_seconds{$LABELS,server_id=\"$1\",strategy=\"$2\"} $3 $(($4 * 1000))" >/tmp/m.txt
  promtool push metrics $URL/api/v1/write /tmp/m.txt >/dev/null 2>&1
}
now=$(date +%s)
real=$((now - 240))
while [ "$real" -le "$now" ]; do
  push fixture-ahead fixture-a $((real + 240)) $((real + 240))
  push fixture-normal fixture-b "$real" "$real"
  real=$((real + 15))
done
# The inventory group runs once a minute, so the first evaluation that can match
# arrives after about 90 seconds, and firing needs the rule's for: 2m on top: about
# 255 seconds at worst. Both hosts keep pushing, as live hosts would. The normal
# host is read in every state on every pass, so a pending alert cannot slip by.
deadline=$(($(date +%s) + 360))
firing=''
normal=''
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 10
  moment=$(date +%s)
  push fixture-ahead fixture-a $((moment + 240)) $((moment + 240))
  push fixture-normal fixture-b "$moment" "$moment"
  normal="$(promtool query instant $URL \
    'ALERTS{alertname="TradingSourceClockAhead",server_id="fixture-normal"}' 2>&1)"
  case "$normal" in *'=>'*) break ;; esac
  firing="$(promtool query instant $URL \
    'ALERTS{alertname="TradingSourceClockAhead",server_id="fixture-ahead",alertstate="firing"}' 2>&1)"
  case "$firing" in *'=>'*) break ;; esac
done
printf '%s\n' "$firing"
echo '---normal'
printf '%s\n' "$normal"
echo '---ages'
promtool query instant $URL 'abs(time() - tnauqquant_probe_timestamp_seconds) < 180' 2>&1
RUN

# Files travel over stdin: a bind mount of $TMPDIR is empty on a Docker VM.
output="$(tar -C "$WORK" -cf - . | docker run -i --rm --network none --entrypoint /bin/sh "$IMAGE" \
  -c 'mkdir -p /tmp/w && tar -xf - -C /tmp/w && sh /tmp/w/run.sh')"
firing="${output%%---normal*}"
rest="${output#*---normal}"
normal="${rest%%---ages*}"
ages="${rest#*---ages}"
[[ "$ages" == *'server_id="fixture-ahead"'* ]] || \
  fail "fixture no longer shows the blind spot: the ahead host must look fresh by age"
[[ "$normal" != *'=>'* ]] || fail "a normal host raised TradingSourceClockAhead"
[[ "$firing" == *'alertstate="firing"'*'server_id="fixture-ahead"'*'=>'* ]] || \
  fail "a host running ahead never fired TradingSourceClockAhead"
printf 'PASS: source clock ahead detection\n'
