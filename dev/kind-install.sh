#!/usr/bin/env bash
# kind-install.sh -- Create kind cluster, build/load images, install Helm chart
#
# Usage: ./dev/kind-install.sh
# Env:   RUNTIME_DIR (default: ../biznez-agentic-runtime)
#        CLUSTER_NAME (default: biznez-dev)
#        NAMESPACE (default: biznez)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RUNTIME_DIR="${RUNTIME_DIR:-../biznez-agentic-runtime}"
CLUSTER_NAME="${CLUSTER_NAME:-biznez-dev}"
NAMESPACE="${NAMESPACE:-biznez}"

# 1. Create kind cluster if not exists
if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "==> Creating kind cluster: $CLUSTER_NAME"
  kind create cluster --name "$CLUSTER_NAME"
else
  echo "==> Kind cluster '$CLUSTER_NAME' already exists"
fi

# Ensure kubectl context is set
kubectl cluster-info --context "kind-${CLUSTER_NAME}" > /dev/null 2>&1

# 2. Build and load images
echo "==> Building and loading images"
"$SCRIPT_DIR/load-local-images.sh" kind

# 3. Create namespace if not exists
if ! kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
  echo "==> Creating namespace: $NAMESPACE"
  kubectl create namespace "$NAMESPACE"
fi

# 4. Install Helm chart with eval defaults + dev image tags
echo "==> Installing Helm chart"
helm upgrade --install biznez "$REPO_ROOT/helm/biznez-runtime/" \
  --namespace "$NAMESPACE" \
  --set backend.image.repository=biznez/platform-api \
  --set backend.image.tag=dev \
  --set frontend.image.repository=biznez/web-app \
  --set frontend.image.tag=dev \
  --wait \
  --timeout 300s

# 5. Run smoke test
echo "==> Running smoke test"
"$REPO_ROOT/tests/smoke-test.sh" "$NAMESPACE"

echo "==> Done. Cluster '$CLUSTER_NAME' ready with Biznez in namespace '$NAMESPACE'."
