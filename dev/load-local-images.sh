#!/usr/bin/env bash
# load-local-images.sh -- Build images from runtime repo and load into local K8s
#
# Usage: ./dev/load-local-images.sh [kind|minikube]
# Env:   RUNTIME_DIR (default: ../biznez-agentic-runtime)

set -euo pipefail

RUNTIME_DIR="${RUNTIME_DIR:-../biznez-agentic-runtime}"
LOADER="${1:-kind}"

if [ ! -d "$RUNTIME_DIR" ]; then
  echo "ERROR: Runtime repo not found at $RUNTIME_DIR"
  echo "Set RUNTIME_DIR to the path of the biznez-agentic-runtime repo"
  exit 1
fi

echo "==> Building backend image from $RUNTIME_DIR/Dockerfile"
docker build -t biznez/platform-api:dev -f "$RUNTIME_DIR/Dockerfile" "$RUNTIME_DIR"

echo "==> Building frontend image from $RUNTIME_DIR/frontend/Dockerfile"
docker build -t biznez/web-app:dev -f "$RUNTIME_DIR/frontend/Dockerfile" "$RUNTIME_DIR/frontend"

IMAGES=(
  "biznez/platform-api:dev"
  "biznez/web-app:dev"
)

case "$LOADER" in
  kind)
    echo "==> Loading images into kind cluster"
    for img in "${IMAGES[@]}"; do
      kind load docker-image "$img"
    done
    ;;
  minikube)
    echo "==> Loading images into minikube"
    for img in "${IMAGES[@]}"; do
      minikube image load "$img"
    done
    ;;
  *)
    echo "ERROR: Unknown loader '$LOADER'. Use 'kind' or 'minikube'."
    exit 1
    ;;
esac

echo "==> Images loaded successfully"
