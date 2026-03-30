# MCP Phase 1 — Eval Environment Implementation Plan

> **Date:** 2026-03-30
> **Status:** Implementation-ready
> **Scope:** Port all Phase 1 MCP gateway changes into the eval provisioning workflow
> **Reference Plans:** `/Users/manimaun/Documents/code/biznez-agentic-framework/docs/features/MCP/MCPphase1/`

---

## Critical Check 1: Backend Env Var Injection Model

**Finding: `envFrom` with `configMapRef` — all keys auto-injected.**

Evidence:

```yaml
# helm/biznez-runtime/templates/backend/deployment.yaml (lines 120-121)
envFrom:
  {{- include "biznez.backend.envFrom" . | nindent 12 }}

# helm/biznez-runtime/templates/_helpers.tpl (lines 355-358)
{{- define "biznez.backend.envFrom" -}}
- configMapRef:
    name: {{ include "biznez.fullname" . }}-backend
{{- end }}
```

The backend deployment uses `envFrom` with `configMapRef`, not per-key `valueFrom.configMapKeyRef`. Every key in the backend ConfigMap is automatically injected as an environment variable into the pod.

The migration job (both initContainer and hook-based) uses the same helpers (`biznez.backend.envFrom` and `biznez.backend.envVars`), so it also receives all ConfigMap keys.

**Consequence:** Adding keys to `backend/configmap.yaml` is sufficient. No changes to `backend/deployment.yaml` or `migration-job.yaml` are needed. This is structurally different from the dev cluster defect documented in `MCP-Phase1C1-Deployment-EnvVar-Fix-Plan.md`, where explicit `configMapKeyRef` entries were missing.

---

## Critical Check 2: Exact Rendered Gateway ConfigMap Name

**Finding: Both expressions are identical. Rendered name is `biznez-biznez-runtime-gateway`.**

Evidence:

```yaml
# Gateway ConfigMap resource name:
# helm/biznez-runtime/templates/gateway/configmap.yaml (line 5)
name: {{ include "biznez.fullname" . }}-gateway

# Gateway Deployment volume mount:
# helm/biznez-runtime/templates/gateway/deployment.yaml (line 81)
name: {{ include "biznez.fullname" . }}-gateway
```

Both use the identical expression `{{ include "biznez.fullname" . }}-gateway`.

Tracing `biznez.fullname` with release name `biznez` and chart name `biznez-runtime`:

```
# _helpers.tpl (lines 16-27)
$name = default .Chart.Name .Values.nameOverride → "biznez-runtime"
contains "biznez-runtime" "biznez" → false
printf "%s-%s" "biznez" "biznez-runtime" → "biznez-biznez-runtime"
```

Result: `biznez-biznez-runtime-gateway`

Confirmed via `helm template`:
```
$ helm template biznez helm/biznez-runtime ... --show-only templates/gateway/configmap.yaml
metadata:
  name: biznez-biznez-runtime-gateway
```

**The backend ConfigMap template must use the same expression** to derive `GATEWAY_CONFIGMAP_NAME`, guaranteeing the names always match regardless of release name or chart name changes.

---

## Critical Check 3: Actual Runtime Code Defaults

| Env Var | Source File:Line | Exact `os.getenv()` Call | Default Value | Critical to Override? |
|---------|-----------------|--------------------------|---------------|----------------------|
| `GATEWAY_APPLY_MODE` | `gateway_policy_service.py:63` | `os.getenv("GATEWAY_APPLY_MODE", "configmap")` | `"configmap"` | **No** — default is correct. Set for explicitness only. |
| `CONFIGMAP_APPLY_MODE` | `configmap_apply_service.py:31` | `os.getenv("CONFIGMAP_APPLY_MODE", "dryrun")` | `"dryrun"` | **YES — CRITICAL.** Dryrun logs YAML but never writes to K8s. Must be `"k8s"`. |
| `GATEWAY_CONFIGMAP_NAME` | `configmap_apply_service.py:32` | `os.getenv("GATEWAY_CONFIGMAP_NAME", "agent-gateway-config")` | `"agent-gateway-config"` | **YES — CRITICAL.** Eval uses `biznez-biznez-runtime-gateway`. |
| `GATEWAY_CONFIGMAP_NAMESPACE` | `configmap_apply_service.py:33` | `os.getenv("GATEWAY_CONFIGMAP_NAMESPACE", "mcp-gateway")` | `"mcp-gateway"` | **YES — CRITICAL.** Eval uses `biznez` namespace. No `mcp-gateway` exists. |
| `GATEWAY_CONFIGMAP_KEY` | `configmap_apply_service.py:34` | `os.getenv("GATEWAY_CONFIGMAP_KEY", "config.yaml")` | `"config.yaml"` | **No** — default matches what gateway reads. Correct by default. |
| `GATEWAY_ENABLED_ENVIRONMENTS` | `gateway_policy_service.py:75` | `os.getenv("GATEWAY_ENABLED_ENVIRONMENTS", "dev-gcp,staging,production")` | `"dev-gcp,staging,production"` | **YES — HIGH.** Eval runtime uses `environment: "development"`. Default rejects it. |
| `GATEWAY_CORS_ORIGINS` | `gateway_config_renderer.py:71` | `os.getenv("GATEWAY_CORS_ORIGINS", "https://dev-app.35.246.109.199.nip.io,...")` | Dev cluster URLs | **YES — MEDIUM.** Eval uses `http://<IP>.nip.io`. |

### Dryrun vs K8s mode behavior

When `CONFIGMAP_APPLY_MODE="dryrun"` (the default):
- `ConfigMapApplyService.apply()` calls `_apply_dryrun()` (line 103-110)
- Logs `[DRYRUN] Would apply gateway config...` at INFO level
- Dumps YAML to debug log
- Returns `success=True` with `mode="dryrun"` — **appears to succeed**
- **Does NOT contact the Kubernetes API. ConfigMap is never written.**

When `CONFIGMAP_APPLY_MODE="k8s"`:
- Acquires in-process mutex per `(namespace, configmap_name)`
- Reads current ConfigMap via K8s API, extracts `resourceVersion`
- PATCHes with optimistic locking
- Retries up to 3 times on 409 conflict (exponential backoff)
- Creates new ConfigMap on 404
- Returns real success/failure status

**This is the single most important variable.** Without `k8s` mode, everything else is irrelevant.

---

## Corrected Gap Analysis

### Variables that MUST be overridden (will break if missing)

| # | Env Var | Why | Default Behavior |
|---|---------|-----|-----------------|
| 1 | `CONFIGMAP_APPLY_MODE` | Must be `k8s` | Default `dryrun` silently no-ops all ConfigMap writes. Appears to succeed but nothing is written. |
| 2 | `GATEWAY_CONFIGMAP_NAME` | Must be `biznez-biznez-runtime-gateway` | Default `agent-gateway-config` targets a ConfigMap that doesn't exist on eval. Write fails or creates orphan. |
| 3 | `GATEWAY_CONFIGMAP_NAMESPACE` | Must be `biznez` | Default `mcp-gateway` targets a namespace that doesn't exist on eval. K8s API returns 404. |
| 4 | `GATEWAY_ENABLED_ENVIRONMENTS` | Must include `development` | Default `dev-gcp,staging,production` excludes `development`. `_validate_environment()` raises `ValueError`, silently rejecting all sync attempts. |

### Variables that SHOULD be overridden (UX/correctness issues)

| # | Env Var | Why | Default Behavior |
|---|---------|-----|-----------------|
| 5 | `GATEWAY_CORS_ORIGINS` | Must include eval's nip.io URL | Default has dev cluster URLs. Browser-based MCP requests get CORS errors. |

### Variables that are optional (defaults are correct)

| # | Env Var | Why OK | Default |
|---|---------|--------|---------|
| 6 | `GATEWAY_APPLY_MODE` | Code already defaults to `configmap` | `"configmap"` |
| 7 | `GATEWAY_CONFIGMAP_KEY` | Code default matches gateway mount | `"config.yaml"` |

---

## Exact Files That Must Change

### File 1: `helm/biznez-runtime/templates/backend/configmap.yaml`

**Current state:** 20 keys (lines 9-32). No gateway-related keys.

**Add after line 32** (after `DB_POOL_RECYCLE`):

```yaml
  {{- /* MCP Gateway ConfigMap integration (Phase 1) */ -}}
  {{- if .Values.gateway.enabled }}
  GATEWAY_APPLY_MODE: {{ .Values.backend.config.gatewayApplyMode | default "configmap" | quote }}
  CONFIGMAP_APPLY_MODE: {{ .Values.backend.config.configmapApplyMode | default "dryrun" | quote }}
  GATEWAY_CONFIGMAP_NAME: {{ .Values.backend.config.gatewayConfigmapName | default (printf "%s-gateway" (include "biznez.fullname" .)) | quote }}
  GATEWAY_CONFIGMAP_NAMESPACE: {{ .Values.backend.config.gatewayConfigmapNamespace | default .Release.Namespace | quote }}
  GATEWAY_CONFIGMAP_KEY: {{ .Values.backend.config.gatewayConfigmapKey | default "config.yaml" | quote }}
  GATEWAY_ENABLED_ENVIRONMENTS: {{ .Values.backend.config.gatewayEnabledEnvironments | default "development" | quote }}
  {{- if .Values.backend.config.gatewayCorsOrigins }}
  GATEWAY_CORS_ORIGINS: {{ .Values.backend.config.gatewayCorsOrigins | quote }}
  {{- end }}
  {{- end }}
```

**Design decisions:**
- Guarded by `gateway.enabled` — no gateway vars if gateway is disabled
- `GATEWAY_CONFIGMAP_NAME` uses `{{ printf "%s-gateway" (include "biznez.fullname" .) }}` — the **exact same expression** used in `gateway/configmap.yaml` line 5 and `gateway/deployment.yaml` line 81. Guaranteed to match.
- `GATEWAY_CONFIGMAP_NAMESPACE` defaults to `.Release.Namespace` — matches the namespace where Helm deploys.
- `GATEWAY_CORS_ORIGINS` only rendered if set — avoids injecting empty string that overrides runtime's default list.
- `CONFIGMAP_APPLY_MODE` defaults to `dryrun` in values.yaml — safe default. Must be explicitly overridden to `k8s` in provision.sh.

**No changes needed to:**
- `backend/deployment.yaml` — `envFrom: configMapRef` auto-injects all keys
- `migration-job.yaml` — uses same `biznez.backend.envFrom` helper
- `gateway/deployment.yaml` — no changes needed (mounts same ConfigMap)
- `gateway/configmap.yaml` — no changes needed (initial empty routes is correct)

### File 2: `helm/biznez-runtime/values.yaml`

**Add under `backend.config` section** (after `prometheusPort` at line ~84):

```yaml
    # MCP Gateway ConfigMap integration (Phase 1)
    # See claud_doc/packaging/MCPplumbing/phase1-eval-implementation-plan.md
    gatewayApplyMode: "configmap"         # Code default. Set for explicitness.
    configmapApplyMode: "dryrun"          # MUST override to "k8s" for live environments.
    # gatewayConfigmapName: ""            # Auto-derived: {{ fullname }}-gateway. Do not set.
    # gatewayConfigmapNamespace: ""       # Auto-derived: {{ .Release.Namespace }}. Do not set.
    # gatewayConfigmapKey: "config.yaml"  # Code default is correct. Do not set.
    gatewayEnabledEnvironments: "development"
    gatewayCorsOrigins: ""                # MUST be set for eval/prod (e.g., http://<IP>.nip.io)
```

**Design decisions:**
- `configmapApplyMode: "dryrun"` is the safe default for local/dev. Override to `k8s` only in provisioning.
- `gatewayConfigmapName` and `gatewayConfigmapNamespace` are commented out — auto-derived from Helm release. Setting them is unnecessary and creates a maintenance risk.
- `gatewayEnabledEnvironments: "development"` — changed from code default (`dev-gcp,staging,production`) to match eval's runtime registration.

### File 3: `infra/scripts/provision.sh`

**Add to `HELM_ARGS` array** (after the ingress block, around line 371):

```bash
# ---------------------------------------------------------------------------
# Phase 1: MCP Gateway ConfigMap integration
# Activate real K8s writes so gateway routes are applied, not just logged.
# ---------------------------------------------------------------------------
HELM_ARGS+=(
    --set backend.config.configmapApplyMode=k8s
)

if [ -n "${INGRESS_HOST:-}" ]; then
    HELM_ARGS+=(
        --set backend.config.gatewayCorsOrigins="http://${INGRESS_HOST}"
    )
fi
```

**What is NOT overridden and why:**
- `gatewayApplyMode` — code default `configmap` is correct
- `gatewayConfigmapName` — auto-derived by Helm template from release name
- `gatewayConfigmapNamespace` — auto-derived by Helm template from release namespace
- `gatewayConfigmapKey` — code default `config.yaml` is correct
- `gatewayEnabledEnvironments` — values.yaml default `development` is correct for eval

**Only two `--set` flags needed:**
1. `configmapApplyMode=k8s` — the critical switch from dryrun to real writes
2. `gatewayCorsOrigins` — dynamic, depends on eval's ingress IP

### File 4: `.github/workflows/upgrade-eval.yml`

**No direct workflow change currently required**, assuming:
1. The initial provisioning is done with the updated chart (containing the new `backend.config.*` values)
2. No later step in the workflow overrides these values unexpectedly

The workflow uses `--reuse-values` (line 493), which preserves all existing config from the initial `helm install`. Only image tags are overridden during upgrades. The gateway env vars set during provisioning persist across upgrades automatically.

**Caveat:** `--reuse-values` only helps after the first successful provisioning with the new chart values. If an eval was initially installed before the chart changes, the gateway env vars will not be present, and a fresh `helm install` (or explicit `--set` overrides in the upgrade workflow) would be needed to inject them.

---

## Gateway Auto-Reload

### Requirement

After the backend writes to the gateway ConfigMap, the gateway pod must detect the file change and reload its configuration **without pod restart**. This is a gating requirement, not optional.

### How it works

1. K8s mounts the ConfigMap as a volume at `/etc/agentgateway/` (read-only)
2. K8s propagates ConfigMap data updates to mounted volumes (~30-60s delay via kubelet sync period)
3. The `agentgateway` binary must watch for file changes and reload

### What must be validated

The `agentgateway` binary (from `ghcr.io/agentgateway/agentgateway`) must support config file watching. This is an external dependency.

**Test procedure** (run on a live eval cluster after implementation):

```bash
# 1. Snapshot current gateway ConfigMap
kubectl get cm biznez-biznez-runtime-gateway -n biznez -o jsonpath='{.data.config\.yaml}' > /tmp/before.yaml

# 2. Authorize an MCP server through the platform UI

# 3. Wait 30s for backend to write + K8s to propagate
sleep 30

# 4. Verify ConfigMap was updated
kubectl get cm biznez-biznez-runtime-gateway -n biznez -o jsonpath='{.data.config\.yaml}' > /tmp/after.yaml
diff /tmp/before.yaml /tmp/after.yaml  # Must show new routes

# 5. Verify gateway reloaded (check logs for reload message)
kubectl logs deploy/biznez-biznez-runtime-gateway -n biznez --tail=20 --since=60s

# 6. Verify route is live via traffic test
ROUTE_PREFIX=$(kubectl exec deploy/biznez-biznez-runtime-backend -n biznez -- python3 -c "
from sqlalchemy import create_engine, text; import os
e = create_engine(os.environ['DATABASE_URL'])
with e.connect() as c:
    r = c.execute(text(\"SELECT route_prefix FROM gateway_routes WHERE apply_status='applied' LIMIT 1\"))
    row = r.fetchone()
    print(row[0] if row else '')
")

# Expect 401 (auth required) — NOT 404 (route not found)
curl -s -o /dev/null -w '%{http_code}' http://biznez-biznez-runtime-gateway.biznez:8080${ROUTE_PREFIX}/mcp
```

### Fallback if auto-reload fails

If the gateway does not reload from file changes:

**Preferred: Native gateway file-watch reload.** The `agentgateway` binary should detect file changes on its mounted volume and reload without restart. This is the target design — no additional infrastructure needed.

**Acceptable fallback (runtime correctness): Reloader/controller.** If the gateway binary does not support file-watch reload:

- **Option A:** Add Stakater Reloader annotation to gateway deployment. Triggers a rolling restart when the ConfigMap changes:

  ```yaml
  # In gateway/deployment.yaml metadata.annotations:
  reloader.stakater.com/auto: "true"
  ```

  Requires Stakater Reloader to be installed on the cluster (add to Terraform or provision.sh).

- **Option B:** After the backend writes the ConfigMap, trigger a rollout restart from backend code. The backend already has K8s API access via the service account. This could be added to `ConfigMapApplyService._apply_k8s()` in the runtime repo.

**Not acceptable as final design: Provision-time-only restart.** A post-sync `kubectl rollout restart` in provision.sh only covers the initial environment build. It does **not** solve the runtime use case — when users later authorize MCP servers, they expect routes to appear live without manual ops. This is acceptable only as a **temporary test fallback** during initial validation, not as the final Phase 1 portability solution.

---

## Mismatch Between Phase 1 Dev Assumptions and Eval Chart Structure

| Aspect | Phase 1 Dev Cluster | Eval (Helm Chart) | Action |
|--------|--------------------|--------------------|--------|
| Gateway ConfigMap name | `agent-gateway-config` | `biznez-biznez-runtime-gateway` | Override via env var (auto-derived in template) |
| Gateway namespace | `mcp-gateway` | `biznez` | Override via env var (auto-derived in template) |
| Backend env injection | Explicit `configMapKeyRef` (had defect) | `envFrom: configMapRef` (auto-inject) | No defect — adding keys to ConfigMap is sufficient |
| RBAC for ConfigMap writes | Namespaced Role + RoleBinding in `mcp-gateway` | ClusterRole `biznez-runtime-deployer` (cluster-wide ConfigMap access) | No change needed — ClusterRole covers it |
| Runtime environment name | `dev-gcp` | `development` | Override `GATEWAY_ENABLED_ENVIRONMENTS` |
| CORS origins | Hardcoded dev URLs | Dynamic nip.io URL | Override via `--set` at provision time |
| Gateway image | Runs in `mcp-gateway` namespace | Runs in `biznez` namespace | Same-namespace write — simpler RBAC |

---

## Hard Prerequisites

### 1. Backend image must contain Phase 1 runtime code

The deployed backend image must include:
- `ConfigMapApplyService` class and `_apply_k8s()` method
- `apply_status` column logic in `GatewayPolicyService`
- Route prefix preservation fix in `_prepare_gateway_route()`
- `policy_config` using stored `route_prefix`
- Atomic commit fix
- Alembic migration `phase1c_gateway_apply_status.py`

**Verification:**
```bash
kubectl exec deploy/biznez-biznez-runtime-backend -n biznez -- \
  python3 -c "from src.agentic_runtime.services.configmap_apply_service import ConfigMapApplyService; print('Phase 1 code present')"
```

If this import fails, the image does not contain Phase 1 code and no amount of env var wiring will help.

### 2. Database migrations must have run

The `phase1c_gateway_apply_status` migration adds columns (`apply_status`, `last_applied_at`, `apply_error_message`, `apply_retry_count`, `source`) to `gateway_routes`. The migration initContainer runs automatically on Helm install/upgrade.

---

## Minimal Implementation Plan

| Step | File | Change | Effort | Gating? |
|------|------|--------|--------|---------|
| **0** | Runtime repo | Confirm BE image tag contains Phase 1 code. Record minimum commit hash. | Pre-check | **YES** |
| **1** | `helm/.../backend/configmap.yaml` | Add 7 gateway env var keys (guarded by `gateway.enabled`) | Small | YES |
| **2** | `helm/.../values.yaml` | Add `backend.config.*` gateway values with safe defaults | Small | YES |
| **3** | `infra/scripts/provision.sh` | Add `--set configmapApplyMode=k8s` and CORS origin | Small | YES |
| **4** | Live eval cluster | Test gateway auto-reload. If fails, implement fallback. | Small-Medium | **YES** |
| **5** | `.github/workflows/upgrade-eval.yml` | No change needed, assuming initial provisioning uses updated chart and no later step overrides values | None | No |

### Execution sequence

```
Step 0:   Verify Phase 1 code is in the current BE image (BLOCKING)
Steps 1-3: Single PR to biznez-runtime-dist
Step 4:   Test on a live eval cluster after PR is merged and deployed
Step 5:   No action needed
```

---

## Verification Plan for a Fresh Eval Environment

Run these checks after provisioning a new eval with the implementation applied.

### V1. Env vars are injected correctly

```bash
kubectl exec deploy/biznez-biznez-runtime-backend -n biznez -- env | grep -E '(GATEWAY_|CONFIGMAP_)'
```

**Expected output:**
```
GATEWAY_APPLY_MODE=configmap
CONFIGMAP_APPLY_MODE=k8s
GATEWAY_CONFIGMAP_NAME=biznez-biznez-runtime-gateway
GATEWAY_CONFIGMAP_NAMESPACE=biznez
GATEWAY_CONFIGMAP_KEY=config.yaml
GATEWAY_ENABLED_ENVIRONMENTS=development
GATEWAY_CORS_ORIGINS=http://<IP>.nip.io
```

**Failure mode:** If `CONFIGMAP_APPLY_MODE=dryrun`, the `--set` in provision.sh is not taking effect.

### V2. Phase 1 code is present

```bash
kubectl exec deploy/biznez-biznez-runtime-backend -n biznez -- \
  python3 -c "from src.agentic_runtime.services.configmap_apply_service import ConfigMapApplyService; print('OK')"
```

**Expected:** `OK`

### V3. ConfigMap name matches between backend env and gateway mount

**V3a. Helm template proof (run before deploying):**

```bash
# Render both templates and extract the gateway ConfigMap name
GATEWAY_CM=$(helm template biznez helm/biznez-runtime \
  --show-only templates/gateway/configmap.yaml 2>/dev/null \
  | grep '  name:' | head -1 | awk '{print $2}')

BACKEND_CM_VAR=$(helm template biznez helm/biznez-runtime \
  --show-only templates/backend/configmap.yaml 2>/dev/null \
  | grep 'GATEWAY_CONFIGMAP_NAME' | awk -F': ' '{print $2}' | tr -d '"')

echo "Gateway ConfigMap resource name: $GATEWAY_CM"
echo "Backend env GATEWAY_CONFIGMAP_NAME: $BACKEND_CM_VAR"
[ "$GATEWAY_CM" = "$BACKEND_CM_VAR" ] && echo "MATCH" || echo "MISMATCH — STOP"
```

**Both must output the same string.** This is a formal pre-deployment gate, not an assumption. The expressions use the same Helm helper (`biznez.fullname`), but rendering both templates proves it end-to-end regardless of release name, chart name, or `nameOverride`.

**V3b. Live cluster confirmation (run after deploying):**

```bash
# Backend's target ConfigMap
kubectl exec deploy/biznez-biznez-runtime-backend -n biznez -- \
  printenv GATEWAY_CONFIGMAP_NAME

# Gateway's mounted ConfigMap (from deployment spec)
kubectl get deploy biznez-biznez-runtime-gateway -n biznez \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="gateway-config")].configMap.name}'
```

**Both must output:** `biznez-biznez-runtime-gateway`

### V4. ConfigMap updated after MCP server authorization

```bash
# Before: should show empty routes
kubectl get cm biznez-biznez-runtime-gateway -n biznez -o jsonpath='{.data.config\.yaml}' | grep 'routes'

# Authorize an MCP server through the platform UI, wait 10s

# After: should show populated routes
kubectl get cm biznez-biznez-runtime-gateway -n biznez -o jsonpath='{.data.config\.yaml}' | grep 'routes'
```

### V4b. Migration job env inheritance (no side effects)

The migration job uses the same `biznez.backend.envFrom` helper and therefore receives all ConfigMap keys, including the new gateway env vars. Verify that these env vars do not cause startup-time sync, ConfigMap writes, or any unintended side effects during migration runs.

```bash
# Check migration job logs for any gateway-related activity
kubectl logs job/biznez-biznez-runtime-migration -n biznez 2>/dev/null | grep -i -E '(gateway|configmap_apply|dryrun)' || echo "No gateway activity during migration — OK"
```

**Expected:** No gateway-related log lines. The migration job only runs Alembic migrations; it should not trigger any `ConfigMapApplyService` logic. If gateway activity appears, investigate whether the migration entrypoint is importing application services that run on import.

### V5. Route status in database

```bash
kubectl exec deploy/biznez-biznez-runtime-backend -n biznez -- python3 -c "
from sqlalchemy import create_engine, text; import os
e = create_engine(os.environ['DATABASE_URL'])
with e.connect() as c:
    for r in c.execute(text('SELECT mcp_server_name, route_prefix, apply_status, last_applied_at FROM gateway_routes')):
        print(dict(r._mapping))
"
```

**Expected:** `apply_status='applied'` and `last_applied_at` is not null for authorized servers.

### V6. Gateway reloaded (no pod restart)

```bash
kubectl logs deploy/biznez-biznez-runtime-gateway -n biznez --tail=20 --since=120s
```

**Expected:** Config reload log message. No restarts.

### V7. Live traffic test (definitive)

```bash
# Get a route_prefix from the DB
ROUTE=$(kubectl exec deploy/biznez-biznez-runtime-backend -n biznez -- python3 -c "
from sqlalchemy import create_engine, text; import os
e = create_engine(os.environ['DATABASE_URL'])
with e.connect() as c:
    r = c.execute(text(\"SELECT route_prefix FROM gateway_routes WHERE apply_status='applied' LIMIT 1\")).fetchone()
    print(r[0] if r else '')
")

# Port-forward to gateway
kubectl port-forward svc/biznez-biznez-runtime-gateway 8080:8080 -n biznez &
PF_PID=$!
sleep 2

# Request through gateway
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080${ROUTE}/mcp)
kill $PF_PID

echo "HTTP response: $HTTP_CODE"
```

**Expected:** `401` (authentication required) — proves the route exists and is live.
**Failure:** `404` means the route was not found — gateway did not reload or ConfigMap was not written.

This is the definitive test. All other checks are intermediate.

---

## Risks If Not Ported Correctly

| Risk | Severity | Detection Difficulty | Symptom |
|------|----------|---------------------|---------|
| `CONFIGMAP_APPLY_MODE` stays `dryrun` | **Critical** | **Hard** — dryrun returns `success=True`, no errors in logs | In eval, `apply_status='applied'` is **only trustworthy when `CONFIGMAP_APPLY_MODE=k8s`**. With dryrun, the `_apply_dryrun()` path returns `success=True` and `apply_status` may be set to `'applied'` by upstream code despite no K8s write occurring. Gateway has no routes. |
| `GATEWAY_CONFIGMAP_NAME` wrong | **Critical** | **Medium** — K8s API error in backend logs | Backend creates orphan ConfigMap `agent-gateway-config` in wrong namespace. Gateway's `biznez-biznez-runtime-gateway` stays empty. |
| `GATEWAY_ENABLED_ENVIRONMENTS` excludes `development` | **High** | **Hard** — `ValueError` raised inside `_validate_environment()` but may be caught silently | All sync attempts fail. No routes are ever created. |
| Gateway doesn't auto-reload | **High** | **Medium** — ConfigMap has routes but gateway returns 404 | Routes are written correctly but gateway serves stale empty config until pod restart. |
| CORS origins wrong | **Medium** | **Easy** — browser console shows CORS error | MCP tools work via direct API but fail from browser UI. |
| Backend image missing Phase 1 code | **Blocking** | **Easy** — import error on `ConfigMapApplyService` | Nothing works. No new code paths exist. |

---

## Go / No-Go Checklist

Before merging the implementation PR:

- [ ] **Phase 1 code in BE image:** `ConfigMapApplyService` import succeeds
- [ ] **Helm template renders correctly:** `helm template` shows all 7 gateway keys in backend ConfigMap
- [ ] **ConfigMap name match (helm template proof):** `helm template` for both `gateway/configmap.yaml` and `backend/configmap.yaml` renders the exact same gateway ConfigMap name string (V3a)
- [ ] **ConfigMap name match (live):** Backend env var and gateway volume mount resolve to same name on cluster (V3b)
- [ ] **`CONFIGMAP_APPLY_MODE=k8s`:** Confirmed via `kubectl exec ... env`
- [ ] **`GATEWAY_ENABLED_ENVIRONMENTS` includes `development`:** Confirmed via `kubectl exec ... env`
- [ ] **Migration job has no gateway side effects:** No gateway/configmap_apply log lines during migration run (V4b)
- [ ] **Gateway auto-reload works:** ConfigMap update triggers route availability without pod restart (native file-watch or reloader — provision-time restart alone is not acceptable)
- [ ] **Live traffic test passes:** `curl` through gateway returns 401 (not 404)

All items must pass. If gateway auto-reload fails, implement an acceptable fallback (reloader or backend-triggered restart) before merging. Provision-time-only restart is not valid as the final solution.

**Status: GO for implementation** — all critical unknowns are resolved, all changes are scoped, risk is well-understood.
