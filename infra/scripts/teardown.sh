#!/usr/bin/env bash
# =============================================================================
# teardown.sh -- Uninstall Biznez runtime from a GKE eval environment
# =============================================================================
# Removes Helm release, PVCs, and namespace. All steps use || true to ensure
# teardown never fails the workflow -- partial cleanup is better than none.
#
# Usage:
#   ./teardown.sh --namespace biznez --release biznez
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
# Parse arguments
# ---------------------------------------------------------------------------
NAMESPACE="biznez"
RELEASE="biznez"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)  NAMESPACE="$2"; shift 2 ;;
        --release)    RELEASE="$2"; shift 2 ;;
        *)            warn "Unknown argument: $1"; shift ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight (soft -- teardown should not fail on prereqs)
# ---------------------------------------------------------------------------
for cmd in kubectl helm; do
    if ! command -v "$cmd" &>/dev/null; then
        warn "$cmd not found -- skipping runtime teardown"
        exit 0
    fi
done

if ! kubectl cluster-info &>/dev/null; then
    warn "Cannot connect to Kubernetes cluster -- skipping runtime teardown"
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 1: Helm uninstall
# ---------------------------------------------------------------------------
info "Uninstalling Helm release $RELEASE from namespace $NAMESPACE..."
if helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null; then
    ok "Helm release $RELEASE uninstalled"
else
    warn "Helm uninstall failed (release may not exist)"
fi

# ---------------------------------------------------------------------------
# Step 2: Delete PVCs
# ---------------------------------------------------------------------------
info "Deleting PVCs for release $RELEASE..."
if kubectl delete pvc \
    -l "app.kubernetes.io/instance=$RELEASE" \
    -n "$NAMESPACE" --wait=false 2>/dev/null; then
    ok "PVCs deleted"
else
    warn "PVC deletion failed (may not exist)"
fi

# ---------------------------------------------------------------------------
# Step 3: Delete namespace
# ---------------------------------------------------------------------------
info "Deleting namespace $NAMESPACE..."
if kubectl delete namespace "$NAMESPACE" --wait=false 2>/dev/null; then
    ok "Namespace $NAMESPACE deletion initiated"
else
    warn "Namespace deletion failed (may not exist)"
fi

ok "Teardown complete"
exit 0
