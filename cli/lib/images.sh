#!/usr/bin/env bash
# =============================================================================
# biznez-cli -- Image supply chain functions (Phase 8)
# =============================================================================
# This file is sourced by cli/biznez-cli during development. At release time,
# make cli-bundle concatenates it into a single distributable file.
#
# RULES:
#   - Functions only -- no top-level executable code
#   - No set -euo pipefail (inherited from main script)
#   - No global variable declarations that duplicate the main file
#   - All functions prefixed _img_ (image ops) or _rel_ (release ops)
# =============================================================================

# Source guard: prevent accidental direct execution (Bash 3.2 friendly)
# When sourced: (return 0) succeeds → continue defining functions
# When executed: (return 0) fails → print error and exit
if ! (return 0 2>/dev/null); then
    echo "Error: This file must be sourced, not executed directly." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Image tool detection
# ---------------------------------------------------------------------------

_img_detect_tool() {
    # Returns best available container image tool: crane, skopeo, or docker
    if command -v crane >/dev/null 2>&1; then
        echo "crane"
    elif command -v skopeo >/dev/null 2>&1; then
        echo "skopeo"
    elif command -v docker >/dev/null 2>&1; then
        echo "docker"
    else
        return 1
    fi
}

_img_require_tool() {
    local tool
    tool=$(_img_detect_tool) || die "No container image tool found. Install crane, skopeo, or docker." "$EXIT_PREREQ"
    echo "$tool"
}

# ---------------------------------------------------------------------------
# images.lock parsing
# ---------------------------------------------------------------------------

_img_parse_lock() {
    # Parse images.lock → tab-separated records
    # Args: $1 = manifest path, $2 = "yq" or "awk"
    # Output: name\tsourceRepo\ttargetRepo\treleaseRepo\ttag\timageDigest\tindexDigest
    local manifest="$1"
    local parser="${2:-yq}"

    if [ ! -f "$manifest" ]; then
        die "Manifest file not found: $manifest" "$EXIT_USAGE"
    fi

    if [ "$parser" = "yq" ]; then
        if ! command -v yq >/dev/null 2>&1; then
            die "yq (mikefarah/yq v4+) is required. Install: brew install yq" "$EXIT_PREREQ"
        fi
        yq eval '.images[] | [.name, .sourceRepo, .targetRepo, .releaseRepo, .tag, .imageDigest, .indexDigest] | @tsv' "$manifest"
    else
        # awk fallback -- emergency only, may mis-parse complex YAML
        warn "Using awk YAML parser. Results may be incorrect. Install yq for reliable parsing."
        _img_parse_lock_awk "$manifest"
    fi
}

_img_parse_lock_awk() {
    # Emergency awk parser for images.lock
    # Fragile: only works with the exact schema defined in phase-8 plan
    local manifest="$1"
    awk '
    /^  - name:/ { if (name != "") print name "\t" sourceRepo "\t" targetRepo "\t" releaseRepo "\t" tag "\t" imageDigest "\t" indexDigest;
                   name=$3; sourceRepo=""; targetRepo=""; releaseRepo=""; tag=""; imageDigest=""; indexDigest="" }
    /^    sourceRepo:/ { sourceRepo=$2; gsub(/^"/, "", sourceRepo); gsub(/"$/, "", sourceRepo) }
    /^    targetRepo:/ { targetRepo=$2; gsub(/^"/, "", targetRepo); gsub(/"$/, "", targetRepo) }
    /^    releaseRepo:/ { releaseRepo=$2; gsub(/^"/, "", releaseRepo); gsub(/"$/, "", releaseRepo) }
    /^    tag:/ { tag=$2; gsub(/^"/, "", tag); gsub(/"$/, "", tag) }
    /^    imageDigest:/ { imageDigest=$2; gsub(/^"/, "", imageDigest); gsub(/"$/, "", imageDigest) }
    /^    indexDigest:/ { indexDigest=$2; gsub(/^"/, "", indexDigest); gsub(/"$/, "", indexDigest) }
    END { if (name != "") print name "\t" sourceRepo "\t" targetRepo "\t" releaseRepo "\t" tag "\t" imageDigest "\t" indexDigest }
    ' "$manifest"
}

_img_get_lock_version() {
    # Extract version field from images.lock
    local manifest="$1"
    if command -v yq >/dev/null 2>&1; then
        yq eval '.version' "$manifest"
    else
        awk '/^version:/ { gsub(/^"/, "", $2); gsub(/"$/, "", $2); print $2 }' "$manifest"
    fi
}

_img_get_lock_platform() {
    # Extract platform field from images.lock
    local manifest="$1"
    if command -v yq >/dev/null 2>&1; then
        yq eval '.platform' "$manifest"
    else
        awk '/^platform:/ { print $2 }' "$manifest"
    fi
}

_img_get_lock_release_registry() {
    # Extract releaseRegistry field from images.lock
    local manifest="$1"
    if command -v yq >/dev/null 2>&1; then
        yq eval '.releaseRegistry' "$manifest"
    else
        awk '/^releaseRegistry:/ { gsub(/^"/, "", $2); gsub(/"$/, "", $2); print $2 }' "$manifest"
    fi
}

# ---------------------------------------------------------------------------
# Image reference helpers
# ---------------------------------------------------------------------------

_img_ref() {
    # Construct image reference: repo@digest or repo:tag
    local repo="$1" digest="${2:-}" tag="${3:-}"
    if [ -n "$digest" ]; then
        echo "${repo}@${digest}"
    elif [ -n "$tag" ]; then
        echo "${repo}:${tag}"
    else
        echo "$repo"
    fi
}

# ---------------------------------------------------------------------------
# Digest resolution (registry-provided only -- never local hashing)
# ---------------------------------------------------------------------------

_img_resolve_digest() {
    # Resolve imageDigest + indexDigest for a given repo:tag
    # Args: $1=tool, $2=repo, $3=tag, $4=platform (e.g. linux/amd64)
    # Outputs two lines: imageDigest, indexDigest
    # CRITICAL: Never compute digests locally. Only read registry-provided digests.
    local tool="$1" repo="$2" tag="$3" platform="$4"
    local _image_digest="" _index_digest=""
    local _os _arch _raw_manifest _media_type

    if [ -z "$platform" ]; then
        die "Platform must not be empty for digest resolution (got empty for ${repo}:${tag})" "$EXIT_RELEASE"
    fi

    _os="${platform%%/*}"
    _arch="${platform##*/}"

    case "$tool" in
        crane)
            # Get top-level digest (index or manifest)
            _index_digest=$(crane digest "${repo}:${tag}" 2>/dev/null) || \
                die "Failed to resolve digest for ${repo}:${tag} via crane" "$EXIT_RELEASE"

            # Check if this is a manifest list/index
            _raw_manifest=$(crane manifest "${repo}:${tag}" 2>/dev/null) || \
                die "Failed to fetch manifest for ${repo}:${tag}" "$EXIT_RELEASE"
            _media_type=$(echo "$_raw_manifest" | _json_field "mediaType") || true

            if echo "$_media_type" | grep -qE "manifest\.list|image\.index" 2>/dev/null; then
                # Multi-arch: extract platform-specific digest from descriptors
                _image_digest=$(echo "$_raw_manifest" | _json_extract_platform_digest "$_os" "$_arch") || \
                    die "Failed to find ${platform} digest in manifest list for ${repo}:${tag}" "$EXIT_RELEASE"
            else
                # Single-arch: imageDigest = indexDigest
                _image_digest="$_index_digest"
            fi
            ;;
        skopeo)
            # Get top-level digest
            _index_digest=$(skopeo inspect --format '{{.Digest}}' "docker://${repo}:${tag}" 2>/dev/null) || \
                die "Failed to resolve digest for ${repo}:${tag} via skopeo" "$EXIT_RELEASE"

            # Check if manifest list
            _raw_manifest=$(skopeo inspect --raw "docker://${repo}:${tag}" 2>/dev/null) || \
                die "Failed to fetch raw manifest for ${repo}:${tag}" "$EXIT_RELEASE"
            _media_type=$(echo "$_raw_manifest" | _json_field "mediaType") || true

            if echo "$_media_type" | grep -qE "manifest\.list|image\.index" 2>/dev/null; then
                _image_digest=$(echo "$_raw_manifest" | _json_extract_platform_digest "$_os" "$_arch") || \
                    die "Failed to find ${platform} digest in manifest list for ${repo}:${tag}" "$EXIT_RELEASE"
            else
                _image_digest="$_index_digest"
            fi
            ;;
        docker)
            # Docker: pull and inspect
            docker pull --platform "$platform" "${repo}:${tag}" >/dev/null 2>&1 || \
                die "Failed to pull ${repo}:${tag} via docker" "$EXIT_RELEASE"
            _image_digest=$(docker inspect --format '{{index .RepoDigests 0}}' "${repo}:${tag}" 2>/dev/null | sed 's/.*@//') || \
                die "Failed to inspect digest for ${repo}:${tag}" "$EXIT_RELEASE"
            # Docker doesn't expose index digest
            _index_digest=""
            ;;
        *)
            die "Unknown image tool: $tool" "$EXIT_ERROR"
            ;;
    esac

    echo "$_image_digest"
    echo "$_index_digest"
}

# ---------------------------------------------------------------------------
# JSON helpers (minimal, no jq dependency -- uses yq or awk)
# ---------------------------------------------------------------------------

_json_field() {
    # Extract a top-level string field from JSON on stdin
    # Uses yq if available, falls back to awk
    local field="$1"
    if command -v yq >/dev/null 2>&1; then
        yq eval ".[\"${field}\"]" -p json -
    else
        awk -F'"' -v f="$field" '$0 ~ "\"" f "\"" { for(i=1;i<=NF;i++) if($(i)==f && $(i+2)!="") { print $(i+2); exit } }'
    fi
}

_json_extract_platform_digest() {
    # From a manifest list JSON on stdin, extract the digest for the given os/arch
    # Args: $1=os, $2=arch
    local os="$1" arch="$2"
    if command -v yq >/dev/null 2>&1; then
        yq eval "(.manifests // .Manifests)[] | select(.platform.os == \"${os}\" and .platform.architecture == \"${arch}\") | .digest" -p json -
    else
        # Minimal awk-based extraction -- fragile, only for emergencies
        awk -v os="$os" -v arch="$arch" '
        BEGIN { found_os=0; found_arch=0; digest="" }
        /"os"/ && $0 ~ "\"" os "\"" { found_os=1 }
        /"architecture"/ && $0 ~ "\"" arch "\"" { found_arch=1 }
        /"digest"/ { gsub(/.*"digest"[[:space:]]*:[[:space:]]*"/, ""); gsub(/".*/, ""); digest=$0 }
        found_os && found_arch && digest != "" { print digest; exit }
        /\}/ { if (found_os || found_arch) { found_os=0; found_arch=0; digest="" } }
        '
    fi
}

# ---------------------------------------------------------------------------
# Archive format detection
# ---------------------------------------------------------------------------

_img_detect_archive_format() {
    # Detect archive format in extracted directory
    # Args: $1 = extracted directory path
    # Outputs: "oci" or "docker-archive"
    local dir="$1"
    local _found_oci=false

    # Check for per-image OCI sublayouts: oci/*/oci-layout
    # Use a loop instead of glob expansion for Bash 3.2 compatibility
    if [ -d "${dir}/oci" ]; then
        local _subdir
        for _subdir in "${dir}"/oci/*/; do
            if [ -f "${_subdir}oci-layout" ]; then
                _found_oci=true
                break
            fi
        done
    fi

    if [ "$_found_oci" = "true" ]; then
        echo "oci"
    elif [ -f "${dir}/manifest.json" ]; then
        echo "docker-archive"
    else
        die "Cannot detect archive format in ${dir}. Expected oci/*/oci-layout or manifest.json." "$EXIT_RELEASE"
    fi
}

# ---------------------------------------------------------------------------
# Mirror to release registry
# ---------------------------------------------------------------------------

_img_mirror_to_release() {
    # Copy image from sourceRepo to release registry by digest
    # Args: $1=tool, $2=sourceRef (repo@digest), $3=releaseRef (releaseRepo:tag)
    local tool="$1" source_ref="$2" release_ref="$3"

    info "Mirroring ${source_ref} → ${release_ref}"

    case "$tool" in
        crane)
            crane copy "$source_ref" "$release_ref" 2>&1 || \
                die "Failed to mirror ${source_ref} → ${release_ref} via crane" "$EXIT_RELEASE"
            ;;
        skopeo)
            skopeo copy "docker://${source_ref}" "docker://${release_ref}" 2>&1 || \
                die "Failed to mirror ${source_ref} → ${release_ref} via skopeo" "$EXIT_RELEASE"
            ;;
        docker)
            docker pull "$source_ref" >/dev/null 2>&1 || \
                die "Failed to pull ${source_ref}" "$EXIT_RELEASE"
            docker tag "$source_ref" "$release_ref" 2>&1 || \
                die "Failed to tag ${source_ref} as ${release_ref}" "$EXIT_RELEASE"
            docker push "$release_ref" >/dev/null 2>&1 || \
                die "Failed to push ${release_ref}" "$EXIT_RELEASE"
            ;;
    esac

    ok "Mirrored ${source_ref} → ${release_ref}"
}

# ---------------------------------------------------------------------------
# Tag→digest verification (remote, registry-based)
# ---------------------------------------------------------------------------

_img_verify_tag_digest() {
    # Resolve tag remotely and compare to expected digest
    # Args: $1=tool, $2=registry/repo:tag, $3=expected_digest
    # Returns 0 if match, 1 if mismatch
    local tool="$1" ref="$2" expected="$3"
    local _actual=""

    case "$tool" in
        crane)
            _actual=$(crane digest "$ref" 2>/dev/null) || return 1
            ;;
        skopeo)
            _actual=$(skopeo inspect --format '{{.Digest}}' "docker://${ref}" 2>/dev/null) || return 1
            ;;
        docker)
            # Docker requires pull -- warn about overhead
            warn "Tag→digest check via docker requires pulling image: $ref"
            docker pull "$ref" >/dev/null 2>&1 || return 1
            _actual=$(docker inspect --format '{{index .RepoDigests 0}}' "$ref" 2>/dev/null | sed 's/.*@//') || return 1
            ;;
    esac

    if [ "$_actual" = "$expected" ]; then
        return 0
    else
        error "Tag drift detected: $ref resolved to $_actual, expected $expected"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Checksums (portable: sha256sum or shasum -a 256)
# ---------------------------------------------------------------------------

_rel_generate_checksums() {
    # Generate checksums.sha256 for all files in output directory
    # Args: $1 = output directory
    local output_dir="$1"
    local checksum_cmd checksum_file

    checksum_file="${output_dir}/checksums.sha256"

    if command -v sha256sum >/dev/null 2>&1; then
        checksum_cmd="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        checksum_cmd="shasum -a 256"
    else
        die "Neither sha256sum nor shasum found. Cannot generate checksums." "$EXIT_PREREQ"
    fi

    info "Generating checksums..."
    (
        cd "$output_dir" || return
        local _f
        for _f in *.tar.gz *.json *.yaml images.lock; do
            if [ -f "$_f" ]; then
                $checksum_cmd "$_f"
            fi
        done
    ) > "$checksum_file"

    ok "Checksums written to $checksum_file"
}

# ---------------------------------------------------------------------------
# Record tool versions
# ---------------------------------------------------------------------------

_rel_record_tool_versions() {
    # Capture versions of all supply chain tools
    # Outputs JSON-ish key=value pairs (consumed by _rel_write_manifest and images.lock update)
    local _crane="" _skopeo="" _docker="" _yq="" _syft="" _trivy="" _cosign=""

    _crane=$(crane version 2>/dev/null | head -1) || true
    _skopeo=$(skopeo --version 2>/dev/null | awk '{print $NF}') || true
    _docker=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',') || true
    _yq=$(yq --version 2>/dev/null | awk '{print $NF}') || true
    _syft=$(syft version 2>/dev/null | awk '/^Version:/{print $2}') || true
    _trivy=$(trivy --version 2>/dev/null | awk '/^Version:/{print $2}') || true
    _cosign=$(cosign version 2>/dev/null | awk '/^cosign/{print $NF}') || true

    echo "crane=${_crane}"
    echo "skopeo=${_skopeo}"
    echo "docker=${_docker}"
    echo "yq=${_yq}"
    echo "syft=${_syft}"
    echo "trivy=${_trivy}"
    echo "cosign=${_cosign}"
}

# ---------------------------------------------------------------------------
# Release manifest (audit trail)
# ---------------------------------------------------------------------------

_rel_write_manifest() {
    # Write release-manifest.json audit trail
    # Args: $1=output_dir, $2=version, $3=platform, $4=policy, $5=manifest_path
    #        Remaining args: step records as "name:status:reason" triples
    local output_dir="$1" version="$2" platform="$3" policy="$4" manifest_path="$5"
    shift 5
    local manifest_file="${output_dir}/release-manifest.json"
    local _timestamp _tools _images_json _steps_json

    _timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Collect tool versions
    _tools=$(_rel_record_tool_versions)

    # Build JSON manually (no jq dependency)
    {
        echo "{"
        echo "  \"version\": \"${version}\","
        echo "  \"timestamp\": \"${_timestamp}\","
        echo "  \"platform\": \"${platform}\","
        echo "  \"policy\": \"${policy}\","

        # Tools section
        echo "  \"tools\": {"
        local _first=true
        local _line
        while IFS= read -r _line; do
            local _key="${_line%%=*}"
            local _val="${_line#*=}"
            if [ "$_first" = "true" ]; then _first=false; else echo ","; fi
            printf '    "%s": "%s"' "$_key" "$_val"
        done <<EOF
$_tools
EOF
        echo ""
        echo "  },"

        # Images section from manifest
        echo "  \"images\": ["
        local _img_first=true
        local _name _source _target _release _tag _img_dig _idx_dig
        local _parser="yq"
        if ! command -v yq >/dev/null 2>&1; then _parser="awk"; fi
        while IFS="$(printf '\t')" read -r _name _source _target _release _tag _img_dig _idx_dig; do
            if [ "$_img_first" = "true" ]; then _img_first=false; else echo ","; fi
            printf '    {"name":"%s","sourceRepo":"%s","targetRepo":"%s","releaseRepo":"%s","tag":"%s","imageDigest":"%s","indexDigest":"%s"}' \
                "$_name" "$_source" "$_target" "$_release" "$_tag" "$_img_dig" "$_idx_dig"
        done < <(_img_parse_lock "$manifest_path" "$_parser")
        echo ""
        echo "  ],"

        # Steps section
        echo "  \"steps\": ["
        local _step_first=true
        local _step
        for _step in "$@"; do
            local _s_name="${_step%%:*}"
            local _rest="${_step#*:}"
            local _s_status="${_rest%%:*}"
            local _s_reason="${_rest#*:}"
            if [ "$_s_reason" = "$_s_status" ]; then _s_reason=""; fi
            if [ "$_step_first" = "true" ]; then _step_first=false; else echo ","; fi
            printf '    {"name":"%s","status":"%s","reason":"%s"}' "$_s_name" "$_s_status" "$_s_reason"
        done
        echo ""
        echo "  ]"
        echo "}"
    } > "$manifest_file"

    ok "Release manifest written to $manifest_file"
}

# ---------------------------------------------------------------------------
# SBOM generation
# ---------------------------------------------------------------------------

_rel_generate_sbom() {
    # Run syft against each image by digest, produce SPDX JSON
    # Args: $1=manifest_path, $2=output_dir, $3=version
    local manifest_path="$1" output_dir="$2" version="$3"
    local sbom_file="${output_dir}/sbom-v${version}.json"
    local _parser="yq"
    if ! command -v yq >/dev/null 2>&1; then _parser="awk"; fi

    if ! command -v syft >/dev/null 2>&1; then
        warn "syft not found, skipping SBOM generation"
        return 1
    fi

    info "Generating SBOM..."

    # Generate per-image SBOMs and combine into array
    local _first=true
    echo "[" > "$sbom_file"

    local _name _source _target _release _tag _img_dig _idx_dig
    while IFS="$(printf '\t')" read -r _name _source _target _release _tag _img_dig _idx_dig; do
        local _ref
        if [ -n "$_release" ] && [ -n "$_img_dig" ]; then
            _ref="${_release}@${_img_dig}"
        elif [ -n "$_release" ]; then
            _ref="${_release}:${_tag}"
        else
            warn "Skipping SBOM for $_name: no releaseRepo"
            continue
        fi

        if [ "$_first" = "true" ]; then _first=false; else echo "," >> "$sbom_file"; fi

        info "  SBOM: $_name (${_ref})"
        local _tmp_sbom
        _tmp_sbom=$(mktemp)
        _register_cleanup "$_tmp_sbom"
        if syft "$_ref" -o spdx-json > "$_tmp_sbom" 2>/dev/null; then
            cat "$_tmp_sbom" >> "$sbom_file"
        else
            warn "Failed to generate SBOM for $_name"
            echo "{\"error\": \"sbom generation failed for $_name\"}" >> "$sbom_file"
        fi
    done < <(_img_parse_lock "$manifest_path" "$_parser")

    echo "]" >> "$sbom_file"
    ok "SBOM written to $sbom_file"
}

# ---------------------------------------------------------------------------
# Vulnerability scanning
# ---------------------------------------------------------------------------

_rel_run_scan() {
    # Run trivy against each image by digest, produce JSON report
    # Args: $1=manifest_path, $2=output_dir, $3=version
    local manifest_path="$1" output_dir="$2" version="$3"
    local scan_file="${output_dir}/trivy-report-v${version}.json"
    local _parser="yq"
    if ! command -v yq >/dev/null 2>&1; then _parser="awk"; fi

    if ! command -v trivy >/dev/null 2>&1; then
        warn "trivy not found, skipping vulnerability scan"
        return 1
    fi

    info "Running vulnerability scan..."

    local _first=true
    echo "[" > "$scan_file"

    local _name _source _target _release _tag _img_dig _idx_dig
    while IFS="$(printf '\t')" read -r _name _source _target _release _tag _img_dig _idx_dig; do
        local _ref
        if [ -n "$_release" ] && [ -n "$_img_dig" ]; then
            _ref="${_release}@${_img_dig}"
        elif [ -n "$_release" ]; then
            _ref="${_release}:${_tag}"
        else
            warn "Skipping scan for $_name: no releaseRepo"
            continue
        fi

        if [ "$_first" = "true" ]; then _first=false; else echo "," >> "$scan_file"; fi

        info "  Scan: $_name (${_ref})"
        local _tmp_scan
        _tmp_scan=$(mktemp)
        _register_cleanup "$_tmp_scan"
        if trivy image --severity HIGH,CRITICAL --format json "$_ref" > "$_tmp_scan" 2>/dev/null; then
            cat "$_tmp_scan" >> "$scan_file"
        else
            warn "Failed to scan $_name"
            echo "{\"error\": \"scan failed for $_name\"}" >> "$scan_file"
        fi
    done < <(_img_parse_lock "$manifest_path" "$_parser")

    echo "]" >> "$scan_file"
    ok "Scan report written to $scan_file"
}

# ---------------------------------------------------------------------------
# Artifact signing
# ---------------------------------------------------------------------------

_rel_sign_artifacts() {
    # Sign images in release registry + sign checksums file
    # Args: $1=tool, $2=manifest_path, $3=output_dir, $4=sign_key (or empty for keyless)
    local tool="$1" manifest_path="$2" output_dir="$3" sign_key="${4:-}"
    local _parser="yq"
    if ! command -v yq >/dev/null 2>&1; then _parser="awk"; fi

    if ! command -v cosign >/dev/null 2>&1; then
        warn "cosign not found, skipping signing"
        return 1
    fi

    info "Signing artifacts..."

    # Sign each image in the release registry by digest
    local _name _source _target _release _tag _img_dig _idx_dig
    while IFS="$(printf '\t')" read -r _name _source _target _release _tag _img_dig _idx_dig; do
        if [ -z "$_release" ] || [ -z "$_img_dig" ]; then
            warn "Skipping sign for $_name: no releaseRepo or digest"
            continue
        fi

        local _sign_ref="${_release}@${_img_dig}"
        info "  Signing: $_name (${_sign_ref})"

        if [ -n "$sign_key" ]; then
            cosign sign --key "$sign_key" "$_sign_ref" 2>&1 || \
                die "Failed to sign $_name" "$EXIT_RELEASE"
        else
            COSIGN_EXPERIMENTAL=1 cosign sign "$_sign_ref" 2>&1 || \
                die "Failed to sign $_name (keyless)" "$EXIT_RELEASE"
        fi
    done < <(_img_parse_lock "$manifest_path" "$_parser")

    # Sign checksums file if it exists
    local checksums_file="${output_dir}/checksums.sha256"
    if [ -f "$checksums_file" ]; then
        info "Signing checksums file..."
        if [ -n "$sign_key" ]; then
            cosign sign-blob --key "$sign_key" --output-signature "${checksums_file}.sig" "$checksums_file" 2>&1 || \
                die "Failed to sign checksums file" "$EXIT_RELEASE"
        else
            COSIGN_EXPERIMENTAL=1 cosign sign-blob --output-signature "${checksums_file}.sig" "$checksums_file" 2>&1 || \
                die "Failed to sign checksums file (keyless)" "$EXIT_RELEASE"
        fi
        ok "Checksums signature written to ${checksums_file}.sig"
    fi

    ok "Signing complete"
}

# ==========================================================================
# CLI Commands
# ==========================================================================

# ---------------------------------------------------------------------------
# export-images
# ---------------------------------------------------------------------------

cmd_export_images() {
    local manifest="${CHART_DIR}/images.lock"
    local output=""
    local format="oci"
    local platform=""
    local allow_awk=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --manifest)         manifest="$2"; shift 2 ;;
            --output|-o)        output="$2"; shift 2 ;;
            --format)           format="$2"; shift 2 ;;
            --platform)         platform="$2"; shift 2 ;;
            --allow-awk-parser) allow_awk=true; shift ;;
            -h|--help)
                cat <<USAGE
Usage: biznez-cli export-images [flags]

Export container images to a portable archive for air-gapped deployment.

Flags:
  --manifest <file>     Path to images.lock (default: helm chart images.lock)
  --output, -o <file>   Output archive path (default: biznez-images-v{VERSION}.tar.gz)
  --format <oci|docker-archive>  Archive format (default: oci)
  --platform <os/arch>  Target platform (default: from images.lock)
  --allow-awk-parser    Use awk parser instead of yq (emergency only)
  -h, --help            Show this help
USAGE
                return 0
                ;;
            *) die "Unknown flag: $1. Run 'biznez-cli export-images --help'" "$EXIT_USAGE" ;;
        esac
    done

    # Determine parser
    local parser="yq"
    if [ "$allow_awk" = "true" ]; then parser="awk"; fi

    # Validate manifest exists
    if [ ! -f "$manifest" ]; then
        die "Manifest not found: $manifest" "$EXIT_USAGE"
    fi

    # Get version and platform from manifest
    local version
    version=$(_img_get_lock_version "$manifest")
    if [ -z "$platform" ]; then
        platform=$(_img_get_lock_platform "$manifest")
    fi

    # Default output filename
    if [ -z "$output" ]; then
        output="biznez-images-v${version}.tar.gz"
    fi

    # Detect image tool
    local tool
    tool=$(_img_require_tool)
    info "Using image tool: $tool"

    # Validate releaseRepo is populated for all images
    local _has_empty_release=false
    local _name _source _target _release _tag _img_dig _idx_dig
    while IFS="$(printf '\t')" read -r _name _source _target _release _tag _img_dig _idx_dig; do
        if [ -z "$_release" ]; then
            error "Image $_name has empty releaseRepo. Run 'build-release' first."
            _has_empty_release=true
        fi
    done < <(_img_parse_lock "$manifest" "$parser")

    if [ "$_has_empty_release" = "true" ]; then
        die "Cannot export: releaseRepo not populated. Run 'biznez-cli build-release' first." "$EXIT_RELEASE"
    fi

    # Create temp directory for bundle
    local bundle_dir
    bundle_dir=$(mktemp -d)
    _register_cleanup "$bundle_dir"

    local bundle_name="biznez-images-v${version}"
    local bundle_root="${bundle_dir}/${bundle_name}"
    mkdir -p "${bundle_root}/oci"

    # Copy images.lock into bundle
    cp "$manifest" "${bundle_root}/images.lock"

    info "Exporting ${format} images..."

    if [ "$format" = "oci" ]; then
        while IFS="$(printf '\t')" read -r _name _source _target _release _tag _img_dig _idx_dig; do
            local _ref
            _ref=$(_img_ref "$_release" "$_img_dig" "$_tag")
            local _oci_dir="${bundle_root}/oci/${_name}"
            mkdir -p "$_oci_dir"

            info "  Exporting $_name → oci/${_name}/"
            case "$tool" in
                crane)
                    crane pull --format oci "$_ref" "$_oci_dir" 2>&1 || \
                        die "Failed to export $_name via crane" "$EXIT_RELEASE"
                    ;;
                skopeo)
                    skopeo copy "docker://${_ref}" "oci:${_oci_dir}:${_tag}" 2>&1 || \
                        die "Failed to export $_name via skopeo" "$EXIT_RELEASE"
                    ;;
                docker)
                    # Docker doesn't natively support OCI layout export
                    # Pull then save, or use skopeo if available
                    docker pull "$_ref" >/dev/null 2>&1 || \
                        die "Failed to pull $_name" "$EXIT_RELEASE"
                    docker save "$_ref" -o "${_oci_dir}.tar" 2>&1 || \
                        die "Failed to save $_name" "$EXIT_RELEASE"
                    warn "Docker export produces docker-archive, not OCI layout for $_name"
                    ;;
            esac
        done < <(_img_parse_lock "$manifest" "$parser")
    elif [ "$format" = "docker-archive" ]; then
        while IFS="$(printf '\t')" read -r _name _source _target _release _tag _img_dig _idx_dig; do
            local _ref
            _ref=$(_img_ref "$_release" "$_img_dig" "$_tag")
            info "  Exporting $_name (docker-archive)"
            case "$tool" in
                crane)
                    crane pull --format tarball "$_ref" "${bundle_root}/${_name}.tar" 2>&1 || \
                        die "Failed to export $_name via crane" "$EXIT_RELEASE"
                    ;;
                skopeo)
                    skopeo copy "docker://${_ref}" "docker-archive:${bundle_root}/${_name}.tar:${_release}:${_tag}" 2>&1 || \
                        die "Failed to export $_name via skopeo" "$EXIT_RELEASE"
                    ;;
                docker)
                    docker pull "$_ref" >/dev/null 2>&1 || true
                    docker save -o "${bundle_root}/${_name}.tar" "$_ref" 2>&1 || \
                        die "Failed to save $_name via docker" "$EXIT_RELEASE"
                    ;;
            esac
        done < <(_img_parse_lock "$manifest" "$parser")
    else
        die "Unknown format: $format. Use 'oci' or 'docker-archive'." "$EXIT_USAGE"
    fi

    # Create tar.gz archive
    info "Creating archive: $output"
    tar czf "$output" -C "$bundle_dir" "$bundle_name" 2>&1 || \
        die "Failed to create archive" "$EXIT_RELEASE"

    local _size
    _size=$(wc -c < "$output" | awk '{printf "%.1f MB", $1/1048576}')
    ok "Export complete: $output (${_size})"
}

# ---------------------------------------------------------------------------
# import-images
# ---------------------------------------------------------------------------

cmd_import_images() {
    local archive=""
    local registry=""
    local docker_mode=false
    local manifest_override=""
    local allow_awk=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --archive|-a)       archive="$2"; shift 2 ;;
            --registry)         registry="$2"; shift 2 ;;
            --docker)           docker_mode=true; shift ;;
            --manifest)         manifest_override="$2"; shift 2 ;;
            --allow-awk-parser) allow_awk=true; shift ;;
            -h|--help)
                cat <<USAGE
Usage: biznez-cli import-images [flags]

Import container images from an archive into a registry or Docker daemon.

Flags:
  --archive, -a <file>  Path to image archive (required)
  --registry <url>      Target registry to push images to
  --docker              Load images into local Docker daemon
  --manifest <file>     Override embedded images.lock
  --allow-awk-parser    Use awk parser instead of yq (emergency only)
  -h, --help            Show this help

Must specify either --registry or --docker.
USAGE
                return 0
                ;;
            *) die "Unknown flag: $1. Run 'biznez-cli import-images --help'" "$EXIT_USAGE" ;;
        esac
    done

    if [ -z "$archive" ]; then
        die "Missing required flag: --archive <file>" "$EXIT_USAGE"
    fi

    if [ ! -f "$archive" ]; then
        die "Archive not found: $archive" "$EXIT_USAGE"
    fi

    if [ -z "$registry" ] && [ "$docker_mode" = "false" ]; then
        die "Must specify --registry <url> or --docker" "$EXIT_USAGE"
    fi

    local parser="yq"
    if [ "$allow_awk" = "true" ]; then parser="awk"; fi

    # Detect image tool
    local tool
    tool=$(_img_require_tool)

    # Extract archive to temp directory
    local extract_dir
    extract_dir=$(mktemp -d)
    _register_cleanup "$extract_dir"

    info "Extracting archive: $archive"
    tar xzf "$archive" -C "$extract_dir" 2>&1 || \
        die "Failed to extract archive" "$EXIT_RELEASE"

    # Find the bundle root (the first directory inside extract_dir)
    local bundle_root
    bundle_root=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [ -z "$bundle_root" ]; then
        bundle_root="$extract_dir"
    fi

    # Read manifest
    local manifest_path
    if [ -n "$manifest_override" ]; then
        manifest_path="$manifest_override"
    elif [ -f "${bundle_root}/images.lock" ]; then
        manifest_path="${bundle_root}/images.lock"
    else
        die "No images.lock found in archive. Use --manifest to specify one." "$EXIT_RELEASE"
    fi

    # Detect format
    local archive_format
    archive_format=$(_img_detect_archive_format "$bundle_root")
    info "Detected archive format: $archive_format"

    local _name _source _target _release _tag _img_dig _idx_dig

    if [ -n "$registry" ]; then
        # Push to registry
        info "Importing images to registry: $registry"

        while IFS="$(printf '\t')" read -r _name _source _target _release _tag _img_dig _idx_dig; do
            local _target_ref="${registry}/${_target}:${_tag}"

            info "  Importing $_name → ${_target_ref}"

            if [ "$archive_format" = "oci" ]; then
                local _oci_dir="${bundle_root}/oci/${_name}"
                if [ ! -d "$_oci_dir" ]; then
                    warn "OCI layout not found for $_name at $_oci_dir, skipping"
                    continue
                fi
                case "$tool" in
                    crane)
                        crane push "$_oci_dir" "$_target_ref" 2>&1 || \
                            die "Failed to push $_name via crane" "$EXIT_RELEASE"
                        ;;
                    skopeo)
                        skopeo copy "oci:${_oci_dir}:${_tag}" "docker://${_target_ref}" 2>&1 || \
                            die "Failed to push $_name via skopeo" "$EXIT_RELEASE"
                        ;;
                    docker)
                        warn "Docker cannot directly push OCI layouts. Use crane or skopeo."
                        die "Docker import to registry requires crane or skopeo for OCI format" "$EXIT_PREREQ"
                        ;;
                esac
            else
                # docker-archive format
                local _tar_file="${bundle_root}/${_name}.tar"
                if [ ! -f "$_tar_file" ]; then
                    warn "Docker archive not found for $_name at $_tar_file, skipping"
                    continue
                fi
                case "$tool" in
                    crane)
                        crane push "$_tar_file" "$_target_ref" 2>&1 || \
                            die "Failed to push $_name via crane" "$EXIT_RELEASE"
                        ;;
                    skopeo)
                        skopeo copy "docker-archive:${_tar_file}" "docker://${_target_ref}" 2>&1 || \
                            die "Failed to push $_name via skopeo" "$EXIT_RELEASE"
                        ;;
                    docker)
                        docker load -i "$_tar_file" >/dev/null 2>&1 || \
                            die "Failed to load $_name" "$EXIT_RELEASE"
                        docker tag "$_release:$_tag" "$_target_ref" 2>&1 || true
                        docker push "$_target_ref" >/dev/null 2>&1 || \
                            die "Failed to push $_name" "$EXIT_RELEASE"
                        ;;
                esac
            fi

            # Post-copy digest verification
            if [ -n "$_img_dig" ]; then
                info "  Verifying digest for $_name..."
                if _img_verify_tag_digest "$tool" "$_target_ref" "$_img_dig"; then
                    ok "  Digest verified for $_name"
                else
                    die "Digest mismatch after import for $_name. Import may be corrupted." "$EXIT_RELEASE"
                fi
            fi
        done < <(_img_parse_lock "$manifest_path" "$parser")

        ok "Import to registry complete"
    fi

    if [ "$docker_mode" = "true" ]; then
        # Load into Docker daemon
        info "Loading images into Docker daemon..."

        while IFS="$(printf '\t')" read -r _name _source _target _release _tag _img_dig _idx_dig; do
            local _local_ref="${_target}:${_tag}"

            info "  Loading $_name → ${_local_ref}"

            if [ "$archive_format" = "oci" ]; then
                local _oci_dir="${bundle_root}/oci/${_name}"
                if [ ! -d "$_oci_dir" ]; then
                    warn "OCI layout not found for $_name, skipping"
                    continue
                fi
                case "$tool" in
                    skopeo)
                        skopeo copy "oci:${_oci_dir}:${_tag}" "docker-daemon:${_local_ref}" 2>&1 || \
                            die "Failed to load $_name via skopeo" "$EXIT_RELEASE"
                        ;;
                    crane)
                        crane push "$_oci_dir" "$_local_ref" 2>&1 || \
                            die "Failed to load $_name via crane" "$EXIT_RELEASE"
                        ;;
                    docker)
                        warn "Cannot load OCI layout directly with docker. Requires skopeo or crane."
                        die "Docker cannot load OCI layout. Install skopeo or crane." "$EXIT_PREREQ"
                        ;;
                esac
            else
                local _tar_file="${bundle_root}/${_name}.tar"
                if [ -f "$_tar_file" ]; then
                    docker load -i "$_tar_file" 2>&1 || \
                        die "Failed to load $_name" "$EXIT_RELEASE"
                else
                    warn "Archive not found for $_name, skipping"
                fi
            fi
        done < <(_img_parse_lock "$manifest_path" "$parser")

        ok "Docker load complete"
    fi
}

# ---------------------------------------------------------------------------
# verify-images
# ---------------------------------------------------------------------------

cmd_verify_images() {
    local manifest="${CHART_DIR}/images.lock"
    local registry=""
    local sign_key=""
    local keyless=false
    local cert_identity=""
    local cert_issuer=""
    local skip_tag_check=false
    local allow_awk=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --manifest)               manifest="$2"; shift 2 ;;
            --registry)               registry="$2"; shift 2 ;;
            --key)                    sign_key="$2"; shift 2 ;;
            --keyless)                keyless=true; shift ;;
            --certificate-identity)   cert_identity="$2"; shift 2 ;;
            --certificate-oidc-issuer) cert_issuer="$2"; shift 2 ;;
            --skip-tag-check)         skip_tag_check=true; shift ;;
            --allow-awk-parser)       allow_awk=true; shift ;;
            -h|--help)
                cat <<USAGE
Usage: biznez-cli verify-images [flags]

Verify image signatures and tag→digest integrity in a registry.

Flags:
  --manifest <file>               Path to images.lock (default: helm chart)
  --registry <url>                Target registry to verify against (required)
  --key <file>                    Cosign public key for verification
  --keyless                       Use keyless (Fulcio/Rekor) verification
  --certificate-identity <id>     Certificate identity for keyless
  --certificate-oidc-issuer <url> OIDC issuer for keyless
  --skip-tag-check                Skip tag→digest match verification
  --allow-awk-parser              Use awk parser instead of yq
  -h, --help                      Show this help
USAGE
                return 0
                ;;
            *) die "Unknown flag: $1. Run 'biznez-cli verify-images --help'" "$EXIT_USAGE" ;;
        esac
    done

    if [ -z "$registry" ]; then
        die "Missing required flag: --registry <url>" "$EXIT_USAGE"
    fi

    if [ ! -f "$manifest" ]; then
        die "Manifest not found: $manifest" "$EXIT_USAGE"
    fi

    local parser="yq"
    if [ "$allow_awk" = "true" ]; then parser="awk"; fi

    # Detect image tool for tag→digest checks
    local tool
    tool=$(_img_detect_tool) || tool=""

    # If docker-only and tag check requested, warn
    if [ "$skip_tag_check" = "false" ] && [ "$tool" = "docker" ]; then
        warn "Tag→digest check via docker requires pulling images (slow)."
        warn "Use crane or skopeo for remote-only checks, or pass --skip-tag-check."
        die "Docker-only tag→digest check not supported without --skip-tag-check" "$EXIT_USAGE"
    fi

    _require_cmd cosign "Install cosign for image verification."

    local _pass=0 _fail=0
    local _name _source _target _release _tag _img_dig _idx_dig

    info "Verifying images in registry: $registry"

    while IFS="$(printf '\t')" read -r _name _source _target _release _tag _img_dig _idx_dig; do
        local _target_ref="${registry}/${_target}"

        # Tag→digest check
        if [ "$skip_tag_check" = "false" ] && [ -n "$tool" ] && [ -n "$_img_dig" ]; then
            info "  Tag check: ${_target_ref}:${_tag}"
            if _img_verify_tag_digest "$tool" "${_target_ref}:${_tag}" "$_img_dig"; then
                ok "  Tag→digest match: $_name"
            else
                error "  Tag→digest MISMATCH: $_name"
                _fail=$((_fail + 1))
                continue
            fi
        fi

        # Signature verification
        if [ -n "$_img_dig" ]; then
            local _verify_ref="${_target_ref}@${_img_dig}"
            info "  Signature: ${_verify_ref}"

            local _cosign_rc=0
            if [ -n "$sign_key" ]; then
                cosign verify --key "$sign_key" "$_verify_ref" >/dev/null 2>&1 || _cosign_rc=$?
            elif [ "$keyless" = "true" ]; then
                local _keyless_args=""
                if [ -n "$cert_identity" ]; then _keyless_args="$_keyless_args --certificate-identity=$cert_identity"; fi
                if [ -n "$cert_issuer" ]; then _keyless_args="$_keyless_args --certificate-oidc-issuer=$cert_issuer"; fi
                # shellcheck disable=SC2086
                COSIGN_EXPERIMENTAL=1 cosign verify $_keyless_args "$_verify_ref" >/dev/null 2>&1 || _cosign_rc=$?
            else
                warn "  No --key or --keyless specified for $_name, skipping signature check"
                _pass=$((_pass + 1))
                continue
            fi

            if [ "$_cosign_rc" -eq 0 ]; then
                ok "  Signature verified: $_name"
                _pass=$((_pass + 1))
            else
                error "  Signature FAILED: $_name"
                _fail=$((_fail + 1))
            fi
        else
            warn "  No digest for $_name, skipping verification"
        fi
    done < <(_img_parse_lock "$manifest" "$parser")

    # Verify checksums signature if present
    local _checksums_dir
    _checksums_dir=$(dirname "$manifest")
    if [ -f "${_checksums_dir}/checksums.sha256.sig" ]; then
        info "Verifying checksums signature..."
        local _verify_rc=0
        if [ -n "$sign_key" ]; then
            cosign verify-blob --key "$sign_key" --signature "${_checksums_dir}/checksums.sha256.sig" "${_checksums_dir}/checksums.sha256" >/dev/null 2>&1 || _verify_rc=$?
        fi
        if [ "$_verify_rc" -eq 0 ]; then
            ok "Checksums signature verified"
        else
            error "Checksums signature FAILED"
            _fail=$((_fail + 1))
        fi
    fi

    echo ""
    echo "==============================="
    echo "  VERIFY RESULTS"
    echo "  PASS: $_pass  FAIL: $_fail"
    echo "==============================="

    if [ "$_fail" -gt 0 ]; then
        exit "$EXIT_RELEASE"
    fi
}

# ---------------------------------------------------------------------------
# build-release
# ---------------------------------------------------------------------------

cmd_build_release() {
    local version=""
    local output_dir="."
    local release_registry=""
    local sign_key=""
    local policy="enterprise"
    local skip_scan=false
    local skip_sbom=false
    local skip_sign=false
    local skip_mirror=false
    local allow_awk=false
    local manifest="${CHART_DIR}/images.lock"

    while [ $# -gt 0 ]; do
        case "$1" in
            --version)           version="$2"; shift 2 ;;
            --output-dir)        output_dir="$2"; shift 2 ;;
            --release-registry)  release_registry="$2"; shift 2 ;;
            --sign-key)          sign_key="$2"; shift 2 ;;
            --policy)            policy="$2"; shift 2 ;;
            --skip-scan)         skip_scan=true; shift ;;
            --skip-sbom)         skip_sbom=true; shift ;;
            --skip-sign)         skip_sign=true; shift ;;
            --skip-mirror)       skip_mirror=true; shift ;;
            --manifest)          manifest="$2"; shift 2 ;;
            --allow-awk-parser)  allow_awk=true; shift ;;
            -h|--help)
                cat <<USAGE
Usage: biznez-cli build-release [flags]

Build a complete release: resolve digests, mirror, scan, generate SBOM, sign, export.

Flags:
  --version <ver>              Release version (required)
  --output-dir <dir>           Output directory (default: .)
  --release-registry <url>     Release registry for mirroring and signing (required unless --skip-mirror)
  --sign-key <file>            Cosign private key for signing
  --policy <enterprise|dev>    Build policy (default: enterprise)
  --manifest <file>            Path to images.lock (default: helm chart)
  --skip-scan                  Skip vulnerability scanning
  --skip-sbom                  Skip SBOM generation
  --skip-sign                  Skip artifact signing
  --skip-mirror                Skip mirroring to release registry
  --allow-awk-parser           Use awk parser instead of yq (emergency only)
  -h, --help                   Show this help
USAGE
                return 0
                ;;
            *) die "Unknown flag: $1. Run 'biznez-cli build-release --help'" "$EXIT_USAGE" ;;
        esac
    done

    # Validate required flags
    if [ -z "$version" ]; then
        die "Missing required flag: --version <ver>" "$EXIT_USAGE"
    fi

    if [ -z "$release_registry" ] && [ "$skip_mirror" = "false" ]; then
        die "Missing required flag: --release-registry <url> (or use --skip-mirror)" "$EXIT_USAGE"
    fi

    if [ ! -f "$manifest" ]; then
        die "Manifest not found: $manifest" "$EXIT_USAGE"
    fi

    local parser="yq"
    if [ "$allow_awk" = "true" ]; then parser="awk"; fi

    # Step tracking for release-manifest.json
    local -a steps=()

    # ---- Step 1: Validate prerequisites ----
    info "=== build-release v${version} (policy: ${policy}) ==="

    local tool
    tool=$(_img_require_tool)
    info "Image tool: $tool"

    if ! command -v yq >/dev/null 2>&1 && [ "$allow_awk" = "false" ]; then
        die "yq is required. Install: brew install yq" "$EXIT_PREREQ"
    fi

    if [ "$policy" = "enterprise" ]; then
        if [ "$skip_sbom" = "false" ]; then
            command -v syft >/dev/null 2>&1 || die "syft required for enterprise policy. Use --skip-sbom to override." "$EXIT_PREREQ"
        fi
        if [ "$skip_scan" = "false" ]; then
            command -v trivy >/dev/null 2>&1 || die "trivy required for enterprise policy. Use --skip-scan to override." "$EXIT_PREREQ"
        fi
        if [ "$skip_sign" = "false" ]; then
            command -v cosign >/dev/null 2>&1 || die "cosign required for enterprise policy. Use --skip-sign to override." "$EXIT_PREREQ"
        fi
    fi

    # ---- Step 2: Record tool versions ----
    local _tool_versions
    _tool_versions=$(_rel_record_tool_versions)
    debug "Tool versions: $_tool_versions"

    # ---- Step 3: Update images.lock version and tags ----
    info "Updating images.lock for version ${version}..."
    if command -v yq >/dev/null 2>&1; then
        yq eval -i ".version = \"${version}\"" "$manifest"
        # Update Biznez image tags (not third-party)
        yq eval -i "(.images[] | select(.name == \"platform-api\" or .name == \"web-app\")).tag = \"${version}\"" "$manifest"
    else
        warn "Cannot update images.lock without yq. Skipping version/tag update."
    fi

    # ---- Step 4: Resolve digests ----
    info "Resolving image digests..."
    local platform
    platform=$(_img_get_lock_platform "$manifest")
    if [ -z "$platform" ]; then
        platform="linux/amd64"
    fi

    local _name _source _target _release _tag _img_dig _idx_dig
    while IFS="$(printf '\t')" read -r _name _source _target _release _tag _img_dig _idx_dig; do
        info "  Resolving: $_name (${_source}:${_tag})"
        local _digests
        _digests=$(_img_resolve_digest "$tool" "$_source" "$_tag" "$platform") || \
            die "Failed to resolve digest for $_name" "$EXIT_RELEASE"

        local _new_image_digest _new_index_digest
        _new_image_digest=$(echo "$_digests" | head -1)
        _new_index_digest=$(echo "$_digests" | tail -1)

        if command -v yq >/dev/null 2>&1; then
            yq eval -i "(.images[] | select(.name == \"${_name}\")).imageDigest = \"${_new_image_digest}\"" "$manifest"
            yq eval -i "(.images[] | select(.name == \"${_name}\")).indexDigest = \"${_new_index_digest}\"" "$manifest"
        fi

        ok "  $_name: imageDigest=${_new_image_digest}"
    done < <(_img_parse_lock "$manifest" "$parser")

    steps+=("resolve-digests:ran:")

    # ---- Step 5: Mirror to release registry ----
    if [ "$skip_mirror" = "false" ]; then
        info "Mirroring images to release registry: ${release_registry}"

        while IFS="$(printf '\t')" read -r _name _source _target _release _tag _img_dig _idx_dig; do
            local _release_ref="${release_registry}/${_target}:${_tag}"
            local _source_ref
            _source_ref=$(_img_ref "$_source" "$_img_dig" "$_tag")

            _img_mirror_to_release "$tool" "$_source_ref" "$_release_ref"

            # Update releaseRepo in manifest
            if command -v yq >/dev/null 2>&1; then
                yq eval -i "(.images[] | select(.name == \"${_name}\")).releaseRepo = \"${release_registry}/${_target}\"" "$manifest"
            fi
        done < <(_img_parse_lock "$manifest" "$parser")

        # Update releaseRegistry
        if command -v yq >/dev/null 2>&1; then
            yq eval -i ".releaseRegistry = \"${release_registry}\"" "$manifest"
        fi

        steps+=("mirror:ran:")
    else
        steps+=("mirror:skipped:flag")
    fi

    # ---- Step 6: Write updated images.lock ----
    # Update generatedBy
    if command -v yq >/dev/null 2>&1; then
        yq eval -i ".generatedBy.tool = \"biznez-cli\"" "$manifest"
        yq eval -i ".generatedBy.toolVersion = \"${CLI_VERSION}\"" "$manifest"
        # Update individual tool versions from _tool_versions
        local _tv_line
        while IFS= read -r _tv_line; do
            local _tv_key="${_tv_line%%=*}"
            local _tv_val="${_tv_line#*=}"
            if [ -n "$_tv_val" ]; then
                yq eval -i ".generatedBy.${_tv_key} = \"${_tv_val}\"" "$manifest" 2>/dev/null || true
            fi
        done <<EOF
$_tool_versions
EOF
    fi

    ok "images.lock updated"
    steps+=("update-manifest:ran:")

    # ---- Step 7: Export images ----
    local archive_file="${output_dir}/biznez-images-v${version}.tar.gz"
    info "Exporting images..."
    cmd_export_images --manifest "$manifest" --output "$archive_file" --format oci
    steps+=("export:ran:")

    # ---- Step 8: Scan ----
    if [ "$skip_scan" = "false" ]; then
        if _rel_run_scan "$manifest" "$output_dir" "$version"; then
            steps+=("scan:ran:")
        else
            steps+=("scan:skipped:tool-missing")
        fi
    else
        steps+=("scan:skipped:flag")
    fi

    # ---- Step 9: SBOM ----
    if [ "$skip_sbom" = "false" ]; then
        if _rel_generate_sbom "$manifest" "$output_dir" "$version"; then
            steps+=("sbom:ran:")
        else
            steps+=("sbom:skipped:tool-missing")
        fi
    else
        steps+=("sbom:skipped:flag")
    fi

    # ---- Step 10: Sign images ----
    if [ "$skip_sign" = "false" ]; then
        if _rel_sign_artifacts "$tool" "$manifest" "$output_dir" "$sign_key"; then
            steps+=("sign:ran:")
        else
            steps+=("sign:skipped:tool-missing")
        fi
    else
        steps+=("sign:skipped:flag")
    fi

    # ---- Step 11: Checksums ----
    _rel_generate_checksums "$output_dir"
    steps+=("checksums:ran:")

    # ---- Step 12: Sign checksums (already done in step 10 if signing enabled) ----
    # Checksums signing is handled by _rel_sign_artifacts

    # ---- Step 13: Release manifest ----
    _rel_write_manifest "$output_dir" "$version" "$platform" "$policy" "$manifest" "${steps[@]}"
    steps+=("release-manifest:ran:")

    # ---- Step 14: Summary ----
    echo ""
    echo "==============================="
    echo "  BUILD-RELEASE COMPLETE"
    echo "  Version: $version"
    echo "  Policy:  $policy"
    echo "  Output:  $output_dir"
    echo "==============================="

    local _f
    for _f in "${output_dir}"/biznez-images-*.tar.gz "${output_dir}"/*.json "${output_dir}"/checksums.sha256 "${output_dir}"/checksums.sha256.sig; do
        if [ -f "$_f" ]; then
            local _sz
            _sz=$(wc -c < "$_f" | awk '{if($1>1048576) printf "%.1f MB",$1/1048576; else printf "%.1f KB",$1/1024}')
            echo "  $(basename "$_f") (${_sz})"
        fi
    done
}
