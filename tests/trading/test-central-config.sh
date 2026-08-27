#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DASHBOARD="$REPO_ROOT/grafana/dashboards/Trading/tnauqquant-trading-overview.json"
DETAIL_DASHBOARD="$REPO_ROOT/grafana/dashboards/Trading/trading-strategy-detail.json"
FLEET_DASHBOARD="$REPO_ROOT/grafana/dashboards/Trading/trading-strategy-fleet.json"
PROM_RULES="$REPO_ROOT/prometheus/rules/trading.yml"
PROM_TARGET="$REPO_ROOT/prometheus/rules/trading-targets.yml"
LOKI_RULES="$REPO_ROOT/loki/rules/fake/tnauqquant.yml"

for required_file in \
  "$DASHBOARD" \
  "$DETAIL_DASHBOARD" \
  "$FLEET_DASHBOARD" \
  "$PROM_RULES" \
  "$PROM_TARGET" \
  "$LOKI_RULES"
do
  [[ -f "$required_file" ]] || {
    printf 'FAIL: missing central Trading config: %s\n' "$required_file" >&2
    exit 1
  }
done

jq empty "$DASHBOARD"
jq empty "$DETAIL_DASHBOARD"
jq empty "$FLEET_DASHBOARD"
jq -e '
  .uid == "tnauqquant-trading-overview" and
  .timezone == "Asia/Taipei" and
  .time.from == "now/d" and
  (.templating.list | length == 0) and
  (.panels | length == 6) and
  ([.panels[].id] | sort == [2, 40, 44, 45, 46, 47]) and
  ([.panels[].type] | sort == ["logs", "stat", "stat", "stat", "stat", "xychart"]) and
  ([.. | objects | select(.mode? == "fixedColor")] | length == 0) and
  ([.. | objects | select(.mode? == "fixed") |
    (has("fixedColor") and (.fixedColor | type) == "string" and (.fixedColor | length) > 0)
  ] | all) and
  ([.panels[] | select(.id == 2) |
    (.type == "xychart" and
     .pluginVersion == "11.2.0" and
     .options.mapping == "auto" and
     (.options | has("seriesMapping") | not) and
     (.options | has("dims") | not) and
     .options.series[0].name.fixed == "Completed cycles" and
     (.options.series[0] | keys == ["name"]) and
     .fieldConfig.defaults.custom.show == "points+lines" and
     .fieldConfig.defaults.custom.pointSize.fixed == 7 and
     .options.legend.showLegend == false and
     .targets[0].instant == true and
     .targets[0].range == false and
     .targets[0].format == "table" and
     (.targets[0].expr | contains("tnauqquant_cycle_cumulative_real_pnl_usdt")) and
     ([.transformations[].id] == ["organize", "convertFieldType", "sortBy"]) and
     .transformations[0].options.excludeByName == {} and
     .transformations[0].options.includeByName == {"Value": true, "cycle": true} and
     .transformations[0].options.indexByName == {
       "Value": 1,
       "cycle": 0
     } and
     .transformations[0].options.renameByName == {
       "Value": "Cumulative Real P&L",
       "cycle": "Cycle"
     } and
     .transformations[1].options.conversions[0].targetField == "Cycle" and
     .transformations[1].options.conversions[0].destinationType == "number" and
     .transformations[2].options.sort[0].field == "Cycle" and
     .transformations[2].options.sort[0].desc == false and
     (.description | contains("Prometheus table result supplies cycle and Value")) and
     (.description | contains("X is the completed session cycle")) and
     (.description | contains("Y is cumulative")))
  ] == [true]) and
  ([.panels[] | select(.id == 40) |
    (.type == "stat" and
     (.targets | length) == 7 and
     ([.targets[].legendFormat] == [
       "TOOBIT · LONG", "TOOBIT · SHORT", "TOOBIT · FLAT",
       "MEXC · LONG", "MEXC · SHORT", "MEXC · FLAT", "NET"
     ]) and
     (.targets[0:3] | map(.expr) | all(contains("exchange=\"toobit\""))) and
     (.targets[3:6] | map(.expr) | all(contains("exchange=\"mexc\""))) and
     (.targets[0:6] | map(.expr | capture("side=\\\"(?<side>long|short|flat)\\\"").side) ==
       ["long", "short", "flat", "long", "short", "flat"]) and
     ([.targets[1].expr, .targets[4].expr] | all(startswith("-sum("))) and
     (.targets[6].expr | contains("side=\"long\"") and contains("side=\"short\"")) and
     (.targets[6].expr | contains("exchange=\"toobit\"") | not) and
     (.targets[6].expr | contains("exchange=\"mexc\"") | not) and
     ([.fieldConfig.overrides[] |
       select(.matcher.options == "TOOBIT · LONG" or .matcher.options == "MEXC · LONG") |
       .properties[] | select(.id == "color") | .value.fixedColor
     ] == ["#73BF69", "#73BF69"]) and
     ([.fieldConfig.overrides[] |
       select(.matcher.options == "TOOBIT · SHORT" or .matcher.options == "MEXC · SHORT") |
       .properties[] | select(.id == "color") | .value.fixedColor
     ] == ["#F2495C", "#F2495C"]) and
     ([.fieldConfig.overrides[] | select(.matcher.options == "NET") |
       .properties[] | select(.id == "color") | .value.mode
     ] == ["thresholds"]) and
     ((.description | ascii_downcase) | contains("long is green")) and
     ((.description | ascii_downcase) | contains("short is red")))
  ] == [true]) and
  ([.panels[] | select(.id == 44) | .targets[].expr | contains("tnauqquant_log_mtime_seconds")] == [true, true]) and
  ([.panels[] | select(.id == 45) |
    (.type == "logs" and
     .datasource.type == "loki" and
     .targets[0].datasource.type == "loki" and
     .targets[0].maxLines == 5 and
     .targets[0].direction == "backward" and
     .options.sortOrder == "Descending")
  ] == [true]) and
  ([.panels[] | select(.id == 46) |
    (.type == "stat" and
     .gridPos.y == 16 and
     .gridPos.x == 16 and
     .fieldConfig.defaults.mappings[0].options["0"].text == "SHUTDOWN" and
     .fieldConfig.defaults.mappings[0].options["1"].text == "RUNNING" and
     (.targets[0].expr | contains("tnauqquant_process_count")) and
     (.targets[0].expr | contains("> bool 0")))
  ] == [true]) and
  ([.panels[] | select(.id == 47) |
    (.type == "stat" and
     .gridPos.y == 16 and
     .gridPos.x == 0 and
     .fieldConfig.defaults.unit == "currencyUSD" and
     (.targets | length) == 2 and
     ([.targets[].legendFormat] == ["TOOBIT VOLUME", "MEXC VOLUME"]) and
     ([.targets[].expr] | all(contains("tnauqquant_current_run_exchange_volume_usd"))) and
     (.targets[0].expr | contains("exchange=\"toobit\"")) and
     (.targets[1].expr | contains("exchange=\"mexc\"")) and
     ([.targets[].instant] == [true, true]) and
     ([.targets[].range] == [false, false]) and
     ((.description | ascii_downcase) | contains("current manifest-bound run")))
  ] == [true]) and
  ([.panels[].targets[].expr] | all(
    contains("environment=\"production\"") and
    contains("server_id=\"tnauqquant-prod-1\"") and
    contains("strategy=\"toobit-mexc-btc\"")
  )) and
  ([.panels[].targets[].expr] | all(
    (contains("tnauqquant_current_real_pnl_usdt") or
     contains("tnauqquant_last_cycle_real_pnl_usdt") or
     contains("tnauqquant_completed_cycles_today")) | not
  ))
' "$DASHBOARD" >/dev/null

jq -e '
  .uid == "trading-strategy-detail" and
  .timezone == "Asia/Taipei" and
  .refresh == "15s" and
  ([.templating.list[].name] == ["server_id", "strategy"]) and
  (.templating.list[0].definition | contains("trading_target_info")) and
  (.templating.list[1].definition |
    contains("trading_target_info") and contains("server_id=\"$server_id\"")) and
  ([.panels[].type] | index("xychart") != null) and
  ([.panels[].type] | index("logs") != null) and
  ([.panels[] | select(.type == "logs") |
    .datasource.uid == "loki" and
    (.targets[0].expr | contains("server_id=\"$server_id\"") and contains("strategy=\"$strategy\""))
  ] == [true]) and
  ([.panels[] | select(.title == "CURRENT RUN VOLUME · BY EXCHANGE") |
    (.targets | length == 1) and
    .targets[0].legendFormat == "{{exchange}} · VOLUME" and
    (.targets[0].expr | contains("trading_strategy_current_run_exchange_volume_usd"))
  ] == [true]) and
  ([.panels[] | select(.title == "PROCESS") |
    .fieldConfig.defaults.mappings[0].options["0"].text == "DOWN" and
    .fieldConfig.defaults.mappings[0].options["1"].text == "RUNNING"
  ] == [true]) and
  ([.panels[] | select(.title == "BINDING") |
    .fieldConfig.defaults.mappings[0].options["0"].text == "INVALID" and
    .fieldConfig.defaults.mappings[0].options["1"].text == "VALID"
  ] == [true]) and
  ([.. | objects | .datasource?.uid? | select(. != null)] |
    all(. == "prometheus" or . == "loki" or . == "alertmanager")) and
  ([.panels[].targets[].expr] |
    map(select(startswith("{") | not)) |
    all(contains("trading_strategy_"))) and
  ((tostring | contains("tnauqquant-prod-1")) | not) and
  ((tostring | contains("toobit-mexc-btc")) | not) and
  ((tostring | contains("trading01")) | not) and
  ((tostring | contains("lighter-robinhood-btc-canary")) | not)
' "$DETAIL_DASHBOARD" >/dev/null

jq -e '
  .uid == "trading-strategy-fleet" and
  .timezone == "Asia/Taipei" and
  .refresh == "15s" and
  (.templating.list | length == 0) and
  ([.panels[] | select(.type == "table")] | length == 1) and
  ([.panels[] | select(.type == "table") |
    (.targets[0].expr | contains("trading_target_info")) and
    ([.transformations[].id] == ["joinByField", "organize"]) and
    .transformations[0].options.byField == "strategy" and
    .transformations[0].options.mode == "outer" and
    (.fieldConfig.overrides | map(.matcher.options) |
      contains(["Process", "Binding", "Risk", "Telemetry"])) and
    ([.fieldConfig.overrides[].properties[]? |
      select(.id == "links") | .value[].url |
      contains("/d/trading-strategy-detail/") and
      contains("var-server_id=") and
      contains("var-strategy=")
    ] == [true])
  ] == [true]) and
  ([.panels[].targets[].expr] |
    map(select(contains("trading_strategy_current_real_pnl_usdt"))) |
    all((startswith("sum(") or startswith("sum by")) | not)) and
  ([.. | objects | .datasource?.uid? | select(. != null)] |
    all(. == "prometheus" or . == "loki" or . == "alertmanager")) and
  ((tostring | contains("tnauqquant-prod-1")) | not) and
  ((tostring | contains("toobit-mexc-btc")) | not) and
  ((tostring | contains("trading01")) | not) and
  ((tostring | contains("lighter-robinhood-btc-canary")) | not)
' "$FLEET_DASHBOARD" >/dev/null

if rg -q 'development|tnauqquant-dev-mac|mexc-toobit-btc' \
  "$DASHBOARD" "$PROM_RULES" "$PROM_TARGET" "$LOKI_RULES"
then
  printf 'FAIL: legacy development Trading target remains in central config\n' >&2
  exit 1
fi

for production_value in \
  production \
  tnauqquant-prod-1 \
  toobit-mexc-btc \
  trading01 \
  lighter-robinhood-btc-canary
do
  rg -q -- "$production_value" "$PROM_TARGET" || {
    printf 'FAIL: inventory is missing production identity %s\n' \
      "$production_value" >&2
    exit 1
  }
done

rg -q 'record:[[:space:]]+trading_target_info' "$PROM_TARGET" || {
  printf 'FAIL: generic trading_target_info inventory is missing\n' >&2
  exit 1
}

for recording_rule in \
  trading_strategy_process_count \
  trading_strategy_binding_ok \
  trading_strategy_current_real_pnl_usdt \
  trading_strategy_current_net_position_btc \
  trading_strategy_current_run_exchange_volume_usd \
  trading_strategy_risk_stopped
do
  rg -q -- "record:[[:space:]]+$recording_rule" "$PROM_RULES" || {
    printf 'FAIL: generic recording rule is missing: %s\n' "$recording_rule" >&2
    exit 1
  }
done

if rg -q 'tnauqquant-prod-1|toobit-mexc-btc|trading01|lighter-robinhood-btc-canary' \
  "$PROM_RULES" "$LOKI_RULES"
then
  printf 'FAIL: generic Trading rules still hard-code a server or strategy\n' >&2
  exit 1
fi

for generic_selector in 'product="tnauqquant"' 'environment="production"'; do
  rg -q -- "$generic_selector" "$PROM_RULES" || {
    printf 'FAIL: Prometheus rules are missing selector %s\n' "$generic_selector" >&2
    exit 1
  }
  rg -q -- "$generic_selector" "$LOKI_RULES" || {
    printf 'FAIL: Loki rules are missing selector %s\n' "$generic_selector" >&2
    exit 1
  }
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
