#!/bin/bash
# PSW ack watcher — only started by ../init.sh (worker swingking_ack). Do not nohup this yourself.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
export ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../var.env}"
exec bash "$SCRIPT_DIR/swingking.sh" watch-ack