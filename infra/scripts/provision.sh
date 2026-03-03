#!/usr/bin/env bash
# =============================================================================
# provision.sh -- Deploy Biznez runtime to a GKE eval environment
# =============================================================================
# Orchestrates: namespace creation, secret generation, Helm install, health check.
# Called by the provision-eval.yml workflow after Terraform creates the cluster.
#
# Usage:
#   ./provision.sh --namespace biznez --release biznez \
#     --values-file ./infra/values/eval-gke.yaml \
#     --chart-dir ./helm/biznez-runtime \
#     --ar-url <ar-url> --images-lock ./helm/biznez-runtime/images.lock
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers (match biznez-cli pattern)
# ---------------------------------------------------------------------------
NO_COLOR="${NO_COLOR:-false}"
_color_enabled() { [ "$NO_COLOR" = "false" ] && [ -t 1 ]; }

info()  { if _color_enabled; then printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; else printf '[INFO]  %s\n' "$*"; fi; }
ok()    { if _color_enabled; then printf '\033[0;32m[OK]\033[0m    %s\n' "$*"; else printf '[OK]    %s\n' "$*"; fi; }
warn()  { if _color_enabled; then printf '\033[0;33m[WARN]\033[0m  %s\n' "$*" >&2; else printf '[WARN]  %s\n' "$*" >&2; fi; }
error() { if _color_enabled; then printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; else printf '[ERROR] %s\n' "$*" >&2; fi; }

# ---------------------------------------------------------------------------
# Exit codes (match biznez-cli)
# ---------------------------------------------------------------------------
readonly EXIT_OK=0
readonly EXIT_PREREQ=2
readonly EXIT_KUBE=4
readonly EXIT_SECRET=5
readonly EXIT_HEALTH=6

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
_CLEANUP_FILES=""
# shellcheck disable=SC2329
_cleanup() {
    if [ -n "$_CLEANUP_FILES" ]; then
        # shellcheck disable=SC2086
        rm -f $_CLEANUP_FILES
    fi
}
trap _cleanup EXIT

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
NAMESPACE="biznez"
RELEASE="biznez"
VALUES_FILE=""
CHART_DIR=""
AR_URL=""
IMAGES_LOCK=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)    NAMESPACE="$2"; shift 2 ;;
        --release)      RELEASE="$2"; shift 2 ;;
        --values-file)  VALUES_FILE="$2"; shift 2 ;;
        --chart-dir)    CHART_DIR="$2"; shift 2 ;;
        --ar-url)       AR_URL="$2"; shift 2 ;;
        --images-lock)  IMAGES_LOCK="$2"; shift 2 ;;
        *)              error "Unknown argument: $1"; exit "$EXIT_PREREQ" ;;
    esac
done

# Validate required args
for var_name in VALUES_FILE CHART_DIR AR_URL IMAGES_LOCK; do
    if [ -z "${!var_name}" ]; then
        error "Missing required argument: --$(echo "$var_name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
        exit "$EXIT_PREREQ"
    fi
done

# ---------------------------------------------------------------------------
# Step 1: Preflight
# ---------------------------------------------------------------------------
info "Running preflight checks..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="${SCRIPT_DIR}/../../cli/biznez-cli"

for cmd in kubectl helm; do
    if ! command -v "$cmd" &>/dev/null; then
        error "$cmd not found in PATH"
        exit "$EXIT_PREREQ"
    fi
done

if [ ! -x "$CLI" ]; then
    error "biznez-cli not found or not executable: $CLI"
    exit "$EXIT_PREREQ"
fi

if [ ! -f "$VALUES_FILE" ]; then
    error "Values file not found: $VALUES_FILE"
    exit "$EXIT_PREREQ"
fi

if [ ! -d "$CHART_DIR" ]; then
    error "Chart directory not found: $CHART_DIR"
    exit "$EXIT_PREREQ"
fi

if [ ! -f "$IMAGES_LOCK" ]; then
    error "images.lock not found: $IMAGES_LOCK"
    exit "$EXIT_PREREQ"
fi

# Verify cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
    error "Cannot connect to Kubernetes cluster. Check kubeconfig."
    exit "$EXIT_KUBE"
fi

ok "Preflight checks passed"

# ---------------------------------------------------------------------------
# Step 2: Create namespace
# ---------------------------------------------------------------------------
info "Creating namespace $NAMESPACE..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "Namespace $NAMESPACE ready"

# ---------------------------------------------------------------------------
# Step 3: Generate admin password
# ---------------------------------------------------------------------------
info "Generating admin credentials..."
ADMIN_PASS=$(openssl rand -base64 24)
kubectl create secret generic biznez-eval-admin-creds \
    --from-literal=password="$ADMIN_PASS" \
    --dry-run=client -o yaml | kubectl apply -f - -n "$NAMESPACE" >/dev/null
unset ADMIN_PASS
ok "Admin credentials stored in biznez-eval-admin-creds secret"

# ---------------------------------------------------------------------------
# Step 4: Generate app secrets
# ---------------------------------------------------------------------------
info "Generating application secrets..."
SECRETS_YAML=$("$CLI" -n "$NAMESPACE" generate-secrets --format yaml --no-docker-fernet 2>/dev/null) || {
    error "Failed to generate secrets via biznez-cli"
    exit "$EXIT_SECRET"
}
echo "$SECRETS_YAML" | kubectl apply -f - -n "$NAMESPACE" >/dev/null || {
    error "Failed to apply secrets to namespace $NAMESPACE"
    exit "$EXIT_SECRET"
}
unset SECRETS_YAML
ok "Application secrets generated and applied"

# ---------------------------------------------------------------------------
# Step 5: Parse image tags from images.lock
# ---------------------------------------------------------------------------
info "Parsing image tags from images.lock..."

# Parse tags using grep/awk (no yq dependency)
parse_image_tag() {
    local image_name="$1"
    local lock_file="$2"
    # Find the image block and extract its tag
    awk -v name="$image_name" '
        /^  - name:/ { found = ($3 == name) }
        found && /^    tag:/ { gsub(/"/, "", $2); print $2; exit }
    ' "$lock_file"
}

BACKEND_TAG=$(parse_image_tag "platform-api" "$IMAGES_LOCK")
FRONTEND_TAG=$(parse_image_tag "web-app" "$IMAGES_LOCK")
POSTGRES_TAG=$(parse_image_tag "postgres" "$IMAGES_LOCK")
GATEWAY_TAG=$(parse_image_tag "agentgateway" "$IMAGES_LOCK")

for tag_var in BACKEND_TAG FRONTEND_TAG POSTGRES_TAG GATEWAY_TAG; do
    if [ -z "${!tag_var}" ]; then
        error "Could not parse tag for $tag_var from images.lock"
        exit "$EXIT_PREREQ"
    fi
done

ok "Image tags: backend=$BACKEND_TAG frontend=$FRONTEND_TAG postgres=$POSTGRES_TAG gateway=$GATEWAY_TAG"

# ---------------------------------------------------------------------------
# Step 6: Helm install
# ---------------------------------------------------------------------------
info "Installing Biznez runtime via Helm..."
helm upgrade --install "$RELEASE" "$CHART_DIR" \
    -f "$VALUES_FILE" \
    --set global.imageRegistry="$AR_URL" \
    --set backend.image.repository=platform-api \
    --set backend.image.tag="$BACKEND_TAG" \
    --set backend.existingSecret="${RELEASE}-backend-secrets" \
    --set frontend.image.repository=web-app \
    --set frontend.image.tag="$FRONTEND_TAG" \
    --set postgres.image.repository=postgres \
    --set postgres.image.tag="$POSTGRES_TAG" \
    --set postgres.existingSecret="${RELEASE}-postgres-secrets" \
    --set gateway.image.repository=agentgateway \
    --set gateway.image.tag="$GATEWAY_TAG" \
    -n "$NAMESPACE" --wait --timeout 300s || {
    error "Helm install failed"
    exit "$EXIT_KUBE"
}
ok "Helm release $RELEASE installed"

# ---------------------------------------------------------------------------
# Step 7: Wait for rollouts (label selectors)
# ---------------------------------------------------------------------------
info "Waiting for deployments to roll out..."

wait_for_component() {
    local component="$1"
    local deploy_name
    deploy_name=$(kubectl get deployment \
        -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=$component" \
        -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true

    if [ -z "$deploy_name" ]; then
        warn "No deployment found for component $component (may not be deployed)"
        return 0
    fi

    kubectl rollout status "deployment/$deploy_name" -n "$NAMESPACE" --timeout=300s || {
        error "Rollout failed for $component ($deploy_name)"
        return 1
    }
    ok "Deployment $deploy_name is ready"
}

wait_for_component "backend" || exit "$EXIT_KUBE"
wait_for_component "frontend" || exit "$EXIT_KUBE"

# ---------------------------------------------------------------------------
# Step 8: Health check
# ---------------------------------------------------------------------------
info "Running health check..."
"$CLI" health-check -r "$RELEASE" -n "$NAMESPACE" --timeout 120 || {
    error "Health check failed"
    exit "$EXIT_HEALTH"
}
ok "Health check passed"

# ---------------------------------------------------------------------------
# Step 9: Output summary for GitHub Actions
# ---------------------------------------------------------------------------
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    info "Writing outputs for GitHub Actions..."

    echo "namespace=$NAMESPACE" >> "$GITHUB_OUTPUT"
    echo "release=$RELEASE" >> "$GITHUB_OUTPUT"

    # Resolve service names via label selectors
    FRONTEND_SVC=$(kubectl get svc -n "$NAMESPACE" \
        -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=frontend" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || FRONTEND_SVC=""

    BACKEND_SVC=$(kubectl get svc -n "$NAMESPACE" \
        -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=backend" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || BACKEND_SVC=""

    if [ -n "$FRONTEND_SVC" ]; then
        echo "frontend_portfwd=kubectl port-forward svc/$FRONTEND_SVC 8080:80 -n $NAMESPACE" >> "$GITHUB_OUTPUT"
    fi

    if [ -n "$BACKEND_SVC" ]; then
        echo "backend_portfwd=kubectl port-forward svc/$BACKEND_SVC 8000:8000 -n $NAMESPACE" >> "$GITHUB_OUTPUT"
    fi

    echo "retrieval_cmd=kubectl get secret biznez-eval-admin-creds -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d" >> "$GITHUB_OUTPUT"
fi

ok "Biznez runtime deployed successfully to namespace $NAMESPACE"
exit "$EXIT_OK"
