#!/bin/bash
# Place regime PRIMARY pendings, then manage background: maintain_order, TC_BUY, TC_SELL.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1

ENV_FILE=""
CMD=""

usage() {
  cat <<EOF
Usage: $0 [-e ENV_FILE] {start|stop|restart|ps}

  -e ENV_FILE   trading + MT5 settings (default: ${SCRIPT_DIR}/var.env)

  start    — place PRIMARY; workers: maintain_order, TC_BUY, TC_SELL, swingking_ack (PSW)
  stop     — stop all background workers for this RUN_TAG
  restart  — stop then start
  ps       — show worker PIDs and related processes

Env defines RUN_TAG, LOG_DIR, PID_DIR. Example multi-asset:
  $0 -e var.env start
  $0 -e env/BTCUSD.env start
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      ENV_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    start|stop|restart|ps)
      CMD="$1"
      shift
      break
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

[[ -n "$CMD" ]] || { usage; exit 1; }

if [[ -z "$ENV_FILE" ]]; then
  ENV_FILE="${SCRIPT_DIR}/var.env"
fi
export ENV_FILE
# shellcheck source=load_env.sh
source "${SCRIPT_DIR}/load_env.sh"
# shellcheck source=primary_regime_lib.sh
source "${SCRIPT_DIR}/primary_regime_lib.sh"

MT5="$MT5_CMD"
[[ -x "$MT5" ]] || MT5="$(command -v mt5 2>/dev/null || true)"
[[ -n "$MT5" ]] || { echo "MT5_CMD not executable: $MT5_CMD" >&2; exit 1; }

WORKERS=(
  "maintain_order:maintain_order.sh"
  "TC_BUY:TC_BUY.sh"
  "TC_SELL:TC_SELL.sh"
  "swingking_ack:SWINGKING/watch_ack.sh"
)

pid_file() { echo "${PID_DIR}/${RUN_TAG}_$1.pid"; }
log_file() { echo "${LOG_DIR}/${RUN_TAG}_$1.log"; }

is_running() {
  local name="$1" pf pid
  pf=$(pid_file "$name")
  [[ -f "$pf" ]] || return 1
  pid=$(cat "$pf")
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

stop_one() {
  local name="$1" pf pid
  pf=$(pid_file "$name")
  if is_running "$name"; then
    pid=$(cat "$pf")
    echo "stop $name (pid $pid)"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pf"
}

start_one() {
  local name="$1" script="$2" pf lf
  pf=$(pid_file "$name")
  lf=$(log_file "$name")
  if is_running "$name"; then
    echo "already running $name (pid $(cat "$pf"))"
    return 0
  fi
  rm -f "$pf"
  echo "start $name ($RUN_TAG) → $lf"
  nohup env ENV_FILE="$ENV_FILE" bash "$SCRIPT_DIR/$script" >>"$lf" 2>&1 &
  echo $! >"$pf"
  echo "  pid $(cat "$pf")"
}

mt5_step() {
  echo "[$RUN_TAG] mt5 $*" >&2
  env ENV_FILE="$ENV_FILE" "$MT5" "$@"
}

place_primary_orders() {
  local EMA_PRICE PRICE_JSON MID_PRICE ORDERS_JSON health_raw ema_raw

  echo "[$RUN_TAG] MT5 API → ${MT5_HOST}:${MT5_PORT} (curl connect ${MT5_CONNECT_TIMEOUT:-10}s max ${MT5_CURL_MAX}s)"
  if ! health_raw=$(mt5_step health); then
    echo "MT5 unreachable — fix MT5_HOST/firewall or start VPS API. Output:" >&2
    echo "$health_raw" >&2
    return 1
  fi
  if ! echo "$health_raw" | jq -e .ok >/dev/null 2>&1; then
    echo "MT5 health not ok: $health_raw" >&2
    return 1
  fi

  echo "[$RUN_TAG] get_ema ${SYMBOL} ${PERIOD} ${METHOD} ${EMA_TIMEFRAME} (count=${EMA_CANDLE_COUNT})"
  if ! ema_raw=$(mt5_step get_ema "$SYMBOL" "$PERIOD" "$METHOD" "$EMA_TIMEFRAME" "$EMA_CANDLE_COUNT"); then
    echo "get_ema failed: $ema_raw" >&2
    return 1
  fi
  EMA_PRICE=$(echo "$ema_raw" | jq -er .value) || {
    echo "get_ema bad JSON: $ema_raw" >&2
    return 1
  }

  echo "[$RUN_TAG] get_price ${SYMBOL}"
  if ! PRICE_JSON=$(mt5_step get_price "$SYMBOL"); then
    echo "get_price failed (see errors above)" >&2
    return 1
  fi
  if ! echo "$PRICE_JSON" | jq -e .ok >/dev/null; then
    echo "get_price failed: $PRICE_JSON" >&2
    return 1
  fi
  MID_PRICE=$(primary_regime_mid_price "$PRICE_JSON") || return 1

  ORDERS_JSON=$(mt5_step get_orders "$SYMBOL") || {
    echo "get_orders failed: $ORDERS_JSON" >&2
    return 1
  }
  if ! echo "$ORDERS_JSON" | jq -e .ok >/dev/null; then
    echo "get_orders failed: $ORDERS_JSON" >&2
    return 1
  fi

  sync_primary_regime_at_ema "$EMA_PRICE" "$ORDERS_JSON" "$MID_PRICE"
}

cmd_start() {
  echo "=== init start RUN_TAG=$RUN_TAG ENV_FILE=$ENV_FILE ==="
  if [[ "${INIT_SKIP_PRIMARY:-0}" == "1" ]]; then
    echo "[$RUN_TAG] INIT_SKIP_PRIMARY=1 — skipping PRIMARY placement"
  else
    place_primary_orders || {
      echo "PRIMARY placement failed — not starting workers (set INIT_SKIP_PRIMARY=1 to skip)" >&2
      exit 1
    }
  fi
  local pair name script
  for pair in "${WORKERS[@]}"; do
    name="${pair%%:*}"
    script="${pair##*:}"
    start_one "$name" "$script"
  done
  echo "=== started — logs: $(log_file maintain_order) $(log_file TC_BUY) $(log_file TC_SELL) $(log_file swingking_ack) ==="
}

cmd_stop() {
  echo "=== init stop RUN_TAG=$RUN_TAG ==="
  local pair name
  for pair in "${WORKERS[@]}"; do
    name="${pair%%:*}"
    stop_one "$name"
  done
  echo "=== stopped ==="
}

cmd_restart() {
  cmd_stop
  sleep 1
  cmd_start
}

cmd_ps() {
  local pair name script pf pid
  echo "=== workers RUN_TAG=$RUN_TAG ($SCRIPT_DIR) ==="
  for pair in "${WORKERS[@]}"; do
    name="${pair%%:*}"
    script="${pair##*:}"
    pf=$(pid_file "$name")
    if is_running "$name"; then
      pid=$(cat "$pf")
      echo "$name  RUNNING  pid=$pid  log=$(log_file "$name")"
      ps -p "$pid" -o pid=,etime=,command= 2>/dev/null | sed 's/^/    /'
    elif [[ -f "$pf" ]]; then
      pid=$(cat "$pf")
      echo "$name  STOPPED (stale pid file: $pid)"
      rm -f "$pf"
    else
      echo "$name  STOPPED  (no pid file)"
    fi
  done
}

case "$CMD" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  ps)      cmd_ps ;;
esac