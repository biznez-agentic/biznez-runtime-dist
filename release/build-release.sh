#!/usr/bin/env bash
# =============================================================================
# build-release.sh -- CI convenience wrapper for biznez-cli build-release
# =============================================================================
# Usage:
#   ./build-release.sh <version>
#   VERSION=1.0.0 ./build-release.sh
#
# Environment variables:
#   VERSION          Release version (alternative to $1)
#   OUTPUT_DIR       Output directory (default: ./release-output)
#   RELEASE_REGISTRY Release registry URL (required unless SKIP_MIRROR=true)
#   SIGN_KEY         Path to cosign private key
#   POLICY           Build policy: enterprise (default) or dev
#   SKIP_SCAN        Set to "true" to skip vulnerability scanning
#   SKIP_SBOM        Set to "true" to skip SBOM generation
#   SKIP_SIGN        Set to "true" to skip signing
#   SKIP_MIRROR      Set to "true" to skip mirroring to release registry
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="${SCRIPT_DIR}/../cli/biznez-cli"

# Parse version from $1 or env
VERSION="${1:-${VERSION:-}}"
if [ -z "$VERSION" ]; then
    echo "[ERROR] Version required. Usage: $0 <version>" >&2
    echo "        Or set VERSION env var." >&2
    exit 1
fi

# Defaults
OUTPUT_DIR="${OUTPUT_DIR:-./release-output}"
RELEASE_REGISTRY="${RELEASE_REGISTRY:-}"
SIGN_KEY="${SIGN_KEY:-}"
POLICY="${POLICY:-enterprise}"
SKIP_SCAN="${SKIP_SCAN:-false}"
SKIP_SBOM="${SKIP_SBOM:-false}"
SKIP_SIGN="${SKIP_SIGN:-false}"
SKIP_MIRROR="${SKIP_MIRROR:-false}"

# Validate CLI exists
if [ ! -x "$CLI" ]; then
    echo "[ERROR] CLI not found or not executable: $CLI" >&2
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Build argument list
args=(
    build-release
    --version "$VERSION"
    --output-dir "$OUTPUT_DIR"
    --policy "$POLICY"
)

if [ -n "$RELEASE_REGISTRY" ]; then
    args+=(--release-registry "$RELEASE_REGISTRY")
fi

if [ -n "$SIGN_KEY" ]; then
    args+=(--sign-key "$SIGN_KEY")
fi

if [ "$SKIP_SCAN" = "true" ]; then args+=(--skip-scan); fi
if [ "$SKIP_SBOM" = "true" ]; then args+=(--skip-sbom); fi
if [ "$SKIP_SIGN" = "true" ]; then args+=(--skip-sign); fi
if [ "$SKIP_MIRROR" = "true" ]; then args+=(--skip-mirror); fi

# Execute
exec "$CLI" "${args[@]}"
