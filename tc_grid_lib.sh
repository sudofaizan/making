# Source from TC_BUY.sh / TC_SELL.sh after load_env.sh (SYMBOL, GAP, MAGIC, SIDE, TARGETBASKET, …).

# Best/worst unrealized basket PnL since last close_grid_basket (resets each session).
SESSION_BEST_FLOAT=""
SESSION_WORST_FLOAT=""
SESSION_START=0
LAST_GRID_PLACE_COMMENT=""
LAST_GRID_PLACE_TS=0
_CACHE_POS_JSON=""
_CACHE_ORD_JSON=""

if [[ -z "${MT5_CMD:-}" ]]; then
  echo "tc_grid_lib: MT5_CMD required (set in ENV_FILE)" >&2
  exit 1
fi

is_mt5_timeout() {
  local msg="$1"
  [[ "$msg" == *"timed out"* || "$msg" == *"Timeout"* || "$msg" == *"curl: (28)"* ]]
}

mt5_retry() {
  local attempt=1 out exitcode
  while true; do
    exitcode=0
    out=$("$@" 2>&1) || exitcode=$?
    if [[ $exitcode -eq 0 ]]; then
      printf '%s\n' "$out"
      return 0
    fi
    if is_mt5_timeout "$out"; then
      echo "timeout (attempt $attempt), retry in ${RETRY_DELAY}s: $*" >&2
      attempt=$((attempt + 1))
      sleep "$RETRY_DELAY"
      continue
    fi
    echo "$out" >&2
    return "$exitcode"
  done
}

json_ok() {
  local raw="$1"
  echo "$raw" | jq -e .ok >/dev/null 2>&1
}

refresh_positions_cache() {
  local raw
  raw=$(mt5_retry "$MT5_CMD" get_positions "$SYMBOL" "$MAGIC") || return 1
  if ! json_ok "$raw"; then
    echo "warn: get_positions not ok" >&2
    return 1
  fi
  _CACHE_POS_JSON=$raw
  return 0
}

refresh_orders_cache() {
  local raw
  raw=$(mt5_retry "$MT5_CMD" get_orders "$SYMBOL" "$MAGIC") || return 1
  if ! json_ok "$raw"; then
    echo "warn: get_orders not ok" >&2
    return 1
  fi
  _CACHE_ORD_JSON=$raw
  return 0
}

account_balance() {
  local raw
  raw=$(mt5_retry "$MT5_CMD" get_account)
  echo "$raw" | jq -er '.balance.balance'
}

basket_pnl_from_cache() {
  echo "$_CACHE_POS_JSON" | jq -r '.total_profit // 0'
}

basket_target() {
  local scaled worst_abs
  # Target = max(TARGETBASKET, 10% × |session_worst|). Floor until drawdown grows.
  if [[ -z "$SESSION_WORST_FLOAT" ]]; then
    echo "$TARGETBASKET"
    return
  fi
  worst_abs=$(awk -v w="$SESSION_WORST_FLOAT" 'BEGIN { v=w; if (v<0) v=-v; printf "%.4f", v }')
  scaled=$(echo "scale=4; $worst_abs * $BASKET_PCT" | bc -l)
  if [[ "$(echo "$scaled > $TARGETBASKET" | bc -l)" -eq 1 ]]; then
    echo "$scaled"
  else
    echo "$TARGETBASKET"
  fi
}

note_session_float_extremes() {
  local pnl="$1"
  [[ "$pnl" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || return 0
  if [[ -z "$SESSION_BEST_FLOAT" ]]; then
    SESSION_BEST_FLOAT=$pnl
    SESSION_WORST_FLOAT=$pnl
    return 0
  fi
  if [[ "$(echo "$pnl > $SESSION_BEST_FLOAT" | bc -l)" -eq 1 ]]; then
    SESSION_BEST_FLOAT=$pnl
  fi
  if [[ "$(echo "$pnl < $SESSION_WORST_FLOAT" | bc -l)" -eq 1 ]]; then
    SESSION_WORST_FLOAT=$pnl
  fi
}

session_float_label() {
  local which="$1"
  if [[ "$which" == best ]]; then
    [[ -n "$SESSION_BEST_FLOAT" ]] && echo "$SESSION_BEST_FLOAT" || echo "n/a"
  else
    [[ -n "$SESSION_WORST_FLOAT" ]] && echo "$SESSION_WORST_FLOAT" || echo "n/a"
  fi
}

format_duration() {
  local secs="$1" h m s
  h=$((secs / 3600))
  m=$(((secs % 3600) / 60))
  s=$((secs % 60))
  if (( h > 0 )); then
    echo "${h}h ${m}m ${s}s"
  elif (( m > 0 )); then
    echo "${m}m ${s}s"
  else
    echo "${s}s"
  fi
}

reset_session_stats() {
  SESSION_BEST_FLOAT=""
  SESSION_WORST_FLOAT=""
  SESSION_START=$(date +%s)
}

jq_position_exists() {
  local comment="$1"
  echo "$_CACHE_POS_JSON" | jq -e --arg c "$comment" \
    '[.positions[]? | select(.comment == $c)] | length > 0' >/dev/null
}

primary_position_row() {
  echo "$_CACHE_POS_JSON" | jq -c --arg c "$COMMENT" --argjson m "$MAGIC" \
    '.positions[]? | select(.comment == $c and .magic == $m)' | head -1
}

position_favor_points() {
  local row="$1" point="$2"
  echo "$row" | jq -r --argjson pt "$point" \
    'if .type == "buy" then ((.price_current - .price_open) / $pt)
     elif .type == "sell" then ((.price_open - .price_current) / $pt)
     else 0 end'
}

# Points underwater (0 if PRIMARY is flat or winning).
primary_adverse_points() {
  local row="$1" point="$2" favor
  [[ -n "$row" ]] || { echo 0; return; }
  favor=$(position_favor_points "$row" "$point")
  [[ "$favor" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || { echo 0; return; }
  if [[ "$(echo "$favor < 0" | bc -l)" -eq 1 ]]; then
    awk -v f="$favor" 'BEGIN { printf "%.2f", -f }'
  else
    echo 0
  fi
}

grid_leg_position_exists() {
  local level lcomment
  for ((level = 1; level <= MAX_LEVEL; level++)); do
    lcomment="L${level}"
    if jq_position_exists "$lcomment"; then
      return 0
    fi
  done
  return 1
}

# Filled grid leg required before basket close (at least L1).
grid_basket_close_allowed() {
  jq_position_exists "L1"
}

cancel_pending_by_comment() {
  local comment="$1" ticket
  ticket=$(echo "$_CACHE_ORD_JSON" | jq -r --arg c "$comment" \
    '.orders[]? | select(.comment == $c) | .ticket' | head -1)
  [[ -n "$ticket" && "$ticket" != "null" ]] || return 0
  echo "cancel pending $comment (ticket $ticket)"
  mt5_retry "$MT5_CMD" close_order "$ticket" >/dev/null || \
    echo "warn: close_order $ticket failed" >&2
}

# Drop unfilled grid limits when PRIMARY has not reached arm threshold (no legs filled yet).
disarm_pending_grid() {
  local level lcomment
  if grid_leg_position_exists; then
    return 0
  fi
  for ((level = 1; level <= MAX_LEVEL; level++)); do
    lcomment="L${level}"
    if jq_pending_exists "$lcomment"; then
      cancel_pending_by_comment "$lcomment"
    fi
  done
}

jq_pending_exists() {
  local comment="$1"
  echo "$_CACHE_ORD_JSON" | jq -e --arg c "$comment" \
    '[.orders[]? | select(.comment == $c)] | length > 0' >/dev/null
}

# Block duplicate grid limits: same order type + price (±2 pts), any comment.
jq_pending_at_grid_price() {
  local otype="$1" price="$2"
  echo "$_CACHE_ORD_JSON" | jq -e --arg t "$otype" --arg p "$price" --argjson e "$GRID_PRICE_EPS" \
    '[.orders[]? | select(.type == $t) | select(
      ((.price - ($p | tonumber)) | if . < 0 then -. else . end) < $e
    )] | length > 0' >/dev/null
}

grid_limit_otype() {
  if [[ "$SIDE" == buy ]]; then
    echo buy_limit
  else
    echo sell_limit
  fi
}

grid_order_already_pending() {
  local comment="$1" otype="$2" price="$3"
  if jq_pending_exists "$comment"; then
    echo "skip $comment — pending order with same comment" >&2
    return 0
  fi
  if jq_pending_at_grid_price "$otype" "$price"; then
    echo "skip $comment — pending $otype already at $price (±${GRID_PRICE_EPS})" >&2
    return 0
  fi
  return 1
}

jq_position_open_price() {
  local comment="$1"
  echo "$_CACHE_POS_JSON" | jq -er --arg c "$comment" \
    '.positions[] | select(.comment == $c) | .price_open' | head -1
}

jq_position_volume() {
  local comment="$1"
  echo "$_CACHE_POS_JSON" | jq -er --arg c "$comment" \
    '.positions[] | select(.comment == $c) | .volume' | head -1
}

# L1 = 2× PRIMARY; L2 = 2× L1; … Ln = 2× L(n−1).
vol_for_next_level() {
  local prev_comment="$1" prev_vol next_vol
  prev_vol=$(jq_position_volume "$prev_comment")
  [[ "$prev_vol" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  next_vol=$(echo "scale=3; $prev_vol * 2" | bc -l)
  # bc may print ".002" — normalize so open_order gets 0.002, not a bad/rounded lot.
  printf '%.3f' "$next_vol"
}

get_point() {
  local raw
  raw=$(mt5_retry "$MT5_CMD" get_price "$SYMBOL")
  echo "$raw" | jq -er '.point'
}

grid_price_from_ref() {
  local ref="$1" point="$2" offset
  [[ "$ref" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  offset=$(echo "$point * $GAP" | bc -l)
  if [[ "$SIDE" == buy ]]; then
    echo "scale=2; $ref - $offset" | bc -l
  else
    echo "scale=2; $ref + $offset" | bc -l
  fi
}

place_grid_limit() {
  local level="$1" price="$2" vol="$3"
  local comment="L${level}" otype
  [[ "$price" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    echo "warn: refuse place $comment — invalid price '$price'" >&2
    return 1
  }
  if [[ "$SIDE" == buy ]]; then
    otype=buy_limit
  else
    otype=sell_limit
  fi
  echo "place $comment $otype vol=$vol @ $price"
  local out req_vol
  out=$(mt5_retry "$MT5_CMD" open_order "$SYMBOL" "$otype" "$vol" "$price" "$MAGIC" 0 0 "$comment")
  echo "$out"
  req_vol=$(echo "$out" | jq -r '.request.volume // empty' 2>/dev/null) || true
  if [[ -n "$req_vol" ]] && [[ "$req_vol" != "$vol" ]]; then
    echo "warn: VPS/broker changed volume $vol -> $req_vol (fix server placeOrder to honor lot size)" >&2
  fi
  LAST_GRID_PLACE_COMMENT=$comment
  LAST_GRID_PLACE_TS=$(date +%s)
}

grid_place_blocked() {
  local comment="$1"
  if jq_pending_exists "$comment"; then
    LAST_GRID_PLACE_COMMENT=""
    return 0
  fi
  if [[ "$LAST_GRID_PLACE_COMMENT" == "$comment" ]] \
    && (( $(date +%s) - LAST_GRID_PLACE_TS < PLACE_COOLDOWN )); then
    return 0
  fi
  return 1
}

# One pending grid leg at a time; uses caches only (no duplicate API hammering).
advance_grid() {
  local point level prev_comment ref price vol lcomment row adverse

  if ! jq_position_exists "$COMMENT"; then
    return 0
  fi

  point=$(get_point) || {
    echo "warn: get_price failed — skip grid advance" >&2
    return 0
  }

  row=$(primary_position_row)
  adverse=$(primary_adverse_points "$row" "$point")
  profit=$(echo "$row" | jq -r .profit)

  if [[ "$profit" =~ ^-?[0-9]+([.][0-9]+)?$ ]] \
    && [[ "$(echo "$profit >= 0" | bc -l)" -eq 1 ]] \
    && ! grid_leg_position_exists; then
    disarm_pending_grid
    echo "grid idle (magic $MAGIC) — $COMMENT in profit; no basket/grid on PRIMARY alone"
    return 0
  fi

  if ! grid_leg_position_exists; then
    if [[ "$(echo "$adverse < $TC_GRID_ARM_LOSS_PTS" | bc -l)" -eq 1 ]]; then
      disarm_pending_grid
      echo "grid idle (magic $MAGIC) — ${COMMENT} adverse ${adverse} pts < arm ${TC_GRID_ARM_LOSS_PTS}"
      return 0
    fi
  fi

  for ((level = 1; level <= MAX_LEVEL; level++)); do
    if [[ $level -eq 1 ]]; then
      prev_comment=$COMMENT
    else
      prev_comment="L$((level - 1))"
    fi

    if ! jq_position_exists "$prev_comment"; then
      return 0
    fi

    lcomment="L${level}"
    if jq_position_exists "$lcomment"; then
      continue
    fi

    ref=$(jq_position_open_price "$prev_comment") || continue
    price=$(grid_price_from_ref "$ref" "$point") || continue
    vol=$(vol_for_next_level "$prev_comment") || continue

    local otype
    otype=$(grid_limit_otype)
    if grid_order_already_pending "$lcomment" "$otype" "$price"; then
      continue
    fi
    if grid_place_blocked "$lcomment"; then
      return 0
    fi

    place_grid_limit "$level" "$price" "$vol"
    return 0
  done
}

close_basket_and_report() {
  local bal_before bal_after delta elapsed target
  target=$(basket_target)
  elapsed=$(($(date +%s) - SESSION_START))
  bal_before=$(account_balance)
  mt5_retry "$MT5_CMD" close_grid_basket "$SYMBOL" "$MAGIC"
  bal_after=$(account_balance)
  delta=$(echo "$bal_after - $bal_before" | bc -l)
  echo "close_grid_basket (magic $MAGIC $SIDE): balance before=$bal_before after=$bal_after delta=$delta"
  echo "session summary: session_best=$(session_float_label best) session_worst=$(session_float_label worst) target_used=$target (max($TARGETBASKET, ${BASKET_PCT}×|worst|)) runtime=$(format_duration "$elapsed")"
  reset_session_stats
  LAST_GRID_PLACE_COMMENT=""
  LAST_GRID_PLACE_TS=0
}

tc_grid_main() {
  echo "[$RUN_TAG] TC grid $SIDE magic=$MAGIC GAP=${GAP}pts arm=${TC_GRID_ARM_LOSS_PTS}pts max=L${MAX_LEVEL} — L1+ only when armed; close basket only with L1+ filled"
  reset_session_stats
  while true; do
    local pnl target

    if ! refresh_positions_cache; then
      echo "warn: skip tick — positions unavailable" >&2
      sleep "$RETRY_DELAY"
      continue
    fi

    pnl=$(basket_pnl_from_cache)
    note_session_float_extremes "$pnl"
    target=$(basket_target)
    echo "PNL (magic $MAGIC): $pnl  session_best: $(session_float_label best)  session_worst: $(session_float_label worst)  target: $target  grid_close_ok=$(grid_basket_close_allowed && echo yes || echo no)"

    if grid_basket_close_allowed \
      && [[ "$pnl" =~ ^-?[0-9]+([.][0-9]+)?$ ]] \
      && [[ "$(echo "$pnl >= $target" | bc -l)" -eq 1 ]]; then
      close_basket_and_report
    fi

    if refresh_orders_cache; then
      advance_grid
    else
      echo "warn: skip grid advance — orders unavailable" >&2
    fi

    sleep "$TC_LOOP_SLEEP"
  done
}