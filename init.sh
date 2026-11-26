#!/bin/bash
# Place regime PRIMARY pendings, then manage background: maintain_order, TC_BUY, TC_SELL.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1

ENV_FILE=""
CMD=""
PS_ALL=0
PS_JSON=0

usage() {
  cat <<EOF
Usage: $0 [-e ENV_FILE] {start|stop|restart|ps} [ps options]

  -e ENV_FILE   trading + MT5 settings (default: ${SCRIPT_DIR}/var.env)

  start    — place PRIMARY; workers: maintain_order, TC_BUY, TC_SELL, swingking_ack, log_cleanup
  stop     — stop all background workers for this RUN_TAG
  restart  — stop then start
  ps           — worker status for one RUN_TAG (use -e or default var.env)
  ps --all     — all stacks: var.env + env/*.env (no -e required)
  ps --json    — JSON for one stack; add --all for every env file

Env defines RUN_TAG, LOG_DIR, PID_DIR.   Multi-asset (one init per env, same VPS; start/stop are per RUN_TAG only):
  $0 -e var.env start          # GOLD
  $0 -e env/ETH.env start     # ETHUSD (separate logs/pids/magics; does not stop GOLD)
  $0 ps --all                 # table of every worker on this host
  $0 -e env/ETH.env ps
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      [[ "$CMD" == ps ]] || { echo "init: --all only applies to ps" >&2; usage; exit 1; }
      PS_ALL=1
      shift
      ;;
    --json)
      [[ "$CMD" == ps ]] || { echo "init: --json only applies to ps" >&2; usage; exit 1; }
      PS_JSON=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "init: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

WORKERS=(
  "maintain_order:maintain_order.sh"
  "TC_BUY:TC_BUY.sh"
  "TC_SELL:TC_SELL.sh"
  "swingking_ack:SWINGKING/watch_ack.sh"
  "log_cleanup:cleanup_logs.sh"
)

pid_file() { echo "${PID_DIR}/${RUN_TAG}_$1.pid"; }
log_file() { echo "${LOG_DIR}/${RUN_TAG}_$1.log"; }

env_file_relpath() {
  local abs="$1"
  if [[ "$abs" == "$SCRIPT_DIR"/* ]]; then
    echo "${abs#"$SCRIPT_DIR"/}"
  else
    echo "$abs"
  fi
}

load_env_for() {
  local f="$1"
  [[ "$f" = /* ]] || f="${SCRIPT_DIR}/${f}"
  ENV_FILE="$f"
  export ENV_FILE
  # shellcheck source=load_env.sh
  source "${SCRIPT_DIR}/load_env.sh"
}

discover_env_files() {
  local f
  if [[ -f "${SCRIPT_DIR}/var.env" ]]; then
    echo "${SCRIPT_DIR}/var.env"
  fi
  for f in "${SCRIPT_DIR}"/env/*.env; do
    [[ -f "$f" ]] || continue
    echo "$f"
  done
}

# Visible in ps/pgrep so GOLD + ETHUSD workers do not kill each other (env vars are not in cmdline).
worker_instance_id() { echo "__MAKING_WORKER__${RUN_TAG}__$1__"; }

list_worker_pids() {
  local name="$1"
  pgrep -f "$(worker_instance_id "$name")" 2>/dev/null || true
}

is_running() {
  local name="$1" pf pid
  pf=$(pid_file "$name")
  [[ -f "$pf" ]] || return 1
  pid=$(cat "$pf")
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# stop/restart: kill children too (log_cleanup used to leave orphan sleep holding flock fd).
kill_worker_tree() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

release_stale_log_cleanup_lock() {
  local lock="${PID_DIR}/log_cleanup.singleton"
  [[ -e "$lock" ]] || return 0
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "$lock" 2>/dev/null || true
  fi
  rm -f "$lock"
}

stop_one() {
  local name="$1" script="$2" pf pid spid
  pf=$(pid_file "$name")
  if is_running "$name"; then
    pid=$(cat "$pf")
    echo "stop $name (pid $pid)"
    kill_worker_tree "$pid"
  fi
  while IFS= read -r spid; do
    [[ -z "$spid" ]] && continue
    echo "stop stray $name (pid $spid)"
    kill_worker_tree "$spid"
  done < <(list_worker_pids "$name")
  [[ "$name" == log_cleanup ]] && release_stale_log_cleanup_lock
  rm -f "$pf"
}

start_one() {
  local name="$1" script="$2" pf lf spid iid
  pf=$(pid_file "$name")
  lf=$(log_file "$name")
  iid=$(worker_instance_id "$name")
  if is_running "$name"; then
    echo "already running $name (pid $(cat "$pf"))"
    return 0
  fi
  while IFS= read -r spid; do
    [[ -z "$spid" ]] && continue
    echo "kill orphan $name (pid $spid) before start"
    kill_worker_tree "$spid"
  done < <(list_worker_pids "$name")
  [[ "$name" == log_cleanup ]] && release_stale_log_cleanup_lock
  rm -f "$pf"
  echo "start $name ($RUN_TAG) → $lf"
  if [[ "$script" == SWINGKING/* ]]; then
    nohup env MAKING_ENV_FILE="$ENV_FILE" ENV_FILE="$ENV_FILE" \
      bash "$SCRIPT_DIR/$script" "$iid" >>"$lf" 2>&1 &
  else
    nohup env ENV_FILE="$ENV_FILE" bash "$SCRIPT_DIR/$script" "$iid" >>"$lf" 2>&1 &
  fi
  echo $! >"$pf"
  sleep 0.3
  if ! kill -0 "$(cat "$pf")" 2>/dev/null; then
    echo "warn: $name exited immediately — check $(log_file "$name")" >&2
    rm -f "$pf"
    return 1
  fi
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
  if [[ -f "${SCRIPT_DIR}/stats_store.sh" ]]; then
    # shellcheck source=stats_store.sh
    source "${SCRIPT_DIR}/stats_store.sh"
    stats_session_start || true
  fi
  echo "=== started — logs: $(log_file maintain_order) $(log_file TC_BUY) $(log_file TC_SELL) $(log_file swingking_ack) $(log_file log_cleanup) ==="
}

cmd_stop() {
  echo "=== init stop RUN_TAG=$RUN_TAG ==="
  local pair name script
  for pair in "${WORKERS[@]}"; do
    name="${pair%%:*}"
    script="${pair##*:}"
    stop_one "$name" "$script"
  done
  echo "=== stopped ==="
}

cmd_restart() {
  cmd_stop
  sleep 1
  cmd_start
}

# Docker-style status for one worker; sets _PS_* globals.
collect_worker_ps() {
  local name="$1"
  local pf pid et iid live_pids n_live filepid
  _PS_WORKER="$name"
  pf=$(pid_file "$name")
  if is_running "$name"; then
    pid=$(cat "$pf")
    _PS_STATUS="Up"
    _PS_PID="$pid"
    et=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ' || true)
    _PS_UPTIME="${et:--}"
    _PS_RUNNING=1
    return
  fi

  iid=$(worker_instance_id "$name")
  live_pids=$(pgrep -f "$iid" 2>/dev/null || true)
  if [[ -n "$live_pids" ]]; then
    n_live=$(printf '%s\n' "$live_pids" | sed '/^$/d' | wc -l | tr -d ' ')
    pid=$(printf '%s\n' "$live_pids" | head -1)
    _PS_PID="$pid"
    et=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ' || true)
    _PS_UPTIME="${et:--}"
    _PS_RUNNING=1
    if [[ "$n_live" -gt 1 ]]; then
      _PS_STATUS="Up (${n_live}x dup)"
    elif [[ -f "$pf" ]]; then
      filepid=$(cat "$pf")
      if [[ "$filepid" != "$pid" ]]; then
        _PS_STATUS="Up (heal pid)"
        echo "$pid" >"$pf"
      else
        _PS_STATUS="Up"
      fi
    else
      _PS_STATUS="Up (heal pid)"
      echo "$pid" >"$pf"
    fi
    return
  fi

  if [[ -f "$pf" ]]; then
    pid=$(cat "$pf")
    rm -f "$pf"
    _PS_STATUS="Exited (stale)"
    _PS_PID="$pid"
    _PS_UPTIME="-"
    _PS_RUNNING=0
  else
    _PS_STATUS="Exited"
    _PS_PID="-"
    _PS_UPTIME="-"
    _PS_RUNNING=0
  fi
}

_PS_HDR_RUNTAG=7
_PS_HDR_SYMBOL=8
_PS_HDR_WORKER=16
_PS_HDR_STATUS=22
_PS_HDR_PID=8
_PS_HDR_UPTIME=10

print_ps_header() {
  printf "%-${_PS_HDR_RUNTAG}s %-${_PS_HDR_SYMBOL}s %-${_PS_HDR_WORKER}s %-${_PS_HDR_STATUS}s %-${_PS_HDR_PID}s %-${_PS_HDR_UPTIME}s %s\n" \
    "RUNTAG" "SYMBOL" "WORKER" "STATUS" "PID" "UPTIME" "ENV"
  printf "%-${_PS_HDR_RUNTAG}s %-${_PS_HDR_SYMBOL}s %-${_PS_HDR_WORKER}s %-${_PS_HDR_STATUS}s %-${_PS_HDR_PID}s %-${_PS_HDR_UPTIME}s %s\n" \
    "-------" "--------" "----------------" "----------------------" "--------" "----------" "---------"
}

print_ps_row() {
  local env_rel="$1"
  printf "%-${_PS_HDR_RUNTAG}s %-${_PS_HDR_SYMBOL}s %-${_PS_HDR_WORKER}s %-${_PS_HDR_STATUS}s %-${_PS_HDR_PID}s %-${_PS_HDR_UPTIME}s %s\n" \
    "$RUN_TAG" "$SYMBOL" "$_PS_WORKER" "$_PS_STATUS" "$_PS_PID" "$_PS_UPTIME" "$env_rel"
}

cmd_ps_for_loaded_env() {
  local pair name env_rel running=0 stopped=0
  env_rel=$(env_file_relpath "$ENV_FILE")
  for pair in "${WORKERS[@]}"; do
    name="${pair%%:*}"
    collect_worker_ps "$name"
    print_ps_row "$env_rel"
    if [[ "$_PS_RUNNING" == 1 ]]; then
      running=$((running + 1))
    else
      stopped=$((stopped + 1))
    fi
  done
  echo ""
  printf "Summary [%s]: %d up, %d exited (%d workers)\n" "$RUN_TAG" "$running" "$stopped" "${#WORKERS[@]}"
}

cmd_ps() {
  local running=0 stopped=0 total=0
  print_ps_header
  cmd_ps_for_loaded_env
}

json_worker_obj() {
  local name="$1" lf
  collect_worker_ps "$name"
  lf=$(log_file "$name")
  if [[ "$_PS_PID" == "-" ]]; then
    jq -nc \
      --arg worker "$name" \
      --arg status "$_PS_STATUS" \
      --argjson running "$_PS_RUNNING" \
      --arg uptime "$_PS_UPTIME" \
      --arg log "$lf" \
      '{worker:$worker, status:$status, running:$running, pid:null, uptime:$uptime, log:$log}'
  else
    jq -nc \
      --arg worker "$name" \
      --arg status "$_PS_STATUS" \
      --argjson running "$_PS_RUNNING" \
      --argjson pid "$_PS_PID" \
      --arg uptime "$_PS_UPTIME" \
      --arg log "$lf" \
      '{worker:$worker, status:$status, running:$running, pid:$pid, uptime:$uptime, log:$log}'
  fi
}

json_workers_array() {
  local pair name first=1
  printf '['
  for pair in "${WORKERS[@]}"; do
    name="${pair%%:*}"
    [[ $first -eq 1 ]] || printf ','
    first=0
    json_worker_obj "$name"
  done
  printf ']'
}

json_stack_for_loaded_env() {
  local env_rel up=0 ex=0 pair name workers
  env_rel=$(env_file_relpath "$ENV_FILE")
  workers=$(json_workers_array)
  for pair in "${WORKERS[@]}"; do
    name="${pair%%:*}"
    collect_worker_ps "$name"
    if [[ "$_PS_RUNNING" == 1 ]]; then up=$((up + 1)); else ex=$((ex + 1)); fi
  done
  jq -nc \
    --arg run_tag "$RUN_TAG" \
    --arg symbol "$SYMBOL" \
    --arg env_file "$env_rel" \
    --arg env_path "$ENV_FILE" \
    --argjson workers "$workers" \
    --argjson up "$up" \
    --argjson ex "$ex" \
    --argjson total "${#WORKERS[@]}" \
    '{run_tag:$run_tag, symbol:$symbol, env_file:$env_file, env_path:$env_path,
      workers:$workers, summary:{up:$up, exited:$ex, total:$total}}'
}

cmd_ps_json_all() {
  local ef stacks='[]' total_up=0 total_ex=0 stacks_n=0 stack up ex
  while IFS= read -r ef; do
    [[ -z "$ef" ]] && continue
    stacks_n=$((stacks_n + 1))
    load_env_for "$ef"
    stack=$(json_stack_for_loaded_env)
    stacks=$(echo "$stacks" | jq --argjson s "$stack" '. + [$s]')
    up=$(echo "$stack" | jq '.summary.up')
    ex=$(echo "$stack" | jq '.summary.exited')
    total_up=$((total_up + up))
    total_ex=$((total_ex + ex))
  done < <(discover_env_files)
  jq -nc \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson stacks "$stacks" \
    --argjson stacks_n "$stacks_n" \
    --argjson total_up "$total_up" \
    --argjson total_ex "$total_ex" \
  '{
    generated_at:$generated_at,
    stacks:$stacks,
    total:{stacks:$stacks_n, up:$total_up, exited:$total_ex, workers:($total_up + $total_ex)}
  }'
}

cmd_ps_json_one() {
  local stack
  stack=$(json_stack_for_loaded_env)
  jq -nc \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson stacks "[$stack]" \
    --argjson total_up "$(echo "$stack" | jq '.summary.up')" \
    --argjson total_ex "$(echo "$stack" | jq '.summary.exited')" \
    '{
      generated_at:$generated_at,
      stacks:$stacks,
      total:{stacks:1, up:$total_up, exited:$total_ex, workers:($total_up + $total_ex)}
    }'
}

cmd_ps_all() {
  local ef stacks=0 total_up=0 total_ex=0
  print_ps_header
  while IFS= read -r ef; do
    [[ -z "$ef" ]] && continue
    stacks=$((stacks + 1))
    load_env_for "$ef"
    local pair name env_rel
    env_rel=$(env_file_relpath "$ef")
    for pair in "${WORKERS[@]}"; do
      name="${pair%%:*}"
      collect_worker_ps "$name"
      print_ps_row "$env_rel"
      if [[ "$_PS_RUNNING" == 1 ]]; then
        total_up=$((total_up + 1))
      else
        total_ex=$((total_ex + 1))
      fi
    done
  done < <(discover_env_files)
  echo ""
  printf "Total: %d stack(s), %d up, %d exited (%d workers)\n" \
    "$stacks" "$total_up" "$total_ex" "$((total_up + total_ex))"
}

if [[ "$CMD" == ps ]]; then
  if [[ "$PS_JSON" == 1 ]]; then
    if [[ "$PS_ALL" == 1 ]]; then
      cmd_ps_json_all
    else
      if [[ -z "$ENV_FILE" ]]; then
        ENV_FILE="${SCRIPT_DIR}/var.env"
      fi
      [[ "$ENV_FILE" = /* ]] || ENV_FILE="${SCRIPT_DIR}/${ENV_FILE}"
      load_env_for "$ENV_FILE"
      cmd_ps_json_one
    fi
    exit 0
  fi
  if [[ "$PS_ALL" == 1 ]]; then
    cmd_ps_all
    exit 0
  fi
fi

if [[ -z "$ENV_FILE" ]]; then
  ENV_FILE="${SCRIPT_DIR}/var.env"
fi
[[ "$ENV_FILE" = /* ]] || ENV_FILE="${SCRIPT_DIR}/${ENV_FILE}"
load_env_for "$ENV_FILE"

if [[ "$CMD" != ps ]]; then
  # shellcheck source=primary_regime_lib.sh
  source "${SCRIPT_DIR}/primary_regime_lib.sh"
  MT5="$MT5_CMD"
  [[ -x "$MT5" ]] || MT5="$(command -v mt5 2>/dev/null || true)"
  [[ -n "$MT5" ]] || { echo "MT5_CMD not executable: $MT5_CMD" >&2; exit 1; }
fi

case "$CMD" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  ps)      cmd_ps ;;
esac