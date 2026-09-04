#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REMOVED_DASHBOARD="$REPO_ROOT/grafana/dashboards/Trading/tnauqquant-trading-overview.json"
DETAIL_DASHBOARD="$REPO_ROOT/grafana/dashboards/Trading/trading-strategy-detail.json"
FLEET_DASHBOARD="$REPO_ROOT/grafana/dashboards/Trading/trading-strategy-fleet.json"
PROM_RULES="$REPO_ROOT/prometheus/rules/trading.yml"
PROM_TARGET="$REPO_ROOT/prometheus/rules/trading-targets.yml"
LOKI_RULES="$REPO_ROOT/loki/rules/fake/tnauqquant.yml"
INCIDENT_FIXTURE="$REPO_ROOT/tests/fixtures/tnauqquant/trading-incident.raw.log"
INCIDENT_TEST="$REPO_ROOT/tests/trading/test-incident-taxonomy.sh"

for required_file in \
  "$DETAIL_DASHBOARD" \
  "$FLEET_DASHBOARD" \
  "$PROM_RULES" \
  "$PROM_TARGET" \
  "$LOKI_RULES" \
  "$INCIDENT_FIXTURE" \
  "$INCIDENT_TEST"
do
  [[ -f "$required_file" ]] || {
    printf 'FAIL: missing central Trading config: %s\n' "$required_file" >&2
    exit 1
  }
done

jq -e '
  .uid == "trading-strategy-detail" and
  .title == "Trading · 策略詳情" and
  .editable == false and
  ([.templating.list[].name] == ["server_id", "strategy"]) and
  ([.templating.list[].label] == ["伺服器", "策略"]) and
  ([.panels[].title] | contains([
    "執行事故 · 最近 15 分鐘",
    "本輪實現損益",
    "最近完成週期",
    "已完成週期",
    "監控摘要",
    "本輪實現損益 · 週期走勢",
    "目前持倉 · 多空方向",
    "損益組成",
    "本輪成交額 · 依交易所",
    "關鍵執行事件 · 近 6 小時",
    "最新策略日誌 · 已去識別"
  ])) and
  ([.panels[] | select(.title == "監控摘要") | .targets[].legendFormat] ==
    ["程序", "Runtime Contract", "執行綁定", "Config 快照", "風控回報", "資料更新"]) and
  ([.panels[] | select(.title == "監控摘要") |
    [.fieldConfig.overrides[] |
      select(any(.properties[]; .id == "noValue")) |
      .matcher.options]
  ] == [["程序", "Runtime Contract", "執行綁定", "Config 快照", "風控回報", "資料更新"]]) and
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
  (.panels | length == 3) and
  ([.panels[].title] == ["執行事故 · 15 分鐘", "監控摘要", "策略損益與運行狀態 · 點選策略查看詳情"]) and
  ([.panels[] | select(.title == "監控摘要") | .targets[].legendFormat] ==
    ["監控策略", "資料過期", "程序異常", "Runtime 缺失", "Prometheus SHADOW"]) and
  ([.panels[] | select(.title == "監控摘要") | .targets[].expr] |
    any(contains("trading_target_info") and contains("unless on") and contains("< 180"))) and
  ([.panels[] | select(.type == "table") | .targets[].expr] |
    any(contains("ALERTS") and contains("pending|firing") and contains("count by (strategy)"))) and
  ([.panels[] | select(.type == "table") |
    [.fieldConfig.overrides[].properties[]? |
      select(.id == "displayName") | .value]] |
    any(contains(["告警", "本輪實現損益", "資料更新"])))
' "$FLEET_DASHBOARD" >/dev/null

if [[ -e "$REMOVED_DASHBOARD" ]]; then
  printf 'FAIL: removed Trading immediate-operations dashboard still exists\n' >&2
  exit 1
fi
if rg -q 'tnauqquant-trading-overview|Trading · 即時營運' "$REPO_ROOT/grafana/dashboards"; then
  printf 'FAIL: removed Trading dashboard identity remains in provisioning sources\n' >&2
  exit 1
fi

jq empty "$DETAIL_DASHBOARD"
jq empty "$FLEET_DASHBOARD"
for dashboard_file in "$DETAIL_DASHBOARD" "$FLEET_DASHBOARD"; do
  jq -e '
    ([.panels[].id] | length == (unique | length)) and
    ([.panels[] |
      (.gridPos.x >= 0 and .gridPos.y >= 0 and
       .gridPos.w > 0 and .gridPos.h > 0 and
       (.gridPos.x + .gridPos.w) <= 24)] | all) and
    ([.panels[] as $left |
      .panels[] as $right |
      select($left.id < $right.id) |
      (($left.gridPos.x + $left.gridPos.w) <= $right.gridPos.x or
       ($right.gridPos.x + $right.gridPos.w) <= $left.gridPos.x or
       ($left.gridPos.y + $left.gridPos.h) <= $right.gridPos.y or
       ($right.gridPos.y + $right.gridPos.h) <= $left.gridPos.y)
    ] | all)
  ' "$dashboard_file" >/dev/null
done
jq -e '
  .uid == "trading-strategy-detail" and
  .timezone == "Asia/Taipei" and
  .refresh == "15s" and
  .editable == false and
  (.panels | length == 11) and
  ([.templating.list[].name] == ["server_id", "strategy"]) and
  ([.templating.list[].label] == ["伺服器", "策略"]) and
  (.templating.list[0].definition | contains("trading_target_info")) and
  (.templating.list[1].definition |
    contains("trading_target_info") and contains("server_id=\"$server_id\"")) and
  ([.panels[].type] | index("xychart") != null) and
  ([.panels[].type] | index("logs") != null) and
  ([.panels[] | select(.type == "logs") |
    (.datasource.uid == "loki" and
     (.targets[0].expr | contains("server_id=\"$server_id\"") and contains("strategy=\"$strategy\"")))
  ] | all) and
  ([.panels[] | select(.title == "執行事故 · 最近 15 分鐘") |
    (.datasource.uid == "loki" and
     .gridPos == {h: 4, w: 24, x: 0, y: 0} and
     ([.targets[].legendFormat] == ["成交確認卡住", "需人工復原", "單邊曝險", "未解 fence"]) and
     ([.targets[].expr] | all(contains("[15m]") and contains("server_id=\"$server_id\"") and contains("strategy=\"$strategy\""))))
  ] == [true]) and
  ([.panels[] | select(.title == "關鍵執行事件 · 近 6 小時") |
    (.type == "logs" and .targets[0].maxLines == 100 and .timeFrom == "6h" and
     (.targets[0].expr | contains("coordinator_fence_stalled") and contains("shutdown_with_unconsumed_continuation")))
  ] == [true]) and
  ([.panels[] | select(.title == "本輪成交額 · 依交易所") |
    (.targets | length == 1) and
    .targets[0].legendFormat == "{{exchange}} · 成交額" and
    (.targets[0].expr | contains("trading_strategy_current_run_exchange_volume_usd"))
  ] == [true]) and
  ([.panels[] | select(.title == "監控摘要") |
    ([.targets[].legendFormat] == ["程序", "Runtime Contract", "執行綁定", "Config 快照", "風控回報", "資料更新"]) and
    (.targets[0].expr | contains("trading_strategy_process_count") and
      (contains("> bool 0") | not)) and
    (.targets[1].expr | contains("trading_strategy_runtime_contract_available")) and
    (.targets[2].expr | contains("trading_strategy_runtime_binding_ok")) and
    (.targets[3].expr | contains("trading_strategy_config_snapshot_match")) and
    ([.fieldConfig.overrides[] |
      select(any(.properties[]; .id == "noValue")) | .matcher.options] ==
      ["程序", "Runtime Contract", "執行綁定", "Config 快照", "風控回報", "資料更新"])
  ] == [true]) and
  ([.panels[] | select(.title == "本輪實現損益" or .title == "損益組成") |
    .fieldConfig.defaults.unit] | all(. == "suffix: USDT")) and
  ([.panels[] | select(.title == "本輪實現損益 · 週期走勢") |
    .fieldConfig.overrides[].properties[] | select(.id == "unit") | .value] == ["suffix: USDT"]) and
  ([.. | objects | .datasource?.uid? | select(. != null)] |
    all(. == "prometheus" or . == "loki" or . == "alertmanager")) and
  ([.panels[] | .targets[] | select(.datasource.uid == "prometheus") | .expr] |
    all(contains("trading_strategy_"))) and
  ((tostring | contains("tnauqquant-prod-1")) | not) and
  ((tostring | contains("toobit-mexc-btc")) | not) and
  ((tostring | contains("trading01")) | not) and
  ((tostring | contains("lighter-robinhood-btc-canary")) | not) and
  ((tostring | contains("lighter-mainnet-btc-canary")) | not)
' "$DETAIL_DASHBOARD" >/dev/null

jq -e '
  .uid == "trading-strategy-fleet" and
  .timezone == "Asia/Taipei" and
  .refresh == "15s" and
  .editable == false and
  (.templating.list | length == 0) and
  (.panels | length == 3) and
  ([.panels[] | select(.title == "監控摘要") |
    .gridPos == {h: 4, w: 18, x: 0, y: 0} and
    ([.targets[].legendFormat] == ["監控策略", "資料過期", "程序異常", "Runtime 缺失", "Prometheus SHADOW"]) and
    (.targets[1].expr | contains("trading_target_info") and contains("unless on") and contains("< 180")) and
    (.targets[2].expr | contains("trading_strategy_run_expected") and contains("!= bool")) and
    (.targets[3].expr | contains("trading_strategy_runtime_contract_available") and contains("== 0")) and
    (.targets[4].expr | contains("pending|firing")) and
    ([.fieldConfig.overrides[] | select(.matcher.options != "監控策略") |
      .properties[] | select(.id == "thresholds") | .value.steps[1].value] == [1, 1, 1, 1])
  ] == [true]) and
  ([.panels[] | select(.title == "執行事故 · 15 分鐘") |
    (.datasource.uid == "loki" and
     .gridPos == {h: 4, w: 6, x: 18, y: 0} and
     .targets[0].queryType == "instant" and
     (.targets[0].expr | contains("[15m]") and contains("coordinator_fence_stalled") and contains("mexcui_recovery_required")))
  ] == [true]) and
  ([.panels[] | select(.type == "table")] | length == 1) and
  ([.panels[] | select(.type == "table") |
    (.targets[0].expr | contains("trading_target_info")) and
    ([.transformations[].id] == ["joinByField", "organize"]) and
    .transformations[0].options.byField == "strategy" and
    .transformations[0].options.mode == "outer" and
    (.fieldConfig.overrides | map(.matcher.options) |
      contains(["Process", "RuntimeContract", "Binding", "ConfigSnapshot", "Risk", "Telemetry", "Alerts"])) and
    (.targets[5].expr | contains("trading_strategy_process_count") and
      (contains("> bool 0") | not)) and
    ([.targets[] | select(.refId == "H") | .expr] |
      (length == 1 and (.[0] | contains("trading_strategy_risk_stopped")))) and
    .transformations[1].options.renameByName["Value #H"] == "Risk" and
    ([.fieldConfig.overrides[] | select(.matcher.options == "Risk") |
      .properties[] | select(.id == "displayName") | .value] == ["風控回報"]) and
    ([.targets[] | select(.refId == "M") | .expr] |
      (length == 1 and (.[0] | contains("trading_strategy_runtime_contract_available")))) and
    .transformations[1].options.renameByName["Value #M"] == "RuntimeContract" and
    ([.targets[] | select(.refId == "G") | .expr] |
      (length == 1 and (.[0] | contains("trading_strategy_runtime_binding_ok")))) and
    ([.targets[] | select(.refId == "N") | .expr] |
      (length == 1 and (.[0] | contains("trading_strategy_config_snapshot_match")))) and
    ([.targets[] | select(.refId == "I") | .expr] |
      (length == 1 and (.[0] | contains("trading_strategy_probe_timestamp_seconds < bool 180")))) and
    .transformations[1].options.renameByName["Value #I"] == "Telemetry" and
    ([.fieldConfig.overrides[] | select(.matcher.options == "Telemetry") |
      .properties[] | select(.id == "displayName") | .value] == ["資料更新"]) and
    (.targets[11].expr |
      contains("count by (strategy)") and
      contains("pending|firing") and
      contains("0 * max by (strategy) (trading_target_info")) and
    ([.fieldConfig.overrides[] | select(.matcher.options == "Process") |
      .properties[] | select(.id == "mappings") | .value[] |
      select(.type == "range") | (.options.from == 2 and .options.to > 1000)] == [true]) and
    ([.fieldConfig.overrides[].properties[]? |
      select(.id == "displayName") | .value] |
      contains(["策略", "伺服器", "本輪實現損益", "最近週期損益", "程序", "Runtime Contract", "執行綁定", "Config 快照", "風控回報", "資料更新", "告警"])) and
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
  ((tostring | contains("lighter-robinhood-btc-canary")) | not) and
  ((tostring | contains("lighter-mainnet-btc-canary")) | not)
' "$FLEET_DASHBOARD" >/dev/null

if rg -q 'development|tnauqquant-dev-mac|mexc-toobit-btc' \
  "$PROM_RULES" "$PROM_TARGET" "$LOKI_RULES"
then
  printf 'FAIL: legacy development Trading target remains in central config\n' >&2
  exit 1
fi

for production_value in \
  production \
  tnauqquant-prod-1 \
  toobit-mexc-btc \
  trading01 \
  lighter-robinhood-btc-canary \
  lighter-mainnet-btc-canary
do
  rg -q -- "$production_value" "$PROM_TARGET" || {
    printf 'FAIL: inventory is missing production identity %s\n' \
      "$production_value" >&2
    exit 1
  }
done

[[ "$(rg -c '^[[:space:]]+- record:[[:space:]]+trading_target_info' "$PROM_TARGET")" == "3" ]] || {
  printf 'FAIL: expected exactly three generic Trading inventory rows\n' >&2
  exit 1
}
for strategy in lighter-robinhood-btc-canary lighter-mainnet-btc-canary; do
  stanza="$(awk -v RS='' -v strategy="$strategy" '
    $0 ~ /record: trading_target_info/ && $0 ~ ("strategy: " strategy) {
      print
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$PROM_TARGET")" || {
    printf 'FAIL: missing Trading01 inventory stanza for %s\n' "$strategy" >&2
    exit 1
  }
  printf '%s\n' "$stanza" | rg -q 'server_id:[[:space:]]+trading01' || {
    printf 'FAIL: %s inventory row is not bound to trading01\n' "$strategy" >&2
    exit 1
  }
  printf '%s\n' "$stanza" | rg -q 'quote_currency:[[:space:]]+USDT' || {
    printf 'FAIL: %s inventory row must use USDT\n' "$strategy" >&2
    exit 1
  }
  if printf '%s\n' "$stanza" | rg -q 'history_capable'; then
    printf 'FAIL: %s must not claim a history builder\n' "$strategy" >&2
    exit 1
  fi
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
  trading_strategy_runtime_binding_ok \
  trading_strategy_config_snapshot_match \
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

rg -q 'alert:[[:space:]]+TradingRuntimeContractMissing' "$PROM_RULES" || {
  printf 'FAIL: expected runs without a runtime contract need a dedicated alert\n' >&2
  exit 1
}
rg -q 'alert:[[:space:]]+TradingExecutionIncident' "$LOKI_RULES" || {
  printf 'FAIL: execution incident taxonomy alert is missing\n' >&2
  exit 1
}
rg -F -q 'ERROR([+][0-9]+)?' "$LOKI_RULES" || {
  printf 'FAIL: generic Loki error fallback must include ERROR+N levels\n' >&2
  exit 1
}
for incident_message in \
  coordinator_fence_stalled \
  mexcui_recovery_required \
  mexcui_recovery_required_refusing_normal_startup \
  shutdown_with_unconsumed_continuation \
  coordinated_shutdown_preserved_unresolved_fence
do
  rg -q -- "$incident_message" "$LOKI_RULES" || {
    printf 'FAIL: Loki incident taxonomy is missing %s\n' "$incident_message" >&2
    exit 1
  }
done
rg -q 'msg!~' "$LOKI_RULES" || {
  printf 'FAIL: generic Loki error fallback must exclude incident taxonomy events\n' >&2
  exit 1
}
[[ "$(rg -c '__error__=""' "$LOKI_RULES")" == "3" ]] || {
  printf 'FAIL: every Loki metric rule must filter parser errors\n' >&2
  exit 1
}

"$INCIDENT_TEST"

if rg -q 'tnauqquant-prod-1|toobit-mexc-btc|trading01|lighter-robinhood-btc-canary|lighter-mainnet-btc-canary' \
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

if command -v docker >/dev/null 2>&1; then
  docker run --rm \
    -v "$REPO_ROOT/prometheus:/etc/prometheus:ro" \
    --entrypoint /bin/promtool \
    prom/prometheus:v2.54.1 \
    check rules \
    /etc/prometheus/rules/trading-targets.yml \
    /etc/prometheus/rules/trading.yml
  docker run --rm \
    -v "$REPO_ROOT/prometheus:/etc/prometheus:ro" \
    --entrypoint /bin/promtool \
    prom/prometheus:v2.54.1 \
    test rules /etc/prometheus/rules/tests/trading.test.yml
elif command -v promtool >/dev/null 2>&1; then
  promtool check rules "$PROM_TARGET" "$PROM_RULES"
  promtool test rules "$REPO_ROOT/prometheus/rules/tests/trading.test.yml"
else
  printf 'SKIP: docker/promtool unavailable; Prometheus rule execution was not run\n'
fi

printf 'PASS: central Trading production target and dashboard contract\n'
