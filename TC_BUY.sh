#!/bin/bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TC_SCRIPT_DIR=$SCRIPT_DIR
cd "$SCRIPT_DIR" || exit 1
[[ "${1:-}" == __MAKING_WORKER__* ]] && shift
# shellcheck source=load_env.sh
source "${SCRIPT_DIR}/load_env.sh"

_singleton_lock="${PID_DIR}/TC_BUY.singleton"
mkdir -p "$(dirname "$_singleton_lock")"
exec 9>>"$_singleton_lock"
if ! flock -n 9; then
  echo "[${RUN_TAG}] TC_BUY: duplicate instance — exit"
  exit 0
fi

MAGIC=$BUY_MAGIC
SIDE=buy
TARGETBASKET=$TC_BUY_TARGETBASKET

# shellcheck source=tc_grid_lib.sh
source "$SCRIPT_DIR/tc_grid_lib.sh"
tc_grid_main