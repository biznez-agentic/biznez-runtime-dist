# Plan: Package Biznez Agentic Runtime for Client Distribution

## Context

The Biznez Agentic Runtime is a production AI agent platform currently deployed on GKE. We need to package it so prospective clients can deploy it on their own infrastructure -- on-prem Kubernetes, GKE, EKS, AKS, or Docker Compose for evaluation.

The platform consists of 4 core services (Backend API, Frontend, PostgreSQL, Agent Gateway), optional add-ons (Langfuse, agents, MCP servers), and external SaaS dependencies (identity provider, LLM providers). Today everything is deployed via raw Kustomize manifests with environment-specific overlays and hardcoded GCP references.

**Design principles:**
- Zero cluster-scoped resources by default (namespaced only)
- Assume nothing about client infrastructure (no ingress controller, no cert-manager, no storage class)
- Embedded PostgreSQL for evaluation only; production requires external managed DB
- All secrets via `existingSecret` references; inline secrets only for eval
- Security-hardened by default (non-root, read-only rootfs, dropped capabilities)
- OIDC-first authentication; local JWT only as fallback for evaluation

---

## Platform Architecture Overview

```
                         Client Infrastructure
  ┌──────────────────────────────────────────────────────────────┐
  │                                                              │
  │   ┌─────────────────── Kubernetes Cluster ───────────────┐  │
  │   │                    (client-managed)                   │  │
  │   │                                                      │  │
  │   │  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │  │
  │   │  │ Frontend │  │ Backend  │  │  Agent Gateway   │  │  │
  │   │  │ (React/  │  │ (FastAPI │  │  (MCP Proxy)     │  │  │
  │   │  │  Nginx)  │  │  Python) │  │                  │  │  │
  │   │  │ Port: 80 │  │ Port:8000│  │  Port: 8080      │  │  │
  │   │  └──────────┘  └──────────┘  └──────────────────┘  │  │
  │   │                      │                               │  │
  │   │              ┌───────v───────┐                       │  │
  │   │              │  PostgreSQL   │  (eval only)          │  │
  │   │              │  OR external  │  (prod: managed DB)   │  │
  │   │              │  managed DB   │                       │  │
  │   │              └───────────────┘                       │  │
  │   │                                                      │  │
  │   │  Client-managed infrastructure:                      │  │
  │   │  - Ingress controller (nginx/ALB/istio/gateway API)  │  │
  │   │  - TLS termination (cert-manager/external LB)        │  │
  │   │  - Storage classes, network policies, PSA             │  │
  │   └──────────────────────────────────────────────────────┘  │
  └──────────────────────────────────────────────────────────────┘
                              │
                   External Services (client-managed)
           ┌──────────────────┼──────────────────┐
           │                  │                  │
     ┌─────v─────┐    ┌──────v─────┐    ┌───────v──────┐
     │  Identity  │    │    LLM     │    │ Observability│
     │  Provider  │    │  Provider  │    │  (optional)  │
     │ (any OIDC) │    │ (OpenAI/   │    │  (Langfuse)  │
     │            │    │ Anthropic) │    │              │
     └────────────┘    └────────────┘    └──────────────┘
```

---

## Approach: Helm Chart + Docker Compose + Installer CLI

### Why Helm
- Industry standard for distributing Kubernetes applications
- Single `values.yaml` for all configuration
- Upgrade/rollback built-in (`helm upgrade`, `helm rollback`)
- Works on GKE, EKS, AKS, and on-prem K8s identically

### Why Docker Compose (additionally)
- Quick evaluation without Kubernetes
- Laptop/VM deployment for demos and PoCs
- Lower barrier to entry for non-K8s clients

### Why Installer CLI
- Generates secrets (prints to stdout by default, `--write` to file)
- Validates prerequisites (`kubectl auth can-i`, helm, docker, PSA compatibility)
- Validates secrets exist and contain required keys
- Runs post-install health checks

---

## 1. Chart Design: Namespaced Only, Zero Cluster-Scoped Resources

The chart installs **only namespaced resources** by default. Cluster-scoped components (ingress controller, cert-manager, CRDs, ClusterRoles) are the client's responsibility.

### What the chart creates (namespaced):
- Deployments (backend, frontend, gateway)
- Services (ClusterIP)
- ConfigMaps
- Secrets (only if `existingSecret` not provided)
- StatefulSet (PostgreSQL, eval only)
- PVC (PostgreSQL, eval only)
- Jobs (migration, if mode=hook)
- ServiceAccount (or reference existing)
- Role + RoleBinding (or reference existing)
- HPA (optional)
- NetworkPolicy (optional)

### What the chart does NOT create:
- Namespace (off by default; client pre-creates)
- Ingress / Gateway API routes (optional, opt-in)
- ClusterRole / ClusterRoleBinding
- CRDs
- Cert-manager resources (references existing ClusterIssuer if provided)
- StorageClass

### Chart structure

```
deploy/helm/biznez-runtime/
  Chart.yaml
  values.yaml                    # Evaluation defaults
  values-production.yaml         # Production hardening
  templates/
    _helpers.tpl
    backend/
      deployment.yaml
      service.yaml
      configmap.yaml
      secret.yaml                # Conditional: skipped if existingSecret set
      hpa.yaml                   # Conditional: if autoscaling.enabled
      migration-job.yaml         # Conditional: if migration.mode == "hook"
    frontend/
      deployment.yaml
      service.yaml
      configmap.yaml
    postgres/                    # Conditional: if postgres.enabled
      statefulset.yaml
      service.yaml
      secret.yaml
      pvc.yaml
    gateway/                     # Conditional: if gateway.enabled
      deployment.yaml
      service.yaml
      configmap.yaml
      secret.yaml                # Gateway-specific secrets (MCP API keys)
    ingress.yaml                 # Conditional: if ingress.enabled
    networkpolicy.yaml           # Conditional: if networkPolicy.enabled
    rbac.yaml                    # Conditional: if rbac.create
    NOTES.txt
```

### RBAC: Create or Use Existing

```yaml
rbac:
  create: true                   # false = use existing serviceaccount
  serviceAccountName: ""         # If create=false, name of existing SA
  # When create=true, chart creates:
  #   ServiceAccount, Role (namespaced only), RoleBinding
  # NO ClusterRole or ClusterRoleBinding
```

---

## 2. Database Strategy: External for Production, Embedded for Eval Only

### Evaluation (default `values.yaml`)
```yaml
postgres:
  enabled: true                  # Embedded StatefulSet
  image: postgres:15-alpine
  storage: 10Gi
  storageClassName: ""           # Empty = use cluster default storage class
                                 # Set explicitly if no default: e.g., "standard", "gp2", "local-path"
                                 # Template omits storageClassName field when empty (uses cluster default)
  resources:
    requests: { cpu: 250m, memory: 512Mi }
    limits: { cpu: 1000m, memory: 1Gi }
```

**Storage class note:** Eval mode requires a working storage class for the PostgreSQL PVC.
If the cluster has a default storage class, leave `storageClassName` empty. If not, set it
explicitly. `biznez-cli validate --profile eval` warns if no default storage class is found
and `storageClassName` is empty.

### Production (`values-production.yaml`)
```yaml
postgres:
  enabled: false                 # DO NOT use embedded postgres

  external:
    host: "your-rds-instance.region.rds.amazonaws.com"
    port: 5432
    database: biznez_platform
    sslMode: require             # require | verify-ca | verify-full
    existingSecret: biznez-db-credentials
    # Secret must contain keys: POSTGRES_USER, POSTGRES_PASSWORD

  pool:
    size: 20                     # App-side pool (SQLAlchemy)
    maxOverflow: 10
    poolTimeout: 30
    poolRecycle: 1800            # Recycle connections every 30 min

  # Optional: PgBouncer sidecar
  pgbouncer:
    enabled: false               # Documented integration guide provided
    maxClientConn: 200
    defaultPoolSize: 25
    poolMode: transaction
```

### Backup/Restore

**Embedded PostgreSQL (eval):**
- `biznez-cli backup-db` -- runs `pg_dump` against in-cluster postgres
- `biznez-cli restore-db --file backup.sql` -- runs `pg_restore`

**External managed DB (production):**
- Backup is the client's responsibility (RDS snapshots, Cloud SQL backups, etc.)
- Document: recommended backup frequency, PITR, retention
- `biznez-cli` does not manage external DB credentials for backup

---

## 3. Database Migration Strategy: Multiple Modes

Migrations use Alembic. Three modes are supported to match client risk tolerance:

```yaml
migration:
  mode: manual                   # hook | initContainer | manual
  # manual     = client runs migrations explicitly (production default)
  # hook       = Helm pre-install/pre-upgrade Job (evaluation default)
  # initContainer = runs before backend pod starts (middle ground)
```

### Mode: `manual` (production default)
- Client runs: `biznez-cli migrate`
- Safest: no surprise migrations during deploys
- Supports staged rollouts and expand/contract patterns
- Document: zero-downtime migration guidelines

**How `biznez-cli migrate` works:**
- Creates a namespaced **Job** (not exec into a running pod)
- Job spec:
  - Uses the same backend image (`biznez/platform-api`)
  - **Shares the exact same env injection block as the backend Deployment** via a shared
    Helm template helper (`_helpers.tpl` defines `biznez.backend.envFrom` and `biznez.backend.envVars`)
    -- this ensures the migration job and backend container never drift in configuration
  - Same `envFrom` secretRef (or `existingSecret`) and same configMapRef as backend
  - Same DATABASE_URL construction logic (from configmap + secret)
  - Command: `python -m agentic_runtime.db.migration_runner` wrapping `alembic upgrade head`
    with advisory lock (see section below)
  - Module lives at `src/agentic_runtime/db/migration_runner.py` inside the backend image
    (proper package path, not ad-hoc import)
  - `restartPolicy: Never`
  - `ttlSecondsAfterFinished: 300` (auto-cleanup). Configurable via `migration.jobTtlSeconds`.
    Set to `null` to omit the field entirely (for clusters where TTL controller is disabled).
    When TTL is omitted, `biznez-cli migrate` prints a cleanup command:
    `kubectl delete job biznez-migration -n biznez`
  - `backoffLimit: 1` (fail fast for manual mode)
  - `activeDeadlineSeconds: 600`
  - Job pod runs under the **same ServiceAccount as the backend** (or a dedicated migration SA
    if `rbac.migrationServiceAccount` is set). The Job pod itself does NOT require any
    Kubernetes API server permissions -- it only needs network access to PostgreSQL.
    The CLI user (human or CI service account running `biznez-cli migrate`) needs these
    permissions in the namespace: `create jobs`, `get jobs`, `get pods`, `get pods/log`.
- Works in restricted PSA environments (same security context as backend)
- No shell access or running pod required

**RBAC for migration operators:** In enterprise environments, the person running migrations
may not be the same as the person running `helm install`. The chart optionally renders a
dedicated Role/RoleBinding for migration operators:
```yaml
rbac:
  migrationOperator:
    enabled: false               # Set true to create migration-specific Role
    subjects: []                 # Users/groups/SAs who can run migrations
    # Example:
    # - kind: User
    #   name: migration-operator@client.com
    # - kind: Group
    #   name: biznez-operators
```
When enabled, creates a Role with: `create/get/delete jobs`, `get pods`, `get pods/log`
in the release namespace. This is the minimum permission set for `biznez-cli migrate`.

**Alternative: Helm-driven migrations in production.** Some enterprises prefer all changes
via Helm (no separate CLI step). `migration.mode: hook` is allowed in production if the
client explicitly sets it. Template guards do NOT block hook mode in production -- the
choice between hook and manual is a client policy decision, not a security constraint.
Document tradeoffs in PRODUCTION-CHECKLIST:
- hook: simpler CI, but migrations run automatically on every upgrade
- manual: explicit control, requires separate RBAC grant for migration operators

**`biznez-cli migrate` workflow:**
1. Renders the migration Job YAML from the Helm template
2. Applies Job to the namespace via `kubectl apply`
3. Streams Job pod logs in real-time (`kubectl logs -f`)
4. Waits for Job completion (success or failure)
5. Reports exit status; Job auto-deletes after TTL

**`biznez-cli migrate --dry-run` workflow:**
1. Creates Job with command `python -m agentic_runtime.db.migration_runner --dry-run` (outputs SQL, does not execute)
2. Streams logs (the SQL statements)
3. Deletes Job immediately after log capture (or lets TTL clean up)

### Advisory Lock Strategy (all modes)

All migration modes use the same lock wrapper (`agentic_runtime.db.migration_runner` module in backend image):

```python
# Pseudocode for agentic_runtime.db.migration_runner
# Uses bigint form: pg_try_advisory_lock(bigint) -- single key, no two-int confusion
LOCK_ID = 738291456  # Documented constant (bigint)
conn = create_engine(DATABASE_URL, pool_size=1, max_overflow=0)  # Single dedicated connection, no pool
with conn.connect() as raw_conn:
    acquired = False
    for attempt in range(30):  # 30 retries, 2s apart = 60s max wait
        acquired = raw_conn.execute(text("SELECT pg_try_advisory_lock(:id)"), {"id": LOCK_ID}).scalar()
        if acquired:
            break
        logger.info(f"Migration lock held by another process, retrying ({attempt+1}/30)...")
        time.sleep(2)
    if not acquired:
        raise RuntimeError("Could not acquire migration lock after 60s")
    try:
        alembic_upgrade_head()
    finally:
        raw_conn.execute(text("SELECT pg_advisory_unlock(:id)"), {"id": LOCK_ID})
```

Key properties:
- Uses `pg_try_advisory_lock(bigint)` (non-blocking, single-key form) with retries + timeout,
  NOT `pg_advisory_lock` (blocking). The bigint variant maps cleanly to a single constant
  and avoids the two-integer `(classid, objid)` confusion of the `(int, int)` variant.
- Runs on a **single dedicated connection** (`pool_size=1, max_overflow=0`) -- no pooling
- Lock ID `738291456` is a documented constant (bigint). Operators can inspect advisory locks via:
  ```sql
  -- List all advisory locks currently held:
  SELECT pid, granted,
         ((classid::bigint << 32) | objid::bigint) AS lock_key
  FROM pg_locks
  WHERE locktype = 'advisory';

  -- Is the specific migration lock (738291456) held?
  -- For bigint advisory locks, the key is encoded across classid and objid:
  --   classid = (key >> 32)    -- upper 32 bits
  --   objid   = (key & 4294967295)  -- lower 32 bits
  WITH x AS (
    SELECT
      (738291456::bigint >> 32)::integer AS classid,
      (738291456::bigint & 4294967295)::integer AS objid
  )
  SELECT l.pid, l.granted
  FROM pg_locks l, x
  WHERE l.locktype = 'advisory'
    AND l.classid = x.classid
    AND l.objid = x.objid;
  ```
- Lock is explicitly released in `finally` block; also auto-releases if process crashes (session-level lock)
- Logs when waiting, so operators can see contention

### Mode: `hook` (evaluation default)
- Helm pre-install/pre-upgrade Job
- Job includes:
  - `ttlSecondsAfterFinished: 300`
  - `backoffLimit: 3`
  - `activeDeadlineSeconds: 600`
  - Advisory lock via `agentic_runtime.db.migration_runner` (see above)
  - `helm.sh/hook-delete-policy: before-hook-creation` to clean up old jobs

### Mode: `initContainer`
- Backend pod has init container that runs `python -m agentic_runtime.db.migration_runner`
- Uses same advisory lock to prevent races when multiple replicas start
- Blocks pod startup until migration completes

### Helm Rollback and Database Migrations

**Critical: Helm rollback does NOT reverse database migrations.** Alembic migrations are forward-only
by design. This has implications:

- `helm rollback` reverts Kubernetes resources (deployments, configmaps) but NOT the database
- If a migration added a column, rolling back the app code means the column still exists
- If a migration removed a column, rolling back the app code means it expects a column that's gone

**Documented guidance (in UPGRADE.md and NOTES.txt):**
1. **Before upgrade:** Always run `biznez-cli backup-db` (eval) or take a managed DB snapshot (prod)
2. **Rollback procedure:**
   - `helm rollback biznez <revision>` reverts app code
   - If migration was additive (new columns/tables): safe to rollback app, unused columns are harmless
   - If migration was destructive (dropped columns): restore from DB backup is required
3. **Expand/contract pattern eliminates this risk** -- never drop columns in the same release
4. **Migration pre-check:** `biznez-cli migrate --dry-run` shows pending SQL before applying
5. **Helm history:** `helm history biznez -n biznez` shows revision history for rollback targets

### Zero-Downtime Migration Guidelines (documented)
- **Expand**: Add new columns/tables (nullable, with defaults)
- **Migrate**: Backfill data in background
- **Contract**: Remove old columns in next release
- Never rename or drop columns in the same release as code changes

---

## 4. Secrets Management: existingSecret Everywhere

### Principle
Every component that needs secrets supports two modes:
1. **`existingSecret`** -- reference a pre-created K8s Secret (production)
2. **Inline values** -- chart creates the Secret (evaluation only)

### values.yaml structure

```yaml
backend:
  existingSecret: ""             # K8s Secret name with all backend secrets
  # If empty, chart creates Secret from inline values below:
  secrets:
    encryptionKey: ""            # Fernet key (auto-generated if empty)
    jwtSecret: ""                # JWT signing key (auto-generated if empty)

postgres:
  existingSecret: ""             # Must contain: POSTGRES_USER, POSTGRES_PASSWORD
  secrets:
    user: biznez
    password: ""                 # Auto-generated if empty

llm:
  existingSecret: ""             # Must contain: LLM_API_KEY
  secrets:
    apiKey: ""

langfuse:
  existingSecret: ""             # Must contain: LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY
  secrets:
    publicKey: ""
    secretKey: ""

auth:
  existingSecret: ""             # Must contain: AUTH_CLIENT_SECRET (if OIDC)
```

### Secret key requirements (documented per component)

| Secret Reference | Required Keys |
|-----------------|---------------|
| `backend.existingSecret` | `ENCRYPTION_KEY`, `JWT_SECRET_KEY` |
| `postgres.existingSecret` | `POSTGRES_USER`, `POSTGRES_PASSWORD` |
| `llm.existingSecret` | `LLM_API_KEY` |
| `langfuse.existingSecret` | `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` |
| `auth.existingSecret` | `AUTH_CLIENT_SECRET` (OIDC only) |
| `gateway.existingSecret` | User-defined (must match `${VAR}` refs in gateway config) |

### Secret injection strategy: explicit env per component

The app reads all secrets from environment variables (`os.getenv`). The Helm chart injects
secrets as env vars. **The injection method differs by component:**

**Backend, postgres:** Use **explicit `env` entries with `valueFrom.secretKeyRef`**
for each required key. This is intentional:
- `validate-secrets` can check each key exists at render time (vs opaque envFrom blob)
- Only required keys are injected -- no unused keys leaked into the environment
- Adding a new required key in a future release is a visible chart change (not silently missing)
- Template example:
  ```yaml
  env:
    - name: ENCRYPTION_KEY
      valueFrom:
        secretKeyRef:
          name: {{ .Values.backend.existingSecret | default (include "biznez.backendSecretName" .) }}
          key: ENCRYPTION_KEY
    - name: JWT_SECRET_KEY
      valueFrom:
        secretKeyRef:
          name: {{ .Values.backend.existingSecret | default (include "biznez.backendSecretName" .) }}
          key: JWT_SECRET_KEY
  ```

**Gateway:** Uses **`envFrom`** to inject the entire secret as env vars. This is correct for
gateway because keys are user-defined and arbitrary (must match `${VAR}` refs in gateway config).
There is no fixed set of required keys to validate at the template level.

**Frontend:** Does NOT receive any secrets. Frontend is nginx serving static assets -- it
consumes only non-secret configuration (API base URL, feature flags) via ConfigMap-backed
environment substitution in the nginx config or build-time `window.__ENV__` injection.
No `existingSecret`, no `secretKeyRef`, no `envFrom` for secrets. If secrets appear in the
frontend pod, that is a security defect (secrets would be visible in the browser).

Both inline and `existingSecret` modes (for backend/postgres/gateway) inject the same env
vars -- the only difference is who creates the K8s Secret object (chart vs client).

**Why env vars (not files):**
- Zero app code changes required for v1
- Works identically across eval and production
- Compatible with External Secrets Operator, Sealed Secrets, SOPS (all create K8s Secrets that inject as env vars)

**Known risk: env var leakage.** Secrets injected as env vars are visible via:
- `kubectl exec <pod> -- env` (requires exec permission)
- `/proc/<pid>/environ` inside the container
- Process crash dumps that include environment
- `kubectl describe pod` does NOT expose values directly (only names), but container runtimes
  may log them in error scenarios

**Mitigations (defense-in-depth, no single one is sufficient):**
- RBAC: restrict `get secrets`, `exec pods`, and `get pods` permissions to operators only
- Pod Security Admission: `restricted` profile prevents privileged access
- Network policies: limit who can reach the API server
- Audit logging: enable K8s audit log for secret access events
- **v2 (file-based secrets) eliminates this class of risk entirely**

**Future (v2):** Add optional file-based secret loading with precedence (file > env):
- Requires adding `load_secret()` helper to `src/agentic_runtime/core/config.py`
- Files at `/etc/biznez/secrets/<KEY_NAME>` (one file per key)
- Helm chart mounts Secret as volume instead of envFrom
- Benefits: avoids env leakage entirely, supports binary secrets

### CLI commands

```bash
biznez-cli generate-secrets              # Prints to stdout (pipe to kubectl create secret)
biznez-cli generate-secrets --write      # Writes to biznez-secrets.yaml (explicit opt-in)
biznez-cli validate-secrets              # Checks all existingSecret refs contain required keys
```

### Key Rotation Guidance (documented)

| Key | Rotation Impact | Procedure |
|-----|----------------|-----------|
| `JWT_SECRET_KEY` | Invalidates all active sessions | Rolling restart; users must re-login |
| `ENCRYPTION_KEY` | Cannot decrypt existing data | Requires planned maintenance (see below) |

**ENCRYPTION_KEY rotation (v1 -- write-once with maintenance window):**

The app has a `KeyManagementService` (`src/agentic_runtime/core/security/key_management.py`)
and `EncryptionService.rotate_key()` (`src/agentic_runtime/core/security/encryption.py`),
but these are not production-ready for K8s (uses local JSON registry file, no multi-key
decryption at runtime).

**v1 approach:** Encryption key is write-once. Rotation requires a planned maintenance window:
1. Scale backend to 0 replicas
2. Run `biznez-cli rotate-encryption-key --old-key <old> --new-key <new>` (batch re-encrypts all encrypted fields in DB)
3. Update the K8s Secret with new key
4. Scale backend back up
5. Document: which DB columns are encrypted (`Secret.encrypted_value`, connector credentials)

**v2 (future):** Runtime multi-key decryption (keyring), automated rotation without downtime

---

## 4b. Configuration Contract: Values to Env Vars / ConfigMap Keys

The backend reads configuration from environment variables. The Helm chart translates
`values.yaml` fields into a ConfigMap (non-secret config) and Secret (sensitive config).
This mapping is a **strict contract** -- incorrect keys cause silent runtime failures,
not Helm errors.

### Backend ConfigMap keys (non-secret)

| values.yaml Path | ConfigMap Key | Default | Notes |
|-----------------|--------------|---------|-------|
| `backend.config.environment` | `ENVIRONMENT` | `production` | `development` / `production` |
| `backend.config.logLevel` | `LOG_LEVEL` | `INFO` | `DEBUG` / `INFO` / `WARNING` / `ERROR` |
| `backend.config.corsOrigins` | `CORS_ORIGINS` | (see derivation below) | Comma-separated URLs |
| `backend.config.frontendUrl` | `FRONTEND_URL` | (see derivation below) | Used for CORS, redirects |
| `backend.config.apiUrl` | `API_BASE_URL` | (see derivation below) | Public backend URL |
| `gateway.baseUrl` | `AGENT_GATEWAY_URL` | `http://biznez-gateway:8080` | In-cluster gateway URL |
| `auth.mode` | `AUTH_MODE` | `local` | `local` / `oidc` / `dual` |
| `auth.oidc.issuer` | `OIDC_ISSUER` | (empty) | OIDC discovery base URL |
| `auth.oidc.audience` | `OIDC_AUDIENCE` | (empty) | Token audience claim |
| `auth.oidc.jwksUrl` | `OIDC_JWKS_URL` | (derived from issuer) | Override if issuer != JWKS host |
| `auth.oidc.claims.subject` | `OIDC_SUBJECT_CLAIM` | `sub` | Claim for user ID |
| `auth.oidc.claims.email` | `OIDC_EMAIL_CLAIM` | `email` | Claim for email |
| `langfuse.enabled` | `LANGFUSE_ENABLED` | `false` | Enable observability |
| `langfuse.host` | `LANGFUSE_HOST` | `https://cloud.langfuse.com` | Langfuse server URL |
| `postgres.pool.size` | `DB_POOL_SIZE` | `5` | SQLAlchemy pool size |
| `postgres.pool.maxOverflow` | `DB_MAX_OVERFLOW` | `10` | Pool overflow connections |
| `postgres.pool.poolRecycle` | `DB_POOL_RECYCLE` | `1800` | Connection recycle seconds |

**Public URL derivation rules:**

`FRONTEND_URL`, `API_BASE_URL`, and `CORS_ORIGINS` are derived with this precedence:
1. Explicit value in `values.yaml` (always wins)
2. Derived from `ingress.hosts` when `ingress.enabled: true`
3. Eval defaults when ingress is disabled:
   - `FRONTEND_URL`: `http://localhost:8080` (matches port-forward default)
   - `API_BASE_URL`: `http://localhost:8000`
   - `CORS_ORIGINS`: `http://localhost:8080` (allows frontend to call backend)

If a client uses NodePort or LoadBalancer instead of port-forward, they MUST set these
explicitly (the chart cannot guess the external IP). NOTES.txt prints the values in use
and warns if they appear to be defaults.

The backend tolerates empty `CORS_ORIGINS` by defaulting to allow-all in `development`
environment mode, but requires explicit origins in `production`.

### Backend Secret keys (sensitive)

| values.yaml Path | Secret Key | Source |
|-----------------|-----------|--------|
| `backend.secrets.encryptionKey` | `ENCRYPTION_KEY` | `backend.existingSecret` or inline |
| `backend.secrets.jwtSecret` | `JWT_SECRET_KEY` | `backend.existingSecret` or inline |
| `llm.secrets.apiKey` | `LLM_API_KEY` | `llm.existingSecret` or inline |
| `langfuse.secrets.publicKey` | `LANGFUSE_PUBLIC_KEY` | `langfuse.existingSecret` or inline |
| `langfuse.secrets.secretKey` | `LANGFUSE_SECRET_KEY` | `langfuse.existingSecret` or inline |

### DATABASE_URL construction

The backend expects `DATABASE_URL` as a single connection string. The chart constructs it from:
```
postgresql://{POSTGRES_USER}:{POSTGRES_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}?sslmode={SSL_MODE}
```
Where:
- `DB_HOST` = `biznez-postgres` (embedded) or `postgres.external.host` (external)
- `DB_PORT` = `5432` or `postgres.external.port`
- `DB_NAME` = `biznez_platform` or `postgres.external.database`
- `SSL_MODE` = `disable` (embedded) or `postgres.external.sslMode`
- Credentials from postgres secret

This is rendered in the ConfigMap/Secret, NOT passed as separate env vars for the URL components.

**Full URL override:** For edge cases (sslrootcert, statement_timeout, IAM auth tokens,
pgbouncer connection strings), clients can bypass construction entirely:
```yaml
postgres:
  external:
    databaseUrl: "postgresql://user:pass@host:5432/db?sslmode=verify-full&sslrootcert=/etc/ssl/rds-ca.pem&options=-c statement_timeout=30000"
```
When `postgres.external.databaseUrl` is set, it takes precedence over all individual fields
(`host`, `port`, `database`, `sslMode`). The value is injected as `DATABASE_URL` directly.
This is the escape hatch for any connection string parameter the chart doesn't model.

---

## 5. Identity / Auth: OIDC-First, Local JWT for Eval Only

### Production: OIDC Required

```yaml
auth:
  mode: oidc                     # Production: OIDC only
  oidc:
    issuer: "https://idp.client.com"
    audience: "biznez-app"
    jwksUrl: ""                  # Auto-derived from issuer if empty
    jwksCacheTtl: 3600           # 1 hour
    clockSkewSeconds: 30         # Tolerance for token validation

    # Claim mapping
    claims:
      subject: sub               # Unique user identifier
      email: email
      name: name
      groups: groups             # For role mapping

    # Role mapping from OIDC groups/claims
    roleMapping:
      adminGroups:               # Groups that get admin role
        - "biznez-admins"
        - "platform-admins"
      userGroups:                 # Groups that get user role
        - "biznez-users"

    # Domain restrictions
    allowedEmailDomains: []      # Empty = all domains allowed
    # Example: ["client.com", "partner.com"]
```

### Evaluation: Local JWT

```yaml
auth:
  mode: local                    # Built-in user/password (eval only)
  local:
    # WARNING: Not recommended for production
    # - No MFA support
    # - Basic bcrypt password hashing (12 rounds)
    # - Account lockout: 5 attempts, 15-min lockout
    # - No external audit trail
    adminBootstrap:
      email: admin@biznez.local
      # Password auto-generated, printed in NOTES.txt
```

### Dual Mode

```yaml
auth:
  mode: dual                     # Local + OIDC (transition period only)
  # Precedence: OIDC token validated first, falls back to local JWT
  # WARNING: dual mode widens attack surface; use only during migration
```

### What is documented for each mode

- Password policy (local): min 12 chars, complexity requirements, rotation
- MFA: not supported in local mode; require OIDC provider for MFA
- Admin bootstrap: first-run admin account creation
- Role mapping: how OIDC claims/groups map to platform roles (admin, user, viewer)
- Multi-tenant: workspace isolation, org-scoped RBAC
- Audit: all auth events logged (login, logout, failed attempts, token refresh)

---

## 6. Container Image Distribution: Deterministic Manifests with Digests

### Image Manifest (`images.lock`)

Every release includes a lockfile with pinned digests:

```yaml
# images.lock -- DO NOT EDIT (generated by biznez-cli build-release)
version: "1.0.0"
images:
  # Each entry uses the full source repository ref for unambiguous pull/retag.
  # `repository` is the full source (where biznez-cli export-images pulls from).
  # `shortName` is the local name used in values.yaml image.repository fields.
  - shortName: biznez/platform-api
    repository: "biznez/platform-api"
    tag: "1.0.0"
    digest: "sha256:abc123..."
    platform: linux/amd64
  - shortName: biznez/web-app
    repository: "biznez/web-app"
    tag: "1.0.0"
    digest: "sha256:def456..."
    platform: linux/amd64
  - shortName: agentgateway
    repository: "ghcr.io/agentgateway/agentgateway"
    tag: "0.1.0"
    digest: "sha256:789abc..."
    platform: linux/amd64
  - shortName: postgres
    repository: "docker.io/library/postgres"
    tag: "15-alpine"
    digest: "sha256:xyz789..."
    platform: linux/amd64
```

The `repository` field is the full source ref used by `export-images` to pull.
The `shortName` field maps to `values.yaml` image repository fields.
On `import-images`, each image is retagged to `{client-registry}/{shortName}:{tag}`.

### Image ownership and third-party images

The archive includes **all** images required to run the platform, both Biznez-built and
third-party:

| Image | Source | Owned By |
|-------|--------|----------|
| `biznez/platform-api` | Built from `Dockerfile` | Biznez |
| `biznez/web-app` | Built from `frontend/Dockerfile` | Biznez |
| `postgres:15-alpine` | Docker Hub official image | Third-party (PostgreSQL) |
| `ghcr.io/agentgateway/agentgateway` | GitHub Container Registry | Third-party (Agent Gateway project) |

**All images, including third-party, are bundled in `biznez-images-*.tar.gz`** and re-tagged
to the client's registry on import. This ensures air-gapped installs work without external
registry access.

**The Helm chart supports overriding the repository for every image**, including postgres and
agentgateway, via `global.imageRegistry` prefix or per-component `image.repository` overrides:

```yaml
# global.imageRegistry prepends to all image references:
global:
  imageRegistry: "registry.client.com/biznez"
  # Results in: registry.client.com/biznez/biznez/platform-api:1.0.0
  #             registry.client.com/biznez/postgres:15-alpine
  #             registry.client.com/biznez/agentgateway:0.1.0

# Or override individually:
postgres:
  image:
    repository: "registry.client.com/mirrors/postgres"  # Full override
    tag: "15-alpine"
```

### Export/Import workflow

```bash
# Export: saves ALL images (Biznez + third-party) from images.lock as OCI archives
biznez-cli export-images \
  --manifest images.lock \
  --output biznez-images-v1.0.0.tar.gz

# Import: loads into client registry, retags all images (including third-party)
biznez-cli import-images \
  --archive biznez-images-v1.0.0.tar.gz \
  --registry registry.client.com/biznez

# Verify: optional cosign verification
biznez-cli verify-images \
  --manifest images.lock \
  --registry registry.client.com/biznez
```

### Platform support

**v1: `linux/amd64` only.** All images in `images.lock` are single-platform `linux/amd64`.
Multi-arch (`linux/arm64`) support is a v2 item requiring:
- Multi-arch Docker builds (`docker buildx build --platform linux/amd64,linux/arm64`)
- OCI image index (manifest list) in `images.lock`
- Tested CI pipeline for ARM builds

The `images.lock` `platform` field and the archive contents must be consistent:
both specify `linux/amd64` for v1.

### Release artifacts (per version)

| Artifact | Purpose |
|----------|---------|
| `biznez-images-v1.0.0.tar.gz` | OCI image archive (`linux/amd64`) |
| `images.lock` | Deterministic image manifest with digests (`linux/amd64`) |
| `sbom-v1.0.0.json` | SBOM (Syft, SPDX format) |
| `trivy-report-v1.0.0.json` | Vulnerability scan report (Trivy, all images) |
| `biznez-images-v1.0.0.sig` | Cosign signatures (see signing modes below) |
| `checksums.sha256` | SHA-256 checksums of all artifacts |

### Artifact signing and verification

Three signing modes are supported, documented in SECURITY.md so procurement teams can
assess before deployment:

| Mode | What's Signed | How | Client Verification |
|------|--------------|-----|---------------------|
| **Unsigned (minimum)** | Nothing | `checksums.sha256` provides integrity only (no authenticity) | `sha256sum -c checksums.sha256` |
| **Cosign key-pair (recommended)** | Container images + archive | Cosign with Biznez-owned key pair. Public key shipped with release. | `cosign verify --key biznez-cosign.pub <image>` |
| **Cosign keyless (OIDC)** | Container images + archive | Cosign keyless with Fulcio + Rekor (requires Sigstore infrastructure). Signatures tied to Biznez CI identity. | `cosign verify --certificate-identity=ci@biznez.io --certificate-oidc-issuer=https://token.actions.githubusercontent.com <image>` |

**Helm chart provenance (optional):** `helm package --sign` produces a `.prov` file. Clients
verify with `helm verify`. This is supplementary to image signing and adds chart-level
tamper detection.

**v1 default:** Cosign key-pair signing. All images in `images.lock` are signed during
`biznez-cli build-release`. `biznez-cli verify-images` runs cosign verification against the
client's registry after import.

### Helm values: digest pinning

```yaml
global:
  imageRegistry: "registry.client.com/biznez"
  imagePullSecrets:
    - name: regcred

backend:
  image:
    repository: biznez/platform-api
    tag: "1.0.0"
    digest: ""                   # If set, overrides tag (recommended for prod)
    pullPolicy: IfNotPresent     # Always for :latest, IfNotPresent for tagged
```

---

## 7. Ingress and Networking: Multiple Exposure Patterns

The chart does NOT install an ingress controller. Three exposure patterns are supported:

### Pattern A: Ingress (nginx reference)

```yaml
ingress:
  enabled: true
  className: nginx               # Client's ingress class
  annotations: {}                # Client adds their own annotations

  # Ingress rendering mode:
  #   multiHost (default): all hosts in a single Ingress resource
  #   splitByHost: one Ingress resource per host entry (for orgs that require
  #     separate WAF policies, annotations, or ingress classes per app)
  mode: multiHost                # multiHost | splitByHost

  hosts:
    - host: api.biznez.example.com
      paths:
        - path: /
          service: backend
          port: 8000
      # Per-host overrides (only used when mode=splitByHost):
      # className: nginx-internal   # Override global className for this host
      # annotations: {}             # Merge with global annotations
    - host: app.biznez.example.com
      paths:
        - path: /
          service: frontend
          port: 80
  tls:
    enabled: true
    mode: existingSecret         # existingSecret | certManager
    # Mode: existingSecret -- client pre-provisions TLS cert
    #   Requires: secretName (must exist in namespace)
    #   No cert-manager annotations added
    secretName: biznez-tls
    # Mode: certManager -- cert-manager issues cert automatically
    #   Requires: clusterIssuer (must exist in cluster)
    #   Chart adds cert-manager.io annotations to Ingress
    #   secretName is auto-derived from host if not set
    clusterIssuer: ""            # e.g., "letsencrypt-prod"
```

**Validation:** Chart template fails with clear error if:
- `mode: existingSecret` but `secretName` is empty
- `mode: certManager` but `clusterIssuer` is empty
- Both `secretName` and `clusterIssuer` are set (ambiguous)

### Pattern B: Gateway API (future-proof)

**Prerequisite:** Gateway API CRDs must be installed in the cluster. These are often
pre-installed on newer clusters (GKE 1.26+, EKS with Gateway API controller), but are
NOT guaranteed. The chart will NOT install Gateway API CRDs.

**Early failure enforcement:** When `gatewayApi.enabled: true`, the chart template checks
for CRD availability via `.Capabilities.APIVersions.Has "gateway.networking.k8s.io/v1"`
and calls `{{ fail }}` if missing. This ensures `helm install` fails immediately with a
clear error rather than silently rendering resources the API server will reject at apply time.
(`helm template` without a live cluster cannot check Capabilities -- the check fires on
`helm install` / `helm upgrade` only.)

Install Gateway API CRDs via your cluster's approved method (air-gapped mirror, internal
artifact repo, or vendor add-on). Upstream source-of-truth for reference:
`https://github.com/kubernetes-sigs/gateway-api/releases/` -- do NOT `kubectl apply` from
the internet in environments with procurement/security restrictions.

```yaml
gatewayApi:
  enabled: false                 # Opt-in
  gatewayRef:
    name: main-gateway           # Client's existing Gateway resource
    namespace: gateway-system
  httpRoutes:
    - hostname: api.biznez.example.com
      service: backend
    - hostname: app.biznez.example.com
      service: frontend
```

### Pattern C: No Ingress (eval default -- ClusterIP + port-forward)

```yaml
ingress:
  enabled: false                 # Default for eval profile

backend:
  service:
    type: ClusterIP              # Default. Use port-forward to access.
    # Overridable to LoadBalancer or NodePort:
    # type: LoadBalancer
    # type: NodePort
    # nodePort: 30800            # if NodePort
    annotations: {}              # e.g., AWS ALB annotations

frontend:
  service:
    type: ClusterIP              # Default. Use port-forward to access.
```

Access: `kubectl port-forward svc/biznez-backend 8000:8000` (see eval quick-start above).

### Timeout and streaming configuration

Agent execution uses SSE (Server-Sent Events) for real-time streaming. This requires specific
configuration at the ingress/LB layer to prevent premature connection termination.

```yaml
backend:
  streaming:
    # Critical for agent execution streaming (SSE)
    proxyReadTimeout: 300        # seconds -- must exceed longest agent execution
    proxySendTimeout: 300
    proxyBuffering: "off"        # Required for SSE (prevents buffering partial events)
    maxBodySize: 10m

ingress:
  # Explicit opt-in for nginx streaming annotations.
  # Do NOT auto-detect from className (className values vary: "nginx", "nginx-internal",
  # "ingress-nginx", "k8s.io/ingress-nginx", etc.). Auto-detection causes false positives
  # that ship nginx-specific annotations to non-nginx controllers (harmless but confusing).
  applyNginxStreamingAnnotations: false  # Set true if using nginx-ingress controller
```

**Per-ingress-controller behavior:**

When `ingress.applyNginxStreamingAnnotations: true`, the chart adds nginx-specific annotations
(`proxy-read-timeout`, `proxy-send-timeout`, `proxy-buffering`). For other controllers/LBs,
the client must configure equivalent settings via `ingress.annotations` or their controller's
native configuration:

| Controller | Key Settings | Notes |
|-----------|-------------|-------|
| **nginx-ingress** | `proxy-read-timeout`, `proxy-send-timeout`, `proxy-buffering` | Chart applies annotations when `applyNginxStreamingAnnotations: true`. WebSocket upgrade headers are automatic. |
| **AWS ALB** | `idle_timeout.timeout_seconds` (target group attr) | Default is 60s -- **must** increase for SSE. Set via `alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=300`. Target group stickiness may be needed for long-lived connections. |
| **GCE/GKE Ingress** | Backend service timeout | Default 30s. Set via BackendConfig CRD `spec.timeoutSec: 300`. **Requires BackendConfig CRD** (GKE add-on; not available on non-GKE clusters). If CRD is absent, configure timeout via load balancer settings directly. |
| **Gateway API** | Implementation-dependent | Timeouts configured via HTTPRoute `timeouts.request` field (if supported by implementation). |
| **Istio** | VirtualService `timeout` | Set `timeout: 300s` on the route. |

**`biznez-cli validate` streaming check:** When ingress is enabled, validate warns if it
detects ALB controller annotations without an explicit idle timeout override.

**Documented in NETWORKING.md:** Full streaming requirements per common ingress/LB, including
WebSocket upgrade configuration (typically automatic but some older controllers need explicit
`connection-proxy-header` or `use-regex` annotations).

### Network Policies (optional)

```yaml
networkPolicy:
  enabled: false                 # Opt-in
  # When enabled, creates NetworkPolicy resources per component:
  #
  # Ingress rules (who can reach each service):
  # - Backend: allow from frontend (same namespace), gateway (same namespace)
  # - Frontend: allow from ingress namespace (configurable)
  # - PostgreSQL: allow from backend only (same namespace)
  # - Gateway: allow from backend (same namespace)
  #
  # Egress rules (where each service can connect):
  # - Backend → postgres (same namespace), LLM provider CIDRs, OIDC issuer CIDRs
  # - Frontend → backend (same namespace) only
  # - PostgreSQL → deny all egress (no outbound needed)
  # - Gateway → MCP target CIDRs/namespaces

  ingress:
    namespaceSelector: {}        # Restrict which namespaces can reach services
    # Example: { matchLabels: { "kubernetes.io/metadata.name": "ingress-nginx" } }

  egress:
    # DNS egress (see parameterization note below)
    dns:
      namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchExpressions:
          - key: k8s-app
            operator: In
            values: ["kube-dns", "coredns"]
      # IMPORTANT: NetworkPolicy requires explicit protocol per port.
      # Omitting protocol defaults to TCP only, which breaks DNS.
      # Template MUST render two port entries:
      ports:
        - port: 53
          protocol: UDP          # Primary DNS transport
        - port: 53
          protocol: TCP          # DNS over TCP (large responses, zone transfers)
        # Optional: uncomment if clients scrape CoreDNS metrics
        # - port: 9153
        #   protocol: TCP        # CoreDNS Prometheus metrics
      # NOTE: DNS selectors vary across clusters. Defaults target standard
      # kube-system/kube-dns and kube-system/coredns. If the client uses
      # node-local-dns or a custom DNS setup, override these selectors.
      # `biznez-cli validate --profile production` checks if coredns/kube-dns
      # exists and reports the correct selector to use.

    # Client-provided CIDRs for external services.
    # WARNING: Many SaaS endpoints (OpenAI, Anthropic, etc.) use CDN/anycast IPs
    # that are NOT stable. Do NOT attempt to resolve hostnames to CIDRs --
    # they will change without notice and break connectivity.
    #
    # Realistic egress strategies (choose one):
    #
    # Option A (recommended): Allow all HTTPS egress (pragmatic default)
    #   Set allowAllHttps: true
    #   Simple, works with any SaaS provider, no maintenance burden.
    #
    # Option B: Corporate proxy / egress gateway
    #   Route all outbound traffic through a corporate proxy or NAT gateway.
    #   Set cidrs to the proxy/gateway IP only. Filtering happens upstream.
    #   cidrs: ["10.0.0.50/32"]  # Corporate proxy
    #
    # Option C: FQDN-based policies (requires Cilium or vendor tooling)
    #   Standard Kubernetes NetworkPolicy does NOT support hostnames/FQDNs.
    #   Cilium CiliumNetworkPolicy, Calico NetworkPolicy, or cloud-vendor
    #   equivalents support FQDN-based egress rules. If the client uses
    #   one of these, configure their native policy format instead.
    #
    # Option D: Client-provided stable CIDRs
    #   Only for services with documented stable IP ranges (rare).
    #   Client is responsible for keeping CIDRs current.

    # Option B: Corporate proxy / egress gateway (explicit field)
    proxy:
      cidrs: []                  # CIDRs of corporate proxy or NAT/egress gateway
      # Example: ["10.0.0.50/32"]
      # NetworkPolicy allows egress ONLY to these CIDRs. But NetworkPolicy alone
      # doesn't route traffic -- it only allows/denies. The application must also
      # be configured to USE the proxy via standard env vars (see below).
      ports: [3128, 443]         # Common proxy ports (Squid: 3128, HTTPS: 443)

      # Proxy env vars -- injected into backend and gateway containers when set.
      # BOTH are required: NetworkPolicy (allows egress to proxy CIDRs) +
      # proxy env vars (tells app to route through proxy).
      httpProxy: ""              # e.g., "http://proxy.corp.com:3128"
      httpsProxy: ""             # e.g., "http://proxy.corp.com:3128"
      noProxy: ""                # e.g., "biznez-postgres,biznez-gateway,.svc.cluster.local,10.0.0.0/8"
      # noProxy should include in-cluster services to avoid proxying internal traffic.
      # Chart auto-appends in-cluster service names when rendering.

    # Option D: Client-provided stable CIDRs for direct access
    externalServices:
      cidrs: []                  # Stable SaaS endpoint CIDRs (rare, see warnings above)
      ports: [443]

    # In-cluster MCP targets (for gateway egress to in-cluster services)
    mcpTargets:
      namespaceSelectors: []     # For in-cluster MCP servers
      # Example: [{ matchLabels: { "app.kubernetes.io/part-of": "biznez-agents" } }]
      ports: [443, 8080]

    # Allow all egress on port 443 (pragmatic fallback)
    # Profile defaults:
    #   eval:       true  (or networkPolicy.enabled: false entirely)
    #   production: false (CIS-hardened; use Option B/C/D above)
    #
    # If production client cannot enumerate CIDRs or set up proxy:
    #   Set true and document the accepted tradeoff in their security review.
    #   Recommended production pattern: corporate proxy/egress gateway (Option B).
    allowAllHttps: true          # Eval default; production overrides to false
```

**Impossible config detection:** `biznez-cli validate --profile production` and `helm template`
both detect and fail on the following impossible configuration:
- `networkPolicy.enabled: true`
- `egress.allowAllHttps: false`
- `egress.externalServices.cidrs` is empty
- `egress.proxy.cidrs` is empty

All four conditions must be true to trigger the failure. Any one of these provides an egress
path:
- `allowAllHttps: true` → allows all port-443 egress
- `proxy.cidrs` populated → routes egress through proxy
- `externalServices.cidrs` populated → allows direct access to specified CIDRs

Error message:
> "Network policies enabled with no egress path configured. Backend requires outbound HTTPS
> access to LLM providers and OIDC issuer. Set one of: egress.allowAllHttps=true,
> egress.proxy.cidrs (corporate proxy), or egress.externalServices.cidrs (direct CIDRs).
> See NETWORKING.md Option B/D for guidance."

In the Helm template, this is enforced via `{{ fail }}` so misconfiguration fails at
render time, not as a silent broken install.

**Production checklist item:** "If `networkPolicy.enabled=true` and `allowAllHttps=false`,
you MUST configure one of: `egress.proxy.cidrs` (corporate proxy/egress gateway),
`egress.externalServices.cidrs` (stable CIDRs), or Cilium FQDN policies (outside chart scope).
Verify with `biznez-cli validate --profile production`."

---

## 7b. Agent Gateway Configuration

The Agent Gateway (MCP proxy) routes LLM tool calls to MCP servers and A2A agents.
Its configuration is a YAML document mounted as a ConfigMap.

### values.yaml: gateway section

```yaml
gateway:
  enabled: true
  image:
    repository: ghcr.io/agentgateway/agentgateway
    tag: "0.1.0"
    digest: ""                   # Pinned in images.lock

  replicas: 1
  resources:
    requests: { cpu: 100m, memory: 128Mi }
    limits: { cpu: 500m, memory: 512Mi }

  # Timeouts
  timeouts:
    connectTimeout: 10s          # TCP connect to MCP target
    requestTimeout: 120s         # Total request timeout (LLM tool calls can be slow)
    idleTimeout: 300s            # Idle connection timeout

  # Gateway secrets -- API keys for MCP targets
  existingSecret: ""             # K8s Secret with MCP target API keys
  # If empty, chart creates Secret from inline values:
  secrets: {}
    # Example:
    # TAVILY_API_KEY: "tvly-..."
    # BRAVE_API_KEY: "BSA..."

  # Gateway YAML configuration (rendered into ConfigMap)
  # This is the complete agentgateway config -- see example below
  config:
    listeners:
      - name: default
        address: 0.0.0.0
        port: 8080
        protocol: MCP
        # Optional: JWT auth for gateway endpoints
        # authentication:
        #   type: jwt
        #   jwks_url: ""             # REQUIRED: Set to provider's jwks_uri
        #   audience: ""             # From auth.oidc.audience
        #   issuer: ""               # From auth.oidc.issuer
        #
        # NOTE: Do NOT hardcode provider-specific JWKS paths (e.g., /oauth/v2/keys).
        # JWKS URL varies by provider. Use the CLI helper to discover it:
        #   biznez-cli oidc-discover --issuer https://idp.client.com
        # This calls /.well-known/openid-configuration and prints:
        #   jwks_uri: https://idp.client.com/.well-known/jwks.json
        #   issuer: https://idp.client.com
        #   supported scopes: openid profile email
        # Copy the jwks_uri into gateway config.
        #
        # `biznez-cli validate --profile production` also calls OIDC discovery and
        # warns if gateway.config.listeners[].authentication.jwks_url is not set.

    targets:
      # Example MCP target: Tavily search
      # - name: tavily
      #   type: mcp
      #   url: "https://mcp.tavily.com/mcp"
      #   headers:
      #     Authorization: "Bearer ${TAVILY_API_KEY}"  # Injected from gateway secret
      #
      # Example: in-cluster MCP server
      # - name: internal-tools
      #   type: mcp
      #   url: "http://mcp-tools-service.biznez.svc.cluster.local:8080/mcp"
      #
      # Example: A2A agent
      # - name: email-agent
      #   type: a2a
      #   url: "http://email-agent-service.biznez.svc.cluster.local:8080"

    routes:
      # Route pattern: /org_{org_id}/{target_name}/mcp
      # Example:
      # - listener: default
      #   prefix: "/org_*/tavily"
      #   target: tavily
```

### Gateway secret requirements

Unlike backend/postgres/langfuse secrets (which have fixed required keys), gateway secret keys
are **arbitrary and user-defined**. They must match the `${VAR_NAME}` references in the gateway
config:

| Secret Reference | Required Keys | Notes |
|-----------------|---------------|-------|
| `gateway.existingSecret` | User-defined | Keys become env vars; must match `${VAR}` refs in `gateway.config` |

Example: if your gateway config references `${TAVILY_API_KEY}` and `${BRAVE_API_KEY}`, your
secret must contain those exact keys.

**Optional validation:** `biznez-cli validate-secrets` parses the gateway config YAML, extracts
all `${VAR_NAME}` references, and checks that each one exists as a key in the gateway secret.
This catches mismatches before deployment.

### Secret integration for gateway targets

MCP targets often require API keys. These are injected as environment variables into the
gateway container and referenced in the config via `${ENV_VAR_NAME}` syntax:

1. **Eval:** Set `gateway.secrets.TAVILY_API_KEY: "tvly-..."` in values.yaml
2. **Production:** Create K8s Secret, set `gateway.existingSecret: gateway-mcp-secrets`
   - Secret keys become env vars in the gateway pod
   - Reference in config: `Authorization: "Bearer ${TAVILY_API_KEY}"`

### Gateway health checks

```yaml
gateway:
  probes:
    liveness:
      httpGet: { path: /healthz, port: 8080 }
      initialDelaySeconds: 5
      periodSeconds: 30
    readiness:
      httpGet: { path: /readyz, port: 8080 }
      initialDelaySeconds: 5
      periodSeconds: 10
```

---

## 8. Security Hardening: Hardened by Default

### Pod Security Context (all pods)

```yaml
global:
  securityProfile: hardened      # hardened | permissive
  # hardened = production defaults below
  # permissive = for debugging / eval (relaxed constraints)

  podSecurityContext:
    runAsNonRoot: true
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault

  containerSecurityContext:
    runAsUser: 1000
    runAsGroup: 1000
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
```

### Per-component overrides

```yaml
backend:
  securityContext:               # Inherits from global, can override
    readOnlyRootFilesystem: true
  # Writable volumes for temp data:
  extraVolumes:
    - name: tmp
      emptyDir: {}
    - name: app-logs
      emptyDir: {}
  extraVolumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: app-logs
      mountPath: /app/logs

postgres:
  securityContext:
    runAsUser: 999               # postgres user
    fsGroup: 999
    readOnlyRootFilesystem: false # PostgreSQL needs writable data dir
```

**Postgres fsGroup caveat (eval only):** The embedded PostgreSQL relies on `fsGroup: 999`
for PVC data directory permissions. This works on clusters that support fsGroup-based
volume permission setting (most managed K8s, Docker Desktop, minikube with standard
provisioners). However, some storage drivers or locked-down on-prem clusters do not
apply fsGroup correctly, causing `Permission denied` on the data directory.

If embedded postgres fails with permission errors:
- Check storage class supports fsGroup (`allowVolumeExpansion` and `volumeBindingMode` are hints)
- Try a different storage class: `postgres.storageClassName: local-path`
- If unfixable: disable embedded postgres and use an external DB even for eval
  (`postgres.enabled: false` + `postgres.external.*`)

`biznez-cli validate --profile eval` detects common failures: PVC bound but pod in
CrashLoopBackOff with `Permission denied` in logs → prints guidance.

**Note:** An initContainer to `chown` the data directory is NOT an option under PSA
`restricted` profile (requires running as root).

### Resource limits (enforced everywhere)

```yaml
backend:
  resources:
    requests: { cpu: 250m, memory: 512Mi }
    limits: { cpu: 1000m, memory: 1Gi }

frontend:
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits: { cpu: 200m, memory: 256Mi }

gateway:
  resources:
    requests: { cpu: 100m, memory: 128Mi }
    limits: { cpu: 500m, memory: 512Mi }

postgres:
  resources:
    requests: { cpu: 250m, memory: 512Mi }
    limits: { cpu: 1000m, memory: 1Gi }
```

### Probes (consistent across all components)

```yaml
backend:
  probes:
    liveness:
      httpGet: { path: /api/v1/health, port: 8000 }
      initialDelaySeconds: 15
      periodSeconds: 30
      failureThreshold: 3
    readiness:
      httpGet: { path: /api/v1/health, port: 8000 }
      initialDelaySeconds: 10
      periodSeconds: 10
      failureThreshold: 3
    startup:
      httpGet: { path: /api/v1/health, port: 8000 }
      initialDelaySeconds: 5
      periodSeconds: 5
      failureThreshold: 30     # 150s max startup time

frontend:
  probes:
    liveness:
      httpGet: { path: /health, port: 80 }
    readiness:
      httpGet: { path: /health, port: 80 }

  # Nginx requires writable dirs even with readOnlyRootFilesystem
  extraVolumes:
    - name: nginx-cache
      emptyDir: {}
    - name: nginx-run
      emptyDir: {}
    - name: nginx-tmp
      emptyDir: {}
  extraVolumeMounts:
    - name: nginx-cache
      mountPath: /var/cache/nginx
    - name: nginx-run
      mountPath: /var/run
    - name: nginx-tmp
      mountPath: /tmp
```

### Standard writable mounts (all containers)

**Policy: all containers get a `/tmp` emptyDir mount** unless explicitly proven not needed.
This ensures PSA `restricted` + `readOnlyRootFilesystem: true` never breaks at runtime due
to unexpected temp file writes.

| Container | Writable Mounts |
|-----------|----------------|
| backend | `/tmp`, `/app/logs` |
| frontend (nginx) | `/tmp`, `/var/cache/nginx`, `/var/run` |
| gateway (agentgateway) | `/tmp` (for potential config reload state, cache, or temp files) |
| postgres | Data dir is on PVC (not readOnlyRootFilesystem) |
| migration job | `/tmp` (inherits backend mounts) |

Gateway mount in template:
```yaml
gateway:
  extraVolumes:
    - name: tmp
      emptyDir: {}
  extraVolumeMounts:
    - name: tmp
      mountPath: /tmp
```

**Note on Docker Compose frontend port:** The Docker Compose setup exposes the frontend on
port `8080` (mapped to nginx port `80` inside the container). This is the production nginx
server, NOT the Vite dev server (port 5173). The Docker Compose frontend uses the same
`frontend/Dockerfile` multi-stage build that produces the production nginx image.

### Image pull policy

```yaml
global:
  # Production: IfNotPresent with digest pinning
  # Eval: Always (to pick up :latest changes)
  imagePullPolicy: IfNotPresent
```

### values-production.yaml (CIS-hardened profile)

Includes all of the above with:
- `securityProfile: hardened`
- `postgres.enabled: false` (external DB required)
- `auth.mode: oidc` (local JWT disabled)
- `migration.mode: manual`
- `imagePullPolicy: IfNotPresent` with digest pinning
- Resource limits tuned up
- HPA enabled (min 2, max 10)
- PodDisruptionBudget (optional, opt-in): `pdb.enabled: true`, `minAvailable: 1` for backend
  (ensures at least one pod survives node drains; requires replicas ≥ 2)
- Network policies enabled, `egress.allowAllHttps: false` (client must configure proxy CIDRs or accept tradeoff)
- All inline secrets disabled (existingSecret required)

### Production template guards

**Profile detection:** Templates check a single canonical field: `global.profile`.

```yaml
# values.yaml (eval default):
global:
  profile: eval              # eval | production

# values-production.yaml includes:
global:
  profile: production
```

All template guards key off `global.profile` exclusively. There is no heuristic detection --
if a client merges `values-production.yaml` with overrides, the `global.profile: production`
field carries through and enforces all guards. If a client manually sets individual production
values without setting `profile: production`, guards are NOT enforced (intentional -- allows
incremental hardening).

When `global.profile: production`, Helm templates enforce required fields via `{{ required }}`
and `{{ fail }}`. Misconfiguration fails at `helm template` / `helm install` time with a clear
error message, not as a silent broken install.

| Guard | Condition | Error Message |
|-------|-----------|---------------|
| `backend.existingSecret` | Required when profile=production | "Production requires backend.existingSecret (inline secrets disabled)" |
| `backend.secrets.*` | Must be empty when profile=production | "Production does not allow inline secrets; use backend.existingSecret" |
| `llm.existingSecret` | Required when profile=production | "Production requires llm.existingSecret for LLM API key" |
| `llm.secrets.*` | Must be empty when profile=production | "Production does not allow inline secrets; use llm.existingSecret" |
| `auth.oidc.issuer` | Required when `auth.mode: oidc` | "OIDC mode requires auth.oidc.issuer" |
| `auth.oidc.audience` | Required when `auth.mode: oidc` | "OIDC mode requires auth.oidc.audience" |
| `postgres.external.host` | Required when `postgres.enabled: false` | "External database host required when embedded postgres disabled" |
| `postgres.external.existingSecret` | Required when `postgres.enabled: false` | "External database credentials required (postgres.external.existingSecret)" |
| `ingress.tls.secretName` | Required when `tls.mode: existingSecret` | "TLS mode existingSecret requires ingress.tls.secretName" |
| `ingress.tls.clusterIssuer` | Required when `tls.mode: certManager` | "TLS mode certManager requires ingress.tls.clusterIssuer" |
| Network policy egress | See "impossible config detection" in section 7 | Fails if no egress path configured |

Template pattern:
```yaml
{{- if eq .Values.global.profile "production" }}
{{- required "Production requires backend.existingSecret" .Values.backend.existingSecret }}
{{- end }}
```

**Eval profile:** No guards enforced. Inline secrets and embedded postgres are allowed.
This ensures `helm install` works out of the box with minimal configuration.

---

## Installer CLI: Enhanced Commands

```bash
biznez-cli validate              # Check prerequisites (profile-aware):
                                 # Common checks (all profiles):
                                 #   - kubectl version ≥ 1.27, helm version ≥ 3.12
                                 #   - kubectl auth can-i create deployments,services,configmaps
                                 #   - Target namespace exists (REQUIRED; chart does not create it)
                                 #     Error if namespace missing; suggest: kubectl create namespace biznez
                                 #   - Registry connectivity (if imageRegistry set)
                                 #
                                 # --profile eval (default):
                                 #   - Storage class exists (for embedded postgres PVC)
                                 #   - Warn if no default storage class
                                 #   - Skip: PSA, external DB, OIDC, TLS checks
                                 #
                                 # --profile production:
                                 #   - PSA label on namespace (restricted)
                                 #   - External DB connectivity (TCP connect to host:port)
                                 #   - existingSecret refs exist and contain required keys
                                 #   - OIDC issuer reachable (HTTP GET .well-known/openid-configuration)
                                 #   - TLS: secretName exists (existingSecret mode) or
                                 #     cert-manager CRDs present (certManager mode)
                                 #   - imagePullSecrets exist in namespace
                                 #   - NetworkPolicy API available (if networkPolicy.enabled)
                                 #
                                 # LIMITATION: DB and OIDC connectivity checks run from the
                                 # machine running the CLI, NOT from inside the cluster. Network
                                 # paths may differ (VPN, firewall rules, DNS resolution).
                                 #
                                 # --in-cluster flag: spins a short-lived Job/pod in the target
                                 # namespace to test connectivity from the cluster network:
                                 #   biznez-cli validate --profile production --in-cluster
                                 #   - Runs curl to OIDC issuer /.well-known/openid-configuration
                                 #   - Runs pg_isready / TCP connect to external DB
                                 #   - Tests DNS resolution of external hostnames
                                 #   - Job auto-deletes after completion
                                 # This catches: firewall rules blocking cluster egress, DNS
                                 # resolution differences, VPC peering issues.

biznez-cli generate-secrets      # Print secrets to stdout (pipe to kubectl)
biznez-cli generate-secrets --write  # Write to file (explicit opt-in)
biznez-cli validate-secrets      # Check existingSecret refs have required keys

biznez-cli install               # Interactive install (namespace must exist)
biznez-cli install --profile eval       # Eval defaults (embedded PG, local auth)
biznez-cli install --profile production # Prod defaults (external DB, OIDC, hardened)
biznez-cli install --create-namespace   # Explicitly create namespace if it doesn't exist
                                        # (requires can-i create namespaces permission)

biznez-cli migrate               # Run Alembic migrations manually
biznez-cli migrate --dry-run     # Show pending migrations without applying

biznez-cli health-check          # Post-install health validation

biznez-cli export-images         # Export images per images.lock
biznez-cli import-images         # Load into client registry, retag
biznez-cli verify-images         # Cosign verify (optional)

biznez-cli oidc-discover         # Discover OIDC endpoints from issuer URL:
                                 #   biznez-cli oidc-discover --issuer https://idp.client.com
                                 #   Prints: jwks_uri, issuer, supported scopes
                                 #   Useful for configuring gateway auth and validating OIDC setup

biznez-cli backup-db             # pg_dump (embedded postgres only)
biznez-cli restore-db            # pg_restore (embedded postgres only)

biznez-cli upgrade               # Upgrade to new version (pulls new chart)

biznez-cli support-bundle        # Collect diagnostic bundle for support:
                                 #   - helm values (secrets REDACTED)
                                 #   - helm get manifest (deployed resources)
                                 #   - kubectl get pods,svc,ep,ingress,events -n biznez
                                 #   - pod logs: backend, frontend, gateway (tail 500)
                                 #   - kubectl version, helm version
                                 #   - node info (kubectl get nodes)
                                 #   - PVC status (kubectl get pvc)
                                 #   - NetworkPolicy status (if enabled)
                                 # Output: biznez-support-<timestamp>.tar.gz
                                 # Clients send this file; we diagnose without cluster access.

# v2 (future):
# biznez-cli rotate-encryption-key  # Re-encrypt stored secrets with new key
```

---

## Files to Create

| File | Purpose |
|------|---------|
| **Helm Chart** | |
| `deploy/helm/biznez-runtime/Chart.yaml` | Chart metadata, version |
| `deploy/helm/biznez-runtime/values.yaml` | Evaluation defaults |
| `deploy/helm/biznez-runtime/values-production.yaml` | CIS-hardened production profile |
| `deploy/helm/biznez-runtime/images.lock` | Deterministic image manifest with digests |
| `deploy/helm/biznez-runtime/templates/_helpers.tpl` | Template helpers |
| `deploy/helm/biznez-runtime/templates/backend/deployment.yaml` | Backend deployment |
| `deploy/helm/biznez-runtime/templates/backend/service.yaml` | Backend service |
| `deploy/helm/biznez-runtime/templates/backend/configmap.yaml` | Backend config |
| `deploy/helm/biznez-runtime/templates/backend/secret.yaml` | Backend secrets (conditional) |
| `deploy/helm/biznez-runtime/templates/backend/migration-job.yaml` | DB migration job (conditional) |
| `deploy/helm/biznez-runtime/templates/backend/hpa.yaml` | Autoscaling (conditional) |
| `deploy/helm/biznez-runtime/templates/frontend/deployment.yaml` | Frontend deployment |
| `deploy/helm/biznez-runtime/templates/frontend/service.yaml` | Frontend service |
| `deploy/helm/biznez-runtime/templates/frontend/configmap.yaml` | Nginx config |
| `deploy/helm/biznez-runtime/templates/postgres/statefulset.yaml` | PostgreSQL (conditional) |
| `deploy/helm/biznez-runtime/templates/postgres/service.yaml` | Postgres service (conditional) |
| `deploy/helm/biznez-runtime/templates/postgres/secret.yaml` | Postgres creds (conditional) |
| `deploy/helm/biznez-runtime/templates/postgres/pvc.yaml` | Persistent storage (conditional) |
| `deploy/helm/biznez-runtime/templates/gateway/deployment.yaml` | Agent Gateway (conditional) |
| `deploy/helm/biznez-runtime/templates/gateway/service.yaml` | Gateway service (conditional) |
| `deploy/helm/biznez-runtime/templates/gateway/configmap.yaml` | Gateway routes (conditional) |
| `deploy/helm/biznez-runtime/templates/ingress.yaml` | Ingress (conditional) |
| `deploy/helm/biznez-runtime/templates/gateway-api.yaml` | Gateway API routes (conditional) |
| `deploy/helm/biznez-runtime/templates/networkpolicy.yaml` | Network policies (conditional) |
| `deploy/helm/biznez-runtime/templates/rbac.yaml` | RBAC (conditional) |
| `deploy/helm/biznez-runtime/templates/NOTES.txt` | Post-install instructions |
| **Docker Compose** | |
| `deploy/docker-compose/docker-compose.yml` | All services (eval) |
| `deploy/docker-compose/.env.template` | Environment template |
| `deploy/docker-compose/nginx.conf` | Frontend nginx |
| `deploy/docker-compose/setup.sh` | Setup script |
| **CLI** | |
| `deploy/biznez-cli` | Installer CLI script |
| **Docs** | |
| `deploy/docs/INSTALL.md` | Installation guide |
| `deploy/docs/PRODUCTION-CHECKLIST.md` | Production readiness checklist |
| `deploy/docs/MIGRATION-GUIDE.md` | Zero-downtime migration guide |
| `deploy/docs/OIDC-SETUP.md` | OIDC provider setup (claims, roles) |
| `deploy/docs/SECURITY.md` | Security hardening guide |
| `deploy/docs/BACKUP-RESTORE.md` | Backup/restore procedures |
| `deploy/docs/NETWORKING.md` | Ingress/networking patterns |
| `deploy/docs/UPGRADE.md` | Version upgrade procedures |

---

## Existing Files to Reference (read-only during implementation)

| File | What to extract |
|------|----------------|
| `k8s/base/platform-api-deployment.yaml` | Backend deployment spec, probes, resources |
| `k8s/base/frontend/frontend-deployment.yaml` | Frontend deployment spec |
| `k8s/base/postgres-statefulset.yaml` | PostgreSQL StatefulSet spec |
| `k8s/base/platform-configmap.yaml` | Config values |
| `k8s/base/platform-secrets.yaml` | Secret structure |
| `k8s/base/platform-ingress.yaml` | Ingress annotations |
| `k8s/overlays/prod/hpa.yaml` | HPA configuration |
| `k8s/mcp-gateway/deployment.yaml` | Gateway deployment |
| `k8s/mcp-gateway/configmap.yaml` | Gateway config structure |
| `k8s/rbac/platform-api-rbac.yaml` | RBAC resources |
| `docker-compose.yml` | Docker Compose structure |
| `.env.example` | All environment variables (293 lines) |
| `Dockerfile` | Backend image build |
| `frontend/Dockerfile` | Frontend image build |
| `frontend/nginx.conf` | Nginx configuration |
| `alembic.ini` | Migration config |
| `src/agentic_runtime/core/config.py` | RuntimeConfig class |
| `src/agentic_runtime/core/security/encryption.py` | Fernet encryption implementation |
| `src/agentic_runtime/api/zitadel_auth.py` | OIDC/JWKS implementation |

---

## Implementation Order

1. **Helm chart structure** -- Chart.yaml, values.yaml, values-production.yaml, _helpers.tpl
2. **Security foundations** -- Pod security contexts, secret mounting, RBAC templates
3. **Backend templates** -- deployment, service, configmap, secret (conditional)
4. **Frontend templates** -- deployment, service, configmap (nginx)
5. **PostgreSQL templates** -- statefulset (conditional), external DB support
6. **Gateway templates** -- deployment, service, configmap (conditional)
7. **Migration job** -- three modes (hook, initContainer, manual), advisory locking
8. **Networking** -- ingress (conditional), gateway API (conditional), network policies
9. **HPA + production values** -- autoscaling, CIS-hardened profile
10. **Docker Compose** -- docker-compose.yml, .env.template, setup.sh
11. **Installer CLI** -- validate, generate-secrets, install, health-check, export/import images
12. **Images.lock + SBOM** -- deterministic manifest, Syft SBOM generation
13. **Documentation** -- INSTALL, PRODUCTION-CHECKLIST, OIDC-SETUP, SECURITY, etc.
14. **NOTES.txt** -- post-install instructions with profile-aware output

---

## Client Quick-Start

### Evaluation

```bash
./biznez-cli validate
./biznez-cli install --profile eval

# Access via port-forward (works on minikube, kind, Docker Desktop, any K8s):
kubectl port-forward svc/biznez-backend 8000:8000 -n biznez &
kubectl port-forward svc/biznez-frontend 8080:80 -n biznez &
# Backend: http://localhost:8000
# Frontend: http://localhost:8080
```

The eval profile defaults to ClusterIP services (no NodePort, no LoadBalancer).
Port-forward is the most reliable access method across all local K8s distributions.

**Optional: NodePort (for persistent access without port-forward):**
```yaml
# Override in my-values.yaml:
backend:
  service:
    type: NodePort
    nodePort: 30800
frontend:
  service:
    type: NodePort
    nodePort: 30080
```
If using NodePort, document per-platform node IP retrieval:
- minikube: `minikube ip`
- kind: `docker inspect kind-control-plane --format '{{.NetworkSettings.Networks.kind.IPAddress}}'`
- Docker Desktop: `localhost`

### Production

```bash
# 1. Validate prerequisites and permissions
./biznez-cli validate

# 2. Import images into client registry
./biznez-cli import-images \
  --archive biznez-images-v1.0.0.tar.gz \
  --registry registry.client.com/biznez

# 3. Create secrets in cluster (client's secret management)
kubectl create secret generic biznez-backend-secrets \
  --from-literal=ENCRYPTION_KEY=$(./biznez-cli generate-secrets --key encryption) \
  --from-literal=JWT_SECRET_KEY=$(./biznez-cli generate-secrets --key jwt) \
  -n biznez

kubectl create secret generic biznez-db-credentials \
  --from-literal=POSTGRES_USER=biznez \
  --from-literal=POSTGRES_PASSWORD=<from-vault> \
  -n biznez

# 4. Configure values
cp values-production.yaml my-values.yaml
# Edit: imageRegistry, external DB, OIDC issuer, ingress hosts

# 5. Validate secrets exist with required keys
./biznez-cli validate-secrets -f my-values.yaml -n biznez

# 6. Install
helm install biznez deploy/helm/biznez-runtime/ \
  -f my-values.yaml \
  -n biznez

# 7. Run migrations
./biznez-cli migrate

# 8. Verify
./biznez-cli health-check
```

### Docker Compose (demos)

```bash
cd deploy/docker-compose/
cp .env.template .env
./setup.sh
# Platform available at http://localhost:8080
```

**Docker Compose image sourcing:**

Docker Compose needs images available in the local Docker daemon. Two modes:

1. **Online (default):** `docker compose pull` fetches images from the configured registry.
   Requires network access to the image registry.

2. **Air-gapped / offline:** Use the same image archive as Kubernetes deployments:
   ```bash
   # Load images into local Docker daemon (no registry needed):
   biznez-cli import-images \
     --archive biznez-images-v1.0.0.tar.gz \
     --docker                    # Handles decompression + format conversion automatically
   ```
   After loading, `docker compose up` uses locally cached images (set
   `pull_policy: never` in docker-compose.yml or `COMPOSE_PULL_POLICY=never` in `.env`).

   **Image archive format:** `biznez-cli export-images` supports two formats:
   - `--format docker-archive` (default): Compatible with `docker load` directly
   - `--format oci-archive`: OCI layout tarball (requires `skopeo` or `crane` to load
     into Docker: `skopeo copy oci-archive:biznez-images.tar docker-daemon:image:tag`)

   `biznez-cli import-images --docker` handles either format transparently (decompresses
   `.tar.gz`, detects format, and loads appropriately). Users should never need to call
   `docker load` directly -- always use `biznez-cli import-images --docker`.

The `setup.sh` script detects whether images are already loaded and skips pull if present.

**Docker Compose auth modes:**
- **Default: local auth** (built-in user/password, no external IdP needed). The `setup.sh`
  script generates a JWT secret and bootstraps an admin account automatically.
- **OIDC in Docker Compose:** Supported but requires additional configuration:
  - Set `AUTH_MODE=oidc` and OIDC issuer/audience in `.env`
  - The OIDC callback URL must match `http://localhost:8080` (or whatever the frontend port is).
    If the IdP requires HTTPS callbacks, you need a local reverse proxy with TLS termination
    (e.g., Caddy, Traefik, or mkcert + nginx).
  - **Common pitfall:** OIDC providers often reject `http://localhost` callback URLs.
    The `.env.template` must document the **actual redirect URI(s) used by the app**
    (not a generic example). These are determined by the frontend routing implementation.
    Document the exact paths, e.g.:
    - `http://localhost:8080/auth/callback` (if that's what the frontend uses)
    - Any additional redirect URIs (logout, silent refresh)
  - `setup.sh` prints the exact redirect URI(s) that must be registered in the IdP,
    based on the configured `FRONTEND_URL`. This prevents "invalid redirect URI" errors.
  - Token issuer URL must be reachable from both the browser AND the backend container.
    If the IdP is external (e.g., Auth0, Okta), this works. If self-hosted on
    `localhost`, use Docker network aliases so the backend can reach it.

---

## Verification

1. **Helm lint**: `helm lint deploy/helm/biznez-runtime/`
2. **Helm template (eval)**: `helm template test deploy/helm/biznez-runtime/` -- verify namespaced-only resources
3. **Helm template (prod)**: `helm template test deploy/helm/biznez-runtime/ -f values-production.yaml`
4. **No cluster-scoped resources (CI gate):** Primary enforcement via `conftest` OPA policy
   (`deploy/helm/policies/no-cluster-scoped.rego`). Uses a denylist of known cluster-scoped
   kinds PLUS an allowlist of permitted kinds in this chart (Deployment, Service, ConfigMap,
   Secret, StatefulSet, Job, PVC, ServiceAccount, Role, RoleBinding, HPA, NetworkPolicy,
   Ingress, HTTPRoute). Any kind not in the allowlist triggers a review.

   Quick smoke test (grep, for local dev -- NOT sufficient as sole gate):
   ```bash
   helm template test deploy/helm/biznez-runtime/ | \
     grep -E 'kind: (ClusterRole|ClusterRoleBinding|CustomResourceDefinition|Namespace|ClusterIssuer|MutatingWebhookConfiguration|ValidatingWebhookConfiguration|PersistentVolume|StorageClass|PodSecurityPolicy|PriorityClass|APIService|RuntimeClass|CSIDriver|IngressClass)' \
     && echo "FAIL: cluster-scoped resources found" || echo "PASS: namespaced only"
   ```
5. **Helm dry-run**: `helm install --dry-run test deploy/helm/biznez-runtime/`
6. **Docker Compose**: `docker compose -f deploy/docker-compose/docker-compose.yml config`
7. **Security scan**: `kubesec scan` on generated YAML + `kubeconform` for schema validation
   (catches typos, invalid field names, wrong apiVersions in rendered YAML)
8. **Vulnerability scan (CI gate):** Trivy scan on all images before release:
   ```bash
   trivy image --severity HIGH,CRITICAL --exit-code 1 biznez/platform-api:1.0.0
   trivy image --severity HIGH,CRITICAL --exit-code 1 biznez/web-app:1.0.0
   ```
   - Publish scan report as release artifact: `trivy-report-v1.0.0.json`
   - Release policy: zero CRITICAL, HIGH acceptable only with documented justification
   - Scan includes third-party images (postgres, agentgateway) -- document known upstream vulns
   - Enterprise clients will ask "what's your vulnerability management story" -- SECURITY.md
     covers: scan cadence (every release + weekly scheduled), acceptable severity thresholds,
     remediation SLAs, and how to request a fresh scan report
9. **Local K8s test**: Install on Docker Desktop K8s or Minikube with eval profile
10. **Health checks**: Backend `/api/v1/health`, Frontend `/health`, Postgres `pg_isready`
11. **PSA compliance**: Verify pods pass `restricted` Pod Security Admission
