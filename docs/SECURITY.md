# Security Guide

This document describes the security controls in the Biznez Agentic Runtime deployment. It is intended for security reviewers and procurement teams evaluating the platform.

## Classification Key

Each security control is classified by enforcement level:

| Classification | Meaning |
|---|---|
| **Chart-enforced** | Set in Helm templates; always active regardless of values |
| **Default in values.yaml** | Set in default values but overridable by the operator |
| **Cluster-recommended** | Requires cluster-level configuration outside the chart |

## Pod Security

### Chart-enforced

The following settings are applied to all containers via Helm template helpers (`_helpers.tpl`) and cannot be disabled through values:

- **`runAsNonRoot: true`** — All pods run as non-root users
- **`readOnlyRootFilesystem: true`** — Container filesystems are read-only (writable `/tmp` via emptyDir)
- **`allowPrivilegeEscalation: false`** — Prevents privilege escalation via setuid/setgid
- **`capabilities.drop: ["ALL"]`** — All Linux capabilities dropped

### Default in values.yaml

These settings are configured in `global.podSecurityContext` and `global.containerSecurityContext` but can be overridden per component:

- **`seccompProfile.type: RuntimeDefault`** — Uses the container runtime's default seccomp profile. Overridable by setting `global.podSecurityContext.seccompProfile`.
- **`fsGroup: 1000`** — File system group for volume mounts. Overridable per component.
- **`runAsUser: 1000`** / **`runAsGroup: 1000`** — Default UID/GID for containers.

### Cluster-recommended

- **Pod Security Admission (PSA) `restricted` profile** — Apply the `restricted` PSA label to the namespace for cluster-level enforcement. The chart templates are compatible with the `restricted` profile, but the chart does not apply the namespace label itself.

  ```bash
  kubectl label namespace biznez pod-security.kubernetes.io/enforce=restricted
  ```

## Container Hardening

Per-component security contexts are merged on top of global defaults:

| Component | UID | GID | readOnlyRootFilesystem | Notes |
|-----------|-----|-----|----------------------|-------|
| Backend | 1000 | 1000 | true | `/tmp` via emptyDir |
| Frontend (nginx) | 101 | 101 | true | nginx user; `/tmp` via emptyDir |
| PostgreSQL | 999 | 999 | **false** | Postgres requires writable data directory |
| Gateway | 1000 | 1000 | true | `/tmp` via emptyDir |

PostgreSQL's `readOnlyRootFilesystem: false` is necessary because PostgreSQL writes to its data directory. The embedded PostgreSQL is evaluation-only; production deployments use an external managed database where hardening is the cloud provider's responsibility.

## Secret Management

### Pattern: existingSecret

The chart uses an `existingSecret` pattern for all sensitive data:

- **Eval mode:** Inline secrets can be set in `values.yaml` (e.g., `backend.secrets.encryptionKey`). The chart creates K8s Secrets from these values.
- **Production mode:** Inline secrets are forbidden. Operators must pre-create K8s Secrets and reference them via `*.existingSecret` values. Production validation guards enforce this.

**Secret ownership boundaries:**

| Values Key | K8s Secret Contains | Used By |
|------------|-------------------|---------|
| `backend.existingSecret` | `ENCRYPTION_KEY`, `JWT_SECRET_KEY` | Backend |
| `postgres.external.existingSecret` | `DATABASE_URL` | Backend (via `_helpers.tpl` db-credentials) |
| `llm.existingSecret` | `LLM_API_KEY` | Backend |
| `langfuse.existingSecret` | `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` | Backend |
| `gateway.existingSecret` | Target-specific API keys | Gateway |
| `auth.existingSecret` | `AUTH_CLIENT_SECRET` | Backend |

### Known Risk: Environment Variable Injection

Secrets are injected as environment variables, not file mounts. This is a deliberate v1 trade-off:

- **Risk:** Environment variables appear in `/proc/<pid>/environ`, `kubectl exec env`, and process listings. Container escape or RBAC misconfiguration could expose secrets.
- **Mitigations:**
  - Namespace-scoped RBAC restricts Secret access (chart creates only `Role`, not `ClusterRole`)
  - Kubernetes audit logging tracks Secret reads
  - `readOnlyRootFilesystem` prevents writing secrets to disk
- **Future:** File-based secret injection (CSI driver or projected volumes) is planned for v2.

## Artifact Signing and Verification

Container images can be signed during the release build process using [cosign](https://github.com/sigstore/cosign).

### Key-pair mode

```bash
# During build:
biznez-cli build-release --version 1.0.0 --policy sign

# During deployment:
biznez-cli verify-images --key cosign.pub --registry registry.example.com/biznez
```

### Keyless mode (Sigstore/Fulcio)

```bash
biznez-cli verify-images --keyless --registry registry.example.com/biznez
```

Verification checks:
1. Cosign signature exists for each image digest
2. Image tag in the registry matches the digest in `images.lock`
3. Tag integrity: `--skip-tag-check` skips the tag-to-digest comparison (use if tags are not pushed)

## Vulnerability Management

### Build-time scanning

`biznez-cli build-release` runs Trivy vulnerability scans on all container images during the release build. Scan results are saved alongside the release artifacts.

Skip with `--skip-scan` (not recommended for production releases).

### SBOM generation

Syft generates SPDX-format Software Bill of Materials for each image during `build-release`. SBOMs are saved alongside release artifacts.

Skip with `--skip-sbom` (not recommended for production releases).

### Recommended cadence

- Scan images on every release build
- Re-scan deployed images weekly or when new CVE databases are published
- Archive SBOMs for compliance and audit

## Network Isolation

When `networkPolicy.enabled: true`, the chart creates four NetworkPolicy resources:

### Backend NetworkPolicy

- **Ingress:** Allows traffic from frontend pods, gateway pods, and the ingress controller namespace
- **Egress:** DNS, PostgreSQL (if embedded), gateway, and configurable external targets

### Frontend NetworkPolicy

- **Ingress:** Allows traffic from the ingress controller namespace
- **Egress:** DNS and backend pods only

### PostgreSQL NetworkPolicy (eval only)

- **Ingress:** Backend pods on port 5432 only
- **Egress:** None (fully isolated)

### Gateway NetworkPolicy

- **Ingress:** Backend pods only
- **Egress:** DNS, external HTTPS (if `allowAllHttps`), proxy CIDRs, external service CIDRs, MCP target namespaces

### Egress strategies

| Strategy | Description | Values |
|----------|------------|--------|
| A. Allow all HTTPS | Open port 443 to any destination (eval default) | `networkPolicy.egress.allowAllHttps: true` |
| B. Corporate proxy | Route through a forward proxy | `networkPolicy.egress.proxy.cidrs`, `.ports` |
| C. Explicit CIDRs | Allowlist specific IP ranges | `networkPolicy.egress.externalServices.cidrs`, `.ports` |
| D. MCP namespace | Allow egress to in-cluster MCP services | `networkPolicy.egress.mcpTargets.namespaceSelectors`, `.ports` |

Production deployments should disable Strategy A and use B, C, or D. See [Networking Guide](NETWORKING.md) for detailed configuration.

## RBAC Model

### Chart-enforced: namespace-scoped only

The chart creates only namespaced resources:
- `ServiceAccount`
- `Role` (not `ClusterRole`)
- `RoleBinding` (not `ClusterRoleBinding`)

Zero cluster-scoped resources are created. This is enforced by the OPA policy `policies/no-cluster-scoped.rego` in CI.

If the backend requires cross-namespace access (e.g., agent workspace management), the operator must pre-create a `ClusterRole`/`ClusterRoleBinding` outside this chart.

### OPA policy enforcement

Three OPA/conftest policies run in CI:

| Policy | Enforces |
|--------|----------|
| `no-cluster-scoped.rego` | No ClusterRole, ClusterRoleBinding, or other cluster-scoped resources |
| `no-frontend-secrets.rego` | Frontend pods never receive Secret references |
| `no-gcp-in-dist.rego` | No GCP-specific references (ensures cloud-agnostic distribution) |

## Image Integrity

### Digest pinning

Set `global.requireDigests: true` to require digest-pinned image references for all components. The `_helpers.tpl` image reference helper fails if any `image.digest` is empty when this is enabled.

This prevents tag mutation attacks where an attacker replaces a tagged image in the registry with a different image.

### images.lock manifest

The `helm/biznez-runtime/images.lock` file pins exact image digests for a release. Schema:

```yaml
version: "1.0.0"
platform: linux/amd64
images:
  - name: platform-api
    sourceRepo: "ghcr.io/biznez-agentic/runtime-backend"
    targetRepo: "biznez/platform-api"
    releaseRepo: "registry.example.com/biznez/platform-api"
    tag: "1.0.0"
    imageDigest: "sha256:abc..."
    indexDigest: "sha256:def..."
```

Fields: `name`, `sourceRepo` (build origin), `targetRepo` (chart default), `releaseRepo` (customer registry), `tag`, `imageDigest` (platform-specific), `indexDigest` (multi-arch manifest).

## Known Risks and Mitigations

| Risk | Severity | Mitigation | Status |
|------|----------|-----------|--------|
| Environment variable secret leakage | Medium | Namespace RBAC, audit logging, readOnlyRootFilesystem | Accepted (v1); file-based injection planned (v2) |
| Embedded PostgreSQL not hardened | Low (eval only) | Production requires external managed DB (enforced by guard) | By design |
| Frontend receives no secrets | Low | Enforced by OPA policy `no-frontend-secrets.rego` | Enforced |
| seccompProfile overridable | Low | Default `RuntimeDefault` in values; operator can override | Acceptable |
| PSA label not applied by chart | Info | Operator applies namespace label; chart templates are compatible | Documentation |
