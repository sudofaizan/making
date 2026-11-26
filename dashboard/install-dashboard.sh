#!/bin/bash
# Install MAKING dashboard on EC2: systemd service + alphafx-router nginx /making/
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAKING_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ROUTER_DOCKER="${ROUTER_DOCKER:-$HOME/alphafx-router-docker}"
ROUTER_CONTAINER="${ROUTER_CONTAINER:-alphafx-router}"
INCLUDE_LINE='include /etc/nginx/conf.d/making-proxy.inc;'
MARK='# MAKING dashboard (install-dashboard.sh)'

if [[ "$(id -un)" != ec2-user ]]; then
  echo "Run as ec2-user on the trading EC2 host." >&2
  exit 1
fi

chmod +x "$SCRIPT_DIR/server.py"

if [[ ! -f "$SCRIPT_DIR/dashboard.env" ]]; then
  cp "$SCRIPT_DIR/dashboard.env.example" "$SCRIPT_DIR/dashboard.env"
  echo "Created dashboard.env — default password: alphafx (change DASHBOARD_PASSWORD)"
fi

sudo cp "$SCRIPT_DIR/making-dashboard.service" /etc/systemd/system/making-dashboard.service
sudo sed -i "s|/home/ec2-user/making|$MAKING_ROOT|g" /etc/systemd/system/making-dashboard.service
sudo systemctl daemon-reload
sudo systemctl enable --now making-dashboard.service
sudo systemctl status making-dashboard.service --no-pager || true

if [[ -d "$ROUTER_DOCKER/nginx/conf.d" ]]; then
  cp "$SCRIPT_DIR/nginx-making-proxy.inc" "$ROUTER_DOCKER/nginx/conf.d/making-proxy.inc"
  if ! grep -qF 'making-proxy.inc' "$ROUTER_DOCKER/nginx/conf.d/xauusd-bar-routes.inc" 2>/dev/null; then
    printf '\n%s\n%s\n' "$MARK" "$INCLUDE_LINE" >>"$ROUTER_DOCKER/nginx/conf.d/xauusd-bar-routes.inc"
    echo "Appended making-proxy.inc to xauusd-bar-routes.inc — rebuild router image next."
  fi
  if [[ -x "$ROUTER_DOCKER/entrypoint.sh" ]] && command -v sudo docker >/dev/null 2>&1; then
    echo "Rebuilding alphafx-router image (nginx picks up making-proxy.inc)…"
    (cd "$ROUTER_DOCKER" && sudo docker build -t dexterquazi/alphafx:router .)
    if sudo docker inspect "$ROUTER_CONTAINER" >/dev/null 2>&1; then
      echo "Restart $ROUTER_CONTAINER (docker restart) — image/env unchanged, new nginx config baked in."
      sudo docker restart "$ROUTER_CONTAINER"
    else
      echo "WARN: $ROUTER_CONTAINER missing — recreate it with your usual docker run (see README)." >&2
    fi
    echo "Test: curl -sS http://127.0.0.1:8877/api/health"
    echo "From router: sudo docker exec $ROUTER_CONTAINER curl -sS http://172.17.0.1:8877/api/health"
  fi
else
  echo "Router docker tree not at $ROUTER_DOCKER — copy nginx-making-proxy.inc manually." >&2
fi

echo ""
echo "Dashboard API: http://127.0.0.1:8877/api/health"
echo "Public URL (after router reload): https://zone4.xauusd.bar/making/"
echo "Sign in at /making/login with DASHBOARD_PASSWORD from dashboard.env"