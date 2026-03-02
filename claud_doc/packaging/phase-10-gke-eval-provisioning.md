# Phase 10: Automated GKE Eval Provisioning System

## Context

Biznez needs a zero-touch way to provision runtime evaluation instances on GKE for customer PoCs. Today the process is fully manual (create cluster, build images, deploy via CLI, share credentials). This plan automates the entire flow so it can be triggered from the Biznez website or by the team on behalf of a customer, with no manual intervention.

This phase builds entirely on Phases 1-9: the Helm chart handles all K8s resource creation, `biznez-cli` handles secrets/install/health-check, `images.lock` from Phase 8 provides digest-pinned image references, and the eval values profile from Phase 9 provides the base configuration.

## Sub-Phase Overview

| Sub-Phase | Name | Depends On | Exit Criteria |
|-----------|------|------------|---------------|
| 10.1 | GHA + WIF + Terraform + basic Helm install | Phases 1-9 | GHA workflow creates GKE cluster, deploys runtime, accessible via port-forward |
| 10.2 | Digest-pinned images + sanity tests | 10.1 | All images mirrored by digest from `releaseRepo`, 14 sanity tests pass, optional cosign verify |
| 10.3 | Public access + guardrails | 10.2 | Frontend reachable via GKE Ingress + Cloud Armor, backend not externally exposed |
| 10.4 | TTL cleanup + environment registry | 10.3 | Lifecycle states tracked in GCS, daily cleanup destroys expired envs with safety guardrails |
| 10.5 | Cloud Run trigger + website callback | 10.4 | Website can trigger provision via Cloud Run, receives callback on completion |

Each sub-phase produces a testable, demonstrable result. Earlier phases use simpler approaches that later phases replace (e.g., 10.1 uses `latest` tags + port-forward; 10.2 switches to digests; 10.3 adds Ingress).

---

## Phase 10.1: GHA + WIF + Terraform + Basic Helm Install

**Goal**: Prove the end-to-end skeleton works. A GitHub Actions workflow creates a GKE Autopilot cluster via Terraform, deploys the Biznez runtime via Helm, and the operator accesses it via port-forward.

### One-time GCP prerequisites (manual)

Set up once in the shared project (`mcpserver-469909`):

- Create GCS bucket `biznez-terraform-state` with versioning enabled
- Enable APIs: `container.googleapis.com`, `compute.googleapis.com`, `artifactregistry.googleapis.com`, `iam.googleapis.com`, `iamcredentials.googleapis.com`
- **Set up Workload Identity Federation for GitHub Actions:**
  - Create a Workload Identity Pool: `biznez-github-pool`
  - Create an OIDC provider in the pool: issuer `https://token.actions.githubusercontent.com`, attribute mapping for `repository` and `ref`
  - Create a GCP service account: `biznez-github-provisioner@mcpserver-469909.iam.gserviceaccount.com`
  - Grant the SA roles: `container.admin`, `compute.admin`, `artifactregistry.admin`, `iam.serviceAccountAdmin`, `storage.objectAdmin`, `serviceusage.serviceUsageAdmin`
  - Bind the WIF pool to the SA with attribute condition: `assertion.repository == 'biznez-agentic/biznez-runtime-dist'`
- No SA key JSON -- GitHub Actions authenticates via OIDC token exchange

### New files

```
infra/
  terraform/
    modules/
      gke-cluster/          main.tf, variables.tf, outputs.tf
      networking/            main.tf, variables.tf, outputs.tf
      artifact-registry/    main.tf, variables.tf, outputs.tf
      iam/                  main.tf, variables.tf, outputs.tf
      workload-identity/    main.tf, variables.tf, outputs.tf
    environments/
      eval/                 main.tf, variables.tf, outputs.tf, backend.tf, versions.tf
    .terraform-version
  scripts/
    provision.sh            Orchestrator: secrets → helm install → health-check
    teardown.sh             Orchestrator: helm uninstall → namespace delete
    preflight-quotas.sh     Check GKE/LB/CPU quotas, APIs, billing
  values/
    eval-gke.yaml           Helm values (all services ClusterIP, eval profile)
.github/workflows/
  provision-eval.yml        4-job workflow: validate → terraform → deploy → notify
  teardown-eval.yml         3-job workflow: validate → uninstall → terraform destroy
```

### Terraform modules

4 modules + 1 one-time module:

**networking/** -- VPC, subnet with pod/service secondary ranges, internal firewall, health-check firewall (GCP LB source ranges `35.191.0.0/16`, `130.211.0.0/22`), Cloud Router + NAT for outbound

**gke-cluster/** -- GKE Autopilot cluster (regional, REGULAR release channel, workload identity, `deletion_protection = false`). Resource labels: `managed-by=biznez-provisioner`, `customer=<name>`, `environment=eval`

**artifact-registry/** -- Per-customer Docker repo

**iam/** -- GKE workload SA with AR reader role + workload identity binding for the `biznez` K8s namespace

**workload-identity/** -- (one-time, in shared project) WIF pool + OIDC provider + SA binding. Applied once, not per-customer.

**environments/eval/** -- Root module composing all per-customer modules. Variables: `customer_name`, `gcp_project_id`, `region`. Environment ID: `<customer_name>-<random_4char>`. GCS backend prefix: `eval/<env_id>`. State locking enabled.

### provision.sh (10.1 version -- simple)

1. Preflight checks (kubectl, helm, cluster connectivity)
2. Create namespace (`biznez`) -- idempotent
3. Generate admin password, store in K8s Secret `biznez-eval-admin-creds` (never echoed, never output)
4. Generate app secrets via `biznez-cli generate-secrets` -- piped to `kubectl apply`
5. Helm install via `helm upgrade --install` with `infra/values/eval-gke.yaml`
6. `kubectl rollout status` for each deployment with timeout
7. Health check via `biznez-cli health-check`
8. Output retrieval command to `$GITHUB_OUTPUT` (never the credential)

### preflight-quotas.sh

Checks before Terraform:
- GKE Autopilot cluster quota in target region
- Autopilot regional capacity
- External IP / LoadBalancer quota
- Regional CPU quota
- AR repository limits
- Required APIs enabled
- Billing enabled
- Org policy constraints
- Actionable error messages for each failure

### eval-gke.yaml (10.1 version -- port-forward only)

```yaml
global:
  profile: eval

backend:
  config:
    environment: development
    logLevel: info
  service:
    type: ClusterIP

frontend:
  service:
    type: ClusterIP
    port: 80

postgres:
  enabled: true

migration:
  mode: auto

auth:
  mode: local
```

### provision-eval.yml (10.1 version)

Inputs: `customer_name`, `region` (choice: europe-west2/us-central1/us-east1/asia-southeast1), `gcp_project_id` (optional, defaults to shared).

Concurrency: `concurrency: { group: eval-${{ inputs.customer_name }}, cancel-in-progress: false }`

Jobs:
1. `validate-inputs` -- regex validate customer name, generate env_id
2. `preflight-and-provision` -- preflight-quotas.sh → terraform init/plan/apply using keyless WIF auth → output cluster name + AR URL
3. `deploy-runtime` -- get GKE credentials → push images to customer AR by tag (simple `crane copy`, no digest pinning yet) → run provision.sh
4. `notify` -- write results to GitHub step summary: cluster name, namespace, port-forward command, kubectl creds retrieval command

Authentication:
```yaml
- uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: projects/<NUM>/locations/global/workloadIdentityPools/biznez-github-pool/providers/github-oidc
    service_account: biznez-github-provisioner@mcpserver-469909.iam.gserviceaccount.com
```

### teardown-eval.yml (10.1 version)

Inputs: `customer_name`, `region`, `confirm_destroy` (must match customer_name). All steps `continue-on-error`. Jobs: validate → helm uninstall → terraform destroy.

### GitHub secrets (10.1)

| Secret | Purpose |
|--------|---------|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | WIF provider resource name |
| `GCP_SERVICE_ACCOUNT` | Provisioner SA email |

### Exit criteria (10.1)

1. `provision-eval.yml` creates a GKE Autopilot cluster + VPC + AR in ~10 min
2. Runtime is deployed and healthy (`biznez-cli health-check` passes)
3. Frontend accessible via `kubectl port-forward svc/biznez-frontend 8080:80 -n biznez`
4. Backend health responds at `localhost:8000/api/v1/health` via port-forward
5. `teardown-eval.yml` destroys all resources cleanly
6. Re-running provision for the same customer is idempotent (terraform handles it)
7. WIF auth works (no SA key JSON anywhere)

---

## Phase 10.2: Digest-Pinned Images + Sanity Tests

**Goal**: Replace tag-based image copies with digest-pinned mirroring from `images.lock`. Add comprehensive sanity tests covering health, security, RBAC, and supply-chain integrity.

### Changes from 10.1

- Images copied by `@sha256` digest from `releaseRepo` in `images.lock` (not by tag)
- All 4 images mirrored (platform-api, web-app, postgres, agentgateway) -- zero Docker Hub dependency
- `crane copy --all` to include cosign signatures/attestations as OCI artifacts
- `global.requireDigests: true` and `imagePullPolicy: IfNotPresent` in Helm values
- Full sanity test suite added

### New/modified files

```
infra/
  scripts/
    mirror-images.sh        NEW: read images.lock, crane copy --all by digest
    sanity-test.sh          NEW: 14 tests + optional signature verification
  values/
    eval-gke.yaml           MODIFIED: add requireDigests, IfNotPresent
.github/workflows/
  provision-eval.yml        MODIFIED: add mirror-images + sanity-tests jobs
```

### mirror-images.sh

Reads `helm/biznez-runtime/images.lock` and copies all 4 images using `crane copy --all`:
- `releaseRepo/platform-api@sha256:...` (Biznez backend)
- `releaseRepo/web-app@sha256:...` (Biznez frontend)
- `releaseRepo/postgres@sha256:...` (third-party, pinned)
- `releaseRepo/agentgateway@sha256:...` (third-party, pinned)

Key design points:
- Sources from `releaseRepo` (not `sourceRepo`) -- the Biznez-controlled registry where Phase 8 already mirrored, scanned, signed, and generated SBOMs
- `--all` flag copies OCI index + associated artifacts (cosign signatures stored as OCI artifacts)
- Third-party redistribution: postgres is PostgreSQL License (permissive), agentgateway is Apache 2.0 (permissive)
- Integration test to prove signature round-trip: sign in release registry → `crane copy --all` → `cosign verify` in customer AR

### sanity-test.sh

14 tests:

Internal tests (via port-forward):
1. `GET /api/v1/health` returns 200
2. `GET /api/v1/health/ready` returns 200
3. `GET /api/v1/health/live` returns 200
4. `GET /` (frontend) returns 200
5. `GET /health` (frontend) returns 200
6. Health response contains `"status"` field (DB connectivity)
7. Auth endpoint responds (401/405/422)
8. No pods in CrashLoopBackOff/ImagePullBackOff

Security tests:
9. Backend not externally reachable: all backend services must be `ClusterIP`
10. Creds secret (`biznez-eval-admin-creds`) not mounted into any pod's `env`, `envFrom`, or `volumeMounts`
11. No broad RoleBinding granting `secrets` read to `system:authenticated` or `system:serviceaccounts`
12. Namespace labeled with `env-id`, `managed-by`

Supply-chain tests:
13. All deployed pod images contain `@sha256:` AND digest matches `images.lock` for the deployed version (cross-reference every image)
14. (External test placeholder -- added in 10.3) Skipped in 10.2 since no public endpoint yet

Optional signature verification (`SANITY_VERIFY_SIGNATURES=true`):
- `cosign verify` against each image in customer AR by digest
- Keyless (Fulcio/Rekor) or key-pair depending on Phase 8 model
- Warnings only in v1; blocking in v2 once proven reliable

### eval-gke.yaml (10.2 version)

```yaml
global:
  profile: eval
  requireDigests: true
  imagePullPolicy: IfNotPresent
  # imageRegistry and digests set via --set at install time from images.lock

backend:
  config:
    environment: development
    logLevel: info
  service:
    type: ClusterIP

frontend:
  service:
    type: ClusterIP
    port: 80

postgres:
  enabled: true

migration:
  mode: auto

auth:
  mode: local
```

### provision-eval.yml (10.2 version)

Adds two new jobs between deploy and notify:
- `mirror-images` -- runs `mirror-images.sh` after terraform, before deploy
- `sanity-tests` -- runs `sanity-test.sh` after deploy

Adds inputs: `runtime_version`, `verify_signatures` (boolean, default false).

provision.sh updated to pass digest overrides from `images.lock` via `--set` to Helm.

### Exit criteria (10.2)

1. All 4 images copied by digest to customer AR (verified by `crane manifest`)
2. `global.requireDigests: true` -- Helm install fails if any digest is missing
3. `imagePullPolicy: IfNotPresent` -- no Docker Hub pulls at runtime
4. All 14 sanity tests pass
5. Pod image references show `@sha256:...` matching `images.lock`
6. `SANITY_VERIFY_SIGNATURES=true` cosign verify passes (if signatures exist in release registry)
7. Integration test proves `crane copy --all` transfers cosign signatures

---

## Phase 10.3: Public Access + Guardrails

**Goal**: Make the frontend publicly accessible via GKE Ingress with Cloud Armor security policy. Backend remains internal. HTTP only for eval (TLS deferred to v2 with managed certs under Biznez-controlled domain).

### Why Ingress, not Service LoadBalancer

A plain `Service type: LoadBalancer` on GKE Autopilot creates an L4 Network Load Balancer. Cloud Armor security policies only apply to L7 HTTP(S) Load Balancers. GKE Ingress creates an L7 HTTP(S) LB where Cloud Armor works correctly.

### TLS strategy

- **v1 (this phase): HTTP only** -- eval environments use raw IPs (no DNS), so HTTPS with proper certs is not practical. Cloud Armor IP allowlist + rate limiting + 48h TTL provide the security boundary. Documented as an eval-only trade-off.
- **v2 (future): HTTPS with managed certs** -- allocate `<env_id>.eval.biznez.ai` DNS records, use GCP Managed Certificates for automatic TLS.

### New/modified files

```
infra/
  terraform/
    modules/
      cloud-armor/          NEW: main.tf, variables.tf, outputs.tf
    environments/
      eval/                 MODIFIED: add cloud-armor module
  values/
    eval-gke.yaml           MODIFIED: add ingress config, BackendConfig annotation
.github/workflows/
  provision-eval.yml        MODIFIED: add customer_ip_allowlist input
```

### cloud-armor/ Terraform module

Google Cloud Armor security policy for the GKE Ingress HTTP(S) LB:
- IP allowlist: customer IP ranges (variable, defaults to `0.0.0.0/0` if not provided)
- Rate limiting: 100 requests/min per IP
- Applied via `BackendConfig` CRD on the frontend backend service

### eval-gke.yaml (10.3 version)

```yaml
global:
  profile: eval
  requireDigests: true
  imagePullPolicy: IfNotPresent

backend:
  config:
    environment: development
    logLevel: info
  service:
    type: ClusterIP    # NOT exposed publicly; frontend proxies /api

frontend:
  service:
    type: ClusterIP    # Ingress handles external exposure
    port: 80
    annotations:
      cloud.google.com/backend-config: '{"default": "biznez-eval-armor"}'

ingress:
  enabled: true
  className: gce       # GKE HTTP(S) LB
  hosts:
    - paths:
        - path: /
          service: frontend

postgres:
  enabled: true

migration:
  mode: auto

auth:
  mode: local
```

### provision.sh (10.3 changes)

- Wait for Ingress external IP/hostname (poll with 180s timeout, handle both `.status.loadBalancer.ingress[0].ip` and `.hostname`)
- Output access URL: `http://<INGRESS_IP>`
- Credential retrieval: kubectl command (Model 1: internal eval)

### sanity-test.sh (10.3 additions)

Test 14 (replaces the placeholder from 10.2):
- **External reachability**: `curl` the Ingress external IP from the GHA runner to prove LB/firewall is working end-to-end

### provision-eval.yml (10.3 changes)

New input: `customer_ip_allowlist` (optional, comma-separated CIDRs). Passed to Terraform as variable for Cloud Armor.

### Exit criteria (10.3)

1. Frontend accessible via Ingress IP from the public internet (or from allowlisted IPs)
2. Backend NOT accessible externally -- no public LB/NodePort/Ingress for backend
3. Cloud Armor policy attached to Ingress backend
4. Rate limiting works (>100 req/min from same IP gets 429)
5. IP allowlist works (request from non-allowlisted IP blocked when configured)
6. External reachability sanity test passes
7. All previous sanity tests still pass

---

## Phase 10.4: TTL Cleanup + Environment Registry

**Goal**: Track all provisioned environments with lifecycle states in a GCS registry. Add scheduled cleanup that safely destroys expired environments. Add a separate least-privilege SA for cleanup.

### Environment registry

Each environment has a JSON record in `gs://biznez-eval-registry/<env_id>.json`.

Lifecycle states:
```
provisioning → ready    (on successful sanity tests)
provisioning → failed   (on any failure after TF apply)
ready        → tearing_down → destroyed
failed       → tearing_down → destroyed
```

Record schema:
```json
{
  "env_id": "acme-x7k2",
  "state": "ready",
  "customer_name": "acme",
  "region": "europe-west2",
  "project_id": "mcpserver-469909",
  "cluster_name": "biznez-eval-acme-x7k2-cluster",
  "ar_url": "europe-west2-docker.pkg.dev/mcpserver-469909/biznez-eval-acme-x7k2-runtime",
  "ttl_expiry": "2026-03-04T14:30:00Z",
  "runtime_version": "1.2.0",
  "tf_state_prefix": "eval/acme-x7k2",
  "created_at": "2026-03-02T14:30:00Z",
  "contact_email": "admin@acme.com",
  "managed_by": "biznez-provisioner",
  "deletion_allowed": true
}
```

Lifecycle rules:
- `state: provisioning` written immediately after TF plan succeeds, before TF apply
- `state: ready` + `deletion_allowed: true` written only after sanity tests pass
- `state: failed` written on any failure after TF apply (with error details)
- Cleanup only targets records where `state` is `ready` or `failed`, AND `deletion_allowed: true`, AND `ttl_expiry` has passed
- Records in `provisioning` state ignored by cleanup unless stale beyond 2 hours (stuck provision grace)
- `managed_by` and `project_id` must match expected values (hard guardrail)

### One-time prerequisites (additions)

- Create GCS bucket `biznez-eval-registry` for environment metadata
- Create cleanup SA: `biznez-github-cleanup@mcpserver-469909.iam.gserviceaccount.com` with roles: `container.admin`, `compute.admin`, `artifactregistry.admin`, `storage.objectAdmin`. Least privilege -- separate from provisioner SA.
- Bind cleanup SA to WIF pool with same repository condition

### New/modified files

```
infra/
  terraform/
    environments/
      eval/                 MODIFIED: add ttl_hours variable, ttl-expiry label
.github/workflows/
  provision-eval.yml        MODIFIED: add ttl_hours input, write env registry records, update states
  teardown-eval.yml         MODIFIED: update env registry on teardown
  cleanup-eval.yml          NEW: scheduled daily cleanup
```

### provision-eval.yml (10.4 changes)

New inputs: `ttl_hours` (default 48), `contact_email`.

State management:
- After TF plan: write env record with `state: provisioning`
- After sanity-tests pass: update to `state: ready`, `deletion_allowed: true`
- On failure: update to `state: failed`

GKE cluster labels now include `ttl-expiry=<unix_timestamp>`.

### teardown-eval.yml (10.4 changes)

Updates env record: `state: tearing_down` → (after destroy) → `state: destroyed` or delete record.

### cleanup-eval.yml (NEW)

Scheduled `cron: '0 6 * * *'` (daily at 06:00 UTC). Uses the **cleanup SA** (least privilege).

**Runs destroy directly** (does not dispatch teardown workflow -- avoids GHA throttling/dispatch failures):

1. List all env records from GCS registry
2. For each record, apply safety guardrails:
   - Skip if `managed_by != biznez-provisioner`
   - Skip if `project_id` not in hardcoded allowlist
   - Skip if `deletion_allowed != true`
   - Skip if `state == provisioning` AND `created_at` < 2 hours ago
   - Skip if `state == tearing_down` (already being destroyed)
3. For eligible records past `ttl_expiry`: update state to `tearing_down` → `terraform destroy -auto-approve` → update to `destroyed`
4. Concurrency: `eval-<env_id>` per environment to prevent overlap with provision
5. Fallback: scan for GKE clusters with label `managed-by=biznez-provisioner` where `ttl-expiry` has passed but no registry record exists (orphan detection)
6. Post summary to GitHub step summary

### GitHub secrets (additions for 10.4)

| Secret | Purpose |
|--------|---------|
| `GCP_CLEANUP_SERVICE_ACCOUNT` | Cleanup SA email for WIF (least privilege) |

### Exit criteria (10.4)

1. Env record created with `state: provisioning` during provision
2. Env record updated to `state: ready` after successful sanity tests
3. `cleanup-eval.yml` correctly identifies expired environments
4. Cleanup respects all guardrails (managed_by, project_id, deletion_allowed, state)
5. Cleanup ignores `provisioning` records less than 2h old
6. Cleanup destroys expired `ready`/`failed` environments via direct TF destroy
7. Cleanup uses cleanup SA (not provisioner SA)
8. Cleanup detects orphan clusters not in registry
9. Teardown updates state transitions correctly
10. Concurrency groups prevent overlap between cleanup and provision

---

## Phase 10.5: Cloud Run Trigger + Website Callback

**Goal**: Enable the Biznez website to trigger provisioning via a minimal Cloud Run service. Add webhook callback so the website receives results. Define credential delivery models.

### Credential delivery models

**Model 1: Internal / Sales Engineering Eval** (implemented in this phase)
- Admin password stored in K8s Secret `biznez-eval-admin-creds`
- Retrieval: `kubectl get secret biznez-eval-admin-creds -n biznez -o jsonpath='{.data.password}' | base64 -d`
- GHA summary shows access URL + retrieval command (not the credential)
- Team member retrieves creds, shares via secure channel

**Model 2: External Self-Serve Eval** (flagged as fast-follow, not in this phase)
- Admin password stored in GCP Secret Manager (scoped to env_id)
- Website receives short-lived retrieval token via callback
- Token expires after first use or 1 hour
- Requires Secret Manager integration + website changes

**Model 3: Zero-password** (future)
- One-time magic login link or per-customer OIDC flow

### Cloud Run trigger service

Minimal scope, strict security. Responsibilities (and nothing more):

1. **Validate request**: HMAC-signed payload from website backend (shared secret)
2. **Idempotency**: accept `request_id` / `idempotency_key`; check against short-lived cache (Firestore or in-memory with TTL) to prevent double dispatch on retries
3. **Ref allowlist**: only dispatch against `ref: main` (reject any other branch)
4. **Create token**: generate short-lived GitHub App installation token
5. **Dispatch workflow**: call GitHub workflow dispatch API
6. **Return tracking ID**: return `env_id` to the caller

Everything else (provisioning, testing, notification) stays in GitHub Actions. Cloud Run does zero orchestration.

### Website flow

```
Customer clicks "Start PoC" → Website backend → Cloud Run trigger → GitHub Actions → provision
                                                                                    ↓
Customer gets email ← Website backend ← Cloud Run callback ← GHA notify job (webhook)
```

### Webhook callback payload

```json
{
  "env_id": "acme-x7k2",
  "customer_name": "acme",
  "status": "success",
  "access_url": "http://34.55.66.77",
  "retrieval_command": "kubectl get secret biznez-eval-admin-creds -n biznez ...",
  "cluster_name": "biznez-eval-acme-x7k2-cluster",
  "region": "europe-west2",
  "ttl_expiry": "2026-03-04T14:30:00Z"
}
```

Never contains the credential itself. For Model 2 (future): would include `retrieval_token` instead of `retrieval_command`.

### New/modified files

```
infra/
  trigger/
    main.py (or main.go)    NEW: Cloud Run trigger service (<100 lines)
    Dockerfile              NEW: Cloud Run container
    cloudbuild.yaml         NEW: Build + deploy trigger service
.github/workflows/
  provision-eval.yml        MODIFIED: add delivery_model input, callback_url input, notify job sends webhook
```

### provision-eval.yml (10.5 changes)

New inputs: `delivery_model` (choice: `internal`/`self-serve`, default `internal`), `callback_url` (optional).

Notify job: if `callback_url` is set, POST results as HMAC-signed webhook.

### GitHub secrets (additions for 10.5)

| Secret | Purpose |
|--------|---------|
| `WEBSITE_CALLBACK_TOKEN` | Shared secret for webhook callback HMAC |
| `GITHUB_APP_ID` | GitHub App ID (for Cloud Run trigger) |
| `GITHUB_APP_PRIVATE_KEY` | GitHub App private key (for Cloud Run trigger) |

### Exit criteria (10.5)

1. Cloud Run trigger accepts HMAC-signed request and dispatches GHA workflow
2. Duplicate requests with same idempotency key are rejected
3. Requests for non-main refs are rejected
4. Provision completes end-to-end when triggered via Cloud Run
5. Webhook callback fires on success with correct payload (no creds)
6. Webhook callback fires on failure with error status
7. Website can display access URL + instructions to customer

---

## All GitHub Secrets (Complete)

| Secret | Added In | Purpose |
|--------|----------|---------|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | 10.1 | WIF provider resource name |
| `GCP_SERVICE_ACCOUNT` | 10.1 | Provisioner SA email |
| `GCP_CLEANUP_SERVICE_ACCOUNT` | 10.4 | Cleanup SA email (least privilege) |
| `WEBSITE_CALLBACK_TOKEN` | 10.5 | HMAC secret for webhook callbacks |
| `GITHUB_APP_ID` | 10.5 | GitHub App ID (Cloud Run trigger) |
| `GITHUB_APP_PRIVATE_KEY` | 10.5 | GitHub App private key (Cloud Run trigger) |

No `GCP_SA_KEY` anywhere -- keyless auth via OIDC/WIF.

## Supply Chain Parity with Phase 8

Added in 10.2 and maintained through 10.3-10.5:

| Aspect | Phase 8 (Production) | Phase 10 (Eval) |
|--------|---------------------|-----------------|
| Image source | Release registry | Same -- `releaseRepo` from `images.lock` |
| Image pinning | By digest in images.lock | Same digests from same images.lock |
| Image signing | cosign in release registry | Signatures copied via `crane copy --all` |
| Signature verification | `biznez-cli verify-images` | Optional: `cosign verify` (`SANITY_VERIFY_SIGNATURES=true`). Manual: `cosign verify <AR>/<image>@sha256:...` |
| Third-party images | Mirrored, scanned, SBOM'd | Same -- mirrored from releaseRepo by digest |
| Docker Hub dependency | None at runtime | None at runtime |
| Pull policy | IfNotPresent | IfNotPresent |
| Licensing | N/A (internal) | postgres: PostgreSQL License, agentgateway: Apache 2.0. Redistribution confirmed. |

**Note**: Eval does not claim identical enterprise supply-chain posture to production. Differences: signature verification is optional (not enforced), HTTP not HTTPS, eval-only auth. These are documented trade-offs for speed of provisioning.

## Timeline Estimate (execution, not calendar)

Per-provision execution time (after all sub-phases complete):
- Preflight quota checks: ~30s
- Terraform apply (GKE Autopilot): ~8-12 min
- Image mirror (all 4 by digest, with signatures): ~2-3 min
- Helm install + health check: ~3-5 min
- Sanity tests (14 tests + optional sig verify): ~2-3 min
- **Total: ~15-20 min**

## Revision History

| Version | Changes |
|---------|---------|
| v1 | Initial draft: SA key, tag-based images, public backend LB, no cleanup |
| v2 | Keyless WIF auth, K8s-only creds, digest pinning (Biznez only), 48h TTL, ClusterIP backend, concurrency, quotas |
| v3 | Mirror all images by digest, Cloud Armor, env registry with lifecycle states, RBAC tests, Cloud Run security hardening |
| v4 | GKE Ingress (not Service LB), explicit TLS strategy, credential delivery models, cosign verification, cleanup safety guardrails, `crane copy --all` for signatures |
| v5 | Broken into 5 sub-phases (10.1-10.5) with incremental delivery and exit criteria per phase |
