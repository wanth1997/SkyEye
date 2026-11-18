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
# the test root put in front of it, wherever the example points, and the host
# accounts become the current user. Empty values stay empty. Then creates what
# setup-linux.sh expects on a host: the repo root, the config carrying the
# example's instance id, the raw log directory and the textfile directory.
# Every path is checked before the first directory or file is created.
stage_example() {
  local example="$1" target="$2" label key value repo_root config_path log_glob textfile_dir
  label="$(basename "$example")"
  cp "$example" "$target"
  chmod 600 "$target"
  for key in "${PATH_KEYS[@]}"; do
    value="$(example_value "$key" "$example")"
    [[ -n "$value" ]] || continue
    [[ "$value" == /* ]] || fail "$label: $key must be a bare absolute path, got $value"
    set_env_value "$target" "$key" "$TEST_ROOT$value"
  done
  set_env_value "$target" TQ_PROBE_USER "$CURRENT_USER"
  set_env_value "$target" TQ_PROBE_GROUP "$CURRENT_GROUP"
  set_env_value "$target" TQ_ALLOY_USER "$CURRENT_USER"
  set_env_value "$target" TQ_ALLOY_GROUP "$CURRENT_GROUP"

  for key in "${PATH_KEYS[@]}"; do
    value="$(example_value "$key" "$target")"
    [[ -z "$value" ]] || require_in_test_root "$label $key" "$value"
  done
  repo_root="$(example_value TQ_REPO_ROOT "$target")"
  config_path="$(example_value TQ_CONFIG_PATH "$target")"
  log_glob="$(example_value TQ_RAW_LOG_GLOB "$target")"
  textfile_dir="$(example_value TQ_TEXTFILE_DIR "$target")"
  [[ -n "$repo_root" && -n "$config_path" && -n "$log_glob" && -n "$textfile_dir" ]] || \
    fail "$label: TQ_REPO_ROOT, TQ_CONFIG_PATH, TQ_RAW_LOG_GLOB and TQ_TEXTFILE_DIR are not host facts to leave empty"
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
resembling_names() {
  local stem="$1"
  printf '%s\n' \
    "${RUN_STAMP}_test_$stem.raw.log" \
    "backup_${RUN_STAMP}_$stem.raw.log" \
    "$stem.raw.log" \
    "${RUN_STAMP}_$stem.raw.log.1"
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

  source_env="$ENVS/$strategy.source.env"
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
  # retire and later sibling adds read the glob back from the installed env
  # without executing it; they must get the same pattern.
  readback_glob="$(
    die() { exit 1; }
    # shellcheck source=/dev/null
    source "$TRADING_DIR/linux-common.sh"
    installed_env_value TQ_RAW_LOG_GLOB "$render_dir/instances/$strategy.env"
  )" || fail "$name: the host tools cannot read TQ_RAW_LOG_GLOB back from the installed env"
  [[ "$readback_glob" == "$staged_glob" ]] || fail "$name: TQ_RAW_LOG_GLOB reads back as $readback_glob"
  cp "$fragment" "$COMBINED/"
  cp "$render_dir/trading-metrics.alloy" "$COMBINED/"

  config_stem="$(basename "$(example_value TQ_CONFIG_PATH "$example")")"
  config_stem="${config_stem%.*}"
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
suffix_only=0
suffix_only_names=''
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

  if [[ "$selected" != "${OWN_LOGS[$i]}" ]]; then
    suffix_only=$((suffix_only + 1))
    suffix_only_names+=" ${STRATEGIES[$i]}"
  fi
done

printf 'case: no further example selects files that only resemble its raw log\n'
# The examples written before the contract form was used here end in
# *<config stem>.raw.log, which also selects the resembling files. They stay
# as they are: the envs installed on the hosts carry the same value and are
# not rewritten from this repo. This is how many of them there are, and no
# other example may join them; lower the number when one is tightened.
MAX_SUFFIX_ONLY_GLOBS=4
[[ "$suffix_only" -le "$MAX_SUFFIX_ONLY_GLOBS" ]] || \
  fail "$suffix_only examples have a TQ_RAW_LOG_GLOB that also selects similarly named files ($suffix_only_names ); only the $MAX_SUFFIX_ONLY_GLOBS older ones may. Use DIR/<8 x [0-9]>_<6 x [0-9]>_<config stem>.raw.log"

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
relocated_env="$TEST_ROOT/relocated/relocated.source.env"
stage_example "$relocated_example" "$relocated_env"
[[ ! -e "$relocated_root" ]] || fail "staging the relocated example wrote to $relocated_root on this machine"
relocated_config="$(example_value TQ_CONFIG_PATH "$relocated_env")"
[[ "$relocated_config" == "$TEST_ROOT$relocated_root/repo/"* && -f "$relocated_config" ]] || \
  fail "the relocated config was not created below the test root: $relocated_config"
fill_env "$relocated_env" "$TEST_ROOT/relocated/relocated.env" ''
"$SETUP" --render-only "$TEST_ROOT/relocated/render" --env-file "$TEST_ROOT/relocated/relocated.env" >/dev/null || \
  fail 'the relocated example does not render'
rg -q -F "\"$(example_value TQ_RAW_LOG_GLOB "$relocated_env")\"" \
  "$TEST_ROOT/relocated/render/trading-$(example_value TQ_STRATEGY "$relocated_env").alloy" || \
  fail 'the relocated fragment does not tail the relocated glob'
[[ ! -e "$relocated_root" ]] || fail "rendering the relocated example wrote to $relocated_root on this machine"

printf 'case: a path that climbs out of the test root is refused before anything is created\n'
climb=''
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32; do
  climb+='../'
done
escape_example="$TEST_ROOT/relocated/deployment-linux-escape.env.example"
cp "$base_example" "$escape_example"
set_env_value "$escape_example" TQ_CONFIG_PATH "/climb/${climb%/}$OUTSIDE/config/escape.yaml"
before_escape="$(tree_listing)"
if (stage_example "$escape_example" "$TEST_ROOT/relocated/escape.source.env") >"$TEST_ROOT/escape.out" 2>&1; then
  fail 'an example whose config path resolves outside the test root was staged'
fi
rg -q -F 'outside the test root' "$TEST_ROOT/escape.out" || {
  cat "$TEST_ROOT/escape.out" >&2
  fail 'the escaping example was refused for another reason'
}
[[ -z "$(ls -A "$OUTSIDE")" ]] || fail 'staging wrote outside the test root'
[[ "$(tree_listing | grep -vxF -e "$TEST_ROOT/escape.out" -e "$TEST_ROOT/relocated/escape.source.env")" == \
  "$before_escape" ]] || fail 'the refused example left directories behind'

printf 'PASS: %d Linux instance examples, %d of them with an inventory row\n' "${#EXAMPLES[@]}" "$rows_compared"
