# Database Migration Guide

This guide covers database migration modes, the advisory lock mechanism, running migrations, zero-downtime patterns, and Helm rollback interaction.

## Overview

The Biznez Agentic Runtime uses Alembic for database schema migrations. The Helm chart supports three migration modes configured via `migration.mode`:

| Mode | Value | Mechanism | Default For |
|------|-------|-----------|------------|
| Auto | `auto` | initContainer on backend pod | Eval |
| Hook | `hook` | Helm pre-install/pre-upgrade Job | — |
| Manual | `manual` | Operator runs `biznez-cli migrate` | Production (recommended) |

## Migration Modes

### `auto` — initContainer

```yaml
migration:
  mode: auto
```

An initContainer runs `alembic upgrade head` before the backend container starts. The backend pod is blocked until migration completes.

This is the default for evaluation deployments. It is simple but has limitations:
- Blocks pod startup — if migration is slow, health checks may fail
- Runs on every pod restart (Alembic is idempotent, but adds startup latency)
- No `--dry-run` inspection before execution

> **Note:** `auto` refers to the values key (`migration.mode: auto`), not "automatic" in the continuous deployment sense. The migration runs as a Kubernetes initContainer that blocks pod startup until it completes.

### `hook` — Helm Job

```yaml
migration:
  mode: hook
```

A Helm pre-install/pre-upgrade Job runs migrations before the main deployment rolls out. The Job:
- Runs once per `helm install` or `helm upgrade`
- Blocks the deployment until the Job succeeds
- Has a configurable TTL (`migration.jobTtlSeconds: 600`)
- Uses the backend image with the same security context and env vars

This mode is production-safe and ensures migrations complete before new code starts.

### `manual` — Operator-controlled

```yaml
migration:
  mode: manual
```

No migration resources are rendered. The operator runs migrations explicitly:

```bash
# Dry-run first:
biznez-cli migrate --namespace biznez --dry-run

# Then apply:
biznez-cli migrate --namespace biznez
```

This mode provides full control and is recommended for production, especially for zero-downtime deployments where migrations must be coordinated with rollout strategy.

## Advisory Lock Mechanism

When multiple migration processes could run concurrently (e.g., multiple pods starting simultaneously in `auto` mode, or overlapping Jobs in `hook` mode), the migration runner uses a PostgreSQL advisory lock to ensure only one migration runs at a time.

- **Lock ID:** `738291456` (fixed constant)
- **Lock type:** `pg_try_advisory_lock` (non-blocking)
- **Retry:** Up to 30 attempts with backoff
- **Connection:** Single connection held for the duration of the migration
- **Release:** Lock is automatically released when the connection closes

If the lock cannot be acquired after 30 retries, the migration process exits with an error. This prevents deadlocks and ensures only one migration modifies the schema at a time.

## Running Migrations

### With biznez-cli

```bash
# Inspect what would run (no changes made):
biznez-cli migrate --namespace biznez --dry-run

# Run migrations:
biznez-cli migrate --namespace biznez
```

The CLI creates a Kubernetes Job using the backend image with the migration command configured in `migration.command` (default: `alembic upgrade head`).

### Migration command override

For custom migration runners (e.g., with advisory lock wrapper):

```yaml
migration:
  command:
    - python
    - -m
    - agentic_runtime.db.migration_runner
  workingDir: /app
```

### Resource limits

Migration containers default to `backend.resources`. Override with:

```yaml
migration:
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi
```

## Zero-Downtime Pattern

For production deployments that cannot tolerate downtime during schema changes, use the expand/contract pattern:

### Step 1: Expand — Add new columns/tables

- Add new nullable columns or new tables
- Deploy new code that writes to both old and new columns
- Old code continues to work (new columns are nullable)

### Step 2: Backfill

- Backfill new columns from old data
- Verify data consistency

### Step 3: Contract — Remove old columns

- Deploy code that only uses new columns
- Remove old columns in a subsequent migration

This requires `migration.mode: manual` so the operator controls when each migration runs relative to code deployments.

## Helm Rollback Interaction

**Helm rollback reverts templates but does NOT reverse database migrations.** Alembic migrations are forward-only by design.

### Risks

If a migration adds columns that the old code does not expect:
- Rollback deploys old code
- Old code encounters unknown columns (usually harmless — ignored by most ORMs)
- If migration drops columns the old code needs, rollback fails

### Recommendations

1. Use the expand/contract pattern — never drop columns in the same release that adds them
2. Before rollback, verify the rolled-back code is compatible with the current schema
3. If schema incompatibility exists, restore the database from backup instead of relying on Helm rollback alone
4. Keep database backups before every upgrade (see [Backup & Restore](BACKUP-RESTORE.md))

## Inspecting Lock State

If you suspect a stuck advisory lock:

```sql
-- Check active advisory locks:
SELECT pid, classid, objid, granted
FROM pg_locks
WHERE locktype = 'advisory';

-- Find the session holding the migration lock (738291456):
SELECT pid, query, state, query_start
FROM pg_stat_activity
WHERE pid IN (
  SELECT pid FROM pg_locks
  WHERE locktype = 'advisory' AND objid = 738291456
);

-- Terminate a stuck session (use with caution):
SELECT pg_terminate_backend(<pid>);
```

## Troubleshooting

### Lock Contention

**Symptom:** Migration fails with "could not acquire advisory lock after 30 retries".

**Causes:**
- Another migration is still running
- A previous migration crashed without releasing the connection (lock auto-releases on disconnect)
- Connection pooler (PgBouncer) is holding the connection open

**Fix:**
1. Check for running migration Jobs: `kubectl get jobs -n biznez`
2. Inspect advisory locks using the SQL queries above
3. If a stuck connection exists, terminate it with `pg_terminate_backend`
4. Retry the migration

### Migration Timeout

**Symptom:** Migration Job exceeds its deadline and is terminated.

**Causes:**
- Large data migration on a slow database
- Lock contention (see above)
- Network issues between the migration pod and database

**Fix:**
- Increase `migration.jobTtlSeconds` for hook mode
- For large migrations, use `manual` mode and run from a persistent session
- Check database connection latency

### Partial Migration

**Symptom:** Migration partially applied — some tables/columns exist, others don't.

**Causes:**
- Migration was interrupted (OOM kill, node eviction, network timeout)
- Alembic versioning table shows a version that doesn't match the schema

**Fix:**
1. Connect to the database and inspect `alembic_version` table
2. Compare against the expected schema for that version
3. If the schema is consistent with the version, retry the migration
4. If the schema is inconsistent, restore from backup and retry
