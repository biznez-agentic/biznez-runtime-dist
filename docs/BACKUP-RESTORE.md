# Backup & Restore Guide

This guide covers backup and restore procedures for the Biznez Agentic Runtime database, covering both embedded (eval) and external managed (production) PostgreSQL.

## Overview

| Environment | Database | Backup Responsibility |
|-------------|----------|----------------------|
| Evaluation | Embedded PostgreSQL (in-cluster) | Operator via `biznez-cli` |
| Production | External managed DB (RDS, Cloud SQL, etc.) | Client/cloud provider |

## Embedded PostgreSQL (Evaluation)

The embedded PostgreSQL is a single-replica StatefulSet with a PVC. Use the CLI for backup and restore.

### Backup

```bash
biznez-cli backup-db --namespace biznez --output backup.sql
```

This runs `pg_dump` against the embedded PostgreSQL pod and saves the output to a local file. The backup contains the full schema and data.

Options:
- `--output <file>` — output file path (default: stdout)
- `--format <plain|custom>` — pg_dump format (default: plain)

### Restore

```bash
biznez-cli restore-db --namespace biznez --input backup.sql
```

This runs `pg_restore` (or `psql` for plain format) against the embedded PostgreSQL pod.

**Pre-restore checklist:**

1. Scale down the backend to avoid writes during restore:
   ```bash
   kubectl scale deploy/biznez-backend --replicas=0 -n biznez
   ```
2. Verify the backup file is complete and accessible
3. Restore:
   ```bash
   biznez-cli restore-db --namespace biznez --input backup.sql
   ```
4. Scale the backend back up:
   ```bash
   kubectl scale deploy/biznez-backend --replicas=1 -n biznez
   ```
5. Verify with health check:
   ```bash
   biznez-cli health-check
   ```

## External Managed Database (Production)

Production deployments use an external managed database. Backup and restore are the responsibility of the database operator using the cloud provider's native tools:

- **AWS RDS:** Automated snapshots, manual snapshots, point-in-time recovery
- **Google Cloud SQL:** Automated backups, on-demand backups, PITR
- **Azure Database for PostgreSQL:** Automated backups, geo-redundant backups
- **Self-managed PostgreSQL:** `pg_dump`/`pg_restore`, WAL archiving, pgBackRest

The Biznez chart does not manage external database backups. Configure these in your cloud provider's console or IaC.

## Recommended Schedule

| Item | Frequency | Retention |
|------|-----------|-----------|
| Full database backup | Daily | 30 days minimum |
| Transaction log / WAL | Continuous (if PITR enabled) | 7 days minimum |
| Pre-upgrade backup | Before every `biznez-cli upgrade` | Until next successful upgrade verified |

Adjust retention based on your compliance requirements.

## Disaster Recovery

To rebuild from scratch after a complete cluster loss:

### 1. Prerequisites

Gather these artifacts:
- Database backup (SQL dump or cloud snapshot)
- Helm values file (`values.yaml`)
- Image archive (if air-gapped): `biznez-images.tar.gz`
- Secrets (stored securely outside the cluster)

### 2. Rebuild Steps

```bash
# 1. Create namespace
kubectl create namespace biznez

# 2. Re-create secrets
kubectl create secret generic biznez-backend-secrets \
  --from-literal=ENCRYPTION_KEY="<saved-key>" \
  --from-literal=JWT_SECRET_KEY="<saved-key>" \
  -n biznez

kubectl create secret generic biznez-db-credentials \
  --from-literal=DATABASE_URL="<connection-string>" \
  -n biznez

# 3. Import images (if air-gapped)
biznez-cli import-images --archive biznez-images.tar.gz --registry registry.internal:5000

# 4. Restore database from backup (external DB)
# Use your cloud provider's restore procedure

# 5. Install the platform
biznez-cli install -f values.yaml

# 6. Verify
biznez-cli health-check
```

### 3. Post-recovery Verification

- Verify all pods are running: `biznez-cli status`
- Verify database connectivity: check backend logs
- Verify authentication: test OIDC login flow
- Verify data integrity: spot-check application data
