#!/usr/bin/env bash
set -euo pipefail

# The SkyEyeWatchdog dead man's switch, end to end and offline:
#   1. the pinned Prometheus loads the real rules and the watchdog fires on its
#      own TSDB head, so the metric name and the millisecond units are right;
#   2. amtool routes the loaded labels through the repository's alertmanager.yml:
#      the watchdog reaches deadman-external whatever other labels it carries,
#      and AllRemoteAgentsSilent stays in shadow;
#   3. a real Alertmanager starts the repository config exactly as written with
#      no secrets and with a token file, then runs it with no deadman_url, the
#      state right after deploy: it stays ready, the ping fails without a retry
#      loop and the other routes still deliver. Then the secret is written,
#      without a reload, and the next flush must POST the ping;
#   4. the ping endpoint answers 404, then 503, then 200: Alertmanager stays up
#      and ready, counts each failure and still delivers BackendDown. Before
#      v0.28.0 it panicked and exited on the first non-2xx.
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
# The labels are the ones Prometheus loaded, so a rule that loses its shadow
# label or the watchdog that gains one is tested as it would really be sent.
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
remote = labels("AllRemoteAgentsSilent")
promoted = " ".join(f for f in remote.split() if not f.startswith("notification_mode="))
with open(f"{out}/routes.txt", "w", encoding="utf-8") as routes:
    for receiver, fields in (
        ("deadman-external", watchdog),
        # The first route wins over the shadow and High routes below it.
        ("deadman-external", labels("SkyEyeWatchdog", notification_mode="shadow")),
        ("deadman-external", labels("SkyEyeWatchdog", severity="High")),
        ("deadman-external", labels("SkyEyeWatchdog", severity="High", notification_mode="page")),
        ("shadow-null", remote),
        ("telegram-high", promoted),
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

# The non-2xx cases only shorten the watchdog route's flush, so each status code
# takes one flush instead of a minute. The receiver stays as written.
route = "      receiver: deadman-external\n      group_wait: 0s\n      group_interval: 1m\n"
assert rendered.count(route) == 1, "the deadman-external route changed; update the regression config"
open(f"{out}/regress.yml", "w", encoding="utf-8").write(
    rendered.replace(route, route.replace("group_interval: 1m", "group_interval: 5s")))
PY
cp "$REPO_ROOT/alertmanager/alertmanager.yml" "$WORK/am/repo.yml"

cat >"$WORK/am/sink.cgi" <<'SINK'
#!/bin/sh
body="$(head -c "${CONTENT_LENGTH:-0}")"
printf '%s %s %s %s\n' "$REQUEST_METHOD" "${PATH_INFO#/}" "${CONTENT_TYPE:--}" "$body" >>/tmp/sink.log
printf 'Status: 200 OK\r\nContent-Type: text/plain\r\n\r\nok\n'
SINK

# A ping endpoint that answers with the status code in /tmp/status, like a
# deleted check (404) or a heartbeat service in trouble (503).
cat >"$WORK/am/status.cgi" <<'STATUS'
#!/bin/sh
body="$(head -c "${CONTENT_LENGTH:-0}")"
code="$(cat /tmp/status)"
printf '%s %s %s %s\n' "$code" "$REQUEST_METHOD" "${CONTENT_TYPE:--}" "$body" >>/tmp/status.log
printf 'Status: %s Fixture\r\nContent-Type: text/plain\r\n\r\nfixture\n' "$code"
STATUS

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

start_am() { # start_am CONFIG STORAGE LOG; sets AM_PID
  alertmanager --config.file="$1" --storage.path="$2" \
    --web.listen-address=127.0.0.1:9093 --cluster.listen-address= >"$3" 2>&1 &
  AM_PID=$!
}
ready() { # ready SECONDS
  deadline=$(($(date +%s) + $1))
  until wget -qO /dev/null "$URL/-/ready" 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 1
  done
}
stop_am() {
  kill "$AM_PID" 2>/dev/null
  wait "$AM_PID" 2>/dev/null
  return 0
}

# A full start of the config exactly as written, which check-config does not
# cover: email-high with its placeholder smarthost and no smtp_password, a
# templates glob that matches nothing, and then a token file in place.
for state in 'no secrets' 'a tg_token'; do
  start_am /etc/alertmanager/repo.yml /tmp/am-start /tmp/start.log
  if ! ready 20; then
    echo "not ok  the repository config does not start with $state: $(grep -i 'level=error' /tmp/start.log | head -n 2)"
  elif grep -qi 'level=error' /tmp/start.log; then
    echo "not ok  the repository config starts with $state but logs errors: $(grep -i 'level=error' /tmp/start.log | head -n 2)"
  elif ! wget -qO- "$URL/api/v2/status" | grep -q 'email-high'; then
    echo "not ok  the repository config with $state is not the one Alertmanager loaded"
  fi
  stop_am
  rm -rf /tmp/am-start
  printf '123456:fixture-token-not-real\n' >"$SECRETS/tg_token"
done
rm -f "$SECRETS/tg_token"
cp /tmp/w/sinks.yml /etc/alertmanager/alertmanager.yml

mkdir -p /tmp/www/cgi-bin
cp /tmp/w/sink.cgi /tmp/www/cgi-bin/sink
cp /tmp/w/status.cgi /tmp/www/cgi-bin/status
chmod 755 /tmp/www/cgi-bin/sink /tmp/www/cgi-bin/status
: >/tmp/sink.log
httpd -f -p 127.0.0.1:9099 -h /tmp/www &
start_am /etc/alertmanager/alertmanager.yml /tmp/am /tmp/am.log
if ! ready 20; then
  echo 'not ok  Alertmanager does not become ready without deadman_url'
  cat /tmp/am.log
  exit 0
fi

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
grep -vi 'level=info' /tmp/am.log
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
stop_am

# ── 4. The ping endpoint answers 404, then 503, then 200 ───────────────────
# Alertmanager before v0.28.0 panics on a non-2xx answer to a url_file webhook
# and exits (prometheus/alertmanager#3800), taking every route down with it.
webhook() { # webhook failed_|''  -> the webhook counter summed over reasons
  wget -qO- "$URL/metrics" 2>/dev/null | awk -v want="alertmanager_notifications_$1total" '
    { split($1, name, "{") }
    name[1] == want && $1 ~ /integration="webhook"/ { sum += $2 }
    END { printf "%d\n", sum }'
}
waitfor() { # waitfor SECONDS COMMAND...
  deadline=$(($(date +%s) + $1)); shift
  until "$@"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 1
  done
}
answered() { tail -n "+$((seen + 1))" /tmp/status.log | grep -q "^$code "; }
counted() { [ "$(webhook failed_)" -gt "$failed" ]; }
settled() { # the failure count has held for longer than one flush and its retries
  now=$(webhook failed_)
  if [ "$now" != "$last" ]; then last=$now; since=$(date +%s); fi
  [ $(($(date +%s) - since)) -ge 15 ]
}
delivered() { grep -q "^POST telegram-high .*\"product\":\"fixture-$code\"" /tmp/sink.log; }

cp /tmp/w/regress.yml /etc/alertmanager/alertmanager.yml
printf 'http://127.0.0.1:9099/cgi-bin/status/deadman-ping\n' >"$SECRETS/deadman_url.tmp"
mv "$SECRETS/deadman_url.tmp" "$SECRETS/deadman_url"
: >/tmp/status.log
echo 404 >/tmp/status
start_am /etc/alertmanager/alertmanager.yml /tmp/am-status /tmp/am-status.log
ready 20 || echo 'not ok  Alertmanager does not become ready for the status cases'
amtool alert add --alertmanager.url=$URL $(cat /tmp/w/watchdog.txt) --annotation=summary=fixture >/dev/null || \
  echo 'not ok  the watchdog cannot be sent for the status cases'
for code in 404 503 200; do
  if [ "$code" = 200 ]; then
    # A 503 flush retries until its timeout (10s at least) and counts its failure
    # only then. Silence the watchdog so no new flush starts, and wait for the
    # count to hold, so the baseline below holds no 503 failure still to come.
    sid=$(amtool silence add --alertmanager.url=$URL alertname=SkyEyeWatchdog \
      --comment=settle --duration=10m) || echo "not ok  $code: the watchdog cannot be silenced"
    last=-1; since=$(date +%s)
    waitfor 60 settled || echo "not ok  $code: the 503 failures do not settle"
  fi
  seen=$(wc -l </tmp/status.log)
  failed=$(webhook failed_)
  printf '%s\n' "$code" >/tmp/status.tmp && mv /tmp/status.tmp /tmp/status
  [ "$code" != 200 ] || amtool silence expire --alertmanager.url=$URL "$sid" || \
    echo "not ok  $code: the settle silence cannot be expired"
  waitfor 20 answered || echo "not ok  $code: no ping reached the endpoint"
  if [ "$code" = 200 ]; then
    # Let the 200 complete and one more flush pass.
    sleep 6
    [ "$(webhook failed_)" -eq "$failed" ] || echo "not ok  $code: a 2xx answer is counted as a failure"
  else
    waitfor 25 counted || echo "not ok  $code: the failed ping is not counted under the webhook integration"
  fi
  if ! kill -0 "$AM_PID" 2>/dev/null; then
    echo "not ok  $code: Alertmanager exited after the ping endpoint answered $code"
    break
  fi
  wget -qO /dev/null "$URL/-/ready" 2>/dev/null || echo "not ok  $code: Alertmanager is not ready"
  amtool alert add --alertmanager.url=$URL alertname=BackendDown severity=High "product=fixture-$code" \
    --annotation=summary=fixture >/dev/null || echo "not ok  $code: Alertmanager does not accept alerts"
  waitfor 10 delivered || echo "not ok  $code: BackendDown does not reach telegram-high"
  echo "STATUS-$code-METRICS-BEGIN"
  wget -qO- "$URL/metrics" 2>/dev/null | grep -E '^alertmanager_notifications_(failed_)?total\{integration="webhook"'
  echo "STATUS-$code-METRICS-END"
done
stop_am
echo "STATUS-PING-BEGIN"
cat /tmp/status.log
echo "STATUS-PING-END"
echo "STATUS-LOG-BEGIN"
grep -vi 'level=info' /tmp/am-status.log
echo "STATUS-LOG-END"
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

answers = [line.split(" ", 3) for line in sections.get("STATUS-PING", [])]
codes = [a[0] for a in answers]
expect("the ping endpoint saw 404, then 503, then 200",
       "404" in codes and "503" in codes and "200" in codes
       and codes.index("404") < codes.index("503") < codes.index("200"))
ok = [a for a in answers if a[0] == "200"]
expect("after the non-2xx answers the ping is still the watchdog's JSON POST",
       bool(ok) and ok[0][1] == "POST" and ok[0][2].startswith("application/json")
       and json.loads(ok[0][3])["receiver"] == "deadman-external")
status_log = "\n".join(sections.get("STATUS-LOG", []))
expect("no panic while the ping endpoint answers non-2xx", "panic" not in status_log)
# Informational: how this Alertmanager labels each failure (runbooks/skyeye-watchdog.md step 5).
for code in ("404", "503", "200"):
    for line in sections.get(f"STATUS-{code}-METRICS", []):
        if line.startswith("alertmanager_notifications_failed_total"):
            print(f"#       after {code}: {line}")
sys.exit(1 if failures else 0)
PY

[[ "$FAILED" -eq 0 ]] || exit 1
printf 'PASS: SkyEyeWatchdog fires, routes first and is safe without deadman_url\n'
