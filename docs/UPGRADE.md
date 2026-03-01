# Upgrade Guide

This guide covers upgrading the Biznez Agentic Runtime to a new version, including pre-upgrade checks, air-gapped upgrades, rollback procedures, and migration handling.

## Pre-Upgrade Checklist

- [ ] **Back up the database** — Take a full backup before any upgrade. See [Backup & Restore](BACKUP-RESTORE.md).
- [ ] **Review the changelog** — Check release notes for breaking changes, new required values, or deprecated configuration.
- [ ] **Verify new images are available** — For air-gapped environments, import new images before upgrading.
- [ ] **Dry-run migration** — If using `migration.mode: manual`, inspect pending migrations:
  ```bash
  biznez-cli migrate --namespace biznez --dry-run
  ```
- [ ] **Validate new values** — Run validation against the new chart version:
  ```bash
  biznez-cli validate -f values.yaml --profile production
  ```

## Standard Upgrade

```bash
biznez-cli upgrade -f values.yaml
```

The `upgrade` command:
1. Runs pre-flight checks (namespace exists, release exists, values validate)
2. Executes `helm upgrade` with your values file
3. Waits for the rollout to complete
4. Runs a health check

If the health check fails, the CLI reports the failure but does not automatically roll back. Review pod logs before deciding to roll back.

### Specifying a chart version

```bash
biznez-cli upgrade -f values.yaml -- --version 1.2.0
```

Flags after `--` are passed through to `helm upgrade`.

## Air-Gapped Upgrade

### 1. Import New Images

On the connected machine, export images for the new version:

```bash
biznez-cli export-images --manifest helm/biznez-runtime/images.lock --output biznez-images-v1.2.0.tar.gz
```

Transfer to the air-gapped environment and import:

```bash
biznez-cli import-images --archive biznez-images-v1.2.0.tar.gz --registry registry.internal:5000
```

### 2. Update Values (if needed)

If the new version introduces required values or changes defaults, update your `values.yaml`. The changelog will note any required changes.

### 3. Upgrade

```bash
biznez-cli upgrade -f values.yaml
```

## Rollback Procedure

If the upgrade fails or causes issues:

```bash
helm rollback biznez -n biznez
```

Or roll back to a specific revision:

```bash
helm history biznez -n biznez
helm rollback biznez <revision> -n biznez
```

**Database migration caveat:** Helm rollback reverts templates (deployments, configmaps, etc.) but does **NOT** reverse database migrations. Alembic migrations are forward-only. If the new schema is incompatible with the old code, you must restore the database from backup rather than relying on Helm rollback alone. This is why the pre-upgrade checklist starts with a database backup. See [Migration Guide](MIGRATION-GUIDE.md) for more details on migration and rollback interaction.

### When to rollback vs restore

| Scenario | Action |
|----------|--------|
| New code has bugs, but DB schema is backward-compatible | Helm rollback is safe |
| Migration added nullable columns (expand phase) | Helm rollback is safe |
| Migration dropped/renamed columns the old code uses | Restore DB from backup + Helm rollback |
| Migration is partially applied | Restore DB from backup + retry upgrade |

## Breaking Changes

### Checking for breaking changes

1. Read the release notes for the target version
2. Run `biznez-cli validate -f values.yaml --profile production` against the new chart
3. Check for deprecated values keys in the changelog

### Config contract changes

The `contracts/config-contract.yaml` file defines the interface between the chart and the runtime application. If a new version changes the contract (new env vars, renamed keys, removed keys), the changelog will document it.

Compare contracts between versions:

```bash
diff contracts/config-contract.yaml <new-version>/contracts/config-contract.yaml
```

## Migration During Upgrade

Database migrations may be required when upgrading. How they run depends on your `migration.mode`:

### `hook` mode (automatic)

Migrations run automatically as a Helm pre-upgrade Job. The Job completes before the new deployment rolls out. No operator action needed.

### `manual` mode (operator-controlled)

Migrations do not run automatically. After upgrading:

```bash
# Inspect pending migrations first:
biznez-cli migrate --namespace biznez --dry-run

# Apply migrations:
biznez-cli migrate --namespace biznez
```

For zero-downtime upgrades with manual mode, coordinate the migration with the rollout:
1. Run expand migrations (add new columns/tables)
2. Upgrade the deployment
3. Run contract migrations (remove old columns) in a subsequent release

See [Migration Guide](MIGRATION-GUIDE.md) for the full expand/contract pattern.

### `auto` mode

Migrations run as an initContainer on every pod start. The new pods will run migrations before the backend starts. This may cause brief unavailability during the rollout as pods wait for migration to complete.

## Canary / Blue-Green Deployments

The chart does not include built-in canary or blue-green deployment mechanisms. For operators who want progressive delivery:

### Canary with Argo Rollouts

Deploy the chart normally, then wrap the backend Deployment with an Argo Rollout:
1. Install Argo Rollouts controller
2. Create a Rollout resource that references the backend Deployment
3. Configure canary steps (weight, pause, analysis)

### Blue-Green with separate releases

Install two releases in the same namespace (or different namespaces) and switch traffic at the ingress/gateway level:

```bash
# Blue (current):
biznez-cli install -f values-blue.yaml -r biznez-blue

# Green (new version):
biznez-cli install -f values-green.yaml -r biznez-green

# Switch ingress to green, verify, then remove blue
```

Both approaches require manual coordination with database migrations.
