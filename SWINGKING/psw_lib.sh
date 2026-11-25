# PSW — one-shot swing OB limits (sourced from swingking.sh after load_env.sh).
# Requires: SYMBOL, BUY_MAGIC, SELL_MAGIC, MT5_CMD, PSW_* from env.

psw_mt5_retry() {
  local attempt=1 out exitcode
  while true; do
    exitcode=0
    out=$("$MT5" "$@" 2>&1) || exitcode=$?
    if [[ $exitcode -eq 0 ]]; then
      printf '%s\n' "$out"
      return 0
    fi
    if [[ "$out" == *"timed out"* || "$out" == *"curl: (28)"* ]]; then
      echo "psw: timeout (attempt $attempt), retry in ${RETRY_DELAY}s: $MT5 $*" >&2
      attempt=$((attempt + 1))
      sleep "${RETRY_DELAY:-5}"
      continue
    fi
    echo "$out" >&2
    return "$exitcode"
  done
}

_PSW_DIGITS=""

psw_round_price() {
  local price="$1" raw
  if [[ -z "$_PSW_DIGITS" ]]; then
    raw=$(psw_mt5_retry get_price "$SYMBOL") || return 1
    _PSW_DIGITS=$(echo "$raw" | jq -er '.digits // 2')
  fi
  awk -v p="$price" -v d="$_PSW_DIGITS" 'BEGIN { printf "%.*f", d, p + 0 }'
}

psw_state_file() {
  echo "${PSW_STATE_FILE:-${OUT_DIR:-./zones}/.psw_deployed}"
}

psw_already_deployed() {
  local sf
  sf=$(psw_state_file)
  [[ -f "$sf" ]] && return 0
  return 1
}

psw_mark_deployed() {
  local sf
  sf=$(psw_state_file)
  mkdir -p "$(dirname "$sf")"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$sf"
}

psw_clear_state() {
  local sf
  sf=$(psw_state_file)
  rm -f "$sf"
}

# Manual ack: e.g. buy_stop @ PSW_ACK_VOLUME (not PRIMARY / grid / PSW system orders).
find_psw_ack_ticket() {
  local raw vol eps ack_type
  vol="${PSW_ACK_VOLUME:-0.14}"
  eps="${PSW_ACK_VOL_EPS:-0.001}"
  ack_type="${PSW_ACK_ORDER_TYPE:-buy_stop}"
  raw=$(psw_mt5_retry get_orders "$SYMBOL") || return 1
  echo "$raw" | jq -er --arg t "$ack_type" --argjson v "$vol" --argjson e "$eps" \
    --arg c "${PSW_COMMENT:-PSW}" '
    [.orders[]?
      | select(.type == $t)
      | select((.volume - $v | if . < 0 then -. else . end) <= $e)
      | select((.comment // "") != $c)
      | select((.comment // "") | test("^L[0-9]+$") | not)
    ][0].ticket // empty'
}

psw_flat() {
  local pos ord c="${PSW_COMMENT:-PSW}"
  pos=$(psw_mt5_retry get_positions "$SYMBOL") || return 1
  if echo "$pos" | jq -e --arg c "$c" '[.positions[]? | select(.comment == $c)] | length > 0' >/dev/null; then
    return 1
  fi
  ord=$(psw_mt5_retry get_orders "$SYMBOL") || return 1
  if echo "$ord" | jq -e --arg c "$c" '[.orders[]? | select(.comment == $c)] | length > 0' >/dev/null; then
    return 1
  fi
  return 0
}

cancel_psw_pendings() {
  local ord ticket
  ord=$(psw_mt5_retry get_orders "$SYMBOL") || return 0
  while IFS= read -r ticket; do
    [[ -n "$ticket" && "$ticket" != "null" ]] || continue
    echo "cancel PSW pending ticket $ticket"
    psw_mt5_retry close_order "$ticket" >/dev/null || true
    ord=$(psw_mt5_retry get_orders "$SYMBOL") || break
  done < <(echo "$ord" | jq -r --arg c "${PSW_COMMENT:-PSW}" \
    '.orders[]? | select(.comment == $c) | .ticket')
}

place_psw_ob_limits() {
  local zones_json="$1" buy_px sell_px vol tp c
  c="${PSW_COMMENT:-PSW}"
  vol="${PSW_VOLUME:-$PRIMARY_VOLUME}"
  tp="${PSW_TP_POINTS:-2000}"

  buy_px=$(echo "$zones_json" | jq -er '.buy_zones[0].mid // empty') || {
    echo "no active buy OB — cannot place PSW buy_limit" >&2
    buy_px=""
  }
  sell_px=$(echo "$zones_json" | jq -er '.sell_zones[0].mid // empty') || {
    echo "no active sell OB — cannot place PSW sell_limit" >&2
    sell_px=""
  }

  [[ -n "$buy_px" ]] && buy_px=$(psw_round_price "$buy_px")
  [[ -n "$sell_px" ]] && sell_px=$(psw_round_price "$sell_px")

  if [[ -n "$buy_px" ]]; then
    echo "PSW buy_limit @ $buy_px vol=$vol magic=$BUY_MAGIC TP=${tp}pts comment=$c"
    psw_mt5_retry open_order "$SYMBOL" buy_limit "$vol" "$buy_px" "$BUY_MAGIC" 0 "$tp" "$c"
  fi
  if [[ -n "$sell_px" ]]; then
    echo "PSW sell_limit @ $sell_px vol=$vol magic=$SELL_MAGIC TP=${tp}pts comment=$c"
    psw_mt5_retry open_order "$SYMBOL" sell_limit "$vol" "$sell_px" "$SELL_MAGIC" 0 "$tp" "$c"
  fi

  [[ -n "$buy_px" || -n "$sell_px" ]]
}