#!/usr/bin/env bash
set -euo pipefail

# Runs the repository's routing and inhibition through a real Alertmanager with
# every receiver replaced by a local sink. No Telegram configuration reaches the
# container and it has no network, so this cannot notify anyone.

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
split = text.index("receivers:")
names = re.findall(r"^  - name: (\S+)$", text[split:], re.M)
sinks = "".join(
    f"  - name: {name}\n    webhook_configs:\n"
    f"      - url: http://127.0.0.1:9099/cgi-bin/sink/{name}\n        send_resolved: false\n"
    for name in names
)
rendered = text[:split] + "receivers:\n" + sinks
for forbidden in ("telegram_configs", "bot_token", "chat_id"):
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
send() { # send ALERTNAME STRATEGY MODE
  amtool alert add --alertmanager.url=$URL alertname="$1" severity=High product=tnauqquant \
    environment=production server_id=fixture-server strategy="$2" notification_mode="$3" \
    --annotation=summary=fixture >/dev/null
}
SOURCE=TradingCriticalSafetyState
LOG=TradingCriticalLogEvent
WARN=TradingCriticalWarnEvent
send "$SOURCE" both-shadow shadow; sleep 1; send "$LOG" both-shadow shadow
send "$SOURCE" mixed-log shadow; sleep 1; send "$LOG" mixed-log page
send "$SOURCE" mixed-warn shadow; sleep 1; send "$WARN" mixed-warn page
send "$SOURCE" both-page page; sleep 1; send "$LOG" both-page page
send "$LOG" log-alone page
send "$LOG" log-first page; sleep 2; send "$SOURCE" log-first shadow
sleep 14
cat /tmp/sink.log
RUN

# Files travel over stdin: a bind mount of $TMPDIR is empty on a Docker VM.
tar -C "$WORK" -cf - . | docker run -i --rm --network none --entrypoint /bin/sh "$IMAGE" \
  -c 'mkdir -p /tmp/w && tar -xf - -C /tmp/w && sh /tmp/w/run.sh' >"$WORK/sink.log"

python3 -I - "$WORK/sink.log" <<'PY'
import json, sys
delivered = set()
for line in open(sys.argv[1], encoding="utf-8"):
    receiver, body = line.split(" ", 1)
    for alert in json.loads(body)["alerts"]:
        delivered.add((alert["labels"]["strategy"], alert["labels"]["alertname"], receiver))

SOURCE, LOG, WARN = "TradingCriticalSafetyState", "TradingCriticalLogEvent", "TradingCriticalWarnEvent"
HIGH = "telegram-high"
failures = 0
def expect(description, condition):
    global failures
    print(("ok      " if condition else "not ok  ") + description)
    failures += 0 if condition else 1

expect("shadow source does not silence a promoted log alert", ("mixed-log", LOG, HIGH) in delivered)
expect("shadow source does not silence a promoted warn alert", ("mixed-warn", WARN, HIGH) in delivered)
expect("promoted source notifies", ("both-page", SOURCE, HIGH) in delivered)
expect("promoted source still deduplicates its log alert", ("both-page", LOG, HIGH) not in delivered)
expect("promoted log alert notifies on its own", ("log-alone", LOG, HIGH) in delivered)
expect("promoted log alert notifies when it arrives first", ("log-first", LOG, HIGH) in delivered)
expect("shadow alerts never reach a paging receiver",
       not any(s == "both-shadow" and r.startswith("telegram") for s, _, r in delivered))
sys.exit(1 if failures else 0)
PY
printf 'PASS: Alertmanager shadow and promoted routing\n'
