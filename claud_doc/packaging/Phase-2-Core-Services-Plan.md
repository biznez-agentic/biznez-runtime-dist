# Plan: Phase 2 -- Core Services + NOTES.txt (v4 -- pre-implementation final)

## Context

Phase 0 (repo scaffold) and Phase 1 (Chart.yaml, values.yaml, _helpers.tpl) are complete. The Helm chart lints and templates successfully but produces no real resources -- only placeholders. Phase 2 creates all the core service templates so that `helm install` produces a working deployment with running pods.

**Repo:** `/Users/manimaun/Documents/code/biznez-runtime-dist`
**Branch:** `Feature/27-Feb-Phase-2-Package` (new, from current HEAD on `main`)

---

## Changes from v3 (third review feedback)

| # | Issue | Fix |
|---|-------|-----|
| F1 | db-credentials-secret generates even when external DB has no usable URL | Added fail-fast guard: if `postgres.enabled=false` and no existingSecret, require `postgres.external.databaseUrl` |
| F2 | "construct from external fields" implies separate user/password fields for external | Simplified: external DB uses only `databaseUrl` (full URL) or `existingSecret`. No separate user/password fields for external in Phase 2 |
| F3 | Test Fernet key example was not a real Fernet key | Using real generated Fernet key: `_sSYK6S9JmnQcoWUZQc4Zg8rBZ52RvGyP8RRlqLhol0=` |
| F4 | NOTES.txt log grep for "admin" is fragile | Changed to generic "check backend logs for first-run instructions" with broader grep |
| F5 | No verification that backend deployment references correct secret name when existingSecret is set | Added verification check #19 |

---

## Changes from v2 (second review)

| # | Issue | Fix |
|---|-------|-----|
| R1 | db-credentials-secret conditional conflicts with helper logic | Fixed: only render when no existing secret provides DATABASE_URL |
| R2 | Three possible sources for DATABASE_URL causes support confusion | Simplified: two sources only |
| R3 | wait-for-db might parse DATABASE_URL in shell | Fixed: always uses explicit host/port fields |
| R4 | encryptionKey required check might block existingSecret users | Fixed: guard scoped correctly |
| R5 | Frontend env-config.js prerequisite not in exit criteria | Added explicit acceptance check |
| R6 | eval test values may hit randAlphaNum nondeterminism | Fixed: all secrets set deterministically |
| R7 | NOTES.txt "admin credentials" references non-existent secret | Fixed: accurate auth info |

---

## Changes from v1 (first review)

| # | Issue | Fix |
|---|-------|-----|
| C1 | DATABASE_URL not in any secret | Create db-credentials secret |
| C2 | POSTGRES_USER/PASSWORD leaked into backend env | Remove; keep only in postgres container |
| C3 | wait-for-db skipped for external DB | Add `backend.waitForDb.enabled` flag |
| C4 | RBAC permissions too broad | ServiceAccount only in Phase 2 |
| C5 | randAlphaNum invalid for Fernet keys | Require encryptionKey; `{{ fail }}` if empty |
| C6 | Frontend VITE_API_URL env var does nothing in nginx | ConfigMap renders `env-config.js` with `window.__ENV__` |

---

## _helpers.tpl Modifications Required

### Fix: `biznez.backend.envVars` helper

**Remove:** POSTGRES_USER, POSTGRES_PASSWORD

**Change:** DATABASE_URL from `value:` to `valueFrom.secretKeyRef` using `biznez.dbCredentialsSecretName`

**Keep as-is:** ENCRYPTION_KEY, JWT_SECRET_KEY, LLM_API_KEY, LANGFUSE keys, AGENT_GATEWAY_URL, FRONTEND_URL, API_BASE_URL, CORS_ORIGINS

### Fix: `biznez.databaseUrl` helper

Constructs full URL with actual credential values (no K8s env var expansion):

- **Eval (postgres.enabled=true):** `postgresql://<user>:<password>@<fullname>-postgres:5432/<database>?sslmode=disable`
  - user from `postgres.secrets.user`, password from `postgres.secrets.password`
- **External (postgres.enabled=false):** `postgres.external.databaseUrl` (required, full URL with creds embedded)
  - `{{ required }}` guard: fails if `postgres.external.databaseUrl` is empty when no existingSecret is provided

**No separate user/password fields for external DB in Phase 2.** External DB access is either:
- Full URL via `postgres.external.databaseUrl` (eval/non-production external)
- Pre-created secret via `postgres.external.existingSecret` (production)

Phase 5 production guards will prohibit `databaseUrl` in values (force existingSecret).

### New helper: `biznez.dbCredentialsSecretName`

- If `postgres.external.existingSecret` is set: return it
- Else: return `{{ fullname }}-db-credentials`

`backend.existingSecret` is NOT a source for DATABASE_URL. Clear ownership boundary.

### New values.yaml additions

```yaml
backend:
  waitForDb:
    enabled: true   # Set false if init container is undesirable
    image: {}       # Defaults to postgres.image; override for external DB scenarios
```

---

## DATABASE_URL Secret Strategy (final)

### Two sources only:

| Mode | Secret Name | Who Creates It | Contains |
|------|-------------|----------------|----------|
| **Chart-generated** | `{{ fullname }}-db-credentials` | Helm chart | DATABASE_URL (constructed from embedded postgres creds OR from `postgres.external.databaseUrl`) |
| **Operator-provided** | `postgres.external.existingSecret` | Operator pre-creates | Must contain key `DATABASE_URL` |

### db-credentials-secret.yaml conditional logic:

```
{{- if not .Values.postgres.external.existingSecret }}
  {{- if .Values.postgres.enabled }}
    # Eval: construct from embedded postgres credentials
    DATABASE_URL: postgresql://{{ user }}:{{ password }}@{{ fullname }}-postgres:5432/{{ database }}?sslmode=disable
  {{- else }}
    # External without existingSecret: require databaseUrl
    DATABASE_URL: {{ required "postgres.external.databaseUrl is required when postgres.enabled=false and postgres.external.existingSecret is not set" .Values.postgres.external.databaseUrl }}
  {{- end }}
{{- end }}
```

This ensures:
- Chart-generated secret always has a valid DATABASE_URL
- `postgres.enabled=false` without existingSecret fails fast if no databaseUrl provided
- No empty or invalid DATABASE_URL ever written to a secret

### `biznez.dbCredentialsSecretName` helper matches exactly:

- When `postgres.external.existingSecret` is set: returns that name (template not rendered)
- When not set: returns `{{ fullname }}-db-credentials` (template is rendered)
- Backend deployment always references whichever name the helper returns

No mismatch possible between template condition and helper output.

---

## wait-for-db Strategy (final)

**Rule: always uses explicit host/port fields, never parses DATABASE_URL.**

| Scenario | Host | Port |
|----------|------|------|
| `postgres.enabled=true` | `{{ fullname }}-postgres` (service DNS) | 5432 |
| `postgres.enabled=false` | `postgres.external.host` (required field) | `postgres.external.port` (default 5432) |

Init container: `pg_isready -h <host> -p <port>` with 12 retries, 5s delay.

Controlled by `backend.waitForDb.enabled` (default: true).

---

## Files to Create (14 total)

### Batch 1 -- Foundation

| # | File | Purpose |
|---|------|---------|
| 1 | `templates/rbac.yaml` | ServiceAccount only |
| 2 | `templates/backend/configmap.yaml` | Non-secret backend config |
| 3 | `templates/backend/secret.yaml` | ENCRYPTION_KEY + JWT_SECRET_KEY (conditional) |
| 4 | `templates/postgres/secret.yaml` | POSTGRES_USER + POSTGRES_PASSWORD (conditional; postgres container only) |
| 5 | `templates/backend/db-credentials-secret.yaml` | DATABASE_URL (conditional; fail-fast if misconfigured) |

### Batch 2 -- Services and StatefulSet

| # | File | Purpose |
|---|------|---------|
| 6 | `templates/postgres/service.yaml` | Headless ClusterIP for StatefulSet DNS |
| 7 | `templates/postgres/statefulset.yaml` | PostgreSQL with volumeClaimTemplate |
| 8 | `templates/backend/service.yaml` | Backend ClusterIP |
| 9 | `templates/frontend/configmap.yaml` | Frontend runtime config (env-config.js with window.__ENV__) |
| 10 | `templates/frontend/service.yaml` | Frontend ClusterIP |

### Batch 3 -- Deployments

| # | File | Purpose |
|---|------|---------|
| 11 | `templates/backend/deployment.yaml` | Backend Deployment with wait-for-db, env helpers |
| 12 | `templates/frontend/deployment.yaml` | Frontend Deployment -- ZERO secrets, ConfigMap volume mount |

### Batch 4 -- Output and Tests

| # | File | Purpose |
|---|------|---------|
| 13 | `templates/NOTES.txt` | Profile-aware post-install instructions |
| 14 | `tests/values/eval.yaml` | Deterministic test values with real Fernet key |

---

## Key Design Decisions (final)

### 1. DATABASE_URL: two sources, fail-fast guards (F1, F2)
See "DATABASE_URL Secret Strategy" section above. External DB without existingSecret requires `postgres.external.databaseUrl` (full URL). No separate user/password fields for external in Phase 2.

### 2. Backend does NOT get POSTGRES_USER/PASSWORD
Backend gets DATABASE_URL only.

### 3. wait-for-db: explicit host/port, never parse DATABASE_URL
See "wait-for-db Strategy" section above.

### 4. RBAC: ServiceAccount only
No Role, no RoleBinding in Phase 2.

### 5. Fernet key: required, not auto-generated
Guard only fires when `backend.existingSecret` is empty AND `backend.secrets.encryptionKey` is empty. JWT secret: `randAlphaNum 64` fallback is fine.

### 6. Frontend: window.__ENV__ via ConfigMap volume mount
ConfigMap renders `env-config.js`. Mounted into `/usr/share/nginx/html/env-config.js`.

**Runtime repo prerequisite:** Frontend `index.html` must include `<script src="/env-config.js"></script>`. Documented as exit criteria. Follow-up task filed for runtime repo if missing.

### 7. Container ports hardcoded
Backend: 8000, Frontend: 80.

### 8. Checksum annotations
Backend: `checksum/config` (always), `checksum/secret` (when `!backend.existingSecret`), `checksum/db-credentials` (when `!postgres.external.existingSecret`). Frontend: `checksum/config` (always).

### 9. Frontend: ZERO secret injection
No secretKeyRef, no secret envFrom, no env vars. Only ConfigMap volume mount.

### 10. NOTES.txt: accurate auth info (F4)
- **Eval:** "Auth mode: local. Check backend logs for first-run setup instructions: `kubectl logs deployment/{{ fullname }}-backend -n {{ ns }} | grep -iE 'admin|password|created'`"
- **Production:** "Auth mode: oidc. Configure your OIDC provider per docs/OIDC-SETUP.md."
- No reference to non-existent admin password secret.

### 11. Deterministic test values with real Fernet key (F3)
`tests/values/eval.yaml`:
- `backend.secrets.encryptionKey`: `_sSYK6S9JmnQcoWUZQc4Zg8rBZ52RvGyP8RRlqLhol0=` (real Fernet key, generated once, committed)
- `backend.secrets.jwtSecret`: `test-jwt-secret-for-eval-only-not-for-production`
- `postgres.secrets.password`: `test-postgres-password`

All secrets deterministic. No randAlphaNum paths in test rendering.

---

## Template Specifications (final)

### 1. `templates/rbac.yaml`
- Conditional: `{{- if .Values.rbac.create }}`
- ServiceAccount only with imagePullSecrets

### 2. `templates/backend/configmap.yaml`
- Name: `{{ fullname }}-backend`
- Keys: ENVIRONMENT, LOG_LEVEL, JWT_ALGORITHM, JWT_ACCESS_TOKEN_EXPIRE_MINUTES, JWT_REFRESH_TOKEN_EXPIRE_DAYS, BCRYPT_ROUNDS, RUNTIME_NAME, MAX_CONCURRENT_AGENTS, AGENT_TIMEOUT_SECONDS, PROMETHEUS_ENABLED, PROMETHEUS_PORT, AUTH_TYPE, AUTH_ENABLED, LLM_PROVIDER, LANGFUSE_ENABLED/HOST/UI_URL (conditional), DB_POOL_SIZE/MAX_OVERFLOW/POOL_RECYCLE

### 3. `templates/backend/secret.yaml`
- Conditional: `{{- if not .Values.backend.existingSecret }}`
- ENCRYPTION_KEY: `{{ required "..." }}` -- fails if empty
- JWT_SECRET_KEY: `{{ default (randAlphaNum 64) }}`

### 4. `templates/postgres/secret.yaml`
- Conditional: `{{- if and .Values.postgres.enabled (not .Values.postgres.existingSecret) }}`
- POSTGRES_USER, POSTGRES_PASSWORD -- used only by postgres StatefulSet

### 5. `templates/backend/db-credentials-secret.yaml`
- Conditional: `{{- if not .Values.postgres.external.existingSecret }}`
- When `postgres.enabled=true`: constructs URL from embedded postgres credentials
- When `postgres.enabled=false`: `{{ required }}` guard on `postgres.external.databaseUrl`
- Fail-fast: never generates empty/invalid DATABASE_URL

### 6. `templates/postgres/service.yaml`
- Conditional: `{{- if .Values.postgres.enabled }}`, headless, port 5432

### 7. `templates/postgres/statefulset.yaml`
- Conditional: `{{- if .Values.postgres.enabled }}`, replicas 1, pg_isready probes, volumeClaimTemplate

### 8. `templates/backend/service.yaml`
- Always created, ClusterIP, port 8000, supports annotations

### 9. `templates/frontend/configmap.yaml`
- `env-config.js` key with `window.__ENV__ = { API_BASE_URL: "..." }`

### 10. `templates/frontend/service.yaml`
- Always created, ClusterIP, port 80

### 11. `templates/backend/deployment.yaml`
- Init container (wait-for-db): conditional on `backend.waitForDb.enabled`, explicit host/port
- Main container: envFrom ConfigMap, env via updated helper (DATABASE_URL secretKeyRef, ENCRYPTION_KEY, JWT_SECRET_KEY, LLM_API_KEY, LANGFUSE, AGENT_GATEWAY_URL, FRONTEND_URL, API_BASE_URL, CORS_ORIGINS), probes, volumes

### 12. `templates/frontend/deployment.yaml`
- ZERO secrets, ZERO env vars, ConfigMap volume mount for env-config.js (subPath), nginx writable dirs

### 13. `templates/NOTES.txt`
- Eval: port-forward, auth mode local, log grep hint, postgres warning, gateway URL
- Production: health check, auth mode oidc, public URLs, migration/backup reminders

### 14. `tests/values/eval.yaml`
- Real Fernet key, deterministic JWT secret, deterministic postgres password

---

## Helpers Summary

| Helper | Phase 2 Change |
|--------|----------------|
| `biznez.backend.envVars` | **UPDATED:** remove POSTGRES_USER/PASSWORD, DATABASE_URL via secretKeyRef |
| `biznez.databaseUrl` | **UPDATED:** full URL with embedded creds; `{{ required }}` for external without existingSecret |
| **NEW: `biznez.dbCredentialsSecretName`** | `postgres.external.existingSecret` or `{{ fullname }}-db-credentials` |
| All others | No change |

---

## Verification (final)

```bash
# 1. Helm lint
helm lint helm/biznez-runtime/

# 2. Template render with deterministic test values
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml

# 3. Verify only namespaced resource kinds
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml | grep "^kind:" | sort -u
# Expected: ConfigMap, Deployment, Secret, Service, ServiceAccount, StatefulSet

# 4. Verify NO Ingress or NetworkPolicy rendered
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml | grep -c "kind: Ingress\|kind: NetworkPolicy"
# Expected: 0

# 5. Verify postgres disabled skips all postgres resources
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set postgres.enabled=false --set postgres.external.host=db.example.com \
  --set postgres.external.existingSecret=my-db-secret \
  | grep -c "component: postgres"
# Expected: 0

# 6. Verify existingSecret for DB skips chart-generated db-credentials
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set postgres.external.existingSecret=my-db-secret \
  | grep -c "db-credentials"
# Expected: 0

# 7. Verify external DB without existingSecret or databaseUrl fails fast
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set postgres.enabled=false --set postgres.external.host=db.example.com 2>&1 \
  | grep -i "databaseUrl"
# Expected: error message requiring postgres.external.databaseUrl

# 8. Verify RBAC disabled skips ServiceAccount
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set rbac.create=false | grep -c "kind: ServiceAccount"
# Expected: 0

# 9. Verify existingSecret skips chart-generated backend secret
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set backend.existingSecret=my-secret | grep -c "ENCRYPTION_KEY"
# Expected: 0

# 10. Verify frontend has ZERO secret references
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/frontend/deployment.yaml | grep -c "secretKeyRef"
# Expected: 0

# 11. Verify frontend ConfigMap has env-config.js
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/frontend/configmap.yaml | grep "env-config.js"
# Expected: match

# 12. Verify frontend deployment mounts env-config.js
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/frontend/deployment.yaml | grep "env-config.js"
# Expected: match (subPath mount)

# 13. Verify DATABASE_URL comes from secretKeyRef (not inline value)
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/backend/deployment.yaml | grep -A3 "DATABASE_URL"
# Expected: secretKeyRef pointing to db-credentials secret

# 14. Verify POSTGRES_USER/PASSWORD NOT in backend deployment
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/backend/deployment.yaml | grep -c "POSTGRES_USER\|POSTGRES_PASSWORD"
# Expected: 0

# 15. Verify db-credentials secret contains valid DATABASE_URL
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/backend/db-credentials-secret.yaml | grep "DATABASE_URL"
# Expected: postgresql://biznez:test-postgres-password@test-biznez-runtime-postgres:5432/biznez_platform

# 16. Verify encryptionKey required (should fail with no values)
helm template test helm/biznez-runtime/ 2>&1 | grep -i "encryptionKey"
# Expected: error message

# 17. Verify NOTES.txt renders correctly
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/NOTES.txt

# 18. Verify wait-for-db uses explicit host (not DATABASE_URL parsing)
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/backend/deployment.yaml | grep "pg_isready"
# Expected: -h test-biznez-runtime-postgres -p 5432

# 19. Verify backend references correct db secret name when existingSecret is set
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set postgres.external.existingSecret=my-db-secret \
  --show-only templates/backend/deployment.yaml | grep -A5 "DATABASE_URL"
# Expected: secretKeyRef name: my-db-secret (NOT fullname-db-credentials)
```

---

## Exit Criteria (Phase 2 acceptance)

- [ ] `helm lint` passes
- [ ] `helm template` with eval values renders all expected resources
- [ ] Only namespaced resource kinds (no ClusterRole, Ingress, NetworkPolicy)
- [ ] Backend env: DATABASE_URL via secretKeyRef, no POSTGRES_USER/PASSWORD
- [ ] Backend secret: encryptionKey required (fails if empty and no existingSecret)
- [ ] DB credentials secret: skipped when `postgres.external.existingSecret` is set
- [ ] DB credentials secret: fails fast when `postgres.enabled=false` and no existingSecret and no databaseUrl
- [ ] Backend deployment references correct secret name in all scenarios (chart-generated AND existingSecret)
- [ ] Postgres templates: skipped when `postgres.enabled=false`
- [ ] Frontend: zero secret injection, env-config.js mounted via volume
- [ ] Frontend: `curl http://localhost:8080/env-config.js` returns expected API_BASE_URL (smoke test after install)
- [ ] wait-for-db: uses explicit host/port, not DATABASE_URL parsing
- [ ] NOTES.txt: accurate auth info, broader log grep hint
- [ ] All test values deterministic with real Fernet key (no randAlphaNum in test rendering)
- [ ] **Runtime repo prerequisite documented:** frontend `index.html` must include `<script src="/env-config.js"></script>`

---

## Git Workflow

1. Create branch `Feature/27-Feb-Phase-2-Package` from current HEAD on `main`
2. Update `_helpers.tpl` (fix envVars, databaseUrl helpers; add dbCredentialsSecretName)
3. Update `values.yaml` (add backend.waitForDb section)
4. Create all 14 template files
5. Run all 19 verification checks
6. Commit all changes
7. Push and create PR to `main`
