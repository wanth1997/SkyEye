#!/usr/bin/env bash
set -euo pipefail

# Covers every checked-in Linux instance example
# (agents/alloy/trading/deployment-linux-*.env.example). The examples are
# discovered and the expectations come from each file, so a new lane's example
# is covered without editing this suite. Which targets exist is the
# inventory's business (tests/trading/test-trading-target.sh): an example
# needs no inventory row and a row needs no example. Where both exist they
# must name the same target.
#
# An example may leave a required value empty when SkyEye has not verified it
# on the host. Such an example must say so, and setup-linux.sh must refuse it
# until every empty value is filled. To check the rest of the file, this suite
# fills the empty values with stand-ins that exist only here; no host value is
# guessed in the example or in this suite.
#
# Every example's TQ_RAW_LOG_GLOB is DIR/<8 x [0-9]>_<6 x [0-9]>_<config
# stem>.raw.log, the stem taken from its own TQ_CONFIG_PATH, and its comments
# say so with the line "# CONTRACT-NAMED LOGS ONLY". The suite proves that the
# glob selects the lane's contract-named raw log and no file that only
# resembles it, as the probe, ensure-log-access.sh and the Alloy fragment use
# it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRADING_DIR="$REPO_ROOT/agents/alloy/trading"
SETUP="$TRADING_DIR/setup-linux.sh"
ACCESS_HELPER="$TRADING_DIR/ensure-log-access.sh"
TARGET_TOOL="$REPO_ROOT/scripts/trading-target"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for required_tool in alloy rg jq python3; do
  command -v "$required_tool" >/dev/null 2>&1 || \
    fail "$required_tool is required; this suite must not pass by skipping"
done
[[ -x "$SETUP" && -x "$ACCESS_HELPER" && -x "$TARGET_TOOL" ]] || \
  fail 'setup-linux.sh, ensure-log-access.sh or scripts/trading-target is missing'

# The host tools' own readers. valid_label_value is what setup-linux.sh accepts
# as a strategy name; installed_env_value is how it reads a value back from an
# env file without executing it.
die() {
  fail "$@"
}
# shellcheck source=/dev/null
source "$TRADING_DIR/linux-common.sh"

EXAMPLES=()
while IFS= read -r example_path; do
  EXAMPLES+=("$example_path")
done < <(find "$TRADING_DIR" -maxdepth 1 -type f -name 'deployment-linux-*.env.example' | LC_ALL=C sort)
[[ "${#EXAMPLES[@]}" -gt 0 ]] || fail 'no deployment-linux-*.env.example was found'

# Reads NAME from an env file as the host tools do, so NAME=value,
# NAME="value" and NAME='value' all give value.
example_value() {
  installed_env_value "$1" "$2" || \
    fail "$(basename "$2"): $1 is not an assignment the host tools can read"
}

# Prints the quote character NAME's value is written in, if any.
value_quote() {
  case "$(sed -nE "s/^$1=//p" "$2" | tail -n 1)" in
    \"*) printf '"' ;;
    \'*) printf "'" ;;
  esac
}

unfilled_keys() {
  sed -nE 's/^(TQ_[A-Z0-9_]+)=$/\1/p' "$1"
}

# Replaces the NAME=... line of FILE. The value is written as it is given, so
# a path or a glob needs no escaping.
set_env_value() {
  local file="$1"
  ENV_KEY="$2" ENV_VALUE="$3" awk '
    index($0, ENVIRON["ENV_KEY"] "=") == 1 { print ENVIRON["ENV_KEY"] "=" ENVIRON["ENV_VALUE"]; next }
    { print }
  ' "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
  chmod 600 "$file"
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-linux-examples.XXXXXX")"
OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-linux-examples-outside.XXXXXX")"
cleanup() {
  rm -rf "$TEST_ROOT" "$OUTSIDE"
}
trap cleanup EXIT
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
OUTSIDE="$(cd "$OUTSIDE" && pwd -P)"
ENVS="$TEST_ROOT/envs"
RENDERS="$TEST_ROOT/renders"
COMBINED="$TEST_ROOT/combined"
FAKE_BIN="$TEST_ROOT/bin"
SETFACL_LOG="$TEST_ROOT/setfacl.log"
CURRENT_USER="$(id -un)"
CURRENT_GROUP="$(id -gn)"
mkdir -p "$RENDERS" "$COMBINED" "$FAKE_BIN"
install -d -m 700 "$ENVS"

# ensure-log-access.sh grants Alloy read access to the files its glob selects.
# These stand in for the ACL tools and record which files that was.
cat >"$FAKE_BIN/getfacl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'user::rw-' 'group::---' 'mask::---' 'other::---'
EOF
cat >"$FAKE_BIN/setfacl" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  target="$argument"
done
printf '%s\n' "$target" >>"$SETFACL_LOG"
EOF
chmod 755 "$FAKE_BIN/getfacl" "$FAKE_BIN/setfacl"
export SETFACL_LOG

# Every value of an example that names a path on the host.
PATH_KEYS=(TQ_REPO_ROOT TQ_EXECUTABLE TQ_CONFIG_PATH TQ_RAW_LOG_GLOB TQ_RUN_MANIFEST TQ_DONE_MARKER TQ_TEXTFILE_DIR)

# Fails unless PATH, with every symlink and .. resolved, is below the test
# root. Nothing has to exist yet.
require_in_test_root() {
  local label="$1" path="$2" resolved
  resolved="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path")"
  [[ "$resolved" == "$TEST_ROOT"/* ]] || \
    fail "$label: $path resolves to $resolved, outside the test root; nothing was created for it"
}

# Copies EXAMPLE to TARGET for a run inside the test root: each host path gets
# the test root put in front of it, wherever the example points and in the
# quotes the example wrote it in, and the host accounts become the current
# user. Empty values stay empty. Then creates what setup-linux.sh expects on a
# host: the repo root, the config carrying the example's instance id, the raw
# log directory and the textfile directory.
#
# Nothing is written before every name and path has been checked. Callers
# build TARGET and later paths from the example's TQ_STRATEGY, so the name
# must be one setup-linux.sh accepts, and TARGET and every mapped path must
# resolve below the test root.
stage_example() {
  local example="$1" target="$2" label strategy key value repo_root config_path log_glob textfile_dir
  label="$(basename "$example")"
  strategy="$(example_value TQ_STRATEGY "$example")"
  valid_label_value "$strategy" || \
    fail "$label: TQ_STRATEGY=$strategy is not a name setup-linux.sh accepts; nothing was written for it"
  require_in_test_root "$label staged env" "$target"
  for key in "${PATH_KEYS[@]}"; do
    value="$(example_value "$key" "$example")"
    [[ -n "$value" ]] || continue
    [[ "$value" == /* ]] || fail "$label: $key must be an absolute path, got $value"
    require_in_test_root "$label $key" "$TEST_ROOT$value"
  done
  for key in TQ_REPO_ROOT TQ_CONFIG_PATH TQ_RAW_LOG_GLOB TQ_TEXTFILE_DIR; do
    [[ -n "$(example_value "$key" "$example")" ]] || \
      fail "$label: $key is not a host fact to leave empty"
  done

  cp "$example" "$target"
  chmod 600 "$target"
  for key in "${PATH_KEYS[@]}"; do
    value="$(example_value "$key" "$example")"
    [[ -n "$value" ]] || continue
    set_env_value "$target" "$key" "$(value_quote "$key" "$example")$TEST_ROOT$value$(value_quote "$key" "$example")"
  done
  set_env_value "$target" TQ_PROBE_USER "$CURRENT_USER"
  set_env_value "$target" TQ_PROBE_GROUP "$CURRENT_GROUP"
  set_env_value "$target" TQ_ALLOY_USER "$CURRENT_USER"
  set_env_value "$target" TQ_ALLOY_GROUP "$CURRENT_GROUP"

  repo_root="$(example_value TQ_REPO_ROOT "$target")"
  config_path="$(example_value TQ_CONFIG_PATH "$target")"
  log_glob="$(example_value TQ_RAW_LOG_GLOB "$target")"
  textfile_dir="$(example_value TQ_TEXTFILE_DIR "$target")"
  mkdir -p "$repo_root" "$(dirname "$config_path")" "${log_glob%/*}" "$textfile_dir"
  printf 'instance_id: "%s"\n' "$(example_value TQ_INSTANCE_ID "$target")" >"$config_path"
}

# Stand-ins for values an example leaves to the operator. They are not host
# facts. A new kind of empty value has no stand-in and fails here on purpose.
stand_in() {
  local key="$1" env_file="$2"
  case "$key" in
    TQ_EXECUTABLE)
      printf '%s/test-only/%s/quant\n' \
        "$(example_value TQ_REPO_ROOT "$env_file")" "$(example_value TQ_STRATEGY "$env_file")"
      ;;
    TQ_EXECUTOR_MAP) printf 'test-only-executor=test-only-exchange\n' ;;
    *) fail "$(example_value TQ_STRATEGY "$env_file") leaves $key empty and this suite has no stand-in for it" ;;
  esac
}

# Fills every empty value except the one named by $3 (none when $3 is empty).
fill_env() {
  local source_env="$1" target="$2" keep_empty="$3" key
  cp "$source_env" "$target"
  chmod 600 "$target"
  while IFS= read -r key; do
    [[ -n "$key" && "$key" != "$keep_empty" ]] || continue
    set_env_value "$target" "$key" "$(stand_in "$key" "$source_env")"
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

# The name the runtime contract gives a raw log is
# YYYYMMDD_HHMMSS_<config stem>.raw.log. Each lane gets one such log, named
# from its TQ_CONFIG_PATH and not from its glob, plus files whose names only
# resemble it. A glob in the contract form selects the first and none of the
# others.
RUN_STAMP=20261119_000000
CONTRACT_PREFIX='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]_'
resembling_names() {
  local stem="$1"
  printf '%s\n' \
    "${RUN_STAMP}_test_$stem.raw.log" \
    "20261119_120000_foo_$stem.raw.log" \
    "backup_${RUN_STAMP}_$stem.raw.log" \
    "x${RUN_STAMP}_$stem.raw.log" \
    "2026111x_000000_$stem.raw.log" \
    "20261119_00000_$stem.raw.log" \
    "20261119-000000_$stem.raw.log" \
    "$stem.raw.log" \
    "$stem.raw.log.bak" \
    "${RUN_STAMP}_$stem.raw.log.1" \
    "${RUN_STAMP}_$stem.raw.log.bak"
}

# Where the loop below stages the example of STRATEGY.
staged_env_path() {
  printf '%s/%s.source.env\n' "$ENVS" "$1"
}

INVENTORY_JSON="$("$TARGET_TOOL" list --format json)"
STRATEGIES=()
STAGED_REPO_ROOTS=()
STAGED_GLOBS=()
OWN_LOGS=()
rows_compared=0
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

  # No line means BTC; a line must carry a value the probe and installer accept.
  if rg -q '^TQ_BASE_ASSET=' "$example"; then
    base_asset="$(example_value TQ_BASE_ASSET "$example")"
    valid_base_asset "$base_asset" || \
      fail "$name: TQ_BASE_ASSET=$base_asset is not an ASCII upper-case asset code"
  fi

  # An example and an inventory row for the same strategy on the same server
  # are one target and must agree on the rest of its identity. Neither has to
  # exist for the other.
  if jq -e --arg h "$server_id" --arg s "$strategy" \
    'any(.[]; .server_id == $h and .strategy == $s)' <<<"$INVENTORY_JSON" >/dev/null; then
    jq -e --arg h "$server_id" --arg s "$strategy" \
      --arg p "$(example_value TQ_PRODUCT "$example")" --arg e "$(example_value TQ_ENVIRONMENT "$example")" \
      'any(.[]; .server_id == $h and .strategy == $s and .product == $p and .environment == $e)' \
      <<<"$INVENTORY_JSON" >/dev/null || \
      fail "$name: the inventory row for $strategy on $server_id names another product or environment"
    rows_compared=$((rows_compared + 1))
  fi

  source_env="$(staged_env_path "$strategy")"
  stage_example "$example" "$source_env"

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

  # example_value reads the glob as retire and later sibling adds do: from the
  # env, without executing it.
  staged_glob="$(example_value TQ_RAW_LOG_GLOB "$filled_env")"
  render_dir="$RENDERS/$strategy"
  "$SETUP" --render-only "$render_dir" --env-file "$filled_env" >/dev/null || fail "$name does not render"
  fragment="$render_dir/trading-$strategy.alloy"
  [[ -f "$fragment" && -f "$render_dir/trading-metrics.alloy" ]] || fail "$name rendered no fragment"
  rg -q "strategy[[:space:]]*=[[:space:]]*\"$strategy\"" "$fragment" || \
    fail "$name: the fragment does not carry strategy=$strategy"
  rg -q "server_id[[:space:]]*=[[:space:]]*\"$server_id\"" "$fragment" || \
    fail "$name: the fragment does not carry server_id=$server_id"
  rg -q -F "\"$staged_glob\"" "$fragment" || \
    fail "$name: the fragment does not tail its own raw log glob, character for character"
  if rg -q 'prometheus[.]exporter[.]unix|@@[A-Z_]+@@' "$fragment"; then
    fail "$name: the fragment carries a collector or an unrendered placeholder"
  fi
  cmp -s "$filled_env" "$render_dir/instances/$strategy.env" || fail "$name: the rendered env differs from its source"
  cp "$fragment" "$COMBINED/"
  cp "$render_dir/trading-metrics.alloy" "$COMBINED/"

  config_stem="$(basename "$(example_value TQ_CONFIG_PATH "$example")")"
  config_stem="${config_stem%.*}"
  # The glob itself, as checked in, is the contract form for this lane's own
  # config stem, and the example says so.
  example_glob="$(example_value TQ_RAW_LOG_GLOB "$example")"
  [[ "${example_glob##*/}" == "$CONTRACT_PREFIX$config_stem.raw.log" ]] || \
    fail "$name: TQ_RAW_LOG_GLOB must end in /$CONTRACT_PREFIX$config_stem.raw.log, got ${example_glob##*/}"
  rg -q '^# CONTRACT-NAMED LOGS ONLY' "$example" || \
    fail "$name: TQ_RAW_LOG_GLOB needs the comment line '# CONTRACT-NAMED LOGS ONLY'"
  log_dir="${staged_glob%/*}"
  own_log="$log_dir/${RUN_STAMP}_$config_stem.raw.log"
  printf 'msg=own\n' >"$own_log"
  while IFS= read -r resembling_name; do
    printf 'msg=not-this-lane\n' >"$log_dir/$resembling_name"
  done < <(resembling_names "$config_stem")

  STRATEGIES+=("$strategy")
  STAGED_REPO_ROOTS+=("$(example_value TQ_REPO_ROOT "$filled_env")")
  STAGED_GLOBS+=("$staged_glob")
  OWN_LOGS+=("$own_log")
done

printf 'case: each raw log glob selects its own contract-named log and no other lane'"'"'s\n'
for i in "${!STAGED_GLOBS[@]}"; do
  # compgen -G is how probe.sh expands the glob.
  selected="$(compgen -G "${STAGED_GLOBS[$i]}" | LC_ALL=C sort || true)"
  grep -qxF "${OWN_LOGS[$i]}" <<<"$selected" || \
    fail "${STRATEGIES[$i]}: TQ_RAW_LOG_GLOB does not select $(basename "${OWN_LOGS[$i]}"), the contract name for its TQ_CONFIG_PATH"
  for j in "${!OWN_LOGS[@]}"; do
    [[ "$i" != "$j" ]] || continue
    if grep -qxF "${OWN_LOGS[$j]}" <<<"$selected"; then
      fail "the ${STRATEGIES[$i]} glob also selects the ${STRATEGIES[$j]} log"
    fi
  done

  # ensure-log-access.sh runs before every probe and opens the selected files
  # to Alloy. It expands the glob with find and must select the same files.
  : >"$SETFACL_LOG"
  TQ_REPO_ROOT="${STAGED_REPO_ROOTS[$i]}" TQ_RAW_LOG_GLOB="${STAGED_GLOBS[$i]}" TQ_ALLOY_USER=alloy \
    PATH="$FAKE_BIN:$PATH" "$ACCESS_HELPER" || fail "${STRATEGIES[$i]}: ensure-log-access.sh refused the glob"
  [[ "$(LC_ALL=C sort "$SETFACL_LOG")" == "$selected" ]] || \
    fail "${STRATEGIES[$i]}: ensure-log-access.sh and the probe select different files for the same glob"

  # The glob selects its own log and none of the files that resemble it.
  # Installed host envs are not rewritten from this repo; README.md says how
  # an operator applies the tightened glob to them.
  if [[ "$selected" != "${OWN_LOGS[$i]}" ]]; then
    fail "${STRATEGIES[$i]}: TQ_RAW_LOG_GLOB selects more than its own contract-named log: $(tr '\n' ' ' <<<"$selected"). Use DIR/<8 x [0-9]>_<6 x [0-9]>_<config stem>.raw.log"
  fi
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

# Stages and renders EXAMPLE, whose host paths are below HOST_ROOT, in its own
# directory of the test root, and checks that what it needed was created below
# the test root and not on this machine.
check_staged_elsewhere() {
  local label="$1" example="$2" host_root="$3" work="$TEST_ROOT/relocated/$1" staged config glob
  mkdir -p "$work"
  staged="$work/source.env"
  stage_example "$example" "$staged"
  config="$(example_value TQ_CONFIG_PATH "$staged")"
  [[ "$config" == "$TEST_ROOT$host_root/repo/"* && -f "$config" ]] || \
    fail "$label: the config was not created below the test root: $config"
  fill_env "$staged" "$work/filled.env" ''
  "$SETUP" --render-only "$work/render" --env-file "$work/filled.env" >/dev/null || \
    fail "$label: the example does not render"
  glob="$(example_value TQ_RAW_LOG_GLOB "$staged")"
  rg -q -F "\"$glob\"" "$work/render/trading-$(example_value TQ_STRATEGY "$staged").alloy" || \
    fail "$label: the fragment does not tail the glob below the test root"
  [[ ! -e "$host_root" ]] || fail "$label: staging or rendering wrote to $host_root on this machine"
}

# A file outside the test root that no case may touch.
victim="$OUTSIDE/victim.source.env"
printf 'not a test file\n' >"$victim"
chmod 644 "$victim"
outside_untouched() {
  [[ "$(ls -A "$OUTSIDE")" == "$(basename "$victim")" && "$(cat "$victim")" == 'not a test file' &&
    "$(file_mode "$victim")" == 644 ]]
}

# Expects stage_example to refuse EXAMPLE with REASON before it writes
# anything, in the test root or outside it.
expect_stage_refused() {
  local label="$1" reason="$2" example="$3" target="$4" before
  before="$(tree_listing)"
  if (stage_example "$example" "$target") >"$TEST_ROOT/refused.out" 2>&1; then
    fail "$label: the example was staged"
  fi
  rg -q -F "$reason" "$TEST_ROOT/refused.out" || {
    cat "$TEST_ROOT/refused.out" >&2
    fail "$label: the example was refused for another reason than: $reason"
  }
  [[ "$(tree_listing)" == "$before" ]] || fail "$label: the refused example left files behind in the test root"
  outside_untouched || fail "$label: staging changed a file outside the test root"
}

printf 'case: an example whose paths are not under /home/ubuntu is still staged inside the test root\n'
base_example="${EXAMPLES[0]}"
relocated_root="/srv/skyeye-example-relocated-$$"
[[ ! -e "$relocated_root" ]] || fail "$relocated_root exists on this machine"
mkdir -p "$TEST_ROOT/relocated"
relocated_example="$TEST_ROOT/relocated/deployment-linux-relocated.env.example"
python3 -c 'import sys; sys.stdout.write(sys.stdin.read().replace(sys.argv[1], sys.argv[2]))' \
  "$(example_value TQ_REPO_ROOT "$base_example")" "$relocated_root/repo" \
  <"$base_example" >"$relocated_example"
for key in TQ_REPO_ROOT TQ_CONFIG_PATH TQ_RAW_LOG_GLOB TQ_RUN_MANIFEST TQ_DONE_MARKER; do
  [[ "$(example_value "$key" "$relocated_example")" == "$relocated_root/repo"* ]] || \
    fail "the relocated example still has $key outside $relocated_root"
done
check_staged_elsewhere relocated "$relocated_example" "$relocated_root"

printf 'case: a path written in quotes is staged like a bare one, and stays quoted\n'
quoted_example="$TEST_ROOT/relocated/deployment-linux-quoted.env.example"
cp "$relocated_example" "$quoted_example"
set_env_value "$quoted_example" TQ_CONFIG_PATH "\"$(example_value TQ_CONFIG_PATH "$relocated_example")\""
set_env_value "$quoted_example" TQ_RAW_LOG_GLOB "'$(example_value TQ_RAW_LOG_GLOB "$relocated_example")'"
check_staged_elsewhere quoted "$quoted_example" "$relocated_root"
rg -q '^TQ_CONFIG_PATH="/.*"$' "$TEST_ROOT/relocated/quoted/source.env" &&
  rg -q "^TQ_RAW_LOG_GLOB='/.*'\$" "$TEST_ROOT/relocated/quoted/source.env" || \
  fail 'the staged env did not keep the quotes the example wrote its paths in'

printf 'case: a path that climbs out of the test root is refused before anything is created\n'
climb=''
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32; do
  climb+='../'
done
escape_example="$TEST_ROOT/relocated/deployment-linux-escape.env.example"
cp "$base_example" "$escape_example"
set_env_value "$escape_example" TQ_CONFIG_PATH "/climb/${climb%/}$OUTSIDE/config/escape.yaml"
expect_stage_refused 'a config path that climbs out' 'outside the test root' \
  "$escape_example" "$TEST_ROOT/relocated/escape.source.env"

printf 'case: a strategy name that is not a plain label is refused before a path is built from it\n'
# With this name, the path the loop above would stage to is the file outside.
unsafe_strategy="../../$(basename "$OUTSIDE")/victim"
unsafe_example="$TEST_ROOT/relocated/deployment-linux-unsafe-name.env.example"
cp "$base_example" "$unsafe_example"
set_env_value "$unsafe_example" TQ_STRATEGY "$unsafe_strategy"
unsafe_target="$(staged_env_path "$unsafe_strategy")"
[[ "$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$unsafe_target")" == "$victim" ]] || \
  fail "the unsafe strategy name does not lead to $victim, so this case would prove nothing"
expect_stage_refused 'a strategy name with path separators' 'is not a name setup-linux.sh accepts' \
  "$unsafe_example" "$unsafe_target"

printf 'case: a staging target outside the test root is refused, whatever the strategy is called\n'
expect_stage_refused 'a staging target outside the test root' 'outside the test root' "$base_example" "$victim"

printf 'PASS: %d Linux instance examples, %d with an inventory row, all held to contract-named logs only\n' \
  "${#EXAMPLES[@]}" "$rows_compared"
