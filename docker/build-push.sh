#!/bin/bash
# Build linux/amd64 image and push dexterquazi/alphafx:making
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

IMAGE="${MAKING_IMAGE:-dexterquazi/alphafx:making}"
REV=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"

echo "build ${IMAGE} (${REV}, ${PLATFORM})"
if command -v docker buildx >/dev/null 2>&1; then
  docker buildx build --platform "$PLATFORM" \
    --build-arg "MAKING_REV=${REV}" \
    -t "$IMAGE" \
    --push \
    .
else
  docker build --build-arg "MAKING_REV=${REV}" -t "$IMAGE" .
  docker push "$IMAGE"
fi
echo "pushed ${IMAGE}"