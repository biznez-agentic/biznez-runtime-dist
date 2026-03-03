#!/usr/bin/env bash
# =============================================================================
# bootstrap-gcp.sh -- One-time GCP + GitHub setup for Biznez eval provisioning
# =============================================================================
# Creates all GCP prerequisites (APIs, GCS bucket, WIF pool/provider, service
# account, IAM bindings) and sets GitHub secrets/variables needed by the
# provision-eval.yml workflow.
#
# Usage:
#   ./bootstrap-gcp.sh --project <gcp-project-id> [--bucket-location <location>] [--repo <owner/repo>]
#   ./bootstrap-gcp.sh status --project <gcp-project-id> [--repo <owner/repo>]
#
# See --help for full usage.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers (match biznez-cli / provision.sh pattern)
# ---------------------------------------------------------------------------
NO_COLOR="${NO_COLOR:-false}"
_color_enabled() { [ "$NO_COLOR" = "false" ] && [ -t 1 ]; }

info()  { [ "$QUIET" = "true" ] && return 0; if _color_enabled; then printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; else printf '[INFO]  %s\n' "$*"; fi; }
ok()    { if _color_enabled; then printf '\033[0;32m[OK]\033[0m    %s\n' "$*"; else printf '[OK]    %s\n' "$*"; fi; }
warn()  { if _color_enabled; then printf '\033[0;33m[WARN]\033[0m  %s\n' "$*" >&2; else printf '[WARN]  %s\n' "$*" >&2; fi; }
error() { if _color_enabled; then printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; else printf '[ERROR] %s\n' "$*" >&2; fi; }

# ---------------------------------------------------------------------------
# Exit codes (match biznez-cli)
# ---------------------------------------------------------------------------
readonly EXIT_OK=0
readonly EXIT_PREREQ=2
readonly EXIT_ABORT=10

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PROJECT_ID=""
BUCKET_LOCATION="EU"
GITHUB_REPO=""
NO_GITHUB="false"
NO_WRITE_PROBE="false"
DRY_RUN="false"
QUIET="false"
YES="false"
COMMAND="bootstrap"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<'USAGE'
Usage:
  bootstrap-gcp.sh --project <gcp-project-id> [options]
  bootstrap-gcp.sh status --project <gcp-project-id> [options]

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
  --no-write-probe   Skip the side-effecting write probe in preflight
  --dry-run          Show what will be created without executing
  --quiet            Reduce output for CI-style runs (only errors and final summary)
  --yes              Skip confirmation prompt
  --help             Show this help message
USAGE
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
parse_args() {
    # Check for status subcommand as first argument
    if [ "${1:-}" = "status" ]; then
        COMMAND="status"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project)         PROJECT_ID="$2"; shift 2 ;;
            --bucket-location) BUCKET_LOCATION="$2"; shift 2 ;;
            --region)          BUCKET_LOCATION="$2"; shift 2 ;;
            --repo)            GITHUB_REPO="$2"; shift 2 ;;
            --no-github)       NO_GITHUB="true"; shift ;;
            --no-write-probe)  NO_WRITE_PROBE="true"; shift ;;
            --dry-run)         DRY_RUN="true"; shift ;;
            --quiet)           QUIET="true"; shift ;;
            --yes)             YES="true"; shift ;;
            --help|-h)         usage; exit 0 ;;
            *)                 error "Unknown argument: $1"; usage; exit "$EXIT_PREREQ" ;;
        esac
    done

    if [ -z "$PROJECT_ID" ]; then
        error "Missing required flag: --project"
        usage
        exit "$EXIT_PREREQ"
    fi
}

# ---------------------------------------------------------------------------
# Detect GitHub repo from git remote
# ---------------------------------------------------------------------------
detect_github_repo() {
    if [ -n "$GITHUB_REPO" ]; then
        info "Using provided GitHub repo: $GITHUB_REPO"
        return 0
    fi

    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null) || {
        error "Cannot detect GitHub repo: no git remote 'origin' found."
        error "Use --repo owner/name to specify the GitHub repository explicitly."
        exit "$EXIT_PREREQ"
    }

    # Normalise SSH and HTTPS formats
    case "$remote_url" in
        git@github.com:*)
            # git@github.com:owner/repo.git → owner/repo
            GITHUB_REPO="${remote_url#git@github.com:}"
            GITHUB_REPO="${GITHUB_REPO%.git}"
            ;;
        https://github.com/*)
            # https://github.com/owner/repo.git → owner/repo
            GITHUB_REPO="${remote_url#https://github.com/}"
            GITHUB_REPO="${GITHUB_REPO%.git}"
            ;;
        *)
            error "Remote is not a GitHub repo: $remote_url"
            error "Use --repo owner/name to specify the GitHub repository explicitly."
            exit "$EXIT_PREREQ"
            ;;
    esac

    # Validate we got owner/repo format
    if [[ ! "$GITHUB_REPO" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
        error "Could not parse owner/repo from remote: $remote_url"
        error "Use --repo owner/name to specify the GitHub repository explicitly."
        exit "$EXIT_PREREQ"
    fi

    info "Auto-detected GitHub repo: $GITHUB_REPO"
}

# ---------------------------------------------------------------------------
# Detect GitHub CLI availability and auth
# ---------------------------------------------------------------------------
GH_AVAILABLE="false"

detect_gh_cli() {
    if [ "$NO_GITHUB" = "true" ]; then
        info "GitHub CLI skipped (--no-github)"
        return 0
    fi

    if ! command -v gh &>/dev/null; then
        warn "GitHub CLI (gh) not found. Switching to --no-github mode."
        NO_GITHUB="true"
        return 0
    fi

    if ! gh auth status &>/dev/null; then
        warn "GitHub CLI not authenticated. Switching to --no-github mode."
        NO_GITHUB="true"
        return 0
    fi

    # Check repo access (best effort)
    if [ -n "$GITHUB_REPO" ]; then
        if ! gh repo view "$GITHUB_REPO" &>/dev/null; then
            warn "GitHub CLI cannot access repo $GITHUB_REPO. Switching to --no-github mode."
            NO_GITHUB="true"
            return 0
        fi
    fi

    GH_AVAILABLE="true"
    ok "GitHub CLI authenticated and accessible"
}

# ---------------------------------------------------------------------------
# Resource names (deterministic)
# ---------------------------------------------------------------------------
BUCKET=""
WIF_POOL="biznez-github-pool"
WIF_PROVIDER="github-actions"
SA_NAME="biznez-github-provisioner"
SA_EMAIL=""
PROJECT_NUMBER=""
POOL_RESOURCE=""
PROVIDER_RESOURCE=""
PRINCIPAL_SET=""
GITHUB_REPO_OWNER=""

REQUIRED_APIS=(
    "container.googleapis.com"
    "compute.googleapis.com"
    "artifactregistry.googleapis.com"
    "iam.googleapis.com"
    "iamcredentials.googleapis.com"
    "serviceusage.googleapis.com"
)

SA_ROLES=(
    "roles/container.admin"
    "roles/compute.admin"
    "roles/artifactregistry.admin"
    "roles/iam.serviceAccountAdmin"
    "roles/storage.objectAdmin"
    "roles/serviceusage.serviceUsageAdmin"
)

compute_resource_names() {
    BUCKET="biznez-terraform-state-${PROJECT_ID}"
    SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

    # Fetch project number
    PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" \
        --format="value(projectNumber)" 2>/dev/null) || {
        error "Cannot fetch project number for $PROJECT_ID."
        error "Verify the project exists and you have access."
        exit "$EXIT_PREREQ"
    }

    POOL_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}"
    PROVIDER_RESOURCE="${POOL_RESOURCE}/providers/${WIF_PROVIDER}"
    PRINCIPAL_SET="principalSet://iam.googleapis.com/${POOL_RESOURCE}/attribute.repository/${GITHUB_REPO}"
    GITHUB_REPO_OWNER="${GITHUB_REPO%%/*}"
}

# =============================================================================
# STATUS SUBCOMMAND
# =============================================================================
run_status() {
    local gcp_failures=0
    local gh_failures=0
    local gh_checked="true"

    printf '\n'
    printf '%-35s %s\n' "Resource" "Status"
    printf '%-35s %s\n' "───────────────────────────────────" "──────────────────────────────────────"

    # --- APIs ---
    local enabled_apis
    enabled_apis=$(gcloud services list --enabled --project="$PROJECT_ID" \
        --format="value(config.name)" 2>/dev/null) || enabled_apis=""
    local api_count=0
    local api_missing=""
    for api in "${REQUIRED_APIS[@]}"; do
        if echo "$enabled_apis" | grep -q "^${api}$"; then
            api_count=$((api_count + 1))
        else
            api_missing="${api_missing:+${api_missing}, }${api%.googleapis.com}"
        fi
    done
    if [ "$api_count" -eq "${#REQUIRED_APIS[@]}" ]; then
        printf '%-35s %s\n' "APIs (${#REQUIRED_APIS[@]} required)" "${api_count}/${#REQUIRED_APIS[@]} enabled"
    else
        printf '%-35s %s\n' "APIs (${#REQUIRED_APIS[@]} required)" "${api_count}/${#REQUIRED_APIS[@]} enabled (missing: ${api_missing})"
        gcp_failures=$((gcp_failures + 1))
    fi

    # --- GCS bucket ---
    if gcloud storage buckets describe "gs://${BUCKET}" --project="$PROJECT_ID" &>/dev/null; then
        printf '%-35s %s\n' "GCS bucket" "EXISTS: ${BUCKET}"
    else
        printf '%-35s %s\n' "GCS bucket" "MISSING"
        gcp_failures=$((gcp_failures + 1))
    fi

    # --- WIF pool ---
    if gcloud iam workload-identity-pools describe "$WIF_POOL" \
        --location=global --project="$PROJECT_ID" &>/dev/null; then
        printf '%-35s %s\n' "WIF pool" "EXISTS: ${WIF_POOL}"
    else
        printf '%-35s %s\n' "WIF pool" "MISSING"
        gcp_failures=$((gcp_failures + 1))
    fi

    # --- WIF OIDC provider ---
    if gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
        --workload-identity-pool="$WIF_POOL" \
        --location=global --project="$PROJECT_ID" &>/dev/null; then
        printf '%-35s %s\n' "WIF OIDC provider" "EXISTS: ${WIF_PROVIDER}"
    else
        printf '%-35s %s\n' "WIF OIDC provider" "MISSING"
        gcp_failures=$((gcp_failures + 1))
    fi

    # --- Service account ---
    if gcloud iam service-accounts describe "$SA_EMAIL" \
        --project="$PROJECT_ID" &>/dev/null; then
        printf '%-35s %s\n' "Service account" "EXISTS: ${SA_EMAIL}"
    else
        printf '%-35s %s\n' "Service account" "MISSING"
        gcp_failures=$((gcp_failures + 1))
    fi

    # --- SA role bindings ---
    local bound_count=0
    local policy
    policy=$(gcloud projects get-iam-policy "$PROJECT_ID" \
        --format="json" 2>/dev/null) || policy=""
    if [ -n "$policy" ]; then
        for role in "${SA_ROLES[@]}"; do
            if echo "$policy" | python3 -c "
import sys, json
policy = json.load(sys.stdin)
member = 'serviceAccount:${SA_EMAIL}'
role = '${role}'
for b in policy.get('bindings', []):
    if b.get('role') == role and member in b.get('members', []):
        sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
                bound_count=$((bound_count + 1))
            fi
        done
    fi
    if [ "$bound_count" -eq "${#SA_ROLES[@]}" ]; then
        printf '%-35s %s\n' "SA role bindings (${#SA_ROLES[@]} required)" "${bound_count}/${#SA_ROLES[@]} bound"
    else
        printf '%-35s %s\n' "SA role bindings (${#SA_ROLES[@]} required)" "${bound_count}/${#SA_ROLES[@]} bound"
        gcp_failures=$((gcp_failures + 1))
    fi

    # --- WIF → SA binding ---
    local sa_policy
    sa_policy=$(gcloud iam service-accounts get-iam-policy "$SA_EMAIL" \
        --project="$PROJECT_ID" --format="json" 2>/dev/null) || sa_policy=""
    local wif_bound="false"
    if [ -n "$sa_policy" ]; then
        local actual_members
        actual_members=$(echo "$sa_policy" | python3 -c "
import sys, json
policy = json.load(sys.stdin)
for b in policy.get('bindings', []):
    if b.get('role') == 'roles/iam.workloadIdentityUser':
        for m in b.get('members', []):
            print(m)
" 2>/dev/null) || actual_members=""
        while IFS= read -r member; do
            if [ "$member" = "$PRINCIPAL_SET" ]; then
                wif_bound="true"
                break
            fi
        done <<< "$actual_members"
    fi
    if [ "$wif_bound" = "true" ]; then
        printf '%-35s %s\n' "WIF → SA binding" "BOUND"
    else
        printf '%-35s %s\n' "WIF → SA binding" "MISSING"
        gcp_failures=$((gcp_failures + 1))
    fi

    # --- GitHub checks ---
    if [ "$NO_GITHUB" = "true" ] || [ "$GH_AVAILABLE" = "false" ]; then
        gh_checked="false"
        printf '%-35s %s\n' "GitHub var: GCP_PROJECT_ID" "SKIPPED (no gh access)"
        printf '%-35s %s\n' "GitHub secret: WIF_PROVIDER" "SKIPPED (no gh access)"
        printf '%-35s %s\n' "GitHub secret: SERVICE_ACCOUNT" "SKIPPED (no gh access)"
    else
        # Check GitHub variable
        if gh variable list --repo "$GITHUB_REPO" 2>/dev/null | grep -q "^GCP_PROJECT_ID"; then
            printf '%-35s %s\n' "GitHub var: GCP_PROJECT_ID" "SET"
        else
            printf '%-35s %s\n' "GitHub var: GCP_PROJECT_ID" "MISSING"
            gh_failures=$((gh_failures + 1))
        fi

        # Check GitHub secrets
        local secret_list
        secret_list=$(gh secret list --repo "$GITHUB_REPO" 2>/dev/null) || secret_list=""
        if echo "$secret_list" | grep -q "^GCP_WORKLOAD_IDENTITY_PROVIDER"; then
            printf '%-35s %s\n' "GitHub secret: WIF_PROVIDER" "SET"
        else
            printf '%-35s %s\n' "GitHub secret: WIF_PROVIDER" "MISSING"
            gh_failures=$((gh_failures + 1))
        fi
        if echo "$secret_list" | grep -q "^GCP_SERVICE_ACCOUNT"; then
            printf '%-35s %s\n' "GitHub secret: SERVICE_ACCOUNT" "SET"
        else
            printf '%-35s %s\n' "GitHub secret: SERVICE_ACCOUNT" "MISSING"
            gh_failures=$((gh_failures + 1))
        fi
    fi

    printf '\n'

    # Exit code: based on GCP only when gh unavailable
    local total_failures=$gcp_failures
    if [ "$gh_checked" = "true" ]; then
        total_failures=$((gcp_failures + gh_failures))
    fi

    if [ "$total_failures" -eq 0 ]; then
        if [ "$gh_checked" = "false" ]; then
            ok "All GCP prerequisites present (GitHub status unknown — verify manually)"
        else
            ok "All prerequisites present"
        fi
        return 0
    else
        error "${total_failures} prerequisite(s) missing"
        return 1
    fi
}

# =============================================================================
# PREFLIGHT (for bootstrap command)
# =============================================================================
run_preflight() {
    info "Running preflight checks..."

    # --- gcloud ---
    if ! command -v gcloud &>/dev/null; then
        error "gcloud CLI not found in PATH"
        exit "$EXIT_PREREQ"
    fi

    if ! gcloud auth print-access-token &>/dev/null; then
        error "gcloud is not authenticated. Run: gcloud auth login"
        exit "$EXIT_PREREQ"
    fi
    ok "gcloud authenticated"

    # --- Project exists and billing active ---
    if ! gcloud projects describe "$PROJECT_ID" &>/dev/null; then
        error "Project $PROJECT_ID does not exist or you lack access"
        exit "$EXIT_PREREQ"
    fi

    local billing_enabled
    billing_enabled=$(gcloud billing projects describe "$PROJECT_ID" \
        --format="value(billingEnabled)" 2>/dev/null) || billing_enabled=""
    if [ "$billing_enabled" != "True" ]; then
        error "Billing is not enabled on project $PROJECT_ID"
        error "Enable billing: https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
        exit "$EXIT_PREREQ"
    fi
    ok "Project $PROJECT_ID exists with billing enabled"

    # --- Early-hint probes ---
    info "Running early-hint capability probes..."

    # Probe a: list APIs
    if gcloud services list --project="$PROJECT_ID" --limit=1 &>/dev/null; then
        ok "Probe: can list APIs"
    else
        error "Probe failed: cannot list APIs."
        error "You need roles/serviceusage.serviceUsageViewer (or broader) to list APIs."
        exit "$EXIT_PREREQ"
    fi

    # Probe b: write probe (idempotent enable of serviceusage API)
    if [ "$DRY_RUN" = "true" ] || [ "$NO_WRITE_PROBE" = "true" ]; then
        if [ "$NO_WRITE_PROBE" = "true" ]; then
            info "Write probe: skipped (--no-write-probe)"
        else
            info "Write probe: skipped (--dry-run)"
        fi
    else
        info "Write probe: attempting to enable serviceusage.googleapis.com (idempotent)"
        if gcloud services enable serviceusage.googleapis.com --project="$PROJECT_ID" &>/dev/null; then
            ok "Probe: can enable APIs"
        else
            error "Probe failed: cannot enable APIs."
            error "You need roles/serviceusage.serviceUsageAdmin to enable APIs."
            exit "$EXIT_PREREQ"
        fi
    fi

    # Probe c: list WIF pools
    if gcloud iam workload-identity-pools list \
        --location=global --project="$PROJECT_ID" --limit=1 &>/dev/null; then
        ok "Probe: can list WIF pools"
    else
        error "Probe failed: cannot list WIF pools."
        error "You need roles/iam.workloadIdentityPoolAdmin (or broader)."
        exit "$EXIT_PREREQ"
    fi

    # Probe d: list service accounts
    if gcloud iam service-accounts list \
        --project="$PROJECT_ID" --limit=1 &>/dev/null; then
        ok "Probe: can list service accounts"
    else
        error "Probe failed: cannot list service accounts."
        error "You need roles/iam.serviceAccountAdmin (or broader)."
        exit "$EXIT_PREREQ"
    fi

    ok "Preflight checks passed"
}

# =============================================================================
# DRY-RUN PRINTER
# =============================================================================
print_dry_run() {
    info "=== DRY RUN — no changes will be made ==="
    printf '\n'

    echo "The following commands would be executed:"
    printf '\n'

    echo "# 1. Enable APIs"
    for api in "${REQUIRED_APIS[@]}"; do
        echo "  gcloud services enable $api --project=$PROJECT_ID"
    done
    printf '\n'

    echo "# 2. Create GCS bucket"
    echo "  gcloud storage buckets create gs://${BUCKET} --project=$PROJECT_ID --location=$BUCKET_LOCATION --uniform-bucket-level-access"
    echo "  gcloud storage buckets update gs://${BUCKET} --public-access-prevention"
    echo "  gcloud storage buckets update gs://${BUCKET} --versioning"
    printf '\n'

    echo "# 3. Create WIF pool"
    echo "  gcloud iam workload-identity-pools create $WIF_POOL --location=global --project=$PROJECT_ID --display-name=\"Biznez GitHub Actions Pool\""
    printf '\n'

    echo "# 4. Create WIF OIDC provider"
    echo "  gcloud iam workload-identity-pools providers create-oidc $WIF_PROVIDER --workload-identity-pool=$WIF_POOL --location=global --project=$PROJECT_ID --issuer-uri=\"https://token.actions.githubusercontent.com\" --attribute-mapping=\"google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.actor=assertion.actor,attribute.ref=assertion.ref\" --attribute-condition=\"assertion.repository_owner == '${GITHUB_REPO_OWNER}'\" --display-name=\"GitHub Actions OIDC\""
    printf '\n'

    echo "# 5. Create service account"
    echo "  gcloud iam service-accounts create $SA_NAME --project=$PROJECT_ID --display-name=\"Biznez GitHub Provisioner\""
    printf '\n'

    echo "# 6. Bind SA roles"
    for role in "${SA_ROLES[@]}"; do
        echo "  gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:${SA_EMAIL} --role=$role --condition=None --quiet"
    done
    printf '\n'

    echo "# 7. Bind WIF → SA"
    echo "  gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL --project=$PROJECT_ID --role=roles/iam.workloadIdentityUser --member=$PRINCIPAL_SET"
    printf '\n'

    echo "# 8. Set GitHub secrets/variables"
    echo "  gh variable set GCP_PROJECT_ID --body '$PROJECT_ID' --repo '$GITHUB_REPO'"
    echo "  gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER --body '$PROVIDER_RESOURCE' --repo '$GITHUB_REPO'"
    echo "  gh secret set GCP_SERVICE_ACCOUNT --body '$SA_EMAIL' --repo '$GITHUB_REPO'"
    printf '\n'

    info "=== END DRY RUN ==="
}

# =============================================================================
# CONFIRMATION
# =============================================================================
confirm_bootstrap() {
    printf '\n'
    info "The following resources will be created in project: $PROJECT_ID"
    printf '\n'

    printf '  %-30s %s\n' "GCS bucket:" "gs://${BUCKET} (location: ${BUCKET_LOCATION})"
    printf '  %-30s %s\n' "APIs:" "${#REQUIRED_APIS[@]} services"
    printf '  %-30s %s\n' "WIF pool:" "$WIF_POOL"
    printf '  %-30s %s\n' "WIF OIDC provider:" "$WIF_PROVIDER"
    printf '  %-30s %s\n' "Service account:" "$SA_EMAIL"
    printf '  %-30s %s\n' "SA role bindings:" "${#SA_ROLES[@]} roles"
    printf '  %-30s %s\n' "WIF → SA binding:" "principalSet for $GITHUB_REPO"
    if [ "$NO_GITHUB" = "false" ]; then
        printf '  %-30s %s\n' "GitHub variable:" "GCP_PROJECT_ID"
        printf '  %-30s %s\n' "GitHub secrets:" "GCP_WORKLOAD_IDENTITY_PROVIDER, GCP_SERVICE_ACCOUNT"
    else
        printf '  %-30s %s\n' "GitHub secrets:" "(skipped — will print commands)"
    fi
    printf '\n'

    warn "WARNING: This grants broad admin roles (container.admin, compute.admin,"
    warn "iam.serviceAccountAdmin, etc.) to the provisioner SA in project $PROJECT_ID."
    warn "Use this only in a DEDICATED EVAL PROJECT, not a production or shared org project."
    printf '\n'

    if [ "$YES" = "true" ]; then
        info "Confirmation skipped (--yes)"
        return 0
    fi

    printf 'Create these resources? [y/N] '
    read -r answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        info "Aborted."
        exit "$EXIT_ABORT"
    fi
}

# =============================================================================
# BOOTSTRAP STEPS
# =============================================================================

# Step 3: Enable APIs
step_enable_apis() {
    info "Enabling APIs..."
    for api in "${REQUIRED_APIS[@]}"; do
        info "  Enabling $api"
        gcloud services enable "$api" --project="$PROJECT_ID" --quiet || {
            error "Failed to enable $api."
            error "You need roles/serviceusage.serviceUsageAdmin on the project."
            exit "$EXIT_PREREQ"
        }
    done
    ok "All ${#REQUIRED_APIS[@]} APIs enabled"
}

# Step 4: Create GCS bucket
step_create_bucket() {
    info "Setting up GCS bucket for Terraform state..."

    if ! gcloud storage buckets describe "gs://${BUCKET}" --project="$PROJECT_ID" &>/dev/null; then
        info "Creating bucket gs://${BUCKET}..."
        gcloud storage buckets create "gs://${BUCKET}" \
            --project="$PROJECT_ID" \
            --location="$BUCKET_LOCATION" \
            --uniform-bucket-level-access || {
            error "Bucket creation failed. You need roles/storage.admin on the project,"
            error "or the bucket name may already be taken globally."
            exit "$EXIT_PREREQ"
        }
        # New bucket — apply hardening unconditionally
        gcloud storage buckets update "gs://${BUCKET}" --public-access-prevention
        gcloud storage buckets update "gs://${BUCKET}" --versioning
        ok "Bucket gs://${BUCKET} created and hardened"
    else
        # Bucket already exists — apply hardening with loud warning
        warn "Bucket gs://${BUCKET} already exists."
        warn "Applying hardening settings (uniform access, public access prevention, versioning)."
        warn "These are additive safety settings and do not affect existing data."
        gcloud storage buckets update "gs://${BUCKET}" --uniform-bucket-level-access
        gcloud storage buckets update "gs://${BUCKET}" --public-access-prevention
        gcloud storage buckets update "gs://${BUCKET}" --versioning
        ok "Bucket gs://${BUCKET} hardening applied"
    fi
}

# Step 5: Create WIF pool
step_create_wif_pool() {
    info "Setting up Workload Identity Federation pool..."

    if ! gcloud iam workload-identity-pools describe "$WIF_POOL" \
        --location=global --project="$PROJECT_ID" &>/dev/null; then
        gcloud iam workload-identity-pools create "$WIF_POOL" \
            --location=global \
            --project="$PROJECT_ID" \
            --display-name="Biznez GitHub Actions Pool" || {
            error "Failed to create WIF pool."
            error "You need roles/iam.workloadIdentityPoolAdmin on the project."
            exit "$EXIT_PREREQ"
        }
        ok "WIF pool $WIF_POOL created"
    else
        info "WIF pool $WIF_POOL already exists — skipping (not mutated)."
    fi
}

# Step 6: Create WIF OIDC provider
step_create_wif_provider() {
    info "Setting up WIF OIDC provider..."

    if ! gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
        --workload-identity-pool="$WIF_POOL" \
        --location=global --project="$PROJECT_ID" &>/dev/null; then
        gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER" \
            --workload-identity-pool="$WIF_POOL" \
            --location=global \
            --project="$PROJECT_ID" \
            --issuer-uri="https://token.actions.githubusercontent.com" \
            --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.actor=assertion.actor,attribute.ref=assertion.ref" \
            --attribute-condition="assertion.repository_owner == '${GITHUB_REPO_OWNER}'" \
            --display-name="GitHub Actions OIDC" || {
            error "Failed to create WIF OIDC provider."
            error "You need roles/iam.workloadIdentityPoolAdmin on the project."
            exit "$EXIT_PREREQ"
        }
        ok "WIF OIDC provider $WIF_PROVIDER created"
    else
        info "WIF provider $WIF_PROVIDER already exists — skipping (not mutated)."
    fi

    info "Provider scoped to org '${GITHUB_REPO_OWNER}' (attribute condition)."
    info "Specific repo authorization is enforced by the SA binding (principalSet)."
    info "Without that binding, GitHub tokens CANNOT impersonate the SA."
}

# Step 7: Create service account
step_create_service_account() {
    info "Setting up service account..."

    if ! gcloud iam service-accounts describe "$SA_EMAIL" \
        --project="$PROJECT_ID" &>/dev/null; then
        gcloud iam service-accounts create "$SA_NAME" \
            --project="$PROJECT_ID" \
            --display-name="Biznez GitHub Provisioner" || {
            error "Failed to create service account."
            error "You need roles/iam.serviceAccountAdmin on the project."
            exit "$EXIT_PREREQ"
        }
        ok "Service account $SA_EMAIL created"
    else
        info "Service account $SA_EMAIL already exists — skipping (not mutated)."
    fi
}

# Step 8: Bind SA roles
step_bind_sa_roles() {
    warn "Granting broad admin roles in project $PROJECT_ID (eval-only project assumed)."
    info "Binding ${#SA_ROLES[@]} roles to $SA_EMAIL..."

    for role in "${SA_ROLES[@]}"; do
        info "  Binding $role"
        gcloud projects add-iam-policy-binding "$PROJECT_ID" \
            --member="serviceAccount:${SA_EMAIL}" \
            --role="$role" \
            --condition=None --quiet &>/dev/null || {
            error "Failed to bind role $role to SA."
            error "You need roles/resourcemanager.projectIamAdmin on the project."
            exit "$EXIT_PREREQ"
        }
    done
    ok "All ${#SA_ROLES[@]} roles bound to $SA_EMAIL"
}

# Step 9: Bind WIF → SA
step_bind_wif_to_sa() {
    info "Binding WIF to service account (authorization boundary)..."

    gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
        --project="$PROJECT_ID" \
        --role="roles/iam.workloadIdentityUser" \
        --member="$PRINCIPAL_SET" &>/dev/null || {
        error "Failed to bind WIF to service account."
        error "You need roles/iam.serviceAccountAdmin on the project."
        exit "$EXIT_PREREQ"
    }

    ok "Bound workloadIdentityUser to SA with member:"
    info "  $PRINCIPAL_SET"
}

# Step 10: Set GitHub secrets/variables
step_set_github_secrets() {
    if [ "$NO_GITHUB" = "true" ]; then
        info "GitHub CLI not available or --no-github set. Run these commands manually:"
        printf '\n'
        echo "  gh variable set GCP_PROJECT_ID --body '$PROJECT_ID' --repo '$GITHUB_REPO'"
        echo "  gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER --body '$PROVIDER_RESOURCE' --repo '$GITHUB_REPO'"
        echo "  gh secret set GCP_SERVICE_ACCOUNT --body '$SA_EMAIL' --repo '$GITHUB_REPO'"
        printf '\n'
        return 0
    fi

    info "Setting GitHub variable and secrets..."

    gh variable set GCP_PROJECT_ID --body "$PROJECT_ID" --repo "$GITHUB_REPO" || {
        error "Failed to set GitHub variable GCP_PROJECT_ID."
        error "You may need admin access to the repo."
        return 1
    }

    gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER --body "$PROVIDER_RESOURCE" --repo "$GITHUB_REPO" || {
        error "Failed to set GitHub secret GCP_WORKLOAD_IDENTITY_PROVIDER."
        return 1
    }

    gh secret set GCP_SERVICE_ACCOUNT --body "$SA_EMAIL" --repo "$GITHUB_REPO" || {
        error "Failed to set GitHub secret GCP_SERVICE_ACCOUNT."
        return 1
    }

    ok "GitHub variable and secrets set"
}

# Step 11: Write .bootstrap.env
step_write_bootstrap_env() {
    local env_file
    env_file="$(cd "$(dirname "$0")/../.." && pwd)/infra/.bootstrap.env"

    info "Writing bootstrap env file: $env_file"

    cat > "$env_file" <<ENVEOF
# Generated by bootstrap-gcp.sh -- DO NOT COMMIT
# This file contains project metadata only (no secrets).
GCP_PROJECT_ID=${PROJECT_ID}
GCP_PROJECT_NUMBER=${PROJECT_NUMBER}
TF_STATE_BUCKET=${BUCKET}
BUCKET_LOCATION=${BUCKET_LOCATION}
WIF_PROVIDER=${PROVIDER_RESOURCE}
SERVICE_ACCOUNT=${SA_EMAIL}
GITHUB_REPO=${GITHUB_REPO}
ENVEOF

    chmod 600 "$env_file"
    ok "Bootstrap env written to $env_file (mode 600)"
}

# Step 12: Verify
step_verify() {
    info "Running verification..."
    local failures=0

    # Verify provider exists
    local provider_name
    provider_name=$(gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
        --workload-identity-pool="$WIF_POOL" \
        --location=global --project="$PROJECT_ID" \
        --format="value(name)" 2>/dev/null) || provider_name=""
    if [ -n "$provider_name" ]; then
        ok "Verify: WIF provider exists"
    else
        error "Verify: WIF provider not found"
        failures=$((failures + 1))
    fi

    # Verify principalSet binding (exact match)
    local sa_policy
    sa_policy=$(gcloud iam service-accounts get-iam-policy "$SA_EMAIL" \
        --project="$PROJECT_ID" --format="json" 2>/dev/null) || sa_policy=""
    local binding_found="false"
    if [ -n "$sa_policy" ]; then
        local actual_members
        actual_members=$(echo "$sa_policy" | python3 -c "
import sys, json
policy = json.load(sys.stdin)
for b in policy.get('bindings', []):
    if b.get('role') == 'roles/iam.workloadIdentityUser':
        for m in b.get('members', []):
            print(m)
" 2>/dev/null) || actual_members=""
        while IFS= read -r member; do
            if [ "$member" = "$PRINCIPAL_SET" ]; then
                binding_found="true"
                break
            fi
        done <<< "$actual_members"
    fi
    if [ "$binding_found" = "true" ]; then
        ok "Verify: principalSet binding verified (exact match)"
    else
        error "Verify: Expected principalSet not found in SA IAM policy."
        error "  Expected: $PRINCIPAL_SET"
        failures=$((failures + 1))
    fi

    # Verify APIs enabled
    local enabled_apis
    enabled_apis=$(gcloud services list --enabled --project="$PROJECT_ID" \
        --format="value(config.name)" 2>/dev/null) || enabled_apis=""
    local api_failures=0
    for api in "${REQUIRED_APIS[@]}"; do
        if ! echo "$enabled_apis" | grep -q "^${api}$"; then
            error "Verify: API not enabled: $api"
            api_failures=$((api_failures + 1))
        fi
    done
    if [ "$api_failures" -eq 0 ]; then
        ok "Verify: All ${#REQUIRED_APIS[@]} APIs enabled"
    else
        failures=$((failures + api_failures))
    fi

    # Verify bucket accessible
    if gcloud storage buckets describe "gs://${BUCKET}" --project="$PROJECT_ID" &>/dev/null; then
        ok "Verify: Bucket gs://${BUCKET} accessible"
    else
        error "Verify: Bucket gs://${BUCKET} not accessible"
        failures=$((failures + 1))
    fi

    # Verify GitHub settings
    if [ "$NO_GITHUB" = "false" ] && [ "$GH_AVAILABLE" = "true" ]; then
        if gh variable list --repo "$GITHUB_REPO" 2>/dev/null | grep -q "^GCP_PROJECT_ID"; then
            ok "Verify: GitHub variable GCP_PROJECT_ID set"
        else
            error "Verify: GitHub variable GCP_PROJECT_ID not set"
            failures=$((failures + 1))
        fi

        local secret_list
        secret_list=$(gh secret list --repo "$GITHUB_REPO" 2>/dev/null) || secret_list=""
        if echo "$secret_list" | grep -q "^GCP_WORKLOAD_IDENTITY_PROVIDER"; then
            ok "Verify: GitHub secret GCP_WORKLOAD_IDENTITY_PROVIDER set"
        else
            error "Verify: GitHub secret GCP_WORKLOAD_IDENTITY_PROVIDER not set"
            failures=$((failures + 1))
        fi
        if echo "$secret_list" | grep -q "^GCP_SERVICE_ACCOUNT"; then
            ok "Verify: GitHub secret GCP_SERVICE_ACCOUNT set"
        else
            error "Verify: GitHub secret GCP_SERVICE_ACCOUNT not set"
            failures=$((failures + 1))
        fi
    else
        info "Verify: GitHub checks skipped (--no-github or gh unavailable)"
    fi

    if [ "$failures" -gt 0 ]; then
        error "Verification failed: $failures issue(s) found"
        return 1
    fi

    ok "All verifications passed"
}

# Step 13: Print summary
print_summary() {
    printf '\n'
    info "============================================"
    info "  Bootstrap Complete"
    info "============================================"
    printf '\n'

    printf '  %-20s %s\n' "PROJECT_ID:" "$PROJECT_ID"
    printf '  %-20s %s\n' "PROJECT_NUMBER:" "$PROJECT_NUMBER"
    printf '  %-20s %s\n' "BUCKET:" "$BUCKET"
    printf '  %-20s %s\n' "BUCKET_LOCATION:" "$BUCKET_LOCATION"
    printf '  %-20s %s\n' "WIF POOL:" "$POOL_RESOURCE"
    printf '  %-20s %s\n' "WIF PROVIDER:" "$PROVIDER_RESOURCE"
    printf '  %-20s %s\n' "PRINCIPAL_SET:" "$PRINCIPAL_SET"
    printf '  %-20s %s\n' "SERVICE ACCOUNT:" "$SA_EMAIL"
    printf '  %-20s %s\n' "GITHUB REPO:" "$GITHUB_REPO"

    local env_file
    env_file="$(cd "$(dirname "$0")/../.." && pwd)/infra/.bootstrap.env"
    printf '  %-20s %s\n' "BOOTSTRAP ENV:" "$env_file"

    printf '\n'
    ok "You can now run the 'Provision Eval Environment' workflow from GitHub Actions."
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    parse_args "$@"

    # Detect repo and gh availability
    detect_github_repo
    detect_gh_cli

    # Compute resource names (needs PROJECT_ID and GITHUB_REPO)
    compute_resource_names

    if [ "$COMMAND" = "status" ]; then
        run_status
        exit $?
    fi

    # Bootstrap flow
    run_preflight

    if [ "$DRY_RUN" = "true" ]; then
        print_dry_run
        exit "$EXIT_OK"
    fi

    confirm_bootstrap

    step_enable_apis
    step_create_bucket
    step_create_wif_pool
    step_create_wif_provider
    step_create_service_account
    step_bind_sa_roles
    step_bind_wif_to_sa
    step_set_github_secrets
    step_write_bootstrap_env
    step_verify
    print_summary

    exit "$EXIT_OK"
}

main "$@"
