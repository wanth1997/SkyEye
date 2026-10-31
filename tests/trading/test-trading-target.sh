#!/usr/bin/env bash
set -euo pipefail

# Exercises scripts/trading-target against temporary copies of the inventory:
# deterministic add/remove, idempotency, refusal paths, canonical checks, and
# a promtool run of the derived test after a dry-run add and remove.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOL="$REPO_ROOT/scripts/trading-target"
INVENTORY="$REPO_ROOT/prometheus/rules/trading-targets.yml"
FIXTURE="$REPO_ROOT/prometheus/rules/tests/fixtures/trading-targets.yml"
PROM_RULES="$REPO_ROOT/prometheus/rules/trading.yml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$TOOL" ]] || fail "scripts/trading-target must be executable"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/skyeye-trading-target.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
COPY="$WORK/trading-targets.yml"
ORIGINAL="$WORK/original.yml"
cp "$INVENTORY" "$COPY"
cp "$INVENTORY" "$ORIGINAL"
tool() {
  "$TOOL" --file "$COPY" "$@"
}
assert_unchanged() {
  cmp -s "$1" "$COPY" || fail "$2"
}

printf 'case: committed inventory and rule fixture are canonical\n'
"$TOOL" check "$INVENTORY" "$FIXTURE" >/dev/null || fail "committed inventory is not canonical"

printf 'case: dry-run add prints the result without writing\n'
dry_output="$(tool add --server trading02 --strategy dry-run-btc --dry-run)"
[[ "$dry_output" == *"strategy: dry-run-btc"* ]] || fail "dry-run add did not print the new row"
assert_unchanged "$ORIGINAL" "dry-run add wrote the inventory"

printf 'case: add appends exactly one canonical shadow row\n'
add_output="$(tool add --server trading02 --strategy new-lane-btc)"
[[ "$add_output" == "added: trading_target_info server_id=trading02 strategy=new-lane-btc quote=USDT" ]] || \
  fail "unexpected add output: $add_output"
original_size="$(wc -c <"$ORIGINAL" | tr -d ' ')"
head -c "$original_size" "$COPY" | cmp -s - "$ORIGINAL" || fail "add rewrote existing rows instead of appending"
expected_tail="$(printf '%s\n' \
  '' \
  '      - record: trading_target_info' \
  '        expr: vector(1)' \
  '        labels:' \
  '          product: tnauqquant' \
  '          environment: production' \
  '          server_id: trading02' \
  '          strategy: new-lane-btc' \
  '          notification_mode: shadow' \
  '          quote_currency: USDT')"
actual_tail="$(tail -c "+$((original_size + 1))" "$COPY")"
[[ "$actual_tail" == "$expected_tail" ]] || fail "added stanza is not canonical:
$actual_tail"
tool check >/dev/null || fail "inventory is not canonical after add"
cp "$COPY" "$WORK/after-add.yml"

printf 'case: repeating an add is a no-op\n'
repeat_output="$(tool add --server trading02 --strategy new-lane-btc)"
[[ "$repeat_output" == already\ present:* ]] || fail "repeated add did not report a no-op"
assert_unchanged "$WORK/after-add.yml" "repeated add changed the inventory"

printf 'case: conflicting and invalid adds are refused without writing\n'
if tool add --server trading02 --strategy new-lane-btc --quote USDC >/dev/null 2>&1; then
  fail "add accepted a conflicting row for an existing identity"
fi
for bad_args in \
  "--server bad_id! --strategy x" \
  "--server -lead --strategy x" \
  "--server trading02 --strategy has.space\ x" \
  "--server trading02 --strategy x --quote usdt"
do
  # Word splitting builds each argument vector on purpose.
  # shellcheck disable=SC2086
  if eval tool add $bad_args >/dev/null 2>&1; then
    fail "add accepted invalid arguments: $bad_args"
  fi
done
assert_unchanged "$WORK/after-add.yml" "a refused add changed the inventory"

printf 'case: YAML-ambiguous values are quoted and round-trip\n'
tool add --server trading02 --strategy 2026 --history >/dev/null
rg -q -F '          strategy: "2026"' "$COPY" || fail "numeric strategy was not quoted"
rg -q -F '          history_capable: "true"' "$COPY" || fail "--history did not set history_capable"
tool check >/dev/null || fail "quoted values do not round-trip canonically"
[[ "$(tool list | awk -F'\t' '$2 == "2026" { print $4 }')" == "true" ]] || \
  fail "list does not report the history-capable row"

printf 'case: remove restores the previous inventory byte for byte\n'
tool remove --server trading02 --strategy 2026 >/dev/null
assert_unchanged "$WORK/after-add.yml" "removing the quoted row did not restore the file"
tool remove --server trading02 --strategy new-lane-btc >/dev/null
assert_unchanged "$ORIGINAL" "add followed by remove is not byte-identical"

printf 'case: repeating a remove is a no-op\n'
remove_output="$(tool remove --server trading02 --strategy new-lane-btc)"
[[ "$remove_output" == not\ present:* ]] || fail "repeated remove did not report a no-op"
assert_unchanged "$ORIGINAL" "repeated remove changed the inventory"

printf 'case: remove also drops a legacy alias for the same identity\n'
legacy_identity="$("$TOOL" --file "$COPY" list --all-records |
  awk -F'\t' '$1 == "tnauqquant_target_info" { print $2 "\t" $3; exit }')"
if [[ -n "$legacy_identity" ]]; then
  legacy_server="${legacy_identity%%$'\t'*}"
  legacy_strategy="${legacy_identity#*$'\t'}"
  cp "$COPY" "$WORK/legacy.yml"
  "$TOOL" --file "$WORK/legacy.yml" remove --server "$legacy_server" --strategy "$legacy_strategy" >/dev/null
  if "$TOOL" --file "$WORK/legacy.yml" list --all-records | awk -F'\t' -v s="$legacy_strategy" '$3 == s' | grep -q .; then
    fail "remove left a row for $legacy_strategy"
  fi
  "$TOOL" check "$WORK/legacy.yml" >/dev/null || fail "inventory is not canonical after legacy removal"
fi

printf 'case: check rejects hand edits the tool would not produce\n'
reject() {
  local label="$1"
  local file="$WORK/reject.yml"
  cat >"$file"
  if "$TOOL" check "$file" >/dev/null 2>&1; then
    fail "check accepted $label"
  fi
}
sed 's/notification_mode: shadow/notification_mode: paging/' "$ORIGINAL" | reject "a paging row"
sed 's/quote_currency: USDT$/quote_currency: USDT /' "$ORIGINAL" | reject "trailing whitespace"
awk '/server_id:/ && !done { hold = $0; getline; print; print hold; done = 1; next } { print }' \
  "$ORIGINAL" | reject "reordered labels"
{ cat "$ORIGINAL"; printf '\n'; sed -n '/^      - record: trading_target_info$/,$p' "$ORIGINAL" | sed -n '1,9p'; } | \
  reject "a duplicate identity"
sed 's/expr: vector(1)/expr: vector(2)/' "$ORIGINAL" | reject "a changed expression"
printf 'groups: []\n' | reject "a foreign layout"

render_and_run() {
  local inventory="$1"
  local label="$2"
  local bundle="$WORK/bundle-$label"
  rm -rf "$bundle"
  mkdir -p "$bundle"
  cp "$inventory" "$bundle/trading-targets.yml"
  cp "$PROM_RULES" "$bundle/trading.yml"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    "$TOOL" --file "$bundle/trading-targets.yml" render-test \
      --rule-file /tmp/work/trading-targets.yml --rule-file /tmp/work/trading.yml \
      --output "$bundle/derived.test.yml"
    # Stream the bundle so no host bind mount of a temp directory is needed.
    tar -C "$bundle" -cf - . | docker run --rm -i --entrypoint /bin/sh prom/prometheus:v2.54.1 \
      -c 'mkdir -p /tmp/work && tar -xf - -C /tmp/work && promtool test rules /tmp/work/derived.test.yml' \
      >"$bundle/promtool.log" 2>&1 || {
        cat "$bundle/promtool.log" >&2
        fail "derived promtool test failed for $label inventory"
      }
  elif command -v promtool >/dev/null 2>&1; then
    "$TOOL" --file "$bundle/trading-targets.yml" render-test --output "$bundle/derived.test.yml"
    promtool test rules "$bundle/derived.test.yml" >"$bundle/promtool.log" 2>&1 || {
      cat "$bundle/promtool.log" >&2
      fail "derived promtool test failed for $label inventory"
    }
  else
    printf 'SKIP: docker/promtool unavailable; derived %s test was rendered only\n' "$label"
    "$TOOL" --file "$bundle/trading-targets.yml" render-test >/dev/null
    return 0
  fi
}

printf 'case: derived promtool test follows a dry-run add and remove\n'
cp "$ORIGINAL" "$WORK/dry-add.yml"
"$TOOL" --file "$WORK/dry-add.yml" add --server trading02 --strategy dry-lane-btc >/dev/null
"$TOOL" --file "$WORK/dry-add.yml" add --server trading02 --strategy dry-history-btc --history >/dev/null
derived_add="$("$TOOL" --file "$WORK/dry-add.yml" render-test)"
[[ "$derived_add" == *'strategy="dry-lane-btc"'* && "$derived_add" == *'strategy="dry-history-btc"'* ]] || \
  fail "derived test does not follow the added rows"
render_and_run "$WORK/dry-add.yml" add

first_row="$("$TOOL" --file "$ORIGINAL" list | head -n 1)"
cp "$ORIGINAL" "$WORK/dry-remove.yml"
"$TOOL" --file "$WORK/dry-remove.yml" remove \
  --server "$(cut -f1 <<<"$first_row")" --strategy "$(cut -f2 <<<"$first_row")" >/dev/null
derived_remove="$("$TOOL" --file "$WORK/dry-remove.yml" render-test)"
[[ "$derived_remove" != *"strategy=\"$(cut -f2 <<<"$first_row")\""* ]] || \
  fail "derived test still expects the removed row"
render_and_run "$WORK/dry-remove.yml" remove

printf 'PASS: scripts/trading-target inventory management\n'
