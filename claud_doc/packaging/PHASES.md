# Biznez Agentic Runtime: Phased Implementation Plan

This document breaks the [Packaging Plan](./PACKAGING-PLAN.md) into logical phases for iterative delivery. Each phase builds on the previous one and produces a testable, demonstrable result.

**Repository:** This document lives in `biznez-runtime-dist` (the distribution repo).
All file paths below are relative to the dist repo root unless prefixed with `[runtime]`.

---

## Phase Overview

| Phase | Name | Deliverables | Exit Criteria |
|-------|------|-------------|---------------|
| 0 | Repo Setup & Config Contract | Dist repo scaffold, Makefile, dev harness, config-contract placeholder | Dist repo structure matches plan, `make lint` fails gracefully |
| 1 | Chart Foundation | Chart.yaml, values.yaml, _helpers.tpl | `helm lint` + `helm template` pass with defaults |
| 2 | Core Services + NOTES.txt | Backend, Frontend, PostgreSQL, RBAC, NOTES.txt | `helm install` on local K8s, pods running |
| 2.5 | Contract Tests & CI Gates | conftest policies, kubeconform, smoke test script | CI gates catch packaging principle violations |
| 3 | Gateway & Migrations | Agent Gateway, migration job (3 modes) | Full stack running, all 3 migration modes work |
| 4 | Networking | Ingress, Gateway API, NetworkPolicy | SSE streaming verified through nginx ingress |
| 5 | Production Hardening | values-production.yaml, template guards, HPA, PDB | Production guards enforce all required fields + digests |
| 6 | Docker Compose | docker-compose.yml, .env.template, setup.sh | `docker compose up` starts full stack |
| 7 | Operator CLI | biznez-cli (runtime ops: validate/install/migrate/health) | Operator CLI workflow works end-to-end |
| 8 | Release Pipeline & Tooling | images.lock, SBOM, signing, scanning, CLI release commands | `build-release` produces all release artifacts |
| 9 | Documentation | INSTALL, PRODUCTION-CHECKLIST, SECURITY, etc. | Documentation complete for client handoff |

---

## Phase 0: Repo Setup & Config Contract

**Goal:** Establish the two-repo architecture. Create the dist repo scaffold with directory structure, Makefile, dev harness, OPA policies, and version mapping. Create the config contract placeholder in the runtime repo. This phase is a prerequisite for all subsequent phases.

### What was done

- Created `biznez-runtime-dist` repo with full directory scaffold
- Created substantive files: README.md, .gitignore, Makefile, versions.yaml
- Created dev harness scripts: `dev/kind-install.sh`, `dev/load-local-images.sh`
- Created OPA policy: `policies/no-gcp-in-dist.rego`
- Moved packaging docs from runtime `docs/package/` to dist `docs/`
- Replaced runtime packaging docs with pointers to dist repo
- Created `[runtime] config-contract.yaml` placeholder at runtime repo root
- Updated this document (PHASES.md) with Phase 0 and corrected file paths

### Cross-Repo Architecture

```
biznez-agentic-runtime (app code)          biznez-runtime-dist (packaging)
├── src/                                    ├── helm/biznez-runtime/
├── frontend/                               ├── compose/
├── Dockerfile                              ├── cli/
├── k8s/ (internal GKE manifests)           ├── docs/
├── config-contract.yaml  ──────────────►   ├── contracts/config-contract.yaml
│   (source of truth)         (pinned copy) ├── versions.yaml
└── CI builds images ──────────────────►    └── images.lock (pinned digests)
```

### Exit Criteria

- [x] Dist repo structure matches the agreed layout
- [x] `make lint` fails gracefully (placeholder Chart.yaml)
- [x] Dev harness scripts reference `RUNTIME_DIR` (overrideable, default `../biznez-agentic-runtime`)
- [x] No GCP-specific strings in any dist repo file
- [x] Runtime repo packaging docs replaced with pointer
- [x] `config-contract.yaml` exists as placeholder in runtime repo
- [x] `versions.yaml` exists with dev version in dist repo
- [x] PHASES.md updated with Phase 0 and corrected paths

---

## Phase 1: Chart Foundation

**Goal:** Create the Helm chart skeleton with all global configuration, template helpers, and the complete `values.yaml` schema. Everything after this phase builds on these foundations.

### Files to Create

| File | Purpose |
|------|---------|
| `helm/biznez-runtime/Chart.yaml` | Chart metadata (name, version, appVersion, description) |
| `helm/biznez-runtime/values.yaml` | Complete values schema with eval defaults |
| `helm/biznez-runtime/templates/_helpers.tpl` | All template helpers |

### What goes into `_helpers.tpl`

- `biznez.fullname` / `biznez.name` / `biznez.chart` -- standard name helpers
- `biznez.labels` / `biznez.selectorLabels` -- consistent labels
- `biznez.imageRef` -- constructs image reference from `global.imageRegistry` + component `image.repository` + `tag` / `digest`
- `biznez.backendSecretName` / `biznez.postgresSecretName` -- conditional secret name resolution (existingSecret or chart-generated)
- `biznez.backend.envFrom` / `biznez.backend.envVars` -- shared env injection block (used by both backend Deployment and migration Job)
- `biznez.databaseUrl` -- DATABASE_URL construction (from components or full override via `postgres.external.databaseUrl`)
- `biznez.publicUrl.frontend` / `biznez.publicUrl.api` -- URL derivation (explicit > ingress-derived > eval defaults)
- `biznez.podSecurityContext` / `biznez.containerSecurityContext` -- security context with global defaults
- `biznez.tmpVolume` / `biznez.tmpVolumeMount` -- standard `/tmp` emptyDir pattern

### What goes into `values.yaml`

The complete schema covering all sections from the plan:
- `global` (profile, imageRegistry, imagePullSecrets, storageClass, security contexts)
- `backend` (image, replicas, resources, config, secrets, existingSecret, probes, streaming)
- `frontend` (image, replicas, resources, probes, extra volumes for nginx)
- `postgres` (enabled, image, storage, storageClassName, external, pool, pgbouncer, secrets)
- `gateway` (enabled, image, replicas, resources, timeouts, secrets, config, probes)
- `auth` (mode, oidc, local)
- `llm` (provider, existingSecret, secrets)
- `langfuse` (enabled, host, existingSecret, secrets)
- `migration` (mode, jobTtlSeconds)
- `ingress` (enabled, className, mode, hosts, tls, applyNginxStreamingAnnotations)
- `gatewayApi` (enabled, gatewayRef, httpRoutes)
- `networkPolicy` (enabled, ingress, egress with all options)
- `rbac` (create, serviceAccountName, migrationOperator)
- `autoscaling` (enabled, minReplicas, maxReplicas, metrics)
- `pdb` (enabled, minAvailable)

### Reference Files to Read (in runtime repo)

| File | What to extract |
|------|----------------|
| `[runtime] k8s/base/platform-configmap.yaml` | All config keys and defaults |
| `[runtime] .env.example` | Complete environment variable list |
| `[runtime] src/agentic_runtime/core/config.py` | RuntimeConfig class -- actual env var names the app reads |

### Exit Criteria

- [ ] `helm lint helm/biznez-runtime/` passes
- [ ] `helm template test helm/biznez-runtime/` renders with default values (lint can pass while templates fail due to missing required functions/values usage -- template render is the real test)
- [ ] `values.yaml` contains all sections from the packaging plan
- [ ] `_helpers.tpl` compiles without errors
- [ ] Chart.yaml has correct metadata (apiVersion: v2, type: application)

---

## Phase 2: Core Services + NOTES.txt

**Goal:** Backend, Frontend, PostgreSQL templates, and NOTES.txt. After this phase, `helm install` on a local Kubernetes cluster (Docker Desktop, minikube, kind) produces running pods with the eval profile and post-install instructions.

### Files to Create

| File | Purpose |
|------|---------|
| `helm/biznez-runtime/templates/backend/deployment.yaml` | Backend API deployment |
| `helm/biznez-runtime/templates/backend/service.yaml` | Backend ClusterIP service |
| `helm/biznez-runtime/templates/backend/configmap.yaml` | Non-secret backend config |
| `helm/biznez-runtime/templates/backend/secret.yaml` | Backend secrets (conditional: skipped if existingSecret) |
| `helm/biznez-runtime/templates/frontend/deployment.yaml` | Frontend (nginx) deployment |
| `helm/biznez-runtime/templates/frontend/service.yaml` | Frontend ClusterIP service |
| `helm/biznez-runtime/templates/frontend/configmap.yaml` | Nginx configuration |
| `helm/biznez-runtime/templates/postgres/statefulset.yaml` | PostgreSQL StatefulSet (conditional) |
| `helm/biznez-runtime/templates/postgres/service.yaml` | PostgreSQL ClusterIP service (conditional) |
| `helm/biznez-runtime/templates/postgres/secret.yaml` | PostgreSQL credentials (conditional) |
| `helm/biznez-runtime/templates/postgres/pvc.yaml` | Persistent volume claim (conditional) |
| `helm/biznez-runtime/templates/rbac.yaml` | ServiceAccount, Role, RoleBinding (conditional) |
| `helm/biznez-runtime/templates/NOTES.txt` | Post-install instructions (profile-aware) |

### Why NOTES.txt is in Phase 2 (not Phase 8)

NOTES.txt becomes part of the iterative demo and support loop immediately. It surfaces:
- Port-forward commands (the primary eval access method)
- Default credentials (eval profile)
- Public URL derivation behavior (explicit > ingress-derived > eval defaults)
- Health-check commands

Waiting until Phase 8 means every `helm install` during development produces no user-facing output. NOTES.txt is the first thing an operator sees after install -- it must exist from the first working deploy.

**NOTES.txt content (Phase 2 scope):**
- Profile-aware output (different content for eval vs production)
- Eval: port-forward commands, default credentials, access URLs
- Production: health-check command, migration reminder
- Prints public URLs in use and warns if they are defaults in production

### Implementation Details

**Backend deployment must include:**
- Pod security context (from global helpers)
- Container security context (readOnlyRootFilesystem, non-root, dropped capabilities)
- Writable emptyDir mounts: `/tmp`, `/app/logs`
- ConfigMap env vars via `envFrom` configMapRef
- Secret env vars via explicit `secretKeyRef` per key (ENCRYPTION_KEY, JWT_SECRET_KEY)
- LLM and Langfuse secret injection (conditional)
- Probes: startup, liveness, readiness (all to `/api/v1/health`)
- Resource limits

**Frontend deployment must include:**
- Nginx writable dirs: `/tmp`, `/var/cache/nginx`, `/var/run` (emptyDir mounts)
- NO secrets (frontend receives only ConfigMap-backed non-secret config)
- Probes: liveness, readiness (to `/health`)
- ConfigMap for nginx config and `window.__ENV__` injection

**PostgreSQL StatefulSet:**
- Conditional on `postgres.enabled: true` (eval only)
- `securityContext.runAsUser: 999`, `fsGroup: 999`
- `readOnlyRootFilesystem: false` (PostgreSQL needs writable data dir)
- PVC with configurable `storageClassName` (empty = cluster default)
- Probes: `exec pg_isready`

**RBAC:**
- Conditional on `rbac.create: true`
- ServiceAccount (or reference existing via `rbac.serviceAccountName`)
- Namespaced Role + RoleBinding only (NO ClusterRole)

### Reference Files to Read (in runtime repo)

| File | What to extract |
|------|----------------|
| `[runtime] k8s/base/platform-api-deployment.yaml` | Backend pod spec, probes, env vars, volumes |
| `[runtime] k8s/base/frontend/frontend-deployment.yaml` | Frontend pod spec, nginx config |
| `[runtime] k8s/base/postgres-statefulset.yaml` | StatefulSet spec, volume claims, init |
| `[runtime] k8s/base/platform-configmap.yaml` | ConfigMap structure and keys |
| `[runtime] k8s/base/platform-secrets.yaml` | Secret structure and required keys |
| `[runtime] k8s/rbac/platform-api-rbac.yaml` | Existing RBAC resources |
| `[runtime] frontend/nginx.conf` | Nginx configuration to templatize |
| `[runtime] Dockerfile` | Backend image entrypoint, ports, user |
| `[runtime] frontend/Dockerfile` | Frontend build stages, nginx base |

### Exit Criteria

- [ ] `helm template test helm/biznez-runtime/` renders valid YAML
- [ ] `helm template` output contains only namespaced resources (no ClusterRole, Namespace, etc.)
- [ ] `helm install biznez helm/biznez-runtime/ -n biznez` succeeds on local K8s
- [ ] Backend pod is Running and `/api/v1/health` returns 200
- [ ] Frontend pod is Running and `/health` returns 200
- [ ] PostgreSQL pod is Running and `pg_isready` passes
- [ ] Port-forward works: `kubectl port-forward svc/biznez-backend 8000:8000 -n biznez`
- [ ] Conditional rendering: `postgres.enabled: false` skips all postgres templates
- [ ] Conditional rendering: `rbac.create: false` skips RBAC templates
- [ ] Secret conditionality: `backend.existingSecret` set skips chart-generated secret
- [ ] **Frontend has zero secret injection** -- no `secretKeyRef`, no `envFrom` for secrets, no `existingSecret` in frontend templates (this is a packaging principle, enforce it now)
- [ ] NOTES.txt renders port-forward commands and access URLs for eval profile
- [ ] NOTES.txt renders health-check reminder for production profile

---

## Phase 2.5: Contract Tests & CI Gates

**Goal:** Establish lightweight CI gates that catch packaging principle violations early. These gates prevent accumulating mistakes (cluster-scoped resources, secret leaks to frontend, wrong env var names) that would otherwise surface late and require rework across multiple phases.

**Timing:** Run after Phase 2, before or alongside Phase 3. These gates run continuously from this point forward.

### Files to Create

| File | Purpose |
|------|---------|
| `policies/no-cluster-scoped.rego` | conftest OPA policy: no cluster-scoped resources |
| `policies/no-frontend-secrets.rego` | conftest OPA policy: frontend must not reference secrets |
| `policies/no-gcp-in-dist.rego` | conftest OPA policy: no GCP-specific references (created in Phase 0) |
| `tests/smoke-test.sh` | Minimal smoke test (curl health endpoints on local K8s) |

### Gate 1: No Cluster-Scoped Resources (conftest)

```bash
helm template test helm/biznez-runtime/ | \
  conftest test - --policy policies/
```

Policy (`no-cluster-scoped.rego`):
- Denylist of cluster-scoped kinds (ClusterRole, ClusterRoleBinding, CRD, Namespace, etc.)
- Allowlist of permitted namespaced kinds (Deployment, Service, ConfigMap, Secret, StatefulSet, Job, PVC, ServiceAccount, Role, RoleBinding, HPA, NetworkPolicy, Ingress, HTTPRoute, PodDisruptionBudget)
- Any kind not in the allowlist triggers a review failure

### Gate 2: No Secret Injection in Frontend (conftest)

Policy (`no-frontend-secrets.rego`):
- Scans all Deployment resources with label `app.kubernetes.io/component: frontend`
- Fails if any container has `envFrom` referencing a Secret
- Fails if any container has `env[].valueFrom.secretKeyRef`
- This enforces the design principle: frontend receives only ConfigMap-backed non-secret config

### Gate 3: No GCP References in Dist (conftest)

Policy (`no-gcp-in-dist.rego`, created in Phase 0):
- Fails if rendered YAML contains: `googleapis.com`, `gke.io`, `cloud.google.com`, GCP project ID patterns, `pkg.dev` registry URLs, `gcr.io` references
- Ensures distribution chart is cloud-agnostic

### Gate 4: Schema Validation (kubeconform)

```bash
helm template test helm/biznez-runtime/ | \
  kubeconform -strict -summary -
```

Catches: typos in field names, wrong apiVersions, invalid field types in rendered YAML.
Run on both eval and production profiles.

### Gate 5: Smoke Test Script

`tests/smoke-test.sh` -- run after `helm install` on local K8s:

```bash
# Usage: ./smoke-test.sh [namespace]
# 1. Wait for all pods to be Ready (timeout 120s)
# 2. Port-forward backend + frontend
# 3. curl backend /api/v1/health -- expect 200
# 4. curl frontend /health -- expect 200
# 5. If postgres.enabled: pg_isready
# 6. If gateway.enabled: curl gateway /healthz -- expect 200
# 7. Report pass/fail
```

### Exit Criteria

- [ ] `conftest test` passes on `helm template` output (no cluster-scoped resources)
- [ ] `conftest test` passes: frontend templates contain zero secret references
- [ ] `conftest test` passes: no GCP-specific references in rendered YAML
- [ ] `kubeconform` validates rendered YAML for both eval and production profiles
- [ ] Smoke test script passes on local K8s after `helm install`
- [ ] All five gates documented as CI steps (even if CI pipeline is configured later)

---

## Phase 3: Gateway & Migrations

**Goal:** Add the Agent Gateway service and database migration infrastructure. After this phase, the full four-service stack runs and migrations can be executed in all three modes.

### Files to Create

| File | Purpose |
|------|---------|
| `helm/biznez-runtime/templates/gateway/deployment.yaml` | Agent Gateway deployment (conditional) |
| `helm/biznez-runtime/templates/gateway/service.yaml` | Gateway ClusterIP service (conditional) |
| `helm/biznez-runtime/templates/gateway/configmap.yaml` | Gateway YAML config (conditional) |
| `helm/biznez-runtime/templates/gateway/secret.yaml` | Gateway secrets (conditional) |
| `helm/biznez-runtime/templates/backend/migration-job.yaml` | Migration Job template (conditional) |

### Implementation Details

**Gateway deployment must include:**
- Conditional on `gateway.enabled: true`
- Security context (non-root, readOnlyRootFilesystem, dropped caps)
- Writable emptyDir mount: `/tmp`
- Secret injection via `envFrom` (entire secret as env vars -- keys are user-defined)
- ConfigMap mount for gateway YAML configuration
- Probes: `/healthz` (liveness), `/readyz` (readiness)
- Resource limits, timeout configuration

**Gateway ConfigMap:**
- Renders `gateway.config` values into YAML format
- Includes listeners, targets, routes structure
- Secret references use `${ENV_VAR_NAME}` syntax (resolved at runtime from env vars)

**Migration Job (`migration-job.yaml`):**
- Conditional on `migration.mode == "hook"` (for Helm hook mode)
- Uses same backend image
- Shares exact same env injection block as backend Deployment (via `_helpers.tpl` shared helper)
- Command: `python -m agentic_runtime.db.migration_runner`
- Helm hook annotations: `pre-install`, `pre-upgrade`
- Hook delete policy: `before-hook-creation`
- `restartPolicy: Never`, `backoffLimit: 3`, `activeDeadlineSeconds: 600`
- `ttlSecondsAfterFinished` configurable (omit when null for clusters without TTL controller)
- Same security context as backend
- Writable emptyDir: `/tmp`

**initContainer mode:**
- When `migration.mode == "initContainer"`, add init container to backend deployment
- Same image, same env, runs `python -m agentic_runtime.db.migration_runner`

**Advisory lock module:**
- Verify `[runtime] src/agentic_runtime/db/migration_runner.py` exists or needs to be created
- `pg_try_advisory_lock(bigint)` with lock ID `738291456`
- Single dedicated connection (`pool_size=1, max_overflow=0`)
- 30 retries, 2s apart = 60s max wait
- Explicit unlock in `finally` block

### Reference Files to Read (in runtime repo)

| File | What to extract |
|------|----------------|
| `[runtime] k8s/mcp-gateway/deployment.yaml` | Gateway pod spec, probes, config mount |
| `[runtime] k8s/mcp-gateway/configmap.yaml` | Gateway YAML config structure |
| `[runtime] alembic.ini` | Migration config, target metadata |
| `[runtime] src/agentic_runtime/db/` | Migration runner module (if exists) |

### Exit Criteria

- [ ] Gateway pod running when `gateway.enabled: true`
- [ ] Gateway skipped when `gateway.enabled: false`
- [ ] Gateway config YAML correctly rendered in ConfigMap
- [ ] Gateway secrets injected via `envFrom`
- [ ] Migration hook Job runs on `helm install` (mode=hook)
- [ ] Migration initContainer blocks backend startup until complete (mode=initContainer)
- [ ] No migration resources rendered when `migration.mode: manual`
- [ ] **Manual migrate path works end-to-end:** render migration Job YAML standalone (as `biznez-cli migrate` would), apply it, verify it runs to completion. This is production-critical even though hook is the eval default.
- [ ] Advisory lock prevents concurrent migrations (test with parallel Jobs)
- [ ] Migration Job uses identical env vars as backend Deployment
- [ ] `ttlSecondsAfterFinished` omitted when set to null

---

## Phase 4: Networking

**Goal:** Ingress, Gateway API, and NetworkPolicy templates. After this phase, services are accessible via ingress (when configured) and network policies enforce isolation.

### Files to Create

| File | Purpose |
|------|---------|
| `helm/biznez-runtime/templates/ingress.yaml` | Ingress resource(s) (conditional) |
| `helm/biznez-runtime/templates/gateway-api.yaml` | Gateway API HTTPRoute(s) (conditional) |
| `helm/biznez-runtime/templates/networkpolicy.yaml` | NetworkPolicy per component (conditional) |

### Implementation Details

**Ingress (`ingress.yaml`):**
- Conditional on `ingress.enabled: true`
- Two modes: `multiHost` (single Ingress) vs `splitByHost` (one Ingress per host)
- TLS: mutually exclusive `existingSecret` vs `certManager` mode
  - `existingSecret`: references pre-created TLS secret, no cert-manager annotations
  - `certManager`: adds `cert-manager.io/cluster-issuer` annotation
  - Template `{{ fail }}` if both or neither configured
- Nginx streaming annotations: conditional on `ingress.applyNginxStreamingAnnotations: true`
  - `proxy-read-timeout`, `proxy-send-timeout`, `proxy-buffering: "off"`
- Client-provided annotations merged via `ingress.annotations`
- Per-host className/annotations override (splitByHost mode)

**Gateway API (`gateway-api.yaml`):**
- Conditional on `gatewayApi.enabled: true`
- CRD availability check: `.Capabilities.APIVersions.Has "gateway.networking.k8s.io/v1"` + `{{ fail }}` if missing
- Renders HTTPRoute resources referencing client's existing Gateway
- No CRD installation (client responsibility)

**NetworkPolicy (`networkpolicy.yaml`):**
- Conditional on `networkPolicy.enabled: true`
- Per-component ingress rules:
  - Backend: allow from frontend + gateway (same namespace)
  - Frontend: allow from ingress namespace (configurable selector)
  - PostgreSQL: allow from backend only
  - Gateway: allow from backend
- Per-component egress rules:
  - DNS: parameterized selectors (kube-system/kube-dns or coredns), both UDP and TCP port 53
  - Backend: postgres + external services (LLM, OIDC)
  - Frontend: backend only
  - PostgreSQL: deny all egress
  - Gateway: MCP target CIDRs/namespaces
- Egress strategies: `allowAllHttps`, `proxy.cidrs`, `externalServices.cidrs`, `mcpTargets`
- Proxy env vars: `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` injected into backend + gateway when `proxy.httpProxy` set
- Impossible config detection: `{{ fail }}` when networkPolicy enabled + no egress path configured

### Reference Files to Read (in runtime repo)

| File | What to extract |
|------|----------------|
| `[runtime] k8s/base/platform-ingress.yaml` | Ingress annotations, hosts, TLS config |

### Exit Criteria

- [ ] Ingress multiHost mode renders single Ingress with multiple hosts
- [ ] Ingress splitByHost mode renders one Ingress per host
- [ ] TLS existingSecret mode references secret, no cert-manager annotations
- [ ] TLS certManager mode adds cert-manager annotation
- [ ] TLS validation: `{{ fail }}` on ambiguous config
- [ ] Gateway API template guarded by Capabilities check
- [ ] NetworkPolicy renders per-component policies with correct ingress/egress rules
- [ ] DNS egress includes both UDP and TCP port 53
- [ ] Impossible config detection fires when no egress path configured
- [ ] Proxy env vars injected when `proxy.httpProxy` set
- [ ] All networking templates skipped when disabled (no orphaned resources)
- [ ] `helm template` with ingress produces valid Ingress YAML
- [ ] **SSE acceptance test (nginx):** SSE streaming works through nginx-ingress with events arriving continuously and connection surviving > 2 minutes. Test with a curl-based SSE client or a purpose-built test script that opens an SSE connection through ingress, receives events, and verifies the connection is not prematurely terminated by proxy timeouts.
- [ ] **Gateway API render-time CRD check:** `helm install` with `gatewayApi.enabled: true` fails immediately on a cluster without Gateway API CRDs (clear error message). Recommended: also provide a test harness for real-cluster smoke test when Gateway API CRDs are available.
- [ ] **NetworkPolicy smoke test:** with `networkPolicy.enabled: true` and `egress.allowAllHttps: true`, deploy on local K8s and verify: (a) backend can reach postgres, (b) backend can reach external HTTPS endpoints (LLM health check or similar), (c) DNS resolution works inside all pods, (d) frontend cannot reach postgres directly. NetworkPolicy bugs are common and silent -- a dedicated test catches them early.

---

## Phase 5: Production Hardening

**Goal:** Complete `values-production.yaml` and all production template guards. After this phase, the production profile enforces all security requirements at render time.

### Files to Create

| File | Purpose |
|------|---------|
| `helm/biznez-runtime/values-production.yaml` | CIS-hardened production overrides |
| `helm/biznez-runtime/templates/backend/hpa.yaml` | HorizontalPodAutoscaler (conditional) |

### Implementation Details

**`values-production.yaml` includes:**
- `global.profile: production`
- `global.securityProfile: hardened`
- `postgres.enabled: false` (external DB required)
- `auth.mode: oidc` (local JWT disabled)
- `migration.mode: manual`
- `imagePullPolicy: IfNotPresent`
- `global.requireDigests: true` (digest pinning enforcement, see below)
- Increased resource limits
- `autoscaling.enabled: true` (minReplicas: 2, maxReplicas: 10)
- `pdb.enabled: true`, `pdb.minAvailable: 1`
- `networkPolicy.enabled: true`, `egress.allowAllHttps: false`
- All inline secrets empty (existingSecret required)

**Production template guards (in existing templates from Phase 2-4):**
- Add `{{ required }}` / `{{ fail }}` guards keyed off `global.profile == "production"`
- Guards for: `backend.existingSecret`, `llm.existingSecret`, `auth.oidc.issuer`, `auth.oidc.audience`, `postgres.external.host`, `postgres.external.existingSecret`, `ingress.tls.secretName` or `clusterIssuer`
- Block inline secrets: `{{ fail }}` when `backend.secrets.*` non-empty in production
- Block inline secrets: `{{ fail }}` when `llm.secrets.*` non-empty in production

**HPA template:**
- Conditional on `autoscaling.enabled: true`
- CPU and memory target utilization
- Min/max replicas from values

**PDB (in backend deployment template or separate file):**
- Conditional on `pdb.enabled: true`
- `minAvailable: 1` (configurable)
- **Template guard:** `{{ fail }}` when `pdb.enabled: true` and `backend.replicas < 2` (PDB with minAvailable=1 is meaningless with 1 replica and blocks voluntary disruptions). This is a template-time fail, not just documentation.

**Digest pinning enforcement:**
```yaml
global:
  requireDigests: false          # eval default (tags are fine)

# values-production.yaml:
global:
  requireDigests: true           # production default
```
When `global.requireDigests: true`, the `biznez.imageRef` helper in `_helpers.tpl` calls
`{{ fail }}` if any component's `image.digest` is empty. This ensures all images are pinned
to digests in production. Transitional clients can set `requireDigests: false` to opt out,
but the secure default is enforced.

Guard message: `"Production requires digest-pinned images. Set <component>.image.digest or set global.requireDigests=false to opt out."`

### Exit Criteria

- [ ] `helm template test helm/biznez-runtime/ -f values-production.yaml` fails with clear error when `backend.existingSecret` not set
- [ ] All production guards produce actionable error messages
- [ ] Inline secrets rejected in production profile
- [ ] **Digest pinning enforced:** `helm template -f values-production.yaml` fails when any image digest is empty (with `global.requireDigests: true`)
- [ ] **Digest pinning opt-out works:** `global.requireDigests: false` allows tags without digest
- [ ] `helm template` with eval profile has NO guards (works out of the box)
- [ ] HPA rendered when `autoscaling.enabled: true`
- [ ] PDB rendered when `pdb.enabled: true`
- [ ] **PDB template guard:** `{{ fail }}` when `pdb.enabled: true` and `backend.replicas < 2`
- [ ] `values-production.yaml` is a minimal overlay (does not duplicate all of `values.yaml`)

---

## Phase 6: Docker Compose

**Goal:** Docker Compose setup for evaluation/demo deployments without Kubernetes. After this phase, `docker compose up` starts the full stack on a laptop.

### Phasing Note: Migration Dependency

Docker Compose can start after Phase 1 (it doesn't need Helm templates), but the "runs
migrations on startup" behavior depends on the migration runner module from Phase 3.

**Phase 6 (early, after Phase 1):** Bring up services, health endpoints, static schema (no
auto-migration). Backend connects to postgres but expects tables to already exist or skips
gracefully.

**Phase 6.1 (after Phase 3):** Add migration-on-startup to `docker-compose.yml` backend
entrypoint (e.g., `python -m agentic_runtime.db.migration_runner && uvicorn ...`). This
gives Docker Compose full parity with the Helm migration modes.

This avoids noisy failures in Phase 6 from a migration runner that doesn't exist yet.

### Files to Create

| File | Purpose |
|------|---------|
| `compose/docker-compose.yml` | All services (postgres, backend, frontend, gateway) |
| `compose/.env.template` | All configuration as env vars with documentation |
| `compose/nginx.conf` | Frontend nginx config for Docker Compose |
| `compose/setup.sh` | Setup script (generate secrets, start services) |

### Implementation Details

**`docker-compose.yml` services:**
- `postgres` -- PostgreSQL 15-alpine, named volume for data, healthcheck via `pg_isready`
- `backend` -- Platform API, depends_on postgres (healthy), port 8000. Migration-on-startup added in Phase 6.1 (after Phase 3).
- `frontend` -- React app via nginx, port 8080 (mapped to container port 80)
- `gateway` -- Agent Gateway (optional, can be commented out)
- Network: single bridge network for inter-service communication
- **All ports configurable via `.env`** (e.g., `BACKEND_PORT=8000`, `FRONTEND_PORT=8080`). Document defaults clearly.

**`.env.template`:**
- All environment variables with comments explaining each
- Placeholder values for secrets (never real keys)
- Auth mode default: `local` (no external IdP needed)
- OIDC section with documentation of required redirect URIs
- `COMPOSE_PULL_POLICY` for air-gapped installs

**`setup.sh`:**
- Generates JWT secret, encryption key, DB password
- **Secrets are written to `.env` file only, never printed to terminal** unless `--show-secrets` is explicitly passed. This prevents accidental exposure in shared terminals, screen recordings, or CI logs.
- Copies `.env.template` to `.env` (if not exists)
- Detects if images are already loaded (skip pull)
- Prints access URLs after startup
- Prints exact redirect URI(s) for OIDC setup (if OIDC mode)

**Air-gapped support:**
- `pull_policy: never` in docker-compose.yml (overridable via env)
- Images loaded via `biznez-cli import-images --docker` (Phase 7)
- `setup.sh` detects locally cached images

### Reference Files to Read (in runtime repo)

| File | What to extract |
|------|----------------|
| `[runtime] docker-compose.yml` | Existing Docker Compose structure |
| `[runtime] .env.example` | All environment variables |
| `[runtime] frontend/nginx.conf` | Nginx config to adapt |

### Exit Criteria

- [ ] `docker compose config` validates without errors
- [ ] `docker compose up` starts all services (postgres, backend, frontend, gateway)
- [ ] Backend accessible at `http://localhost:8000/api/v1/health`
- [ ] Frontend accessible at `http://localhost:8080`
- [ ] PostgreSQL data persists across restarts (named volume)
- [ ] `setup.sh` generates secrets and starts services in one command
- [ ] **`setup.sh` does not print secrets to terminal** (writes to `.env` only)
- [ ] `.env.template` documents all variables with comments
- [ ] Frontend port is 8080 (nginx production build, NOT Vite dev server 5173)
- [ ] Ports are configurable via `.env` (BACKEND_PORT, FRONTEND_PORT, etc.)
- [ ] **Phase 6.1 (after Phase 3):** Backend runs migrations on startup, migration runner module works in Docker Compose context

---

## Phase 7: Operator CLI

**Goal:** The `biznez-cli` bash script with runtime operator commands: validate, install, migrate, health-check, and diagnostics. Supply chain commands (export/import images, signing, verification) are deferred to Phase 8 to avoid scope pressure and prevent "bash turns into a build system" too early.

### Files to Create

| File | Purpose |
|------|---------|
| `cli/biznez-cli` | Operator CLI script (bash 3.2+, single file) |

### Commands to Implement (Phase 7 scope: runtime ops only)

| Command | Priority | Description |
|---------|----------|-------------|
| `validate` | P0 | Profile-aware prerequisite checks |
| `generate-secrets` | P0 | Generate encryption key, JWT secret, DB password |
| `validate-secrets` | P0 | Check existingSecret refs contain required keys |
| `install` | P0 | Interactive install (wraps `helm install`) |
| `migrate` | P0 | Run Alembic migrations (creates Job, streams logs) |
| `migrate --dry-run` | P1 | Show pending SQL without applying |
| `health-check` | P0 | Post-install health validation |
| `oidc-discover` | P1 | Discover OIDC endpoints from issuer URL |
| `support-bundle` | P1 | Collect diagnostic bundle (redacted) |
| `backup-db` | P2 | pg_dump for embedded postgres |
| `restore-db` | P2 | pg_restore for embedded postgres |
| `upgrade` | P2 | Upgrade to new version (wraps `helm upgrade`) |

**Deferred to Phase 8 (release tooling):**

| Command | Description |
|---------|-------------|
| `export-images` | Export images per images.lock as archive |
| `import-images` | Load archive into client registry (retag all images) |
| `import-images --docker` | Load archive into local Docker daemon |
| `verify-images` | Cosign verification against registry |
| `build-release` | Generate images.lock, SBOM, sign artifacts |

### Implementation Details

**`validate` command:**
- Common: kubectl version >= 1.27, helm >= 3.12, namespace exists, registry connectivity
- `--profile eval`: storage class check, warn if no default
- `--profile production`: PSA label, external DB connectivity, existingSecret validation, OIDC issuer reachable, TLS config, imagePullSecrets, NetworkPolicy API
- `--in-cluster` flag: spin short-lived Job for cluster-network connectivity tests (DB, OIDC, DNS)

**`migrate` command:**
- Renders migration Job YAML from Helm template
- Applies Job via `kubectl apply`
- Streams logs in real-time (`kubectl logs -f`)
- Waits for completion, reports exit status
- Prints cleanup command if TTL disabled

**`export-images` / `import-images`:**
- Reads `images.lock` for image list
- `export`: pulls all images by digest, saves as tar.gz (docker-archive or oci-archive format)
- `import`: loads tar.gz, retags to client registry, pushes
- `import --docker`: loads into local Docker daemon (handles format detection)

**`support-bundle`:**
- helm values (secrets REDACTED)
- helm get manifest
- kubectl get pods, svc, ep, ingress, events
- Pod logs (tail 500) for backend, frontend, gateway
- kubectl/helm versions, node info, PVC status, NetworkPolicy status
- Output: `biznez-support-<timestamp>.tar.gz`

### Exit Criteria

- [ ] `biznez-cli validate` passes on local K8s with eval profile
- [ ] `biznez-cli generate-secrets` outputs valid Fernet key + JWT secret
- [ ] `biznez-cli install --profile eval` does full install from scratch
- [ ] `biznez-cli migrate` creates Job, streams logs, reports success
- [ ] `biznez-cli migrate --dry-run` shows SQL without applying
- [ ] `biznez-cli health-check` validates all component health endpoints
- [ ] `biznez-cli support-bundle` produces tar.gz with redacted values
- [ ] Script is **bash 3.2+ compatible** (macOS ships bash 3.2 due to GPLv3 licensing; avoid bash 4+ features like associative arrays, `${var,,}` lowercasing, `mapfile`, `readarray`). If you truly need POSIX sh, avoid arrays and `[[ ]]` entirely -- but bash 3.2 is the pragmatic target for mac+linux compatibility.
- [ ] All commands print usage on `--help`

---

## Phase 8: Release Pipeline & Tooling

**Goal:** Image manifest, SBOM generation, artifact signing, vulnerability scanning, and CLI release commands (export/import/verify). After this phase, the release process produces all artifacts needed for enterprise delivery.

**Note on CI gates:** The conftest policies and kubeconform gates were established in Phase 2.5 and have been running continuously since then. This phase builds on those foundations with release-specific tooling.

### Files to Create

| File | Purpose |
|------|---------|
| `helm/biznez-runtime/images.lock` | Deterministic image manifest with digests |

### CLI Commands Added to `biznez-cli` (release tooling)

These commands extend the operator CLI from Phase 7 with supply chain management:

| Command | Description |
|---------|-------------|
| `export-images` | Export images per images.lock as archive (docker-archive or oci-archive) |
| `import-images` | Load archive into client registry, retag all images |
| `import-images --docker` | Load archive into local Docker daemon (format detection) |
| `verify-images` | Cosign verification against client registry |
| `build-release` | Generate images.lock, pull images, generate SBOM, sign artifacts |

### Implementation Details

**`images.lock`:**
- Schema: `version`, `images[]` with `shortName`, `repository`, `tag`, `digest`, `platform`
- v1: all images `linux/amd64`
- Full source repository refs (`docker.io/library/postgres`, `ghcr.io/agentgateway/agentgateway`)
- Generated by `biznez-cli build-release` (or manually)

**Release artifacts (per version):**
- `biznez-images-v{VERSION}.tar.gz` -- OCI image archive
- `images.lock` -- pinned digests
- `sbom-v{VERSION}.json` -- Syft SPDX SBOM
- `trivy-report-v{VERSION}.json` -- vulnerability scan report
- `biznez-images-v{VERSION}.sig` -- cosign signatures
- `checksums.sha256` -- SHA-256 checksums

**Artifact signing (3 modes):**
- Unsigned (minimum): checksums only
- Cosign key-pair (recommended): key-pair signing of images + archive
- Cosign keyless (OIDC): Fulcio + Rekor with CI identity

**Vulnerability scanning:**
- Trivy scan on **all images** (Biznez-owned + third-party: postgres, agentgateway)
- `--severity HIGH,CRITICAL --exit-code 1`
- Release policy: zero CRITICAL, HIGH with documented justification
- Report published as release artifact
- Enterprise clients will ask for all-image scanning (not just Biznez-owned) -- the report
  must cover every image in `images.lock`

**SBOM scope:** SBOM is generated for **all images in `images.lock`** (Biznez-owned + third-party).
Enterprise procurement teams require complete dependency visibility across the entire software
supply chain, not just first-party code. Use Syft to scan each image individually and merge
into a single SPDX document.

### Exit Criteria

- [ ] `images.lock` contains all 4 images with valid digests
- [ ] `biznez-cli export-images` produces archive from images.lock
- [ ] `biznez-cli import-images` loads into registry and retags
- [ ] `biznez-cli import-images --docker` loads into local Docker daemon
- [ ] Trivy scan runs against **all images** (including third-party) without CRITICAL vulnerabilities
- [ ] **SBOM covers all images** in images.lock (not just Biznez-owned)
- [ ] Cosign signing workflow documented and functional
- [ ] `biznez-cli verify-images` checks signatures against client registry
- [ ] `biznez-cli build-release` produces all release artifacts in one command

---

## Phase 9: Documentation

**Goal:** Complete documentation set for client handoff. Each document is standalone and self-contained for the topic it covers.

### Files to Create

| File | Audience | Content |
|------|----------|---------|
| `docs/INSTALL.md` | Platform operator | Step-by-step install (eval + production) |
| `docs/PRODUCTION-CHECKLIST.md` | Platform operator | Pre-production sign-off checklist |
| `docs/MIGRATION-GUIDE.md` | Platform operator / DBA | Zero-downtime migration procedures |
| `docs/OIDC-SETUP.md` | Identity admin | OIDC provider setup (claims, roles, redirect URIs) |
| `docs/SECURITY.md` | Security / procurement | Security posture, signing, scanning, hardening |
| `docs/BACKUP-RESTORE.md` | Platform operator | Backup/restore procedures |
| `docs/NETWORKING.md` | Network admin | Ingress, TLS, streaming, network policies, proxy |
| `docs/UPGRADE.md` | Platform operator | Version upgrade procedures, rollback |

### Documentation Content Outline

**INSTALL.md:**
- Prerequisites (kubectl, helm, namespace, storage class)
- Eval quick-start (5 commands)
- Production install (step-by-step with secrets, registry, values)
- Docker Compose quick-start
- Troubleshooting common issues

**PRODUCTION-CHECKLIST.md:**
- [ ] External managed DB configured and tested
- [ ] OIDC provider configured with correct claims/roles
- [ ] All secrets via existingSecret (no inline secrets)
- [ ] TLS configured (existingSecret or certManager)
- [ ] Image registry populated, imagePullSecrets created
- [ ] Network policies configured with egress path
- [ ] Resource limits tuned for workload
- [ ] HPA configured (min 2 replicas)
- [ ] Backup strategy documented
- [ ] Migration mode decision (hook vs manual)
- [ ] Vulnerability scan report reviewed

**MIGRATION-GUIDE.md:**
- Three migration modes explained
- Advisory lock mechanism
- Zero-downtime expand/contract pattern
- Helm rollback + migration interaction
- `biznez-cli migrate --dry-run` workflow

**OIDC-SETUP.md:**
- Provider-agnostic setup (any OIDC-compliant IdP)
- Claim mapping configuration
- Role mapping from groups
- `biznez-cli oidc-discover` usage
- Redirect URI configuration
- Common pitfalls (HTTP vs HTTPS, audience mismatch)

**SECURITY.md:**
- Pod Security Admission (restricted profile)
- Container hardening (non-root, read-only rootfs, dropped caps)
- Secret management (existingSecret pattern)
- Artifact signing and verification
- Vulnerability management (scan cadence, SLAs)
- Network isolation (NetworkPolicy)
- RBAC model
- Known risks and mitigations (env var leakage)
- Future: file-based secrets (v2)

**NETWORKING.md:**
- Ingress patterns (nginx, ALB, GKE, istio)
- Gateway API setup
- Streaming/SSE timeout requirements per controller
- Network policy egress strategies (A/B/C/D)
- Proxy configuration
- ClusterIP + port-forward (eval)

**UPGRADE.md:**
- Pre-upgrade checklist (backup, dry-run migration)
- `biznez-cli upgrade` workflow
- Rollback procedure (Helm rollback + DB considerations)
- Breaking change communication
- Expand/contract migration pattern

**BACKUP-RESTORE.md:**
- Embedded postgres: `biznez-cli backup-db` / `restore-db`
- External DB: client responsibility (RDS snapshots, Cloud SQL)
- Recommended backup frequency and retention

### Exit Criteria

- [ ] All 8 documentation files created
- [ ] Each document is standalone (no broken cross-references)
- [ ] INSTALL.md eval quick-start is copy-pasteable (5 commands or fewer)
- [ ] PRODUCTION-CHECKLIST.md covers all production guards from Phase 5
- [ ] SECURITY.md addresses common enterprise procurement questions
- [ ] All `biznez-cli` commands documented with examples
- [ ] No hardcoded GCP/Biznez-internal references

---

## Dependency Graph

```
Phase 0 ──► Phase 1 ──► Phase 2 ──► Phase 2.5 ──► Phase 3 ──► Phase 4 ──► Phase 5 ──► Phase 8
  (Repo      (Chart)    (Services    (CI Gates)    (Gateway+    (Network)   (Hardening)  (Release
   Setup)                + NOTES)                   Migration)                           Tooling)

Phase 6 (Docker Compose) can start after Phase 1
  └── Phase 6.1 (migration on startup) requires Phase 3

Phase 7 (Operator CLI) can start after Phase 3 (needs migration Job template)

Phase 8 (Release Tooling) extends CLI from Phase 7 + needs Phase 5 (production values)

Phase 9 (Docs) can start after Phase 8 (needs all CLI commands finalized)

Parallel tracks:
  Track A: Phase 0 → 1 → 2 → 2.5 → 3 → 4 → 5 → 8 → 9  (Helm chart + release)
  Track B: Phase 1 → 6 (Docker Compose, no migration)
                    Phase 3 → 6.1 (Docker Compose + migration)
  Track C: Phase 3 → 7 → 8 (CLI: runtime ops → release tooling)
  Track D: Phase 8 → 9 (Docs, needs full CLI)

Cross-repo interactions:
  - Runtime repo builds images → dist repo consumes them via images.lock
  - Runtime repo owns config-contract.yaml → dist repo ships pinned copy in contracts/
  - versions.yaml maps dist release → runtime release tag → git SHA → digests

Note: Phase 2.5 CI gates (conftest, kubeconform, smoke test) run continuously
from Phase 2.5 onward. Every subsequent phase must pass these gates.
```

---

## Risk Mitigation Per Phase

| Phase | Key Risk | Mitigation |
|-------|----------|------------|
| 0 | Two-repo workflow friction | Makefile + dev harness scripts abstract cross-repo operations |
| 1 | values.yaml schema drift from plan | Cross-reference every section of packaging plan |
| 2 | Existing K8s manifests have undocumented env vars | Read `config.py` + `.env.example` exhaustively |
| 2.5 | CI gates miss a principle violation | Run gates against both eval and production profiles |
| 3 | Advisory lock module doesn't exist in codebase | Create `migration_runner.py` as part of this phase |
| 4 | NetworkPolicy breaks DNS or inter-service comms | Dedicated NetworkPolicy smoke test with DNS verification |
| 4 | SSE streaming silently broken by proxy timeouts | Explicit SSE acceptance test through nginx ingress |
| 5 | Production guards too strict for transitioning clients | `requireDigests: false` opt-out, incremental hardening without profile=production |
| 6 | Docker Compose fails due to missing migration runner | Phase 6 works without migrations; Phase 6.1 adds them after Phase 3 |
| 6 | Docker Compose port conflicts on client machines | All ports configurable via `.env`, defaults documented |
| 7 | CLI requires bash 4+ features unavailable on macOS | Target bash 3.2+; avoid associative arrays, `${var,,}`, `mapfile` |
| 7 | CLI assumes tools not present (skopeo, crane) | Degrade gracefully, detect available tools (deferred to Phase 8 release commands) |
| 8 | Cosign/Trivy not in CI pipeline yet | Start with unsigned + checksums, add signing later |
| 8 | SBOM scope unclear (first-party only vs all) | All images in images.lock -- enterprise requires full supply chain visibility |
| 9 | Documentation references non-existent features | Write docs after implementation, not before |
