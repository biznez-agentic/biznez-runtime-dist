# Phase 10.9: Upgrade Eval Environment Workflow

## Problem Statement

Currently, the only way to deploy new FE/BE images to an eval environment is to **tear down and re-provision from scratch** using `provision-eval.yml`. This destroys all data — users, organizations, workspaces, MCP server definitions, deployed MCP servers, connectors, and agent configurations.

There is no mechanism to do a rolling upgrade of an existing eval environment when a new backend or frontend image is released.

### Impact

- **Evaluators lose all work** when a bug fix or feature update requires a new image
- **Slow feedback loop** — full provision takes ~15 minutes (Terraform + Helm + bootstrap), whereas a rolling upgrade takes ~2-3 minutes
- **DB migrations can't be tested incrementally** — every deploy starts from a fresh database, so migration-on-existing-data scenarios are never exercised
- **MCP server deployments are lost** — any deployed MCP servers (Google Workspace, GitHub, etc.) and their gateway routes must be manually re-created

## Current Architecture

```
provision-eval.yml (existing)
├── Job 1: Validate inputs (generates NEW env_id)
├── Job 2: Terraform (creates GKE cluster, AR repo, static IP)
├── Job 3: Copy images + provision.sh (Helm install, bootstrap admin, seed data)
└── Job 4: Summary
```

`provision-eval.yml` always creates **new infrastructure**. The `env_id` is randomly generated (e.g., `manimaun22-4ui5`), and Terraform provisions a fresh GKE cluster, Artifact Registry repo, and static IP for each run.

### Image Tag Flow

Image tags are pinned in `helm/biznez-runtime/images.lock`:
```yaml
images:
  - name: platform-api
    sourceRepo: "europe-west2-docker.pkg.dev/mcpserver-469909/biznez-backend/platform-api"
    tag: "dev-248758a..."
  - name: web-app
    sourceRepo: "europe-west2-docker.pkg.dev/mcpserver-469909/biznez-frontend/web-app"
    tag: "dev-e8f09d0"
```

The provision workflow reads these tags, copies images from source AR → eval AR using `crane copy`, then passes the tags to `helm upgrade --install`.

## Proposed Solution

Create a new **`upgrade-eval.yml`** GitHub Actions workflow that performs a rolling Helm upgrade on an **existing, healthy** eval environment.

### Prerequisite

**This workflow is for upgrading an already healthy eval environment.** It is not a repair workflow for broken or half-provisioned environments. If the environment is in a degraded state, use `provision-eval.yml` to rebuild or fix it manually first.

### Scope: Full Chart + Image Upgrade

This workflow performs a **full chart + image upgrade**, not just an image tag swap. When run from a branch, the Helm chart templates from that branch are applied alongside the new image tags. This means:

- Template changes (new env vars, config tweaks, resource adjustments) are part of the rollout
- Chart-level changes increase risk compared to an image-only refresh
- Operators should review `git diff` on the chart directory before running against a working eval

This is an intentional design choice — eval environments need to validate chart changes alongside code changes. An image-only mode could be added later if needed.

**Operator guidance:** This workflow upgrades Helm templates from the selected branch, not just images. Do not run it against a valuable eval environment unless you have reviewed `helm/biznez-runtime/` changes in that branch (`git diff main -- helm/biznez-runtime/`).

**Backward compatibility rule:** This workflow is safe for incremental upgrades where the chart schema remains backward compatible. If the chart introduces breaking values or schema changes, use `provision-eval.yml` for a clean deploy or create a dedicated migration path instead.

### What This Workflow Does NOT Do

This workflow preserves existing state and does not re-run any bootstrap steps:

- Does **not** reseed eval data
- Does **not** recreate the admin user
- Does **not** re-register runtimes
- Does **not** touch bootstrap secrets
- Does **not** re-run `provision.sh`

### Key Differences from Provisioning

| Aspect | `provision-eval.yml` | `upgrade-eval.yml` (new) |
|--------|---------------------|--------------------------|
| Input | `customer_name` → generates new `env_id` | `env_id` (existing environment) |
| Terraform | Yes — creates cluster, AR, IP | **No** — skips entirely |
| Database | Fresh — runs seed, creates admin | **Preserved** — untouched |
| Users/Orgs | New admin + bootstrap | **Preserved** |
| MCP servers | Lost | **Expected preserved** (see caveats) |
| Helm operation | `helm upgrade --install` (fresh) | `helm upgrade --reuse-values` (rolling) |
| Migrations | Init container (fresh DB) | Init container (incremental on existing DB) |
| Secrets | Generated fresh | **Preserved** — Helm reuses existing values |
| Ingress | Configured from Terraform output | **Preserved** — Helm reuses existing values |
| Bootstrap | Full (admin, workspace, runtime, seed) | **None** |
| Duration | ~15 minutes | ~2-3 minutes |

### Workflow Design

```
upgrade-eval.yml (new)
├── Job 1: Upgrade Runtime
│   ├── Step 1: Checkout repo
│   ├── Step 2: GCP auth (WIF)
│   ├── Step 3: Get GKE credentials (derive cluster name from env_id)
│   ├── Step 4: Preflight checks (release exists, namespace, deployments, health)
│   ├── Step 5: Derive + validate AR URL against live deployment images
│   ├── Step 6: Preview (show current vs target images, Helm revisions — informational)
│   ├── Step 6b: Validate source image existence (crane manifest for each image)
│   ├── Step 6c: [dry_run stops here — print crane copy commands and exit]
│   ├── Step 7: Copy updated images from images.lock → eval AR
│   ├── Step 8: Helm upgrade --reuse-values (only override image tags)
│   ├── Step 9: Verify rollout + show new image tags
│   ├── Step 10: Post-upgrade health checks (service port-forward, ingress, migrations)
│   └── Step 11: Post-upgrade MCP/gateway verification (best-effort diagnostics)
└── Job 2: Summary (includes rollback instructions, especially on failure)
```

### Concurrency

Only one upgrade can run against a given environment at a time:

```yaml
concurrency:
  group: upgrade-eval-${{ inputs.env_id }}
  cancel-in-progress: false
```

This prevents two operators from upgrading the same env simultaneously.

### Workflow Inputs

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `env_id` | string | Yes | Existing environment ID (e.g., `manimaun22-4ui5`) |
| `region` | choice | Yes | GCP region where the cluster lives |
| `gcp_project_id` | string | No | Defaults to `vars.GCP_PROJECT_ID` |
| `allow_source_repo_fallback` | boolean | No | Allow `sourceRepo` when `releaseRepo` is empty (default: true for dev) |
| `dry_run` | boolean | No | If true, run preflight + preview + source image validation but **stop before any mutations** (default: false) |

The `dry_run` input is the v1 approval mechanism. Operators can run with `dry_run: true` to see the full preview, validate source image existence, and print the exact `crane copy` commands that *would* run — without actually copying images or touching the cluster. Then re-run with `dry_run: false` to apply. GitHub Actions does not support mid-job pauses, so this two-run pattern is the practical alternative.

**`dry_run: true` is strictly non-mutating.** It does not copy images, does not run Helm upgrade, and does not modify any target registry or cluster state.

## Detailed Step Design

### Step 4: Preflight Checks

Before touching anything, validate the environment is healthy and complete:

```bash
# 1. Namespace exists
kubectl get namespace biznez || {
  echo "::error::Namespace 'biznez' not found. This env may not exist or is partially provisioned."
  echo "::error::Use provision-eval.yml to create or repair the environment."
  exit 1
}

# 2. Helm release exists
helm status biznez -n biznez || {
  echo "::error::Helm release 'biznez' not found. Use provision-eval.yml first."
  exit 1
}

# 3. Core deployments exist
for DEPLOY in biznez-biznez-runtime-backend biznez-biznez-runtime-frontend biznez-biznez-runtime-gateway; do
  kubectl get deploy "$DEPLOY" -n biznez || {
    echo "::error::Deployment $DEPLOY not found. Environment is incomplete."
    exit 1
  }
done

# 4. Backend is currently healthy (via service port-forward)
#    Use trap to ensure port-forward is cleaned up on any exit (curl failure, shell error, etc.)
kubectl port-forward svc/biznez-biznez-runtime-backend -n biznez 18000:8000 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3
curl -sf --max-time 10 http://localhost:18000/api/v1/health || {
  echo "::error::Backend health check failed. Fix the existing environment before upgrading."
  exit 1
}
kill $PF_PID 2>/dev/null || true
trap - EXIT

# 5. Ingress exists (if expected)
kubectl get ingress -n biznez -o name || echo "::warning::No ingress found"
```

If any check fails, the workflow exits with:
> "This environment looks incomplete or unhealthy. Use provision-eval.yml to create or repair it first."

### Step 5: Derive + Validate AR URL

Do **not** trust convention alone. Validate the derived AR URL against the live deployment:

```bash
# Derive from naming convention
DERIVED_AR_URL="${REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/biznez-eval-${ENV_ID}"

# Read actual image prefix from live backend deployment
CURRENT_IMAGE=$(kubectl get deploy biznez-biznez-runtime-backend -n biznez \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
# e.g., "europe-west2-docker.pkg.dev/mcpserver-469909/biznez-eval-manimaun22-4ui5/platform-api:dev-abc123"

CURRENT_AR_PREFIX=$(echo "$CURRENT_IMAGE" | sed 's|/[^/]*:[^:]*$||')
# e.g., "europe-west2-docker.pkg.dev/mcpserver-469909/biznez-eval-manimaun22-4ui5"

if [ "$DERIVED_AR_URL" != "$CURRENT_AR_PREFIX" ]; then
  echo "::warning::AR URL mismatch — using live value instead of derived."
  echo "  Derived:  $DERIVED_AR_URL"
  echo "  Live:     $CURRENT_AR_PREFIX"
  AR_URL="$CURRENT_AR_PREFIX"
else
  AR_URL="$DERIVED_AR_URL"
fi
```

This ensures we never copy images to the wrong registry or deploy tags that don't exist.

### Step 6: Preview (Current vs Target)

Print a clear before/after comparison. This is **informational only** — the workflow proceeds immediately after printing. Use `dry_run: true` to stop before mutations.

```bash
# Capture current Helm revision for rollback reference
PRE_UPGRADE_REVISION=$(helm history biznez -n biznez -o json | python3 -c "
import sys, json
revs = json.load(sys.stdin)
print(revs[-1]['revision'])
")
PREVIOUS_REVISION=$((PRE_UPGRADE_REVISION - 1))
```

```
=== Upgrade Preview ===
Cluster:    biznez-eval-manimaun22-4ui5
Namespace:  biznez
Release:    biznez (current revision: 3, rollback target: 2)
Ingress:    35.197.215.138.nip.io
AR URL:     europe-west2-docker.pkg.dev/mcpserver-469909/biznez-eval-manimaun22-4ui5
Dry run:    false

  Component        Current Tag              Target Tag
  ─────────        ───────────              ──────────
  platform-api     dev-248758a...           dev-new-sha...
  web-app          dev-e8f09d0              dev-new-fe-sha
  agentgateway     latest                   latest (unchanged)
  postgres         15-alpine                15-alpine (unchanged)
```

### Step 6b: Validate Source Image Existence

Before any mutations, verify all source images from `images.lock` actually exist in their source registries:

```bash
# Validate every source image exists before copying any
MISSING=0
for IMG_NAME in platform-api web-app agentgateway postgres; do
  SOURCE=$(python3 -c "import json; d=json.load(open('/tmp/images-parsed.json')); print(d['$IMG_NAME']['sourceRepo'])")
  TAG=$(python3 -c "import json; d=json.load(open('/tmp/images-parsed.json')); print(d['$IMG_NAME']['tag'])")
  if ! crane manifest "${SOURCE}:${TAG}" > /dev/null 2>&1; then
    echo "::error::Source image not found: ${SOURCE}:${TAG}"
    MISSING=$((MISSING + 1))
  else
    echo "  ✓ ${SOURCE}:${TAG} exists"
  fi
done

if [ "$MISSING" -gt 0 ]; then
  echo "::error::$MISSING source image(s) not found. Aborting before any mutations."
  exit 1
fi
```

This ensures all images are available **before** any `crane copy` runs. If any source image is missing, the workflow fails without touching the target registry.

### Step 6c: Dry Run Exit Point

If `dry_run` is true, print the `crane copy` commands that *would* run, then exit successfully:

```bash
if [ "$DRY_RUN" = "true" ]; then
  echo "=== Dry Run — commands that would execute ==="
  for IMG_NAME in platform-api web-app agentgateway postgres; do
    SOURCE=$(...)  # from parsed images
    TAG=$(...)
    echo "  crane copy ${SOURCE}:${TAG} ${AR_URL}/${IMG_NAME}:${TAG}"
  done
  echo ""
  echo "Dry run complete. Re-run with dry_run=false to apply."
  exit 0
fi
```

### Step 7: Parse images.lock with Python (not awk)

Use Python with PyYAML for robust YAML parsing instead of fragile awk patterns:

```bash
# Pin PyYAML version for repeatability and governance
python3 -m pip install pyyaml==6.0.2

# Parse images.lock and extract tag/repo info
python3 <<'PYEOF'
import yaml, json, sys

with open("helm/biznez-runtime/images.lock") as f:
    data = yaml.safe_load(f)

result = {}
for img in data.get("images", []):
    name = img["name"]
    result[name] = {
        "tag": img.get("tag", ""),
        "sourceRepo": img.get("sourceRepo", ""),
        "releaseRepo": img.get("releaseRepo", ""),
    }

# Write as JSON for easy consumption by bash
with open("/tmp/images-parsed.json", "w") as f:
    json.dump(result, f)

# Also write individual env vars for bash
for name, info in result.items():
    safe_name = name.replace("-", "_").upper()
    print(f"{safe_name}_TAG={info['tag']}")
    print(f"{safe_name}_SOURCE={info['sourceRepo']}")
    print(f"{safe_name}_RELEASE={info['releaseRepo']}")
PYEOF
```

This is more resilient than awk if the YAML format changes (indentation, quoting, comments, ordering).

### Step 8: Helm Upgrade Strategy — `--reuse-values`

**Critical design decision**: Use `helm get values` + `helm upgrade --reuse-values` instead of reconstructing Helm args from partial reads.

```bash
# Capture pre-upgrade revision for rollback reference
PRE_REVISION=$(helm history biznez -n biznez -o json | python3 -c "
import sys, json; print(json.load(sys.stdin)[-1]['revision'])")
echo "Pre-upgrade revision: $PRE_REVISION"

# Log current effective values (for audit / rollback reference)
helm get values biznez -n biznez -o yaml > /tmp/pre-upgrade-values.yaml
echo "--- Current Helm values (pre-upgrade) ---"
cat /tmp/pre-upgrade-values.yaml

# Upgrade with --reuse-values: preserves ALL existing config
# Only override the specific image tags that changed
helm upgrade biznez ./helm/biznez-runtime \
  --reuse-values \
  --set backend.image.tag="$BACKEND_TAG" \
  --set frontend.image.tag="$FRONTEND_TAG" \
  --set gateway.image.tag="$GATEWAY_TAG" \
  --set postgres.image.tag="$POSTGRES_TAG" \
  -n biznez --wait --timeout 600s

# Capture post-upgrade revision
POST_REVISION=$(helm history biznez -n biznez -o json | python3 -c "
import sys, json; print(json.load(sys.stdin)[-1]['revision'])")
echo "Post-upgrade revision: $POST_REVISION (rollback target: $PRE_REVISION)"

# Log post-upgrade values for comparison
helm get values biznez -n biznez -o yaml > /tmp/post-upgrade-values.yaml
echo "--- Helm values diff (pre vs post) ---"
diff /tmp/pre-upgrade-values.yaml /tmp/post-upgrade-values.yaml || true
```

**Why `--reuse-values`:**
- Preserves all existing config: secrets, ingress, RBAC, resource limits, feature flags, security contexts, `rbac.serviceAccountName`, `frontend.config.apiUrl`, `backend.existingSecret`, `postgres.existingSecret` — everything
- No risk of accidentally dropping values that were set at provision time
- Only the explicitly overridden image tags change
- Avoids the fragile pattern of reading individual values from kubectl/secrets and reconstructing Helm args

**Caveat:** `--reuse-values` can keep old values that may no longer be wanted if the chart schema has changed. For eval upgrades, preserving working config is more important than ensuring schema freshness. If chart schema changes require new values, those must be explicitly passed as additional `--set` flags.

### Step 10: Post-Upgrade Health Checks (v1, not future)

Use **service port-forward from the runner** for health checks — do not assume containers have `curl` installed. Use `trap` around every port-forward block to ensure cleanup on any exit.

**Service port-forward health checks are authoritative.** Ingress checks are supplemental — DNS/LB propagation may lag briefly after an upgrade, so ingress failures are warnings, not errors.

```bash
# 1. Backend health (via service port-forward from runner — AUTHORITATIVE)
kubectl port-forward svc/biznez-biznez-runtime-backend -n biznez 18000:8000 &
PF_BACKEND=$!
trap 'kill $PF_BACKEND 2>/dev/null || true' EXIT
sleep 3
curl -sf --max-time 10 http://localhost:18000/api/v1/health || {
  echo "::error::Backend health check failed after upgrade"
  exit 1
}
kill $PF_BACKEND 2>/dev/null || true
trap - EXIT
echo "Backend health: OK"

# 2. Frontend reachable (via service port-forward from runner — AUTHORITATIVE)
kubectl port-forward svc/biznez-biznez-runtime-frontend -n biznez 18080:80 &
PF_FRONTEND=$!
trap 'kill $PF_FRONTEND 2>/dev/null || true' EXIT
sleep 3
curl -sf --max-time 10 http://localhost:18080/ -o /dev/null || {
  echo "::error::Frontend health check failed after upgrade"
  exit 1
}
kill $PF_FRONTEND 2>/dev/null || true
trap - EXIT
echo "Frontend health: OK"

# 3. Ingress-level checks — SUPPLEMENTAL, non-fatal
#    DNS/LB propagation may lag briefly after an upgrade. These are warnings only.
INGRESS_HOST=$(kubectl get ingress -n biznez -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null) || true
if [ -n "$INGRESS_HOST" ]; then
  curl -sf --max-time 10 "http://${INGRESS_HOST}/api/v1/health" || {
    echo "::warning::Backend not reachable through ingress (DNS/LB propagation may be in progress — non-fatal)"
  }
  curl -sf --max-time 10 "http://${INGRESS_HOST}/" -o /dev/null || {
    echo "::warning::Frontend not reachable through ingress (DNS/LB propagation may be in progress — non-fatal)"
  }
fi

# 4. Migration init container succeeded
#    Target the pod from the LATEST ReplicaSet owned by the backend Deployment,
#    not just the newest pod by timestamp. This is more reliable during rollouts
#    with pod churn or retries.
LATEST_RS=$(kubectl get rs -n biznez -l app.kubernetes.io/component=backend \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
if [ -n "$LATEST_RS" ]; then
  # Get pods owned by the latest ReplicaSet via pod-template-hash label
  POD_HASH=$(kubectl get rs "$LATEST_RS" -n biznez -o jsonpath='{.metadata.labels.pod-template-hash}')
  NEW_POD=$(kubectl get pod -n biznez \
    -l app.kubernetes.io/component=backend,pod-template-hash="$POD_HASH" \
    --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null) || true
else
  # Fallback: newest backend pod by creation timestamp
  NEW_POD=$(kubectl get pod -n biznez -l app.kubernetes.io/component=backend \
    --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
fi

if [ -n "$NEW_POD" ]; then
  INIT_STATUS=$(kubectl get pod "$NEW_POD" -n biznez \
    -o jsonpath='{.status.initContainerStatuses[?(@.name=="run-migrations")].state.terminated.exitCode}' 2>/dev/null) || true
  if [ -n "$INIT_STATUS" ] && [ "$INIT_STATUS" != "0" ]; then
    echo "::error::Migration init container on pod $NEW_POD exited with code $INIT_STATUS"
    echo "::error::Check logs: kubectl logs $NEW_POD -n biznez -c run-migrations"
    exit 1
  fi
  echo "Migration check: OK (pod=$NEW_POD, rs=$LATEST_RS, exit=$INIT_STATUS)"
fi
```

### Step 11: Post-Upgrade MCP/Gateway Verification (Best-Effort Diagnostics)

This step is **best-effort and warning-only**. It provides diagnostic information but does not block the workflow on failure.

MCP server deployments and gateway routes are **expected to be preserved** but not guaranteed, especially if chart changes touch shared components (namespace labels, network policies, RBAC).

**Two verification layers:**

1. **K8s namespace check (supplemental)** — looks for namespaces with known labels. May report "not found" if labels are inconsistent. Not authoritative.

2. **API check (authoritative, if available)** — queries the backend API for MCP/gateway counts. This is the source of truth but depends on the backend being healthy.

```bash
echo "=== MCP/Gateway Post-Upgrade Diagnostics (best-effort) ==="

# Layer 1: Namespace check (supplemental — depends on consistent labeling)
MCP_NS=$(kubectl get ns -l biznez-platform=true -o name 2>/dev/null) || true
if [ -n "$MCP_NS" ]; then
  echo "MCP namespaces found:"
  echo "$MCP_NS"
  for NS in $MCP_NS; do
    NS_NAME=$(echo "$NS" | sed 's|namespace/||')
    kubectl get pods -n "$NS_NAME" --no-headers 2>/dev/null || true
  done
else
  echo "No MCP namespaces found via label (may not be labeled, or no MCP servers deployed)"
fi

# Layer 2: API check (authoritative — uses the application's own endpoints)
#   Uses the canonical backend MCP listing endpoint currently used by the frontend.
#   If this endpoint path changes in a future release, this diagnostic will silently
#   return empty and emit a warning — it will never fail the upgrade.
MCP_API_PATH="/api/v1/mcp/servers"

kubectl port-forward svc/biznez-biznez-runtime-backend -n biznez 18000:8000 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3

MCP_RESP=$(curl -sf --max-time 10 "http://localhost:18000${MCP_API_PATH}" 2>/dev/null) || true
if [ -n "$MCP_RESP" ]; then
  echo "MCP servers API response received"
  echo "$MCP_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get('items', [])
print(f'MCP server definitions: {len(items)}')
for s in items:
    print(f\"  {s.get('name', '?'):20s} status={s.get('status', '?')}\")
" 2>/dev/null || echo "  (could not parse response — endpoint may have changed)"
else
  echo "::warning::Could not reach MCP servers API at ${MCP_API_PATH} (endpoint may have changed — non-fatal)"
fi

kill $PF_PID 2>/dev/null || true
trap - EXIT
```

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Wrong `env_id` targets wrong cluster | Preflight shows current state; AR URL validated against live images |
| Config drift from partial value reconstruction | **`--reuse-values`** preserves all existing Helm config; only image tags are overridden |
| AR URL naming convention is wrong | Derived AR URL is compared against live deployment image prefix; falls back to live value on mismatch |
| Breaking DB migration | Helm/K8s rollout avoids immediate replacement of healthy old pods. **However**, failed migrations may leave the database in a partially migrated state. Workflow fails fast and requires manual review before retry. Do NOT retry automatically. |
| MCP servers affected by chart changes | Post-upgrade best-effort diagnostics check MCP namespaces and API. Labeled as "expected preserved" not guaranteed. |
| Chart template changes introduce regressions | This is a full chart+image upgrade. Operators should review chart diff before running. Use `dry_run: true` to preview first. |
| Image not found in source AR | Source image existence is validated (`crane manifest`) for all images before any `crane copy` runs. Fails before any target mutation. |
| `--reuse-values` keeps stale config | Acceptable for backward-compatible upgrades. If chart introduces breaking schema changes, use `provision-eval.yml` or an explicit migration path instead. |
| Two upgrades on same env simultaneously | Job-level concurrency group `upgrade-eval-{env_id}` prevents this |
| Containers don't have curl/wget | Health checks use service port-forward from the GHA runner, not kubectl exec |
| Migration check targets wrong pod | Migration verification targets a pod from the latest ReplicaSet (via `pod-template-hash` label), not just newest pod by timestamp. Falls back to timestamp sort if RS lookup fails. |
| Workflow used on broken/incomplete env | Preflight checks enforce that namespace, Helm release, core deployments, and backend health must all pass before proceeding |

## Rollback

The workflow summary **always** includes the captured revision numbers and rollback instructions:

```
## Upgrade Summary

Pre-upgrade revision:  3
Post-upgrade revision: 4
Rollback target:       3
```

On workflow failure, the summary outputs:
```
## Upgrade Failed

The upgrade did not complete successfully. The previous revision may still be serving.

Pre-upgrade revision: 3 ← rollback to this
Post-upgrade revision: 4 (failed)

### Immediate Actions

1. Check pod status:
   gcloud container clusters get-credentials biznez-eval-{env_id} --region {region} --project {project}
   kubectl get pods -n biznez

2. Check migration logs:
   kubectl logs <backend-pod> -n biznez -c run-migrations

3. Rollback to previous revision:
   helm rollback biznez 3 -n biznez --wait --timeout 300s

4. If DB is in a partially migrated state, do NOT retry automatically.
   Review migration logs and database state before any further action.
```

## Usage Flow

### Scenario: Preview before upgrading (dry run)

1. **Run workflow** with `dry_run: true`
2. Review the preview output — current vs target images, Helm revision, AR URL validation, source image existence, and the exact `crane copy` commands that would run
3. No mutations occur — no images are copied, no Helm upgrade runs
4. If everything looks correct, re-run with `dry_run: false`

### Scenario: New FE/BE images released

1. **Update `images.lock`** — bump the `tag` field for `platform-api` and/or `web-app`:
   ```yaml
   - name: platform-api
     tag: "dev-new-commit-sha"
   - name: web-app
     tag: "dev-new-fe-sha"
   ```

2. **Commit and push** to the branch (or directly to `main`)

3. **Run workflow** — Go to Actions → **Upgrade Eval Environment**:
   - `env_id`: `manimaun22-4ui5`
   - `region`: `europe-west2`
   - Click "Run workflow"

4. **Review** — workflow prints preview, runs upgrade, health checks, and MCP diagnostics

5. **On failure** — follow rollback instructions in the workflow summary

### Scenario: Only backend update needed

Same flow — only update `platform-api` tag in `images.lock`. The frontend image won't change (crane copies are idempotent with same tag). `--reuse-values` ensures nothing else drifts.

## File Changes

At minimum one workflow file. Helper scripts may be extracted during implementation if complexity warrants it (e.g., images.lock parsing, image copy, rollout/health verification).

| # | File | Change |
|---|------|--------|
| 1 | `.github/workflows/upgrade-eval.yml` | **New file** — Upgrade Eval Environment workflow |
| 2+ | `infra/scripts/upgrade-helpers/` (optional) | Reusable scripts if workflow logic grows beyond one file |

## Future Enhancements

- **Auto-trigger on `images.lock` change** — add a `push` trigger to auto-upgrade active eval environments
- **Multi-env upgrade** — accept comma-separated `env_id` list for parallel upgrades
- **Automated rollback** — `rollback-eval.yml` workflow that runs `helm rollback`
- **Image-only mode** — a constrained mode that only swaps image tags without applying chart template changes, for lower-risk updates
- **GitHub Environment approval** — use a GitHub Environment with required reviewers between preview and apply jobs, as an alternative to the `dry_run` input
