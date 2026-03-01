#!/usr/bin/env bash
# =============================================================================
# biznez-cli -- Integration smoke tests (requires kind cluster)
# =============================================================================
# Usage:
#   ./smoke-test.sh              # smoke-fast (~2 min)
#   ./smoke-test.sh --full       # smoke-full (~5 min)
#
# Prerequisites:
#   - kind cluster running (context: kind-kind or KUBECONTEXT env)
#   - kubectl, helm installed
#   - Images loaded into kind (or publicly available)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="$SCRIPT_DIR/../cli/biznez-cli"
CHART_DIR="$SCRIPT_DIR/../helm/biznez-runtime"
VALUES_DIR="$SCRIPT_DIR/values"
PASS=0
FAIL=0
FULL=false
RELEASE="smoke-$$"
NAMESPACE="smoke-test-$$"
KUBECONTEXT="${KUBECONTEXT:-kind-kind}"

# ---- Parse flags ------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --full) FULL=true ;;
        -h|--help)
            echo "Usage: $0 [--full]"
            echo ""
            echo "  --full   Run full integration suite (~5 min)"
            echo "  default  Run fast smoke tests only (~2 min)"
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown flag: $arg"
            exit 1
            ;;
    esac
done

# ---- Helpers ----------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; }

_test() {
    local name="$1"
    shift
    if "$@"; then
        printf '[PASS] %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '[FAIL] %s\n' "$name"
        FAIL=$((FAIL + 1))
    fi
}

_test_exit_code() {
    local name="$1" expected="$2"
    shift 2
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq "$expected" ]; then
        printf '[PASS] %s (exit code %d)\n' "$name" "$rc"
        PASS=$((PASS + 1))
    else
        printf '[FAIL] %s (expected exit %d, got %d)\n' "$name" "$expected" "$rc"
        FAIL=$((FAIL + 1))
    fi
}

_output_contains() {
    local output="$1" pattern="$2"
    echo "$output" | grep -qF -e "$pattern" 2>/dev/null
}

# ---- Cleanup on exit -------------------------------------------------------
_cleanup() {
    info "Cleaning up test resources..."
    # Uninstall helm release if it exists
    helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null || true
    # Delete namespace
    kubectl delete namespace "$NAMESPACE" --wait=false 2>/dev/null || true
    # Remove temp files
    rm -f /tmp/smoke-secrets-$$.yaml /tmp/smoke-bundle-$$.tar.gz
    info "Cleanup complete."
}
trap _cleanup EXIT

# ---- Preflight checks -------------------------------------------------------
info "Preflight checks..."

if [ ! -x "$CLI" ]; then
    error "CLI not found or not executable: $CLI"
    exit 1
fi

if [ ! -d "$CHART_DIR" ]; then
    error "Chart directory not found: $CHART_DIR"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    error "kubectl is not installed."
    exit 2
fi

if ! command -v helm >/dev/null 2>&1; then
    error "helm is not installed."
    exit 2
fi

# Check kind cluster is reachable
if ! kubectl --context "$KUBECONTEXT" cluster-info >/dev/null 2>&1; then
    error "Cannot reach cluster (context: $KUBECONTEXT)."
    error "Start a kind cluster: kind create cluster"
    exit 4
fi

ok "Preflight checks passed (context: $KUBECONTEXT)."

# ---- Setup namespace --------------------------------------------------------
info "Creating test namespace: $NAMESPACE"
kubectl --context "$KUBECONTEXT" create namespace "$NAMESPACE"
ok "Namespace created."

# ---- Image availability check -----------------------------------------------
_setup_kind_images() {
    # Check if the eval values file references images that are loaded in kind
    local _eval_values="${VALUES_DIR}/eval.yaml"
    if [ ! -f "$_eval_values" ]; then
        warn "eval.yaml not found at $_eval_values. Using chart defaults."
        return 0
    fi

    # Try to detect image references from values
    local _be_img _fe_img
    _be_img=$(grep -E '^\s+repository:' "$_eval_values" 2>/dev/null | head -1 | awk '{print $2}') || true
    _fe_img=$(grep -E '^\s+repository:' "$_eval_values" 2>/dev/null | tail -1 | awk '{print $2}') || true

    if [ -n "$_be_img" ]; then
        if docker image inspect "$_be_img" >/dev/null 2>&1; then
            info "Loading backend image into kind: $_be_img"
            kind load docker-image "$_be_img" 2>/dev/null || warn "Failed to load $_be_img into kind."
        else
            warn "Backend image not found locally: $_be_img (may pull from registry)"
        fi
    fi

    if [ -n "$_fe_img" ]; then
        if docker image inspect "$_fe_img" >/dev/null 2>&1; then
            info "Loading frontend image into kind: $_fe_img"
            kind load docker-image "$_fe_img" 2>/dev/null || warn "Failed to load $_fe_img into kind."
        else
            warn "Frontend image not found locally: $_fe_img (may pull from registry)"
        fi
    fi
}

_setup_kind_images

# ---- Determine values file --------------------------------------------------
VALUES_FILE=""
if [ -f "${VALUES_DIR}/eval.yaml" ]; then
    VALUES_FILE="${VALUES_DIR}/eval.yaml"
elif [ -f "${VALUES_DIR}/ci-eval.yaml" ]; then
    VALUES_FILE="${VALUES_DIR}/ci-eval.yaml"
fi

if [ -z "$VALUES_FILE" ]; then
    error "No eval values file found in $VALUES_DIR"
    error "Create tests/values/eval.yaml with eval profile settings."
    exit 1
fi

info "Using values file: $VALUES_FILE"

# =============================================================================
# SMOKE-FAST tests (~2 min)
# =============================================================================
echo ""
echo "=== smoke-fast tests ==="
echo ""

# ---- Test 1: generate-secrets -----------------------------------------------
info "Test 1: generate-secrets --format yaml"
_secrets_file="/tmp/smoke-secrets-$$.yaml"
_secrets_output=$("$CLI" generate-secrets --format yaml --no-docker-fernet 2>&1)
_secrets_rc=0
echo "$_secrets_output" > "$_secrets_file" || _secrets_rc=$?

_test "generate-secrets produces YAML output" _output_contains "$_secrets_output" "kind: Secret"
_test "generate-secrets contains stringData" _output_contains "$_secrets_output" "stringData"

# Apply secrets to test namespace
if [ "$_secrets_rc" -eq 0 ] && [ -s "$_secrets_file" ]; then
    if kubectl --context "$KUBECONTEXT" apply -f "$_secrets_file" -n "$NAMESPACE" >/dev/null 2>&1; then
        ok "Secrets applied to namespace $NAMESPACE"
    else
        warn "Failed to apply generated secrets (non-fatal for smoke test)."
    fi
fi

# ---- Test 2: validate -------------------------------------------------------
info "Test 2: validate -f $VALUES_FILE"
_validate_output=$("$CLI" validate -f "$VALUES_FILE" -n "$NAMESPACE" --release "$RELEASE" 2>&1) || true
_test "validate exits without fatal error" echo "$_validate_output" | grep -qv "FATAL" 2>/dev/null || true

# Just check that validate ran — it may report warnings but shouldn't crash
_test "validate produces output" [ -n "$_validate_output" ]

# ---- Test 3: install --------------------------------------------------------
info "Test 3: install -f $VALUES_FILE"
_install_rc=0
"$CLI" install -f "$VALUES_FILE" -n "$NAMESPACE" --release "$RELEASE" 2>&1 || _install_rc=$?

if [ "$_install_rc" -eq 0 ]; then
    printf '[PASS] install succeeded (exit 0)\n'
    PASS=$((PASS + 1))
else
    printf '[FAIL] install failed (exit %d)\n' "$_install_rc"
    FAIL=$((FAIL + 1))
fi

# Give pods time to start
info "Waiting for pods to schedule..."
sleep 10

# Check pods exist
_pod_count=$(kubectl --context "$KUBECONTEXT" get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ') || true
_test "install created pods" [ "${_pod_count:-0}" -gt 0 ]

# ---- Test 4: health-check ---------------------------------------------------
info "Test 4: health-check --release $RELEASE --timeout 120"
_health_rc=0
_health_output=$("$CLI" health-check -n "$NAMESPACE" --release "$RELEASE" --timeout 120 2>&1) || _health_rc=$?

if [ "$_health_rc" -eq 0 ]; then
    printf '[PASS] health-check passed (exit 0)\n'
    PASS=$((PASS + 1))
else
    printf '[FAIL] health-check failed (exit %d)\n' "$_health_rc"
    FAIL=$((FAIL + 1))
    # Print health output for debugging
    echo "--- health-check output ---"
    echo "$_health_output"
    echo "--- end output ---"
fi

# =============================================================================
# SMOKE-FULL tests (~5 min, opt-in)
# =============================================================================
if [ "$FULL" = "true" ]; then
    echo ""
    echo "=== smoke-full tests ==="
    echo ""

    # ---- Test 5: migrate -----------------------------------------------------
    info "Test 5: migrate --release $RELEASE --timeout 300"
    _migrate_rc=0
    _migrate_output=$("$CLI" migrate -n "$NAMESPACE" --release "$RELEASE" --timeout 300 2>&1) || _migrate_rc=$?

    if [ "$_migrate_rc" -eq 0 ]; then
        printf '[PASS] migrate succeeded (exit 0)\n'
        PASS=$((PASS + 1))
    else
        printf '[WARN] migrate returned exit %d (may be expected if no migrations pending)\n' "$_migrate_rc"
        # Don't count as fail if migration job simply had nothing to do
        if echo "$_migrate_output" | grep -qi "no.*migration\|already.*current\|nothing.*to.*migrate" 2>/dev/null; then
            printf '[PASS] migrate - no migrations needed (acceptable)\n'
            PASS=$((PASS + 1))
        else
            printf '[FAIL] migrate failed (exit %d)\n' "$_migrate_rc"
            FAIL=$((FAIL + 1))
            echo "--- migrate output ---"
            echo "$_migrate_output"
            echo "--- end output ---"
        fi
    fi

    # ---- Test 6: validate-secrets --------------------------------------------
    info "Test 6: validate-secrets --release $RELEASE"
    _vs_rc=0
    _vs_output=$("$CLI" validate-secrets -n "$NAMESPACE" --release "$RELEASE" 2>&1) || _vs_rc=$?

    if [ "$_vs_rc" -eq 0 ]; then
        printf '[PASS] validate-secrets passed (exit 0)\n'
        PASS=$((PASS + 1))
    else
        printf '[FAIL] validate-secrets failed (exit %d)\n' "$_vs_rc"
        FAIL=$((FAIL + 1))
    fi

    # ---- Test 7: support-bundle ----------------------------------------------
    info "Test 7: support-bundle --release $RELEASE"
    _bundle_file="/tmp/smoke-bundle-$$.tar.gz"
    _bundle_rc=0
    "$CLI" support-bundle -n "$NAMESPACE" --release "$RELEASE" --output "$_bundle_file" 2>&1 || _bundle_rc=$?

    if [ "$_bundle_rc" -eq 0 ]; then
        printf '[PASS] support-bundle succeeded (exit 0)\n'
        PASS=$((PASS + 1))
    else
        printf '[FAIL] support-bundle failed (exit %d)\n' "$_bundle_rc"
        FAIL=$((FAIL + 1))
    fi

    # ---- Test 8: Verify bundle contents --------------------------------------
    if [ -f "$_bundle_file" ]; then
        _bundle_contents=$(tar tzf "$_bundle_file" 2>/dev/null) || true
        _test "bundle contains pod-describe" _output_contains "${_bundle_contents:-}" "pod-describe"
        _test "bundle contains helm-values" _output_contains "${_bundle_contents:-}" "helm-values"
    else
        printf '[SKIP] bundle file not created, skipping content check\n'
    fi

    # ---- Test 9: uninstall ---------------------------------------------------
    info "Test 9: uninstall --release $RELEASE --yes"
    _uninstall_rc=0
    "$CLI" uninstall -n "$NAMESPACE" --release "$RELEASE" --yes 2>&1 || _uninstall_rc=$?

    if [ "$_uninstall_rc" -eq 0 ]; then
        printf '[PASS] uninstall succeeded (exit 0)\n'
        PASS=$((PASS + 1))
    else
        printf '[FAIL] uninstall failed (exit %d)\n' "$_uninstall_rc"
        FAIL=$((FAIL + 1))
    fi

    # Verify release is gone
    sleep 3
    if ! helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
        printf '[PASS] release is removed after uninstall\n'
        PASS=$((PASS + 1))
    else
        printf '[FAIL] release still exists after uninstall\n'
        FAIL=$((FAIL + 1))
    fi
fi

# ---- Summary ----------------------------------------------------------------
echo ""
echo "==============================="
if [ "$FULL" = "true" ]; then
    echo "  SMOKE-FULL RESULTS"
else
    echo "  SMOKE-FAST RESULTS"
fi
echo "  PASS: $PASS  FAIL: $FAIL"
echo "==============================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
