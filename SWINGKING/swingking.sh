#!/bin/bash
# SWINGKING — mark buy/sell zones (BigBeluga SMC-style order blocks) from MT5 candles.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1

ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/swingking.env}"
[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

ROOT_ENV="${SCRIPT_DIR}/../var.env"
if [[ -f "$ROOT_ENV" ]]; then
  export ENV_FILE="$ROOT_ENV"
fi

MT5="${MT5_CMD:-../mt5}"
[[ -x "$MT5" ]] || MT5="$(cd "$SCRIPT_DIR/.." && pwd)/mt5"

mkdir -p "${OUT_DIR:-./zones}"

cfg_json() {
  python3 - <<'PY'
import json, os
keys = (
    "MS_LEN", "OB_LAST", "OB_LEN", "OB_MODE", "OB_MITI",
    "MS_WINDOW", "MS_WINDOW_ENABLED", "MS_MODE", "BUILD_SWEEP",
    "HIDE_OVERLAP", "OVERLAP_KEEP",
)
print(json.dumps({k: os.environ.get(k, "") for k in keys}))
PY
}

fetch_and_compute() {
  local raw outf
  raw=$("$MT5" get_candles "$SYMBOL" "$TIMEFRAME" "$CANDLE_COUNT") || {
    echo "get_candles failed" >&2
    return 1
  }
  python3 "$SCRIPT_DIR/smc_zones.py" "$(cfg_json)" <<<"$raw"
}

print_human() {
  local json="$1"
  echo "$json" | jq -r '
    "Symbol: \(.symbol // "n/a")  bars: \(.bars)  last: \(.last_close)  trend: \(if .trend==1 then "bull" elif .trend==-1 then "bear" else "neutral" end)",
    "",
    "BUY ZONES (demand / bullish OB)",
    (.buy_zones[]? | "  \(.mid)  [\(.bottom) – \(.top)]  vol \(.volume) (\(.vol_pct)%)\(if .time != "" then "  " + .time else "" end)"),
    (if (.buy_zones | length) == 0 then "  (none active)" else empty end),
    "",
    "SELL ZONES (supply / bearish OB)",
    (.sell_zones[]? | "  \(.mid)  [\(.bottom) – \(.top)]  vol \(.volume) (\(.vol_pct)%)\(if .time != "" then "  " + .time else "" end)"),
    (if (.sell_zones | length) == 0 then "  (none active)" else empty end)
  '
}

save_json() {
  local json="$1"
  local path="${OUT_DIR:-./zones}/${RUN_TAG:-${SYMBOL}}-${TIMEFRAME}-zones.json"
  echo "$json" | jq . >"$path"
  echo "saved $path"
}

cmd_mark() {
  local json
  json=$(fetch_and_compute) || exit 1
  print_human "$json"
  save_json "$json"
}

cmd_json() {
  fetch_and_compute
}

cmd_watch() {
  while true; do
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    cmd_mark || echo "warn: mark failed" >&2
    sleep "${LOOP_SLEEP:-60}"
  done
}

load_trading_env() {
  [[ -f "${ENV_FILE:-$ROOT_ENV}" ]] || { echo "missing trading env (var.env)" >&2; exit 1; }
  # shellcheck source=../load_env.sh
  source "${SCRIPT_DIR}/../load_env.sh"
  MT5="$MT5_CMD"
  [[ -x "$MT5" ]] || MT5="$(cd "$SCRIPT_DIR/.." && pwd)/mt5"
  export MT5
  # shellcheck source=psw_lib.sh
  source "${SCRIPT_DIR}/psw_lib.sh"
}

cmd_deploy() {
  local force=0 ticket zones_json
  [[ "${1:-}" == "--force" ]] && force=1

  load_trading_env

  if [[ $force -eq 0 ]] && psw_already_deployed; then
    if ! psw_flat; then
      echo "PSW already deployed (state file exists) — still have PSW orders/positions; not placing again" >&2
      echo "Use: $0 reset-psw when flat, or $0 deploy --force after manual ack" >&2
      exit 1
    fi
    echo "PSW state file present but flat — clearing stale state"
    psw_clear_state
  fi

  ticket=$(find_psw_ack_ticket) || ticket=""
  if [[ -z "$ticket" ]]; then
    echo "No ack order: place manual ${PSW_ACK_ORDER_TYPE:-buy_stop} vol=${PSW_ACK_VOLUME:-0.14} on $SYMBOL, then run deploy again" >&2
    exit 1
  fi

  echo "Ack: delete manual order ticket $ticket (${PSW_ACK_ORDER_TYPE:-buy_stop} ${PSW_ACK_VOLUME:-0.14})"
  psw_mt5_retry close_order "$ticket" >/dev/null || {
    echo "failed to cancel ack order $ticket" >&2
    exit 1
  }

  zones_json=$(fetch_and_compute) || exit 1
  print_human "$zones_json"
  save_json "$zones_json"

  cancel_psw_pendings
  place_psw_ob_limits "$zones_json" || {
    echo "PSW placement failed" >&2
    exit 1
  }

  psw_mark_deployed
  echo "PSW deploy done (one-shot). TC workers use magic ${BUY_MAGIC}/${SELL_MAGIC} + comment ${PSW_COMMENT:-PSW} for basket/grid."
}

cmd_reset_psw() {
  load_trading_env
  if ! psw_flat; then
    echo "refuse reset — PSW orders or positions still open" >&2
    exit 1
  fi
  psw_clear_state
  echo "PSW state cleared — you may ack and deploy again"
}

usage() {
  cat <<EOF
Usage: $0 {mark|json|watch|deploy|reset-psw}

  mark        — compute zones, print table + write zones JSON
  json        — raw JSON to stdout
  watch       — loop mark every LOOP_SLEEP seconds
  deploy      — one-shot: ack manual ${PSW_ACK_ORDER_TYPE:-buy_stop} (${PSW_ACK_VOLUME:-0.14}), place PSW limits at 1st OB mids
  reset-psw   — clear deploy lock when no PSW orders/positions (for next ack cycle)
  deploy --force — clear stale lock when flat, still requires ack order

Trading: ENV_FILE=${ENV_FILE:-$ROOT_ENV}
SMC: $ENV_FILE
EOF
}

case "${1:-mark}" in
  mark)  cmd_mark ;;
  json)  cmd_json ;;
  watch) cmd_watch ;;
  deploy) shift; cmd_deploy "$@" ;;
  reset-psw) cmd_reset_psw ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac