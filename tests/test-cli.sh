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

# ---- Summary ---------------------------------------------------------------
echo ""
echo "==============================="
echo "  PASS: $PASS  FAIL: $FAIL"
echo "==============================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
