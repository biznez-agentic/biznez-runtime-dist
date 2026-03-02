# Phase 10.1: GHA + WIF + Terraform + Basic Helm Install

## Context

Biznez needs automated GKE eval provisioning for customer PoCs. Phase 10.1 proves the end-to-end skeleton: a GitHub Actions workflow authenticates to GCP via Workload Identity Federation (keyless), creates a GKE Autopilot cluster + VPC + Artifact Registry via Terraform, copies images from `releaseRepo` into a per-env AR, deploys the Biznez runtime via Helm, and outputs port-forward instructions.

This is the foundation that later sub-phases (10.2-10.5) build on. It intentionally keeps things simple: tag-based images from `releaseRepo` (not digest-pinned yet), ClusterIP services (port-forward only), no public ingress, no TTL cleanup, no website trigger.

Builds on Phases 1-9: Helm chart, `biznez-cli` (generate-secrets, install, health-check), eval values profile.

## One-Time GCP Prerequisites (Manual, Not Automated)

Before any workflow runs, set up once in project `mcpserver-469909`:

1. Create GCS bucket `biznez-terraform-state` with versioning enabled
2. Enable APIs: `container`, `compute`, `artifactregistry`, `iam`, `iamcredentials`
3. Create Workload Identity Pool `biznez-github-pool` with OIDC provider (issuer: `https://token.actions.githubusercontent.com`)
4. Create SA `biznez-github-provisioner@mcpserver-469909.iam.gserviceaccount.com` with roles: `container.admin`, `compute.admin`, `artifactregistry.admin`, `iam.serviceAccountAdmin`, `storage.objectAdmin`, `serviceusage.serviceUsageAdmin`
5. Bind WIF pool → SA with condition: `assertion.repository == 'biznez-agentic/biznez-runtime-dist'`

Store as GitHub secrets: `GCP_WORKLOAD_IDENTITY_PROVIDER` (WIF provider resource name), `GCP_SERVICE_ACCOUNT` (SA email).

## New Files

```
infra/
├── terraform/
│   ├── .terraform-version                    # Pin Terraform version (1.9.x)
│   ├── modules/
│   │   ├── networking/
│   │   │   ├── main.tf                       # VPC, subnet, NAT (no LB firewall rules)
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── gke-cluster/
│   │   │   ├── main.tf                       # GKE Autopilot cluster (public endpoint)
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── artifact-registry/
│   │   │   ├── main.tf                       # Docker repo per customer
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   └── iam/
│   │       ├── main.tf                       # AR reader for both node SAs
│   │       ├── variables.tf
│   │       └── outputs.tf
│   └── environments/
│       └── eval/
│           ├── main.tf                       # Root module composing all 4
│           ├── variables.tf                  # customer_name, region, project_id
│           ├── outputs.tf                    # cluster_name, ar_url, cluster_endpoint, env_id
│           ├── backend.tf                    # GCS backend with per-env prefix
│           └── versions.tf                   # Required providers + versions
├── scripts/
│   ├── provision.sh                          # Orchestrator: secrets → helm → health-check
│   ├── teardown.sh                           # Helm uninstall → namespace delete
│   └── preflight-quotas.sh                   # Quota/API/billing checks
└── values/
    └── eval-gke.yaml                         # Helm values for GKE eval
.github/workflows/
├── provision-eval.yml                        # 4-job workflow
└── teardown-eval.yml                         # 3-job workflow
```

Total: ~20 new files.

## Terraform Modules

### `modules/networking/` — VPC + Subnet + NAT

```hcl
# Resources:
google_compute_network          "eval-vpc"          # VPC (auto_create_subnetworks = false)
google_compute_subnetwork       "eval-subnet"       # /20 primary, /16 pods secondary, /20 services secondary
google_compute_router           "nat-router"        # For outbound internet
google_compute_router_nat       "nat-config"        # AUTO_ONLY, all subnets

# NO LB health-check firewall rule -- 10.1 has no Ingress or LoadBalancer services.
# LB health-check firewall (35.191.0.0/16, 130.211.0.0/22) added in 10.3 with Ingress.

# All resources named with env_id prefix and labeled:
#   managed-by = "biznez-provisioner"
#   env-id     = var.env_id
#   customer   = var.customer_name
#   environment = "eval"

# Variables: env_id, customer_name, region, project_id
# Outputs: network_id, network_name, subnet_id, subnet_name, pod_range_name, service_range_name
```

**Design note (feedback R2#5):** No `allow-health-check` firewall rule in 10.1. There are no Ingress resources or LoadBalancer services, so GCP LB health-check CIDRs are unnecessary. Added in 10.3 when Ingress is introduced.

### `modules/gke-cluster/` — GKE Autopilot (Public Endpoint)

```hcl
# Resources:
google_container_cluster        "eval-cluster"
  # name             = "biznez-eval-${var.env_id}"  (deterministic from env_id)
  # enable_autopilot = true
  # release_channel  = REGULAR
  # deletion_protection = false  (easy teardown)
  # network / subnetwork from networking module
  # ip_allocation_policy with pod/service range names
  # PUBLIC cluster endpoint (no private_cluster_config)
  #   -- GHA runners need direct API access; private nodes would require
  #      bastion/VPN or tracking brittle GHA egress ranges. Not 10.1 scope.
  #   -- Control plane is protected by GCP IAM auth (only WIF SA has access).
  # workload_identity_config enabled
  # resource_labels:
  #   managed-by  = "biznez-provisioner"
  #   env-id      = var.env_id
  #   customer    = var.customer_name
  #   environment = "eval"

# Naming convention (all deterministic from env_id):
#   cluster:  biznez-eval-<env_id>
#   VPC:      biznez-eval-<env_id>-vpc
#   subnet:   biznez-eval-<env_id>-subnet
#   AR repo:  biznez-eval-<env_id>-runtime
#   NAT:      biznez-eval-<env_id>-nat
# Teardown can derive any resource name from env_id alone.

# Variables: env_id, customer_name, region, project_id, network_id, subnet_id, pod_range_name, service_range_name
# Outputs: cluster_name, cluster_endpoint, cluster_ca_certificate
```

### `modules/artifact-registry/` — Docker Repo

```hcl
# Resources:
google_artifact_registry_repository  "eval-runtime"
  # format = DOCKER
  # location = var.region
  # description = "Biznez eval images for ${var.env_id}"
  # cleanup_policies with keep_count = 5
  # labels: managed-by, env-id, customer, environment

# Variables: env_id, customer_name, region, project_id
# Outputs: ar_url (full registry path: <region>-docker.pkg.dev/<project>/<repo-name>), repository_id
```

### `modules/iam/` — Image Pull Permissions

```hcl
# Resources:
# Grant artifactregistry.reader to BOTH principals that may pull images
# on GKE Autopilot. Which identity the kubelet uses depends on cluster config:
#
# 1. Compute Engine default SA (most common):
google_project_iam_member  "compute-sa-ar-reader"
  # member = "serviceAccount:<project-number>-compute@developer.gserviceaccount.com"
  # role   = "roles/artifactregistry.reader"
#
# 2. GKE service agent (fallback, used in some configurations):
google_project_iam_member  "gke-agent-ar-reader"
  # member = "serviceAccount:service-<project-number>@container-engine-robot.iam.gserviceaccount.com"
  # role   = "roles/artifactregistry.reader"
#
# Both bindings are at project level (acceptable for single-project eval).
# No imagePullSecrets needed.

# Variables: env_id, project_id, project_number
# Outputs: (none needed for 10.1)
```

**Design note (feedback R2#1):** Both the Compute Engine default SA and the GKE service agent get `artifactregistry.reader`. In Autopilot, the kubelet pulls images using node-level credentials (not Workload Identity). Which principal is used varies by cluster config. Binding both is safe for single-project eval and avoids `ImagePullBackOff` on first run.

### `environments/eval/` — Root Module

```hcl
# Composes all 4 modules
# Variables:
#   customer_name  (required, alphanumeric + hyphens, 3-20 chars)
#   region         (required, default: europe-west2)
#   project_id     (required, default: mcpserver-469909)

# Locals:
#   env_id = "${var.customer_name}-${random_string.suffix.result}"  (4 char random)

# Data source:
#   google_project  (to get project_number for IAM bindings)

# backend.tf:
#   bucket = "biznez-terraform-state"
#   prefix = "eval/${local.env_id}"
#   -- prefix is ONLY under eval/ and scoped to this env_id
#   -- never touches shared state or other env prefixes

# All resources across all modules are:
#   - Named with env_id prefix (e.g., biznez-eval-<env_id>-vpc)
#   - Labeled with managed-by=biznez-provisioner, env-id=<env_id>
#   -- These labels are the foundation for safe cleanup in 10.4

# Outputs: env_id, cluster_name, ar_url, region, project_id
```

## Image Mirroring Strategy

### Why mirror in 10.1 (not defer to 10.2)

Mirroring images into a per-env AR in 10.1 rehearses the full flow that 10.2 will tighten with digests. It validates:
- AR creation and permissions work end-to-end
- `crane copy` works in the GHA runner
- The Helm chart resolves images from `global.imageRegistry` correctly

### releaseRepo is required (no silent fallback)

If `images.lock` `releaseRepo` fields are empty or missing, the workflow **fails immediately** with:
```
ERROR: images.lock releaseRepo not configured for '<image-name>'; cannot provision eval env.
       Run 'biznez-cli build-release' to populate releaseRepo before provisioning.
```

No silent fallback to `sourceRepo`. The `releaseRepo` is the supply-chain source of truth (scanned, signed, SBOM'd by Phase 8). Falling back silently risks pulling unsigned/unscanned images and makes debugging harder.

For dev/testing only: an explicit workflow input `allow_source_repo_fallback` (boolean, default `false`) can be set to `true` to permit sourcing from `sourceRepo`. This is never enabled in production-like flows.

### AR repository layout (flat, no nested paths)

The chart constructs image refs as `{global.imageRegistry}/{component.image.repository}:{tag}` (see `_helpers.tpl:84-103`).

Default `image.repository` values from `values.yaml` include paths with registry hostnames (`ghcr.io/agentgateway/agentgateway`) that would be **illegal as AR path segments**. AR repository names must be docker-compatible paths without registry hostnames.

**Solution: flat AR layout with `--set` overrides.**

```
crane copy <releaseRepo>/platform-api:<tag>    $AR_URL/platform-api:<tag>
crane copy <releaseRepo>/web-app:<tag>         $AR_URL/web-app:<tag>
crane copy <releaseRepo>/postgres:<tag>        $AR_URL/postgres:<tag>
crane copy <releaseRepo>/agentgateway:<tag>    $AR_URL/agentgateway:<tag>
```

Helm install overrides:
```
--set global.imageRegistry="$AR_URL" \
--set backend.image.repository=platform-api \
--set frontend.image.repository=web-app \
--set postgres.image.repository=postgres \
--set gateway.image.repository=agentgateway
```

This produces: `$AR_URL/platform-api:<tag>`, `$AR_URL/web-app:<tag>`, etc. -- clean, flat, AR-safe paths.

### Tags must be set explicitly from images.lock

The chart defaults tags to `appVersion` from `Chart.yaml` (currently `0.0.0-dev`). If this doesn't match the tag in `images.lock`, the pod will pull a tag that doesn't exist in the customer AR.

The deploy-runtime job parses `images.lock` for each component's tag and passes them via `--set`:

```
--set backend.image.tag=<tag from images.lock for platform-api> \
--set frontend.image.tag=<tag from images.lock for web-app> \
--set postgres.image.tag=<tag from images.lock for postgres> \
--set gateway.image.tag=<tag from images.lock for agentgateway>
```

This ensures the mirrored tag and the deployed tag are always the same value, parsed from the same source (`images.lock`).

**Design notes (feedback R3#1, R3#2, R3#4):** Flat layout only (nested layout removed to prevent accidental drift into illegal AR paths). Tags explicitly set from `images.lock` to prevent mismatch. `releaseRepo` required with hard fail.

## Scripts

### `infra/scripts/provision.sh`

Follows existing patterns from `cli/biznez-cli` and `release/build-release.sh`: `set -euo pipefail`, `info/ok/warn/error` helpers, `trap _cleanup EXIT`, structured exit codes.

```
Steps:
1. Parse args: --namespace, --release, --values-file, --chart-dir, --ar-url, --images-lock
2. Preflight: require kubectl, helm, biznez-cli; verify cluster connectivity
3. Create namespace (kubectl create ns ... --dry-run=client -o yaml | kubectl apply -f -)
4. Generate admin password (openssl rand -base64 24), store in K8s Secret:
   kubectl create secret generic biznez-eval-admin-creds \
     --from-literal=password="$ADMIN_PASS" \
     --dry-run=client -o yaml | kubectl apply -f - -n "$NAMESPACE"
   (Never echo, never write to $GITHUB_OUTPUT)
5. Generate app secrets: biznez-cli generate-secrets --format yaml --no-docker-fernet | kubectl apply -f - -n "$NAMESPACE"
6. Parse images.lock for per-component tags (yq or grep/awk):
     BACKEND_TAG, FRONTEND_TAG, POSTGRES_TAG, GATEWAY_TAG
7. Helm install: helm upgrade --install "$RELEASE" "$CHART_DIR" \
     -f "$VALUES_FILE" \
     --set global.imageRegistry="$AR_URL" \
     --set backend.image.repository=platform-api \
     --set backend.image.tag="$BACKEND_TAG" \
     --set frontend.image.repository=web-app \
     --set frontend.image.tag="$FRONTEND_TAG" \
     --set postgres.image.repository=postgres \
     --set postgres.image.tag="$POSTGRES_TAG" \
     --set gateway.image.repository=agentgateway \
     --set gateway.image.tag="$GATEWAY_TAG" \
     -n "$NAMESPACE" --wait --timeout 300s
8. Wait for deployments using label selectors (not hardcoded names):
     kubectl rollout status deployment \
       -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/component=backend \
       -n "$NAMESPACE" --timeout=300s
     kubectl rollout status deployment \
       -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/component=frontend \
       -n "$NAMESPACE" --timeout=300s
9. Health check: biznez-cli health-check -r "$RELEASE" -n "$NAMESPACE" --timeout 120
10. Write to $GITHUB_OUTPUT (if set): env_id, cluster_name, namespace
   Port-forward commands using service name resolved via jsonpath:
     SVC=$(kubectl get svc -n "$NAMESPACE" \
       -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/component=frontend \
       -o jsonpath='{.items[0].metadata.name}')
     echo "frontend_portfwd=kubectl port-forward svc/$SVC 8080:80 -n $NAMESPACE" >> "$GITHUB_OUTPUT"
   Credential retrieval command (never the credential itself):
     echo "retrieval_cmd=kubectl get secret biznez-eval-admin-creds -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d" >> "$GITHUB_OUTPUT"

Exit codes: match biznez-cli (0=ok, 2=prereq, 4=kube, 5=secret, 6=health)
```

**Design note (feedback R2#3):** `kubectl port-forward` does not support label selectors directly. The script resolves the service name via `kubectl get svc -l ... -o jsonpath` first, then port-forwards to `svc/<name>`. This avoids hardcoded names while using a supported port-forward target.

### `infra/scripts/teardown.sh`

```
Steps:
1. Parse args: --namespace, --release
2. Preflight: require kubectl, helm; verify cluster connectivity
3. Helm uninstall: helm uninstall "$RELEASE" -n "$NAMESPACE" (continue-on-error)
4. Delete PVCs: kubectl delete pvc -l app.kubernetes.io/instance="$RELEASE" -n "$NAMESPACE" (continue-on-error)
5. Delete namespace: kubectl delete namespace "$NAMESPACE" --wait=false (continue-on-error)
6. All steps use || true -- teardown should never fail the workflow
```

### `infra/scripts/preflight-quotas.sh`

```
Hard fail (exit 2) on:
1. Required APIs not enabled (container, compute, artifactregistry)
2. Billing account not active
3. Org policy blockers (if org policies exist):
   - constraints/compute.vmExternalIpAccess (blocks NAT external IPs)
   - constraints/gke.autopilotAllowed (explicitly disallows Autopilot)
   - constraints/gke.locationRestriction (target region not in allowed list)
   Detected via `gcloud org-policies describe <constraint> --project=<id>`.
   If the gcloud call fails (no org policies / no permission), skip gracefully.

Warn only (exit 0) on:
4. GKE Autopilot cluster count in region >5
5. Regional CPU quota below 8 vCPU available
6. External IP quota below 2 available
7. AR repository count >20

Each check: info message → pass/warn/fail with actionable guidance.
Hard fails block provision; warnings are informational only.
```

### `infra/values/eval-gke.yaml`

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

Minimal. `global.imageRegistry` and per-component `image.repository` overrides set via `--set` at install time (not hardcoded).

## GitHub Actions Workflows

### `.github/workflows/provision-eval.yml`

```yaml
name: Provision Eval Environment
on:
  workflow_dispatch:
    inputs:
      customer_name:
        description: 'Customer name (alphanumeric + hyphens, 3-20 chars)'
        required: true
        type: string
      region:
        description: 'GCP region'
        required: true
        type: choice
        options:
          - europe-west2
          - us-central1
          - us-east1
          - asia-southeast1
      gcp_project_id:
        description: 'GCP project (default: mcpserver-469909)'
        required: false
        type: string
        default: 'mcpserver-469909'

permissions:
  id-token: write    # Required for WIF OIDC token
  contents: read

jobs:
  validate-inputs:
    runs-on: ubuntu-latest
    outputs:
      env_id: ${{ steps.gen.outputs.env_id }}
    steps:
      # Regex validate customer_name: ^[a-z][a-z0-9-]{2,19}$
      # Generate env_id (customer_name + 4-char random suffix)
      # Output: env_id

  provision-infrastructure:
    needs: validate-inputs
    runs-on: ubuntu-latest
    concurrency:
      group: eval-${{ needs.validate-inputs.outputs.env_id }}
      cancel-in-progress: false
    outputs:
      cluster_name: ${{ steps.tf.outputs.cluster_name }}
      ar_url: ${{ steps.tf.outputs.ar_url }}
      env_id: ${{ needs.validate-inputs.outputs.env_id }}
    steps:
      # google-github-actions/auth@v2 with WIF
      # google-github-actions/setup-gcloud@v2
      # hashicorp/setup-terraform@v3
      # Run preflight-quotas.sh
      # terraform init -backend-config="prefix=eval/$ENV_ID"
      # terraform plan -var="customer_name=$CUSTOMER" -var="region=$REGION" -out=tfplan
      # terraform apply tfplan
      # Output: cluster_name, ar_url

  deploy-runtime:
    needs: [validate-inputs, provision-infrastructure]
    runs-on: ubuntu-latest
    concurrency:
      group: eval-${{ needs.validate-inputs.outputs.env_id }}
      cancel-in-progress: false
    steps:
      # google-github-actions/auth@v2
      # google-github-actions/get-gke-credentials@v2
      #
      # Install crane via release binary (NOT gcloud component):
      #   CRANE_VERSION=v0.20.2
      #   curl -sL "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" \
      #     | tar xzf - crane
      #   chmod +x crane && sudo mv crane /usr/local/bin/
      #   Cache via actions/cache keyed on CRANE_VERSION
      #
      # Validate images.lock: for each image, check releaseRepo is non-empty.
      #   If empty and allow_source_repo_fallback != true: FAIL with clear error.
      #
      # Copy images from releaseRepo → customer AR (flat layout, by tag):
      #   Parse images.lock for each image: name, releaseRepo, tag
      #   crane copy <releaseRepo>/<name>:<tag>  $AR_URL/<name>:<tag>
      #
      #   Concrete example:
      #     crane copy releaseRepo/platform-api:0.0.0-dev  $AR_URL/platform-api:0.0.0-dev
      #     crane copy releaseRepo/web-app:0.0.0-dev       $AR_URL/web-app:0.0.0-dev
      #     crane copy releaseRepo/postgres:15-alpine       $AR_URL/postgres:15-alpine
      #     crane copy releaseRepo/agentgateway:0.1.0       $AR_URL/agentgateway:0.1.0
      #
      # Run provision.sh with --images-lock path
      #   (provision.sh parses tags from images.lock and passes --set overrides
      #    for both image.repository and image.tag per component)
      # Output: port-forward commands, cred retrieval command

  notify:
    needs: [validate-inputs, provision-infrastructure, deploy-runtime]
    if: always()
    runs-on: ubuntu-latest
    steps:
      # Write GitHub step summary with:
      #   - Status (success/failure)
      #   - env_id, cluster name, region, project
      #   - Port-forward commands (resolved via service name, not label selector)
      #   - Credential retrieval command (not the credential)
      #   - Teardown instructions (referencing the env_id)
```

### `.github/workflows/teardown-eval.yml`

```yaml
name: Teardown Eval Environment
on:
  workflow_dispatch:
    inputs:
      env_id:
        description: 'Environment ID (customer-xxxx)'
        required: true
        type: string
      region:
        description: 'GCP region'
        required: true
        type: choice
        options: [europe-west2, us-central1, us-east1, asia-southeast1]
      confirm_destroy:
        description: 'Type the env_id to confirm destruction'
        required: true
        type: string

concurrency:
  group: eval-${{ inputs.env_id }}
  cancel-in-progress: false

jobs:
  validate:
    # confirm_destroy must match env_id exactly
    # Validate env_id format: ^[a-z][a-z0-9-]{2,19}-[a-z0-9]{4}$

  uninstall-runtime:
    needs: validate
    steps:
      # Auth via WIF
      # terraform init -backend-config="prefix=eval/$ENV_ID"
      # Fetch cluster name from terraform state (deterministic, no guessing):
      #   CLUSTER_NAME=$(terraform output -raw cluster_name)
      # Get GKE credentials:
      #   gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$REGION"
      # Run teardown.sh (continue-on-error)
      # If terraform output fails (state corrupted), skip helm uninstall and proceed to destroy

  destroy-infrastructure:
    needs: uninstall-runtime
    if: always()
    # terraform init -backend-config="prefix=eval/$ENV_ID"  (already done, but idempotent)
    # terraform destroy -auto-approve
    # All steps continue-on-error to ensure maximum cleanup
    # Terraform state prefix is strictly eval/<env_id> -- cannot touch other state
    # terraform destroy does NOT need kubectl -- it talks to GCP APIs directly
```

**Design note (feedback R3#5):** Cluster name is deterministic (`biznez-eval-<env_id>`) and stored in Terraform state. Teardown fetches it via `terraform output -raw cluster_name` after init -- no guessing or derivation. If the state is corrupted, helm uninstall is skipped and `terraform destroy` still runs (it talks to GCP APIs directly, not kubectl).

## Key Patterns Reused from Phases 1-9

| What | Source | How Used in 10.1 |
|------|--------|------------------|
| `biznez-cli generate-secrets` | `cli/biznez-cli:262` | provision.sh calls with `--format yaml --no-docker-fernet` |
| `biznez-cli install` | `cli/biznez-cli:733` | Not used directly; provision.sh calls `helm upgrade --install` for more control |
| `biznez-cli health-check` | `cli/biznez-cli:838` | provision.sh calls after helm install |
| eval values profile | `examples/eval-quickstart.yaml` | Base for `infra/values/eval-gke.yaml` |
| Script patterns | `release/build-release.sh`, `tests/smoke-test.sh` | `set -euo pipefail`, `info/ok/warn/error`, `trap`, exit codes |
| `images.lock` | `helm/biznez-runtime/images.lock` | Read `releaseRepo` fields for image source + tags |
| `_helpers.tpl` image ref | `helm/biznez-runtime/templates/_helpers.tpl:84-103` | Verified: `{imageRegistry}/{repository}:{tag}` -- flat layout with `--set` overrides |
| CI workflow | `.github/workflows/ci.yml` | Pattern for job structure, checkout, setup steps |
| Chart structure | `helm/biznez-runtime/Chart.yaml` | chart name `biznez-runtime`, version `0.1.0` |
| Helm values | `helm/biznez-runtime/values.yaml` | `global.imageRegistry`, `backend.image.repository`, etc. |

## Implementation Order

1. `infra/terraform/.terraform-version`
2. `infra/terraform/modules/networking/` (main.tf, variables.tf, outputs.tf)
3. `infra/terraform/modules/gke-cluster/` (main.tf, variables.tf, outputs.tf)
4. `infra/terraform/modules/artifact-registry/` (main.tf, variables.tf, outputs.tf)
5. `infra/terraform/modules/iam/` (main.tf, variables.tf, outputs.tf)
6. `infra/terraform/environments/eval/` (main.tf, variables.tf, outputs.tf, backend.tf, versions.tf)
7. `infra/values/eval-gke.yaml`
8. `infra/scripts/preflight-quotas.sh`
9. `infra/scripts/provision.sh`
10. `infra/scripts/teardown.sh`
11. `.github/workflows/provision-eval.yml`
12. `.github/workflows/teardown-eval.yml`

## Exit Criteria

1. `provision-eval.yml` creates a GKE Autopilot cluster + VPC + AR via Terraform (~10 min)
2. All 4 images copied from `releaseRepo` to customer AR via `crane copy`
3. Runtime deploys and `biznez-cli health-check` passes
4. **Image pull validation**: all pods are Running -- no `ImagePullBackOff` (validates IAM bindings)
5. Frontend accessible via port-forward (service name resolved via label selector)
6. Backend health responds at `localhost:8000/api/v1/health` via port-forward
7. `teardown-eval.yml` destroys all resources cleanly (cluster, VPC, AR, state)
8. Re-running provision for same customer creates a new env (different env_id)
9. WIF auth works -- no SA key JSON anywhere
10. All scripts pass `shellcheck -s bash`
11. Terraform validates: `terraform fmt -check` and `terraform validate`
12. All Terraform resources are labeled `managed-by=biznez-provisioner` and prefixed with `env_id`

## What Is NOT In 10.1

- Digest-pinned images (10.2)
- Sanity test suite (10.2)
- LB health-check firewall rules (10.3 -- no LB in 10.1)
- Public ingress / Cloud Armor (10.3)
- Private cluster endpoint (10.3 -- when bastion/VPN plumbing is justified)
- TTL cleanup / env registry (10.4)
- Cloud Run trigger / website callback (10.5)

## Feedback Changelog

| # | Round | Issue | Resolution |
|---|-------|-------|------------|
| 1 | R1 | Private cluster config unsafe/contradictory | Removed `private_cluster_config` entirely. Public endpoint, protected by GCP IAM. Private nodes deferred to 10.3+. |
| 2 | R1 | Concurrency group uses `customer_name` but env_id has random suffix | Concurrency group changed to `eval-<env_id>` at job level. Teardown uses `env_id` as primary key. |
| 3 | R1 | Image source should be `releaseRepo` not `sourceRepo` | Changed to `releaseRepo` from `images.lock`. Single source of truth across all 10.x. |
| 4 | R1 | `gcloud components install crane` unreliable | crane installed via direct binary download from GitHub releases, pinned version, cached. |
| 5 | R1 | AR pull permissions need node-level SA, not Workload Identity | IAM module grants `artifactregistry.reader` to GKE node SA (Compute Engine default SA). |
| 6 | R1 | Preflight quotas too aggressive | Hard fail only on APIs-disabled and billing-disabled. Quota checks are warnings only. |
| 7 | R1 | Hardcoded deployment/service names are brittle | All kubectl operations use label selectors. |
| 8 | R1 | Terraform destroy safety for future 10.4 | All resources prefixed with `env_id`, labeled `managed-by=biznez-provisioner`. |
| 9 | R2 | AR reader must cover both Compute default SA and GKE service agent | IAM module binds `artifactregistry.reader` to both principals. Exit criteria includes image-pull validation. |
| 10 | R2 | Image mirroring adds moving parts -- consider deferring | Kept in 10.1 (rehearses full flow). releaseRepo required (see R3#3). |
| 11 | R2 | `kubectl port-forward deployment -l ...` not supported | Resolve service name via `kubectl get svc -l ... -o jsonpath`, then `port-forward svc/<name>`. |
| 12 | R2 | `global.imageRegistry` alone may not produce correct image paths | Verified `_helpers.tpl`. Using flat AR layout + per-component `--set` overrides for `image.repository`. |
| 13 | R2 | `allow-health-check` firewall rule not needed in 10.1 | Removed. No Ingress or LB in 10.1. Added in 10.3 scope. |
| 14 | R3 | Nested AR paths include illegal registry hostnames (e.g., `ghcr.io/...`) | Removed nested layout entirely. Flat layout only (`platform-api`, `web-app`, `postgres`, `agentgateway`). |
| 15 | R3 | Tags not explicitly set -- chart defaults may not match images.lock | Tags parsed from `images.lock` per component and passed via `--set <component>.image.tag=<tag>`. |
| 16 | R3 | Silent fallback to sourceRepo risks unsigned images | Hard fail if `releaseRepo` empty. Explicit `allow_source_repo_fallback` input (default false) for dev only. |
| 17 | R3 | Preflight should check org policy constraints | Added org policy checks (vmExternalIpAccess, autopilotAllowed, locationRestriction). Skip gracefully if no permission. |
| 18 | R3 | Teardown cluster name derivation not deterministic | Cluster name is `biznez-eval-<env_id>` (deterministic). Teardown fetches via `terraform output`, not derivation. `terraform destroy` doesn't need kubectl. |
