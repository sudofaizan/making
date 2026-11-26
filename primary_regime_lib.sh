# Shared PRIMARY regime pendings at EMA (init + maintain_order).
# Requires load_env.sh: SYMBOL, COMMENT, BUY_MAGIC, SELL_MAGIC, PRIMARY_VOLUME, PRICE_EPS, …
# Caller sets MT5 or MT5_CMD and optional mt5_retry wrapper; default: direct "$MT5_CMD" or "$MT5".

_mt5_primary() {
  if declare -F mt5_retry >/dev/null 2>&1; then
    mt5_retry "$@"
  else
    local m="${MT5_CMD:-${MT5:-./mt5}}"
    "$m" "$@"
  fi
}

json_ok_positions() {
  local raw="$1"
  echo "$raw" | jq -e .ok >/dev/null 2>&1
}

primary_regime_mid_price() {
  local price_json="$1"
  echo "$price_json" | jq -er 'if (.last | tonumber) > 0 then .last else (.bid + .ask) / 2 end'
}

# Broker digits/point for SYMBOL (cached per sync tick).
_SYMBOL_DIGITS=""
_SYMBOL_POINT=""

load_symbol_quote_spec() {
  local raw
  raw=$(_mt5_primary get_price "$SYMBOL") || return 1
  _SYMBOL_DIGITS=$(echo "$raw" | jq -er '.digits // 2')
  _SYMBOL_POINT=$(echo "$raw" | jq -er '.point // 0.01')
}

round_to_symbol_digits() {
  local price="$1"
  [[ -n "$_SYMBOL_DIGITS" ]] || load_symbol_quote_spec || return 1
  awk -v p="$price" -v d="$_SYMBOL_DIGITS" 'BEGIN { printf "%.*f", d, p + 0 }'
}

# Prints lines: order_type magic
primary_regime_required_pairs() {
  local mid="$1" ema="$2"
  if awk -v p="$mid" -v e="$ema" 'BEGIN { exit !(p > e) }'; then
    echo "buy_limit $BUY_MAGIC"
    echo "sell_stop $SELL_MAGIC"
  else
    echo "sell_limit $SELL_MAGIC"
    echo "buy_stop $BUY_MAGIC"
  fi
}

orders_has_primary() {
  local orders_raw="$1" otype="$2" magic="$3"
  echo "$orders_raw" | jq -e --arg t "$otype" --argjson m "$magic" --arg c "$COMMENT" \
    --argjson vmin "$PRIMARY_VOLUME_MIN" --argjson vmax "$PRIMARY_VOLUME_MAX" \
    '[.orders[]? | select(
      .type == $t and .magic == $m and .comment == $c
      and ((.volume | tonumber) >= $vmin and (.volume | tonumber) <= $vmax)
    )] | length > 0' >/dev/null
}

primary_order_row() {
  local orders_raw="$1" otype="$2" magic="$3"
  echo "$orders_raw" | jq -c --arg t "$otype" --argjson m "$magic" --arg c "$COMMENT" \
    --argjson vmin "$PRIMARY_VOLUME_MIN" --argjson vmax "$PRIMARY_VOLUME_MAX" \
    '.orders[]? | select(
      .type == $t and .magic == $m and .comment == $c
      and ((.volume | tonumber) >= $vmin and (.volume | tonumber) <= $vmax)
    )' | head -1
}

list_stale_regime_primaries() {
  local orders_raw="$1" mid="$2" ema="$3"
  local required otype magic req_types=()
  while read -r otype magic; do
    [[ -n "$otype" ]] && req_types+=("$otype")
  done < <(primary_regime_required_pairs "$mid" "$ema")

  local req_json
  req_json=$(printf '%s\n' "${req_types[@]}" | jq -R . | jq -s .)
  echo "$orders_raw" | jq -c \
    --arg c "$COMMENT" --argjson buy "$BUY_MAGIC" --argjson sell "$SELL_MAGIC" \
    --argjson vmin "$PRIMARY_VOLUME_MIN" --argjson vmax "$PRIMARY_VOLUME_MAX" \
    --argjson req "$req_json" \
    '.orders[]? | select(
      .comment == $c and ((.magic == $buy) or (.magic == $sell))
      and ((.volume | tonumber) >= $vmin and (.volume | tonumber) <= $vmax)
      and ((.type as $t | any($req[]; . == $t) | not))
    )'
}

price_differs() {
  local order_price="$1" ema_price="$2"
  awk -v a="$order_price" -v b="$ema_price" -v e="$PRICE_EPS" \
    'BEGIN { d = a - b; if (d < 0) d = -d; exit (d >= e) ? 0 : 1 }'
}

any_primary_position_open() {
  local positions_raw="$1"
  echo "$positions_raw" | jq -e --arg c "$COMMENT" --argjson buy "$BUY_MAGIC" --argjson sell "$SELL_MAGIC" \
    --argjson vmin "$PRIMARY_VOLUME_MIN" --argjson vmax "$PRIMARY_VOLUME_MAX" \
    '[.positions[]? | select(
      .comment == $c and ((.magic == $buy) or (.magic == $sell))
      and ((.volume | tonumber) >= $vmin and (.volume | tonumber) <= $vmax)
    )] | length > 0' >/dev/null
}

cancel_all_primary_pendings() {
  local orders_raw="$1" reason="$2"
  local row ticket otype magic
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    ticket=$(echo "$row" | jq -r .ticket)
    otype=$(echo "$row" | jq -r .type)
    magic=$(echo "$row" | jq -r .magic)
    echo "cancel PRIMARY pending ticket $ticket $otype magic $magic ($reason)"
    _mt5_primary close_order "$ticket" >/dev/null || \
      echo "warn: close_order $ticket failed" >&2
  done < <(echo "$orders_raw" | jq -c \
    --arg c "$COMMENT" --argjson buy "$BUY_MAGIC" --argjson sell "$SELL_MAGIC" \
    --argjson vmin "$PRIMARY_VOLUME_MIN" --argjson vmax "$PRIMARY_VOLUME_MAX" \
    '.orders[]? | select(
      .comment == $c and ((.magic == $buy) or (.magic == $sell))
      and ((.volume | tonumber) >= $vmin and (.volume | tonumber) <= $vmax)
    )')
}

# More than one PRIMARY pending on the same leg (otype+magic) — keep best at EMA, cancel the rest.
cancel_duplicate_primary_legs() {
  local orders_raw="$1" mid="$2" ema_px="$3" otype magic
  local rows_json keep_ticket row ticket oprice dist

  while read -r otype magic; do
    [[ -z "$otype" ]] && continue
    rows_json=$(echo "$orders_raw" | jq -c \
      --arg c "$COMMENT" --arg t "$otype" --argjson m "$magic" \
      --argjson vmin "$PRIMARY_VOLUME_MIN" --argjson vmax "$PRIMARY_VOLUME_MAX" \
      '[.orders[]? | select(
        .comment == $c and .type == $t and .magic == $m
        and ((.volume | tonumber) >= $vmin and (.volume | tonumber) <= $vmax)
      )]')
    count=$(echo "$rows_json" | jq 'length')
    (( count <= 1 )) && continue

    keep_ticket=$(echo "$rows_json" | jq -er --argjson ema "$ema_px" --argjson e "$PRICE_EPS" '
      [.[] | {ticket, price: (.price | tonumber), dist: (((.price | tonumber) - $ema) | fabs)}]
      | sort_by(.dist) | .[0].ticket')

    while IFS= read -r row; do
      [[ -z "$row" ]] && continue
      ticket=$(echo "$row" | jq -r .ticket)
      [[ "$ticket" == "$keep_ticket" ]] && continue
      oprice=$(echo "$row" | jq -r .price)
      echo "cancel duplicate PRIMARY $otype magic $magic ticket $ticket @ $oprice (keep $keep_ticket)"
      _mt5_primary close_order "$ticket" >/dev/null || \
        echo "warn: close_order $ticket failed" >&2
    done < <(echo "$rows_json" | jq -c '.[]')
    orders_raw=$(_mt5_primary get_orders "$SYMBOL") || return 1
  done < <(primary_regime_required_pairs "$mid" "$ema_px")

  echo "$orders_raw"
}

orders_has_primary_at_price() {
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

_PRIMARY_SYNC_LOCK="${PID_DIR:-/tmp}/primary_sync.lock"

# EMA pendings only while fully flat (no PRIMARY buy or sell position). Manual delete → both recreated.
sync_primary_regime_at_ema() {
  local ema_price="$1" orders_raw="$2" mid_price="$3"
  mkdir -p "$(dirname "$_PRIMARY_SYNC_LOCK")"

  (
    flock -w 15 9 || {
      echo "warn: primary sync busy (another worker?) — skip tick" >&2
      return 0
    }
    _sync_primary_regime_at_ema_impl "$@"
  ) 9>>"$_PRIMARY_SYNC_LOCK"
}

_sync_primary_regime_at_ema_impl() {
  local ema_price="$1" orders_raw="$2" mid_price="$3"
  local otype magic row ticket oprice stale ema_px positions_raw

  if ! positions_raw=$(_mt5_primary get_positions "$SYMBOL"); then
    echo "warn: get_positions failed — skip PRIMARY pending sync (will not place one leg blind)" >&2
    return 1
  fi
  if ! json_ok_positions "$positions_raw"; then
    echo "warn: positions not ok — skip PRIMARY pending sync" >&2
    return 1
  fi
  if any_primary_position_open "$positions_raw"; then
    echo "PRIMARY deal running — keep flat before EMA pair; cancel pendings only (no buy-only/sell-only place)"
    cancel_all_primary_pendings "$orders_raw" "PRIMARY position open"
    return 0
  fi

  load_symbol_quote_spec || ema_px="$ema_price"
  ema_px=$(round_to_symbol_digits "$ema_price") || ema_px="$ema_price"
  echo "PRIMARY target EMA (raw $ema_price → $ema_px, digits=${_SYMBOL_DIGITS:-?})"

  while IFS= read -r stale; do
    [[ -z "$stale" ]] && continue
    ticket=$(echo "$stale" | jq -r .ticket)
    echo "cancel wrong-regime PRIMARY ticket $ticket $(echo "$stale" | jq -r .type)"
    _mt5_primary close_order "$ticket" >/dev/null || \
      echo "warn: close_order $ticket failed" >&2
  done < <(list_stale_regime_primaries "$orders_raw" "$mid_price" "$ema_px")

  orders_raw=$(_mt5_primary get_orders "$SYMBOL") || return 1
  orders_raw=$(cancel_duplicate_primary_legs "$orders_raw" "$mid_price" "$ema_px") || return 1

  if ! positions_raw=$(_mt5_primary get_positions "$SYMBOL"); then
    echo "warn: get_positions failed after stale cleanup — skip place" >&2
    return 1
  fi
  if any_primary_position_open "$positions_raw"; then
    echo "PRIMARY opened during sync — cancel pendings, no partial place"
    cancel_all_primary_pendings "$orders_raw" "position opened"
    return 0
  fi

  while read -r otype magic; do
    [[ -z "$otype" ]] && continue
    row=$(primary_order_row "$orders_raw" "$otype" "$magic")
    if [[ -z "$row" ]]; then
      if orders_has_primary_at_price "$orders_raw" "$otype" "$magic" "$ema_px"; then
        echo "skip place $otype magic $magic — already at EMA"
        continue
      fi
      echo "place $otype @ $ema_px (magic $magic)"
      _mt5_primary open_order "$SYMBOL" "$otype" "$PRIMARY_VOLUME" "$ema_px" "$magic" 0 0 "$COMMENT"
      orders_raw=$(_mt5_primary get_orders "$SYMBOL") || return 1
      continue
    fi

    ticket=$(echo "$row" | jq -r .ticket)
    oprice=$(echo "$row" | jq -r .price)
    if ! price_differs "$oprice" "$ema_px"; then
      echo "ok ticket $ticket $otype @ $oprice (within ${PRICE_EPS} of EMA)"
      continue
    fi

    if orders_has_primary_at_price "$orders_raw" "$otype" "$magic" "$ema_px"; then
      echo "cancel stale ticket $ticket $otype magic $magic @ $oprice — already at EMA"
      _mt5_primary close_order "$ticket" >/dev/null || echo "warn: close_order $ticket failed" >&2
      continue
    fi

    echo "modify ticket $ticket $otype magic $magic: $oprice -> $ema_px (modifyOrder)"
    if ! _mt5_primary modify_order "$ticket" "$ema_px" - -; then
      echo "warn: modify_order $ticket failed — fallback cancel+place" >&2
      _mt5_primary close_order "$ticket" >/dev/null || {
        echo "warn: close_order $ticket failed" >&2
        continue
      }
      orders_raw=$(_mt5_primary get_orders "$SYMBOL") || return 1
      if orders_has_primary_at_price "$orders_raw" "$otype" "$magic" "$ema_px"; then
        echo "skip place $otype magic $magic — active order already at EMA"
        continue
      fi
      _mt5_primary open_order "$SYMBOL" "$otype" "$PRIMARY_VOLUME" "$ema_px" "$magic" 0 0 "$COMMENT"
    fi
    orders_raw=$(_mt5_primary get_orders "$SYMBOL") || return 1
    orders_raw=$(cancel_duplicate_primary_legs "$orders_raw" "$mid_price" "$ema_px") || return 1
  done < <(primary_regime_required_pairs "$mid_price" "$ema_px")

  return 0
}