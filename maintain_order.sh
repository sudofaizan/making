#!/bin/bash
# PRIMARY pending @ EMA; trail winning PRIMARY position SL to EMA when +POINTS_PROFIT_MIN pts.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
# shellcheck source=load_env.sh
source "${SCRIPT_DIR}/load_env.sh"

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

price_differs() {
  local order_price="$1" ema_price="$2"
  awk -v a="$order_price" -v b="$ema_price" -v e="$PRICE_EPS" \
    'BEGIN { d = a - b; if (d < 0) d = -d; exit (d >= e) ? 0 : 1 }'
}

orders_has_primary_at() {
  local orders_raw="$1" otype="$2" magic="$3" target_price="$4"
  echo "$orders_raw" | jq -e \
    --arg c "$COMMENT" --arg t "$otype" --argjson m "$magic" \
    --arg p "$target_price" --argjson e "$PRICE_EPS" \
    --argjson vmin "$PRIMARY_VOLUME_MIN" --argjson vmax "$PRIMARY_VOLUME_MAX" \
    '[.orders[]? | select(
      .comment == $c and .type == $t and .magic == $m
      and ((.volume | tonumber) >= $vmin and (.volume | tonumber) <= $vmax)
      and (((.price - ($p | tonumber)) * (.price - ($p | tonumber))) <= ($e * $e))
    )] | length > 0' >/dev/null
}

primary_order_count() {
  local orders_raw="$1"
  echo "$orders_raw" | jq -r \
    --arg c "$COMMENT" --argjson buy "$BUY_MAGIC" --argjson sell "$SELL_MAGIC" \
    --argjson vmin "$PRIMARY_VOLUME_MIN" --argjson vmax "$PRIMARY_VOLUME_MAX" \
    '[.orders[]? | select(
      .comment == $c
      and ((.magic == $buy) or (.magic == $sell))
      and ((.volume | tonumber) >= $vmin and (.volume | tonumber) <= $vmax)
    )] | length'
}

list_primary_orders() {
  local orders_raw="$1"
  echo "$orders_raw" | jq -c \
    --arg c "$COMMENT" --argjson buy "$BUY_MAGIC" --argjson sell "$SELL_MAGIC" \
    --argjson vmin "$PRIMARY_VOLUME_MIN" --argjson vmax "$PRIMARY_VOLUME_MAX" \
    '.orders[]? | select(
      .comment == $c
      and ((.magic == $buy) or (.magic == $sell))
      and ((.volume | tonumber) >= $vmin and (.volume | tonumber) <= $vmax)
    )'
}

maintain_tick() {
  local ema_raw orders_raw ema_price count
  ema_raw=$(mt5_retry get_ema "$SYMBOL" "$PERIOD" "$METHOD" "$EMA_TIMEFRAME" "$EMA_CANDLE_COUNT") || return 1
  ema_price=$(echo "$ema_raw" | jq -er .value) || return 1

  orders_raw=$(fetch_orders) || return 1
  if ! echo "$orders_raw" | jq -e .ok >/dev/null; then
    echo "get_orders not ok" >&2
    return 1
  fi

  count=$(primary_order_count "$orders_raw")
  if [[ "$count" -eq 0 ]]; then
    echo "no PRIMARY ${PRIMARY_VOLUME} pending (magic ${BUY_MAGIC}/${SELL_MAGIC}) — EMA ${ema_price}"
    return 0
  fi

  echo "[$RUN_TAG] EMA ${PERIOD} ${METHOD}: ${ema_price} — checking ${count} PRIMARY order(s)"

  local rows=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && rows+=("$line")
  done < <(list_primary_orders "$orders_raw")

  local row ticket otype magic oprice
  for row in "${rows[@]}"; do
    ticket=$(echo "$row" | jq -r .ticket)
    otype=$(echo "$row" | jq -r .type)
    magic=$(echo "$row" | jq -r .magic)
    oprice=$(echo "$row" | jq -r .price)

    orders_raw=$(fetch_orders) || continue
    if ! price_differs "$oprice" "$ema_price"; then
      echo "ok ticket $ticket $otype @ $oprice (within ${PRICE_EPS} of EMA)"
      continue
    fi

    if orders_has_primary_at "$orders_raw" "$otype" "$magic" "$ema_price"; then
      echo "cancel stale ticket $ticket $otype magic $magic @ $oprice — already at EMA"
      mt5_retry close_order "$ticket" >/dev/null || echo "warn: close_order $ticket failed" >&2
      continue
    fi

    echo "reprice ticket $ticket $otype magic $magic: $oprice -> $ema_price"
    mt5_retry close_order "$ticket" >/dev/null || {
      echo "warn: close_order $ticket failed" >&2
      continue
    }

    orders_raw=$(fetch_orders) || continue
    if orders_has_primary_at "$orders_raw" "$otype" "$magic" "$ema_price"; then
      echo "skip place $otype magic $magic — active order already at EMA ${ema_price}"
      continue
    fi

    if echo "$orders_raw" | jq -e \
      --arg t "$otype" --argjson m "$magic" --arg p "$ema_price" --argjson e "$PRICE_EPS" \
      '[.orders[]? | select(
        .type == $t and .magic == $m
        and (((.price - ($p | tonumber)) * (.price - ($p | tonumber))) <= ($e * $e))
      )] | length > 0' >/dev/null; then
      echo "skip place $otype @ $ema_price — pending order at price (magic $magic)"
      continue
    fi

    mt5_retry open_order "$SYMBOL" "$otype" "$PRIMARY_VOLUME" "$ema_price" "$magic" 0 0 "$COMMENT"
  done

  trail_winning_primaries
}

echo "[$RUN_TAG] maintain_order: orders→EMA; trail SL=EMA when PRIMARY profit >= ${POINTS_PROFIT_MIN} pts (loop ${LOOP_SLEEP}s)"
while true; do
  maintain_tick || echo "warn: tick failed — retry next loop" >&2
  sleep "$LOOP_SLEEP"
done