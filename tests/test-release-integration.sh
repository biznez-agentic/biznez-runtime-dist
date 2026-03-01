#!/usr/bin/env bash
# =============================================================================
# biznez-cli -- Release pipeline integration tests (requires Docker + yq)
# =============================================================================
# Usage: bash tests/test-release-integration.sh
#
# Prerequisites:
#   - Docker daemon running
#   - yq (mikefarah/yq v4+) installed
#   - crane or skopeo installed
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="$SCRIPT_DIR/../cli/biznez-cli"
PASS=0
FAIL=0
REGISTRY_PORT=5555
REGISTRY_CONTAINER="biznez-test-registry-$$"

# ---- Helpers ---------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
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

# ---- Cleanup ---------------------------------------------------------------
_cleanup() {
    info "Cleaning up..."
    docker rm -f "$REGISTRY_CONTAINER" 2>/dev/null || true
    rm -rf /tmp/biznez-integration-test-$$ 2>/dev/null || true
    info "Cleanup complete."
}
trap _cleanup EXIT

# ---- Preflight checks ------------------------------------------------------
info "Preflight checks..."

if [ ! -x "$CLI" ]; then
    error "CLI not found or not executable: $CLI"
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    error "docker is required for integration tests."
    exit 2
fi

if ! command -v yq >/dev/null 2>&1; then
    error "yq is required for integration tests. Install: brew install yq"
    exit 2
fi

# Need at least one of crane/skopeo for OCI operations
_IMG_TOOL=""
if command -v crane >/dev/null 2>&1; then
    _IMG_TOOL="crane"
elif command -v skopeo >/dev/null 2>&1; then
    _IMG_TOOL="skopeo"
else
    error "crane or skopeo required for integration tests."
    exit 2
fi

ok "Preflight passed (image tool: $_IMG_TOOL)"

# ---- Start local registry --------------------------------------------------
info "Starting local registry on port $REGISTRY_PORT..."
docker run -d -p "${REGISTRY_PORT}:5000" --name "$REGISTRY_CONTAINER" registry:2 >/dev/null 2>&1 || {
    error "Failed to start registry container"
    exit 1
}
sleep 2
ok "Registry running at localhost:${REGISTRY_PORT}"

# ---- Setup test images -----------------------------------------------------
TEST_DIR="/tmp/biznez-integration-test-$$"
mkdir -p "$TEST_DIR"

info "Setting up test images..."

# Pull a small test image
docker pull alpine:3.19 >/dev/null 2>&1 || { error "Failed to pull alpine:3.19"; exit 1; }

# Tag and push as fake biznez images
for _name in biznez/platform-api biznez/web-app; do
    docker tag alpine:3.19 "localhost:${REGISTRY_PORT}/${_name}:0.0.1-test" 2>/dev/null
    docker push "localhost:${REGISTRY_PORT}/${_name}:0.0.1-test" >/dev/null 2>&1
done

# Tag and push as fake third-party images
docker tag alpine:3.19 "localhost:${REGISTRY_PORT}/biznez/thirdparty/agentgateway:0.1.0" 2>/dev/null
docker push "localhost:${REGISTRY_PORT}/biznez/thirdparty/agentgateway:0.1.0" >/dev/null 2>&1

docker tag alpine:3.19 "localhost:${REGISTRY_PORT}/biznez/thirdparty/postgres:15-alpine" 2>/dev/null
docker push "localhost:${REGISTRY_PORT}/biznez/thirdparty/postgres:15-alpine" >/dev/null 2>&1

ok "Test images pushed to local registry"

# ---- Create test images.lock -----------------------------------------------
cat > "${TEST_DIR}/images.lock" <<LOCKEOF
version: "0.0.1-test"
generatedBy:
  tool: "biznez-cli"
  toolVersion: ""
  crane: ""
  syft: ""
  trivy: ""
platform: linux/amd64
releaseRegistry: ""
images:
  - name: platform-api
    sourceRepo: "localhost:${REGISTRY_PORT}/biznez/platform-api"
    targetRepo: "biznez/platform-api"
    releaseRepo: ""
    tag: "0.0.1-test"
    imageDigest: ""
    indexDigest: ""
  - name: web-app
    sourceRepo: "localhost:${REGISTRY_PORT}/biznez/web-app"
    targetRepo: "biznez/web-app"
    releaseRepo: ""
    tag: "0.0.1-test"
    imageDigest: ""
    indexDigest: ""
  - name: agentgateway
    sourceRepo: "localhost:${REGISTRY_PORT}/biznez/thirdparty/agentgateway"
    targetRepo: "biznez/thirdparty/agentgateway"
    releaseRepo: ""
    tag: "0.1.0"
    imageDigest: ""
    indexDigest: ""
  - name: postgres
    sourceRepo: "localhost:${REGISTRY_PORT}/biznez/thirdparty/postgres"
    targetRepo: "biznez/thirdparty/postgres"
    releaseRepo: ""
    tag: "15-alpine"
    imageDigest: ""
    indexDigest: ""
LOCKEOF

# =============================================================================
# Tests
# =============================================================================
echo ""
echo "=== Release pipeline integration tests ==="
echo ""

# ---- Test 1: build-release -------------------------------------------------
info "Test 1: build-release"
_br_rc=0
"$CLI" build-release \
    --version 0.0.1-test \
    --release-registry "localhost:${REGISTRY_PORT}/release" \
    --policy dev \
    --skip-sign \
    --skip-sbom \
    --skip-scan \
    --manifest "${TEST_DIR}/images.lock" \
    --output-dir "$TEST_DIR" 2>&1 || _br_rc=$?

_test "build-release succeeds" [ "$_br_rc" -eq 0 ]

# ---- Test 2: Verify digests resolved ---------------------------------------
_dig_count=$(yq eval '[.images[].imageDigest | select(. != "")] | length' "${TEST_DIR}/images.lock")
_test "images.lock has resolved digests" [ "${_dig_count:-0}" -gt 0 ]

# ---- Test 3: Verify releaseRepo populated -----------------------------------
_rel_count=$(yq eval '[.images[].releaseRepo | select(. != "")] | length' "${TEST_DIR}/images.lock")
_test "images.lock has releaseRepo for all images" [ "${_rel_count:-0}" -eq 4 ]

# ---- Test 4: release-manifest.json exists -----------------------------------
_test "release-manifest.json exists" [ -f "${TEST_DIR}/release-manifest.json" ]

if [ -f "${TEST_DIR}/release-manifest.json" ]; then
    _manifest_version=$(yq eval '.version' -p json "${TEST_DIR}/release-manifest.json" 2>/dev/null) || true
    _test "release-manifest.json has correct version" [ "$_manifest_version" = "0.0.1-test" ]
fi

# ---- Test 5: Export archive exists ------------------------------------------
_archive="${TEST_DIR}/biznez-images-v0.0.1-test.tar.gz"
_test "export archive exists" [ -f "$_archive" ]

# ---- Test 6: Verify OCI sublayout structure ---------------------------------
if [ -f "$_archive" ]; then
    _verify_dir=$(mktemp -d)
    tar xzf "$_archive" -C "$_verify_dir" 2>/dev/null

    _bundle_root=$(find "$_verify_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
    _test "bundle contains images.lock" [ -f "${_bundle_root}/images.lock" ]

    _oci_count=0
    if [ -d "${_bundle_root}/oci" ]; then
        for _sd in "${_bundle_root}"/oci/*/; do
            if [ -f "${_sd}oci-layout" ] 2>/dev/null; then
                _oci_count=$((_oci_count + 1))
            fi
        done
    fi
    _test "bundle has per-image OCI sublayouts" [ "$_oci_count" -gt 0 ]

    rm -rf "$_verify_dir"
fi

# ---- Test 7: checksums.sha256 exists ----------------------------------------
_test "checksums.sha256 exists" [ -f "${TEST_DIR}/checksums.sha256" ]

# ---- Test 8: Import images to separate namespace ----------------------------
if [ -f "$_archive" ]; then
    info "Test 8: import-images"
    _ii_rc=0
    "$CLI" import-images \
        --archive "$_archive" \
        --registry "localhost:${REGISTRY_PORT}/imported" 2>&1 || _ii_rc=$?

    _test "import-images succeeds" [ "$_ii_rc" -eq 0 ]
fi

# ---- Summary ----------------------------------------------------------------
echo ""
echo "==============================="
echo "  INTEGRATION TEST RESULTS"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "==============================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
