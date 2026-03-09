# Phase 10.4: Zero-Touch Eval Provisioning

## Context

After deploying eval environment `manimaun15-puch`, we had to manually:
1. Seed plans + connector definitions (now automated via `seed-eval-data.sh` in PR #34)
2. Register an admin user via curl
3. Promote user to `is_admin=true` via direct SQL (no admin promotion API exists)
4. Create a GCP service account key for runtime registration
5. Apply K8s RBAC for the SA
6. Register GKE as a runtime via the UI
7. Port-forward frontend and backend services manually

A customer evaluating the platform should not need to do any of this.

## Goal

After `provision-eval.yml` completes, the customer gets:
- A public URL (`http://<static-ip>.nip.io`) — no port-forwarding
- A working admin account (password retrievable via kubectl)
- A default workspace already created
- GKE already registered as a runtime
- All seed data present (plans, connectors)

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **No GCP SA key** — K8s ServiceAccount + TokenRequest API | No long-lived JSON keys. `kubectl create token --duration=48h` is deterministic (no polling for secret population). Consistent with WIF direction |
| **Custom ClusterRole** | Matches `gke.py` REQUIRED_PERMISSIONS exactly + `patch` verb for safety. Code uses `replace_namespaced_*` (= `update` verb), no `pods/exec`, no `replicasets`, no `events` needed |
| **Single Helm install** | nginx-ingress first, then one `helm upgrade --install` with all args including ingress. No double upgrade |
| **`--cluster-endpoint` mandatory when `--ingress-ip` provided** | Prevents registering wrong endpoint from stale kubectl context |
| **Dual ingress verification** | Curl both `/` (frontend) and `/api/v1/health` (backend routing) |
| **Trap-based cleanup** | Port-forward PID and temp files cleaned on all exit paths |
| **Runtime registration idempotency** | Check existing by name+endpoint; handle 409/400 as "already exists" |
| **Portable base64** | Use `python3 -c "import sys,base64;..."` instead of `base64 \| tr -d '\n'` (macOS vs Linux differences) |
| **Xtrace save/restore** | `case "$-" in *x*) ...` + `if $_xtrace_was_on; then set -x; fi` — safe conditional restore |
| **Token duration 48h** | Within GKE token TTL caps; eval workflow is rerunnable so short-lived is fine |
| **nginx-ingress replicaCount=1** | Deterministic for eval, cheaper, avoids Autopilot scheduling two pods |
| **Bearer token auth** | Platform uses JWT (not cookies), HTTP on nip.io works fine |
| **Admin SQL promotion** | No API exists. Idempotent UPDATE + SELECT confirmation |
| **GKE Autopilot resource requests** | Set explicit CPU/memory for nginx-ingress to avoid Autopilot scheduling surprises |

## Architecture

```
Customer browser → http://<static-ip>.nip.io
    ↓
GCP Network LB (auto-created by nginx-ingress Service type=LoadBalancer)
    ↓ static IP pinned via google_compute_address
nginx-ingress controller pod (with resource requests for Autopilot)
    ├─ /api/*  → backend ClusterIP:8000
    └─ /*      → frontend ClusterIP:80

Runtime deploys agents via K8s ServiceAccount (biznez-runtime-deployer)
    → kubeconfig with TokenRequest API token (not legacy secret)
    → Custom ClusterRole with exact permissions:
      namespaces (create/get/list)
      deployments (create/get/update/patch/delete/list/watch)
      services (create/get/update/patch/delete/list)
      secrets (create/get/update/patch/delete/list)
      configmaps (create/get/update/patch/delete/list)
      pods (get/list/watch/delete)
      pods/log (get)
      ingresses (create/get/update/patch/delete/list)
```

## Changes (4 Layers)

---

### Layer 1: Terraform — Static IP Only

**No IAM changes. No GCP SA key.**

#### `infra/terraform/modules/networking/main.tf` (modify)

```hcl
resource "google_compute_address" "ingress_ip" {
  name         = "${local.name_prefix}-ingress-ip"
  project      = var.project_id
  region       = var.region
  address_type = "EXTERNAL"
  description  = "Static IP for eval ingress (${var.env_id})"
}
```

#### `infra/terraform/modules/networking/outputs.tf` (modify)

```hcl
output "ingress_ip" {
  description = "Static external IP for ingress load balancer"
  value       = google_compute_address.ingress_ip.address
}
```

#### `infra/terraform/environments/eval/outputs.tf` (modify)

```hcl
output "ingress_ip" {
  description = "Static IP for eval ingress"
  value       = module.networking.ingress_ip
}
```

---

### Layer 2: provision.sh — Ingress + Admin + Workspace + Runtime

**File: `infra/scripts/provision.sh`**

#### New arguments

```
--ingress-ip <ip>              # Static IP from Terraform (enables ingress flow)
--cluster-endpoint <endpoint>  # GKE API server URL (REQUIRED when --ingress-ip is set)
--project-id <id>              # GCP project ID
```

All new args optional for backward compatibility, **except** `--cluster-endpoint` is required when `--ingress-ip` is provided (prevents registering wrong cluster endpoint from stale kubectl context).

#### Argument validation

```bash
if [ -n "${INGRESS_IP:-}" ] && [ -z "${CLUSTER_ENDPOINT:-}" ]; then
    error "Missing required argument: --cluster-endpoint (required when --ingress-ip is set)"
    exit "$EXIT_PREREQ"
fi
```

#### Cleanup trap

```bash
_provision_cleanup() {
    [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null || true
    rm -f /tmp/biznez-runtime-kubeconfig.yaml /tmp/register-resp.json
}
trap '_provision_cleanup; _cleanup' EXIT
```

#### Step 5.5: Install nginx-ingress (before Helm install, conditional)

```bash
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

    # Deterministic wait: poll until LB IP is actually assigned
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
```

Resource requests are set explicitly for GKE Autopilot compatibility (avoids defaulting surprises and slow scheduling).

#### Step 6: Single Helm install with conditional ingress

Build `HELM_ARGS` array with all existing args, then conditionally append ingress args:

```bash
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
    -n "$NAMESPACE" --wait --timeout 600s
```

#### Steps 7-9: Existing (rollout wait, health check, seed data)

#### Step 10: K8s ServiceAccount + custom ClusterRole + TokenRequest API token

```bash
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
    verbs: [create, get, update, patch, delete, list]
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

# TokenRequest API (deterministic, no polling, no legacy secret)
_xtrace_was_on=false; case "$-" in *x*) _xtrace_was_on=true; set +x ;; esac
SA_TOKEN=$(kubectl create token biznez-runtime-deployer \
    -n "$NAMESPACE" --duration=48h 2>/dev/null) || true
if $_xtrace_was_on; then set -x; fi

if [ -z "$SA_TOKEN" ]; then
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
    ok "Runtime deployer RBAC and kubeconfig ready"
fi
unset SA_TOKEN  # clear from env
```

#### Step 11: Port-forward backend (temporary, for API bootstrap)

```bash
info "Starting temporary port-forward to backend..."
BACKEND_SVC=$(kubectl get svc -n "$NAMESPACE" \
    -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=backend" \
    -o jsonpath='{.items[0].metadata.name}')

# Verify endpoints exist before port-forwarding
for i in $(seq 1 10); do
    EP_COUNT=$(kubectl get endpoints "$BACKEND_SVC" -n "$NAMESPACE" \
        -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' ') || EP_COUNT=0
    [ "$EP_COUNT" -gt 0 ] && break
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
        fi
    fi
    sleep 2
done
```

#### Step 12: Register admin user + promote (idempotent)

```bash
info "Registering admin user..."
ADMIN_PASS=$(kubectl get secret biznez-eval-admin-creds -n "$NAMESPACE" \
    -o jsonpath='{.data.password}' | base64 -d)

_xtrace_was_on=false; case "$-" in *x*) _xtrace_was_on=true; set +x ;; esac
REGISTER_HTTP=$(curl -s -o /tmp/register-resp.json -w '%{http_code}' \
    -X POST "$API_URL/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"email\":\"admin@eval.biznez.local\",\"password\":\"$ADMIN_PASS\",\"full_name\":\"Eval Admin\"}")
if $_xtrace_was_on; then set -x; fi

ACCESS_TOKEN=""
if [ "$REGISTER_HTTP" = "201" ]; then
    ACCESS_TOKEN=$(python3 -c "import json; print(json.load(open('/tmp/register-resp.json'))['access_token'])" 2>/dev/null) || true
    ok "Admin user registered"
elif [ "$REGISTER_HTTP" = "400" ]; then
    info "Admin user already exists, logging in..."
    _xtrace_was_on=false; case "$-" in *x*) _xtrace_was_on=true; set +x ;; esac
    LOGIN_RESP=$(curl -sf -X POST "$API_URL/api/v1/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}" 2>/dev/null) || true
    if $_xtrace_was_on; then set -x; fi
    if [ -n "$LOGIN_RESP" ]; then
        ACCESS_TOKEN=$(echo "$LOGIN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true
        ok "Logged in as existing admin"
    fi
else
    warn "Admin registration returned HTTP $REGISTER_HTTP"
fi
rm -f /tmp/register-resp.json

# Promote to admin via SQL (idempotent, targets both identifiers)
PG_POD=$(kubectl get pod -n "$NAMESPACE" \
    -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=postgres" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
if [ -n "$PG_POD" ]; then
    kubectl exec "$PG_POD" -n "$NAMESPACE" -- psql -U biznez -d biznez_platform -c \
        "UPDATE users SET is_admin = true WHERE username = 'admin' OR email = 'admin@eval.biznez.local';" 2>&1 || true
    # Confirm promotion
    ADMIN_CHECK=$(kubectl exec "$PG_POD" -n "$NAMESPACE" -- psql -U biznez -d biznez_platform -tAc \
        "SELECT is_admin FROM users WHERE username = 'admin';" 2>/dev/null) || true
    if [ "$ADMIN_CHECK" = "t" ]; then
        ok "Admin user confirmed: is_admin=true"
    else
        warn "Admin promotion could not be confirmed (is_admin=$ADMIN_CHECK)"
    fi
fi
```

#### Step 13: Create default workspace (idempotent)

```bash
if [ -n "${ACCESS_TOKEN:-}" ]; then
    info "Creating default workspace..."
    ME_RESP=$(curl -sf "$API_URL/api/v1/auth/me" \
        -H "Authorization: Bearer $ACCESS_TOKEN") || true
    if [ -n "$ME_RESP" ]; then
        ORG_ID=$(echo "$ME_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('organization',{}).get('id','') or d.get('organization_id',''))
" 2>/dev/null) || true
        if [ -n "$ORG_ID" ]; then
            WS_HTTP=$(curl -s -o /dev/null -w '%{http_code}' \
                -X POST "$API_URL/api/v1/workspaces" \
                -H "Authorization: Bearer $ACCESS_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"name\":\"Default Workspace\",\"slug\":\"default\",\"description\":\"Pre-configured eval workspace\",\"organization_id\":\"$ORG_ID\",\"max_agents\":100,\"max_concurrent_executions\":10,\"max_storage_mb\":5120,\"is_public\":false}")
            if [ "$WS_HTTP" = "201" ] || [ "$WS_HTTP" = "200" ]; then
                ok "Default workspace created"
            elif [ "$WS_HTTP" = "409" ] || [ "$WS_HTTP" = "400" ]; then
                info "Default workspace already exists"
            else
                warn "Workspace creation returned HTTP $WS_HTTP"
            fi
        fi
    fi
fi
```

#### Step 14: Register GKE runtime (idempotent — check existing first)

```bash
if [ -f /tmp/biznez-runtime-kubeconfig.yaml ] && [ -n "${ACCESS_TOKEN:-}" ]; then
    info "Registering GKE cluster as runtime..."

    # Check if runtime already exists (match by name AND endpoint)
    EXISTING_RT=$(curl -sf "$API_URL/api/v1/runtimes" \
        -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get('items', data.get('runtimes', []))
for rt in items:
    if rt.get('name') == 'GKE Eval Cluster' and rt.get('endpoint') == '${CLUSTER_ENDPOINT}':
        print(rt['id'])
        break
" 2>/dev/null) || true

    if [ -n "$EXISTING_RT" ]; then
        ok "GKE runtime already registered (id=$EXISTING_RT)"
    else
        WS_ID=$(curl -sf "$API_URL/api/v1/workspaces" \
            -H "Authorization: Bearer $ACCESS_TOKEN" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get('items', data.get('workspaces', []))
print(items[0]['id'] if items else '')
" 2>/dev/null) || true

        if [ -n "$WS_ID" ]; then
            _xtrace_was_on=false; case "$-" in *x*) _xtrace_was_on=true; set +x ;; esac
            KUBECONFIG_B64=$(python3 -c "import sys,base64; print(base64.b64encode(open('/tmp/biznez-runtime-kubeconfig.yaml','rb').read()).decode())")
            RT_HTTP=$(curl -s -o /dev/null -w '%{http_code}' \
                -X POST "$API_URL/api/v1/runtimes" \
                -H "Authorization: Bearer $ACCESS_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{
                    \"name\":\"GKE Eval Cluster\",
                    \"type\":\"kubernetes\",
                    \"endpoint\":\"${CLUSTER_ENDPOINT}\",
                    \"credentials\":{\"kubeconfig_content\":\"${KUBECONFIG_B64}\"},
                    \"workspace_id\":\"$WS_ID\",
                    \"environment\":\"development\"
                }")
            if $_xtrace_was_on; then set -x; fi

            if [ "$RT_HTTP" = "201" ] || [ "$RT_HTTP" = "200" ]; then
                ok "GKE runtime registered"
            elif [ "$RT_HTTP" = "409" ] || [ "$RT_HTTP" = "400" ]; then
                info "Runtime may already exist (HTTP $RT_HTTP)"
            else
                warn "Runtime registration returned HTTP $RT_HTTP"
            fi
        fi
    fi
fi

# Cleanup
rm -f /tmp/biznez-runtime-kubeconfig.yaml
kill "$PF_PID" 2>/dev/null || true; PF_PID=""
```

#### Step 15: Verify ingress (dual check: frontend + backend routing)

```bash
if [ -n "${INGRESS_HOST:-}" ]; then
    info "Verifying ingress serves traffic..."

    # Check 1: Frontend (/) — accept 200 or 304 (cached)
    FE_OK=false
    for i in $(seq 1 15); do
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://${INGRESS_HOST}/" 2>/dev/null) || true
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "304" ]; then FE_OK=true; break; fi
        sleep 2
    done

    # Check 2: Backend routing (/api/v1/health)
    BE_OK=false
    for i in $(seq 1 10); do
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://${INGRESS_HOST}/api/v1/health" 2>/dev/null) || true
        if [ "$HTTP_CODE" = "200" ]; then BE_OK=true; break; fi
        sleep 2
    done

    if $FE_OK && $BE_OK; then
        ok "Ingress verified: frontend (/) and backend (/api/v1/health) both return 200"
    else
        warn "Ingress partial: frontend=$FE_OK backend=$BE_OK"
    fi
fi
```

#### Step 16: GitHub Actions output

```bash
if [ -n "${INGRESS_HOST:-}" ]; then
    echo "app_url=http://${INGRESS_HOST}" >> "$GITHUB_OUTPUT"
fi
echo "admin_username=admin" >> "$GITHUB_OUTPUT"
# Password NOT echoed — summary shows kubectl retrieval command
```

---

### Layer 3: Workflow Changes

**File: `.github/workflows/provision-eval.yml`**

#### Job 2 outputs (add)
```yaml
ingress_ip: ${{ steps.tf-outputs.outputs.ingress_ip }}
cluster_endpoint: ${{ steps.tf-outputs.outputs.cluster_endpoint }}
```

#### Job 2 extract step (add)
```bash
echo "ingress_ip=$(terraform output -raw ingress_ip)" >> "$GITHUB_OUTPUT"
echo "cluster_endpoint=$(terraform output -raw cluster_endpoint)" >> "$GITHUB_OUTPUT"
```

No sensitive values. No SA keys. No temp files.

#### Job 3 deploy step
```bash
bash infra/scripts/provision.sh \
    --namespace biznez --release biznez \
    --values-file infra/values/eval-gke.yaml \
    --chart-dir helm/biznez-runtime \
    --ar-url "$AR_URL" \
    --images-lock helm/biznez-runtime/images.lock \
    --ingress-ip "${{ needs.provision-infrastructure.outputs.ingress_ip }}" \
    --cluster-endpoint "${{ needs.provision-infrastructure.outputs.cluster_endpoint }}" \
    --project-id "$GCP_PROJECT_ID"
```

#### Job 4 summary

Replace port-forward instructions with URL-based access. Admin password shown only as kubectl retrieval command (never echoed directly).

---

### Layer 4: Teardown

**File: `.github/workflows/teardown-eval.yml`**

#### Job 2 (uninstall-runtime) — add before existing Helm uninstall:

```bash
# Uninstall nginx-ingress
helm uninstall ingress-nginx -n ingress-nginx 2>/dev/null || true
kubectl delete namespace ingress-nginx --ignore-not-found 2>/dev/null || true

# Delete runtime deployer resources (SA, ClusterRole, ClusterRoleBinding)
kubectl delete clusterrolebinding biznez-runtime-deployer --ignore-not-found 2>/dev/null || true
kubectl delete clusterrole biznez-runtime-deployer --ignore-not-found 2>/dev/null || true
kubectl delete serviceaccount biznez-runtime-deployer -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
```

#### Job 3 gcloud fallback (add after AR repo deletion):

```bash
# 7. Delete static IP
if gcloud compute addresses describe "${PREFIX}-ingress-ip" \
     --region="$REGION" --project="$GCP_PROJECT_ID" &>/dev/null; then
    echo "Deleting static IP: ${PREFIX}-ingress-ip"
    gcloud compute addresses delete "${PREFIX}-ingress-ip" \
      --region="$REGION" --project="$GCP_PROJECT_ID" \
      --quiet 2>&1 && CLEANED="${CLEANED}static-ip," || true
fi
```

---

## Files Modified (6 files)

| # | File | Change |
|---|------|--------|
| 1 | `infra/terraform/modules/networking/main.tf` | Add `google_compute_address` for ingress static IP |
| 2 | `infra/terraform/modules/networking/outputs.tf` | Add `ingress_ip` output |
| 3 | `infra/terraform/environments/eval/outputs.tf` | Expose `ingress_ip` |
| 4 | `infra/scripts/provision.sh` | Single Helm install; steps 10-16 (RBAC+KSA+TokenRequest, port-forward with endpoint check, admin with SELECT confirm, workspace, runtime with existence check, dual ingress verify, output) |
| 5 | `.github/workflows/provision-eval.yml` | Pass ingress_ip + cluster_endpoint, URL-based summary |
| 6 | `.github/workflows/teardown-eval.yml` | Clean up ingress-nginx, SA, ClusterRole/Binding, static IP |

## Security Properties

| Property | How |
|----------|-----|
| No long-lived GCP SA keys | K8s ServiceAccount + TokenRequest API (`--duration=48h`) |
| Least-privilege RBAC | Custom ClusterRole matching `gke.py` REQUIRED_PERMISSIONS + `patch` verb |
| No secrets in logs | Xtrace save/restore (`case "$-"` + `if $_xtrace_was_on; then set -x; fi`) around sensitive ops |
| Portable base64 | `python3 -c "import base64;..."` avoids macOS vs Linux `base64` flag differences |
| Payload never echoed | curl uses `-o file` and `-w '%{http_code}'`, never prints body on error |
| Temp files cleaned on exit | Trap removes kubeconfig + response files on all exit paths |
| Token cleared from env | `unset SA_TOKEN` after kubeconfig is written |
| Kubeconfig restricted | `chmod 600` on temp kubeconfig file |
| Idempotent bootstrap | Register→400→login; workspace→409→skip; runtime→check existing first |
| Mandatory endpoint | `--cluster-endpoint` required when `--ingress-ip` set (prevents wrong cluster) |

## HTTP Limitation (eval-acceptable)

Auth uses bearer tokens (not cookies), so HTTP works for eval. If HTTPS is needed later:
- cert-manager + Let's Encrypt (nip.io doesn't support DNS-01 well)
- Google-managed certificate with a real domain
- Or sslip.io with HTTP-01 challenge

Tracked as a follow-up, not a blocker for eval.

## What the Customer Gets

```
GitHub Actions Summary:

  App URL: http://34.89.42.100.nip.io
  Admin Username: admin
  Admin Password: kubectl get secret biznez-eval-admin-creds -n biznez ...

  Quick Start:
    1. Open http://34.89.42.100.nip.io
    2. Login as admin
    3. Add your LLM API key in Connectors
    4. Deploy your first agent!

  Pre-configured:
    - Default workspace
    - GKE runtime registered
    - OpenAI, Anthropic, Gemini, Ollama connectors
```

No port-forwarding, no gcloud commands, no manual RBAC setup.

## Verification

1. Provision fresh eval via workflow dispatch
2. `http://<ip>.nip.io` — frontend loads (200)
3. `http://<ip>.nip.io/api/v1/health` — backend returns 200 (validates ingress routing)
4. Login as `admin` — works
5. Workspaces → "Default Workspace" exists
6. Runtimes → "GKE Eval Cluster" healthy (RBAC validation passes with custom ClusterRole)
7. Connectors → 4 LLM providers + Gmail
8. Deploy agent to GKE — succeeds (verifies `patch` verb works)
9. Teardown → static IP deleted, ClusterRole/Binding gone, SA deleted, ingress-nginx namespace removed
10. No orphaned resources remain

## Implementation Order

1. Terraform: static IP in networking module (3 files)
2. provision.sh: restructure + steps 10-16 (1 file, biggest change)
3. Workflow: pass outputs, update summary (1 file)
4. Teardown: add cleanup (1 file)
5. Test end-to-end with fresh eval environment
