# Fix Migration Failure on Fresh Eval Databases

## Context

The eval provisioning workflow (`provision-eval.yml`) deploys a fresh PostgreSQL database with no tables. The Helm chart runs `alembic upgrade head` as an init container before the backend starts. But the first Alembic migration (`24c2526fe8f3`) tries to `ALTER TABLE agents ADD COLUMN slug` — it assumes tables already exist. On a fresh database, this fails with `relation "agents" does not exist`, causing CrashLoopBackOff on the backend pod.

The runtime repo's Docker image (`Dockerfile.platform`) already solves this: its CMD runs `python3 scripts/init_database_schema.py && alembic upgrade head && uvicorn ...`. The `init_database_schema.py` script checks if the database is empty, creates all tables via `Base.metadata.create_all()`, then runs `alembic stamp head` to mark migrations as applied. But the Helm chart overrides the CMD with just `alembic upgrade head`, bypassing the schema initialization step.

## Root Cause

| Component | What it does | Problem |
|-----------|-------------|---------|
| `Dockerfile.platform` CMD (line 104) | `python3 scripts/init_database_schema.py && alembic upgrade head && uvicorn ...` | Correct — handles fresh DB |
| Helm `migration.command` (values.yaml line 471) | `alembic upgrade head` | Missing — skips schema init on fresh DB |
| `scripts/init_database_schema.py` | Creates tables if DB empty, stamps head, skips if tables exist | Already in Docker image but never called by Helm |

## Risk Analysis: `stamp head` After `create_all()`

**Concern:** `Base.metadata.create_all()` generates schema from current SQLAlchemy models. `alembic stamp head` marks ALL migrations as applied. If the models have drifted from the migration chain (e.g., a column added in models but not yet in a migration), the stamped schema would differ from what running all migrations sequentially would produce.

**Why this is acceptable for eval deployments:**
- The runtime repo's own `Dockerfile.platform` CMD uses the exact same pattern (`init_database_schema.py && alembic upgrade head`). This is the vendor-blessed approach.
- Eval environments are ephemeral — torn down after testing, no long-lived data.
- The script only runs on **completely empty** databases (0 tables). Existing databases skip straight to `alembic upgrade head`.
- If model-migration drift exists, it's a bug in the runtime repo, not in our Helm chart. The runtime CI should catch this.

**For production deployments:** The migration command is overridable via `migration.command` in values. Production operators with existing databases will never trigger `create_all()` since their databases already have tables.

## Verified: Docker Image Contains Required Files

Verified on live cluster (manimaun13-tx2t) by running a one-shot pod with the exact backend image:

| Check | Result |
|-------|--------|
| `/app/scripts/init_database_schema.py` | EXISTS (3016 bytes) |
| `python3` binary | `/usr/local/bin/python3` (available) |
| `/app/alembic.ini` | EXISTS |
| `/app/alembic/versions/` | Contains migration files |
| `PYTHONPATH` | Includes `/app` |
| Working directory | `/app` |

## Verified: Template Already Handles Key Concerns

### workingDir is explicitly set on the run-migrations init container

Confirmed in `deployment.yaml` line 88:
```yaml
workingDir: {{ .Values.migration.workingDir | default "/app" | quote }}
```
This is set directly on the `run-migrations` init container, not just the main backend container. The relative path `scripts/init_database_schema.py` resolves correctly because `workingDir` is `/app` and the script lives at `/app/scripts/`.

### run-migrations init container inherits all backend env vars

Confirmed in `deployment.yaml` lines 91-94:
```yaml
envFrom:
  {{- include "biznez.backend.envFrom" . | nindent 12 }}
env:
  {{- include "biznez.backend.envVars" . | nindent 12 }}
```
These are the **same helper templates** used by the main backend container (lines 116-119). The init container gets `DATABASE_URL`, `ENCRYPTION_KEY`, `JWT_SECRET_KEY`, and all other env vars that `init_database_schema.py` needs. No subset risk.

### init_database_schema.py already logs which branch it took

The script has clear log lines for both paths (lines 51 and 65):
- Fresh DB: `[init_database_schema] Database is empty. Creating all tables...`
- Existing DB: `[init_database_schema] Database already has N tables. Skipping creation.`

Combined with `python3 -u` (unbuffered stdout), these will appear immediately in `kubectl logs`.

## Changes

### 1. `infra/values/eval-gke.yaml` — Add migration command override (eval-only)

Rather than changing the global `migration.command` default in `values.yaml`, override it only in the eval values file. This keeps production behavior unchanged and makes the eval-specific nature explicit.

```yaml
# Add to eval-gke.yaml:
migration:
  mode: auto
  command:
    - sh
    - -ceu
    - python3 -u scripts/init_database_schema.py && alembic upgrade head
```

**Design decision:** The global `values.yaml` default (`alembic upgrade head`) stays unchanged. Production operators never see `init_database_schema.py` in their migration path. Eval environments opt in explicitly.

**Shell flags:**
- `-c`: execute the following string as a command
- `-e` (`errexit`): exit immediately if any command fails — script failure stops the init container without silently continuing to `alembic upgrade head`
- `-u` (`nounset`): treat unset variables as errors — catches misconfigured env vars early

**`python3 -u`:** Forces unbuffered stdout so init logs appear immediately in `kubectl logs` rather than being buffered until process exit.

**Why relative paths are safe:** The `run-migrations` init container has `workingDir: /app` set explicitly (deployment.yaml line 88), and the script lives at `/app/scripts/init_database_schema.py`.

### 2. `helm/biznez-runtime/values.yaml` — Add resources to wait-for-db

Address the GKE Autopilot warning: `defaulted unspecified 'cpu' resource for containers [wait-for-db]`.

`waitForDb` is nested under `backend` in values.yaml (line 135). The template references it as `.Values.backend.waitForDb.resources` (confirmed via grep). Both are consistent.

```yaml
# Before (values.yaml, under backend:):
  waitForDb:
    enabled: true
    image: {}

# After:
  waitForDb:
    enabled: true
    image: {}
    resources:
      requests:
        cpu: 50m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 64Mi
```

### 3. `helm/biznez-runtime/templates/backend/deployment.yaml` — Wire up wait-for-db resources

Add the resources block to the wait-for-db init container template (currently missing). The template must reference `.Values.backend.waitForDb.resources` to match the values structure.

```yaml
# Add after the securityContext block (line 47) and before the command block (line 48):
          {{- with .Values.backend.waitForDb.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
```

### 4. `infra/scripts/provision.sh` — Add failure diagnostics after Helm install

When `helm upgrade --install` fails, dump diagnostic logs automatically so failures are actionable without manual cluster access.

```bash
# Before (line 210-213):
    -n "$NAMESPACE" --wait --timeout 600s || {
    error "Helm install failed"
    exit "$EXIT_KUBE"
}

# After:
    -n "$NAMESPACE" --wait --timeout 600s || {
    error "Helm install failed — collecting diagnostics..."
    echo "--- Pod status ---"
    kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || true
    echo "--- Backend pod describe ---"
    BACKEND_POD=$(kubectl get pod -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=backend" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
    if [ -n "$BACKEND_POD" ]; then
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
```

This captures pod status, events, and container logs in the GitHub Actions output, making failures actionable without manual `kubectl` access.

## How It Flows Through the GitHub Actions Pipeline

```
provision-eval.yml
  │
  ├─ Step: Deploy Runtime
  │    └─ provision.sh --values-file infra/values/eval-gke.yaml
  │         └─ helm upgrade --install -f eval-gke.yaml
  │              │
  │              ├─ eval-gke.yaml sets: migration.mode: auto
  │              ├─ eval-gke.yaml sets: migration.command:
  │              │    [sh, -ceu, "python3 -u scripts/init_database_schema.py && alembic upgrade head"]
  │              └─ values.yaml global default unchanged: [alembic, upgrade, head]
  │
  └─ Kubernetes creates backend pod:
       │
       ├─ initContainer[0]: wait-for-db
       │    ├─ pg_isready -U biznez -d biznez_platform (waits for postgres) ← FIXED in PR #27
       │    └─ resources: 50m/32Mi requests, 100m/64Mi limits ← NEW
       │
       ├─ initContainer[1]: run-migrations
       │    ├─ Image: platform-api (same as backend)
       │    ├─ Command: sh -ceu "python3 -u scripts/init_database_schema.py && alembic upgrade head"
       │    ├─ workingDir: /app (explicitly set on init container, line 88)
       │    ├─ Env: DATABASE_URL, ENCRYPTION_KEY, JWT_SECRET_KEY, ... (same envFrom as backend)
       │    │
       │    ├─ Step 1: init_database_schema.py
       │    │    ├─ Connects to DB using DATABASE_URL
       │    │    ├─ Fresh DB: create_all() creates all 41 tables → alembic stamp head
       │    │    │    └─ Logs: "[init_database_schema] Database is empty. Creating all tables..."
       │    │    └─ Existing DB: skips (tables already exist)
       │    │         └─ Logs: "[init_database_schema] Database already has N tables. Skipping creation."
       │    │
       │    └─ Step 2: alembic upgrade head
       │         ├─ Fresh DB: all migrations stamped → nothing to do
       │         └─ Existing DB: applies any pending migrations
       │
       ├─ On failure: provision.sh dumps pod status + container logs to GitHub Actions output
       │
       └─ container[0]: backend
            └─ uvicorn starts (database fully migrated)
```

## Files Modified

| File | Change |
|------|--------|
| `infra/values/eval-gke.yaml` | Add `migration.command` override with `init_database_schema.py` + shell strict mode |
| `helm/biznez-runtime/values.yaml` | Add `backend.waitForDb.resources` (no migration command change) |
| `helm/biznez-runtime/templates/backend/deployment.yaml` | Add resources block to wait-for-db init container |
| `infra/scripts/provision.sh` | Add failure diagnostics (pod status, describe, container logs) after Helm install failure |

## Verification

### Pre-merge (local)
1. `helm lint` passes
2. `helm template` with eval-gke.yaml renders the new migration command: `sh -ceu "python3 -u scripts/init_database_schema.py && alembic upgrade head"`
3. `helm template` with default values.yaml still renders: `alembic upgrade head` (unchanged for non-eval)
4. `helm template` renders wait-for-db with resources block
5. `helm template` confirms `.Values.backend.waitForDb.resources` path renders correctly

### Post-deploy (on live cluster)
6. Clean up manimaun13-tx2t environment
7. Merge PR, trigger provision workflow
8. Expected outcome:
   - wait-for-db: passes with resources set (no Autopilot warning)
   - run-migrations: `init_database_schema.py` creates tables on fresh DB, stamps head, then `alembic upgrade head` is a no-op
   - backend pod: moves from Init:0/2 → Init:1/2 → Running
   - Helm `--wait` succeeds within 600s timeout
9. **Verify database state** after deployment:
   - `alembic_version` table exists and contains a single row with `version_num` matching head revision
   - Key tables exist: `agents`, `users`, `organizations`, `workflows` (spot-check)
   - Backend `/api/v1/health` returns 200
10. **On failure:** provision.sh now dumps diagnostics automatically — check GitHub Actions output for pod status, events, and container logs

## Follow-Up Items (Out of Scope)

| Item | Owner | Description |
|------|-------|-------------|
| Align Helm init container with image entrypoint | dist repo | Long-term: consider having Helm defer to the image's own CMD rather than overriding with `migration.command`. This avoids the two diverging over time. |
| CI schema drift test | runtime repo | Add a test that compares `create_all()` output against sequential migration output to catch model-migration drift. |
