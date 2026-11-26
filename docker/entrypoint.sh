#!/bin/bash
set -euo pipefail
ROOT=/app/making
cd "$ROOT"
export MAKING_ROOT="$ROOT"
export PYTHONPATH="${ROOT}/dashboard${PYTHONPATH:+:$PYTHONPATH}"

if [[ ! -f dashboard/dashboard.env ]]; then
  cp dashboard/dashboard.env.example dashboard/dashboard.env
fi

if [[ ! -s dashboard/STATIC_VER ]]; then
  echo "${MAKING_IMAGE_REV:-docker}" > dashboard/STATIC_VER
fi

mkdir -p logs pids data env

chmod +x init.sh mt5 mt5_api.sh stats_store.sh maintain_order.sh tc_grid_lib.sh TC_BUY.sh TC_SELL.sh 2>/dev/null || true
chmod +x dashboard/server.py dashboard/install-dashboard.sh 2>/dev/null || true
find SWINGKING -maxdepth 1 -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

exec python3 dashboard/server.py