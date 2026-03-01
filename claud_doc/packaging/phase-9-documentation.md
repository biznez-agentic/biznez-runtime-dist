# Phase 9 — Documentation for Client Handoff

**Status: IMPLEMENTED**

## Context

All implementation phases (0–9) are complete. The platform is fully functional with:
- Helm chart (22 templates, eval + production profiles, 12 production guards)
- Docker Compose (4 services, setup.sh automation)
- Operator CLI (17 commands across P0/P1/P2/P3 tiers)
- Release pipeline (build-release, export/import/verify images, signing, SBOM)
- CI pipeline (shellcheck, unit tests, integration tests, bundle)

Phase 9 replaces the 8 placeholder docs with production-quality content for client handoff. The audience is **platform operators, security reviewers, and network/identity admins** at client organizations.

---

## Files to Create/Modify

### Documentation (replace placeholders)

| # | File | Audience | ~Lines |
|---|------|----------|--------|
| 1 | `docs/INSTALL.md` | Platform operator | ~350 |
| 2 | `docs/PRODUCTION-CHECKLIST.md` | Platform operator | ~200 |
| 3 | `docs/SECURITY.md` | Security / procurement | ~300 |
| 4 | `docs/NETWORKING.md` | Network admin | ~350 |
| 5 | `docs/MIGRATION-GUIDE.md` | Platform operator / DBA | ~250 |
| 6 | `docs/OIDC-SETUP.md` | Identity admin | ~200 |
| 7 | `docs/BACKUP-RESTORE.md` | Platform operator | ~150 |
| 8 | `docs/UPGRADE.md` | Platform operator | ~200 |

### Example Values (replace placeholders)

| # | File | Purpose |
|---|------|---------|
| 9 | `examples/eval-quickstart.yaml` | Copy-pasteable eval install values |
| 10 | `examples/production-minimal.yaml` | Minimal production values with comments |

---

## Document Content Plans

### 1. INSTALL.md (~350 lines)

**Sections:**
1. **Prerequisites** — kubectl v1.28+, helm v3.14+, namespace, storage class
2. **Evaluation Quick-Start (Kubernetes)** — 5 commands or fewer:
   ```
   kubectl create namespace biznez
   biznez-cli generate-secrets --format yaml | kubectl apply -n biznez -f -
   biznez-cli install -f examples/eval-quickstart.yaml --create-namespace
   biznez-cli health-check
   kubectl port-forward svc/biznez-frontend 8080:80 -n biznez
   ```
3. **Evaluation Quick-Start (Docker Compose)** — 3 commands:
   ```
   cd compose && bash setup.sh
   ```
4. **Production Install (Step-by-Step)** — Secrets → Registry → Values → Validate → Install → Health-check → Migrate
5. **Air-Gapped Install** — export-images → transfer → import-images → install with imageRegistry
6. **Uninstall** — `biznez-cli uninstall` with PVC cleanup options
7. **Troubleshooting** — Common issues (ImagePullBackOff, CrashLoopBackOff, pending PVC, OIDC errors)

**Source material:**
- CLI help text from `cli/biznez-cli` (lines 1680–1710 for help, dispatch at 1745–1760)
- `compose/setup.sh` (10-step flow)
- `helm/biznez-runtime/templates/NOTES.txt` (post-install guidance)
- `helm/biznez-runtime/values.yaml` (all configuration options)
- `examples/eval-quickstart.yaml` (will populate)
- `examples/production-minimal.yaml` (will populate)

---

### 2. PRODUCTION-CHECKLIST.md (~200 lines)

Markdown checklist format. Each item has a **what**, **why**, and **how** (CLI command or values key).

**Sections:**
1. **Infrastructure** — External managed DB, storage class, namespace, RBAC
2. **Secrets** — All via existingSecret (backend, postgres, llm, gateway, auth)
3. **Identity** — OIDC provider configured (issuer, audience, claims, role mapping)
4. **TLS** — Ingress TLS via existingSecret or cert-manager
5. **Container Images** — Private registry, imagePullSecrets, digest pinning (`global.requireDigests: true`)
6. **Networking** — Network policies enabled, egress path configured, ingress controller timeouts
7. **High Availability** — HPA (min 2 replicas), PDB, resource limits tuned
8. **Data** — Backup strategy, migration mode decision (hook vs manual)
9. **Supply Chain** — Vulnerability scan reviewed, SBOM archived, signatures verified
10. **Validation** — `biznez-cli validate -f values.yaml --profile production`

**Source material:**
- `helm/biznez-runtime/templates/validate.yaml` (12 production guards — maps 1:1 to checklist items)
- `helm/biznez-runtime/values-production.yaml` (all production overrides)

---

### 3. SECURITY.md (~300 lines)

**Sections:**
1. **Security Overview** — Defense-in-depth approach summary
2. **Pod Security** — PSA restricted profile, non-root, read-only rootfs, dropped capabilities, seccomp
3. **Container Hardening** — Per-component security contexts (backend, frontend/nginx UID 101, postgres UID 999)
4. **Secret Management** — existingSecret pattern, why env vars (not files in v1), known risk of env var leakage, mitigations (RBAC, audit logging)
5. **Artifact Signing & Verification** — Cosign key-pair and keyless modes, `verify-images` workflow
6. **Vulnerability Management** — Trivy scan during build-release, SBOM (Syft/SPDX), scan cadence recommendations
7. **Network Isolation** — NetworkPolicy model (backend, frontend, postgres, gateway), egress strategies
8. **RBAC Model** — Namespace-scoped only, zero cluster-scoped resources, OPA enforcement
9. **Image Integrity** — Digest pinning (`global.requireDigests`), images.lock manifest
10. **Known Risks & Mitigations** — Env var leakage, eval postgres not hardened, future file-based secrets (v2)

**Source material:**
- PACKAGING-PLAN.md Section 8 (Security Hardening, lines 1272+)
- `helm/biznez-runtime/values.yaml` (global.podSecurityContext, containerSecurityContext)
- `helm/biznez-runtime/templates/networkpolicy.yaml` (217 lines)
- `policies/no-gcp-in-dist.rego`, `no-cluster-scoped.rego`, `no-frontend-secrets.rego`

---

### 4. NETWORKING.md (~350 lines)

**Sections:**
1. **Overview** — Three exposure patterns (ClusterIP, Ingress, Gateway API)
2. **Evaluation (ClusterIP + port-forward)** — Default, no ingress controller needed
3. **Ingress Setup** — nginx reference config, multiHost vs splitByHost modes, annotations
4. **TLS Configuration** — existingSecret mode vs certManager mode, validation rules
5. **Streaming / SSE Timeouts** — Per-controller table (nginx, ALB, GCE, Istio), `applyNginxStreamingAnnotations`, `backend.streaming.*` values
6. **Gateway API** — HTTPRoute setup, prerequisite CRDs, `gatewayApi.*` values
7. **Network Policies** — Enable/disable, ingress rules, egress strategies (A/B/C/D), DNS rules
8. **Proxy Configuration** — HTTP/HTTPS proxy env vars, noProxy settings
9. **Agent Gateway** — MCP proxy, config structure (binds/listeners/routes), secrets for targets
10. **Troubleshooting** — SSE timeouts, 502/504 errors, blocked egress, DNS resolution

**Source material:**
- PACKAGING-PLAN.md Section 7 (lines 847–1271)
- `helm/biznez-runtime/templates/ingress.yaml`, `gateway-api.yaml`, `networkpolicy.yaml`
- `helm/biznez-runtime/values.yaml` (ingress, gatewayApi, networkPolicy, backend.streaming sections)

---

### 5. MIGRATION-GUIDE.md (~250 lines)

**Sections:**
1. **Overview** — Alembic-based migrations, three modes
2. **Migration Modes**:
   - **Auto (initContainer)** — Default for eval, blocks pod startup
   - **Hook (Helm Job)** — Pre-install/pre-upgrade, production-safe
   - **Manual** — Operator runs `biznez-cli migrate`, full control
3. **Advisory Lock Mechanism** — pg_try_advisory_lock(738291456), single connection, 30 retries
4. **Running Migrations** — `biznez-cli migrate` workflow, `--dry-run` for inspection
5. **Zero-Downtime Pattern** — Expand/contract: add nullable → backfill → remove old
6. **Helm Rollback Interaction** — Rollback does NOT reverse migrations, column mismatch risks
7. **Inspecting Lock State** — SQL queries for pg_locks
8. **Troubleshooting** — Lock contention, migration timeout, partial migrations

**Source material:**
- PACKAGING-PLAN.md Section 3 (lines 217–396)
- `helm/biznez-runtime/templates/backend/migration-job.yaml`
- CLI `migrate` command help text

---

### 6. OIDC-SETUP.md (~200 lines)

**Sections:**
1. **Overview** — OIDC-first auth, local JWT as eval fallback
2. **Provider-Agnostic Setup** — Any OIDC-compliant IdP (Okta, Azure AD, Auth0, Keycloak, Google)
3. **Configuration** — `auth.oidc.*` values (issuer, audience, claims, roleMapping)
4. **Claim Mapping** — subject, email, name, groups → platform roles
5. **Role Mapping** — adminGroups, userGroups configuration
6. **Redirect URIs** — Frontend URL, callback paths
7. **`biznez-cli oidc-discover`** — Usage and output
8. **Common Pitfalls** — HTTP vs HTTPS, audience mismatch, clock skew, JWKS cache TTL
9. **Dual Mode (Transition)** — `auth.mode: dual`, security implications, when to use
10. **Local JWT (Eval Only)** — Bootstrap admin, limitations (no MFA, no external audit)

**Source material:**
- PACKAGING-PLAN.md Section 5 (lines 626–695)
- `helm/biznez-runtime/values.yaml` (auth section)
- CLI `oidc-discover` command help text

---

### 7. BACKUP-RESTORE.md (~150 lines)

**Sections:**
1. **Overview** — Embedded vs external postgres responsibility model
2. **Embedded PostgreSQL (Eval)** — `biznez-cli backup-db`, `biznez-cli restore-db`, pg_dump/pg_restore
3. **External Managed Database (Production)** — Client responsibility (RDS snapshots, Cloud SQL backups, Azure managed backups)
4. **Recommended Schedule** — Backup frequency, retention policy
5. **Restore Procedure** — Pre-restore checklist (scale down, verify backup), restore steps
6. **Disaster Recovery** — Full cluster rebuild from backup + Helm values + image archive

**Source material:**
- PACKAGING-PLAN.md Section 2 (database strategy)
- CLI `backup-db` and `restore-db` command help text

---

### 8. UPGRADE.md (~200 lines)

**Sections:**
1. **Pre-Upgrade Checklist** — Backup, review changelog, dry-run migration, verify images available
2. **Standard Upgrade** — `biznez-cli upgrade -f values.yaml` workflow
3. **Air-Gapped Upgrade** — Import new images, update values, upgrade
4. **Rollback Procedure** — Helm rollback, DB considerations (migrations are forward-only)
5. **Breaking Changes** — How to check release notes, config-contract changes
6. **Migration During Upgrade** — Hook mode (automatic), manual mode (separate step)
7. **Canary / Blue-Green** — Not built-in; guidance for operators who want it

**Source material:**
- CLI `upgrade` command help text
- PACKAGING-PLAN.md Section 3 (rollback + migration interaction)

---

### 9. examples/eval-quickstart.yaml

Minimal eval values — copy-pasteable, no secrets (generated by CLI):

```yaml
global:
  profile: eval

backend:
  config:
    environment: development
    logLevel: info

postgres:
  enabled: true

migration:
  mode: auto

auth:
  mode: local
```

---

### 10. examples/production-minimal.yaml

Annotated production values with all required fields:

```yaml
global:
  profile: production
  requireDigests: true
  imageRegistry: "registry.example.com/biznez"
  imagePullSecrets:
    - name: regcred

backend:
  existingSecret: biznez-backend-secrets   # Must contain ENCRYPTION_KEY, JWT_SECRET_KEY

postgres:
  enabled: false
  external:
    host: db.example.com
    port: 5432
    database: biznez_platform
    sslMode: require
    existingSecret: biznez-db-credentials   # Must contain DATABASE_URL

auth:
  mode: oidc
  oidc:
    issuer: "https://idp.example.com"
    audience: "biznez-app"

migration:
  mode: manual

autoscaling:
  enabled: true

pdb:
  enabled: true

networkPolicy:
  enabled: true
```

---

## Implementation Order

1. **examples/** first (eval-quickstart.yaml, production-minimal.yaml) — docs reference these
2. **INSTALL.md** — Entry point for all operators, references examples
3. **PRODUCTION-CHECKLIST.md** — Complements INSTALL.md production section
4. **SECURITY.md** — Standalone for security/procurement reviews
5. **NETWORKING.md** — Standalone for network admins
6. **MIGRATION-GUIDE.md** — Standalone for DBA/operators
7. **OIDC-SETUP.md** — Standalone for identity admins
8. **BACKUP-RESTORE.md** — Standalone for operators
9. **UPGRADE.md** — Standalone for operators (references MIGRATION-GUIDE.md for DB)

---

## Cross-Reference Rules

- Each doc is **standalone** — no required reading order
- Cross-references use relative links: `[Production Checklist](PRODUCTION-CHECKLIST.md)`
- CLI commands shown with exact syntax matching `biznez-cli <command> --help`
- Values keys shown with dot notation matching `values.yaml` (e.g., `backend.existingSecret`)
- No hardcoded GCP, AWS, or cloud-specific references (cloud-agnostic examples only)
- No Biznez-internal references (no internal URLs, no internal team names)

---

## Verification

After implementation:
1. **No broken cross-references** — `grep -r '\[.*\](.*\.md)' docs/ | grep -v PACKAGING-PLAN | grep -v PHASES` and verify all targets exist
2. **No placeholder content** — `grep -rl 'Placeholder' docs/` returns nothing (except PACKAGING-PLAN.md and PHASES.md which are reference docs)
3. **Eval quick-start is copy-pasteable** — Follow INSTALL.md eval section verbatim on a clean kind cluster
4. **CLI commands match** — Every `biznez-cli` example in docs matches actual `--help` output
5. **Production checklist covers all guards** — Each of the 12 guards in `validate.yaml` has a corresponding checklist item
6. **No GCP/internal leaks** — `grep -ri 'gcloud\|googleapis\|gcr\.io\|pkg\.dev\|gke\.io' docs/` returns nothing
7. **shellcheck on code blocks** — bash code blocks use valid syntax
