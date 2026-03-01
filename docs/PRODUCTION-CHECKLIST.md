# Production Readiness Checklist

Complete each item before deploying to production. Every item maps to a validation guard enforced by the Helm chart or `biznez-cli validate --profile production`.

Format: **What** — Why — How (values key or CLI command).

## 1. Infrastructure

- [ ] **External managed database** — Embedded PostgreSQL is not hardened or HA. Production requires a managed DB (RDS, Cloud SQL, Azure Database, etc.).
  - Set `postgres.enabled: false` *(guard in `validate.yaml`: embedded postgres forbidden in production)*
  - Set `postgres.external.host` to the managed DB hostname *(guard: external host required for wait-for-db healthcheck)*

- [ ] **Storage class** — PVC provisioning requires a StorageClass (only if embedded postgres used for non-production).
  - Set `global.storageClass` or ensure a cluster default exists

- [ ] **Namespace** — Isolate the deployment in a dedicated namespace.
  - `kubectl create namespace biznez` or use `--create-namespace`

## 2. Secrets

All secrets must be pre-created Kubernetes Secrets. Production guards forbid inline secret values in `values.yaml`.

- [ ] **Backend secrets** — Contains application encryption and JWT signing keys.
  - Create Secret with keys: `ENCRYPTION_KEY`, `JWT_SECRET_KEY`
  - Set `backend.existingSecret: <secret-name>` *(guard in `validate.yaml`: backend.existingSecret required)*
  - Remove `backend.secrets.encryptionKey` and `backend.secrets.jwtSecret` *(guard: inline secrets forbidden)*

- [ ] **Database credentials** — Contains the full connection string for the external DB.
  - Create Secret with key: `DATABASE_URL`
  - Set `postgres.external.existingSecret: <secret-name>` *(guard in `validate.yaml`: external existingSecret required)*

- [ ] **LLM API key** (if `llm.provider` is set) — API key for the LLM provider.
  - Create Secret with key: `LLM_API_KEY`
  - Set `llm.existingSecret: <secret-name>` *(guard in `validate.yaml`: llm.existingSecret required when provider is active)*
  - Remove `llm.secrets.apiKey` *(guard: inline secrets forbidden)*

- [ ] **Gateway secrets** (if gateway needs API keys) — API keys for MCP target services.
  - Create Secret with target-specific keys
  - Set `gateway.existingSecret: <secret-name>` *(guard in `validate.yaml`: inline gateway.secrets forbidden)*

- [ ] **Auth client secret** (if OIDC) — OIDC client secret for backend-to-IdP communication.
  - Create Secret with key: `AUTH_CLIENT_SECRET`
  - Set `auth.existingSecret: <secret-name>`

## 3. Identity

- [ ] **OIDC provider configured** — Production should not rely on local JWT authentication (no MFA, no external audit trail).
  - Set `auth.mode: oidc` (or `dual` during transition)
  - Set `auth.oidc.issuer` to your provider's issuer URL *(guard in `validate.yaml`: OIDC issuer required)*
  - Set `auth.oidc.audience` to the OAuth2 client ID *(guard in `validate.yaml`: OIDC audience required)*
  - See [OIDC Setup](OIDC-SETUP.md) for claim and role mapping

## 4. TLS

- [ ] **Ingress TLS** — Encrypt traffic between clients and the ingress controller.
  - Set `ingress.tls.enabled: true`
  - Choose mode:
    - `existingSecret` — pre-created TLS Secret, set `ingress.tls.secretName` *(guard in `validate.yaml`: secretName required)*
    - `certManager` — automated via cert-manager, set `ingress.tls.clusterIssuer` *(guard in `validate.yaml`: clusterIssuer required)*

## 5. Container Images

- [ ] **Private registry** — Pull images from your controlled registry, not public sources.
  - Set `global.imageRegistry: "registry.example.com/biznez"`
  - Set `global.imagePullSecrets` with registry credentials

- [ ] **Digest pinning** — Prevent tag mutation attacks by requiring image digests.
  - Set `global.requireDigests: true` *(guard in `_helpers.tpl`: fails if any image.digest is empty)*
  - Populate `image.digest` for each component (backend, frontend, postgres, gateway)

## 6. Networking

- [ ] **Network policies enabled** — Restrict pod-to-pod and egress traffic.
  - Set `networkPolicy.enabled: true`
  - Set `networkPolicy.egress.allowAllHttps: false` (restrict egress, don't allow all HTTPS)
  - Configure explicit egress for your environment (`proxy.cidrs`, `externalServices.cidrs`, `mcpTargets.namespaceSelectors`)
  - See [Networking Guide](NETWORKING.md) for egress strategy options

- [ ] **Ingress namespace selector** — When both ingress and networkPolicy are enabled, restrict which namespaces can reach pods.
  - Set `networkPolicy.ingress.namespaceSelector` to match your ingress controller's namespace *(guard in `validate.yaml`: namespaceSelector required)*

- [ ] **SSE streaming timeouts** — Backend uses Server-Sent Events for agent streaming. The ingress controller must allow long-lived connections.
  - Set `ingress.applyNginxStreamingAnnotations: true` (for nginx)
  - For other controllers, set read/proxy timeout >= `backend.streaming.proxyReadTimeout` (default: 300s)

## 7. High Availability

- [ ] **Horizontal Pod Autoscaler** — Scale backend pods based on load.
  - Set `autoscaling.enabled: true`
  - Set `autoscaling.minReplicas: 2` (minimum) *(guard in `validate.yaml`: minReplicas >= 2 when PDB enabled)*
  - Ensure at least one metric is configured: `autoscaling.metrics.cpu.targetAverageUtilization` or `.memory.targetAverageUtilization` *(guard in `validate.yaml`: at least one metric required)*

- [ ] **Pod Disruption Budget** — Ensure availability during node maintenance.
  - Set `pdb.enabled: true`
  - Requires `backend.replicas >= 2` or `autoscaling.minReplicas >= 2` *(guard in `validate.yaml`: PDB requires >= 2 replicas)*

- [ ] **Resource limits tuned** — Adjust CPU/memory for your workload. Production defaults in `values-production.yaml`: backend requests 500m/1Gi, limits 2000m/2Gi.

## 8. Data

- [ ] **Backup strategy** — Define backup frequency and retention for your managed database. The chart does not manage external DB backups.
  - See [Backup & Restore](BACKUP-RESTORE.md) for guidance

- [ ] **Migration mode** — Choose how database migrations run during deployments.
  - `hook` — Helm pre-install/pre-upgrade Job (automatic, production-safe)
  - `manual` — Operator runs `biznez-cli migrate` (full control, recommended for zero-downtime)
  - Set `migration.mode: hook` or `migration.mode: manual`
  - See [Migration Guide](MIGRATION-GUIDE.md) for details

## 9. Supply Chain

- [ ] **Vulnerability scan reviewed** — Review Trivy scan results from `biznez-cli build-release`.
  - Scan reports are generated during the release build process

- [ ] **SBOM archived** — Software Bill of Materials generated by Syft during `build-release`.
  - Archive SBOM artifacts for compliance

- [ ] **Image signatures verified** — Verify image signatures match trusted keys.
  - `biznez-cli verify-images --key cosign.pub --registry registry.example.com/biznez`
  - Or keyless: `biznez-cli verify-images --keyless --registry registry.example.com/biznez`

## 10. Validation

- [ ] **Run full validation** — Catch all guard failures before deploying.

```bash
biznez-cli validate -f values.yaml --profile production
```

This command renders all Helm templates, triggering every validation guard listed above. Fix all errors before running `biznez-cli install`.
