#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DASHBOARD="$REPO_ROOT/grafana/dashboards/Trading/tnauqquant-trading-overview.json"
PROM_RULES="$REPO_ROOT/prometheus/rules/trading.yml"
PROM_TARGET="$REPO_ROOT/prometheus/rules/trading-targets.yml"
LOKI_RULES="$REPO_ROOT/loki/rules/fake/tnauqquant.yml"

for required_file in "$DASHBOARD" "$PROM_RULES" "$PROM_TARGET" "$LOKI_RULES"; do
  [[ -f "$required_file" ]] || {
    printf 'FAIL: missing central Trading config: %s\n' "$required_file" >&2
    exit 1
  }
done

jq empty "$DASHBOARD"
jq -e '
  .uid == "tnauqquant-trading-overview" and
  .timezone == "Asia/Taipei" and
  .time.from == "now/d" and
  ([.templating.list[] | select(.name == "environment") | .current.value] == ["production"]) and
  ([.templating.list[] | select(.name == "server_id") | .current.value] == ["tnauqquant-prod-1"]) and
  ([.templating.list[] | select(.name == "strategy") | .current.value] == ["toobit-mexc-btc"]) and
  ([.panels[] | select(.id == 2) | .targets[].expr | contains("tnauqquant_current_real_pnl_usdt")] == [true]) and
  ([.panels[] | select(.id == 31) | .targets[].expr | contains("tnauqquant_completed_cycles_today")] == [true]) and
  ([.panels[] | select(.id == 33) | .targets[].expr | contains("tnauqquant_last_completed_cycle_timestamp_seconds")] == [true]) and
  ([.panels[] | select(.id == 34) | .targets[].expr | contains("tnauqquant_current_run_info")] == [true]) and
  ([.panels[] | select(.id == 35) | .targets[].expr | contains("cycle_completed=\"true\"")] == [true])
' "$DASHBOARD" >/dev/null

if rg -q 'development|tnauqquant-dev-mac|mexc-toobit-btc' \
  "$DASHBOARD" "$PROM_RULES" "$PROM_TARGET" "$LOKI_RULES"
then
  printf 'FAIL: legacy development Trading target remains in central config\n' >&2
  exit 1
fi

for production_value in production tnauqquant-prod-1 toobit-mexc-btc; do
  for target_file in "$PROM_RULES" "$PROM_TARGET" "$LOKI_RULES"; do
    rg -q -- "$production_value" "$target_file" || {
      printf 'FAIL: %s is missing production identity %s\n' \
        "$target_file" "$production_value" >&2
      exit 1
    }
  done
done

prom_alert_count="$(rg -c '^[[:space:]]+- alert: Trading' "$PROM_RULES")"
prom_shadow_count="$(rg -c '^[[:space:]]+notification_mode: shadow' "$PROM_RULES")"
loki_alert_count="$(rg -c '^[[:space:]]+- alert: Trading' "$LOKI_RULES")"
loki_shadow_count="$(rg -c '^[[:space:]]+notification_mode: shadow' "$LOKI_RULES")"
if [[ "$prom_alert_count" != "$prom_shadow_count" ||
      "$loki_alert_count" != "$loki_shadow_count" ]]
then
  printf 'FAIL: every Trading alert must remain shadow-only during rollout\n' >&2
  exit 1
fi

printf 'PASS: central Trading production target and dashboard contract\n'
