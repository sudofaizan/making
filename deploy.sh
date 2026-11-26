#!/bin/bash
# Pull latest on trading EC2 and restart dashboard (run from laptop after push.sh).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTANCE_FILE="${INSTANCE_FILE:-$ROOT/instance}"
REMOTE_DIR="${REMOTE_DIR:-/home/ec2-user/making}"

[[ -f "$INSTANCE_FILE" ]] || { echo "deploy: missing $INSTANCE_FILE" >&2; exit 1; }

SSH_LINE=$(grep -v '^[[:space:]]*#' "$INSTANCE_FILE" | head -1 | sed 's/^[[:space:]]*ssh[[:space:]]*//')
[[ -n "$SSH_LINE" ]] || { echo "deploy: empty instance file" >&2; exit 1; }

echo "deploy → $REMOTE_DIR"

# shellcheck disable=SC2086
ssh $SSH_LINE bash -s <<EOF
set -euo pipefail
cd "$REMOTE_DIR"
if [[ -f dashboard/dashboard.env ]]; then
  cp -a dashboard/dashboard.env /tmp/making-dashboard.env.bak
fi
git fetch origin
if ! git merge --ff-only origin/main 2>/dev/null; then
  git checkout -- dashboard/static 2>/dev/null || true
  git merge --ff-only origin/main
fi
if [[ -f /tmp/making-dashboard.env.bak ]]; then
  cp -a /tmp/making-dashboard.env.bak dashboard/dashboard.env
fi
chmod +x init.sh mt5 mt5_api.sh stats_store.sh maintain_order.sh tc_grid_lib.sh TC_BUY.sh TC_SELL.sh 2>/dev/null || true
chmod +x dashboard/server.py dashboard/install-dashboard.sh 2>/dev/null || true
git rev-parse --short HEAD > dashboard/STATIC_VER 2>/dev/null || echo dev > dashboard/STATIC_VER
if systemctl is-enabled making-dashboard &>/dev/null; then
  sudo systemctl restart making-dashboard
  sudo systemctl is-active making-dashboard
fi
echo "deploy ok at \$(git log -1 --oneline)"
EOF