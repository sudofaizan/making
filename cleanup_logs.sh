#!/bin/bash
# Truncate RUN_TAG worker logs on a schedule (init worker).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
[[ "${1:-}" == __MAKING_WORKER__* ]] && shift
# shellcheck source=load_env.sh
source "${SCRIPT_DIR}/load_env.sh"

INTERVAL_SEC=$(( ${LOG_CLEAN_EVERY_HOURS:-12} * 3600 ))
SELF_LOG="${LOG_DIR}/${RUN_TAG}_log_cleanup.log"

clear_logs() {
  local f n=0
  shopt -s nullglob
  for f in "$LOG_DIR"/*.log; do
    [[ "$f" == "$SELF_LOG" ]] && continue
    : >"$f"
    n=$((n + 1))
  done
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$RUN_TAG] cleared ${n} log file(s) in ${LOG_DIR}"
}

echo "[${RUN_TAG}] log_cleanup: every ${LOG_CLEAN_EVERY_HOURS:-12}h → ${LOG_DIR}/*.log (truncate, keeps worker file handles)"
while true; do
  clear_logs
  # Built-in sleep: external sleep inherits flock fd if we ever re-add locking; also dies with this bash.
  builtin sleep "$INTERVAL_SEC"
done