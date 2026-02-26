# Biznez Runtime Dist - Claude Code Context

## What This Repo Is

This is the **distribution packaging** repo for the Biznez Agentic Runtime platform. It contains the Helm chart, Docker Compose setup, installer CLI, documentation, OPA policies, and release tooling needed to deploy the platform on client infrastructure.

**This repo does NOT contain application code, Dockerfiles, or migrations.** Those live in the runtime repo.

## Two-Repo Architecture

| Repo | Path | Purpose |
|------|------|---------|
| **biznez-agentic-runtime** (runtime) | `/Users/manimaun/Documents/code/biznez-agentic-framework` | App code, Dockerfiles, migrations, internal GKE manifests, CI that builds images |
| **biznez-runtime-dist** (this repo) | `/Users/manimaun/Documents/code/biznez-runtime-dist` | Helm chart, Docker Compose, CLI, docs, policies, release tooling |

### Cross-Repo Rules

- **NEVER write files to the runtime repo from this session.** Read-only access only.
- When you need to reference runtime repo files (K8s manifests, config.py, Dockerfiles), use the absolute path: `/Users/manimaun/Documents/code/biznez-agentic-framework/...`
- The runtime repo owns `config-contract.yaml` (source of truth). This repo ships a pinned copy in `contracts/`.
- `versions.yaml` maps dist releases to runtime release tags and image digests.
- `images.lock` pins container image digests built by the runtime repo CI.

## Repo Structure

```
biznez-runtime-dist/
  helm/biznez-runtime/       # Helm chart (Phase 1-5)
    Chart.yaml
    values.yaml              # Eval defaults
    values-production.yaml   # CIS-hardened production overrides
    images.lock              # Pinned image digests
    templates/
      _helpers.tpl
      backend/               # Backend deployment, service, configmap, secret, hpa, migration-job
      frontend/              # Frontend deployment, service, configmap
      postgres/              # PostgreSQL statefulset, service, secret, pvc (eval only)
      gateway/               # Agent Gateway deployment, service, configmap, secret
      ingress.yaml
      gateway-api.yaml
      networkpolicy.yaml
      rbac.yaml
      NOTES.txt
  compose/                   # Docker Compose (Phase 6)
    docker-compose.yml
    .env.template
    nginx.conf
    setup.sh
  cli/                       # Installer CLI (Phase 7)
    biznez-cli
  docs/                      # Client-facing documentation (Phase 9)
    PACKAGING-PLAN.md        # Full packaging architecture (reference)
    PHASES.md                # Phased implementation plan (reference)
    INSTALL.md
    PRODUCTION-CHECKLIST.md
    MIGRATION-GUIDE.md
    OIDC-SETUP.md
    SECURITY.md
    BACKUP-RESTORE.md
    NETWORKING.md
    UPGRADE.md
  policies/                  # OPA/conftest policies (Phase 2.5)
    no-cluster-scoped.rego
    no-frontend-secrets.rego
    no-gcp-in-dist.rego
  tests/                     # Test values and smoke tests
    values/
    snapshots/
    smoke-test.sh
  release/                   # Release build tooling (Phase 8)
    build-release.sh
  dev/                       # Local dev harness
    kind-install.sh
    load-local-images.sh
  examples/                  # Example values files
  contracts/                 # Pinned config contract from runtime
  versions.yaml              # Release version mapping
  Makefile                   # CI/dev command targets
```

## Implementation Phases

| Phase | Name | Status |
|-------|------|--------|
| 0 | Repo Setup & Config Contract | COMPLETE |
| 1 | Chart Foundation (Chart.yaml, values.yaml, _helpers.tpl) | Not started |
| 2 | Core Services + NOTES.txt | Not started |
| 2.5 | Contract Tests & CI Gates | Not started |
| 3 | Gateway & Migrations | Not started |
| 4 | Networking | Not started |
| 5 | Production Hardening | Not started |
| 6 | Docker Compose | Not started |
| 7 | Operator CLI | Not started |
| 8 | Release Pipeline & Tooling | Not started |
| 9 | Documentation | Not started |

Full details: [docs/PHASES.md](docs/PHASES.md)
Full packaging architecture: [docs/PACKAGING-PLAN.md](docs/PACKAGING-PLAN.md)

## Key Design Principles

- **Zero cluster-scoped resources** -- namespaced only (enforced by OPA policy)
- **No GCP-specific references** -- cloud-agnostic (enforced by OPA policy)
- **Frontend never receives secrets** -- ConfigMap only (enforced by OPA policy)
- **existingSecret everywhere** -- inline secrets only for eval, production requires pre-created K8s Secrets
- **Embedded PostgreSQL for eval only** -- production requires external managed DB
- **OIDC-first auth** -- local JWT only as fallback for evaluation

## Development Commands

```bash
make lint          # helm lint
make template      # helm template (dry-run render)
make kubeconform   # validate rendered YAML against K8s schemas
make conftest      # run OPA policy checks
make all           # all of the above
make kind-install  # full local install on kind cluster
make smoke-test    # run smoke tests
```

## Runtime Repo Reference Files

When building Helm templates, read these from the runtime repo (read-only):

| Runtime Repo File | What It Contains |
|-------------------|------------------|
| `src/agentic_runtime/core/config.py` | RuntimeConfig class -- env var names the app reads |
| `.env.example` | Complete environment variable list |
| `k8s/base/platform-api-deployment.yaml` | Backend deployment spec, probes, env vars |
| `k8s/base/frontend/frontend-deployment.yaml` | Frontend deployment spec |
| `k8s/base/postgres-statefulset.yaml` | PostgreSQL StatefulSet spec |
| `k8s/base/platform-configmap.yaml` | ConfigMap structure and keys |
| `k8s/base/platform-secrets.yaml` | Secret structure and required keys |
| `k8s/mcp-gateway/deployment.yaml` | Gateway deployment spec |
| `k8s/mcp-gateway/configmap.yaml` | Gateway config structure |
| `k8s/rbac/platform-api-rbac.yaml` | RBAC resources |
| `docker-compose.yml` | Existing Docker Compose structure |
| `frontend/nginx.conf` | Nginx configuration |
| `Dockerfile` | Backend image build |
| `frontend/Dockerfile` | Frontend image build |
| `alembic.ini` | Migration config |

## Git Workflow

- `main` branch for this repo
- Create feature branches for each phase (e.g., `feature/phase-1-chart-foundation`)
- PR to `main` when phase is complete
- GitHub remote: `https://github.com/biznez-agentic/biznez-runtime-dist`
