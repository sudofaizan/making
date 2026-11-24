# shellcheck shell=bash
# Source trading + MT5 settings from ENV_FILE (set by init or export before run).
# Usage: ENV_FILE=/path/to/var.env source load_env.sh

_load_env_fatal() {
  echo "load_env: $*" >&2
  exit 1
}

[[ -n "${BASH_SOURCE[0]:-}" ]] || _load_env_fatal "must be sourced, not executed"

if [[ -z "${ENV_FILE:-}" ]]; then
  _SCRIPT_DIR_LOAD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -f "${_SCRIPT_DIR_LOAD}/var.env" ]]; then
    ENV_FILE="${_SCRIPT_DIR_LOAD}/var.env"
  else
    _load_env_fatal "ENV_FILE unset and var.env not found in ${_SCRIPT_DIR_LOAD}"
  fi
fi

[[ -f "$ENV_FILE" ]] || _load_env_fatal "env file not found: $ENV_FILE"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

_req() {
  local name="$1"
  [[ -n "${!name+x}" && -n "${!name}" ]] || _load_env_fatal "missing required variable: $name (in $ENV_FILE)"
}

for _v in \
  RUN_TAG SYMBOL PERIOD METHOD EMA_TIMEFRAME BUY_MAGIC SELL_MAGIC \
  PRIMARY_VOLUME PRIMARY_VOLUME_MIN PRIMARY_VOLUME_MAX COMMENT \
  LOOP_SLEEP PRICE_EPS POINTS_PROFIT_MIN RETRY_DELAY \
  GAP BASKET_PCT MAX_LEVEL PLACE_COOLDOWN GRID_PRICE_EPS TC_LOOP_SLEEP \
  TC_GRID_ARM_LOSS_PTS TC_BUY_TARGETBASKET TC_SELL_TARGETBASKET \
  MT5_HOST MT5_PORT API_KEY MT5_CURL_MAX MT5_CMD
do
  _req "$_v"
done

if [[ -z "${EMA_CANDLE_COUNT:-}" ]]; then
  if [[ -n "${EMA_BARS:-}" ]]; then
    EMA_CANDLE_COUNT=$EMA_BARS
  elif [[ -n "${EMA_BARS_MULT:-}" ]]; then
    EMA_CANDLE_COUNT=$((PERIOD * EMA_BARS_MULT))
  else
  # Too few bars skew EMA (e.g. 250 vs 600 for period 200 differs by several points).
    EMA_CANDLE_COUNT=$((PERIOD * 10))
    (( EMA_CANDLE_COUNT < 600 )) && EMA_CANDLE_COUNT=600
    (( EMA_CANDLE_COUNT > 5000 )) && EMA_CANDLE_COUNT=5000
  fi
fi
if (( EMA_CANDLE_COUNT < PERIOD + 50 )); then
  _load_env_fatal "EMA_CANDLE_COUNT ($EMA_CANDLE_COUNT) too low for PERIOD $PERIOD"
fi
# Legacy name used in logs; candle fetch count is EMA_CANDLE_COUNT.
EMA_BARS=$EMA_CANDLE_COUNT

_SCRIPT_DIR_LOAD=${_SCRIPT_DIR_LOAD:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
RUN_TAG_DIR="${RUN_TAG//[^a-zA-Z0-9._-]/_}"

if [[ -z "${LOG_DIR:-}" ]]; then
  LOG_DIR="${_SCRIPT_DIR_LOAD}/logs/${RUN_TAG_DIR}"
fi
if [[ -z "${PID_DIR:-}" ]]; then
  PID_DIR="${_SCRIPT_DIR_LOAD}/pids/${RUN_TAG_DIR}"
fi

mkdir -p "$LOG_DIR" "$PID_DIR"

# Aliases used by maintain_order / init (single name for primary lot).
VOLUME="$PRIMARY_VOLUME"

export ENV_FILE RUN_TAG LOG_DIR PID_DIR EMA_BARS EMA_CANDLE_COUNT VOLUME

unset _v _req _load_env_fatal _SCRIPT_DIR_LOAD RUN_TAG_DIR