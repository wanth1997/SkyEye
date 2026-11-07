#!/usr/bin/env bash
set -euo pipefail

# Grafana must accept only identities that Cloudflare Access signed (P2-16).
# This runs the grafana service exactly as docker-compose.yml configures it on
# the pinned image, with one change: the key set URL points at a local HTTPS
# server that holds a key made for this run, because the real one belongs to
# Cloudflare. Tokens carry the committed aud and iss, so the claim checks that
# run here are the ones production runs.
#
# Every request comes from 127.0.0.1 inside the Grafana container, the source
# the old header whitelist trusted. Containers have no network, no name and no
# bind mount (a bind mount of $TMPDIR is empty on a Docker VM); files arrive by
# docker cp. Every check runs even after one fails.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FAILED=0
GRAFANA_ID=""
JWKS_ID=""

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

for tool in docker python3 openssl jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required; this suite must not pass by skipping"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-grafana-jwt.XXXXXX")"
cleanup() {
  local id
  for id in "$JWKS_ID" "$GRAFANA_ID"; do
    # -v: the Prometheus image declares a volume, which would outlive the container.
    [[ -z "$id" ]] || docker rm -f -v "$id" >/dev/null 2>&1 || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

GF_ADMIN_PW=verify-placeholder docker compose --env-file /dev/null -p "skyeye-grafana-jwt-$$" \
  --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" config --format json \
  >"$WORK/compose.json" || fail "docker compose config failed"

# Static checks on the committed environment, plus what the live part needs.
# The key set URL is the only value the live part replaces.
python3 -I - "$WORK/compose.json" "$WORK" <<'PY' || FAILED=1
import json, os, re, sys

compose, work = sys.argv[1:3]
services = json.load(open(compose, encoding="utf-8"))["services"]
env = dict(services["grafana"]["environment"])
failed = False

def check(ok, message):
    global failed
    print(("ok      " if ok else "not ok  ") + message)
    failed = failed or not ok

def setting(key):
    return env.get(key, "")

check(setting("GF_AUTH_PROXY_ENABLED") == "false", "auth proxy is disabled")
proxy_rest = sorted(k for k in env if k.startswith("GF_AUTH_PROXY_") and k != "GF_AUTH_PROXY_ENABLED")
check(not proxy_rest, "no auth proxy header or whitelist is configured (%s)" % (", ".join(proxy_rest) or "none"))
check(setting("GF_AUTH_JWT_ENABLED") == "true", "JWT auth is enabled")
check(setting("GF_AUTH_JWT_HEADER_NAME") == "Cf-Access-Jwt-Assertion", "the JWT is read from Cf-Access-Jwt-Assertion")
check(setting("GF_AUTH_JWT_EMAIL_CLAIM") == "email" and setting("GF_AUTH_JWT_USERNAME_CLAIM") == "email",
      "users are matched on the token's email claim")
check(not setting("GF_AUTH_JWT_JWK_SET_FILE") and not setting("GF_AUTH_JWT_KEY_FILE"),
      "keys come only from the key set URL")

try:
    claims = json.loads(setting("GF_AUTH_JWT_EXPECT_CLAIMS"))
except ValueError:
    claims = {}
iss, aud = claims.get("iss", ""), claims.get("aud", "")
check(sorted(claims) == ["aud", "iss"], "expected claims are exactly aud and iss")
check(re.fullmatch(r"https://[a-z0-9-]+\.cloudflareaccess\.com", iss or "") is not None,
      "iss is a Cloudflare Access team domain (%s)" % iss)
check(setting("GF_AUTH_JWT_JWK_SET_URL") == iss + "/cdn-cgi/access/certs",
      "the key set URL belongs to the same team as iss")
check(isinstance(aud, str) and re.fullmatch(r"[0-9a-f]{64}", aud) is not None,
      "aud is the Access application AUD tag, 64 hex characters (%s)" % aud)

ttl = re.fullmatch(r"(\d+)m", setting("GF_AUTH_JWT_CACHE_TTL"))
check(ttl is not None and 1 <= int(ttl[1]) <= 15,
      "the key cache expires within 15m, which bounds sign-in failures after a key rotation")
check(setting("GF_AUTH_JWT_AUTO_SIGN_UP") == "true", "new Access users get a Grafana account")
check(setting("GF_USERS_AUTO_ASSIGN_ORG_ROLE") == "Viewer", "a new account gets Viewer, not Admin")
check(setting("GF_AUTH_JWT_SKIP_ORG_ROLE_SYNC") == "true", "roles stay editable in Grafana (org role sync is off)")
check(not setting("GF_AUTH_JWT_ROLE_ATTRIBUTE_PATH"), "no role is taken from the token")
for key, why in (("GF_AUTH_JWT_URL_LOGIN", "no sign-in with a token in the URL"),
                 ("GF_AUTH_JWT_ENABLE_LOGIN_TOKEN", "no session cookie minted from a token"),
                 ("GF_AUTH_JWT_ALLOW_ASSIGN_GRAFANA_ADMIN", "no server admin granted by a token"),
                 ("GF_AUTH_JWT_TLS_SKIP_VERIFY_INSECURE", "the key set server's certificate is verified")):
    check(setting(key).lower() != "true", why)
check(setting("GF_AUTH_BASIC_ENABLED") == "false" and setting("GF_AUTH_DISABLE_LOGIN_FORM") == "true"
      and setting("GF_AUTH_ANONYMOUS_ENABLED") == "false", "no password or anonymous login")

# The live run: the committed environment, a local key set URL, the test CA.
live = dict(env)
live.update({
    "GF_AUTH_JWT_JWK_SET_URL": "https://localhost:9443/user/jwks.json",
    "SSL_CERT_FILE": "/etc/grafana/test-ca.pem",
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
with open(os.path.join(work, "claims.json"), "w", encoding="utf-8") as handle:
    json.dump({"aud": aud if isinstance(aud, str) else "", "iss": iss,
               "grafana": services["grafana"]["image"], "prometheus": services["prometheus"]["image"]}, handle)
sys.exit(1 if failed else 0)
PY
[[ -s "$WORK/claims.json" ]] || fail "could not read the grafana service from docker-compose.yml"

GRAFANA_IMAGE="$(jq -r .grafana "$WORK/claims.json")"
PROM_IMAGE="$(jq -r .prometheus "$WORK/claims.json")"
for image in "$GRAFANA_IMAGE" "$PROM_IMAGE"; do
  docker image inspect "$image" >/dev/null 2>&1 || \
    fail "$image is not on this machine; run docker pull $image (this suite never pulls)"
done

# Key material for this run only: a CA the test Grafana trusts, the key set
# server's certificate, the signing key the key set publishes, a second
# published key, and a key Grafana has never seen.
mkdir "$WORK/tls" "$WORK/keys" "$WORK/jwks" "$WORK/jwks/assets"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=skyeye-test-ca \
  -keyout "$WORK/tls/ca-key.pem" -out "$WORK/tls/ca.pem" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj /CN=localhost \
  -keyout "$WORK/jwks/server-key.pem" -out "$WORK/tls/server.csr" 2>/dev/null
printf 'subjectAltName=DNS:localhost\n' >"$WORK/tls/san.ext"
openssl x509 -req -days 1 -in "$WORK/tls/server.csr" -CA "$WORK/tls/ca.pem" -CAkey "$WORK/tls/ca-key.pem" \
  -CAcreateserial -extfile "$WORK/tls/san.ext" -out "$WORK/jwks/server.pem" 2>/dev/null
for key in signing published-spare foreign; do
  openssl genrsa -out "$WORK/keys/$key.pem" 2048 2>/dev/null
done
openssl req -x509 -new -days 1 -subj /CN=skyeye-test-signing -key "$WORK/keys/signing.pem" \
  -out "$WORK/keys/signing-cert.pem" 2>/dev/null
printf 'tls_server_config:\n  cert_file: /jwks/server.pem\n  key_file: /jwks/server-key.pem\n' >"$WORK/jwks/web.yml"

# The key set has Cloudflare's shape (keys plus public_cert and public_certs),
# and the tokens have the claims an Access application token carries.
python3 -I - "$WORK" <<'PY' || fail "cannot build the key set and tokens"
import base64, json, os, subprocess, sys, time, uuid

work = sys.argv[1]
claims = json.load(open(os.path.join(work, "claims.json"), encoding="utf-8"))

def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

def key_path(name):
    return os.path.join(work, "keys", name + ".pem")

def jwk(name, kid):
    out = subprocess.run(["openssl", "rsa", "-in", key_path(name), "-noout", "-modulus"],
                         capture_output=True, text=True, check=True).stdout
    modulus = bytes.fromhex(out.strip().split("=", 1)[1])
    return {"kid": kid, "kty": "RSA", "alg": "RS256", "use": "sig",
            "e": b64((65537).to_bytes(3, "big")), "n": b64(modulus)}

cert = open(key_path("signing-cert"), encoding="ascii").read()
keyset = {"keys": [jwk("signing", "kid-signing"), jwk("published-spare", "kid-spare")],
          "public_cert": {"kid": "kid-signing", "cert": cert},
          "public_certs": [{"kid": "kid-signing", "cert": cert}]}
with open(os.path.join(work, "jwks", "assets", "jwks.json"), "w", encoding="utf-8") as handle:
    json.dump(keyset, handle)

def sign(name, header, body):
    signing_input = ("%s.%s" % (b64(json.dumps(header).encode()), b64(json.dumps(body).encode()))).encode()
    signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path(name)],
                               input=signing_input, capture_output=True, check=True).stdout
    return "%s.%s" % (signing_input.decode(), b64(signature))

now = int(time.time())
def token(email, key="signing", aud=None, iss=None, exp=3600, extra=None, drop=()):
    body = {"aud": [claims["aud"] if aud is None else aud], "email": email, "exp": now + exp,
            "iat": now - 60, "nbf": now - 60, "iss": claims["iss"] if iss is None else iss,
            "type": "app", "identity_nonce": "test",
            "sub": str(uuid.uuid5(uuid.NAMESPACE_URL, "skyeye-test:" + email)), "country": "TW"}
    body.update(extra or {})
    for field in drop:
        body.pop(field, None)
    return sign(key, {"alg": "RS256", "kid": "kid-signing", "typ": "JWT"}, body)

unsigned = "%s.%s." % (b64(json.dumps({"alg": "none", "typ": "JWT"}).encode()),
                       b64(json.dumps({"aud": [claims["aud"]], "iss": claims["iss"], "exp": now + 3600,
                                       "email": "viewer@example.test"}).encode()))
tokens = {
    "viewer": token("viewer@example.test"),
    "admin": token("admin@localhost"),
    "wrong-aud": token("viewer@example.test", aud="aud-of-another-access-app"),
    "wrong-iss": token("viewer@example.test", iss="https://another-team.cloudflareaccess.com"),
    # Grafana allows 60s of clock skew; five minutes is well past it.
    "expired": token("viewer@example.test", exp=-300),
    "foreign-key": token("viewer@example.test", key="foreign"),
    "no-email": token("", extra={"common_name": "service-token.access"}, drop=("email",)),
    "unsigned": unsigned,
    "malformed": "not-a-jwt",
}
with open(os.path.join(work, "tokens.json"), "w", encoding="utf-8") as handle:
    json.dump(tokens, handle)
PY
# docker cp keeps modes, and the key set server runs as nobody.
chmod -R a+rX "$WORK/tls" "$WORK/jwks"

tok() {
  jq -r --arg name "$1" '.[$name]' "$WORK/tokens.json"
}

# req JWT_OR_EMPTY PATH [curl args...]: prints the status, then the body on the next line.
# It never fails: a request that does not get through prints status 000 and no body.
req() {
  local jwt="$1" path="$2"
  shift 2
  local args=(-sS -o /tmp/body -w '%{http_code}')
  [[ -z "$jwt" ]] || args+=(-H "Cf-Access-Jwt-Assertion: $jwt")
  docker exec "$GRAFANA_ID" sh -c \
    'rm -f /tmp/body; curl "$@" >/tmp/code; cat /tmp/code; echo; cat /tmp/body 2>/dev/null; true' \
    sh "${args[@]}" "$@" "http://127.0.0.1:3000$path" || true
}

# No pipes into head or tail here: with pipefail a closed pipe would be a failure.
status() {
  local response
  response="$(req "$@")"
  printf '%s\n' "${response%%$'\n'*}"
}

body() {
  local response
  response="$(req "$@")"
  printf '%s\n' "${response#*$'\n'}"
}

expect_status() { # expect_status WANT MESSAGE JWT PATH [curl args...]
  local want="$1" message="$2" got
  shift 2
  got="$(status "$@")"
  if [[ "$got" == "$want" ]]; then
    pass "$message"
  else
    record "$message: HTTP $got, want $want"
  fi
}

expect_json() { # expect_json JQ_TEST MESSAGE JWT PATH [curl args...]
  local filter="$1" message="$2" response
  shift 2
  response="$(req "$@")"
  if [[ "${response%%$'\n'*}" == 200 ]] && jq -e "$filter" >/dev/null 2>&1 <<<"${response#*$'\n'}"; then
    pass "$message"
  else
    record "$message: ${response//$'\n'/ }"
  fi
}

GRAFANA_ID="$(docker create --pull never --network none --env-file "$WORK/grafana.env" "$GRAFANA_IMAGE")"
docker cp -q "$WORK/tls/ca.pem" "$GRAFANA_ID:/etc/grafana/test-ca.pem"
docker cp -q "$REPO_ROOT/grafana/provisioning/." "$GRAFANA_ID:/etc/grafana/provisioning"
docker cp -q "$REPO_ROOT/grafana/dashboards/." "$GRAFANA_ID:/var/lib/grafana/dashboards"
docker start "$GRAFANA_ID" >/dev/null
for _ in $(seq 1 120); do
  docker exec "$GRAFANA_ID" curl -fsS -o /dev/null http://127.0.0.1:3000/api/health 2>/dev/null && break
  sleep 0.5
done

# Before the key set server exists: Grafana must start, then refuse.
expect_status 200 "Grafana starts while the key set URL is unreachable" "" /api/health
expect_status 401 "a valid token is refused while the key set cannot be fetched" "$(tok viewer)" /api/user

JWKS_ID="$(docker create --pull never --network "container:$GRAFANA_ID" "$PROM_IMAGE" \
  --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/tmp/prometheus \
  --web.listen-address=127.0.0.1:9443 --web.config.file=/jwks/web.yml --web.user-assets=/jwks/assets)"
docker cp -q "$WORK/jwks/." "$JWKS_ID:/jwks"
docker start "$JWKS_ID" >/dev/null
for _ in $(seq 1 40); do
  [[ "$(status "$(tok viewer)" /api/user)" == 200 ]] && break
  sleep 0.5
done

VIEWER="$(tok viewer)"
ADMIN="$(tok admin)"
expect_json '.email == "viewer@example.test"' "a valid Access token signs in" "$VIEWER" /api/user
expect_json 'map(select(.orgId == 1)) | .[0].role == "Viewer"' \
  "the account created from the token is Viewer" "$VIEWER" /api/user/orgs
expect_json '.isGrafanaAdmin == true and .id == 1' \
  "an existing admin signs in as the same account and keeps server admin" "$ADMIN" /api/user
expect_json 'map(select(.orgId == 1)) | .[0].role == "Admin"' "an existing admin keeps the Admin role" \
  "$ADMIN" /api/user/orgs

viewer_id="$(body "$VIEWER" /api/user | jq -r '.id // empty' 2>/dev/null || true)"
expect_json '.message != null' "an admin can change the role of a token account" "$ADMIN" \
  "/api/org/users/$viewer_id" -X PATCH -H 'Content-Type: application/json' -d '{"role":"Editor"}'
expect_json 'map(select(.orgId == 1)) | .[0].role == "Editor"' \
  "the role set in Grafana survives the next token request" "$VIEWER" /api/user/orgs

# The header the old auth proxy trusted, from the address it trusted most.
for email in admin@localhost viewer@example.test; do
  expect_status 401 "a forged Cf-Access-Authenticated-User-Email ($email) is refused" "" /api/user \
    -H "Cf-Access-Authenticated-User-Email: $email"
done
expect_status 401 "a request with no credentials is refused" "" /api/user
for case in wrong-aud wrong-iss expired foreign-key no-email unsigned malformed; do
  expect_status 401 "a token that is $case is refused" "$(tok "$case")" /api/user
done

# central-deploy reads dashboards back with a Viewer service account token.
sa_id="$(body "$ADMIN" /api/serviceaccounts -X POST -H 'Content-Type: application/json' \
  -d '{"name":"central-deploy","role":"Viewer"}' | jq -r '.id // empty' 2>/dev/null || true)"
if [[ -n "$sa_id" ]]; then
  body "$ADMIN" "/api/serviceaccounts/$sa_id/tokens" -X POST -H 'Content-Type: application/json' \
    -d '{"name":"test"}' | jq -r '"header = \"Authorization: Bearer \(.key)\""' >"$WORK/sa.cfg" || true
  chmod a+r "$WORK/sa.cfg" # curl in the container runs as the grafana user
  docker cp -q "$WORK/sa.cfg" "$GRAFANA_ID:/tmp/sa.cfg"
  search="$(docker exec "$GRAFANA_ID" curl -fsS --config /tmp/sa.cfg \
    'http://127.0.0.1:3000/api/search?type=dash-db&limit=1' 2>&1 || true)"
  uid="$(jq -r '.[0].uid // empty' <<<"$search" 2>/dev/null || true)"
  if [[ -n "$uid" ]]; then
    pass "a Viewer service account token lists provisioned dashboards"
    if docker exec "$GRAFANA_ID" curl -fsS --config /tmp/sa.cfg "http://127.0.0.1:3000/api/dashboards/uid/$uid" |
      jq -e '.meta.provisionedExternalId | length > 0' >/dev/null 2>&1; then
      pass "a Viewer service account token reads the provisioning source of a dashboard"
    else
      record "a Viewer service account token cannot read meta.provisionedExternalId of $uid"
    fi
  else
    record "a Viewer service account token lists no dashboards: ${search:0:200}"
  fi
else
  record "the admin could not create a Viewer service account"
fi

if [[ "$FAILED" -ne 0 ]]; then
  printf 'FAIL: Grafana Cloudflare Access JWT sign-in\n'
  exit 1
fi
printf 'PASS: Grafana accepts only Cloudflare Access tokens for this application\n'
