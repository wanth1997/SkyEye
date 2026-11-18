#!/usr/bin/env bash
set -euo pipefail

# Covers every checked-in Linux instance example
# (agents/alloy/trading/deployment-linux-*.env.example). The examples are
# discovered and the expectations come from each file and from the live
# inventory, so a new lane's example is covered without editing this suite.
#
# An example may leave a required value empty when SkyEye has not verified it
# on the host. Such an example must say so, and setup-linux.sh must refuse it
# until every empty value is filled. To check the rest of the file, this suite
# fills the empty values with stand-ins that exist only here; no host value is
# guessed in the example or in this suite.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRADING_DIR="$REPO_ROOT/agents/alloy/trading"
SETUP="$TRADING_DIR/setup-linux.sh"
TARGET_TOOL="$REPO_ROOT/scripts/trading-target"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for required_tool in alloy rg jq python3; do
  command -v "$required_tool" >/dev/null 2>&1 || \
    fail "$required_tool is required; this suite must not pass by skipping"
done
[[ -x "$SETUP" && -x "$TARGET_TOOL" ]] || fail 'setup-linux.sh or scripts/trading-target is missing'

EXAMPLES=()
while IFS= read -r example_path; do
  EXAMPLES+=("$example_path")
done < <(find "$TRADING_DIR" -maxdepth 1 -type f -name 'deployment-linux-*.env.example' | LC_ALL=C sort)
[[ "${#EXAMPLES[@]}" -gt 0 ]] || fail 'no deployment-linux-*.env.example was found'

example_value() {
  sed -nE "s/^$1=//p" "$2" | tail -n 1
}

unfilled_keys() {
  sed -nE 's/^(TQ_[A-Z0-9_]+)=$/\1/p' "$1"
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-linux-examples.XXXXXX")"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
HOST_HOME="$TEST_ROOT/home/ubuntu"
TEXTFILE_DIR="$TEST_ROOT/var/lib/skyeye-trading/textfile"
ENVS="$TEST_ROOT/envs"
RENDERS="$TEST_ROOT/renders"
COMBINED="$TEST_ROOT/combined"
CURRENT_USER="$(id -un)"
CURRENT_GROUP="$(id -gn)"
mkdir -p "$HOST_HOME" "$TEXTFILE_DIR" "$RENDERS" "$COMBINED"
install -d -m 700 "$ENVS"

# The example moved into the test root and nothing else; empty values stay empty.
host_env() {
  local example="$1" target="$2"
  sed -E \
    -e "s#/home/ubuntu#$HOST_HOME#g" \
    -e "s#/var/lib/skyeye-trading/textfile#$TEXTFILE_DIR#g" \
    -e "s#^TQ_PROBE_USER=.*#TQ_PROBE_USER=$CURRENT_USER#" \
    -e "s#^TQ_PROBE_GROUP=.*#TQ_PROBE_GROUP=$CURRENT_GROUP#" \
    -e "s#^TQ_ALLOY_USER=.*#TQ_ALLOY_USER=$CURRENT_USER#" \
    -e "s#^TQ_ALLOY_GROUP=.*#TQ_ALLOY_GROUP=$CURRENT_GROUP#" \
    "$example" >"$target"
  chmod 600 "$target"
}

# Stand-ins for values an example leaves to the operator. They are not host
# facts. A new kind of empty value has no stand-in and fails here on purpose.
stand_in() {
  local key="$1" strategy="$2"
  case "$key" in
    TQ_EXECUTABLE) printf '%s/tnauqquant/test-only/%s/quant\n' "$HOST_HOME" "$strategy" ;;
    TQ_EXECUTOR_MAP) printf 'test-only-executor=test-only-exchange\n' ;;
    *) fail "$strategy leaves $key empty and this suite has no stand-in for it" ;;
  esac
}

# Fills every empty value except the one named by $3 (none when $3 is empty).
fill_env() {
  local source_env="$1" target="$2" keep_empty="$3" strategy key value
  strategy="$(example_value TQ_STRATEGY "$source_env")"
  cp "$source_env" "$target"
  chmod 600 "$target"
  while IFS= read -r key; do
    [[ -n "$key" && "$key" != "$keep_empty" ]] || continue
    value="$(stand_in "$key" "$strategy")"
    sed -i.bak -E "s#^$key=\$#$key=$value#" "$target" && rm -f "$target.bak"
  done < <(unfilled_keys "$source_env")
}

tree_listing() {
  find "$TEST_ROOT" -mindepth 1 ! -path "$TEST_ROOT/refused.out" | LC_ALL=C sort
}

expect_refused() {
  local label="$1" key="$2"
  shift 2
  local before
  before="$(tree_listing)"
  if "$@" >"$TEST_ROOT/refused.out" 2>&1; then
    fail "$label: setup-linux.sh accepted an env with $key empty"
  fi
  rg -q -F "$key is required" "$TEST_ROOT/refused.out" || {
    cat "$TEST_ROOT/refused.out" >&2
    fail "$label: the refusal does not name $key"
  }
  [[ "$(tree_listing)" == "$before" ]] || fail "$label: a refused run wrote a file"
}

INVENTORY_JSON="$("$TARGET_TOOL" list --format json)"
STRATEGIES=()
SERVERS=()
SAMPLE_LOGS=()
GLOBS=()
seen_paths=$'\n'

for example in "${EXAMPLES[@]}"; do
  name="$(basename "$example")"
  strategy="$(example_value TQ_STRATEGY "$example")"
  server_id="$(example_value TQ_SERVER_ID "$example")"
  [[ -n "$strategy" && -n "$server_id" ]] || fail "$name names no strategy or server"
  printf 'case: %s (%s on %s)\n' "$name" "$strategy" "$server_id"

  [[ "$(head -n 1 "$example")" == "# Install as /etc/skyeye-trading/instances/$strategy.env" ]] || \
    fail "$name: the first line must name the install path of $strategy.env"
  if rg -n -v '^(#.*|TQ_[A-Z0-9_]+=.*|)$' "$example"; then
    fail "$name: a line is not a comment or a TQ_ assignment"
  fi
  if rg -n -i 'CF_ACCESS|SECRET|TOKEN|PASSWORD|PRIVATE' "$example"; then
    fail "$name must not name a credential"
  fi
  [[ "$(example_value TQ_TEXTFILE_NAME "$example")" == "tnauqquant-$strategy.prom" ]] || \
    fail "$name: TQ_TEXTFILE_NAME must be tnauqquant-$strategy.prom"

  # Isolation: no two examples share an identity or a monitored path.
  for key in TQ_STRATEGY TQ_CONFIG_PATH TQ_RAW_LOG_GLOB TQ_RUN_MANIFEST TQ_DONE_MARKER TQ_TEXTFILE_NAME; do
    value="$(example_value "$key" "$example")"
    [[ -n "$value" ]] || fail "$name: $key is empty; only host facts SkyEye cannot derive may be left empty"
    [[ "$seen_paths" != *$'\n'"$key=$value"$'\n'* ]] || fail "$name: $key=$value is also used by another example"
    seen_paths+="$key=$value"$'\n'
  done

  disabled="$(example_value TQ_STRATEGY_DISABLED "$example")"
  case "$disabled" in
    '' | 0) ;;
    1)
      # A disabled example must tell the operator how it gets enabled and what
      # a start shows until then.
      rg -q -F 'setup-linux.sh add' "$example" && rg -q -F 'TradingUnexpectedProcess' "$example" || \
        fail "$name: TQ_STRATEGY_DISABLED=1 needs a comment naming setup-linux.sh add and TradingUnexpectedProcess"
      ;;
    *) fail "$name: TQ_STRATEGY_DISABLED=$disabled" ;;
  esac

  # The live inventory row for this strategy, if any, is on the same server.
  inventory_server="$(jq -r --arg s "$strategy" \
    '[.[] | select(.strategy == $s) | .server_id] | unique | join(",")' <<<"$INVENTORY_JSON")"
  [[ -z "$inventory_server" || "$inventory_server" == "$server_id" ]] || \
    fail "$name: the inventory has $strategy on $inventory_server, the example on $server_id"

  source_env="$ENVS/$strategy.source.env"
  host_env "$example" "$source_env"
  config_path="$(example_value TQ_CONFIG_PATH "$source_env")"
  mkdir -p "$(dirname "$config_path")" "$HOST_HOME/tnauqquant/logs/live-runs"
  printf 'instance_id: "%s"\n' "$(example_value TQ_INSTANCE_ID "$source_env")" >"$config_path"

  unfilled="$(unfilled_keys "$example")"
  filled_env="$ENVS/$strategy.env"
  if [[ -n "$unfilled" ]]; then
    rg -q -F 'NOT INSTALLABLE AS CHECKED IN' "$example" || \
      fail "$name leaves a value empty without saying it is not installable as checked in"
    [[ "$(rg -c '^# UNVERIFIED' "$example")" -ge "$(wc -l <<<"$unfilled")" ]] || \
      fail "$name: every empty value needs an UNVERIFIED comment saying how the operator finds it"
    first_unfilled="$(head -n 1 <<<"$unfilled")"
    expect_refused "$name as checked in, render" "$first_unfilled" \
      "$SETUP" --render-only "$RENDERS/$strategy-refused" --env-file "$source_env"
    expect_refused "$name as checked in, add" "$first_unfilled" \
      env SKYEYE_TRADING_TEST_ROOT="$TEST_ROOT" "$SETUP" add --env-file "$source_env"
    # Each empty value is refused on its own, whatever else is filled.
    partial_env="$ENVS/$strategy.partial.env"
    while IFS= read -r key; do
      fill_env "$source_env" "$partial_env" "$key"
      expect_refused "$name with only $key empty" "$key" \
        env SKYEYE_TRADING_TEST_ROOT="$TEST_ROOT" "$SETUP" add --env-file "$partial_env"
    done <<<"$unfilled"
    rm -f "$partial_env"
  fi
  fill_env "$source_env" "$filled_env" ''
  [[ -z "$(unfilled_keys "$filled_env")" ]] || fail "$name: a value is still empty after the stand-ins"

  render_dir="$RENDERS/$strategy"
  "$SETUP" --render-only "$render_dir" --env-file "$filled_env" >/dev/null || fail "$name does not render"
  fragment="$render_dir/trading-$strategy.alloy"
  [[ -f "$fragment" && -f "$render_dir/trading-metrics.alloy" ]] || fail "$name rendered no fragment"
  rg -q "strategy[[:space:]]*=[[:space:]]*\"$strategy\"" "$fragment" || \
    fail "$name: the fragment does not carry strategy=$strategy"
  rg -q "server_id[[:space:]]*=[[:space:]]*\"$server_id\"" "$fragment" || \
    fail "$name: the fragment does not carry server_id=$server_id"
  rg -q -F "$(example_value TQ_RAW_LOG_GLOB "$filled_env")" "$fragment" || \
    fail "$name: the fragment does not tail its own raw log glob"
  if rg -q 'prometheus[.]exporter[.]unix|@@[A-Z_]+@@' "$fragment"; then
    fail "$name: the fragment carries a collector or an unrendered placeholder"
  fi
  cmp -s "$filled_env" "$render_dir/instances/$strategy.env" || fail "$name: the rendered env differs from its source"
  cp "$fragment" "$COMBINED/"
  cp "$render_dir/trading-metrics.alloy" "$COMBINED/"

  STRATEGIES+=("$strategy")
  SERVERS+=("$server_id")
  GLOBS+=("$(example_value TQ_RAW_LOG_GLOB "$example")")
  sample_log="$(example_value TQ_RAW_LOG_GLOB "$example")"
  [[ "$sample_log" == *'*'* ]] || fail "$name: TQ_RAW_LOG_GLOB has no wildcard for the run timestamp"
  SAMPLE_LOGS+=("${sample_log/\*/20261119_000000_}")
done

printf 'case: each raw log glob matches only its own lane\n'
for i in "${!GLOBS[@]}"; do
  for j in "${!SAMPLE_LOGS[@]}"; do
    # shellcheck disable=SC2053
    if [[ "${SAMPLE_LOGS[$j]}" == ${GLOBS[$i]} ]]; then
      [[ "$i" == "$j" ]] || fail "the ${STRATEGIES[$i]} glob also matches a ${STRATEGIES[$j]} log"
    else
      [[ "$i" != "$j" ]] || fail "the ${STRATEGIES[$i]} glob does not match its own log name"
    fi
  done
done

printf 'case: every fragment loads next to the others in one Alloy directory\n'
cat >"$COMBINED/config.alloy" <<'EOF'
loki.write "central" {
  endpoint { url = "https://loki.invalid/loki/api/v1/push" }
}
prometheus.remote_write "central" {
  endpoint { url = "https://prometheus.invalid/api/v1/write" }
}
EOF
alloy validate "$COMBINED" >/dev/null || fail 'the combined Alloy directory does not validate'

printf 'case: every inventory row on a server with Linux examples has an example\n'
example_servers="$(printf '%s\n' "${SERVERS[@]}" | LC_ALL=C sort -u)"
example_strategies="$(printf '%s\n' "${STRATEGIES[@]}")"
checked_rows=0
while IFS=$'\t' read -r row_server row_strategy; do
  grep -qxF "$row_server" <<<"$example_servers" || continue
  grep -qxF "$row_strategy" <<<"$example_strategies" || \
    fail "the inventory has $row_strategy on $row_server but no deployment-linux-*.env.example names it"
  checked_rows=$((checked_rows + 1))
done < <(jq -r '.[] | [.server_id, .strategy] | @tsv' <<<"$INVENTORY_JSON")
[[ "$checked_rows" -gt 0 ]] || fail 'no inventory row was compared with the examples'

printf 'PASS: %d Linux instance examples, %d inventory rows\n' "${#EXAMPLES[@]}" "$checked_rows"
