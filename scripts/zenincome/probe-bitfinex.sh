#!/usr/bin/env bash
# probe-bitfinex.sh — diagnose Bitfinex private API key for ZenIncome.
#
# Use when SkyEye fires ZenIncomeBitfinexAuthFail or ZenIncomeOfferGenerationStuck.
# Distinguishes between common failure modes:
#   - SECRET wrong         → HMAC digest invalid
#   - KEY revoked / wrong  → apikey invalid / not found
#   - Permission missing   → 403 / permission denied
#   - Server flaky         → mixed 200 / 5xx
#   - Nonce race           → script can't reproduce; if A all 200 and prod still
#                            errors, suspect concurrent callers sharing one key
#
# Usage:
#   export BFX_API_KEY=...
#   export BFX_API_SECRET=...
#   bash scripts/zenincome/probe-bitfinex.sh        # default 5 calls
#   N_CALLS=10 bash scripts/zenincome/probe-bitfinex.sh
#
# This script is READ-ONLY (only hits /v2/auth/r/wallets). It does NOT modify
# any state, does NOT notify anyone, does NOT touch SkyEye config.

set -euo pipefail

: "${BFX_API_KEY:?BFX_API_KEY required (set via env)}"
: "${BFX_API_SECRET:?BFX_API_SECRET required (set via env)}"

API_HOST="https://api.bitfinex.com"
API_PATH="/v2/auth/r/wallets"
N_CALLS="${N_CALLS:-5}"

mk_nonce() { date +%s%N | cut -c1-13; }

# Returns "BODY|HTTP_CODE" on stdout. Body has no trailing newline.
call_once() {
  local nonce="$1"
  export SIG_PAYLOAD="/api${API_PATH}${nonce}"
  local sig
  sig=$(python3 -c '
import hmac, hashlib, os
secret = os.environ["BFX_API_SECRET"].encode()
payload = os.environ["SIG_PAYLOAD"]
print(hmac.new(secret, payload.encode(), hashlib.sha384).hexdigest())
')
  curl -sS -m 10 -w '|%{http_code}' -X POST "${API_HOST}${API_PATH}" \
    -H "bfx-apikey: ${BFX_API_KEY}" \
    -H "bfx-nonce: ${nonce}" \
    -H "bfx-signature: ${sig}" \
    -H "Content-Type: application/json" \
    -d ""
}

declare -a http_codes=()
last_body=""

echo "==> Probing ${N_CALLS} sequential calls to ${API_PATH}"
echo
for i in $(seq 1 "$N_CALLS"); do
  n=$(mk_nonce)
  raw=$(call_once "$n" || echo "|000")
  http="${raw##*|}"
  body="${raw%|*}"
  http_codes+=("$http")
  last_body="$body"
  printf '  [%d/%d] nonce=%s HTTP=%s | %s\n' \
    "$i" "$N_CALLS" "$n" "$http" "${body:0:100}"
  sleep 0.3
done

echo
echo "════════════════════════════════════════════════════════"
echo "    診斷結果"
echo "════════════════════════════════════════════════════════"

ok=0; fail=0
for h in "${http_codes[@]}"; do
  if [[ "$h" == "200" ]]; then ((ok++)); else ((fail++)); fi
done

echo "  成功: ${ok}/${N_CALLS}    失敗: ${fail}/${N_CALLS}"
echo

# All success
if (( fail == 0 )); then
  cat <<'EOF'
✅ 全部成功 — key/secret 本身完全沒問題。

  ZenIncome production 仍持續吐 ERROR 的可能原因（按機率）：

  1. 多個 process / goroutine 共用同一把 key → nonce race
     檢查：在 ZenIncome 機器執行
       systemctl status zenincome
       ps -ef | grep -i zenincome | grep -v grep
     確認只有 1 個 main process 在跑。
     看 follower.go 產 nonce 的邏輯，需要：
       - sync.Mutex 包住 nonce 產生 + send 整段，OR
       - atomic.AddInt64 確保單調遞增

  2. Bitfinex server 偶發 5xx
     確認方法：把 follower retry log 拿出來，看是否 5xx 出現的時候
     timestamp 跟 Bitfinex statusapi.bitfinex.com 上的 incident 對得上

  3. 你的 ZenIncome 跑的 key 跟你執行此 script 的 key 不同
     確認：sudo systemctl show zenincome -p Environment | grep -i bfx
     比對其中的 BFX_API_KEY 跟你目前 export 的是否同一把
EOF
  exit 0
fi

# All failed — interpret last error body
if (( ok == 0 )); then
  echo "❌ ${N_CALLS}/${N_CALLS} 全失敗。Last response body："
  echo "    ${last_body}"
  echo
  case "$last_body" in
    *"digest invalid"*|*"10100"*)
      cat <<'EOF'
  根因：HMAC 簽章對不上 → API SECRET 不正確
  做法：
    1. 確認 ZenIncome 拿到的 SECRET 跟 Bitfinex 後台一致
       特別注意：複製貼上多了空白 / 換行 / encoding 不對
    2. 若 secret 確實一致仍失敗 → Bitfinex 後台重生一把 key+secret
       (Bitfinex → API → Create New Key, 勾 Account History: Read Wallets)
    3. 更新 ZenIncome 的 systemd env 後 systemctl restart zenincome
EOF
      ;;
    *"apikey: invalid"*|*"10010"*|*"key not found"*)
      cat <<'EOF'
  根因：API KEY 已被撤銷或不存在
  做法：
    1. 到 Bitfinex 後台 (API → Active Keys) 確認此 key 還在
    2. 不在 → 重生一把，更新 ZenIncome systemd env 後 restart
    3. 在 → 看是否被停用 (Status: Disabled)，重新啟用即可
EOF
      ;;
    *"permission"*|*"403"*|*"unauthorized"*)
      cat <<'EOF'
  根因：API key 權限不足
  做法：
    Bitfinex 後台對該 key 確認勾選：
      Account History → Wallets: Read
    若沒勾 → 改設定後保存即可（不需要重生 key）
EOF
      ;;
    *)
      cat <<'EOF'
  根因不明（不在已知 auth 失敗 pattern 裡）
  做法：
    1. 看 raw response body 自行判斷
    2. 對照 Bitfinex error code 表：
       https://docs.bitfinex.com/docs/abbreviations-glossary#errorinfo-codes
    3. 若是 5xx，可能是 Bitfinex server 出問題，等一下再試
EOF
      ;;
  esac
  exit 2
fi

# Mixed (some pass, some fail)
cat <<EOF
⚠️ 行為不穩定 (${ok} 成功 / ${fail} 失敗)。

  最可能原因：
  - Bitfinex server 偶發 5xx
  - 你跟其他 process 共用 key，互相打架 nonce

  排查：
  - 看上面表格 HTTP code 分布；若失敗都是 5xx → 對方端問題
  - 若失敗都是 'nonce' / '10114' → 同把 key 被多個來源用
EOF
exit 1
