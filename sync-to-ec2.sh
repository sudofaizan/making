#!/bin/bash
# Push MAKING project to EC2 trading host.
set -euo pipefail

LOCAL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SSH_KEY="${SYNC_SSH_KEY:-$HOME/Downloads/zone3.xauusd.bar.pem}"
SSH_USER_HOST="${SYNC_HOST:-ec2-user@54.203.18.192}"
REMOTE_DIR="${SYNC_REMOTE:-/home/ec2-user/macking}"

if [[ ! -f "$SSH_KEY" ]]; then
  echo "SSH key not found: $SSH_KEY" >&2
  exit 1
fi
chmod 400 "$SSH_KEY" 2>/dev/null || true

RSYNC_SSH=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new)

echo "Sync $LOCAL_DIR -> ${SSH_USER_HOST}:${REMOTE_DIR}"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$SSH_USER_HOST" \
  "sudo chown -R ec2-user:ec2-user '$REMOTE_DIR' 2>/dev/null || true"

rsync -avz \
  -e "${RSYNC_SSH[*]}" \
  --include='*.sh' \
  --include='primary_regime_lib.sh' \
  --include='*.env' \
  --include='mt5' \
  --include='mt5_api.sh' \
  --include='var.env' \
  --include='load_env.sh' \
  --include='env/' \
  --include='env/**' \
  --exclude='*' \
  "$LOCAL_DIR/" "${SSH_USER_HOST}:${REMOTE_DIR}/"

# Ensure mt5 target is the API script (symlink or copy).
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$SSH_USER_HOST" \
  "cd '$REMOTE_DIR' && chmod +x mt5_api.sh mt5 sync-to-ec2.sh init.sh maintain_order.sh tc_grid_lib.sh TC_BUY.sh TC_SELL.sh load_env.sh 2>/dev/null || true; \
   if [[ ! -e mt5 ]] || [[ -d mt5 ]]; then ln -sf mt5_api.sh mt5; fi; \
   chmod +x mt5 mt5_api.sh"

echo "Done."