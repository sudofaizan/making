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
"$ROOT/deploy.sh"