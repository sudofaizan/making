#!/bin/bash
# PRIMARY pending @ EMA; trail winning PRIMARY position SL to EMA when +POINTS_PROFIT_MIN pts.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
[[ "${1:-}" == __MAKING_WORKER__* ]] && shift
# shellcheck source=load_env.sh
source "${SCRIPT_DIR}/load_env.sh"
# shellcheck source=primary_regime_lib.sh
# shellcheck source=stats_store.sh
source "${SCRIPT_DIR}/stats_store.sh"
# shellcheck source=primary_regime_lib.sh
source "${SCRIPT_DIR}/primary_regime_lib.sh"

_singleton_lock="${PID_DIR}/maintain_order.singleton"
mkdir -p "$(dirname "$_singleton_lock")"
exec 9>>"$_singleton_lock"
if ! flock -n 9; then
  echo "[${RUN_TAG}] maintain_order: duplicate instance — exit (use init.sh stop/start)"
  exit 0
fi

MT5="$MT5_CMD"
[[ -x "$MT5" ]] || MT5="$(command -v mt5 2>/dev/null || true)"

mt5_retry() {
  local attempt=1 out exitcode
  while true; do
    exitcode=0
    out=$("$MT5" "$@" 2>&1) || exitcode=$?
    if [[ $exitcode -eq 0 ]]; then
      printf '%s\n' "$out"
      return 0
    fi
    if [[ "$out" == *"timed out"* || "$out" == *"curl: (28)"* ]]; then
      echo "timeout (attempt $attempt), retry in ${RETRY_DELAY}s: $MT5 $*" >&2
      attempt=$((attempt + 1))
      sleep "$RETRY_DELAY"
      continue
    fi
    echo "$out" >&2
    return "$exitcode"
  done
}

fetch_orders() {
  mt5_retry get_orders "$SYMBOL"
}

fetch_positions() {
  mt5_retry get_positions "$SYMBOL"
}

position_favor_points() {
  local row="$1" point="$2"
  echo "$row" | jq -r --argjson pt "$point" \
    'if .type == "buy" then ((.price_current - .price_open) / $pt)
     elif .type == "sell" then ((.price_open - .price_current) / $pt)
     else 0 end'
}

list_primary_positions() {
  local positions_raw="$1"
  echo "$positions_raw" | jq -c \
    --arg c "$COMMENT" --argjson buy "$BUY_MAGIC" --argjson sell "$SELL_MAGIC" \
    '.positions[]? | select(
      .comment == $c and ((.magic == $buy) or (.magic == $sell))
    )'
}

trail_winning_primaries() {
  local ema_price positions_raw point rows=() row ticket pts profit sl
  local ema_raw
  ema_raw=$(mt5_retry get_ema "$SYMBOL" "$PERIOD" "$METHOD" "$EMA_TIMEFRAME" "$EMA_CANDLE_COUNT") || return 0
  ema_price=$(echo "$ema_raw" | jq -er .value) || return 0

  positions_raw=$(fetch_positions) || return 0
  if ! echo "$positions_raw" | jq -e .ok >/dev/null; then
    return 0
  fi

  point=$("$MT5" get_price "$SYMBOL" | jq -er .point) || return 0

  while IFS= read -r line; do
    [[ -n "$line" ]] && rows+=("$line")
  done < <(list_primary_positions "$positions_raw")

  [[ ${#rows[@]} -eq 0 ]] && return 0

  for row in "${rows[@]}"; do
    profit=$(echo "$row" | jq -r .profit)
    pts=$(position_favor_points "$row" "$point")
    ticket=$(echo "$row" | jq -r .ticket)
    sl=$(echo "$row" | jq -r .sl)

    if [[ -z "$profit" || "$profit" == "null" ]]; then
      continue
    fi
    if [[ "$(echo "$profit <= 0" | bc -l)" -eq 1 ]]; then
      echo "trail skip ticket $ticket — PRIMARY losing (profit $profit), TC grid handles"
      continue
    fi
    if [[ -z "$pts" ]] || [[ "$(echo "$pts < $POINTS_PROFIT_MIN" | bc -l)" -eq 1 ]]; then
      echo "trail skip ticket $ticket — profit ${profit} but ${pts:-0} pts < ${POINTS_PROFIT_MIN}"
      continue
    fi

    if ! price_differs "$sl" "$ema_price"; then
      echo "trail ok ticket $ticket SL @ $sl (EMA $ema_price)"
      continue
    fi

    echo "trail ticket $ticket: SL $sl -> $ema_price (profit $profit, ${pts} pts), TP=0"
    mt5_retry modify_position "$ticket" "$ema_price" 0 || \
      echo "warn: modify_position $ticket failed" >&2
  done
}

maintain_tick() {
  local ema_raw orders_raw ema_price price_json mid_price regime
  ema_raw=$(mt5_retry get_ema "$SYMBOL" "$PERIOD" "$METHOD" "$EMA_TIMEFRAME" "$EMA_CANDLE_COUNT") || return 1
  ema_price=$(echo "$ema_raw" | jq -er .value) || return 1

  orders_raw=$(fetch_orders) || return 1
  if ! echo "$orders_raw" | jq -e .ok >/dev/null; then
    echo "get_orders not ok" >&2
    return 1
  fi

  price_json=$(mt5_retry get_price "$SYMBOL") || return 1
  mid_price=$(primary_regime_mid_price "$price_json") || return 1

  if awk -v p="$mid_price" -v e="$ema_price" 'BEGIN { exit !(p > e) }'; then
    regime="above EMA → buy_limit + sell_stop"
  else
    regime="at/below EMA → sell_limit + buy_stop"
  fi
  echo "[$RUN_TAG] EMA ${PERIOD} ${METHOD}: ${ema_price} | mid: ${mid_price} | ${regime}"

  sync_primary_regime_at_ema "$ema_price" "$orders_raw" "$mid_price" || return 1
  trail_winning_primaries
}

echo "[$RUN_TAG] maintain_order: orders→EMA; trail SL=EMA when PRIMARY profit >= ${POINTS_PROFIT_MIN} pts (loop ${LOOP_SLEEP}s)"
while true; do
  maintain_tick || echo "warn: tick failed — retry next loop" >&2
  sleep "$LOOP_SLEEP"
done