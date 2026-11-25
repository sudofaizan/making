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

if [[ -f "${SCRIPT_DIR}/../var.env" ]]; then
  export ENV_FILE="${SCRIPT_DIR}/../var.env"
fi

MT5="${MT5_CMD:-../mt5}"
[[ -x "$MT5" ]] || MT5="$(cd "$SCRIPT_DIR/.." && pwd)/mt5"

mkdir -p "${OUT_DIR:-./zones}"

cfg_json() {
  python3 - <<'PY'
import json, os
keys = (
    "MS_LEN", "OB_LAST", "OB_LEN", "OB_MODE", "OB_MITI",
    "MS_WINDOW", "MS_WINDOW_ENABLED", "HIDE_OVERLAP", "OVERLAP_KEEP",
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

usage() {
  cat <<EOF
Usage: $0 {mark|json|watch}

  mark   — compute zones, print table + write ${OUT_DIR:-zones}/<SYMBOL>-<TF>-zones.json
  json   — raw JSON to stdout
  watch  — loop mark every LOOP_SLEEP seconds

Config: $ENV_FILE
EOF
}

case "${1:-mark}" in
  mark)  cmd_mark ;;
  json)  cmd_json ;;
  watch) cmd_watch ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac