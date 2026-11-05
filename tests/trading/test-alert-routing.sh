#!/usr/bin/env bash
set -euo pipefail

# Runs the repository's routing and inhibition through a real Alertmanager with
# every receiver replaced by a local sink. No Telegram or mail configuration
# reaches the container and it has no network, so this cannot notify anyone.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG="$REPO_ROOT/alertmanager/alertmanager.yml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fail "docker is required; this suite must not pass by skipping"
IMAGE="$(sed -n -E 's/^[[:space:]]*image:[[:space:]]*(prom\/alertmanager:[^[:space:]]+).*$/\1/p' \
  "$REPO_ROOT/docker-compose.yml" | head -n 1)"
[[ -n "$IMAGE" ]] || fail "cannot find the pinned Alertmanager image"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-alert-routing.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

python3 -I - "$CONFIG" "$WORK/alertmanager.yml" <<'PY'
import re, sys
source, target = sys.argv[1:3]
text = open(source, encoding="utf-8").read()
split = re.search(r"^receivers:$", text, re.M).start()
names = re.findall(r"^  - name: (\S+)$", text[split:], re.M)
sinks = "".join(
    f"  - name: {name}\n    webhook_configs:\n"
    f"      - url: http://127.0.0.1:9099/cgi-bin/sink/{name}\n        send_resolved: false\n"
    for name in names
)
rendered = text[:split] + "receivers:\n" + sinks
for forbidden in ("telegram_configs", "bot_token", "chat_id", "email_configs", "smarthost", "auth_password"):
    assert forbidden not in rendered, forbidden
open(target, "w", encoding="utf-8").write(rendered)
PY

cat >"$WORK/sink.cgi" <<'SINK'
#!/bin/sh
body="$(head -c "${CONTENT_LENGTH:-0}")"
printf '%s %s\n' "${PATH_INFO#/}" "$body" >>/tmp/sink.log
printf 'Status: 200 OK\r\nContent-Type: text/plain\r\n\r\nok\n'
SINK
cat >"$WORK/run.sh" <<'RUN'
#!/bin/sh
URL=http://127.0.0.1:9093
mkdir -p /tmp/www/cgi-bin
cp /tmp/w/sink.cgi /tmp/www/cgi-bin/sink
chmod 755 /tmp/www/cgi-bin/sink
: >/tmp/sink.log
httpd -f -p 127.0.0.1:9099 -h /tmp/www &
alertmanager --config.file=/tmp/w/alertmanager.yml --storage.path=/tmp/am \
  --web.listen-address=127.0.0.1:9093 --cluster.listen-address= --log.level=warn >/tmp/am.log 2>&1 &
sleep 2
send() { # send ALERTNAME STRATEGY [MODE]; no MODE sends an alert without the label
  amtool alert add --alertmanager.url=$URL alertname="$1" severity=High product=tnauqquant \
    environment=production server_id=fixture-server strategy="$2" ${3:+notification_mode="$3"} \
    --annotation=summary=fixture >/dev/null
}
SOURCE=TradingCriticalSafetyState
LOG=TradingCriticalLogEvent
WARN=TradingCriticalWarnEvent
DOWN=TradingProcessDown
RISK=TradingRiskStopped

# Every pair runs in both arrival orders, because a target that arrives first
# hides inhibition. The first alert of each pair goes out here, its partner
# after the pause.
send "$SOURCE" page-source-first page
send "$LOG" page-log-first page
send "$SOURCE" shadow-source-first shadow
send "$LOG" shadow-source-last page
send "$SOURCE" shadow-source-first-warn shadow
send "$WARN" shadow-source-last-warn page
send "$SOURCE" shadow-log-last page
send "$LOG" shadow-log-first shadow
send "$SOURCE" all-shadow-source-first shadow
send "$LOG" all-shadow-log-first shadow
sleep 2
send "$LOG" page-source-first page
send "$SOURCE" page-log-first page
send "$LOG" shadow-source-first page
send "$SOURCE" shadow-source-last shadow
send "$WARN" shadow-source-first-warn page
send "$SOURCE" shadow-source-last-warn shadow
send "$LOG" shadow-log-last shadow
send "$SOURCE" shadow-log-first page
send "$LOG" all-shadow-source-first shadow
send "$SOURCE" all-shadow-log-first shadow

send "$LOG" log-alone page
send "$DOWN" process-down-page page
send "$RISK" risk-stopped-page page
send "$DOWN" process-down-shadow shadow
send "$RISK" risk-stopped-shadow shadow
send BackendDown no-mode-high
send "$SOURCE" no-wait page

# The root group_wait is 10s, so only a 0s route has delivered by now.
sleep 4
cat /tmp/sink.log
echo EARLY-SNAPSHOT-END
sleep 10
cat /tmp/sink.log
RUN

# Files travel over stdin: a bind mount of $TMPDIR is empty on a Docker VM.
tar -C "$WORK" -cf - . | docker run -i --rm --network none --entrypoint /bin/sh "$IMAGE" \
  -c 'mkdir -p /tmp/w && tar -xf - -C /tmp/w && sh /tmp/w/run.sh' >"$WORK/sink.log"

python3 -I - "$WORK/sink.log" <<'PY'
import json, sys
early, delivered = set(), set()
current = early
for line in open(sys.argv[1], encoding="utf-8"):
    if line.strip() == "EARLY-SNAPSHOT-END":
        current = delivered
        continue
    receiver, body = line.split(" ", 1)
    for alert in json.loads(body)["alerts"]:
        current.add((alert["labels"]["strategy"], alert["labels"]["alertname"], receiver))

SOURCE, LOG, WARN = "TradingCriticalSafetyState", "TradingCriticalLogEvent", "TradingCriticalWarnEvent"
DOWN, RISK = "TradingProcessDown", "TradingRiskStopped"
TELEGRAM, EMAIL = "telegram-high", "email-high"
failures = 0
def expect(description, condition):
    global failures
    print(("ok      " if condition else "not ok  ") + description)
    failures += 0 if condition else 1

def pages(strategy, alert, seen=delivered):
    return (strategy, alert, TELEGRAM) in seen and (strategy, alert, EMAIL) in seen

def silent(strategy, alert=None):
    return not any(s == strategy and alert in (None, a) and r != "shadow-null"
                   for s, a, r in delivered)

expect("promoted source reaches both sinks when it arrives first", pages("page-source-first", SOURCE))
expect("promoted source still deduplicates its log alert on both sinks", silent("page-source-first", LOG))
expect("promoted log alert reaches both sinks when it arrives first", pages("page-log-first", LOG))
expect("promoted source reaches both sinks when it arrives last", pages("page-log-first", SOURCE))
expect("shadow source does not silence a promoted log alert", pages("shadow-source-first", LOG))
expect("shadow source does not silence a promoted warn alert", pages("shadow-source-first-warn", WARN))
expect("promoted log alert notifies when it arrives before a shadow source", pages("shadow-source-last", LOG))
expect("promoted warn alert notifies when it arrives before a shadow source", pages("shadow-source-last-warn", WARN))
expect("a shadow source sends nothing whichever arrives first",
       all(silent(s, SOURCE) for s in ("shadow-source-first", "shadow-source-last",
                                       "shadow-source-first-warn", "shadow-source-last-warn")))
expect("promoted source reaches both sinks before a shadow log", pages("shadow-log-last", SOURCE))
expect("promoted source reaches both sinks after a shadow log", pages("shadow-log-first", SOURCE))
expect("a shadow log sends nothing whichever arrives first",
       silent("shadow-log-last", LOG) and silent("shadow-log-first", LOG))
expect("all-shadow pairs send nothing in either order",
       silent("all-shadow-source-first") and silent("all-shadow-log-first"))
expect("promoted log alert notifies on its own", pages("log-alone", LOG))
expect("promoted process down reaches both sinks", pages("process-down-page", DOWN))
expect("promoted risk stop reaches both sinks", pages("risk-stopped-page", RISK))
expect("shadow process down and risk stop send nothing",
       silent("process-down-shadow") and silent("risk-stopped-shadow"))
expect("High without a mode stays on Telegram until the switch PR",
       ("no-mode-high", "BackendDown", TELEGRAM) in delivered
       and ("no-mode-high", "BackendDown", EMAIL) not in delivered)
expect("both sinks deliver a page with no group wait", pages("no-wait", SOURCE, early))
sys.exit(1 if failures else 0)
PY
printf 'PASS: Alertmanager shadow and promoted routing\n'
