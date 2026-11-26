#!/bin/bash
# Commit all changes, push, then deploy on EC2 (instance file).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"

if [[ -z "$(git status --porcelain)" ]]; then
  echo "push: nothing to commit"
else
  git add .
  git commit -m "update"
fi
git push
if [[ "${MAKING_SKIP_DOCKER_PUSH:-}" != 1 ]]; then
  chmod +x "$ROOT/docker/build-push.sh"
  "$ROOT/docker/build-push.sh" || {
    echo "push: docker build/push failed (set MAKING_SKIP_DOCKER_PUSH=1 to skip)" >&2
    exit 1
  }
fi
"$ROOT/deploy.sh"