# Append-only trading stats per RUN_TAG (data/<RUN_TAG>/events.jsonl). Source after load_env.sh.
# shellcheck shell=bash

stats_dir() {
  local root="${MAKING_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  echo "${root}/data/${RUN_TAG}"
}

stats_event() {
  local event_type="$1"
  shift
  local dir f
  dir=$(stats_dir)
  mkdir -p "$dir"
  f="${dir}/events.jsonl"
  STATS_EVENT_TYPE="$event_type" STATS_RUN_TAG="$RUN_TAG" \
    python3 - "$f" "$@" <<'PY'
import json, os, sys
from datetime import datetime, timezone

path = sys.argv[1]
etype = os.environ["STATS_EVENT_TYPE"]
run_tag = os.environ["STATS_RUN_TAG"]
row = {
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "run_tag": run_tag,
    "type": etype,
}
for arg in sys.argv[2:]:
    if "=" not in arg:
        continue
    k, v = arg.split("=", 1)
    if v == "":
        continue
    try:
        if v.lstrip("-").replace(".", "", 1).isdigit():
            row[k] = float(v) if "." in v else int(v)
        else:
            row[k] = v
    except ValueError:
        row[k] = v
with open(path, "a", encoding="utf-8") as fp:
    fp.write(json.dumps(row, separators=(",", ":")) + "\n")
PY
}

stats_session_start() {
  stats_event session_start source=init
}

stats_order_created() {
  local otype="${1:-}" side="${2:-}" comment="${3:-}" magic="${4:-}"
  stats_event order_created \
    "order_type=$otype" "side=$side" "comment=$comment" "magic=$magic"
}

stats_basket_closed() {
  local magic="${1:-}" delta="${2:-0}" buy_c="${3:-0}" sell_c="${4:-0}"
  stats_event basket_closed \
    "magic=$magic" "pnl_delta=$delta" "buy_closed=$buy_c" "sell_closed=$sell_c"
}

stats_floating_sample() {
  local float_pnl="${1:-0}"
  stats_event pnl_sample "floating_pnl=$float_pnl"
}