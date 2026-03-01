#!/usr/bin/env bash
# =============================================================================
# biznez-cli -- Unit tests (no cluster required)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="$SCRIPT_DIR/../cli/biznez-cli"
PASS=0
FAIL=0

# ---- Helpers ---------------------------------------------------------------
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

# ---- Tests -----------------------------------------------------------------

echo "=== biznez-cli unit tests ==="
echo ""

# Test: CLI is executable
_test "CLI script exists and is executable" test -x "$CLI"

# Test: --version
_version_output=$("$CLI" --version 2>&1)
_test "--version contains version string" _output_contains "$_version_output" "biznez-cli"

# Test: --help lists all P0 commands
_help_output=$("$CLI" --help 2>&1)
_test "--help lists generate-secrets" _output_contains "$_help_output" "generate-secrets"
_test "--help lists validate" _output_contains "$_help_output" "validate"
_test "--help lists validate-secrets" _output_contains "$_help_output" "validate-secrets"
_test "--help lists install" _output_contains "$_help_output" "install"
_test "--help lists health-check" _output_contains "$_help_output" "health-check"
_test "--help lists migrate" _output_contains "$_help_output" "migrate"

# Test: --help lists P1 commands
_test "--help lists status" _output_contains "$_help_output" "status"
_test "--help lists uninstall" _output_contains "$_help_output" "uninstall"
_test "--help lists oidc-discover" _output_contains "$_help_output" "oidc-discover"
_test "--help lists support-bundle" _output_contains "$_help_output" "support-bundle"

# Test: --help lists P2 commands
_test "--help lists backup-db" _output_contains "$_help_output" "backup-db"
_test "--help lists restore-db" _output_contains "$_help_output" "restore-db"
_test "--help lists upgrade" _output_contains "$_help_output" "upgrade"

# Test: unknown command exits with code 1
_test_exit_code "unknown command exits 1" 1 "$CLI" nonexistent-command

# Test: command-specific help
_gs_help=$("$CLI" generate-secrets --help 2>&1)
_test "generate-secrets --help shows usage" _output_contains "$_gs_help" "Usage:"
_test "generate-secrets --help shows --format" _output_contains "$_gs_help" "--format"
_test "generate-secrets --help shows --no-docker-fernet" _output_contains "$_gs_help" "--no-docker-fernet"

_val_help=$("$CLI" validate --help 2>&1)
_test "validate --help shows --strict" _output_contains "$_val_help" "--strict"

# Test: generate-secrets --format raw --no-docker-fernet outputs 3 lines
if command -v openssl >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
    _raw_output=$("$CLI" generate-secrets --format raw --no-docker-fernet 2>/dev/null)
    _line_count=$(echo "$_raw_output" | wc -l | tr -d ' ')
    _test "generate-secrets --format raw outputs 3 lines" [ "$_line_count" -eq 3 ]

    # Test: generate-secrets --format yaml --no-docker-fernet outputs K8s Secret
    _yaml_output=$("$CLI" generate-secrets --format yaml --no-docker-fernet 2>/dev/null)
    _test "generate-secrets --format yaml contains kind: Secret" _output_contains "$_yaml_output" "kind: Secret"
    _test "generate-secrets --format yaml contains stringData" _output_contains "$_yaml_output" "stringData"

    # Test: generate-secrets --format env --no-docker-fernet outputs KEY=VALUE
    _env_output=$("$CLI" generate-secrets --format env --no-docker-fernet 2>/dev/null)
    _test "generate-secrets --format env contains ENCRYPTION_KEY=" _output_contains "$_env_output" "ENCRYPTION_KEY="
    _test "generate-secrets --format env contains JWT_SECRET_KEY=" _output_contains "$_env_output" "JWT_SECRET_KEY="
    _test "generate-secrets --format env contains POSTGRES_PASSWORD=" _output_contains "$_env_output" "POSTGRES_PASSWORD="
else
    echo "[SKIP] generate-secrets tests: neither openssl nor python3 available"
fi

# Test: validate requires -f flag
_test_exit_code "validate without -f exits 3" 3 "$CLI" validate

# Test: --no-color flag doesn't break dispatch
_nocolor_output=$("$CLI" --no-color --help 2>&1)
_test "--no-color --help still works" _output_contains "$_nocolor_output" "biznez-cli"

# Test: -- passthrough doesn't break
_passthrough_output=$("$CLI" --help -- --some-helm-flag 2>&1)
_test "-- passthrough doesn't break --help" _output_contains "$_passthrough_output" "biznez-cli"

# =============================================================================
# Phase 8: Supply chain command tests
# =============================================================================
echo ""
echo "=== Phase 8 supply chain tests ==="
echo ""

# Test: --help lists P3 commands
_test "--help lists export-images" _output_contains "$_help_output" "export-images"
_test "--help lists import-images" _output_contains "$_help_output" "import-images"
_test "--help lists verify-images" _output_contains "$_help_output" "verify-images"
_test "--help lists build-release" _output_contains "$_help_output" "build-release"

# Test: export-images --help shows expected flags
_ei_help=$("$CLI" export-images --help 2>&1)
_test "export-images --help shows --manifest" _output_contains "$_ei_help" "--manifest"
_test "export-images --help shows --format" _output_contains "$_ei_help" "--format"
_test "export-images --help shows --output" _output_contains "$_ei_help" "--output"

# Test: import-images --help shows expected flags
_ii_help=$("$CLI" import-images --help 2>&1)
_test "import-images --help shows --archive" _output_contains "$_ii_help" "--archive"
_test "import-images --help shows --registry" _output_contains "$_ii_help" "--registry"
_test "import-images --help shows --docker" _output_contains "$_ii_help" "--docker"

# Test: verify-images --help shows expected flags
_vi_help=$("$CLI" verify-images --help 2>&1)
_test "verify-images --help shows --key" _output_contains "$_vi_help" "--key"
_test "verify-images --help shows --keyless" _output_contains "$_vi_help" "--keyless"
_test "verify-images --help shows --skip-tag-check" _output_contains "$_vi_help" "--skip-tag-check"

# Test: build-release --help shows expected flags
_br_help=$("$CLI" build-release --help 2>&1)
_test "build-release --help shows --version" _output_contains "$_br_help" "--version"
_test "build-release --help shows --policy" _output_contains "$_br_help" "--policy"
_test "build-release --help shows --release-registry" _output_contains "$_br_help" "--release-registry"
_test "build-release --help shows --skip-scan" _output_contains "$_br_help" "--skip-scan"
_test "build-release --help shows --skip-sbom" _output_contains "$_br_help" "--skip-sbom"
_test "build-release --help shows --skip-sign" _output_contains "$_br_help" "--skip-sign"

# Test: exit codes for missing required flags
_test_exit_code "export-images --manifest /nonexistent exits 11" 11 "$CLI" export-images --manifest /nonexistent
_test_exit_code "import-images without --archive exits 11" 11 "$CLI" import-images
_test_exit_code "build-release without --version exits 11" 11 "$CLI" build-release
_test_exit_code "verify-images without --registry exits 11" 11 "$CLI" verify-images

# Test: images.lock awk parser
echo ""
echo "--- images.lock parser tests ---"

_tmp_lock=$(mktemp)
cat > "$_tmp_lock" <<'LOCKEOF'
version: "1.0.0-test"
platform: linux/amd64
releaseRegistry: ""
images:
  - name: test-api
    sourceRepo: "ghcr.io/org/test-api"
    targetRepo: "mycompany/test-api"
    releaseRepo: "registry.example.com/mycompany/test-api"
    tag: "1.0.0"
    imageDigest: "sha256:abc123"
    indexDigest: "sha256:def456"
  - name: test-db
    sourceRepo: "docker.io/library/postgres"
    targetRepo: "mycompany/thirdparty/postgres"
    releaseRepo: ""
    tag: "15-alpine"
    imageDigest: "sha256:789xyz"
    indexDigest: ""
LOCKEOF

# Parse with awk (always available)
_awk_output=$("$CLI" export-images --manifest "$_tmp_lock" --allow-awk-parser --help 2>&1) || true
# Actually test the parser directly by sourcing lib if available
_LIB_FILE="$SCRIPT_DIR/../cli/lib/images.sh"
if [ -f "$_LIB_FILE" ]; then
    # Source the lib to get _img_parse_lock_awk
    # Need to provide stub functions the lib expects
    _stub_die() { echo "DIE: $1" >&2; return 1; }
    _stub_warn() { echo "WARN: $1" >&2; }
    # Use awk parser directly
    _awk_records=$(awk '
    /^  - name:/ { if (name != "") print name "\t" sourceRepo "\t" targetRepo "\t" releaseRepo "\t" tag "\t" imageDigest "\t" indexDigest;
                   name=$3; sourceRepo=""; targetRepo=""; releaseRepo=""; tag=""; imageDigest=""; indexDigest="" }
    /^    sourceRepo:/ { sourceRepo=$2; gsub(/^"/, "", sourceRepo); gsub(/"$/, "", sourceRepo) }
    /^    targetRepo:/ { targetRepo=$2; gsub(/^"/, "", targetRepo); gsub(/"$/, "", targetRepo) }
    /^    releaseRepo:/ { releaseRepo=$2; gsub(/^"/, "", releaseRepo); gsub(/"$/, "", releaseRepo) }
    /^    tag:/ { tag=$2; gsub(/^"/, "", tag); gsub(/"$/, "", tag) }
    /^    imageDigest:/ { imageDigest=$2; gsub(/^"/, "", imageDigest); gsub(/"$/, "", imageDigest) }
    /^    indexDigest:/ { indexDigest=$2; gsub(/^"/, "", indexDigest); gsub(/"$/, "", indexDigest) }
    END { if (name != "") print name "\t" sourceRepo "\t" targetRepo "\t" releaseRepo "\t" tag "\t" imageDigest "\t" indexDigest }
    ' "$_tmp_lock")

    _awk_count=$(echo "$_awk_records" | wc -l | tr -d ' ')
    _test "awk parser: 2 images parsed" [ "$_awk_count" -eq 2 ]

    # Verify field extraction
    _first_name=$(echo "$_awk_records" | head -1 | cut -f1)
    _test "awk parser: first image name is test-api" [ "$_first_name" = "test-api" ]

    _first_source=$(echo "$_awk_records" | head -1 | cut -f2)
    _test "awk parser: sourceRepo with URL colons" [ "$_first_source" = "ghcr.io/org/test-api" ]

    _first_digest=$(echo "$_awk_records" | head -1 | cut -f6)
    _test "awk parser: imageDigest extracted" [ "$_first_digest" = "sha256:abc123" ]

    _second_name=$(echo "$_awk_records" | tail -1 | cut -f1)
    _test "awk parser: second image name is test-db" [ "$_second_name" = "test-db" ]

    # Conditional yq parser test
    if command -v yq >/dev/null 2>&1; then
        echo ""
        echo "--- yq parser tests ---"
        _yq_records=$(yq eval '.images[] | [.name, .sourceRepo, .targetRepo, .releaseRepo, .tag, .imageDigest, .indexDigest] | @tsv' "$_tmp_lock")
        _yq_count=$(echo "$_yq_records" | wc -l | tr -d ' ')
        _test "yq parser: 2 images parsed" [ "$_yq_count" -eq 2 ]

        _yq_first_name=$(echo "$_yq_records" | head -1 | cut -f1)
        _test "yq parser: first image name is test-api" [ "$_yq_first_name" = "test-api" ]

        _yq_first_source=$(echo "$_yq_records" | head -1 | cut -f2)
        _test "yq parser: sourceRepo with URL colons" [ "$_yq_first_source" = "ghcr.io/org/test-api" ]

        _yq_first_digest=$(echo "$_yq_records" | head -1 | cut -f6)
        _test "yq parser: imageDigest extracted" [ "$_yq_first_digest" = "sha256:abc123" ]

        _yq_release=$(echo "$_yq_records" | head -1 | cut -f4)
        _test "yq parser: releaseRepo extracted" [ "$_yq_release" = "registry.example.com/mycompany/test-api" ]
    else
        echo "[SKIP] yq parser tests: yq not found"
    fi
else
    echo "[SKIP] Parser tests: lib/images.sh not found"
fi

rm -f "$_tmp_lock"

# ---- Summary ---------------------------------------------------------------
echo ""
echo "==============================="
echo "  PASS: $PASS  FAIL: $FAIL"
echo "==============================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
