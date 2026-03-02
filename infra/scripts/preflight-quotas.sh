#!/usr/bin/env bash
# =============================================================================
# preflight-quotas.sh -- Pre-provision checks for GKE eval environments
# =============================================================================
# Validates APIs, billing, org policies, and resource quotas before Terraform.
#
# Hard fail (exit 2): APIs disabled, billing inactive, blocking org policies
# Warn only (exit 0): quota thresholds exceeded
#
# Usage:
#   ./preflight-quotas.sh --project <project-id> --region <region>
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers (match biznez-cli pattern)
# ---------------------------------------------------------------------------
NO_COLOR="${NO_COLOR:-false}"
_color_enabled() { [ "$NO_COLOR" = "false" ] && [ -t 1 ]; }

info()  { if _color_enabled; then printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; else printf '[INFO]  %s\n' "$*"; fi; }
ok()    { if _color_enabled; then printf '\033[0;32m[OK]\033[0m    %s\n' "$*"; else printf '[OK]    %s\n' "$*"; fi; }
warn()  { if _color_enabled; then printf '\033[0;33m[WARN]\033[0m  %s\n' "$*" >&2; else printf '[WARN]  %s\n' "$*" >&2; fi; }
error() { if _color_enabled; then printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; else printf '[ERROR] %s\n' "$*" >&2; fi; }

# ---------------------------------------------------------------------------
# Exit codes
# ---------------------------------------------------------------------------
readonly EXIT_OK=0
readonly EXIT_PREREQ=2

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
PROJECT_ID=""
REGION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)  PROJECT_ID="$2"; shift 2 ;;
        --region)   REGION="$2"; shift 2 ;;
        *)          error "Unknown argument: $1"; exit "$EXIT_PREREQ" ;;
    esac
done

if [ -z "$PROJECT_ID" ] || [ -z "$REGION" ]; then
    error "Usage: $0 --project <project-id> --region <region>"
    exit "$EXIT_PREREQ"
fi

# ---------------------------------------------------------------------------
# Require gcloud
# ---------------------------------------------------------------------------
if ! command -v gcloud &>/dev/null; then
    error "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
    exit "$EXIT_PREREQ"
fi

HARD_FAIL=false
WARNINGS=false

# ---------------------------------------------------------------------------
# Hard fail checks
# ---------------------------------------------------------------------------

# 1. Required APIs
info "Checking required APIs..."
REQUIRED_APIS=("container.googleapis.com" "compute.googleapis.com" "artifactregistry.googleapis.com")
ENABLED_APIS=$(gcloud services list --project="$PROJECT_ID" --enabled --format="value(config.name)" 2>/dev/null) || true

for api in "${REQUIRED_APIS[@]}"; do
    if echo "$ENABLED_APIS" | grep -q "^${api}$"; then
        ok "API enabled: $api"
    else
        error "API not enabled: $api"
        error "  Fix: gcloud services enable $api --project=$PROJECT_ID"
        HARD_FAIL=true
    fi
done

# 2. Billing account active
info "Checking billing..."
BILLING_ENABLED=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingEnabled)" 2>/dev/null) || true
if [ "$BILLING_ENABLED" = "True" ]; then
    ok "Billing is active"
else
    error "Billing is not active for project $PROJECT_ID"
    error "  Fix: Link a billing account at https://console.cloud.google.com/billing"
    HARD_FAIL=true
fi

# 3. Org policy blockers (skip gracefully if no permission)
info "Checking org policy constraints..."

check_org_policy() {
    local constraint="$1"
    local description="$2"

    # Try to read the policy; if no permission or no org, skip gracefully
    local policy_output
    if ! policy_output=$(gcloud org-policies describe "$constraint" --project="$PROJECT_ID" 2>&1); then
        if echo "$policy_output" | grep -qi "permission\|not found\|PERMISSION_DENIED\|NOT_FOUND"; then
            ok "Org policy $constraint: no restriction detected (or no permission to read)"
            return 0
        fi
    fi

    # Check if the policy explicitly denies all
    if echo "$policy_output" | grep -qi "allValues: DENY"; then
        error "Org policy $constraint blocks: $description"
        HARD_FAIL=true
        return 1
    fi

    ok "Org policy $constraint: no blocking restriction"
    return 0
}

check_org_policy "constraints/compute.vmExternalIpAccess" "Blocks NAT external IPs"
check_org_policy "constraints/compute.restrictVpcPeering" "May block GKE VPC peering"

# Check GKE location restriction (need target region in allowed list)
check_location_policy() {
    local policy_output
    if ! policy_output=$(gcloud org-policies describe "constraints/gke.locationRestriction" --project="$PROJECT_ID" 2>&1); then
        ok "Org policy gke.locationRestriction: no restriction detected"
        return 0
    fi

    if echo "$policy_output" | grep -qi "allValues: DENY"; then
        error "Org policy gke.locationRestriction blocks all locations"
        HARD_FAIL=true
        return 1
    fi

    # If there's an allowed list, check if our region is in it
    if echo "$policy_output" | grep -q "allowedValues"; then
        if ! echo "$policy_output" | grep -q "$REGION"; then
            error "Org policy gke.locationRestriction does not allow region $REGION"
            HARD_FAIL=true
            return 1
        fi
    fi

    ok "Org policy gke.locationRestriction: region $REGION is allowed"
    return 0
}

check_location_policy

# ---------------------------------------------------------------------------
# Warning-only checks
# ---------------------------------------------------------------------------

# 4. GKE cluster count
info "Checking existing GKE clusters in $REGION..."
CLUSTER_COUNT=$(gcloud container clusters list --project="$PROJECT_ID" --region="$REGION" --format="value(name)" 2>/dev/null | wc -l | tr -d ' ') || CLUSTER_COUNT=0
if [ "$CLUSTER_COUNT" -gt 5 ]; then
    warn "Found $CLUSTER_COUNT GKE clusters in $REGION (threshold: 5)"
    warn "  Consider cleaning up unused eval environments"
    WARNINGS=true
else
    ok "GKE cluster count: $CLUSTER_COUNT (threshold: 5)"
fi

# 5. CPU quota
info "Checking regional CPU quota in $REGION..."
CPU_QUOTA=$(gcloud compute regions describe "$REGION" --project="$PROJECT_ID" --format="json" 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for q in data.get('quotas', []):
    if q['metric'] == 'CPUS':
        print(int(q['limit'] - q['usage']))
        sys.exit(0)
print(-1)
" 2>/dev/null) || CPU_QUOTA=-1

if [ "$CPU_QUOTA" -eq -1 ]; then
    warn "Could not determine CPU quota (non-fatal)"
    WARNINGS=true
elif [ "$CPU_QUOTA" -lt 8 ]; then
    warn "Available CPU quota: $CPU_QUOTA vCPUs (need ~8 for Autopilot minimum)"
    warn "  Request increase: https://console.cloud.google.com/iam-admin/quotas"
    WARNINGS=true
else
    ok "CPU quota available: $CPU_QUOTA vCPUs"
fi

# 6. External IP quota
info "Checking external IP quota in $REGION..."
IP_QUOTA=$(gcloud compute regions describe "$REGION" --project="$PROJECT_ID" --format="json" 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for q in data.get('quotas', []):
    if q['metric'] == 'STATIC_ADDRESSES' or q['metric'] == 'IN_USE_ADDRESSES':
        avail = int(q['limit'] - q['usage'])
        print(avail)
        sys.exit(0)
print(-1)
" 2>/dev/null) || IP_QUOTA=-1

if [ "$IP_QUOTA" -eq -1 ]; then
    warn "Could not determine external IP quota (non-fatal)"
    WARNINGS=true
elif [ "$IP_QUOTA" -lt 2 ]; then
    warn "Available external IP quota: $IP_QUOTA (need 1+ for NAT)"
    WARNINGS=true
else
    ok "External IP quota available: $IP_QUOTA"
fi

# 7. AR repository count
info "Checking Artifact Registry repositories..."
AR_COUNT=$(gcloud artifacts repositories list --project="$PROJECT_ID" --location="$REGION" --format="value(name)" 2>/dev/null | wc -l | tr -d ' ') || AR_COUNT=0
if [ "$AR_COUNT" -gt 20 ]; then
    warn "Found $AR_COUNT AR repositories in $REGION (threshold: 20)"
    warn "  Consider cleaning up unused eval repositories"
    WARNINGS=true
else
    ok "AR repository count: $AR_COUNT (threshold: 20)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [ "$HARD_FAIL" = "true" ]; then
    error "Preflight checks FAILED -- resolve errors above before provisioning"
    exit "$EXIT_PREREQ"
fi

if [ "$WARNINGS" = "true" ]; then
    warn "Preflight checks passed with warnings (see above)"
else
    ok "All preflight checks passed"
fi

exit "$EXIT_OK"
