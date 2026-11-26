#!/bin/bash
# PSW ack watcher — only started by ../init.sh (worker swingking_ack). Do not nohup this yourself.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAKING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"
# Absolute path so swingking.sh + load_env work when cwd is SWINGKING/
if [[ -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
  export MAKING_ENV_FILE="$(cd "$(dirname "$ENV_FILE")" && pwd)/$(basename "$ENV_FILE")"
else
  export MAKING_ENV_FILE="$MAKING_DIR/var.env"
fi
unset ENV_FILE
_worker_marker="${1:-}"
if [[ "$_worker_marker" == __MAKING_WORKER__* ]]; then
  exec bash "$SCRIPT_DIR/swingking.sh" watch-ack "$_worker_marker"
fi
exec bash "$SCRIPT_DIR/swingking.sh" watch-ack