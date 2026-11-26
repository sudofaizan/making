#!/bin/bash
# Truncate RUN_TAG worker logs on a schedule (init worker).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
# shellcheck source=load_env.sh
source "${SCRIPT_DIR}/load_env.sh"

_singleton_lock="${PID_DIR}/log_cleanup.singleton"
mkdir -p "$(dirname "$_singleton_lock")"
exec 9>>"$_singleton_lock"
if ! flock -n 9; then
  echo "[${RUN_TAG}] log_cleanup: duplicate instance — exit"
  exit 0
fi

INTERVAL_SEC=$(( ${LOG_CLEAN_EVERY_HOURS:-12} * 3600 ))

clear_logs() {
  local f n=0
  shopt -s nullglob
  for f in "$LOG_DIR"/*.log; do
    : >"$f"
    n=$((n + 1))
  done
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$RUN_TAG] cleared ${n} log file(s) in ${LOG_DIR}"
}

echo "[${RUN_TAG}] log_cleanup: every ${LOG_CLEAN_EVERY_HOURS:-12}h → ${LOG_DIR}/*.log (truncate, keeps worker file handles)"
while true; do
  clear_logs
  sleep "$INTERVAL_SEC"
done