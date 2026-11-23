#!/bin/bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TC_SCRIPT_DIR=$SCRIPT_DIR
cd "$SCRIPT_DIR" || exit 1
# shellcheck source=load_env.sh
source "${SCRIPT_DIR}/load_env.sh"

MAGIC=$SELL_MAGIC
SIDE=sell
TARGETBASKET=$TC_SELL_TARGETBASKET

# shellcheck source=tc_grid_lib.sh
source "$SCRIPT_DIR/tc_grid_lib.sh"
tc_grid_main