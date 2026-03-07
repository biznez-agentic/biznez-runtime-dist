#!/usr/bin/env bash
# =============================================================================
# provision.sh -- Deploy Biznez runtime to a GKE eval environment
# =============================================================================
# Orchestrates: namespace creation, secret generation, Helm install, health check,
# ingress setup, admin bootstrap, workspace creation, and runtime registration.
# Called by the provision-eval.yml workflow after Terraform creates the cluster.
#
# Usage:
#   ./provision.sh --namespace biznez --release biznez \
#     --values-file ./infra/values/eval-gke.yaml \
#     --chart-dir ./helm/biznez-runtime \
#     --ar-url <ar-url> --images-lock ./helm/biznez-runtime/images.lock \
#     [--ingress-ip <ip>] [--cluster-endpoint <endpoint>] [--project-id <id>]
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
readonly EXIT_BOOTSTRAP=7

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
PF_PID=""
# shellcheck disable=SC2329
_provision_cleanup() {
    [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null || true
    rm -f /tmp/biznez-runtime-kubeconfig.yaml /tmp/register-resp.json
}

_CLEANUP_FILES=""
# shellcheck disable=SC2329
_cleanup() {
    if [ -n "$_CLEANUP_FILES" ]; then
        # shellcheck disable=SC2086
        rm -f $_CLEANUP_FILES
    fi
}
trap '_provision_cleanup; _cleanup' EXIT

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
NAMESPACE="biznez"
RELEASE="biznez"
VALUES_FILE=""
CHART_DIR=""
AR_URL=""
IMAGES_LOCK=""
INGRESS_IP=""
CLUSTER_ENDPOINT=""
PROJECT_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)         NAMESPACE="$2"; shift 2 ;;
        --release)           RELEASE="$2"; shift 2 ;;
        --values-file)       VALUES_FILE="$2"; shift 2 ;;
        --chart-dir)         CHART_DIR="$2"; shift 2 ;;
        --ar-url)            AR_URL="$2"; shift 2 ;;
        --images-lock)       IMAGES_LOCK="$2"; shift 2 ;;
        --ingress-ip)        INGRESS_IP="$2"; shift 2 ;;
        --cluster-endpoint)  CLUSTER_ENDPOINT="$2"; shift 2 ;;
        --project-id)        PROJECT_ID="$2"; shift 2 ;;  # reserved for future use
        *)                   error "Unknown argument: $1"; exit "$EXIT_PREREQ" ;;
    esac
done

# Validate required args
for var_name in VALUES_FILE CHART_DIR AR_URL IMAGES_LOCK; do
    if [ -z "${!var_name}" ]; then
        error "Missing required argument: --$(echo "$var_name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
        exit "$EXIT_PREREQ"
    fi
done

# cluster-endpoint is REQUIRED when ingress-ip is provided
if [ -n "${INGRESS_IP:-}" ] && [ -z "${CLUSTER_ENDPOINT:-}" ]; then
    error "Missing required argument: --cluster-endpoint (required when --ingress-ip is set)"
    exit "$EXIT_PREREQ"
fi

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
# Extract postgres password from the K8s secret for Helm (it needs it to build DATABASE_URL)
PG_PASS=$(kubectl get secret "${RELEASE}-postgres-secrets" -n "$NAMESPACE" \
    -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d) || true
if [ -z "$PG_PASS" ]; then
    error "Could not read POSTGRES_PASSWORD from ${RELEASE}-postgres-secrets"
    exit "$EXIT_SECRET"
fi
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
# Step 5.5: Install nginx-ingress (conditional on --ingress-ip)
# ---------------------------------------------------------------------------
INGRESS_HOST=""
if [ -n "${INGRESS_IP:-}" ]; then
    info "Installing nginx-ingress controller..."
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update ingress-nginx
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx --create-namespace \
        --set controller.replicaCount=1 \
        --set controller.service.loadBalancerIP="$INGRESS_IP" \
        --set controller.service.externalTrafficPolicy=Local \
        --set controller.resources.requests.cpu=100m \
        --set controller.resources.requests.memory=128Mi \
        --set controller.admissionWebhooks.patch.resources.requests.cpu=50m \
        --set controller.admissionWebhooks.patch.resources.requests.memory=64Mi \
        --wait --timeout 300s

    # Deterministic wait: poll until LB IP is actually assigned and routing
    info "Waiting for LoadBalancer IP assignment..."
    for i in $(seq 1 60); do
        LB_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) || true
        if [ "$LB_IP" = "$INGRESS_IP" ]; then
            ok "LoadBalancer IP $INGRESS_IP is active"
            break
        fi
        if [ "$i" -eq 60 ]; then
            error "LoadBalancer IP not assigned after 120s (current: ${LB_IP:-none})"
            exit "$EXIT_KUBE"
        fi
        sleep 2
    done

    INGRESS_HOST="${INGRESS_IP}.nip.io"
fi

# ---------------------------------------------------------------------------
# Step 6: Helm install
# ---------------------------------------------------------------------------
info "Installing Biznez runtime via Helm..."

HELM_ARGS=(
    --set global.imageRegistry="$AR_URL"
    --set backend.image.repository=platform-api
    --set backend.image.tag="$BACKEND_TAG"
    --set backend.existingSecret="${RELEASE}-backend-secrets"
    --set frontend.image.repository=web-app
    --set frontend.image.tag="$FRONTEND_TAG"
    --set postgres.image.repository=postgres
    --set postgres.image.tag="$POSTGRES_TAG"
    --set postgres.existingSecret="${RELEASE}-postgres-secrets"
    --set postgres.secrets.password="$PG_PASS"
    --set gateway.image.repository=agentgateway
    --set gateway.image.tag="$GATEWAY_TAG"
)

if [ -n "${INGRESS_HOST:-}" ]; then
    HELM_ARGS+=(
        --set frontend.config.apiUrl="http://${INGRESS_HOST}"
        --set ingress.enabled=true
        --set ingress.className=nginx
        --set ingress.applyNginxStreamingAnnotations=true
        --set 'ingress.hosts[0].host='"$INGRESS_HOST"
        --set 'ingress.hosts[0].paths[0].path=/api'
        --set 'ingress.hosts[0].paths[0].service=backend'
        --set 'ingress.hosts[0].paths[0].port=8000'
        --set 'ingress.hosts[0].paths[1].path=/'
        --set 'ingress.hosts[0].paths[1].service=frontend'
        --set 'ingress.hosts[0].paths[1].port=80'
    )
fi

helm upgrade --install "$RELEASE" "$CHART_DIR" \
    -f "$VALUES_FILE" "${HELM_ARGS[@]}" \
    -n "$NAMESPACE" --wait --timeout 600s || {
    error "Helm install failed — collecting diagnostics..."
    echo "--- Pod status ---"
    kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || true
    echo "--- Backend pod describe ---"
    BACKEND_POD=$(kubectl get pod -n "$NAMESPACE" \
        -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=backend" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
    if [ -n "${BACKEND_POD:-}" ]; then
        kubectl describe pod "$BACKEND_POD" -n "$NAMESPACE" 2>/dev/null | tail -40 || true
        echo "--- run-migrations logs ---"
        kubectl logs "$BACKEND_POD" -c run-migrations -n "$NAMESPACE" --tail=200 2>/dev/null || true
        echo "--- wait-for-db logs ---"
        kubectl logs "$BACKEND_POD" -c wait-for-db -n "$NAMESPACE" --tail=200 2>/dev/null || true
        echo "--- backend logs ---"
        kubectl logs "$BACKEND_POD" -n "$NAMESPACE" --tail=200 2>/dev/null || true
    fi
    exit "$EXIT_KUBE"
}
unset PG_PASS
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

    kubectl rollout status "deployment/$deploy_name" -n "$NAMESPACE" --timeout=600s || {
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
"$CLI" -r "$RELEASE" -n "$NAMESPACE" health-check --timeout 120 || {
    error "Health check failed"
    exit "$EXIT_HEALTH"
}
ok "Health check passed"

# ---------------------------------------------------------------------------
# Step 9: Seed eval data
# ---------------------------------------------------------------------------
SEED_SCRIPT="${SCRIPT_DIR}/seed-eval-data.sh"
if [ -x "$SEED_SCRIPT" ]; then
    info "Seeding eval data..."
    bash "$SEED_SCRIPT" --namespace "$NAMESPACE" --release "$RELEASE" || {
        error "Seed data script failed"
        exit "$EXIT_BOOTSTRAP"
    }
fi

# ---------------------------------------------------------------------------
# Step 10: Create K8s ServiceAccount + custom ClusterRole
# ---------------------------------------------------------------------------
if [ -n "${CLUSTER_ENDPOINT:-}" ]; then
    info "Creating runtime deployer service account and RBAC..."
    kubectl apply -n "$NAMESPACE" -f - <<RBAC_EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: biznez-runtime-deployer
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: biznez-runtime-deployer
rules:
  - apiGroups: [""]
    resources: [namespaces]
    verbs: [create, get, list]
  - apiGroups: ["apps"]
    resources: [deployments]
    verbs: [create, get, update, patch, delete, list, watch]
  - apiGroups: [""]
    resources: [services]
    verbs: [create, get, update, patch, delete, list]
  - apiGroups: [""]
    resources: [secrets]
    verbs: [create, get, delete, list]
  - apiGroups: [""]
    resources: [configmaps]
    verbs: [create, get, update, patch, delete, list]
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list, watch, delete]
  - apiGroups: [""]
    resources: [pods/log]
    verbs: [get]
  - apiGroups: ["networking.k8s.io"]
    resources: [ingresses]
    verbs: [create, get, update, patch, delete, list]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: biznez-runtime-deployer
subjects:
  - kind: ServiceAccount
    name: biznez-runtime-deployer
    namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: biznez-runtime-deployer
  apiGroup: rbac.authorization.k8s.io
RBAC_EOF

    # Generate token via TokenRequest API (deterministic, no polling)
    # Suppress xtrace for entire block: token generation + kubeconfig write
    _xtrace_was_on=false; case "$-" in *x*) _xtrace_was_on=true; set +x ;; esac
    SA_TOKEN=$(kubectl create token biznez-runtime-deployer \
        -n "$NAMESPACE" --duration=720h 2>/dev/null) || true

    if [ -z "$SA_TOKEN" ]; then
        if $_xtrace_was_on; then set -x; fi
        warn "Failed to generate SA token via TokenRequest API"
    else
        # Build kubeconfig — portable base64 (macOS base64 has no -w flag)
        CA_DATA=$(kubectl get cm kube-root-ca.crt -n "$NAMESPACE" \
            -o jsonpath='{.data.ca\.crt}' | python3 -c "import sys,base64; print(base64.b64encode(sys.stdin.buffer.read()).decode())")

        cat > /tmp/biznez-runtime-kubeconfig.yaml <<KUBECONFIG_EOF
apiVersion: v1
kind: Config
clusters:
  - cluster:
      certificate-authority-data: ${CA_DATA}
      server: ${CLUSTER_ENDPOINT}
    name: eval-cluster
contexts:
  - context:
      cluster: eval-cluster
      user: biznez-runtime-deployer
    name: eval
current-context: eval
users:
  - name: biznez-runtime-deployer
    user:
      token: ${SA_TOKEN}
KUBECONFIG_EOF
        chmod 600 /tmp/biznez-runtime-kubeconfig.yaml
        if $_xtrace_was_on; then set -x; fi
        ok "Runtime deployer RBAC and kubeconfig ready"
    fi
    unset SA_TOKEN  # clear from env immediately
fi

# ---------------------------------------------------------------------------
# Step 11: Port-forward backend (temporary, for API bootstrap)
# ---------------------------------------------------------------------------
info "Starting temporary port-forward to backend..."
BACKEND_SVC=$(kubectl get svc -n "$NAMESPACE" \
    -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=backend" \
    -o jsonpath='{.items[0].metadata.name}') || true

if [ -n "$BACKEND_SVC" ]; then
    # Verify backend endpoints exist before port-forwarding
    for i in $(seq 1 10); do
        EP_COUNT=$(kubectl get endpoints "$BACKEND_SVC" -n "$NAMESPACE" \
            -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' ') || EP_COUNT=0
        [ "$EP_COUNT" -gt 0 ] && break
        if [ "$i" -eq 10 ]; then
            warn "Backend endpoints not ready after 20s — port-forward may fail"
        fi
        sleep 2
    done

    kubectl port-forward "svc/$BACKEND_SVC" 18000:8000 -n "$NAMESPACE" &
    PF_PID=$!

    API_URL="http://localhost:18000"
    for i in $(seq 1 15); do
        if curl -sf "$API_URL/api/v1/health" >/dev/null 2>&1; then
            ok "Port-forward ready"
            break
        fi
        if [ "$i" -eq 15 ]; then
            warn "Port-forward health check failed after 30s"
            if [ -n "${INGRESS_HOST:-}" ]; then
                API_URL="http://${INGRESS_HOST}"
                info "Falling back to ingress URL: $API_URL"
                # Verify fallback URL is reachable before proceeding
                for j in $(seq 1 10); do
                    if curl -sf "$API_URL/api/v1/health" >/dev/null 2>&1; then
                        ok "Ingress fallback health check passed"
                        break
                    fi
                    if [ "$j" -eq 10 ]; then
                        warn "Ingress fallback also unreachable — bootstrap steps may be skipped"
                        API_URL=""
                    fi
                    sleep 2
                done
            else
                API_URL=""
            fi
            break
        fi
        sleep 2
    done
else
    warn "Could not find backend service"
    if [ -n "${INGRESS_HOST:-}" ]; then
        API_URL="http://${INGRESS_HOST}"
    else
        API_URL=""
    fi
fi

# ---------------------------------------------------------------------------
# Step 12: Register admin user + promote (idempotent)
# ---------------------------------------------------------------------------
ACCESS_TOKEN=""
if [ -n "${API_URL:-}" ]; then
    info "Registering admin user..."
    ADMIN_PASS=$(kubectl get secret biznez-eval-admin-creds -n "$NAMESPACE" \
        -o jsonpath='{.data.password}' | base64 -d)

    # Try registration; 400 = already exists (idempotent)
    # Pass password via stdin to avoid exposure in /proc/PID/cmdline
    _xtrace_was_on=false; case "$-" in *x*) _xtrace_was_on=true; set +x ;; esac
    REGISTER_BODY=$(echo "$ADMIN_PASS" | python3 -c "
import json, sys
pw = sys.stdin.read().rstrip('\n')
print(json.dumps({'username':'admin','email':'admin@eval.biznez.io','password':pw,'full_name':'Eval Admin'}))
")
    REGISTER_HTTP=$(curl -s --max-time 30 -o /tmp/register-resp.json -w '%{http_code}' \
        -X POST "$API_URL/api/v1/auth/register" \
        -H "Content-Type: application/json" \
        -d "$REGISTER_BODY")
    unset REGISTER_BODY
    if $_xtrace_was_on; then set -x; fi

    if [ "$REGISTER_HTTP" = "201" ]; then
        ACCESS_TOKEN=$(python3 -c "import json; print(json.load(open('/tmp/register-resp.json'))['access_token'])" 2>/dev/null) || true
        ok "Admin user registered"
    elif [ "$REGISTER_HTTP" = "400" ]; then
        info "Admin user already exists, logging in..."
        _xtrace_was_on=false; case "$-" in *x*) _xtrace_was_on=true; set +x ;; esac
        LOGIN_BODY=$(echo "$ADMIN_PASS" | python3 -c "
import json, sys
pw = sys.stdin.read().rstrip('\n')
print(json.dumps({'username':'admin','password':pw}))
")
        LOGIN_RESP=$(curl -sf --max-time 30 -X POST "$API_URL/api/v1/auth/login" \
            -H "Content-Type: application/json" \
            -d "$LOGIN_BODY" 2>/dev/null) || true
        unset LOGIN_BODY
        if $_xtrace_was_on; then set -x; fi
        if [ -n "$LOGIN_RESP" ]; then
            ACCESS_TOKEN=$(echo "$LOGIN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true
            ok "Logged in as existing admin"
        fi
    else
        error "Admin registration returned HTTP $REGISTER_HTTP"
        cat /tmp/register-resp.json 2>/dev/null || true
        rm -f /tmp/register-resp.json
        unset ADMIN_PASS
        exit "$EXIT_BOOTSTRAP"
    fi
    rm -f /tmp/register-resp.json
    unset ADMIN_PASS

    # Promote to admin via SQL (idempotent, targets both identifiers)
    PG_POD=$(kubectl get pod -n "$NAMESPACE" \
        -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=postgres" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
    if [ -n "$PG_POD" ]; then
        kubectl exec "$PG_POD" -n "$NAMESPACE" -- psql -U biznez -d biznez_platform -c \
            "UPDATE users SET is_admin = true WHERE username = 'admin' OR email = 'admin@eval.biznez.io';" 2>&1 || true
        # Confirm promotion
        ADMIN_CHECK=$(kubectl exec "$PG_POD" -n "$NAMESPACE" -- psql -U biznez -d biznez_platform -tAc \
            "SELECT is_admin FROM users WHERE username = 'admin';" 2>/dev/null) || true
        if [ "$ADMIN_CHECK" = "t" ]; then
            ok "Admin user confirmed: is_admin=true"
        else
            warn "Admin promotion could not be confirmed (is_admin=$ADMIN_CHECK)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Step 13: Create default workspace
# ---------------------------------------------------------------------------
if [ -z "${ACCESS_TOKEN:-}" ]; then
    error "No access token — cannot create workspace (admin registration failed?)"
    exit "$EXIT_BOOTSTRAP"
fi

info "Creating default workspace..."
ME_RESP=$(curl -sf --max-time 30 "$API_URL/api/v1/auth/me" \
    -H "Authorization: Bearer $ACCESS_TOKEN") || true
if [ -z "$ME_RESP" ]; then
    error "Failed to fetch /auth/me — cannot determine organization ID"
    exit "$EXIT_BOOTSTRAP"
fi

ORG_ID=$(echo "$ME_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('organization',{}).get('id','') or d.get('organization_id',''))
" 2>/dev/null) || true
if [ -z "$ORG_ID" ]; then
    error "Could not determine organization ID from /auth/me response"
    exit "$EXIT_BOOTSTRAP"
fi

WS_BODY=$(python3 -c "
import json, sys
print(json.dumps({
    'name': 'Default Workspace',
    'slug': 'default',
    'description': 'Pre-configured eval workspace',
    'organization_id': sys.argv[1],
    'max_agents': 100,
    'max_concurrent_executions': 10,
    'max_storage_mb': 5120,
    'is_public': False
}))
" "$ORG_ID")
WS_HTTP=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' \
    -X POST "$API_URL/api/v1/workspaces" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$WS_BODY")
unset WS_BODY
if [ "$WS_HTTP" = "201" ] || [ "$WS_HTTP" = "200" ]; then
    ok "Default workspace created"
elif [ "$WS_HTTP" = "409" ] || [ "$WS_HTTP" = "400" ]; then
    info "Default workspace already exists"
else
    error "Workspace creation returned HTTP $WS_HTTP"
    exit "$EXIT_BOOTSTRAP"
fi

# ---------------------------------------------------------------------------
# Step 14: Register GKE runtime (idempotent)
# ---------------------------------------------------------------------------
if [ -f /tmp/biznez-runtime-kubeconfig.yaml ] && [ -n "${ACCESS_TOKEN:-}" ]; then
    info "Registering GKE cluster as runtime..."

    # Check if runtime already exists (match by name AND endpoint)
    # Pass CLUSTER_ENDPOINT via sys.argv to avoid shell interpolation in Python
    EXISTING_RT=$(curl -sf --max-time 30 "$API_URL/api/v1/runtimes" \
        -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null | \
        python3 -c "
import sys, json
target_endpoint = sys.argv[1]
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get('items', data.get('runtimes', []))
for rt in items:
    if rt.get('name') == 'GKE Eval Cluster' and rt.get('endpoint') == target_endpoint:
        print(rt['id'])
        break
" "$CLUSTER_ENDPOINT" 2>/dev/null) || true

    if [ -n "$EXISTING_RT" ]; then
        ok "GKE runtime already registered (id=$EXISTING_RT)"
    else
        # Get workspace ID
        WS_ID=$(curl -sf --max-time 30 "$API_URL/api/v1/workspaces" \
            -H "Authorization: Bearer $ACCESS_TOKEN" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get('items', data.get('workspaces', []))
print(items[0]['id'] if items else '')
" 2>/dev/null) || true

        if [ -n "$WS_ID" ]; then
            # Build JSON body via Python to avoid kubeconfig exposure in /proc/PID/cmdline
            _xtrace_was_on=false; case "$-" in *x*) _xtrace_was_on=true; set +x ;; esac
            RT_BODY=$(python3 -c "
import json, sys, base64
kb64 = base64.b64encode(open('/tmp/biznez-runtime-kubeconfig.yaml','rb').read()).decode()
print(json.dumps({
    'name': 'GKE Eval Cluster',
    'type': 'kubernetes',
    'endpoint': sys.argv[1],
    'credentials': {'kubeconfig_content': kb64},
    'workspace_id': sys.argv[2],
    'environment': 'development'
}))
" "$CLUSTER_ENDPOINT" "$WS_ID")
            RT_HTTP=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' \
                -X POST "$API_URL/api/v1/runtimes" \
                -H "Authorization: Bearer $ACCESS_TOKEN" \
                -H "Content-Type: application/json" \
                -d "$RT_BODY")
            unset RT_BODY
            if $_xtrace_was_on; then set -x; fi

            if [ "$RT_HTTP" = "201" ] || [ "$RT_HTTP" = "200" ]; then
                ok "GKE runtime registered"
            elif [ "$RT_HTTP" = "409" ] || [ "$RT_HTTP" = "400" ]; then
                info "Runtime may already exist (HTTP $RT_HTTP)"
            else
                error "Runtime registration returned HTTP $RT_HTTP"
                exit "$EXIT_BOOTSTRAP"
            fi
        fi
    fi
fi

# Cleanup sensitive temp files, tokens, and port-forward
rm -f /tmp/biznez-runtime-kubeconfig.yaml
unset ACCESS_TOKEN
kill "$PF_PID" 2>/dev/null || true; PF_PID=""

# ---------------------------------------------------------------------------
# Step 15: Verify ingress (dual check: frontend + backend routing)
# ---------------------------------------------------------------------------
if [ -n "${INGRESS_HOST:-}" ]; then
    info "Verifying ingress serves traffic..."

    # Check 1: Frontend (/) — accept 200 or 304 (cached)
    FE_OK=false
    for i in $(seq 1 15); do
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://${INGRESS_HOST}/" 2>/dev/null) || true
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "304" ]; then
            FE_OK=true
            break
        fi
        sleep 2
    done

    # Check 2: Backend routing (/api/v1/health)
    BE_OK=false
    for i in $(seq 1 10); do
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://${INGRESS_HOST}/api/v1/health" 2>/dev/null) || true
        if [ "$HTTP_CODE" = "200" ]; then
            BE_OK=true
            break
        fi
        sleep 2
    done

    if $FE_OK && $BE_OK; then
        INGRESS_VERIFIED=true
        ok "Ingress verified: frontend (/) and backend (/api/v1/health) both return 200"
    else
        INGRESS_VERIFIED=false
        warn "Ingress partial: frontend=$FE_OK backend=$BE_OK — app_url will not be emitted"
    fi
fi

# ---------------------------------------------------------------------------
# Step 16: Output summary for GitHub Actions
# ---------------------------------------------------------------------------
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    info "Writing outputs for GitHub Actions..."

    echo "namespace=$NAMESPACE" >> "$GITHUB_OUTPUT"
    echo "release=$RELEASE" >> "$GITHUB_OUTPUT"

    if [ -n "${INGRESS_HOST:-}" ] && [ "${INGRESS_VERIFIED:-false}" = "true" ]; then
        echo "app_url=http://${INGRESS_HOST}" >> "$GITHUB_OUTPUT"
    fi
    echo "admin_username=admin" >> "$GITHUB_OUTPUT"
    # Password NOT echoed — summary shows kubectl retrieval command

    # Resolve service names via label selectors (for fallback port-forward instructions)
    FRONTEND_SVC=$(kubectl get svc -n "$NAMESPACE" \
        -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=frontend" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || FRONTEND_SVC=""

    BACKEND_SVC_OUT=$(kubectl get svc -n "$NAMESPACE" \
        -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=backend" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || BACKEND_SVC_OUT=""

    if [ -n "$FRONTEND_SVC" ]; then
        echo "frontend_portfwd=kubectl port-forward svc/$FRONTEND_SVC 8080:80 -n $NAMESPACE" >> "$GITHUB_OUTPUT"
    fi

    if [ -n "$BACKEND_SVC_OUT" ]; then
        echo "backend_portfwd=kubectl port-forward svc/$BACKEND_SVC_OUT 8000:8000 -n $NAMESPACE" >> "$GITHUB_OUTPUT"
    fi

    echo "retrieval_cmd=kubectl get secret biznez-eval-admin-creds -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d" >> "$GITHUB_OUTPUT"
fi

ok "Biznez runtime deployed successfully to namespace $NAMESPACE"
exit "$EXIT_OK"
