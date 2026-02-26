# biznez-runtime-dist

Distribution packaging for the Biznez Agentic Runtime platform.

## Repository Purpose

This repo contains everything needed to **deploy** the Biznez Agentic Runtime on client infrastructure:

- **Helm chart** (`helm/biznez-runtime/`) -- Kubernetes deployment for eval and production
- **Docker Compose** (`compose/`) -- single-machine evaluation and demos
- **Installer CLI** (`cli/biznez-cli`) -- operator tooling (validate, install, migrate, health-check)
- **Documentation** (`docs/`) -- install guides, production checklist, security, networking
- **OPA policies** (`policies/`) -- CI gates ensuring packaging principles (no cluster-scoped resources, no GCP leaks)
- **Release tooling** (`release/`) -- build-release script, image manifest, signing
- **Dev harness** (`dev/`) -- kind/minikube local development workflow

## Relationship to Runtime Repo

| Concern | Repo |
|---------|------|
| Application code, Dockerfiles, migrations, internal GKE manifests, CI that builds images | [`biznez-agentic-runtime`](https://github.com/biznez-agentic/biznez-agentic-runtime) |
| Helm chart, Docker Compose, CLI, docs, policies, release tooling | **This repo** (`biznez-runtime-dist`) |

The runtime repo builds container images. This repo consumes them via `images.lock` (pinned digests).

### Cross-Repo Contract

- **`config-contract.yaml`** in the runtime repo defines the env vars and config keys the app reads.
- **`versions.yaml`** in this repo maps each dist release to a runtime release tag, git SHA, and image digests.
- At release time, `release/build-release.sh` pulls images from the runtime CI, pins digests in `images.lock`, and produces release artifacts.

## Quick Start (Development)

```bash
# Prerequisites: helm, kind (or minikube), docker

# 1. Clone both repos side-by-side
git clone https://github.com/biznez-agentic/biznez-agentic-runtime.git
git clone https://github.com/biznez-agentic/biznez-runtime-dist.git

# 2. Build and load images into kind
cd biznez-runtime-dist
make kind-install    # creates kind cluster, builds images from ../biznez-agentic-runtime, installs chart

# 3. Run CI gates
make all             # lint, template, kubeconform, conftest
```

## Development Workflow

```bash
# Lint the Helm chart
make lint

# Render templates (dry-run)
make template

# Validate rendered YAML against K8s schemas
make kubeconform

# Run OPA policy checks (no cluster-scoped resources, no GCP leaks)
make conftest

# Full local install on kind
make kind-install

# Run smoke tests
make smoke-test
```

## Project Structure

```
biznez-runtime-dist/
  helm/biznez-runtime/       # Helm chart
  compose/                   # Docker Compose (eval/demo)
  cli/                       # Installer CLI
  docs/                      # Client-facing documentation
  policies/                  # OPA/conftest policies (CI gates)
  tests/                     # Test values, snapshots, smoke tests
  release/                   # Release build tooling
  dev/                       # Local dev harness (kind, image loading)
  examples/                  # Example values files
  contracts/                 # Pinned config contract from runtime
  versions.yaml              # Release version mapping
  Makefile                   # CI/dev command targets
```

## Phased Implementation

See [docs/PHASES.md](docs/PHASES.md) for the phased implementation plan.
See [docs/PACKAGING-PLAN.md](docs/PACKAGING-PLAN.md) for the full packaging architecture.
