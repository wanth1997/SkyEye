#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$REPO_ROOT/tests/fixtures/tnauqquant/trading-incident.raw.log"
CHECKSUM="$FIXTURE.sha256"

for required_file in "$FIXTURE" "$CHECKSUM"; do
  [[ -f "$required_file" ]] || {
    printf 'FAIL: missing incident taxonomy fixture: %s\n' "$required_file" >&2
    exit 1
  }
done

expected_checksum="$(awk '{print $1}' "$CHECKSUM")"
actual_checksum="$(shasum -a 256 "$FIXTURE" | awk '{print $1}')"
[[ "$actual_checksum" == "$expected_checksum" ]] || {
  printf 'FAIL: incident fixture checksum mismatch\n' >&2
  exit 1
}

incident_messages=(
  coordinator_fence_stalled
  mexcui_recovery_required
  mexcui_recovery_required_refusing_normal_startup
  shutdown_with_unconsumed_continuation
  coordinated_shutdown_preserved_unresolved_fence
)
incident_regex="msg=($(IFS='|'; printf '%s' "${incident_messages[*]}"))([[:space:]]|$)"

for message in "${incident_messages[@]}"; do
  [[ "$(rg -c -- "msg=$message([[:space:]]|$)" "$FIXTURE")" == "1" ]] || {
    printf 'FAIL: incident fixture must contain exactly one %s event\n' "$message" >&2
    exit 1
  }
done

[[ "$(rg -c -- "$incident_regex" "$FIXTURE")" == "5" ]] || {
  printf 'FAIL: incident allowlist must classify exactly five fixture events\n' >&2
  exit 1
}

normal_unresolved="$(rg 'disposition=unresolved.*ui_submission_status=accepted' "$FIXTURE")"
[[ -n "$normal_unresolved" ]] || {
  printf 'FAIL: fixture must preserve the normal unresolved submission case\n' >&2
  exit 1
}
if printf '%s\n' "$normal_unresolved" | rg -q -- "$incident_regex"; then
  printf 'FAIL: accepted unresolved submissions must not be classified as incidents\n' >&2
  exit 1
fi

[[ "$(rg -c 'level=ERROR[+]4([[:space:]]|$)' "$FIXTURE")" == "1" ]] || {
  printf 'FAIL: fixture must cover extended ERROR+N severity\n' >&2
  exit 1
}

generic_errors="$({
  rg 'level=(ERROR([+][0-9]+)?|FATAL([+][0-9]+)?)([[:space:]]|$)' "$FIXTURE" || true
} | rg -v -- "$incident_regex" || true)"
[[ "$(printf '%s\n' "$generic_errors" | rg -c 'msg=unrelated_fixture_error')" == "1" ]] || {
  printf 'FAIL: generic ERROR fallback must retain unrelated errors\n' >&2
  exit 1
}
if printf '%s\n' "$generic_errors" | rg -q -- "$incident_regex"; then
  printf 'FAIL: allowlisted incidents must be excluded from the generic ERROR fallback\n' >&2
  exit 1
fi

for sensitive_field in grant_id mutation_id mutations account; do
  rg -q -- "${sensitive_field}=" "$FIXTURE" || {
    printf 'FAIL: fixture does not exercise scrub field %s\n' "$sensitive_field" >&2
    exit 1
  }
done

printf 'PASS: trading incident taxonomy fixture contract\n'
