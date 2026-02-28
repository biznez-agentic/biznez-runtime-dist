# Plan: Phase 5 -- Production Hardening

## Context

Phases 0-4 are complete. The chart renders all services (backend, frontend, postgres, gateway), networking (ingress, gateway-api, networkpolicy), and migrations. The eval profile works out of the box. Phase 5 adds production enforcement: `values-production.yaml` with CIS-hardened defaults, `{{ fail }}` guards that block misconfiguration at render time, HPA for autoscaling, PDB for disruption budgets, and digest-pinning for supply chain security.

**Repo:** `/Users/manimaun/Documents/code/biznez-runtime-dist`
**Branch:** New branch from current HEAD

---

## Files to Create / Modify

| # | File | Action | Change |
|---|------|--------|--------|
| 1 | `values.yaml` | Modify | Add `global.requireDigests: false` (1 line) |
| 2 | `templates/_helpers.tpl` | Modify | Insert digest-pinning guard in `biznez.imageRef` helper |
| 3 | `templates/validate.yaml` | Modify | Append 10 production profile guards + 1 PDB guard + 1 HPA metrics guard |
| 4 | `templates/backend/hpa.yaml` | Create | HorizontalPodAutoscaler (autoscaling/v2), backend-only |
| 5 | `templates/pdb.yaml` | Create | PodDisruptionBudget (policy/v1), backend-only |
| 6 | `values-production.yaml` | Overwrite | Complete minimal overlay replacing 4-line placeholder |
| 7 | `templates/NOTES.txt` | Modify | Add HPA/PDB status sections |

---

## Implementation Order

1. Add `global.requireDigests: false` to `values.yaml`
2. Modify `biznez.imageRef` in `_helpers.tpl` — add digest guard
3. Append production guards to `validate.yaml`
4. Create `templates/backend/hpa.yaml`
5. Create `templates/pdb.yaml`
6. Populate `values-production.yaml`
7. Update `NOTES.txt` with HPA/PDB status
8. Run verification checks

---

## Step 1: `values.yaml` — Add `global.requireDigests`

Add one field after `global.profile`:

```yaml
global:
  profile: eval
  # Require digest-pinned images for all components.
  # When true, fails if any image.digest is empty.
  requireDigests: false
```

This is the only change to `values.yaml`.

---

## Step 2: `_helpers.tpl` — Digest-Pinning Guard in `biznez.imageRef`

Insert after the `$digest` binding (line 88), before the registry branch logic:

```
{{- define "biznez.imageRef" -}}
{{- $registry := .root.Values.global.imageRegistry -}}
{{- $repository := .image.repository -}}
{{- $tag := .image.tag | default .root.Chart.AppVersion -}}
{{- $digest := .image.digest -}}
{{- if and .root.Values.global.requireDigests (empty $digest) -}}
  {{- fail (printf "Digest-pinned images required when global.requireDigests=true. Set image.digest for '%s' or set global.requireDigests=false." $repository) -}}
{{- end -}}
{{- if $registry -}}
  ... (rest unchanged)
```

**Why inside the helper:** The helper is the single point of image resolution. Every component image passes through it, so new images added in future phases are automatically covered. The error message includes the repository name for actionability.

**Postgres/waitForDb note:** When `postgres.enabled=false` but `backend.waitForDb.enabled=true` (default), the wait-for-db initContainer still uses `postgres.image` as fallback. The wait-for-db template already uses `postgres.external.host` for the `pg_isready` target when `postgres.enabled=false` (guard #4 enforces this is set). To avoid digest friction with the postgres image in production, `values-production.yaml` explicitly includes `backend.waitForDb.enabled: true` for clarity, and operators must either set `postgres.image.digest` or provide `backend.waitForDb.image` with a digest in their site-specific overlay.

---

## Step 3: `validate.yaml` — Production Profile Guards

Append after existing Phase 4 guards. All guards keyed off `$isProd := eq .Values.global.profile "production"`.

| Guard | Condition | Error Message |
|-------|-----------|---------------|
| 1 | prod AND `backend.existingSecret` empty | "Production requires backend.existingSecret. Create a K8s Secret with ENCRYPTION_KEY and JWT_SECRET_KEY." |
| 2a | prod AND `backend.secrets.encryptionKey` non-empty | "Production forbids inline secrets. Remove backend.secrets.encryptionKey, use backend.existingSecret." |
| 2b | prod AND `backend.secrets.jwtSecret` non-empty | "Production forbids inline secrets. Remove backend.secrets.jwtSecret, use backend.existingSecret." |
| 3 | prod AND `postgres.enabled: true` | "Production requires an external managed database. Set postgres.enabled=false." |
| 4 | prod AND `postgres.external.host` empty | "Production requires postgres.external.host for wait-for-db healthcheck." |
| 5 | prod AND `postgres.external.existingSecret` empty | "Production requires postgres.external.existingSecret with DATABASE_URL key." |
| 6 | prod AND `llm.provider` non-empty AND `!= "none"` AND `llm.existingSecret` empty | "Production requires llm.existingSecret when llm.provider is '<provider>'." |
| 7 | prod AND `llm.provider` non-empty AND `!= "none"` AND `llm.secrets.apiKey` non-empty | "Production forbids inline secrets. Remove llm.secrets.apiKey, use llm.existingSecret." |
| 8 | prod AND `auth.mode` in [oidc, dual] AND `auth.oidc.issuer` empty | "Production with auth.mode=<mode> requires auth.oidc.issuer." |
| 9 | prod AND `auth.mode` in [oidc, dual] AND `auth.oidc.audience` empty | "Production with auth.mode=<mode> requires auth.oidc.audience." |
| 10 | prod AND `gateway.enabled` AND `gateway.secrets` non-empty AND `gateway.existingSecret` empty | "Production forbids inline gateway.secrets. Use gateway.existingSecret." |
| 11 | ANY profile: `pdb.enabled` AND `autoscaling.enabled` AND `autoscaling.minReplicas < 2` | "pdb.enabled=true with autoscaling requires autoscaling.minReplicas >= 2 (got N)." |
| 11b | ANY profile: `pdb.enabled` AND NOT `autoscaling.enabled` AND `backend.replicas < 2` | "pdb.enabled=true requires backend.replicas >= 2 (got N). PDB with minAvailable=1 and 1 replica blocks all voluntary disruptions." |
| 12 | ANY profile: `autoscaling.enabled` AND no cpu target AND no memory target | "autoscaling.enabled requires at least one metric. Set autoscaling.metrics.cpu.targetAverageUtilization or autoscaling.metrics.memory.targetAverageUtilization." |

**Guards 11/11b (PDB)** are outside the `$isProd` block — they apply in any profile. When HPA is enabled, `backend.replicas` is the initial count but the HPA controls actual replica count, so the guard checks `autoscaling.minReplicas` instead. When HPA is disabled, it checks `backend.replicas`.

**Guard 12 (HPA metrics)** is outside the `$isProd` block — `autoscaling/v2` requires at least one metric entry. An HPA with empty `metrics:` would be rejected by the API server.

**Guard 6-7 (LLM)** uses `and (not (empty .Values.llm.provider)) (ne .Values.llm.provider "none")` to avoid false positives when the provider is empty string (which is falsy in Go templates but not equal to `"none"`).

**Guard ordering:** Guards 3-5 are ordered so `postgres.enabled=true` fires first (most actionable), then external host, then existingSecret.

---

## Step 4: `templates/backend/hpa.yaml` — Create

```yaml
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "biznez.fullname" . }}-backend
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "biznez.componentLabels" (dict "root" . "component" "backend") | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "biznez.fullname" . }}-backend
  minReplicas: {{ .Values.autoscaling.minReplicas | default 2 }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas | default 10 }}
  metrics:
    {{- if .Values.autoscaling.metrics.cpu.targetAverageUtilization }}
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.metrics.cpu.targetAverageUtilization }}
    {{- end }}
    {{- if .Values.autoscaling.metrics.memory.targetAverageUtilization }}
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.metrics.memory.targetAverageUtilization }}
    {{- end }}
{{- end }}
```

- Uses `autoscaling/v2` (stable since K8s 1.23)
- Backend-only (frontend is static nginx, gateway scales via replicas)
- Both metrics conditional — omitted if target utilization is 0/null

---

## Step 5: `templates/pdb.yaml` — Create

```yaml
{{- if .Values.pdb.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "biznez.fullname" . }}-backend
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "biznez.componentLabels" (dict "root" . "component" "backend") | nindent 4 }}
spec:
  minAvailable: {{ .Values.pdb.minAvailable | default 1 }}
  selector:
    matchLabels:
      {{- include "biznez.componentSelectorLabels" (dict "root" . "component" "backend") | nindent 6 }}
{{- end }}
```

- Uses `policy/v1` (stable since K8s 1.21)
- Selector reuses `biznez.componentSelectorLabels` — same labels as backend Deployment
- Guard 11 in validate.yaml catches `pdb.enabled=true` with `replicas < 2`

---

## Step 6: `values-production.yaml` — Complete Minimal Overlay

```yaml
# Biznez Agentic Runtime -- production overrides
# Usage: helm install ... -f values.yaml -f values-production.yaml
#
# REQUIRED -- set via --set or additional values file:
#   backend.existingSecret            K8s Secret with ENCRYPTION_KEY, JWT_SECRET_KEY
#   postgres.external.existingSecret  K8s Secret with DATABASE_URL
#   postgres.external.host            Managed database hostname
#   auth.oidc.issuer                  OIDC provider issuer URL
#   auth.oidc.audience                OAuth2 client ID
#   (If llm.provider != none) llm.existingSecret
#   (If gateway needs keys) gateway.existingSecret

global:
  profile: production
  requireDigests: true

postgres:
  enabled: false

auth:
  mode: oidc

migration:
  mode: manual

backend:
  secrets:
    encryptionKey: ""
    jwtSecret: ""
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 2Gi
  # Explicit for production clarity; operator sets postgres.external.host (guard #4)
  waitForDb:
    enabled: true

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  metrics:
    cpu:
      targetAverageUtilization: 70

pdb:
  enabled: true
  minAvailable: 1

networkPolicy:
  enabled: true
  egress:
    allowAllHttps: false

llm:
  secrets:
    apiKey: ""
```

**Minimal overlay principle:** Only fields that differ from `values.yaml` defaults. Operator-specific values (existingSecret names, OIDC coordinates, external DB host) are provided at deploy time via `--set`.

---

## Step 7: `NOTES.txt` Updates

Add to both eval and production blocks:

**HPA section** (when `autoscaling.enabled`):
```
Autoscaling:  HPA enabled ({{ minReplicas }}-{{ maxReplicas }} replicas)
```

**PDB section** (when `pdb.enabled`):
```
Disruption Budget:  PDB enabled (minAvailable: {{ minAvailable }})
```

---

## Verification (17 checks)

```bash
# Working directory: /Users/manimaun/Documents/code/biznez-runtime-dist

# --- Eval profile: no guards ---

# 1. Eval defaults render cleanly
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml 2>&1 | head -3
# Expected: no errors

# 2. Eval lint passes
helm lint helm/biznez-runtime/ -f tests/values/eval.yaml 2>&1
# Expected: 0 charts failed

# --- Production guards (all use --set global.requireDigests=false to bypass digest guard) ---

# 3. Guard 1: backend.existingSecret missing
helm template test helm/biznez-runtime/ \
  -f helm/biznez-runtime/values-production.yaml \
  --set global.requireDigests=false \
  --set postgres.external.host=db.example.com 2>&1 | grep -c "backend.existingSecret"
# Expected: 1

# 4. Guard 3: postgres.enabled=true in production
helm template test helm/biznez-runtime/ \
  -f helm/biznez-runtime/values-production.yaml \
  --set global.requireDigests=false \
  --set postgres.enabled=true 2>&1 | grep -c "external managed database"
# Expected: 1

# 5. Guard 5: postgres.external.existingSecret missing
helm template test helm/biznez-runtime/ \
  -f helm/biznez-runtime/values-production.yaml \
  --set global.requireDigests=false \
  --set backend.existingSecret=s \
  --set postgres.external.host=db 2>&1 | grep -c "postgres.external.existingSecret"
# Expected: 1

# 6. Guard 8: OIDC issuer missing
helm template test helm/biznez-runtime/ \
  -f helm/biznez-runtime/values-production.yaml \
  --set global.requireDigests=false \
  --set backend.existingSecret=s \
  --set postgres.external.host=db \
  --set postgres.external.existingSecret=s 2>&1 | grep -c "auth.oidc.issuer"
# Expected: 1

# 7. Guard 2a: inline encryptionKey rejected
helm template test helm/biznez-runtime/ \
  -f helm/biznez-runtime/values-production.yaml \
  --set global.requireDigests=false \
  --set backend.existingSecret=s \
  --set backend.secrets.encryptionKey=LEAK \
  --set postgres.external.host=db \
  --set postgres.external.existingSecret=s \
  --set auth.oidc.issuer=https://idp \
  --set auth.oidc.audience=cid 2>&1 | grep -c "inline secrets"
# Expected: 1

# 8. Guard 10: gateway inline secrets rejected
helm template test helm/biznez-runtime/ \
  -f helm/biznez-runtime/values-production.yaml \
  --set global.requireDigests=false \
  --set backend.existingSecret=s \
  --set postgres.external.host=db \
  --set postgres.external.existingSecret=s \
  --set auth.oidc.issuer=https://idp \
  --set auth.oidc.audience=cid \
  --set-json 'gateway.secrets={"KEY":"val"}' 2>&1 | grep -c "inline gateway.secrets"
# Expected: 1

# --- Digest pinning ---

# 9. Digest guard fires (requireDigests=true, no digests set)
helm template test helm/biznez-runtime/ \
  -f helm/biznez-runtime/values-production.yaml \
  --set backend.existingSecret=s \
  --set postgres.external.host=db \
  --set postgres.external.existingSecret=s \
  --set auth.oidc.issuer=https://idp \
  --set auth.oidc.audience=cid 2>&1 | grep -c "requireDigests=true"
# Expected: 1

# 10. Digest opt-out works
helm template test helm/biznez-runtime/ \
  -f helm/biznez-runtime/values-production.yaml \
  --set global.requireDigests=false \
  --set backend.existingSecret=s \
  --set postgres.external.host=db \
  --set postgres.external.existingSecret=s \
  --set auth.oidc.issuer=https://idp \
  --set auth.oidc.audience=cid 2>&1 | head -3
# Expected: renders successfully

# --- HPA ---

# 11. HPA renders when autoscaling enabled
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set autoscaling.enabled=true \
  --show-only templates/backend/hpa.yaml 2>&1 | grep -c "kind: HorizontalPodAutoscaler"
# Expected: 1

# 12. HPA not rendered when disabled (default)
count=$(helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/backend/hpa.yaml 2>&1 | grep -c "kind: HorizontalPodAutoscaler" || true)
echo "$count"
# Expected: 0

# 13. HPA guard: autoscaling enabled but no metrics fails
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set autoscaling.enabled=true \
  --set autoscaling.metrics.cpu.targetAverageUtilization=0 \
  --set autoscaling.metrics.memory.targetAverageUtilization=0 2>&1 | grep -c "at least one metric"
# Expected: 1

# --- PDB ---

# 14. PDB renders when enabled + replicas >= 2 (no HPA)
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set pdb.enabled=true --set backend.replicas=2 \
  --show-only templates/pdb.yaml 2>&1 | grep -c "kind: PodDisruptionBudget"
# Expected: 1

# 15. PDB guard: enabled + replicas < 2 (no HPA) fails
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set pdb.enabled=true --set backend.replicas=1 2>&1 | grep -c "backend.replicas >= 2"
# Expected: 1

# 16. PDB with HPA: minReplicas >= 2 succeeds
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set pdb.enabled=true --set autoscaling.enabled=true --set autoscaling.minReplicas=2 \
  --show-only templates/pdb.yaml 2>&1 | grep -c "kind: PodDisruptionBudget"
# Expected: 1

# --- Full production render ---

# 17. Full production with all required values succeeds
helm template test helm/biznez-runtime/ \
  -f helm/biznez-runtime/values-production.yaml \
  --set global.requireDigests=false \
  --set backend.existingSecret=my-secret \
  --set postgres.external.host=db.example.com \
  --set postgres.external.existingSecret=db-secret \
  --set auth.oidc.issuer=https://idp.example.com \
  --set auth.oidc.audience=client-id 2>&1 | grep "kind:" | sort -u
# Expected: ConfigMap, Deployment, HorizontalPodAutoscaler, NetworkPolicy,
#           PodDisruptionBudget, Service, ServiceAccount
# (No StatefulSet — postgres disabled; No Job — migration mode manual)
# Note: Secret may or may not be present depending on whether non-sensitive
# chart-managed secrets are rendered. Its absence is not a failure.
```

---

## Exit Criteria

- [ ] Eval profile renders with zero guards (works out of the box)
- [ ] `helm template -f values-production.yaml` fails when `backend.existingSecret` not set
- [ ] All 10 production guards produce actionable error messages
- [ ] Inline secrets rejected in production (encryptionKey, jwtSecret, apiKey, gateway.secrets)
- [ ] `postgres.enabled=true` fails in production
- [ ] OIDC issuer/audience required when `auth.mode` is oidc or dual
- [ ] LLM guard uses safe condition: non-empty provider AND != "none"
- [ ] Digest pinning enforced: fails when `requireDigests=true` and any image.digest empty
- [ ] Digest guard message references `global.requireDigests=true` (not "production")
- [ ] Digest opt-out works: `requireDigests=false` bypasses digest check
- [ ] HPA rendered when `autoscaling.enabled=true`, not rendered when false
- [ ] HPA guard fires when `autoscaling.enabled=true` with no metrics configured
- [ ] PDB rendered when `pdb.enabled=true`
- [ ] PDB guard with HPA: checks `autoscaling.minReplicas >= 2`
- [ ] PDB guard without HPA: checks `backend.replicas >= 2`
- [ ] `values-production.yaml` is minimal overlay with cpu metric default and waitForDb explicit
- [ ] Full production render succeeds with all required values (HPA + PDB + NetworkPolicy present, no StatefulSet, no migration Job)
- [ ] All 17 verification checks pass
- [ ] Helm lint passes with all value file combinations
