#!/usr/bin/env bash
set -euo pipefail

# Provisioning smoke test for the pinned Grafana image in docker-compose.yml.
# Runs a single throwaway container with --pull never --network none, no name,
# dummy credentials and no access to production. Bind-mounts
# grafana/provisioning:ro identically to docker-compose.yml (so missing
# provisioning subdirectories cannot be masked by image defaults) and copies
# grafana/dashboards via docker cp so synthetic refresh checks can run in the
# same container. Verifies health, clean startup logs (no errors, no background
# plugin preinstall, unified storage migration succeeded), exact dashboard/folder
# provisioning parity with central-deploy's comparable() rule, v2beta1 schema
# conversion, non-Angular/non-deprecated panel registry support, stable
# datasource UIDs and settings, home dashboard, and Grafana's refresh
# normalization contract.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FAILED=0
GRAFANA_ID=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok      %s\n' "$*"
}

record() {
  printf 'not ok  %s\n' "$*"
  FAILED=1
}

for tool in docker python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required; this suite must not pass by failing to run"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-grafana-prov.XXXXXX")"
cleanup() {
  [[ -z "$GRAFANA_ID" ]] || docker rm -f -v "$GRAFANA_ID" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

GF_ADMIN_PW=verify-placeholder docker compose --env-file /dev/null -p "skyeye-grafana-prov-$$" \
  --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" config --format json \
  >"$WORK/compose.json" || fail "docker compose config failed"

# Extract image, version tag, and compose environment; verify required 12.x flags.
python3 -I - "$WORK/compose.json" "$WORK" <<'PY' || FAILED=1
import json, os, re, sys

compose_path, work = sys.argv[1:3]
services = json.load(open(compose_path, encoding="utf-8"))["services"]
grafana = services["grafana"]
image = grafana["image"]
env = dict(grafana["environment"])
failed = False

def check(ok, message):
    global failed
    print(("ok      " if ok else "not ok  ") + message)
    failed = failed or not ok

match = re.fullmatch(r"grafana/grafana:([0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}", image)
check(match is not None, "grafana image is pinned by version tag and sha256 digest (%s)" % image)
version = match[1] if match else ""

check(env.get("GF_PLUGINS_PREINSTALL_DISABLED") == "true",
      "plugin preinstall is disabled in docker-compose.yml")
check(env.get("GF_UNIFIED_STORAGE_FOLDERS_FOLDER_GRAFANA_APP_ENABLEMIGRATION") == "true",
      "unified storage folder migration opt-in is enabled")
check(env.get("GF_UNIFIED_STORAGE_DASHBOARDS_DASHBOARD_GRAFANA_APP_ENABLEMIGRATION") == "true",
      "unified storage dashboard migration opt-in is enabled")

# Keep committed compose env; enable basic auth for local API reads and disable
# outbound network lookups that always fail under --network none.
live = dict(env)
live.update({
    "GF_AUTH_BASIC_ENABLED": "true",
    "GF_PLUGINS_PUBLIC_KEY_RETRIEVAL_DISABLED": "true",
    "GF_ANALYTICS_REPORTING_ENABLED": "false",
    "GF_ANALYTICS_CHECK_FOR_UPDATES": "false",
    "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES": "false",
    "GF_NEWS_NEWS_FEED_ENABLED": "false",
})
with open(os.path.join(work, "grafana.env"), "w", encoding="utf-8") as handle:
    for key, value in sorted(live.items()):
        if "\n" in str(value):
            sys.exit("FAIL: %s has a newline, which an env file cannot carry" % key)
        handle.write("%s=%s\n" % (key, value))

with open(os.path.join(work, "meta.json"), "w", encoding="utf-8") as handle:
    json.dump({"image": image, "version": version}, handle)

sys.exit(1 if failed else 0)
PY

[[ -s "$WORK/meta.json" ]] || fail "could not read grafana service from docker-compose.yml"
GRAFANA_IMAGE="$(jq -r .image "$WORK/meta.json")"
PINNED_VERSION="$(jq -r .version "$WORK/meta.json")"

docker image inspect "$GRAFANA_IMAGE" >/dev/null 2>&1 || \
  fail "$GRAFANA_IMAGE is not on this machine; run docker pull $GRAFANA_IMAGE (this suite never pulls)"

GRAFANA_ID="$(docker create --pull never --network none --env-file "$WORK/grafana.env" \
  -v "$REPO_ROOT/grafana/provisioning:/etc/grafana/provisioning:ro" "$GRAFANA_IMAGE")"
docker cp -q "$REPO_ROOT/grafana/dashboards/." "$GRAFANA_ID:/var/lib/grafana/dashboards"
docker start "$GRAFANA_ID" >/dev/null

ready=0
for _ in $(seq 1 120); do
  if docker exec "$GRAFANA_ID" curl -fsS -o /dev/null http://127.0.0.1:3000/api/health 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.5
done
[[ "$ready" -eq 1 ]] || fail "Grafana did not become healthy within 60s"

# Give background startup tasks a moment to settle before reading logs.
sleep 2

api_get() {
  local path="$1" out="$2"
  docker exec "$GRAFANA_ID" curl -fsS -u admin:verify-placeholder "http://127.0.0.1:3000$path" >"$out"
}

api_get /api/health "$WORK/health.json" || fail "GET /api/health failed"
api_get '/api/search?type=dash-db&limit=5000' "$WORK/search.json" || fail "GET /api/search failed"
api_get /api/frontend/settings "$WORK/settings.json" || fail "GET /api/frontend/settings failed"
api_get /api/datasources "$WORK/datasources.json" || fail "GET /api/datasources failed"
api_get /api/dashboards/home "$WORK/home.json" || fail "GET /api/dashboards/home failed"
docker logs "$GRAFANA_ID" >"$WORK/grafana.log" 2>&1

# Fetch each repo dashboard via both legacy API and v2beta1 conversion API.
mkdir -p "$WORK/live-dashboards" "$WORK/v2beta1"
while IFS= read -r uid; do
  [[ -n "$uid" ]] || continue
  api_get "/api/dashboards/uid/$uid" "$WORK/live-dashboards/$uid.json" || \
    record "GET /api/dashboards/uid/$uid failed"
  api_get "/apis/dashboard.grafana.app/v2beta1/namespaces/default/dashboards/$uid" "$WORK/v2beta1/$uid.json" || \
    record "GET v2beta1 conversion for $uid failed"
done < <(find "$REPO_ROOT/grafana/dashboards" -type f -name '*.json' -print0 | xargs -0 jq -r '.uid' | LC_ALL=C sort)

# Run core assertions in Python so every failure is reported clearly.
python3 -I - "$REPO_ROOT" "$WORK" "$PINNED_VERSION" <<'PY' || FAILED=1
import json, os, sys

repo_root, work, pinned_version = sys.argv[1:4]
failed = False

def check(ok, message):
    global failed
    print(("ok      " if ok else "not ok  ") + message)
    failed = failed or not ok

def comparable(dashboard):
    return {key: value for key, value in dashboard.items() if key not in ("id", "version")}

def collect_panel_types(panels, out):
    for panel in panels or []:
        if not isinstance(panel, dict):
            continue
        ptype = panel.get("type")
        if ptype:
            out.add(ptype)
        collect_panel_types(panel.get("panels"), out)

# 1. Health & version
health = json.load(open(os.path.join(work, "health.json"), encoding="utf-8"))
check(health.get("database") == "ok" and health.get("version") == pinned_version,
      "/api/health reports database=ok and version=%s (got database=%s version=%s)"
      % (pinned_version, health.get("database"), health.get("version")))

# 2. Startup logs
logs = open(os.path.join(work, "grafana.log"), encoding="utf-8", errors="replace").read().splitlines()
error_lines = [line for line in logs if "level=error" in line]
check(not error_lines,
      "startup logs contain zero level=error lines" + ("" if not error_lines else " (%d: %s)" % (len(error_lines), error_lines[0][:160])))
bg_installer = [line for line in logs if "plugin.backgroundinstaller" in line]
check(not bg_installer,
      "startup logs contain no plugin.backgroundinstaller activity (preinstall disabled)")
unified_ok = any(
    'msg="Migration successfully executed"' in line and 'id="folders and dashboards migration"' in line
    for line in logs
) and any('msg="Unified storage migrations completed successfully"' in line for line in logs)
check(unified_ok, "unified storage folders and dashboards migration completed cleanly")

# 3. Inventory repo dashboards
dash_root = os.path.join(repo_root, "grafana", "dashboards")
repo_dashboards = {}
for dirpath, _, filenames in os.walk(dash_root):
    for name in sorted(filenames):
        if not name.endswith(".json"):
            continue
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, dash_root).replace(os.sep, "/")
        folder = rel.split("/", 1)[0]
        body = json.load(open(full, encoding="utf-8"))
        uid = body["uid"]
        repo_dashboards[uid] = {"rel": rel, "folder": folder, "body": body}

check(len(repo_dashboards) > 0, "discovered %d repo dashboard JSON files" % len(repo_dashboards))

# 4. /api/search UIDs and folders
search = json.load(open(os.path.join(work, "search.json"), encoding="utf-8"))
served_by_uid = {item["uid"]: item for item in search}
check(sorted(served_by_uid) == sorted(repo_dashboards),
      "/api/search lists the exact %d repo dashboard UIDs" % len(repo_dashboards))

folder_mismatches = []
for uid, info in sorted(repo_dashboards.items()):
    got_folder = (served_by_uid.get(uid) or {}).get("folderTitle", "")
    if got_folder != info["folder"]:
        folder_mismatches.append("%s: got %r want %r" % (uid, got_folder, info["folder"]))
check(not folder_mismatches,
      "every dashboard sits in the folder matching its directory name"
      + ("" if not folder_mismatches else " (%s)" % "; ".join(folder_mismatches)))

# 5. /api/dashboards/uid/<uid> parity and provisionedExternalId
parity_errors = []
extid_errors = []
for uid, info in sorted(repo_dashboards.items()):
    live_path = os.path.join(work, "live-dashboards", uid + ".json")
    if not os.path.exists(live_path):
        parity_errors.append("%s missing live response" % uid)
        continue
    live = json.load(open(live_path, encoding="utf-8"))
    if comparable(live.get("dashboard", {})) != comparable(info["body"]):
        parity_errors.append("%s body differs from %s" % (uid, info["rel"]))
    got_ext = (live.get("meta") or {}).get("provisionedExternalId")
    if got_ext != info["rel"]:
        extid_errors.append("%s got %r want %r" % (uid, got_ext, info["rel"]))

check(not parity_errors,
      "every served dashboard matches its Git JSON minus id/version"
      + ("" if not parity_errors else " (%s)" % "; ".join(parity_errors)))
check(not extid_errors,
      "every served dashboard reports meta.provisionedExternalId matching its relative path"
      + ("" if not extid_errors else " (%s)" % "; ".join(extid_errors)))

# 6. v2beta1 schema conversion
v2_errors = []
for uid in sorted(repo_dashboards):
    v2_path = os.path.join(work, "v2beta1", uid + ".json")
    if not os.path.exists(v2_path):
        v2_errors.append("%s missing v2beta1 response" % uid)
        continue
    v2 = json.load(open(v2_path, encoding="utf-8"))
    conv = (v2.get("status") or {}).get("conversion") or {}
    if conv.get("failed") is not False:
        v2_errors.append("%s conversion=%r" % (uid, conv))
check(not v2_errors,
      "all %d dashboards convert cleanly via v2beta1 (status.conversion.failed == false)" % len(repo_dashboards)
      + ("" if not v2_errors else " (%s)" % "; ".join(v2_errors)))

# 7. Panel types in /api/frontend/settings registry (non-deprecated, non-angular)
settings = json.load(open(os.path.join(work, "settings.json"), encoding="utf-8"))
registry = settings.get("panels") or {}
used_types = set()
for info in repo_dashboards.values():
    collect_panel_types(info["body"].get("panels"), used_types)

# 'row' is a built-in dashboard layout container, not a panel plugin.
panel_errors = []
for ptype in sorted(used_types):
    if ptype == "row":
        continue
    entry = registry.get(ptype)
    if not entry:
        panel_errors.append("%s not in panel registry" % ptype)
        continue
    if entry.get("state") == "deprecated":
        panel_errors.append("%s is deprecated" % ptype)
    if (entry.get("angular") or {}).get("detected"):
        panel_errors.append("%s is marked angular" % ptype)
check(not panel_errors,
      "all used panel types (%s) are active React panels in the %s registry"
      % (", ".join(sorted(used_types)), pinned_version)
      + ("" if not panel_errors else " (%s)" % "; ".join(panel_errors)))

# 8. Datasources: assert the live provisioned API responses against the stable
# UID contract and explicit expected settings (Grafana already parses the
# bind-mounted grafana/provisioning/datasources/default.yml on startup).
STABLE_DS_UIDS = ["alertmanager", "loki", "prometheus"]
EXPECTED_DS = {
    "prometheus": {
        "uid": "prometheus",
        "name": "Prometheus",
        "type": "prometheus",
        "url": "http://prometheus:9090",
        "isDefault": True,
        "jsonData": {"timeInterval": "15s"},
    },
    "loki": {
        "uid": "loki",
        "name": "Loki",
        "type": "loki",
        "url": "http://loki:3100",
        "isDefault": False,
        "jsonData": {"maxLines": 1000},
    },
    "alertmanager": {
        "uid": "alertmanager",
        "name": "Alertmanager",
        "type": "alertmanager",
        "url": "http://alertmanager:9093",
        "isDefault": False,
        "jsonData": {
            "implementation": "prometheus",
            "handleGrafanaManagedAlerts": False,
        },
    },
}

live_ds = {d["uid"]: d for d in json.load(open(os.path.join(work, "datasources.json"), encoding="utf-8"))}
check(sorted(live_ds) == STABLE_DS_UIDS,
      "provisioned datasource UIDs match stable contract (%s; got %s)"
      % (", ".join(STABLE_DS_UIDS), ", ".join(sorted(live_ds))))

ds_diffs = []
for uid, want in sorted(EXPECTED_DS.items()):
    got = live_ds.get(uid) or {}
    for field in ("uid", "name", "type", "url", "isDefault", "jsonData"):
        if got.get(field) != want.get(field):
            ds_diffs.append("%s.%s: got %r want %r" % (uid, field, got.get(field), want.get(field)))
check(not ds_diffs,
      "all %d provisioned datasources match explicit contract" % len(EXPECTED_DS)
      + ("" if not ds_diffs else " (%s)" % "; ".join(ds_diffs)))

# 9. Default home dashboard
home = json.load(open(os.path.join(work, "home.json"), encoding="utf-8"))
home_uid = (home.get("dashboard") or {}).get("uid")
check(home_uid == "overview-all",
      "/api/dashboards/home serves overview-all (got %r)" % (home_uid,))

sys.exit(1 if failed else 0)
PY

# 10. central-deploy refresh contract (GRAFANA_MIN_REFRESH_SECONDS=5):
# Copy synthetic dashboards into a test-only folder, trigger reload, and verify
# refused refresh values are rewritten to "5s" while accepted ones stay intact.
mkdir -p "$WORK/refresh/_RefreshCheck"
python3 -I - "$WORK/refresh/_RefreshCheck" "$WORK/refresh-cases.json" <<'PY'
import json, os, sys

out_dir, cases_path = sys.argv[1:3]
rewritten = ["1s", "4s", "0s", "0m", "500ms", "1.5s", "30", "abc"]
kept = ["5s", "1m", "1h", "1d", "1w", "1M", "1y", "", "auto", False, True, None, 30]
cases = []
idx = 0
for val in rewritten:
    idx += 1
    uid = "refresh-rewrite-%d" % idx
    json.dump({"uid": uid, "title": "Refresh Rewrite %d" % idx, "refresh": val},
              open(os.path.join(out_dir, uid + ".json"), "w", encoding="utf-8"))
    cases.append({"uid": uid, "sent": val, "want": "5s", "kind": "rewrite"})
for val in kept:
    idx += 1
    uid = "refresh-keep-%d" % idx
    json.dump({"uid": uid, "title": "Refresh Keep %d" % idx, "refresh": val},
              open(os.path.join(out_dir, uid + ".json"), "w", encoding="utf-8"))
    cases.append({"uid": uid, "sent": val, "want": val, "kind": "keep"})
json.dump(cases, open(cases_path, "w", encoding="utf-8"))
PY

docker cp -q "$WORK/refresh/_RefreshCheck" "$GRAFANA_ID:/var/lib/grafana/dashboards/"
docker exec "$GRAFANA_ID" curl -fsS -u admin:verify-placeholder -X POST \
  http://127.0.0.1:3000/api/admin/provisioning/dashboards/reload >/dev/null

mkdir -p "$WORK/refresh-got"
while IFS= read -r uid; do
  api_get "/api/dashboards/uid/$uid" "$WORK/refresh-got/$uid.json" || \
    record "GET synthetic refresh dashboard $uid failed"
done < <(jq -r '.[].uid' "$WORK/refresh-cases.json")

python3 -I - "$WORK/refresh-cases.json" "$WORK/refresh-got" <<'PY' || FAILED=1
import json, os, sys

cases = json.load(open(sys.argv[1], encoding="utf-8"))
got_dir = sys.argv[2]
rewrite_bad, keep_bad = [], []
for case in cases:
    path = os.path.join(got_dir, case["uid"] + ".json")
    if not os.path.exists(path):
        (rewrite_bad if case["kind"] == "rewrite" else keep_bad).append("%s missing" % case["uid"])
        continue
    got = (json.load(open(path, encoding="utf-8")).get("dashboard") or {}).get("refresh")
    if got != case["want"] or type(got) is not type(case["want"]):
        msg = "sent=%r got=%r want=%r" % (case["sent"], got, case["want"])
        (rewrite_bad if case["kind"] == "rewrite" else keep_bad).append(msg)

failed = False
if not rewrite_bad:
    print("ok      Grafana rewrites all refused refresh values below 5s or unparseable to \"5s\"")
else:
    print("not ok  refresh rewrite mismatch: %s" % "; ".join(rewrite_bad))
    failed = True

if not keep_bad:
    print("ok      Grafana keeps all accepted refresh values unchanged")
else:
    print("not ok  refresh keep mismatch: %s" % "; ".join(keep_bad))
    failed = True

sys.exit(1 if failed else 0)
PY

if [[ "$FAILED" -ne 0 ]]; then
  printf 'FAIL: Grafana provisioning smoke test\n'
  exit 1
fi
printf 'PASS: Grafana %s provisions all repo dashboards and datasources cleanly\n' "$PINNED_VERSION"
