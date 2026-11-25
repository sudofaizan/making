#!/usr/bin/env bash
# AlphaFX MT5 VPS API helper: mt5 <command> ...
set -euo pipefail

_MT5_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -z "${ENV_FILE:-}" && -f "${_MT5_SCRIPT_DIR}/var.env" ]]; then
  ENV_FILE="${_MT5_SCRIPT_DIR}/var.env"
fi
if [[ -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

: "${MT5_HOST:?MT5_HOST required — set in ENV_FILE or environment}"
: "${MT5_PORT:?MT5_PORT required — set in ENV_FILE or environment}"
: "${API_KEY:?API_KEY required — set in ENV_FILE or environment}"
: "${MT5_CURL_MAX:?MT5_CURL_MAX required — set in ENV_FILE or environment}"

BASE_URL="http://${MT5_HOST}:${MT5_PORT}"
unset _MT5_SCRIPT_DIR

MT5_CONNECT_TIMEOUT="${MT5_CONNECT_TIMEOUT:-10}"

api_get() {
  curl -sS --connect-timeout "${MT5_CONNECT_TIMEOUT}" -m "${MT5_CURL_MAX}" \
    -H "X-API-Key: ${API_KEY}" "${BASE_URL}$1"
}

api_post() {
  local path="$1"
  local body="${2:?json body required}"
  curl -sS --connect-timeout "${MT5_CONNECT_TIMEOUT}" -m "${MT5_CURL_MAX}" \
    -H "X-API-Key: ${API_KEY}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "${body}" \
    "${BASE_URL}${path}"
}

uri_encode() {
  python3 -c "import urllib.parse; print(urllib.parse.quote('''$1''', safe=''))"
}

# Build JSON without jq (jq reserves "type" as a keyword in {type: ...}).
json_place_order() {
  python3 - "$@" <<'PY'
import json, sys
sym, otype, vol, price, magic, sl, tp, comment = sys.argv[1:9]
body = {
    "symbol": sym,
    "type": otype,
    "volume": float(vol),
    "magic": int(magic),
    "comment": comment,
}
if price not in ("", "none", "None", "-"):
    body["price"] = float(price)
if sl not in ("", "none", "None", "-", "0"):
    body["sl_points"] = int(sl)
if tp not in ("", "none", "None", "-", "0"):
    body["tp_points"] = int(tp)
print(json.dumps(body, separators=(",", ":")))
PY
}

# After required args: [MAGIC] [SL_POINTS] [TP_POINTS] [COMMENT...]
# COMMENT is last; quote it for spaces. SL/TP: omit, 0, or - for none.
parse_order_tail() {
  ORDER_MAGIC="78001"
  ORDER_SL=""
  ORDER_TP=""
  ORDER_COMMENT="mt5"
  # Single trailing token that is not numeric → comment only (skip magic/sl/tp).
  if (( $# == 1 )) && ! [[ "$1" =~ ^-?[0-9]+$ ]]; then
    ORDER_COMMENT="$1"
    return
  fi
  [[ $# -ge 1 && -n "${1:-}" ]] && ORDER_MAGIC="$1" && shift
  [[ $# -ge 1 ]] && ORDER_SL="$1" && shift
  [[ $# -ge 1 ]] && ORDER_TP="$1" && shift
  [[ $# -ge 1 ]] && ORDER_COMMENT="$*"
}

usage() {
  local topic="${1:-}"
  case "$topic" in
    get_price)
      cat <<'EOF'
get_price — live bid/ask (GET /getPrice)

  mt5 get_price <SYMBOL>

  SYMBOL   Broker symbol, e.g. BTCUSD, XAUUSD, GOLDmicro

Example:
  mt5 get_price BTCUSD
EOF
      ;;
    get_candles)
      cat <<'EOF'
get_candles — OHLCV bars from VPS (GET /getCandles)

  mt5 get_candles <SYMBOL> [TIMEFRAME] [COUNT]

  COUNT default 3000, max 5000
EOF
      ;;
    get_ema)
      cat <<'EOF'
get_ema — moving average from /getCandles closes (GET + local calc)

  mt5 get_ema <SYMBOL> <PERIOD> <METHOD> [TIMEFRAME] [COUNT]

  SYMBOL     e.g. BTCUSD
  PERIOD     integer bars, e.g. 200
  METHOD     EMA | SMMA | LW (LWMA) | SMA
  TIMEFRAME  optional, default M5  (M1 M5 M15 M30 H1 H4 D1 ...)
  COUNT      optional, default 3000 (max 5000)

Examples:
  mt5 get_ema BTCUSD 200 LW
  mt5 get_ema BTCUSD 200 SMMA M5 3000
EOF
      ;;
    open_buy)
      cat <<'EOF'
open_buy — market BUY (POST /placeOrder)

  mt5 open_buy <SYMBOL> <VOLUME> [MAGIC] [SL_POINTS] [TP_POINTS] [COMMENT]

  SYMBOL      e.g. BTCUSD
  VOLUME      lots, e.g. 0.01  (not 0.02 strings — use decimals)
  MAGIC       optional int, default 78001
  SL_POINTS   optional int; omit, 0, or - = none
  TP_POINTS   optional int; omit, 0, or - = none
  COMMENT     optional, last arg (default mt5); quote if it has spaces

Example:
  mt5 open_buy BTCUSD 0.01
  mt5 open_buy BTCUSD 0.01 78001 500 1000
  mt5 open_buy BTCUSD 0.01 78001 - - ema_grid_L2
EOF
      ;;
    open_sell)
      cat <<'EOF'
open_sell — market SELL (POST /placeOrder)

  mt5 open_sell <SYMBOL> <VOLUME> [MAGIC] [SL_POINTS] [TP_POINTS] [COMMENT]

  Same args as open_buy; type is sell.

Example:
  mt5 open_sell BTCUSD 0.01
  mt5 open_sell BTCUSD 0.01 78001 - - manual_scratch
EOF
      ;;
    open_order)
      cat <<'EOF'
open_order — pending order (POST /placeOrder)

  mt5 open_order <SYMBOL> <ORDER_TYPE> <VOLUME> <PRICE> [MAGIC] [SL_POINTS] [TP_POINTS] [COMMENT]

  SYMBOL      e.g. BTCUSD
  ORDER_TYPE  buy_limit | sell_limit | buy_stop | sell_stop
  VOLUME      lots, e.g. 0.02
  PRICE       limit/stop price, e.g. 59000
  MAGIC       optional int, default 78001
  SL_POINTS   optional; omit, 0, or - = not sent
  TP_POINTS   optional; omit, 0, or - = not sent
  COMMENT     optional, last arg (default mt5)

Example:
  mt5 open_order BTCUSD buy_stop 0.02 59000
  mt5 open_order BTCUSD sell_limit 0.01 62000 78001 0 500
  mt5 open_order BTCUSD buy_stop 0.02 59000 88122 - - EMA_BRACKET

JSON sent:
  {"symbol":"BTCUSD","type":"buy_stop","volume":0.02,"price":59000,"magic":78001,"comment":"EMA_BRACKET"}
EOF
      ;;
    get_pnl|get_positions)
      cat <<'EOF'
get_pnl / get_positions — open positions + floating P/L (GET /getPositions)

  mt5 get_pnl [SYMBOL] [MAGIC]
  mt5 get_positions [SYMBOL] [MAGIC]

  SYMBOL  optional filter, e.g. BTCUSD
  MAGIC   optional int filter

Examples:
  mt5 get_pnl
  mt5 get_pnl BTCUSD
  mt5 get_pnl BTCUSD 78001
EOF
      ;;
    get_account)
      cat <<'EOF'
get_account — balance, equity, margin, floating (GET /getAccountHealth)

  mt5 get_account
EOF
      ;;
    get_orders)
      cat <<'EOF'
get_orders — pending limits/stops (GET /getOrders)

  mt5 get_orders [SYMBOL] [MAGIC]

  SYMBOL  optional
  MAGIC   optional int
EOF
      ;;
    close_trade)
      cat <<'EOF'
close_trade — close one position by ticket (POST /closePositions)

  mt5 close_trade <TICKET>

  TICKET  position ticket from get_positions (integer)

Example:
  mt5 close_trade 123456789
EOF
      ;;
    close_trades)
      cat <<'EOF'
close_trades — close all matching open positions (POST /closePositions)

  mt5 close_trades [SYMBOL] [MAGIC]

  SYMBOL  optional — close all on symbol
  MAGIC   optional — with symbol, filter magic

Examples:
  mt5 close_trades BTCUSD
  mt5 close_trades BTCUSD 78001
EOF
      ;;
    close_grid_basket|closeGridBasket)
      cat <<'EOF'
close_grid_basket — close positions + cancel orders for symbol/magic (POST /closeGridBasket)

  mt5 close_grid_basket [SYMBOL] [MAGIC]

  SYMBOL  optional, e.g. GOLD or BTCUSD
  MAGIC   optional int, e.g. 788

Examples:
  mt5 close_grid_basket GOLD 788
  mt5 close_grid_basket BTCUSD 788
EOF
      ;;
    modify_position)
      cat <<'EOF'
modify_position — change SL/TP on open position (POST /modifyPosition)

  mt5 modify_position <TICKET> <SL_PRICE> [TP_PRICE]

  SL_PRICE    stop loss price level (e.g. EMA); use 0 to clear TP only if server allows
  TP_PRICE    optional, default 0 (no take-profit)

Example:
  mt5 modify_position 123456789 3610.50 0
EOF
      ;;
    close_order)
      cat <<'EOF'
close_order — cancel pending order (POST /cancelOrder)

  mt5 close_order <TICKET>

  TICKET  order ticket from get_orders (integer)

Example:
  mt5 close_order 987654321
EOF
      ;;
    *)
      if [[ -n "$topic" ]]; then
        echo "No help for: $topic" >&2
        echo >&2
      fi
      cat <<'EOF'
AlphaFX mt5 — HTTP API to server1.3.py on MT5 VPS

Set MT5_HOST on line 2. Optional env: MT5_PORT=8080, API_KEY=alphafx

Help:
  mt5 -h                 this list
  mt5 -h <command>         usage for one command
  mt5 <command> -h         same

Commands:
  get_price      live bid/ask/spread (GET /getPrice)
  get_ema        moving average from candles (GET /getCandles + local calc)
  open_buy       market buy (POST /placeOrder)
  open_sell      market sell (POST /placeOrder)
  open_order     pending limit/stop (POST /placeOrder)
  get_pnl        open positions + floating P/L (GET /getPositions)
  get_positions  alias for get_pnl
  get_account    balance, equity, margin (GET /getAccountHealth)
  get_orders     pending orders (GET /getOrders)
  close_trade    close one position by ticket (POST /closePositions)
  close_trades       close positions by symbol/magic (POST /closePositions)
  close_grid_basket  close basket + cancel orders (POST /closeGridBasket)
  modify_position    set SL/TP on open position (POST /modifyPosition)
  close_order        cancel pending order by ticket (POST /cancelOrder)
  health         server health (GET /health)
  version        server version (GET /version)

Quick examples:
  mt5 get_price GOLD
  mt5 get_ema GOLD 200 EMA M5 600
  mt5 get_positions GOLD
  mt5 get_orders GOLD
  mt5 open_order GOLD buy_limit 0.01 2500
  mt5 close_order 123456789
  mt5 close_grid_basket GOLD 788
EOF
      ;;
  esac
}

cmd_get_price() {
  local sym="${1:?symbol — see: mt5 -h get_price}"
  api_get "/getPrice?symbol=$(uri_encode "$sym")"
}

cmd_get_candles() {
  local sym="${1:?symbol}" tf="${2:-M5}" count="${3:-3000}"
  api_get "/getCandles?symbol=$(uri_encode "$sym")&timeframe=${tf}&count=${count}"
}

cmd_get_ema() {
  local sym="${1:?symbol}" period="${2:?period}" method="${3:?EMA|SMMA|LW|SMA}"
  local tf="${4:-M5}" count="${5:-3000}"
  method=$(echo "$method" | tr '[:lower:]' '[:upper:]')
  local tmp
  tmp=$(mktemp)
  api_get "/getCandles?symbol=$(uri_encode "$sym")&timeframe=${tf}&count=${count}" >"$tmp"
  python3 - "$tmp" "$period" "$method" "$sym" "$tf" <<'PY'
import json, sys
path, period_s, method, sym, tf = sys.argv[1:6]
period = int(period_s)
with open(path) as f:
    d = json.load(f)
if not d.get("ok"):
    print(json.dumps(d, indent=2))
    sys.exit(1)
closes = [float(b["close"]) for b in d["candles"]]
if len(closes) < period:
    print(json.dumps({"ok": False, "error": f"need {period} bars, got {len(closes)}"}))
    sys.exit(1)

def ema(vals, n):
    e = sum(vals[:n]) / n
    k = 2.0 / (n + 1)
    for v in vals[n:]:
        e = v * k + e * (1 - k)
    return e

def smma(vals, n):
    s = sum(vals[:n]) / n
    for v in vals[n:]:
        s = (s * (n - 1) + v) / n
    return s

def lwma(vals, n):
    w = vals[-n:]
    weights = list(range(1, n + 1))
    return sum(a * b for a, b in zip(w, weights)) / sum(weights)

def sma(vals, n):
    return sum(vals[-n:]) / n

method = method.upper()
if method in ("EMA", "EXP", "EXPONENTIAL"):
    value = ema(closes, period)
elif method in ("SMMA", "SMOOTH", "SMOOTHED"):
    value = smma(closes, period)
elif method in ("LW", "LWMA", "LINEAR"):
    value = lwma(closes, period)
elif method in ("SMA", "SIMPLE"):
    value = sma(closes, period)
else:
    print(json.dumps({"ok": False, "error": f"unknown method {method}"}))
    sys.exit(1)
print(json.dumps({
    "ok": True, "symbol": d.get("symbol", sym), "timeframe": tf,
    "period": period, "method": method, "value": round(value, 5),
    "bars_used": len(closes), "last_candle_time": d.get("last"),
    "last_close": closes[-1],
}, indent=2))
PY
  rm -f "$tmp"
}

cmd_open_buy() {
  local sym="${1:?symbol}" vol="${2:?volume}"
  shift 2
  parse_order_tail "$@"
  local json
  json=$(json_place_order "$sym" buy "$vol" "" "$ORDER_MAGIC" "$ORDER_SL" "$ORDER_TP" "$ORDER_COMMENT")
  api_post "/placeOrder" "$json"
}

cmd_open_sell() {
  local sym="${1:?symbol}" vol="${2:?volume}"
  shift 2
  parse_order_tail "$@"
  local json
  json=$(json_place_order "$sym" sell "$vol" "" "$ORDER_MAGIC" "$ORDER_SL" "$ORDER_TP" "$ORDER_COMMENT")
  api_post "/placeOrder" "$json"
}

cmd_open_order() {
  local sym="${1:?symbol}" otype="${2:?order_type}" vol="${3:?volume}" price="${4:?price}"
  shift 4
  parse_order_tail "$@"
  otype=$(echo "$otype" | tr '[:upper:]' '[:lower:]')
  case "$otype" in
    buy_limit|sell_limit|buy_stop|sell_stop) ;;
    *)
      echo "ORDER_TYPE must be buy_limit | sell_limit | buy_stop | sell_stop (got: $otype)" >&2
      echo "See: mt5 -h open_order" >&2
      exit 1
      ;;
  esac
  local json
  json=$(json_place_order "$sym" "$otype" "$vol" "$price" "$ORDER_MAGIC" "$ORDER_SL" "$ORDER_TP" "$ORDER_COMMENT")
  if [[ "${DEBUG:-}" == "1" ]]; then
    echo "POST /placeOrder body: $json" >&2
  fi
  api_post "/placeOrder" "$json"
}

cmd_get_pnl() {
  local sym="${1:-}" magic="${2:-}"
  local q=""
  [[ -n "$sym" ]] && q+="?symbol=$(uri_encode "$sym")"
  [[ -n "$magic" ]] && q+="${q:+&}magic=${magic}"
  api_get "/getPositions${q}"
}

cmd_get_account() {
  api_get "/getAccountHealth"
}

cmd_get_positions() {
  cmd_get_pnl "$@"
}

cmd_get_orders() {
  local sym="${1:-}" magic="${2:-}"
  local q=""
  [[ -n "$sym" ]] && q+="?symbol=$(uri_encode "$sym")"
  [[ -n "$magic" ]] && q+="${q:+&}magic=${magic}"
  api_get "/getOrders${q}"
}

cmd_close_trade() {
  local ticket="${1:?ticket}"
  api_post "/closePositions" "{\"ticket\":${ticket}}"
}

cmd_close_trades() {
  local sym="${1:-}" magic="${2:-}"
  local json
  json=$(python3 - "$sym" "$magic" <<'PY'
import json, sys
sym, magic = sys.argv[1], sys.argv[2]
body = {}
if sym:
    body["symbol"] = sym
if magic:
    body["magic"] = int(magic)
print(json.dumps(body, separators=(",", ":")))
PY
)
  api_post "/closePositions" "$json"
}

cmd_close_order() {
  local ticket="${1:?ticket}"
  api_post "/cancelOrder" "{\"ticket\":${ticket}}"
}

cmd_modify_position() {
  local ticket="${1:?ticket}" sl="${2:?sl_price}" tp="${3:-0}"
  api_post "/modifyPosition" "{\"ticket\":${ticket},\"sl\":${sl},\"tp\":${tp}}"
}

cmd_close_grid_basket() {
  local sym="${1:-}" magic="${2:-}"
  local json
  json=$(python3 - "$sym" "$magic" <<'PY'
import json, sys
sym, magic = sys.argv[1], sys.argv[2]
body = {}
if sym:
    body["symbol"] = sym
if magic:
    body["magic"] = int(magic)
print(json.dumps(body, separators=(",", ":")))
PY
)
  api_post "/closeGridBasket" "$json"
}

main() {
  local cmd="${1:-}"

  # -h as first arg, or <cmd> -h
  if [[ "$cmd" == "-h" || "$cmd" == "--help" ]]; then
    usage "${2:-}"
    exit 0
  fi

  if [[ $# -ge 2 && ( "${2:-}" == "-h" || "${2:-}" == "--help" ) ]]; then
    usage "$cmd"
    exit 0
  fi

  if [[ -z "$cmd" ]]; then
    usage
    exit 0
  fi

  shift || true

  case "$cmd" in
    get_price)        cmd_get_price "$@" ;;
    get_candles)      cmd_get_candles "$@" ;;
    get_ema)          cmd_get_ema "$@" ;;
    open_buy)         cmd_open_buy "$@" ;;
    open_sell)        cmd_open_sell "$@" ;;
    open_order)       cmd_open_order "$@" ;;
    get_pnl)          cmd_get_pnl "$@" ;;
    get_account)      cmd_get_account ;;
    get_positions)    cmd_get_positions "$@" ;;
    get_orders)       cmd_get_orders "$@" ;;
    close_trade)      cmd_close_trade "$@" ;;
    close_trades)     cmd_close_trades "$@" ;;
    close_grid_basket|closeGridBasket) cmd_close_grid_basket "$@" ;;
    close_order)      cmd_close_order "$@" ;;
    modify_position)  cmd_modify_position "$@" ;;
    health)           api_get "/health" ;;
    version)          api_get "/version" ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"