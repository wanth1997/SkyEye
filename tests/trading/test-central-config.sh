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

jq -e '
  .uid == "tnauqquant-trading-overview" and
  .title == "Trading · 即時營運" and
  .editable == false and
  ([.panels[].title] | contains([
    "跨輪累積實現損益 · 近 30 日",
    "損益摘要",
    "監控摘要",
    "目前持倉 · 多空方向",
    "最新 5 筆策略日誌",
    "本輪成交額 · 依交易所",
    "資料涵蓋範圍"
  ])) and
  ([.panels[] | select(.title == "損益摘要") | .targets[].expr] |
    any(contains("tnauqquant_pnl_history_current_value_usdt"))) and
  ([.panels[] | select(.title == "最新 5 筆策略日誌") | .timeFrom] == ["6h"]) and
  ([.links[].url] | any(contains("trading-strategy-fleet")))
' "$DASHBOARD" >/dev/null

jq -e '
  .uid == "trading-strategy-detail" and
  .title == "Trading · 策略詳情" and
  .editable == false and
  ([.templating.list[].name] == ["server_id", "strategy"]) and
  ([.templating.list[].label] == ["伺服器", "策略"]) and
  ([.panels[].title] | contains([
    "本輪實現損益",
    "最近完成週期",
    "已完成週期",
    "監控摘要",
    "本輪實現損益 · 週期走勢",
    "目前持倉 · 多空方向",
    "損益組成",
    "本輪成交額 · 依交易所",
    "最新策略日誌 · 已去識別"
  ])) and
  ([.panels[] | select(.title == "監控摘要") | .targets[].legendFormat] ==
    ["程序", "資料綁定", "風控狀態", "資料更新"]) and
  ([.panels[] | select(.title == "監控摘要") |
    [.fieldConfig.overrides[] |
      select(any(.properties[]; .id == "noValue")) |
      .matcher.options]
  ] == [["程序", "資料綁定", "風控狀態", "資料更新"]]) and
  ([.panels[] | select(.title == "監控摘要") |
    .fieldConfig.overrides[] |
    select(.matcher.options == "程序") |
    .properties[] | select(.id == "mappings") | .value[] |
    select(.type == "range") | (.options.from == 2 and .options.to > 1000)
  ] == [true])
' "$DETAIL_DASHBOARD" >/dev/null

jq -e '
  .uid == "trading-strategy-fleet" and
  .title == "Trading · 策略總覽" and
  .editable == false and
  (.panels | length == 2) and
  ([.panels[].title] == ["監控摘要", "策略損益與運行狀態 · 點選策略查看詳情"]) and
  ([.panels[] | select(.title == "監控摘要") | .targets[].legendFormat] ==
    ["監控策略", "資料過期", "程序異常", "SHADOW 告警"]) and
  ([.panels[] | select(.title == "監控摘要") | .targets[].expr] |
    any(contains("trading_target_info") and contains("unless on") and contains("< 180"))) and
  ([.panels[] | select(.type == "table") | .targets[].expr] |
    any(contains("ALERTS") and contains("pending|firing") and contains("count by (strategy)"))) and
  ([.panels[] | select(.type == "table") |
    [.fieldConfig.overrides[].properties[]? |
      select(.id == "displayName") | .value]] |
    any(contains(["告警", "本輪實現損益", "資料更新"])))
' "$FLEET_DASHBOARD" >/dev/null

jq empty "$DASHBOARD"
jq empty "$DETAIL_DASHBOARD"
jq empty "$FLEET_DASHBOARD"
jq -e '
  .uid == "tnauqquant-trading-overview" and
  .timezone == "Asia/Taipei" and
  .time.from == "now-30d" and
  (.templating.list | length == 0) and
  (.panels | length == 7) and
  ([.panels[].id] | sort == [2, 40, 45, 47, 48, 49, 50]) and
  ([.panels[].type] | sort == ["logs", "stat", "stat", "stat", "stat", "stat", "timeseries"]) and
  ([.. | objects | select(.mode? == "fixedColor")] | length == 0) and
  ([.. | objects | select(.mode? == "fixed") |
    (has("fixedColor") and (.fixedColor | type) == "string" and (.fixedColor | length) > 0)
  ] | all) and
  ([.panels[] | select(.id == 2) |
    (.type == "timeseries" and
     .pluginVersion == "11.2.0" and
     .fieldConfig.defaults.custom.drawStyle == "line" and
     .fieldConfig.defaults.custom.lineInterpolation == "stepAfter" and
     .fieldConfig.defaults.custom.showPoints == "always" and
     .options.legend.showLegend == false and
     (.targets | length) == 2 and
     ([.targets[].instant] == [true, true]) and
     ([.targets[].range] == [false, false]) and
     ([.targets[].format] == ["table", "table"]) and
     (.targets[0].expr | contains("tnauqquant_pnl_history_point_value_usdt")) and
     (.targets[1].expr | contains("tnauqquant_pnl_history_point_timestamp_seconds")) and
     (.targets[1].expr | endswith(" * 1000")) and
     ([.transformations[].id] == ["joinByField", "organize", "convertFieldType", "sortBy"]) and
     .transformations[0].options == {"byField": "point", "mode": "outer"} and
     .transformations[1].options.includeByName == {"Value #A": true, "Value #B": true} and
     .transformations[1].options.indexByName == {
       "Value #A": 1,
       "Value #B": 0
     } and
     .transformations[1].options.renameByName == {
       "Value #A": "Accumulated Real P&L",
       "Value #B": "Time"
     } and
     .transformations[2].options.conversions[0].targetField == "Time" and
     .transformations[2].options.conversions[0].destinationType == "time" and
     .transformations[3].options.sort[0].field == "Time" and
     .transformations[3].options.sort[0].desc == false and
     ([.targets[].expr] | all(
       (contains("tnauqquant_current_real_pnl_usdt") or
        contains("tnauqquant_last_cycle_real_pnl_usdt") or
        contains("tnauqquant_cycle_cumulative_real_pnl_usdt")) | not
     )))
  ] == [true]) and
  ([.panels[] | select(.id == 40) |
    (.type == "stat" and
     (.targets | length) == 7 and
     ([.targets[].legendFormat] == [
       "TOOBIT · 多", "TOOBIT · 空", "TOOBIT · 空倉",
       "MEXC · 多", "MEXC · 空", "MEXC · 空倉", "淨部位"
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
       select(.matcher.options == "TOOBIT · 多" or .matcher.options == "MEXC · 多") |
       .properties[] | select(.id == "color") | .value.fixedColor
     ] == ["#73BF69", "#73BF69"]) and
     ([.fieldConfig.overrides[] |
       select(.matcher.options == "TOOBIT · 空" or .matcher.options == "MEXC · 空") |
       .properties[] | select(.id == "color") | .value.fixedColor
     ] == ["#F2495C", "#F2495C"]) and
     ([.fieldConfig.overrides[] | select(.matcher.options == "淨部位") |
       .properties[] | select(.id == "color") | .value.mode
     ] == ["thresholds"]))
  ] == [true]) and
  ([.panels[] | select(.id == 45) |
    (.type == "logs" and
     .datasource.type == "loki" and
     .targets[0].datasource.type == "loki" and
     .targets[0].maxLines == 5 and
     .targets[0].direction == "backward" and
     .options.sortOrder == "Descending" and
     .timeFrom == "6h")
  ] == [true]) and
  ([.panels[] | select(.id == 49) |
    (.type == "stat" and
     .fieldConfig.defaults.unit == "suffix: USDT" and
     ([.targets[].legendFormat] == ["跨輪累積", "本輪", "最近週期"]) and
     (.targets[0].expr | contains("tnauqquant_pnl_history_current_value_usdt")) and
     (.targets[1].expr | contains("tnauqquant_current_real_pnl_usdt")) and
     (.targets[2].expr | contains("tnauqquant_last_cycle_real_pnl_usdt")))
  ] == [true]) and
  ([.panels[] | select(.id == 50) |
    (.type == "stat" and
     ([.targets[].legendFormat] == ["程序", "資料綁定", "風控狀態", "資料更新", "歷史更新"]) and
     (.targets[0].expr | contains("trading_strategy_process_count") and
       (contains("> bool 0") | not)) and
     ([.fieldConfig.overrides[] |
       select(any(.properties[]; .id == "noValue")) | .matcher.options] ==
       ["程序", "資料綁定", "風控狀態", "資料更新", "歷史更新"]) and
     ([.fieldConfig.overrides[] | select(.matcher.options == "程序") |
       .properties[] | select(.id == "mappings") | .value[] |
       select(.type == "range") | (.options.from == 2 and .options.to > 1000)] == [true]))
  ] == [true]) and
  ([.panels[] | select(.id == 47) |
    (.type == "stat" and
     .gridPos.y == 17 and
     .gridPos.x == 0 and
     .gridPos.w == 8 and
     .fieldConfig.defaults.unit == "currencyUSD" and
     (.targets | length) == 2 and
     ([.targets[].legendFormat] == ["TOOBIT 成交額", "MEXC 成交額"]) and
     ([.targets[].expr] | all(contains("tnauqquant_current_run_exchange_volume_usd"))) and
     (.targets[0].expr | contains("exchange=\"toobit\"")) and
     (.targets[1].expr | contains("exchange=\"mexc\"")) and
     ([.targets[].instant] == [true, true]) and
     ([.targets[].range] == [false, false]))
  ] == [true]) and
  ([.panels[] | select(.id == 48) |
    (.type == "stat" and
     .gridPos.y == 17 and
     .gridPos.x == 8 and
     .gridPos.w == 16 and
     ([.targets[].legendFormat] == ["更新秒數", "資料起點", "排除舊資料"]) and
     (.targets[0].expr | contains("tnauqquant_pnl_history_build_timestamp_seconds")) and
     (.targets[1].expr | contains("tnauqquant_pnl_history_first_supported_event_timestamp_seconds")) and
     (.targets[2].expr | contains("tnauqquant_pnl_history_skipped_legacy_events")) and
     ([.targets[].instant] == [true, true, true]) and
     ([.targets[].range] == [false, false, false]))
  ] == [true]) and
  ([.panels[].targets[].expr] | all(
    contains("environment=\"production\"") and
    contains("server_id=\"tnauqquant-prod-1\"") and
    contains("strategy=\"toobit-mexc-btc\"")
  )) and
  ([.panels[].targets[].expr] | all(contains("tnauqquant_cycle_cumulative_real_pnl_usdt") | not))
' "$DASHBOARD" >/dev/null

jq -e '
  .uid == "trading-strategy-detail" and
  .timezone == "Asia/Taipei" and
  .refresh == "15s" and
  .editable == false and
  (.panels | length == 9) and
  ([.templating.list[].name] == ["server_id", "strategy"]) and
  ([.templating.list[].label] == ["伺服器", "策略"]) and
  (.templating.list[0].definition | contains("trading_target_info")) and
  (.templating.list[1].definition |
    contains("trading_target_info") and contains("server_id=\"$server_id\"")) and
  ([.panels[].type] | index("xychart") != null) and
  ([.panels[].type] | index("logs") != null) and
  ([.panels[] | select(.type == "logs") |
    .datasource.uid == "loki" and
    (.targets[0].expr | contains("server_id=\"$server_id\"") and contains("strategy=\"$strategy\""))
  ] == [true]) and
  ([.panels[] | select(.title == "本輪成交額 · 依交易所") |
    (.targets | length == 1) and
    .targets[0].legendFormat == "{{exchange}} · 成交額" and
    (.targets[0].expr | contains("trading_strategy_current_run_exchange_volume_usd"))
  ] == [true]) and
  ([.panels[] | select(.title == "監控摘要") |
    ([.targets[].legendFormat] == ["程序", "資料綁定", "風控狀態", "資料更新"]) and
    (.targets[0].expr | contains("trading_strategy_process_count") and
      (contains("> bool 0") | not)) and
    ([.fieldConfig.overrides[] |
      select(any(.properties[]; .id == "noValue")) | .matcher.options] ==
      ["程序", "資料綁定", "風控狀態", "資料更新"])
  ] == [true]) and
  ([.panels[] | select(.title == "本輪實現損益" or .title == "損益組成") |
    .fieldConfig.defaults.unit] | all(. == "suffix: USDT")) and
  ([.panels[] | select(.title == "本輪實現損益 · 週期走勢") |
    .fieldConfig.overrides[].properties[] | select(.id == "unit") | .value] == ["suffix: USDT"]) and
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
  .editable == false and
  (.templating.list | length == 0) and
  (.panels | length == 2) and
  ([.panels[] | select(.title == "監控摘要") |
    .gridPos == {h: 3, w: 24, x: 0, y: 0} and
    ([.targets[].legendFormat] == ["監控策略", "資料過期", "程序異常", "SHADOW 告警"]) and
    (.targets[1].expr | contains("trading_target_info") and contains("unless on") and contains("< 180")) and
    (.targets[2].expr | contains("trading_strategy_run_expected") and contains("!= bool")) and
    (.targets[3].expr | contains("pending|firing")) and
    ([.fieldConfig.overrides[] | select(.matcher.options != "監控策略") |
      .properties[] | select(.id == "thresholds") | .value.steps[1].value] == [1, 1, 1])
  ] == [true]) and
  ([.panels[] | select(.type == "table")] | length == 1) and
  ([.panels[] | select(.type == "table") |
    (.targets[0].expr | contains("trading_target_info")) and
    ([.transformations[].id] == ["joinByField", "organize"]) and
    .transformations[0].options.byField == "strategy" and
    .transformations[0].options.mode == "outer" and
    (.fieldConfig.overrides | map(.matcher.options) |
      contains(["Process", "Binding", "Risk", "Telemetry", "Alerts"])) and
    (.targets[5].expr | contains("trading_strategy_process_count") and
      (contains("> bool 0") | not)) and
    (.targets[7].expr | contains("< bool 180")) and
    (.targets[11].expr |
      contains("count by (strategy)") and
      contains("pending|firing") and
      contains("0 * max by (strategy) (trading_target_info")) and
    ([.fieldConfig.overrides[] | select(.matcher.options == "Process") |
      .properties[] | select(.id == "mappings") | .value[] |
      select(.type == "range") | (.options.from == 2 and .options.to > 1000)] == [true]) and
    ([.fieldConfig.overrides[].properties[]? |
      select(.id == "displayName") | .value] |
      contains(["策略", "伺服器", "本輪實現損益", "最近週期損益", "程序", "資料綁定", "風控狀態", "資料更新", "告警"])) and
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

rg -q 'history_capable:[[:space:]]+"true"' "$PROM_TARGET" || {
  printf 'FAIL: history-capable Trading inventory contract is missing\n' >&2
  exit 1
}
rg -q 'alert:[[:space:]]+TradingPnlHistoryUnavailable' "$PROM_RULES" || {
  printf 'FAIL: P&L history health alert is missing\n' >&2
  exit 1
}
rg -U -q 'tnauqquant_probe_timestamp_seconds\{[^}]*\}[[:space:]]*< 180' "$PROM_RULES" || {
  printf 'FAIL: Trading telemetry freshness threshold must be 180 seconds\n' >&2
  exit 1
}

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
