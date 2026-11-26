#!/bin/bash
# Run on EC2: pull image, migrate data from legacy git checkout, start container.
set -euo pipefail

IMAGE="${MAKING_IMAGE:-dexterquazi/alphafx:making}"
NAME="${MAKING_CONTAINER:-making}"
DATA="${MAKING_DATA:-/home/ec2-user/making-data}"
LEGACY="${MAKING_LEGACY:-/home/ec2-user/making}"

mkdir -p "$DATA"/{logs,pids,data,env}

sync_tree() {
  local src="$1" dst="$2"
  [[ -d "$src" ]] || return 0
  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$src/" "$dst/"
  else
    cp -a "$src/." "$dst/" 2>/dev/null || true
  fi
}

if [[ -d "$LEGACY" ]]; then
  sync_tree "$LEGACY/logs" "$DATA/logs"
  sync_tree "$LEGACY/pids" "$DATA/pids"
  sync_tree "$LEGACY/data" "$DATA/data"
  sync_tree "$LEGACY/env" "$DATA/env"
  [[ -f "$LEGACY/var.env" ]] && cp -a "$LEGACY/var.env" "$DATA/var.env"
  [[ -f "$LEGACY/dashboard/dashboard.env" ]] && cp -a "$LEGACY/dashboard/dashboard.env" "$DATA/dashboard.env"
fi

[[ -f "$DATA/var.env" ]] || cp "$LEGACY/var.env" "$DATA/var.env" 2>/dev/null || true
[[ -f "$DATA/dashboard.env" ]] || cp "$LEGACY/dashboard/dashboard.env.example" "$DATA/dashboard.env" 2>/dev/null || true

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not installed on host" >&2
  exit 1
fi

if ! sudo docker pull "$IMAGE"; then
  echo "pull failed — building from legacy tree ${LEGACY}"
  if [[ ! -f "${LEGACY}/Dockerfile" ]]; then
    echo "no Dockerfile at ${LEGACY} — commit docker files and git pull or push image to hub" >&2
    exit 1
  fi
  (cd "$LEGACY" && git pull --ff-only 2>/dev/null || true)
  REV=$(cd "$LEGACY" && git rev-parse --short HEAD 2>/dev/null || echo dev)
  sudo docker build --build-arg "MAKING_REV=${REV}" -t "$IMAGE" "$LEGACY"
fi
sudo docker stop "$NAME" 2>/dev/null || true
sudo docker rm "$NAME" 2>/dev/null || true

sudo docker run -d \
  --name "$NAME" \
  --restart unless-stopped \
  -p 8877:8877 \
  -e MAKING_ROOT=/app/making \
  -e DASHBOARD_BASE_PATH=/making \
  -v "$DATA/logs:/app/making/logs" \
  -v "$DATA/pids:/app/making/pids" \
  -v "$DATA/data:/app/making/data" \
  -v "$DATA/env:/app/making/env" \
  -v "$DATA/var.env:/app/making/var.env" \
  -v "$DATA/dashboard.env:/app/making/dashboard/dashboard.env" \
  "$IMAGE"

if systemctl is-enabled making-dashboard &>/dev/null; then
  sudo systemctl disable --now making-dashboard 2>/dev/null || true
  echo "disabled systemd making-dashboard (replaced by container)"
fi

sleep 2
sudo docker exec "$NAME" curl -fsS "http://127.0.0.1:8877/making/api/health" && echo " health ok"
sudo docker ps --filter "name=$NAME"
echo "MAKING container up — restart worker stacks from dashboard if they were running before deploy"