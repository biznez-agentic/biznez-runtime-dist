# Installation Guide

This guide covers installing the Biznez Agentic Runtime on Kubernetes (Helm) and Docker Compose. Choose the path that fits your environment.

## GCP Eval Environment (Automated)

For GCP-hosted eval environments, a one-command bootstrap sets up all prerequisites and a GitHub Actions workflow handles provisioning.

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/biznez-agentic/biznez-runtime-dist&cloudshell_tutorial=docs/BOOTSTRAP-CLOUDSHELL.md)

Or run locally:

```bash
# Preview what will be created
./infra/scripts/bootstrap-gcp.sh --project <your-project-id> --dry-run

# Run the bootstrap
./infra/scripts/bootstrap-gcp.sh --project <your-project-id>
```

After bootstrap, trigger the **Provision Eval Environment** workflow from GitHub Actions to create a GKE cluster and deploy the runtime.

See [Bootstrap Cloud Shell Tutorial](BOOTSTRAP-CLOUDSHELL.md) for the guided walkthrough.

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| kubectl | v1.28+ | Kubernetes CLI |
| helm | v3.14+ | Chart installation |
| biznez-cli | shipped in this repo | Operator CLI (wraps helm/kubectl) |

Optional:
- **Docker** — required for Docker Compose path
- **cosign** — required for image signature verification (`biznez-cli verify-images`)
- **yq** — preferred YAML parser for release tooling (falls back to awk)

## Evaluation Quick-Start (Kubernetes)

Run these 4 commands to get a working evaluation instance:

```bash
biznez-cli generate-secrets --format yaml | kubectl apply -n biznez -f -
biznez-cli install -f examples/eval-quickstart.yaml --create-namespace
biznez-cli health-check
kubectl port-forward svc/biznez-frontend 8080:80 -n biznez
```

Open http://localhost:8080 in your browser. Check backend logs for first-run admin credentials:

```bash
kubectl logs deploy/biznez-backend -n biznez | grep -iE 'admin|password|created'
```

> **Note:** `--create-namespace` creates the `biznez` namespace if it does not exist. The `generate-secrets` command creates `ENCRYPTION_KEY`, `JWT_SECRET_KEY`, and `POSTGRES_PASSWORD` and wraps them in a Kubernetes Secret manifest.

## Evaluation Quick-Start (Docker Compose)

```bash
cd compose && bash setup.sh
```

The `setup.sh` script:
1. Checks prerequisites (Docker, Compose v2 plugin)
2. Creates `.env` from template with generated secrets
3. Starts all services (backend, frontend, postgres, gateway)
4. Validates nginx config
5. Waits for health checks
6. Prints access URLs

For air-gapped Docker environments, set `COMPOSE_PULL_POLICY=never` in `.env` and pre-load images with `docker load -i <archive>.tar`.

Options:
- `setup.sh --generate-only` — generate secrets without starting services
- `setup.sh --show-secrets` — print generated secrets to terminal (opt-in)

## Production Install (Step-by-Step)

### Step 1: Create Secrets

Create Kubernetes Secrets before installing. The chart requires pre-created Secrets in production (`global.profile: production`).

**Required Secrets:**

| Secret Name | Required Keys | Values Key |
|-------------|--------------|------------|
| Backend secrets | `ENCRYPTION_KEY`, `JWT_SECRET_KEY` | `backend.existingSecret` |
| Database credentials | `DATABASE_URL` | `postgres.external.existingSecret` |
| LLM API key (if provider set) | `LLM_API_KEY` | `llm.existingSecret` |
| Gateway keys (if gateway enabled) | Target-specific API keys | `gateway.existingSecret` |
| Auth client secret (if OIDC) | `AUTH_CLIENT_SECRET` | `auth.existingSecret` |

Example:

```bash
kubectl create namespace biznez

kubectl create secret generic biznez-backend-secrets \
  --from-literal=ENCRYPTION_KEY="$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')" \
  --from-literal=JWT_SECRET_KEY="$(openssl rand -base64 32)" \
  -n biznez

kubectl create secret generic biznez-db-credentials \
  --from-literal=DATABASE_URL="postgresql://user:pass@db.example.com:5432/biznez_platform?sslmode=require" \
  -n biznez
```

### Step 2: Configure Private Registry (if applicable)

```bash
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=<user> \
  --docker-password=<token> \
  -n biznez
```

Set in your values file:

```yaml
global:
  imageRegistry: "registry.example.com/biznez"
  imagePullSecrets:
    - name: regcred
```

### Step 3: Prepare Values File

Start from `examples/production-minimal.yaml` and customize for your environment. See [Production Checklist](PRODUCTION-CHECKLIST.md) for all required fields.

### Step 4: Validate

```bash
biznez-cli validate -f values.yaml --profile production
```

This runs Helm template rendering which triggers all validation guards. Fix any errors before proceeding.

### Step 5: Install

```bash
biznez-cli install -f values.yaml --create-namespace
```

### Step 6: Health Check

```bash
biznez-cli health-check
```

### Step 7: Run Migrations (manual mode)

If using `migration.mode: manual` (recommended for production):

```bash
biznez-cli migrate --namespace biznez
```

Use `--dry-run` first to inspect what will run:

```bash
biznez-cli migrate --namespace biznez --dry-run
```

See [Migration Guide](MIGRATION-GUIDE.md) for details on migration modes.

## Air-Gapped Install

For environments without internet access:

### 1. Export Images (from connected machine)

```bash
biznez-cli export-images --manifest helm/biznez-runtime/images.lock --output biznez-images.tar.gz
```

### 2. Transfer Archive

Copy `biznez-images.tar.gz` to the air-gapped environment.

### 3. Import Images

```bash
# Into a private registry:
biznez-cli import-images --archive biznez-images.tar.gz --registry registry.internal:5000

# Or directly into local Docker:
biznez-cli import-images --archive biznez-images.tar.gz --docker
```

### 4. Install with Registry Override

```bash
biznez-cli install -f values.yaml --set global.imageRegistry=registry.internal:5000
```

## Uninstall

```bash
biznez-cli uninstall
```

Options:
- `--delete-pvcs` — delete PersistentVolumeClaims matching the release
- `--delete-namespace` — delete the namespace after uninstall
- `--yes` — skip confirmation prompts

To uninstall and clean up everything:

```bash
biznez-cli uninstall --delete-pvcs --delete-namespace --yes
```

## Troubleshooting

### ImagePullBackOff

Pod cannot pull the container image.

```bash
kubectl describe pod <pod-name> -n biznez
```

Common causes:
- Missing `imagePullSecrets` — verify `global.imagePullSecrets` is set and the Secret exists
- Wrong registry — check `global.imageRegistry` matches your registry
- Air-gapped without images loaded — run `biznez-cli import-images` first

### CrashLoopBackOff

Pod starts but exits immediately.

```bash
kubectl logs <pod-name> -n biznez --previous
```

Common causes:
- Missing or invalid secrets — run `biznez-cli validate-secrets` to check
- Database unreachable — verify `postgres.external.host` and network connectivity
- Migration not run — if `migration.mode: manual`, run `biznez-cli migrate`

### Pending PVC

PersistentVolumeClaim stuck in Pending state (embedded postgres).

```bash
kubectl describe pvc -n biznez
```

Common causes:
- No default StorageClass — set `global.storageClass` or configure a cluster default
- Insufficient capacity — check node storage

### OIDC Authentication Errors

```bash
kubectl logs deploy/biznez-backend -n biznez | grep -i oidc
```

Common causes:
- Issuer URL mismatch — ensure `auth.oidc.issuer` matches exactly (including trailing slash behavior)
- Audience mismatch — `auth.oidc.audience` must match the OAuth2 client ID
- Clock skew — increase `auth.oidc.clockSkewSeconds` (default: 30)
- JWKS unreachable — verify egress to the OIDC provider is allowed by network policies

Run `biznez-cli oidc-discover --issuer <url>` to verify provider metadata. See [OIDC Setup](OIDC-SETUP.md) for full configuration.

### Helm Template Validation Failures

If `biznez-cli validate` or `biznez-cli install` fails with a guard error, the error message includes the specific values key to fix. Common production guard failures:

- `backend.existingSecret` required — create the backend secrets K8s Secret
- `postgres.enabled=false` required — disable embedded postgres for production
- `postgres.external.existingSecret` required — create the DB credentials Secret
- Inline secrets forbidden — remove `backend.secrets.*` values, use `existingSecret` instead

See [Production Checklist](PRODUCTION-CHECKLIST.md) for the complete list.
