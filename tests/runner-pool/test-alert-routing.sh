#!/usr/bin/env bash
set -euo pipefail

# Runs the repository's runner-pool Alertmanager routing through a real pinned
# Alertmanager container with every receiver replaced by a local CGI webhook
# sink. No Telegram or mail configuration reaches the container and it runs with
# --network none, so nothing can notify anyone.
#
# Verifies:
# 1. All 11 alerts in prometheus/rules/runner-pool.yml carry
#    notification_mode=shadow and product=runner-pool and route to shadow-null.
# 2. Static route contract on the unmodified alertmanager.yml (repeat_interval:
#    4h on pool High vs 30m on general High, group_wait: 0s, server_id in
#    group_by, BriefOffline route without active_time_intervals).
# 3. Live Alertmanager Run 1 (outside work-hours):
#    - Two simultaneous PoolHostOffline alerts (pool-win, pool-ubuntu) arrive before
#      the 10s root group_wait (proving group_wait: 0s) as two separate groups
#      at telegram-high only (not email-high).
#    - Shadow pool High / Medium / BriefOffline arrive only at shadow-null.
#    - Page pool High arrives at both email-high and telegram-high (0s wait).
#    - Non-shadow PoolHostBriefOffline delivers to telegram-medium outside
#      work-hours, while PoolHostHeld and other products' Medium are blocked.
#    - Other products' High still routes to telegram-high (not email-high).
# 4. Live Alertmanager Run 2 (inside work-hours):
#    - PoolHostBriefOffline, PoolHostHeld and other products' Medium all deliver
#      to telegram-medium, proving Run 1's blocking came from work-hours.
# 5. Live Alertmanager Run 3 (shortened test-only group_interval and general
#    High repeat_interval; pool High repeat_interval stays 4h):
#    - Resolving pool-win delivers resolved only for pool-win's group while
#      pool-ubuntu remains firing without resolving.
#    - Other product's High repeats (>= 2 deliveries) while pool-ubuntu
#      PoolHostOffline delivers only once (4h route, not 30m).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG="$REPO_ROOT/alertmanager/alertmanager.yml"
RULES="$REPO_ROOT/prometheus/rules/runner-pool.yml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for tool in docker python3 tar; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required; this suite must not pass by skipping"
done

IMAGE="$(sed -n -E 's/^[[:space:]]*image:[[:space:]]*(prom\/alertmanager:[^[:space:]]+).*$/\1/p' \
  "$REPO_ROOT/docker-compose.yml" | head -n 1)"
[[ -n "$IMAGE" ]] || fail "cannot find the pinned Alertmanager image"

docker image inspect "$IMAGE" >/dev/null 2>&1 || \
  fail "$IMAGE is not on this machine; run docker pull $IMAGE (this suite never pulls)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-pool-routing.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cp "$CONFIG" "$WORK/repo-alertmanager.yml"

# Render test configs and extract the 11 shadow rules from runner-pool.yml.
python3 -I - "$CONFIG" "$RULES" "$WORK" <<'PY'
import datetime
import re
import sys

config_path, rules_path, work = sys.argv[1:4]
text = open(config_path, encoding="utf-8").read()

# 1. Static route contract checks on the unmodified repository alertmanager.yml
split = re.search(r"^receivers:$", text, re.M).start()
routes_section = text[:split]
receivers_section = text[split:]

# Parse receiver names and their send_resolved flag from the real config.
receiver_blocks = re.split(r"(?m)^  - name: (\S+)\s*$", receivers_section)[1:]
receivers = []
for i in range(0, len(receiver_blocks), 2):
    name = receiver_blocks[i]
    block = receiver_blocks[i + 1]
    send_resolved = bool(re.search(r"^\s*send_resolved:\s*true\b", block, re.M))
    receivers.append((name, send_resolved))

assert receivers, "no receivers found in alertmanager.yml"

def extract_route_block(pattern):
    m = re.search(pattern, routes_section, re.M)
    assert m, f"route not found: {pattern}"
    start = m.start()
    nxt = re.search(r"(?m)^    - matchers:", routes_section[m.end():])
    end = m.end() + nxt.start() if nxt else len(routes_section)
    return start, routes_section[start:end]

shadow_pos, _ = extract_route_block(r'^    - matchers: \[notification_mode="shadow"\]$')
email_pos, email_blk = extract_route_block(r'^    - matchers: \[severity="High", notification_mode="page"\]$')
pool_high_pos, pool_high_blk = extract_route_block(r'^    - matchers: \[product="runner-pool", severity="High"\]$')
brief_pos, brief_blk = extract_route_block(r'^    - matchers: \[product="runner-pool", alertname="PoolHostBriefOffline"\]$')
gen_high_pos, gen_high_blk = extract_route_block(r'^    - matchers: \[severity="High"\]$')
gen_med_pos, gen_med_blk = extract_route_block(r'^    - matchers: \[severity="Medium"\]$')

assert shadow_pos < email_pos < pool_high_pos < gen_high_pos, "pool High route order is wrong"
assert shadow_pos < brief_pos < gen_med_pos, "PoolHostBriefOffline route order is wrong"
assert re.search(r"receiver:\s*telegram-high\b", pool_high_blk), "pool High must target telegram-high"
assert re.search(r"group_by:\s*\[[^\]]*\bserver_id\b[^\]]*\]", pool_high_blk), "pool High group_by must contain server_id"
assert re.search(r"group_wait:\s*0s\b", pool_high_blk), "pool High must set group_wait: 0s"
assert re.search(r"repeat_interval:\s*4h\b", pool_high_blk), "pool High must set repeat_interval: 4h"
assert re.search(r"continue:\s*false\b", pool_high_blk), "pool High must set continue: false"
assert re.search(r"receiver:\s*telegram-medium\b", brief_blk), "BriefOffline must target telegram-medium"
assert "active_time_intervals" not in brief_blk, "BriefOffline must not set active_time_intervals"
assert re.search(r"continue:\s*false\b", brief_blk), "BriefOffline must set continue: false"
assert re.search(r"repeat_interval:\s*30m\b", gen_high_blk), "general High must keep repeat_interval: 30m"
assert re.search(r"active_time_intervals:\s*\[work-hours\]", gen_med_blk), "general Medium must keep work-hours"
assert re.search(r"continue:\s*true\b", email_blk), "email-high must keep continue: true"

def render_with_sinks(head):
    sinks = "".join(
        f"  - name: {name}\n    webhook_configs:\n"
        f"      - url: http://127.0.0.1:9099/cgi-bin/sink/{name}\n"
        f"        send_resolved: {'true' if resolved else 'false'}\n"
        for name, resolved in receivers
    )
    rendered = head + "receivers:\n" + sinks
    for forbidden in ("telegram_configs", "bot_token", "chat_id", "email_configs",
                      "smarthost", "auth_password", "deadman_url"):
        assert forbidden not in rendered, f"forbidden config leaked: {forbidden}"
    return rendered

# Compute Asia/Taipei (UTC+8, no DST) time windows relative to now.
taipei_now = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=8)
now_min = taipei_now.hour * 60 + taipei_now.minute
out_start = (now_min + 720) % 1440
if out_start >= 1439:
    out_start = 1438
out_end = out_start + 1
outside_window = f"{out_start // 60:02d}:{out_start % 60:02d}", f"{out_end // 60:02d}:{out_end % 60:02d}"

work_hours_re = re.compile(
    r"(?m)^(\s*- times: \[\{ start_time: ')[0-9]{2}:[0-9]{2}(', end_time: ')[0-9]{2}:[0-9]{2}(' \}\]\s*)$"
)
assert work_hours_re.search(routes_section), "could not locate work-hours times block"

# Run 1 config: outside work-hours (1-minute window ~12h away), all timings untouched.
head_outside = work_hours_re.sub(rf"\g<1>{outside_window[0]}\g<2>{outside_window[1]}\g<3>", routes_section, count=1)
open(f"{work}/am-outside.yml", "w", encoding="utf-8").write(render_with_sinks(head_outside))

# Run 2 config: inside work-hours (00:00..24:00 covers now), all timings untouched.
head_inside = work_hours_re.sub(r"\g<1>00:00\g<2>24:00\g<3>", routes_section, count=1)
open(f"{work}/am-inside.yml", "w", encoding="utf-8").write(render_with_sinks(head_inside))

# Run 3 config: shortened test-only group_interval (1s) and general High repeat_interval (2s)
# while keeping pool High repeat_interval at 4h untouched.
head_repeat = re.sub(r"(?m)^(\s*group_interval:\s*)5m\b", r"\g<1>1s", head_outside, count=1)
gen_high_re = re.compile(
    r'(?ms)(^    - matchers: \[severity="High"\]\n.*?^      repeat_interval:\s*)30m\b'
)
assert gen_high_re.search(head_repeat), "could not locate general High repeat_interval: 30m"
head_repeat = gen_high_re.sub(r"\g<1>2s", head_repeat, count=1)
assert 'repeat_interval: 4h' in head_repeat, "pool High repeat_interval: 4h must remain untouched"
open(f"{work}/am-repeat.yml", "w", encoding="utf-8").write(render_with_sinks(head_repeat))

# 2. Extract all alert rules from prometheus/rules/runner-pool.yml and assert shadow + product.
rules_text = open(rules_path, encoding="utf-8").read()
alert_chunks = re.split(r"(?m)^      - alert: (\S+)\s*$", rules_text)[1:]
alerts = []
for i in range(0, len(alert_chunks), 2):
    alertname = alert_chunks[i]
    chunk = alert_chunks[i + 1]
    labels_m = re.search(r"(?m)^        labels:\n((?:          .+\n)+)", chunk)
    assert labels_m, f"{alertname}: missing labels block"
    labels = {}
    for line in labels_m.group(1).splitlines():
        k, v = line.strip().split(":", 1)
        labels[k.strip()] = v.strip().strip('"').replace("{{ $labels.host }}", "win")
    assert labels.get("notification_mode") == "shadow", f"{alertname}: notification_mode must be shadow"
    assert labels.get("product") == "runner-pool", f"{alertname}: product must be runner-pool"
    assert labels.get("server_id"), f"{alertname}: missing server_id"
    alerts.append((alertname, labels))

assert len(alerts) == 11, f"expected 11 rules in runner-pool.yml, found {len(alerts)}"
with open(f"{work}/shadow-alerts.txt", "w", encoding="utf-8") as fh:
    for alertname, labels in alerts:
        pairs = [f"alertname={alertname}"] + [f"{k}={v}" for k, v in sorted(labels.items())]
        fh.write(" ".join(pairs) + "\n")

print(f"ok      static route contract verified (outside work-hours window: {outside_window[0]}-{outside_window[1]} Asia/Taipei)")
print(f"ok      all {len(alerts)} rules in prometheus/rules/runner-pool.yml carry notification_mode=shadow and product=runner-pool")
PY

cat >"$WORK/sink.cgi" <<'SINK'
#!/bin/sh
body="$(head -c "${CONTENT_LENGTH:-0}")"
printf '%s %s\n' "${PATH_INFO#/}" "$body" >>/tmp/sink.log
printf 'Status: 200 OK\r\nContent-Type: text/plain\r\n\r\nok\n'
SINK

cat >"$WORK/run.sh" <<'RUN'
#!/bin/sh
set -eu
URL=http://127.0.0.1:9093
mkdir -p /tmp/www/cgi-bin
cp /tmp/w/sink.cgi /tmp/www/cgi-bin/sink
chmod 755 /tmp/www/cgi-bin/sink
httpd -f -p 127.0.0.1:9099 -h /tmp/www &
HTTPD_PID=$!
trap 'kill "$HTTPD_PID" 2>/dev/null || true' EXIT

# 0. Verify unmodified repo alertmanager.yml + shadow routing of all 11 rules.
amtool check-config /tmp/w/repo-alertmanager.yml >/dev/null
amtool check-config /tmp/w/am-outside.yml >/dev/null
amtool check-config /tmp/w/am-inside.yml >/dev/null
amtool check-config /tmp/w/am-repeat.yml >/dev/null

while IFS= read -r labels; do
  amtool config routes test --config.file=/tmp/w/repo-alertmanager.yml \
    --verify.receivers=shadow-null $labels >/dev/null
done </tmp/w/shadow-alerts.txt
echo "SHADOW-ROUTES-OK"

start_am() { # start_am CONFIG STORAGE
  rm -rf "$2"
  : >/tmp/sink.log
  alertmanager --config.file="$1" --storage.path="$2" \
    --web.listen-address=127.0.0.1:9093 --cluster.listen-address= \
    --log.level=warn >/tmp/am.log 2>&1 &
  AM_PID=$!
  i=0
  while [ "$i" -lt 40 ]; do
    if wget -q -O /dev/null "$URL/-/ready" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  cat /tmp/am.log >&2
  exit 1
}

stop_am() {
  kill "$AM_PID" 2>/dev/null || true
  wait "$AM_PID" 2>/dev/null || true
}

add_alert() {
  amtool alert add --alertmanager.url="$URL" --annotation=summary=fixture "$@" >/dev/null
}

# ── Run 1: outside work-hours (real timings intact) ──────────────────────────
start_am /tmp/w/am-outside.yml /tmp/am-1
add_alert alertname=PoolHostOffline severity=High product=runner-pool server_id=pool-win host=win
add_alert alertname=PoolHostOffline severity=High product=runner-pool server_id=pool-ubuntu host=ubuntu
add_alert alertname=PoolHostOffline severity=High product=runner-pool server_id=pool-shadow host=shadow notification_mode=shadow
add_alert alertname=PoolHostOffline severity=High product=runner-pool server_id=pool-page host=page notification_mode=page
add_alert alertname=PoolHostBriefOffline severity=Medium product=runner-pool server_id=pool-win host=win
add_alert alertname=PoolHostBriefOffline severity=Medium product=runner-pool server_id=pool-shadow host=shadow notification_mode=shadow
add_alert alertname=PoolHostHeld severity=Medium product=runner-pool server_id=pool-win host=win
add_alert alertname=PoolHostHeld severity=Medium product=runner-pool server_id=pool-shadow host=shadow notification_mode=shadow
add_alert alertname=HostHighCPU severity=Medium product=ppclub server_id=prod01
add_alert alertname=BackendDown severity=High product=ppclub server_id=prod01

# Root group_wait is 10s, so only 0s routes (pool High, email-high, general High) arrive by 4s.
sleep 4
echo "=== RUN1-EARLY ==="
cat /tmp/sink.log
sleep 10
echo "=== RUN1-FULL ==="
cat /tmp/sink.log
stop_am

# ── Run 2: inside work-hours (control test proving work-hours did the blocking)
start_am /tmp/w/am-inside.yml /tmp/am-2
add_alert alertname=PoolHostBriefOffline severity=Medium product=runner-pool server_id=pool-win host=win
add_alert alertname=PoolHostHeld severity=Medium product=runner-pool server_id=pool-win host=win
add_alert alertname=HostHighCPU severity=Medium product=ppclub server_id=prod01
sleep 14
echo "=== RUN2-FULL ==="
cat /tmp/sink.log
stop_am

# ── Run 3: independent resolved + repeat_interval 4h vs 30m behavioral proof ─
start_am /tmp/w/am-repeat.yml /tmp/am-3
add_alert alertname=PoolHostOffline severity=High product=runner-pool server_id=pool-win host=win
add_alert alertname=PoolHostOffline severity=High product=runner-pool server_id=pool-ubuntu host=ubuntu
add_alert alertname=BackendDown severity=High product=ppclub server_id=prod01
sleep 2
# End ONLY pool-win; pool-ubuntu and ppclub BackendDown stay firing.
add_alert --end="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  alertname=PoolHostOffline severity=High product=runner-pool server_id=pool-win host=win
sleep 6
echo "=== RUN3-FULL ==="
cat /tmp/sink.log
stop_am
RUN

tar -C "$WORK" -cf - repo-alertmanager.yml am-outside.yml am-inside.yml am-repeat.yml shadow-alerts.txt sink.cgi run.sh | \
  docker run -i --rm --pull never --network none --entrypoint /bin/sh "$IMAGE" \
    -c 'mkdir -p /tmp/w && tar -xf - -C /tmp/w && sh /tmp/w/run.sh' >"$WORK/results.log"

python3 -I - "$WORK/results.log" <<'PY'
import json
import sys

sections = {}
current = "preamble"
sections[current] = []
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.rstrip("\n")
    if line.startswith("=== ") and line.endswith(" ==="):
        current = line[4:-4]
        sections[current] = []
    elif line:
        sections[current].append(line)

def parse_deliveries(lines):
    out = []
    for line in lines:
        receiver, body = line.split(" ", 1)
        payload = json.loads(body)
        out.append((receiver, payload))
    return out

def alert_tuples(deliveries):
    seen = set()
    for receiver, payload in deliveries:
        for alert in payload.get("alerts", []):
            labels = alert.get("labels", {})
            seen.add((receiver, labels.get("product"), labels.get("server_id"),
                      labels.get("alertname"), alert.get("status")))
    return seen

failures = 0
def expect(description, condition):
    global failures
    print(("ok      " if condition else "not ok  ") + description)
    if not condition:
        failures += 1

expect("all 11 runner-pool rules route to shadow-null via amtool",
       "SHADOW-ROUTES-OK" in sections.get("preamble", []))

r1_early = parse_deliveries(sections.get("RUN1-EARLY", []))
r1_full = parse_deliveries(sections.get("RUN1-FULL", []))
r2_full = parse_deliveries(sections.get("RUN2-FULL", []))
r3_full = parse_deliveries(sections.get("RUN3-FULL", []))

r1_early_set = alert_tuples(r1_early)
r1_full_set = alert_tuples(r1_full)
r2_full_set = alert_tuples(r2_full)

# Run 1 EARLY: group_wait: 0s and separate groups per server_id
pool_early_groups = [
    p for r, p in r1_early
    if r == "telegram-high"
    and p.get("groupLabels", {}).get("alertname") == "PoolHostOffline"
    and p.get("groupLabels", {}).get("server_id") in ("pool-win", "pool-ubuntu")
]
expect("two simultaneous PoolHostOffline hosts arrive within 4s (group_wait: 0s) as two separate groups",
       len(pool_early_groups) == 2
       and {p["groupLabels"]["server_id"] for p in pool_early_groups} == {"pool-win", "pool-ubuntu"}
       and all(len(p["alerts"]) == 1 for p in pool_early_groups))

expect("non-page PoolHostOffline reaches telegram-high and NOT email-high",
       ("telegram-high", "runner-pool", "pool-win", "PoolHostOffline", "firing") in r1_full_set
       and ("telegram-high", "runner-pool", "pool-ubuntu", "PoolHostOffline", "firing") in r1_full_set
       and ("email-high", "runner-pool", "pool-win", "PoolHostOffline", "firing") not in r1_full_set
       and ("email-high", "runner-pool", "pool-ubuntu", "PoolHostOffline", "firing") not in r1_full_set)

expect("page PoolHostOffline reaches both email-high and telegram-high with 0s group_wait",
       ("email-high", "runner-pool", "pool-page", "PoolHostOffline", "firing") in r1_early_set
       and ("telegram-high", "runner-pool", "pool-page", "PoolHostOffline", "firing") in r1_early_set)

shadow_non_null = [
    t for t in r1_full_set
    if t[2] == "pool-shadow" and t[0] != "shadow-null"
]
shadow_null_alerts = {t[3] for t in r1_full_set if t[2] == "pool-shadow" and t[0] == "shadow-null"}
expect("shadow pool alerts (High, Medium, BriefOffline) go ONLY to shadow-null",
       not shadow_non_null
       and shadow_null_alerts == {"PoolHostOffline", "PoolHostBriefOffline", "PoolHostHeld"})

expect("PoolHostBriefOffline delivers to telegram-medium outside work-hours",
       ("telegram-medium", "runner-pool", "pool-win", "PoolHostBriefOffline", "firing") in r1_full_set)

expect("PoolHostHeld and other products' Medium are blocked outside work-hours",
       ("telegram-medium", "runner-pool", "pool-win", "PoolHostHeld", "firing") not in r1_full_set
       and ("telegram-medium", "ppclub", "prod01", "HostHighCPU", "firing") not in r1_full_set)

expect("other product High (ppclub BackendDown) still delivers to telegram-high with 0s wait and not email-high",
       ("telegram-high", "ppclub", "prod01", "BackendDown", "firing") in r1_early_set
       and ("email-high", "ppclub", "prod01", "BackendDown", "firing") not in r1_full_set)

# Run 2: inside work-hours control
expect("inside work-hours, PoolHostBriefOffline, PoolHostHeld and ppclub Medium all deliver to telegram-medium",
       ("telegram-medium", "runner-pool", "pool-win", "PoolHostBriefOffline", "firing") in r2_full_set
       and ("telegram-medium", "runner-pool", "pool-win", "PoolHostHeld", "firing") in r2_full_set
       and ("telegram-medium", "ppclub", "prod01", "HostHighCPU", "firing") in r2_full_set)

# Run 3: separate resolved + repeat_interval 4h vs 30m
win_deliveries = [
    p for r, p in r3_full
    if r == "telegram-high" and p.get("groupLabels", {}).get("server_id") == "pool-win"
]
ubuntu_deliveries = [
    p for r, p in r3_full
    if r == "telegram-high" and p.get("groupLabels", {}).get("server_id") == "pool-ubuntu"
]
ppclub_deliveries = [
    p for r, p in r3_full
    if r == "telegram-high"
    and p.get("groupLabels", {}).get("product") == "ppclub"
    and p.get("groupLabels", {}).get("alertname") == "BackendDown"
]

expect("resolving pool-win delivers resolved in pool-win's own group while pool-ubuntu stays firing without resolving",
       any(p.get("status") == "firing" for p in win_deliveries)
       and any(p.get("status") == "resolved" for p in win_deliveries)
       and all(len(p["alerts"]) == 1 for p in win_deliveries)
       and len(ubuntu_deliveries) == 1
       and ubuntu_deliveries[0].get("status") == "firing"
       and all(p.get("status") != "resolved" for p in ubuntu_deliveries))

expect("pool High stays on 4h repeat (1 delivery) while other product High repeats on the general 30m route (>= 2 deliveries)",
       len(ubuntu_deliveries) == 1 and len(ppclub_deliveries) >= 2)

sys.exit(1 if failures else 0)
PY

printf 'PASS: runner-pool Alertmanager routing (shadow, grouping, resolved, repeat_interval, work-hours)\n'
