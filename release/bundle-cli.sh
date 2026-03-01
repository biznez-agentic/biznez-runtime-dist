#!/usr/bin/env bash
# =============================================================================
# bundle-cli.sh -- Bundle biznez-cli + lib/images.sh into single distributable
# =============================================================================
# Usage: bash release/bundle-cli.sh cli/biznez-cli cli/lib/images.sh
#
# Outputs the bundled CLI to stdout. Redirect to file:
#   bash release/bundle-cli.sh cli/biznez-cli cli/lib/images.sh > cli/biznez-cli-bundle
#
# Rules:
#   - Strips source guard block (if ! (return 0 ...); then ... fi) from lib
#   - Strips shebang (#!/usr/bin/env bash) from lib
#   - Inserts lib functions at # === PHASE8_LIB_INSERTION_POINT === marker
# =============================================================================
set -euo pipefail

MAIN_FILE="${1:?Usage: $0 <main-cli> <lib-file>}"
LIB_FILE="${2:?Usage: $0 <main-cli> <lib-file>}"

if [ ! -f "$MAIN_FILE" ]; then
    echo "[ERROR] Main CLI not found: $MAIN_FILE" >&2
    exit 1
fi

if [ ! -f "$LIB_FILE" ]; then
    echo "[ERROR] Lib file not found: $LIB_FILE" >&2
    exit 1
fi

MARKER="# === PHASE8_LIB_INSERTION_POINT ==="

if ! grep -qF "$MARKER" "$MAIN_FILE"; then
    echo "[ERROR] Marker not found in $MAIN_FILE: $MARKER" >&2
    exit 1
fi

# Process lib: strip shebang, source guard block, and leading comments
LIB_CONTENT=$(sed -e '/^#!\/usr\/bin\/env bash/d' \
                  -e '/^# Source guard:/d' \
                  -e '/^# When sourced:/d' \
                  -e '/^# When executed:/d' \
                  -e '/^if ! (return 0 2>\/dev\/null); then$/,/^fi$/d' \
                  -e '/^# ===.*bundle/d' \
              "$LIB_FILE" | sed '/^$/N;/^\n$/d')

# Output: everything before marker, then lib content, then everything after marker
while IFS= read -r line; do
    if [ "$line" = "$MARKER" ]; then
        echo "# --- BEGIN lib/images.sh (bundled) ---"
        echo "$LIB_CONTENT"
        echo "# --- END lib/images.sh (bundled) ---"
    else
        echo "$line"
    fi
done < "$MAIN_FILE"
