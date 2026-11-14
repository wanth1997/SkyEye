#!/usr/bin/env bash
set -euo pipefail

# The SkyEyeWatchdog dead man's switch, end to end and offline:
#   1. the pinned Prometheus loads the real rules and the watchdog fires on its
#      own TSDB head, so the metric name and the millisecond units are right;
#   2. amtool routes the loaded labels through the repository's alertmanager.yml:
#      the watchdog reaches deadman-external whatever other labels it carries;
#   3. a real Alertmanager runs the repository config with no deadman_url, the
#      state right after deploy: it stays ready, the ping fails without a retry
#      loop and the other routes still deliver. Then the secret is written,
#      without a reload, and the next flush must POST the ping.
# Containers have no network. Telegram and mail receivers are replaced by local
# sinks, deadman-external is kept as written, and no secret reaches a container.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FAILED=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

record() {
  printf 'not ok  %s\n' "$*"
  FAILED=1
}

image() {
  sed -n -E "s/^[[:space:]]*image:[[:space:]]*($1:[^[:space:]]+).*\$/\\1/p" \
    "$REPO_ROOT/docker-compose.yml" | head -n 1
}

command -v docker >/dev/null 2>&1 || fail "docker is required; this suite must not pass by skipping"
PROM_IMAGE="$(image 'prom\/prometheus')"
AM_IMAGE="$(image 'prom\/alertmanager')"
[[ -n "$PROM_IMAGE" && -n "$AM_IMAGE" ]] || fail "cannot find the pinned images"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-deadman.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/prom" "$WORK/am"
cp "$REPO_ROOT/prometheus/rules/deadman.yml" "$REPO_ROOT/prometheus/rules/stack-health.yml" "$WORK/prom/"

# ── 1. The watchdog fires on a healthy, real Prometheus ─────────────────────
cat >"$WORK/prom/prometheus.yml" <<'CONFIG'
global:
  scrape_interval: 1s
rule_files:
  - /tmp/w/deadman.yml
  - /tmp/w/stack-health.yml
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
CONFIG

cat >"$WORK/prom/run.sh" <<'RUN'
#!/bin/sh
URL=http://127.0.0.1:9090
prometheus --config.file=/tmp/w/prometheus.yml --storage.tsdb.path=/tmp/p \
  --web.listen-address=127.0.0.1:9090 --log.level=error >/tmp/p.log 2>&1 &
# The deadman group runs every minute and its first run lands up to a minute
# after start.
deadline=$(($(date +%s) + 100))
until wget -qO- "$URL/api/v1/rules?type=alert" 2>/dev/null | grep -q '"state":"firing","name":"SkyEyeWatchdog"'; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo 'not ok  SkyEyeWatchdog does not fire on a healthy Prometheus'
    break
  fi
  sleep 2
done
wget -qO /tmp/w/rules.json "$URL/api/v1/rules"
echo "RULES $(cat /tmp/w/rules.json)"
RUN

# Files travel over stdin: a bind mount of $TMPDIR is empty on a Docker VM.
tar -C "$WORK/prom" -cf - . | docker run -i --rm --network none --entrypoint /bin/sh "$PROM_IMAGE" \
  -c 'mkdir -p /tmp/w && tar -xf - -C /tmp/w && sh /tmp/w/run.sh' >"$WORK/prom.log"
while IFS= read -r line; do
  [[ "$line" == 'not ok'* ]] && record "${line#not ok  }"
done <"$WORK/prom.log"

# ── 2. Inputs for Alertmanager: loaded labels, routes and a sink config ─────
# The labels are the ones Prometheus loaded, so the watchdog is tested as it
# would really be sent.
python3 -I - "$WORK/prom.log" "$REPO_ROOT/alertmanager/alertmanager.yml" \
  "$REPO_ROOT/docker-compose.yml" "$WORK/am" <<'PY'
import json, re, sys
log, config, compose, out = sys.argv[1:5]
line = next((l for l in open(log, encoding="utf-8") if l.startswith("RULES ")), None)
if line is None:
    sys.exit("FAIL: Prometheus returned no rules")
rules = {r["name"]: r for g in json.loads(line[6:])["data"]["groups"] for r in g["rules"]}

def labels(name, **extra):
    found = dict(rules[name].get("labels", {}))
    found.update(extra)
    return " ".join([f"alertname={name}"] + [f"{k}={v}" for k, v in sorted(found.items())])

watchdog = labels("SkyEyeWatchdog")
with open(f"{out}/routes.txt", "w", encoding="utf-8") as routes:
    for receiver, fields in (
        ("deadman-external", watchdog),
        # The first route wins over the shadow and High routes below it.
        ("deadman-external", labels("SkyEyeWatchdog", notification_mode="shadow")),
        ("deadman-external", labels("SkyEyeWatchdog", severity="High")),
        ("deadman-external", labels("SkyEyeWatchdog", severity="High", notification_mode="page")),
        ("telegram-high", "alertname=BackendDown severity=High product=fixture"),
        ("telegram-low", "alertname=DailyHeartbeat severity=Low"),
    ):
        routes.write(f"{receiver} {fields}\n")
with open(f"{out}/watchdog.txt", "w", encoding="utf-8") as alert:
    alert.write(watchdog + " instance=localhost:9090 job=prometheus\n")

# deadman-external stays exactly as written, with its real url_file path, which
# the compose file maps onto this checkout's alertmanager/secrets.
text = open(config, encoding="utf-8").read()
assert re.search(r"^\s+- \./alertmanager:/etc/alertmanager:ro$", open(compose, encoding="utf-8").read(), re.M), \
    "compose no longer mounts ./alertmanager at /etc/alertmanager"
split = re.search(r"^receivers:$", text, re.M).end() + 1
starts = [m.start() + split for m in re.finditer(r"^  - name: (\S+)$", text[split:], re.M)]
blocks = [text[a:b] for a, b in zip(starts, starts[1:] + [len(text)])]
rendered = text[:split]
deadman = None
for block in blocks:
    name = re.match(r"  - name: (\S+)", block).group(1)
    if name == "deadman-external":
        deadman = block
        rendered += block
    elif name == "shadow-null":
        rendered += block
    else:
        rendered += (f"  - name: {name}\n    webhook_configs:\n"
                     f"      - url: http://127.0.0.1:9099/cgi-bin/sink/{name}\n        send_resolved: false\n\n")
assert deadman is not None, "deadman-external receiver is missing"
assert "url_file: /etc/alertmanager/secrets/deadman_url" in deadman, deadman
assert not re.search(r"^\s+url:", deadman, re.M), "the ping URL must not be in Git"
assert "send_resolved: false" in deadman, deadman
for forbidden in ("telegram_configs", "bot_token", "chat_id", "email_configs", "smarthost", "auth_password"):
    assert forbidden not in rendered, forbidden
open(f"{out}/sinks.yml", "w", encoding="utf-8").write(rendered)
PY
cp "$REPO_ROOT/alertmanager/alertmanager.yml" "$WORK/am/repo.yml"

cat >"$WORK/am/sink.cgi" <<'SINK'
#!/bin/sh
body="$(head -c "${CONTENT_LENGTH:-0}")"
printf '%s %s %s %s\n' "$REQUEST_METHOD" "${PATH_INFO#/}" "${CONTENT_TYPE:--}" "$body" >>/tmp/sink.log
printf 'Status: 200 OK\r\nContent-Type: text/plain\r\n\r\nok\n'
SINK

# ── 3. Routes, then the no-secret state, then the secret appearing ──────────
cat >"$WORK/am/run.sh" <<'RUN'
#!/bin/sh
URL=http://127.0.0.1:9093
SECRETS=/etc/alertmanager/secrets
while read -r receiver labels; do
  amtool config routes test --config.file=/tmp/w/repo.yml --verify.receivers="$receiver" \
    $labels >/tmp/route.log 2>&1 || echo "not ok  $labels should reach $receiver, got $(head -n 1 /tmp/route.log)"
done </tmp/w/routes.txt

# The state right after deploy: the config is live, secrets/ has no deadman_url.
rm -rf "$SECRETS" && mkdir -p "$SECRETS"
cp /tmp/w/repo.yml /etc/alertmanager/repo.yml
amtool check-config /etc/alertmanager/repo.yml >/tmp/check.log 2>&1 || \
  echo "not ok  amtool check-config rejects the repository config without secrets: $(tail -n 3 /tmp/check.log)"
cp /tmp/w/sinks.yml /etc/alertmanager/alertmanager.yml

mkdir -p /tmp/www/cgi-bin
cp /tmp/w/sink.cgi /tmp/www/cgi-bin/sink
chmod 755 /tmp/www/cgi-bin/sink
: >/tmp/sink.log
httpd -f -p 127.0.0.1:9099 -h /tmp/www &
alertmanager --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/tmp/am \
  --web.listen-address=127.0.0.1:9093 --cluster.listen-address= >/tmp/am.log 2>&1 &
AM_PID=$!
deadline=$(($(date +%s) + 20))
until wget -qO /dev/null "$URL/-/ready" 2>/dev/null; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo 'not ok  Alertmanager does not become ready without deadman_url'
    cat /tmp/am.log
    exit 0
  fi
  sleep 1
done

amtool alert add --alertmanager.url=$URL $(cat /tmp/w/watchdog.txt) --annotation=summary=fixture >/dev/null
amtool alert add --alertmanager.url=$URL alertname=BackendDown severity=High product=fixture \
  --annotation=summary=fixture >/dev/null
# Both routes have no group wait. Let a few flushes pass on the watchdog.
sleep 5
kill -0 "$AM_PID" 2>/dev/null || echo 'not ok  Alertmanager exited without deadman_url'
wget -qO /dev/null "$URL/-/ready" 2>/dev/null || echo 'not ok  Alertmanager is not ready without deadman_url'
echo "NOSECRET-SINK-BEGIN"
cat /tmp/sink.log
echo "NOSECRET-SINK-END"
echo "NOSECRET-LOG-BEGIN"
grep -v 'level=info' /tmp/am.log
echo "NOSECRET-LOG-END"
echo "NOSECRET-METRICS-BEGIN"
wget -qO- "$URL/metrics" | grep -E '^alertmanager_notifications_(failed_)?total\{integration="webhook"'
echo "NOSECRET-METRICS-END"

# The operator places the secret with a temp file and a rename; no reload.
printf 'http://127.0.0.1:9099/cgi-bin/sink/deadman-ping\n' >"$SECRETS/deadman_url.tmp"
mv "$SECRETS/deadman_url.tmp" "$SECRETS/deadman_url"
# A failed send leaves nothing in the notification log, so the next 1m flush
# sends again.
deadline=$(($(date +%s) + 80))
until grep -q ' deadman-ping ' /tmp/sink.log; do
  [ "$(date +%s)" -lt "$deadline" ] || break
  sleep 2
done
kill -0 "$AM_PID" 2>/dev/null || echo 'not ok  Alertmanager exited after deadman_url appeared'
echo "SECRET-SINK-BEGIN"
cat /tmp/sink.log
echo "SECRET-SINK-END"
RUN

tar -C "$WORK/am" -cf - . | docker run -i --rm --network none --entrypoint /bin/sh "$AM_IMAGE" \
  -c 'mkdir -p /tmp/w && tar -xf - -C /tmp/w && sh /tmp/w/run.sh' >"$WORK/am.log"
while IFS= read -r line; do
  [[ "$line" == 'not ok'* ]] && record "${line#not ok  }"
done <"$WORK/am.log"

python3 -I - "$WORK/am.log" <<'PY' || FAILED=1
import json, sys
sections, current = {}, None
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if line.endswith("-BEGIN"):
        current = line[:-6]
        sections[current] = []
    elif line.endswith("-END"):
        current = None
    elif current:
        sections[current].append(line)

failures = 0
def expect(description, condition):
    global failures
    print(("ok      " if condition else "not ok  ") + description)
    failures += 0 if condition else 1

def deliveries(section):
    for line in sections.get(section, []):
        method, path, ctype, body = line.split(" ", 3)
        yield method, path, ctype, json.loads(body)

before = list(deliveries("NOSECRET-SINK"))
log = "\n".join(sections.get("NOSECRET-LOG", []))
metrics = "\n".join(sections.get("NOSECRET-METRICS", []))
expect("without deadman_url the watchdog reaches no sink",
       not any(a["labels"]["alertname"] == "SkyEyeWatchdog" for _, _, _, b in before for a in b["alerts"]))
expect("without deadman_url the ping fails on the missing file, once, without retrying",
       "deadman-external/webhook[0]" in log and "read url_file" in log and "after 1 attempts" in log)
expect("without deadman_url the failure is counted under the webhook integration",
       'alertmanager_notifications_failed_total{integration="webhook",reason="other"} 0' not in metrics
       and 'alertmanager_notifications_failed_total{integration="webhook",reason="other"}' in metrics)
expect("without deadman_url other routes still deliver",
       any(p == "telegram-high" and b["alerts"][0]["labels"]["alertname"] == "BackendDown"
           for _, p, _, b in before))

pings = [(m, c, b) for m, p, c, b in deliveries("SECRET-SINK") if p == "deadman-ping"]
expect("once deadman_url exists the next flush pings it without a reload", len(pings) >= 1)
if pings:
    method, ctype, body = pings[0]
    expect("the ping is a JSON POST", method == "POST" and ctype.startswith("application/json"))
    expect("the ping carries the watchdog for deadman-external only",
           body["receiver"] == "deadman-external" and body["status"] == "firing"
           and [a["labels"]["alertname"] for a in body["alerts"]] == ["SkyEyeWatchdog"])
sys.exit(1 if failures else 0)
PY

[[ "$FAILED" -eq 0 ]] || exit 1
printf 'PASS: SkyEyeWatchdog fires, routes first and is safe without deadman_url\n'
