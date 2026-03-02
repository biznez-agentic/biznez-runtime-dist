# GCP Bootstrap Automation for Eval Provisioning

## Context

Phase 10.1 requires 6 GCP resources and 3 GitHub settings to exist before the `provision-eval.yml` workflow can run. Currently these are documented as manual steps in the plan doc. From a client perspective, asking them to run 15+ gcloud commands in sequence is error-prone and a bad first impression. A single `bootstrap-gcp.sh` script that automates the entire setup — GCP resources + GitHub secrets/variables — gives clients a one-command onboarding experience.

## Assumptions

- **One repo per GCP project.** WIF pool/provider names (`biznez-github-pool`, `github-actions`) are per-project. If multi-repo support is needed later, provider names would need to include the repo name (e.g., `github-actions-biznez-runtime-dist`). Documented but not implemented in 10.1.
- **Repo-level secrets only.** GitHub Environment-level secrets are not used in 10.1. Can be added later if environment-based RBAC is needed.
- **Eval-only project.** The SA roles (container.admin, compute.admin, iam.serviceAccountAdmin, etc.) are broad and intended for a dedicated eval project, NOT a production or shared org project. Future: split into separate provisioner vs cleanup service accounts in Phase 10.4.

## What Gets Created

| # | Resource | Name / Value |
|---|----------|-------------|
| 1 | GCS bucket (Terraform state) | `biznez-terraform-state-<project-id>` (uniform access, public access prevention, versioning) |
| 2 | APIs enabled | container, compute, artifactregistry, iam, iamcredentials, serviceusage |
| 3 | WIF pool | `biznez-github-pool` |
| 4 | WIF OIDC provider | `github-actions` (issuer + attribute mapping only, no repo restriction at provider level) |
| 5 | Service account | `biznez-github-provisioner@<project>.iam.gserviceaccount.com` |
| 6 | SA role bindings | roles/container.admin, roles/compute.admin, roles/artifactregistry.admin, roles/iam.serviceAccountAdmin, roles/storage.objectAdmin, roles/serviceusage.serviceUsageAdmin |
| 7 | WIF → SA binding | `principalSet` restricted to repo at SA level (the actual authorization boundary) |
| 8 | GitHub variable | `GCP_PROJECT_ID` = `<project-id>` |
| 9 | GitHub secrets | `GCP_WORKLOAD_IDENTITY_PROVIDER` = full provider resource name, `GCP_SERVICE_ACCOUNT` = SA email |

**Note:** Bucket name includes project ID to avoid global name collisions. The `backend.tf` bucket name will need a corresponding update.

## New Files

```
infra/scripts/bootstrap-gcp.sh    # One-time GCP + GitHub setup
infra/.bootstrap.env              # Generated output: project details for local reference (chmod 600)
```

Also modifies:
```
infra/terraform/environments/eval/backend.tf              # Remove hardcoded bucket, pass both via -backend-config
.github/workflows/provision-eval.yml                      # Add -backend-config="bucket=..." to terraform init
.github/workflows/teardown-eval.yml                       # Add -backend-config="bucket=..." to terraform init
.gitignore                                                # Add infra/.bootstrap.env
```

## Script Design: `infra/scripts/bootstrap-gcp.sh`

### Interface

```
Usage:
  ./bootstrap-gcp.sh --project <gcp-project-id> [--bucket-location <location>] [--repo <owner/repo>]
  ./bootstrap-gcp.sh status --project <gcp-project-id> [--repo <owner/repo>]

Commands:
  (default)   Create all GCP resources and set GitHub secrets
  status      Check prerequisite status (exists/missing) without changing anything

Flags:
  --project          GCP project ID (required)
  --bucket-location  GCS bucket location (default: EU). Accepts multi-region (EU, US, ASIA)
                     or single region (europe-west2, us-central1, etc.)
  --region           Alias for --bucket-location (convenience)
  --repo             GitHub repo in owner/name format (default: auto-detect from git remote)
  --no-github        Skip GitHub secrets/variables setup; print gh commands instead
  --no-write-probe   Skip the side-effecting write probe in preflight (for restricted environments)
  --dry-run          Show what will be created without executing
  --quiet            Reduce output for CI-style runs (only errors and final summary)
  --yes              Skip confirmation prompt
```

### `status` Subcommand

Read-only check of all prerequisites. Prints a table:

```
Resource                        Status
──────────────────────────────  ──────
APIs (6 required)               5/6 enabled (missing: artifactregistry)
GCS bucket                      EXISTS: biznez-terraform-state-myproject
WIF pool                        MISSING
WIF OIDC provider               MISSING
Service account                 EXISTS: biznez-github-provisioner@...
SA role bindings (6 required)   4/6 bound
WIF → SA binding                MISSING
GitHub var: GCP_PROJECT_ID      SET
GitHub secret: WIF_PROVIDER     SET
GitHub secret: SERVICE_ACCOUNT  SET
```

**GitHub check scope (R4#1):** If `gh` is unavailable or not authenticated, GitHub
checks are printed as `SKIPPED (no gh access)` instead of failing. The exit code
is based on GCP resources only:
- Exit 0: all GCP resources present (GitHub status unknown)
- Exit 1: any GCP resource missing

When `gh` IS available, GitHub checks are included in the overall pass/fail.

Does not modify anything.

### Flow

```
1. Preflight
   - Require: gcloud (authenticated)
   - GitHub CLI handling (R3#8): attempt to detect gh availability and auth status.
     If gh is missing, not authenticated, or lacks admin on the repo:
       auto-switch to --no-github mode (continue with GCP setup, print gh commands at end).
     This prevents hard failure on clients who can't use gh CLI.
     Only skip this auto-detection if --no-github was explicitly set.
   - Validate project exists and billing is active
   - Early-hint probes: "best effort" sanity checks, NOT proof of create capability.
     The real create steps are the proof — probes catch obvious permission gaps early.
       a. gcloud services list --project=<id>
          fail → "You need roles/serviceusage.serviceUsageViewer (or broader) to list APIs"
       b. Write probe (R3#5, R4#5): skipped when --dry-run OR --no-write-probe.
          When run:
          info "Write probe: attempting to enable serviceusage.googleapis.com (idempotent)"
          gcloud services enable serviceusage.googleapis.com --project=<id>
          fail → "You need roles/serviceusage.serviceUsageAdmin to enable APIs"
          When skipped via --no-write-probe:
          info "Write probe: skipped (--no-write-probe)"
       c. gcloud iam workload-identity-pools list --location=global --project=<id>
          fail → "You need roles/iam.workloadIdentityPoolAdmin (or broader)"
       d. gcloud iam service-accounts list --project=<id>
          fail → "You need roles/iam.serviceAccountAdmin (or broader)"
     Each probe: pass → ok, fail → error with specific remediation.
     Note: probes do NOT guarantee create/update will succeed. If a later
     create step fails, the error message includes the specific permission needed.
   - Detect GitHub repo from `git remote get-url origin` if --repo not specified
     Normalise both SSH and HTTPS remote formats:
       git@github.com:owner/repo.git     → owner/repo
       https://github.com/owner/repo.git → owner/repo
       https://github.com/owner/repo     → owner/repo
     Fail fast (R3#4) if:
       - remote host is NOT github.com → error "Remote is not a GitHub repo.
         Use --repo owner/name to specify the GitHub repository explicitly."
       - parsing fails (can't extract owner/repo) → same error
   - Fetch PROJECT_NUMBER via: gcloud projects describe <id> --format="value(projectNumber)"

2. Confirmation
   - Print summary table of all resources that will be created
   - Print warning banner (R3#6):
       "WARNING: This grants broad admin roles (container.admin, compute.admin,
        iam.serviceAccountAdmin, etc.) to the provisioner SA in project <PROJECT_ID>.
        Use this only in a DEDICATED EVAL PROJECT, not a production or shared org project."
   - Prompt: "Create these resources? [y/N]" (skip with --yes)

3. Enable APIs (idempotent)
   gcloud services enable <api> --project=<id>
   (6 APIs — gcloud enable is already idempotent)

4. Create GCS bucket (R3#2: hardened defaults, R4#3/R4#4: conditional mutation)
   BUCKET="biznez-terraform-state-${PROJECT_ID}"
   if ! gsutil ls -b "gs://${BUCKET}" &>/dev/null; then
     gsutil mb -p "$PROJECT_ID" -l "$BUCKET_LOCATION" -b on "gs://${BUCKET}"
     # New bucket — apply all hardening unconditionally
     gsutil uniformbucketlevelaccess set on "gs://${BUCKET}"
     gsutil pap set enforced "gs://${BUCKET}"
     gsutil versioning set on "gs://${BUCKET}"
   else
     # Bucket already exists (R4#4): apply hardening settings ONLY with loud warning.
     # These mutations are additive/safe (they don't delete data), but the operator
     # should know their existing bucket is being modified.
     warn "Bucket gs://${BUCKET} already exists."
     warn "Applying hardening settings (uniform access, public access prevention, versioning)."
     warn "These are additive safety settings and do not affect existing data."
     gsutil uniformbucketlevelaccess set on "gs://${BUCKET}"
     gsutil pap set enforced "gs://${BUCKET}"
     gsutil versioning set on "gs://${BUCKET}"
   fi
   fail → "Bucket creation failed. You need roles/storage.admin on the project,
           or the bucket name may already be taken globally."

   -b on: uniform bucket-level access (no per-object ACLs)
   pap set enforced: public access prevention (no accidental public exposure)
   versioning: protects against accidental state deletion

5. Create WIF pool (check-before-create, R4#3: create-only, never mutate)
   if ! gcloud iam workload-identity-pools describe biznez-github-pool \
        --location=global --project="$PROJECT_ID" &>/dev/null; then
     gcloud iam workload-identity-pools create biznez-github-pool \
       --location=global --project="$PROJECT_ID" \
       --display-name="Biznez GitHub Actions Pool"
   else
     info "WIF pool biznez-github-pool already exists — skipping (not mutated)."
   fi

6. Create WIF OIDC provider (R3#1: no repo restriction; R4#3: create-only, never mutate)
   Provider sets issuer + attribute mapping ONLY. Repo scoping is enforced
   at the SA binding (step 9), which is the actual authorization boundary.

   **Safety (R4#3):** If pool or provider already exists, the script does NOT
   update its configuration. This prevents accidentally overwriting attribute
   mappings or other settings that may have been customised post-bootstrap.
   To update an existing provider, use `gcloud ... update-oidc` manually.

   if ! gcloud iam workload-identity-pools providers describe github-actions \
        --workload-identity-pool=biznez-github-pool \
        --location=global --project="$PROJECT_ID" &>/dev/null; then
     gcloud iam workload-identity-pools providers create-oidc github-actions \
       --workload-identity-pool=biznez-github-pool \
       --location=global --project="$PROJECT_ID" \
       --issuer-uri="https://token.actions.githubusercontent.com" \
       --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.actor=assertion.actor,attribute.ref=assertion.ref" \
       --display-name="GitHub Actions OIDC"
   else
     info "WIF provider github-actions already exists — skipping (not mutated)."
   fi

   Script output after provider creation (R3#1):
     info "Provider is generic (accepts tokens from any GitHub repo)."
     info "Authorization is enforced by the service account binding (principalSet)."
     info "Without that binding, GitHub tokens CANNOT impersonate the SA."

   Note on attribute.ref: attribute.ref is mapped from assertion.ref in the
   GitHub OIDC token. This claim is best-effort — its format and availability
   depend on workflow trigger context. It is mapped now so that future branch
   restrictions (e.g., main-only) can be added to the principalSet WITHOUT
   recreating the provider. For 10.1, repo-only restriction is the enforced
   security control.

   Note on audiences (R3#3): google-github-actions/auth@v2 uses the default
   audience (the WIF provider resource URI) unless explicitly overridden.
   This works with the default provider configuration. If a client's org
   requires explicit allowed audiences, see Troubleshooting section.

7. Create Service Account (check-before-create, R4#3: create-only, never mutate)
   SA_EMAIL="biznez-github-provisioner@${PROJECT_ID}.iam.gserviceaccount.com"
   if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
     gcloud iam service-accounts create biznez-github-provisioner \
       --project="$PROJECT_ID" \
       --display-name="Biznez GitHub Provisioner"
   else
     info "Service account $SA_EMAIL already exists — skipping (not mutated)."
   fi

8. Bind SA roles (full role names, with warning banner)
   Print warning (R3#6):
     warn "Granting broad admin roles in project $PROJECT_ID (eval-only project assumed)."

   ROLES=(
     "roles/container.admin"
     "roles/compute.admin"
     "roles/artifactregistry.admin"
     "roles/iam.serviceAccountAdmin"
     "roles/storage.objectAdmin"
     "roles/serviceusage.serviceUsageAdmin"
   )
   for role in "${ROLES[@]}"; do
     gcloud projects add-iam-policy-binding "$PROJECT_ID" \
       --member="serviceAccount:${SA_EMAIL}" \
       --role="$role" \
       --condition=None --quiet
   done

   Note: These roles are broad and appropriate for an eval-only project.
   For production/shared org projects, use least-privilege custom roles.
   Phase 10.4 will split into separate provisioner vs cleanup SAs.

9. Bind WIF → SA (repo restriction HERE, full resource path)
   Build full resource paths from PROJECT_NUMBER (not display names):

   POOL_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/biznez-github-pool"
   PROVIDER_RESOURCE="${POOL_RESOURCE}/providers/github-actions"
   PRINCIPAL_SET="principalSet://iam.googleapis.com/${POOL_RESOURCE}/attribute.repository/${GITHUB_REPO}"

   gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
     --project="$PROJECT_ID" \
     --role="roles/iam.workloadIdentityUser" \
     --member="$PRINCIPAL_SET"

   Print the exact member string (R3#7):
     ok "Bound workloadIdentityUser to SA with member:"
     info "  $PRINCIPAL_SET"

   This is the authorization boundary — only tokens from GITHUB_REPO
   can assume this SA. Provider is generic (no repo lock).

   Note: Only roles/iam.workloadIdentityUser is bound. Do NOT add
   roles/iam.serviceAccountTokenCreator — google-github-actions/auth@v2
   does not require it when configured correctly. If auth failures occur
   later, TokenCreator is documented as a troubleshooting step (not default).

10. Set GitHub variable + secrets (R3#8: auto-fallback)
    If gh is unavailable/not authed/lacks admin (detected in preflight), or
    --no-github was explicitly set: skip gh commands and print them instead.

    gh variable set GCP_PROJECT_ID --body "$PROJECT_ID" --repo "$GITHUB_REPO"
    gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER --body "$PROVIDER_RESOURCE" --repo "$GITHUB_REPO"
    gh secret set GCP_SERVICE_ACCOUNT --body "$SA_EMAIL" --repo "$GITHUB_REPO"

    Fallback output:
      info "GitHub CLI not available or lacks admin access. Run these commands manually:"
      echo ""
      echo "  gh variable set GCP_PROJECT_ID --body '$PROJECT_ID' --repo '$GITHUB_REPO'"
      echo "  gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER --body '$PROVIDER_RESOURCE' --repo '$GITHUB_REPO'"
      echo "  gh secret set GCP_SERVICE_ACCOUNT --body '$SA_EMAIL' --repo '$GITHUB_REPO'"
      echo ""

11. Write bootstrap env file (R3#9: secured)
    Write infra/.bootstrap.env for local reference and debugging:

    chmod 600 infra/.bootstrap.env
    Contents:
      # Generated by bootstrap-gcp.sh -- DO NOT COMMIT
      # This file contains project metadata only (no secrets).
      GCP_PROJECT_ID=<project-id>
      GCP_PROJECT_NUMBER=<project-number>
      TF_STATE_BUCKET=biznez-terraform-state-<project-id>
      BUCKET_LOCATION=EU
      WIF_PROVIDER=projects/<number>/locations/global/.../providers/github-actions
      SERVICE_ACCOUNT=biznez-github-provisioner@<project>.iam.gserviceaccount.com
      GITHUB_REPO=<owner/repo>

    Also ensure infra/.bootstrap.env is in .gitignore.
    File contains no secrets (SA email and provider resource name are not secrets).

12. Verify (R3#10: deterministic, no raw grep)
    - Verify provider exists:
        gcloud iam workload-identity-pools providers describe github-actions \
          --workload-identity-pool=biznez-github-pool \
          --location=global --project="$PROJECT_ID" \
          --format="value(name)" → must return non-empty

    - Verify SA IAM policy includes the exact principalSet member (R4#2: exact match):
        EXPECTED_PRINCIPAL_SET="principalSet://iam.googleapis.com/${POOL_RESOURCE}/attribute.repository/${GITHUB_REPO}"

        ACTUAL_MEMBERS=$(gcloud iam service-accounts get-iam-policy "$SA_EMAIL" \
          --project="$PROJECT_ID" \
          --format="json" \
          --flatten="bindings[].members" \
          --filter="bindings.role:roles/iam.workloadIdentityUser" \
          --format="value(bindings.members)")

        # Exact string match — not substring. Prevents false positives from
        # repos like "owner/repo-fork" matching a filter for "owner/repo".
        FOUND=false
        while IFS= read -r member; do
          if [ "$member" = "$EXPECTED_PRINCIPAL_SET" ]; then
            FOUND=true; break
          fi
        done <<< "$ACTUAL_MEMBERS"

        if [ "$FOUND" = true ]; then
          ok "principalSet binding verified (exact match)"
        else
          error "Expected principalSet not found in SA IAM policy."
          error "  Expected: $EXPECTED_PRINCIPAL_SET"
          error "  Actual members: $ACTUAL_MEMBERS"
        fi

    - Verify APIs enabled (deterministic):
        ENABLED=$(gcloud services list --enabled --project="$PROJECT_ID" --format="value(config.name)")
        For each required API: check presence in $ENABLED list.

    - Verify bucket accessible:
        gsutil ls -b "gs://${BUCKET}" → must succeed

    - Verify GitHub settings (unless --no-github / fallback mode):
        gh variable list --repo "$GITHUB_REPO" | check GCP_PROJECT_ID present
        gh secret list --repo "$GITHUB_REPO" | check both secrets present

13. Print summary (exact values for troubleshooting)
    Table with:
      PROJECT_ID:       <project-id>
      PROJECT_NUMBER:   <project-number>
      BUCKET:           biznez-terraform-state-<project-id>
      BUCKET_LOCATION:  EU
      WIF POOL:         projects/<number>/locations/global/workloadIdentityPools/biznez-github-pool
      WIF PROVIDER:     projects/<number>/locations/global/.../providers/github-actions
      PRINCIPAL_SET:    principalSet://iam.googleapis.com/projects/<number>/locations/global/workloadIdentityPools/biznez-github-pool/attribute.repository/<owner/repo>
      SERVICE ACCOUNT:  biznez-github-provisioner@<project>.iam.gserviceaccount.com
      GITHUB REPO:      <owner/repo>
      BOOTSTRAP ENV:    infra/.bootstrap.env

    "You can now run the 'Provision Eval Environment' workflow from GitHub Actions."
```

### WIF Architecture

```
┌─────────────────────────────────┐
│ WIF Provider: github-actions    │
│   issuer + attribute mapping    │
│   NO repo restriction here      │  ← Generic, reusable
│   (maps sub, repository, actor, │
│    ref from GitHub OIDC token)  │
│                                 │
│   "Provider is generic.         │
│    Authorization is enforced    │
│    by the SA binding. Without   │
│    that binding, GitHub tokens  │
│    CANNOT impersonate the SA."  │
└──────────────┬──────────────────┘
               │ token exchange
               ▼
┌─────────────────────────────────┐
│ SA: biznez-github-provisioner   │
│   IAM policy binding:           │
│     principalSet restricted to  │
│     attribute.repository =      │  ← Authorization boundary
│     <owner/repo>                │
│                                 │
│   Only workloadIdentityUser     │
│   (NOT serviceAccountToken-     │
│    Creator — not needed for     │
│    google-github-actions/auth)  │
│                                 │
│   Future: can add attribute.ref │
│   restriction for branch lock   │
└─────────────────────────────────┘
```

Single enforcement point at the SA binding. Provider stays generic. Easier to debug, follows Google's recommended pattern.

### Idempotency & Mutation Strategy (R4#3)

**Create-only (never mutate existing):**
- WIF pool: `gcloud ... describe` → exists? log + skip : create
- WIF OIDC provider: `gcloud ... describe` → exists? log + skip : create
- Service account: `gcloud ... describe` → exists? log + skip : create

**Idempotent (safe to re-apply):**
- `gcloud services enable` → already idempotent
- `gcloud projects add-iam-policy-binding` → additive (no duplicate bindings)
- `gh variable set` / `gh secret set` → overwrites with explicit `--repo` (safe for re-runs)

**Conditional mutation (with loud warning):**
- GCS bucket: `gsutil ls -b` → new? create + harden. Exists? warn + apply hardening settings.
  The three hardening mutations (uniform access, public access prevention, versioning)
  are additive safety settings that don't affect existing data.

Safe to re-run at any point. If it fails midway, re-running picks up where it left off.

### Patterns Reused

| Pattern | Source |
|---------|--------|
| `set -euo pipefail`, `info/ok/warn/error` helpers | `infra/scripts/provision.sh`, `cli/biznez-cli` |
| Exit codes (0=ok, 2=prereq, 10=abort) | `cli/biznez-cli` |
| Confirmation prompt with `--yes` override | `cli/biznez-cli` uninstall command |
| `NO_COLOR` / TTY detection | All existing scripts |
| Early-hint preflight probes | `infra/scripts/preflight-quotas.sh` |

### Backend.tf Update

`backend.tf` contains NO hardcoded bucket or prefix. Both are passed at `terraform init` time via `-backend-config`:

```hcl
terraform {
  backend "gcs" {
    # Both bucket and prefix set via -backend-config at init time.
    # See bootstrap-gcp.sh for bucket naming convention.
  }
}
```

Both workflows (`provision-eval.yml`, `teardown-eval.yml`) pass both values. `GCP_PROJECT_ID` is resolved from the workflow-level `env:` block (which falls back to `vars.GCP_PROJECT_ID`):

```yaml
# In provision-eval.yml and teardown-eval.yml:
env:
  GCP_PROJECT_ID: ${{ inputs.gcp_project_id || vars.GCP_PROJECT_ID }}

# In terraform init steps:
terraform init \
  -backend-config="bucket=biznez-terraform-state-${GCP_PROJECT_ID}" \
  -backend-config="prefix=eval/${ENV_ID}"
```

`vars.GCP_PROJECT_ID` is set by `bootstrap-gcp.sh` (step 10) in the same repo that runs the workflow. This ensures the bucket name is consistent between bootstrap and workflow execution.

## Verification

1. Run `shellcheck -s bash infra/scripts/bootstrap-gcp.sh` — passes clean
2. Run with `--dry-run` — prints all gcloud/gh commands without executing (write probe skipped)
3. Run `status` subcommand — prints prerequisite table without modifying anything
4. Run against live project — all resources created, GitHub secrets set
5. Run again — idempotent, all steps report "already exists"
6. Verify smoke test passes (deterministic: format-filtered gcloud output, not raw grep)
7. Run `provision-eval.yml` workflow — succeeds end-to-end (WIF auth works)
8. Verify `gh variable list --repo <repo>` shows `GCP_PROJECT_ID` and `gh secret list --repo <repo>` shows both secrets
9. Verify `infra/.bootstrap.env` written with correct values and mode 600
10. Run without gh CLI available — auto-falls back to printing gh commands

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `provision-eval.yml` fails at auth step | WIF provider or SA binding misconfigured | Verify `GCP_WORKLOAD_IDENTITY_PROVIDER` secret matches `PROVIDER_RESOURCE` from bootstrap output. Run `bootstrap-gcp.sh status` to check. |
| `Error: unable to impersonate` | Missing `serviceAccountTokenCreator` role | Add `roles/iam.serviceAccountTokenCreator` to SA: `gcloud iam service-accounts add-iam-policy-binding ...` (not default — only add if auth fails) |
| Auth fails with audience error | Org requires explicit WIF allowed audiences | Update provider: `gcloud iam workload-identity-pools providers update-oidc github-actions --allowed-audiences="https://iam.googleapis.com/projects/<number>/locations/global/workloadIdentityPools/biznez-github-pool/providers/github-actions" ...` |
| Bucket creation fails with 409 | Global name collision | The bucket name `biznez-terraform-state-<project-id>` should be unique, but if it's taken, delete the conflicting bucket or use a different project |
| `gh secret set` permission denied | Insufficient GitHub repo permissions | Script auto-falls back to printing gh commands. Have a repo admin run them. |
| Terraform init fails with bucket not found | `GCP_PROJECT_ID` mismatch between bootstrap and workflow | Ensure `vars.GCP_PROJECT_ID` in GitHub matches the project used in bootstrap. Run `bootstrap-gcp.sh status` to verify. |

## Feedback Changelog

| # | Round | Issue | Resolution |
|---|-------|-------|------------|
| 1 | R1 | WIF provider attribute-condition is in the wrong place | Removed attribute-condition from provider. Repo scoping enforced only at SA binding (principalSet). Provider is generic: issuer + mapping only. |
| 2 | R1 | Role binding loop uses short names | Changed to full role names in array: `roles/container.admin`, `roles/compute.admin`, etc. |
| 3 | R1 | WIF pool ID vs full resource name confusion | Script explicitly fetches PROJECT_NUMBER, builds full paths: `projects/<number>/locations/global/workloadIdentityPools/<name>`. All member strings and secret values use full resource paths. |
| 4 | R1 | gh commands must target correct repo | All `gh variable set` and `gh secret set` use explicit `--repo "$GITHUB_REPO"`. |
| 5 | R1 | Bucket location: europe-west2 may not work for all clients | Default changed to `EU` multi-region. Flag renamed to `--bucket-location` (`--region` kept as alias). |
| 6 | R1 | Owner/editor role check is misleading with custom roles | Replaced with early-hint capability probes. Probes are not proof of create capability — the real create steps are the proof, with actionable error messages on failure. |
| 7 | R1 | serviceusage API needed | Already included. Confirmed. |
| A | R1 | Add branch/ref restriction for future use | Mapped `attribute.ref=assertion.ref` in provider attribute-mapping. 10.1 enforces repo-only. Branch restriction can be added to principalSet later without recreating the provider. |
| B | R1 | Don't put repo restriction in two places | Single enforcement point: SA binding only. Provider is generic. |
| C | R1 | Print exact values for troubleshooting | Summary prints: PROJECT_ID, PROJECT_NUMBER, bucket name, pool resource, provider resource, principalSet, SA email, GitHub repo. |
| D | R1 | Add verify/smoke test | Added verification step: checks provider exists, SA policy has principalSet, APIs enabled, bucket accessible, GitHub settings present. |
| E | R1 | Backend config: no hardcoded bucket | `backend.tf` is empty placeholder. Both bucket and prefix passed via `-backend-config` in workflows. |
| F | R1 | Naming: one repo per project assumption | Documented in Assumptions section. Provider names are per-project; multi-repo support would need provider name changes. |
| 8 | R2 | Capability probes can't prove create permission | Reframed probes as "early hints" not "capability verified". Added one write probe (enable serviceusage API). All create steps have explicit, actionable error messages on failure. |
| 9 | R2 | --region flag misleading for bucket location | Renamed to `--bucket-location` (default: `EU`). `--region` kept as alias for convenience. |
| 10 | R2 | attribute.ref claim availability depends on workflow context | Added note: attribute.ref is best-effort, format depends on trigger context. Repo-only is the enforced control for 10.1. |
| 11 | R2 | Don't add serviceAccountTokenCreator unless needed | Only `workloadIdentityUser` bound. TokenCreator documented as troubleshooting step, not default. Follows least privilege. |
| 12 | R2 | SA roles are broad for shared projects | Added assumption: eval-only project. Documented future TODO: split SAs in Phase 10.4. |
| 13 | R2-A | Clients may not allow gh CLI auth | Added `--no-github` flag: creates GCP resources, prints exact gh commands for manual execution. |
| 14 | R2-B | No local record of bootstrap output | Script writes `infra/.bootstrap.env` with all values. Added to `.gitignore`. |
| 15 | R2-D | Repo autodetect must handle SSH and HTTPS | Normalise both formats: `git@github.com:owner/repo.git` and `https://github.com/owner/repo.git` → `owner/repo`. |
| 16 | R3 | Provider wording could confuse security reviewers | Added explicit output: "Provider is generic. Authorization is enforced by the SA binding (principalSet). Without that binding, GitHub tokens CANNOT impersonate the SA." |
| 17 | R3 | Bucket check should use `gsutil ls -b`; harden bucket config | Changed to `gsutil ls -b`. Added: uniform bucket-level access (`-b on`), public access prevention (`pap set enforced`), versioning. |
| 18 | R3 | WIF provider audiences may be required by some orgs | Added troubleshooting entry for audience errors. Default config works with `google-github-actions/auth@v2` without explicit audiences. |
| 19 | R3 | Repo autodetect must fail if remote isn't GitHub | Fail fast if remote host is not `github.com`. Require `--repo` explicitly in that case. |
| 20 | R3 | serviceusage enable probe is side-effecting | Labeled as "Write probe" in output. Skipped in `--dry-run` mode. |
| 21 | R3 | IAM role warning should be unmissable | Added warning banner at confirmation AND before role binding: "Use only in DEDICATED EVAL PROJECT." |
| 22 | R3 | WIF → SA verification should print exact member string | Script prints the full `principalSet://...` member string after binding and in final summary. |
| 23 | R3 | gh failures should auto-fallback, not hard fail | If gh is missing/not authed/lacks admin, auto-switch to `--no-github` mode and print commands. Only hard-fail path is `--no-github` explicitly set = expected. |
| 24 | R3 | `.bootstrap.env` security | Written with `chmod 600`. Header says "DO NOT COMMIT". Contains no secrets (SA email and provider name are not secrets). In `.gitignore`. |
| 25 | R3 | Verification should be deterministic, not raw grep | SA policy check uses `gcloud --format=json --flatten --filter` instead of piping to grep. API check compares enabled list against required set. |
| 26 | R3-NB | Add `status` subcommand | Read-only prerequisite check: prints exists/missing table, exit 0 if all present, exit 1 if any missing. |
| 27 | R3-NB | Add `--quiet` flag | Reduces output for CI-style runs (only errors and final summary). |
| 28 | R3-align | Workflow alignment with bootstrap | Documented: workflows use `env: GCP_PROJECT_ID: ${{ inputs.gcp_project_id || vars.GCP_PROJECT_ID }}` and pass `bucket=biznez-terraform-state-${GCP_PROJECT_ID}` to terraform init. `vars.GCP_PROJECT_ID` set by bootstrap in the same repo. |
| 29 | R4 | `status` subcommand should show "SKIPPED" for GitHub checks when gh unavailable | GitHub checks print as `SKIPPED (no gh access)`. Exit code based on GCP resources only when gh unavailable. |
| 30 | R4 | principalSet verification must match exact string, not substring | Changed from `--filter` substring match to exact string comparison in a loop. Prevents false positives from similarly-named repos (e.g., `owner/repo-fork` matching `owner/repo`). |
| 31 | R4 | Pool/provider/SA should not be mutated if they already exist | Added "create-only, never mutate" pattern for WIF pool, WIF provider, and service account. Each logs "already exists — skipping (not mutated)" on re-run. Safety note added to provider section. |
| 32 | R4 | Bucket hardening should warn loudly if bucket already exists | Bucket creation split into new vs existing paths. Existing bucket gets loud `warn` messages before applying hardening settings (uniform access, PAP, versioning). |
| 33 | R4 | Write probe should be optional via --no-write-probe | Added `--no-write-probe` flag. Write probe skipped when `--dry-run` OR `--no-write-probe`. Useful for restricted environments where even idempotent writes need explicit approval. |
| 34 | R4 | Teardown workflow env fallback logic | Confirmed correct: `teardown-eval.yml` already has `gcp_project_id` input (line 19-22) with `vars.GCP_PROJECT_ID` fallback (line 35). No changes needed. |
