# MCP Phase 1 — Eval Provisioning Gap Analysis

> **Date:** 2026-03-30 (v2 — updated after review)
> **Scope:** What must change in the GitHub Actions provisioning workflow and Helm chart to support Phase 1 ConfigMap-based gateway integration in eval environments.
> **Reference Plans:** `/Users/manimaun/Documents/code/biznez-agentic-framework/docs/features/MCP/MCPphase1/`

---

## Hard Prerequisites

These must be true before any workflow changes matter:

### 1. Backend image must contain all Phase 1 runtime code

The eval workflow must deploy a backend image built from a commit that includes:
- `ConfigMapApplyService` — the configmap write path
- `apply_status` column and logic in `GatewayPolicyService`
- Route prefix preservation fix in `_prepare_gateway_route()`
- `policy_config` using effective (stored) `route_prefix`
- Atomic commit fix (route + policy prepared before commit)

**Verification:** Before provisioning validation, confirm the deployed image tag matches a commit known to contain Phase 1 changes. Add to post-deploy checks:

```bash
# Confirm Phase 1 code is present in the running image
kubectl exec deploy/biznez-biznez-runtime-backend -n biznez -- \
  python3 -c "from src.agentic_runtime.services.configmap_apply_service import ConfigMapApplyService; print('Phase 1 code present')"
```

If this fails, no amount of env var wiring will help.

### 2. Backend env var injection mechanism confirmed

**Verified:** The Helm chart uses `envFrom: configMapRef` (not per-key `valueFrom.configMapKeyRef`):

```yaml
# helm/biznez-runtime/templates/backend/deployment.yaml (line 120-121)
envFrom:
  {{- include "biznez.backend.envFrom" . | nindent 12 }}

# helm/biznez-runtime/templates/_helpers.tpl (line 355-358)
{{- define "biznez.backend.envFrom" -}}
- configMapRef:
    name: {{ include "biznez.fullname" . }}-backend
{{- end }}
```

**Consequence:** Every key in the backend ConfigMap is automatically injected as an env var. Adding keys to `backend/configmap.yaml` is sufficient — **no deployment template changes needed**.

This is different from the dev cluster defect (documented in `MCP-Phase1C1-Deployment-EnvVar-Fix-Plan.md`) where explicit `configMapKeyRef` entries were missing. The Helm chart uses `envFrom`, so this defect class does not apply here.

### 3. Gateway auto-reload must work

**Acceptance criterion (must-pass):** The agentgateway binary must detect and reload config changes from the mounted ConfigMap file at `/etc/agentgateway/config.yaml` without pod restart.

The gateway deployment already mounts the ConfigMap as a volume (confirmed in `gateway/deployment.yaml` line 79-81). Kubernetes propagates ConfigMap updates to mounted volumes (~60s delay). But the binary must watch for file changes.

**If auto-reload does not work**, the fallback is:
1. **Option A (preferred):** Add `stakater/reloader` annotation to the gateway deployment — triggers pod rollout on ConfigMap change
2. **Option B:** Add a sidecar that watches the file and sends SIGHUP to the gateway process

**This must be tested during implementation, not deferred.** Add to the implementation plan as a gating step.

---

## Phase 1 Summary (What Changed)

- Replaced legacy admin-api (`localhost:15000`) with Kubernetes ConfigMap-based gateway configuration
- Introduced ConfigMap as the single source of truth for gateway routes
- Sync flow: **database → ConfigMap → gateway reload** (no HTTP calls to admin port)
- Route prefix is preserved on existing routes (no regeneration on sync)
- `policy_config` uses the effective (stored) `route_prefix`
- Single atomic commit after route + policy are fully prepared
- No admin-api usage remains

---

## 1. Required Env Vars — Verified Against Source Code

The backend needs these environment variables. Defaults are verified against actual source code.

| Env Var | Code Default | Required Value (Eval) | Currently Set? | Criticality |
|---------|-------------|----------------------|----------------|-------------|
| `GATEWAY_APPLY_MODE` | `"configmap"` | `configmap` | **NO** | **Low** — code already defaults to `configmap` (gateway_policy_service.py:63). Useful for explicitness but not functionally required. |
| `CONFIGMAP_APPLY_MODE` | `"dryrun"` | `k8s` | **NO** | **CRITICAL** — code defaults to `dryrun` (configmap_apply_service.py:31). Without override, all ConfigMap writes are logged but never executed. This is the single most important variable. |
| `GATEWAY_CONFIGMAP_NAME` | `"agent-gateway-config"` | `biznez-biznez-runtime-gateway` | **NO** | **CRITICAL** — code default points to dev cluster name. Eval uses Helm-created name. Wrong name = writes to nonexistent ConfigMap. |
| `GATEWAY_CONFIGMAP_NAMESPACE` | `"mcp-gateway"` | `biznez` | **NO** | **CRITICAL** — code default points to dev namespace. Eval has no `mcp-gateway` namespace. Wrong namespace = 404 on ConfigMap write. |
| `GATEWAY_CONFIGMAP_KEY` | `"config.yaml"` | `config.yaml` | **NO** | **None** — code default matches what the gateway reads. Correct by default. Set explicitly for clarity only. |
| `GATEWAY_ENABLED_ENVIRONMENTS` | `"dev-gcp,staging,production"` | Must include `development` | **NO** | **HIGH** — eval registers runtime as `environment: "development"`. Code default does not include `development`. All sync attempts are silently rejected by `_validate_environment()`. |
| `GATEWAY_CORS_ORIGINS` | `"https://dev-app.35.246.109.199.nip.io,..."` | `http://<INGRESS_IP>.nip.io` | **NO** | **MEDIUM** — code default has dev cluster URLs. Browser-based MCP calls from eval's nip.io domain get CORS errors. |

**Source code references:**
- `GATEWAY_APPLY_MODE`: `gateway_policy_service.py:63` — `os.getenv("GATEWAY_APPLY_MODE", "configmap")`
- `CONFIGMAP_APPLY_MODE`: `configmap_apply_service.py:31` — `os.getenv("CONFIGMAP_APPLY_MODE", "dryrun")`
- `GATEWAY_CONFIGMAP_NAME`: `configmap_apply_service.py:32` — `os.getenv("GATEWAY_CONFIGMAP_NAME", "agent-gateway-config")`
- `GATEWAY_CONFIGMAP_NAMESPACE`: `configmap_apply_service.py:33` — `os.getenv("GATEWAY_CONFIGMAP_NAMESPACE", "mcp-gateway")`
- `GATEWAY_CONFIGMAP_KEY`: `configmap_apply_service.py:34` — `os.getenv("GATEWAY_CONFIGMAP_KEY", "config.yaml")`
- `GATEWAY_ENABLED_ENVIRONMENTS`: `gateway_policy_service.py:75` — `os.getenv("GATEWAY_ENABLED_ENVIRONMENTS", "dev-gcp,staging,production")`
- `GATEWAY_CORS_ORIGINS`: `gateway_config_renderer.py:71` — `os.getenv("GATEWAY_CORS_ORIGINS", "https://dev-app.35.246.109.199.nip.io,...")`

**Classification:**
- **Required for correctness (must override):** `CONFIGMAP_APPLY_MODE`, `GATEWAY_CONFIGMAP_NAME`, `GATEWAY_CONFIGMAP_NAMESPACE`, `GATEWAY_ENABLED_ENVIRONMENTS`
- **Required for UX (should override):** `GATEWAY_CORS_ORIGINS`
- **Required for explicitness only:** `GATEWAY_APPLY_MODE`, `GATEWAY_CONFIGMAP_KEY`

---

## 2. ConfigMap Name — Verified Against Helm Template Output

The gateway ConfigMap name must match exactly between what the gateway pod mounts and what the backend writes to.

### Verified Helm template rendering

With release name `biznez` (used by eval provisioning):

```
$ helm template biznez helm/biznez-runtime ... --show-only templates/gateway/configmap.yaml

metadata:
  name: biznez-biznez-runtime-gateway    ← this is what the gateway pod mounts
```

The Helm helper `{{ include "biznez.fullname" . }}` renders to `biznez-biznez-runtime` (confirmed via `helm template`). The gateway ConfigMap is `{{ include "biznez.fullname" . }}-gateway` = `biznez-biznez-runtime-gateway`.

The gateway deployment mounts this exact name:

```yaml
# gateway/deployment.yaml line 79-81
- name: gateway-config
  configMap:
    name: {{ include "biznez.fullname" . }}-gateway
```

### Template expression for backend ConfigMap

The backend ConfigMap should use the **same Helm helper expression** used by the gateway template, not a hardcoded string:

```yaml
# Correct — uses the same expression as gateway/deployment.yaml
GATEWAY_CONFIGMAP_NAME: {{ printf "%s-gateway" (include "biznez.fullname" .) | quote }}
```

This guarantees the names always match, even if the release name or chart name changes.

### Validation step

After implementation, run:

```bash
helm template biznez helm/biznez-runtime ... 2>&1 | grep -A1 'GATEWAY_CONFIGMAP_NAME'
# Must output: biznez-biznez-runtime-gateway

helm template biznez helm/biznez-runtime ... --show-only templates/gateway/configmap.yaml | grep 'name:'
# Must output: name: biznez-biznez-runtime-gateway

# Both values MUST be identical
```

---

## 3. Required Changes — Files and Code

### A. `helm/biznez-runtime/templates/backend/configmap.yaml`

Add after existing keys (line 32):

```yaml
  # MCP Gateway ConfigMap integration (Phase 1)
  GATEWAY_APPLY_MODE: {{ .Values.backend.config.gatewayApplyMode | default "configmap" | quote }}
  CONFIGMAP_APPLY_MODE: {{ .Values.backend.config.configmapApplyMode | default "dryrun" | quote }}
  GATEWAY_CONFIGMAP_NAME: {{ .Values.backend.config.gatewayConfigmapName | default (printf "%s-gateway" (include "biznez.fullname" .)) | quote }}
  GATEWAY_CONFIGMAP_NAMESPACE: {{ .Values.backend.config.gatewayConfigmapNamespace | default .Release.Namespace | quote }}
  GATEWAY_CONFIGMAP_KEY: {{ .Values.backend.config.gatewayConfigmapKey | default "config.yaml" | quote }}
  GATEWAY_ENABLED_ENVIRONMENTS: {{ .Values.backend.config.gatewayEnabledEnvironments | default "development" | quote }}
  {{- if .Values.backend.config.gatewayCorsOrigins }}
  GATEWAY_CORS_ORIGINS: {{ .Values.backend.config.gatewayCorsOrigins | quote }}
  {{- end }}
```

**No changes needed to `backend/deployment.yaml`** — the `envFrom: configMapRef` pattern automatically injects all ConfigMap keys.

### B. `helm/biznez-runtime/values.yaml`

Add under `backend.config` (after existing keys like `prometheusPort`):

```yaml
    # MCP Gateway ConfigMap integration (Phase 1)
    # gatewayApplyMode: "configmap"       # Code default is already "configmap"
    configmapApplyMode: "dryrun"          # MUST override to "k8s" for live environments
    # gatewayConfigmapName: ""            # Auto-derived: {{ fullname }}-gateway
    # gatewayConfigmapNamespace: ""       # Auto-derived: {{ .Release.Namespace }}
    # gatewayConfigmapKey: "config.yaml"  # Code default is correct
    gatewayEnabledEnvironments: "development"
    gatewayCorsOrigins: ""                # MUST be set for eval/prod (e.g., http://<IP>.nip.io)
```

### C. `infra/scripts/provision.sh`

Add to the `HELM_ARGS` array (after existing `--set` flags, around line 370):

```bash
# Phase 1: MCP Gateway ConfigMap integration — activate real K8s writes
HELM_ARGS+=(
    --set backend.config.configmapApplyMode=k8s
)

if [ -n "${INGRESS_HOST:-}" ]; then
    HELM_ARGS+=(
        --set backend.config.gatewayCorsOrigins="http://${INGRESS_HOST}"
    )
fi
```

Notes:
- `GATEWAY_APPLY_MODE` — not overridden; code default (`configmap`) is correct
- `GATEWAY_CONFIGMAP_NAME` — not overridden; Helm template auto-derives from release name
- `GATEWAY_CONFIGMAP_NAMESPACE` — not overridden; Helm template uses `.Release.Namespace`
- `CONFIGMAP_APPLY_MODE=k8s` — the one critical override
- `GATEWAY_ENABLED_ENVIRONMENTS` — not overridden; values.yaml default changed to `development`
- `GATEWAY_CORS_ORIGINS` — must be set dynamically with eval's nip.io URL

---

## 4. ConfigMap Provisioning Requirements

### A. RBAC — backend writing the gateway ConfigMap

The `biznez-runtime-deployer` ClusterRole (created in provision.sh Step 5.6) already includes:

```yaml
- apiGroups: [""]
  resources: [configmaps]
  verbs: [create, get, update, patch, delete, list]
```

This is cluster-wide. The backend SA can write ConfigMaps in the `biznez` namespace. **No RBAC changes needed.**

### B. Gateway auto-reload (must-pass acceptance criterion)

The gateway deployment mounts the ConfigMap as a volume:

```yaml
# gateway/deployment.yaml line 69-73, 79-81
volumeMounts:
  - name: gateway-config
    mountPath: /etc/agentgateway
    readOnly: true
volumes:
  - name: gateway-config
    configMap:
      name: {{ include "biznez.fullname" . }}-gateway
```

Kubernetes automatically propagates ConfigMap updates to mounted volumes (~60s delay).

**Must verify:** The `agentgateway` binary watches the file and reloads. This is a gating requirement — if it doesn't auto-reload:

1. **Fallback A (preferred):** Add annotation-based reloader (e.g., `stakater/reloader`) to trigger pod rollout on ConfigMap change
2. **Fallback B:** Platform calls `kubectl rollout restart` after ConfigMap write (requires additional RBAC for deployments in `biznez` namespace — already covered by ClusterRole)

**Test procedure:**
```bash
# 1. Get current gateway config
kubectl get cm biznez-biznez-runtime-gateway -n biznez -o jsonpath='{.data.config\.yaml}'

# 2. Authorize an MCP server through the UI

# 3. Verify ConfigMap was updated (should contain routes)
kubectl get cm biznez-biznez-runtime-gateway -n biznez -o jsonpath='{.data.config\.yaml}'

# 4. Verify gateway picked up the change (no pod restart)
kubectl logs deploy/biznez-biznez-runtime-gateway -n biznez --tail=10
# Look for config reload message

# 5. Make a request through the gateway route
curl -s -o /dev/null -w '%{http_code}' http://<GATEWAY_IP>:8080/<route_prefix>/mcp
# Expect 401 (auth required) — NOT 404 (route not found)
```

### C. Initial ConfigMap state

The Helm chart creates the gateway ConfigMap with empty routes:

```yaml
config:
  binds:
    - port: 8080
      listeners:
        - name: default
          routes: []
```

This is correct. Routes are populated by the platform when MCP servers are authorized. No pre-seeding needed.

---

## 5. Gaps Between Current Workflow and Phase 1

| # | Gap | Severity | Impact |
|---|-----|----------|--------|
| 1 | **`CONFIGMAP_APPLY_MODE` not set — defaults to `dryrun`** | **CRITICAL** | ConfigMap writes are logged but never executed. MCP gateway is non-functional. This is the single most important variable. |
| 2 | **`GATEWAY_CONFIGMAP_NAME` defaults to `agent-gateway-config`** | **CRITICAL** | Backend writes to wrong ConfigMap. Gateway never receives routes. |
| 3 | **`GATEWAY_CONFIGMAP_NAMESPACE` defaults to `mcp-gateway`** | **CRITICAL** | Backend targets a namespace that doesn't exist on eval. ConfigMap write returns 404. |
| 4 | **`GATEWAY_ENABLED_ENVIRONMENTS` excludes `development`** | **HIGH** | Eval runtime is `development`. All sync attempts silently rejected by `_validate_environment()`. |
| 5 | **`GATEWAY_CORS_ORIGINS` has hardcoded dev URLs** | **MEDIUM** | Browser MCP requests from eval's nip.io domain get CORS errors. |
| 6 | **Backend ConfigMap template missing gateway keys** | **HIGH** | Even with correct `--set` values, the template doesn't render the keys. Must add them. |
| 7 | **Gateway auto-reload not verified** | **HIGH** | If gateway doesn't reload from file changes, routes are never live until pod restart. |
| 8 | **Backend image may not contain Phase 1 code** | **BLOCKING** | All other changes are irrelevant without the runtime code. |
| 9 | **`GATEWAY_APPLY_MODE` not set** | **LOW** | Code already defaults to `configmap`. Not functionally required. Set for explicitness. |
| 10 | **Legacy admin port 15000 still exposed** | **LOW** | Not used by Phase 1. Cleanup later. |

---

## 6. Risks If Not Ported

1. **MCP servers unreachable through gateway** — `CONFIGMAP_APPLY_MODE=dryrun` means all ConfigMap writes are logged but never executed. Routes stay `apply_status='pending'` forever. Agents can't access MCP tools via the gateway.

2. **Silent failure** — No error is thrown. The dryrun path looks identical to success in logs except the ConfigMap is never written. The UI may show "deployed" but MCP tools don't work.

3. **Route prefix mutation** — Without the Phase 1 fix to `_prepare_gateway_route()`, existing routes get `route_prefix` overwritten on every sync. This is a runtime code fix — must be in the deployed image.

4. **Environment rejection** — `GATEWAY_ENABLED_ENVIRONMENTS` default excludes `development`. All eval sync attempts are silently rejected.

5. **CORS failure** — Even if routes sync correctly, wrong CORS origins cause browser-based MCP requests to fail.

6. **Gateway stale config** — If auto-reload doesn't work, the gateway serves stale config until pod restart. Routes appear `applied` in DB but are not actually live.

---

## 7. Minimal Implementation Plan

| Step | File(s) | Change | Effort | Gating? |
|------|---------|--------|--------|---------|
| **0** | Runtime repo | Confirm backend image contains all Phase 1 code. Identify minimum commit hash. | Pre-work | **YES** |
| **1** | `helm/.../backend/configmap.yaml` | Add 7 gateway env var keys with `.Values` overrides and auto-derived defaults | Small | YES |
| **2** | `helm/.../values.yaml` | Add `backend.config.*` gateway values | Small | YES |
| **3** | `infra/scripts/provision.sh` | Add `--set backend.config.configmapApplyMode=k8s` and CORS origin | Small | YES |
| **4** | Gateway deployment | Verify auto-reload works. If not, add reloader annotation or sidecar. | Small–Medium | **YES** |
| **5** | `.github/workflows/upgrade-eval.yml` | No change needed — `--reuse-values` preserves new env vars | None | No |
| **6** | Post-provision validation | Add live gateway traffic check to verification suite | Medium | No |

### Execution Order

```
Step 0:  Confirm Phase 1 code is in the BE image (BLOCKING prerequisite)
Step 1-3: Helm chart + provision.sh changes (single PR to biznez-runtime-dist)
Step 4:  Test gateway auto-reload on eval cluster (MUST PASS before merge)
Step 5:  No action
Step 6:  Optional follow-up PR
```

---

## 8. Verification

After deploying to a new eval environment:

### 8.1 Env vars are injected

```bash
kubectl exec deploy/biznez-biznez-runtime-backend -n biznez -- env | grep -E '(GATEWAY_|CONFIGMAP_)'
```

Expected:
```
GATEWAY_APPLY_MODE=configmap
CONFIGMAP_APPLY_MODE=k8s
GATEWAY_CONFIGMAP_NAME=biznez-biznez-runtime-gateway
GATEWAY_CONFIGMAP_NAMESPACE=biznez
GATEWAY_CONFIGMAP_KEY=config.yaml
GATEWAY_ENABLED_ENVIRONMENTS=development
GATEWAY_CORS_ORIGINS=http://<IP>.nip.io
```

### 8.2 Phase 1 code is present

```bash
kubectl exec deploy/biznez-biznez-runtime-backend -n biznez -- \
  python3 -c "from src.agentic_runtime.services.configmap_apply_service import ConfigMapApplyService; print('OK')"
```

### 8.3 ConfigMap updated after MCP authorization

```bash
# Before: empty routes
kubectl get cm biznez-biznez-runtime-gateway -n biznez -o jsonpath='{.data.config\.yaml}'

# Authorize an MCP server through the UI, then:
kubectl get cm biznez-biznez-runtime-gateway -n biznez -o jsonpath='{.data.config\.yaml}'
# Should now contain routes
```

### 8.4 Gateway reloaded (no pod restart)

```bash
kubectl logs deploy/biznez-biznez-runtime-gateway -n biznez --tail=20
# Look for config reload message after ConfigMap update
```

### 8.5 Route status in DB

```bash
kubectl exec deploy/biznez-biznez-runtime-backend -n biznez -- python3 -c "
from sqlalchemy import create_engine, text
import os
engine = create_engine(os.environ['DATABASE_URL'])
with engine.connect() as c:
    for r in c.execute(text('SELECT mcp_server_name, route_prefix, apply_status FROM gateway_routes')):
        print(dict(r._mapping))
"
```

Expected: `apply_status='applied'` for authorized servers.

### 8.6 Live traffic through gateway (most important)

```bash
# Get the gateway route prefix from DB (e.g., /org_xxx/brave-search)
# Make a request through the gateway
curl -s -o /dev/null -w '%{http_code}' http://<GATEWAY_URL>/<route_prefix>/mcp
```

Expected: **401** (authentication required) — proves the route exists and is live.
**404** means the route was not found — gateway did not reload or ConfigMap was not written.

This is the definitive test. All other checks are intermediate.

---

## Appendix: Phase 1 Sync Flow Reference

```
User authorizes MCP server
         │
         ▼
GatewayPolicyService.sync_authorization()
  │
  ├── Validate environment (reject if not in GATEWAY_ENABLED_ENVIRONMENTS)
  ├── _prepare_gateway_route()
  │     └── PRESERVE existing route_prefix (only generate if null/empty)
  ├── Upsert gateway_routes row: apply_status='pending'
  ├── GatewayConfigRenderer.render_full_shared_config()
  │     └── ALL active routes for ALL orgs (full shared config)
  ├── ConfigMapApplyService.apply()
  │     ├── Guard: reject scoped renders (is_scoped=True)
  │     ├── Mode: k8s → write to K8s ConfigMap with optimistic lock
  │     └── Mode: dryrun → log only, no K8s write  ← DEFAULT (broken for eval)
  └── On success: apply_status='applied', last_applied_at=now()
         │
         ▼
K8s ConfigMap updated in biznez namespace
         │
         ▼
Gateway pod auto-reloads from mounted config file (MUST be verified)
         │
         ▼
Route is live — GatewayRouteResolver returns apply_status='applied' routes
```
