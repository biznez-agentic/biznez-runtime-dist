# Phase 8: Release Pipeline & Tooling

## Context

Phases 0-7 are complete. The Helm chart, Docker Compose, and operator CLI (`cli/biznez-cli`) are fully implemented. Enterprise clients need a deterministic, auditable supply chain: pinned image digests, vulnerability scans, SBOMs, and signed artifacts. Phase 8 adds supply chain management so that `build-release` produces all artifacts needed for enterprise delivery, and `export-images`/`import-images` enable air-gapped deployments.

## Architecture

Phase 8 adds image supply chain commands to the CLI. To manage the ~1,000 lines of new code without bloating the main script, image/release logic is developed in a separate source file (`cli/lib/images.sh`) and concatenated into the single-file `cli/biznez-cli` at release time. During development, the CLI sources the lib file if present.

A thin wrapper script (`release/build-release.sh`) provides CI convenience.

## Files to Modify/Create

| File | Action | Description |
|------|--------|-------------|
| `helm/biznez-runtime/images.lock` | **Replace** | Populate with 4-image schema including sourceRepo/targetRepo/releaseRepo fields |
| `cli/lib/images.sh` | **Create** | Image supply chain functions (~900 lines): parsing, export, import, verify, build-release, mirror, audit |
| `cli/biznez-cli` | **Extend** | Source `lib/images.sh`, add dispatch entries + help text + EXIT_USAGE=11 (~60 lines) |
| `release/build-release.sh` | **Replace** | Thin wrapper (~80 lines) that calls `biznez-cli build-release` |
| `release/bundle-cli.sh` | **Create** | CLI bundler script (~30 lines): strips guards/shebangs from lib, inserts before dispatch |
| `tests/test-cli.sh` | **Extend** | Add ~120 lines of Phase 8 unit tests (awk + conditional yq parser tests) |
| `tests/test-release-integration.sh` | **Create** | Integration test with local registry (~180 lines, requires Docker + yq) |
| `Makefile` | **Extend** | Add `build-release`, `verify-images`, `test-release-integration`, `cli-bundle` targets |

## Design Decisions

### 1. images.lock parsing: yq is a hard prerequisite

**yq (mikefarah/yq v4+) is required** for all Phase 8 commands. awk parsing of YAML is inherently brittle — fields will be added (annotations, multiple platforms, extra images) and awk will silently mis-parse.

- `build-release`, `export-images`, `import-images`, `verify-images` all require `yq` and fail with `EXIT_PREREQ` if missing.
- An `--allow-awk-parser` escape hatch exists for emergencies. It prints a loud warning: `"[WARN] Using awk YAML parser. Results may be incorrect. Install yq for reliable parsing."` This is never the default.
- Unit tests use the awk parser inline (no yq dependency for CI test runners).
- `yq` is installable via `brew install yq`, `apt install yq`, `choco install yq`, or single binary download.

Parser function `_parse_images_lock()`:
```bash
# yq path (required):
yq eval '.images[] | [.name, .sourceRepo, .targetRepo, .releaseRepo, .tag, .imageDigest, .indexDigest] | @tsv' "$manifest"
```
Output: tab-separated records consumed via `while IFS="$(printf '\t')" read -r ...`

### 2. Digest resolution: registry-provided digests only (never local hashing)

`_img_resolve_digest()` resolves **two** digests per image. **Critical rule: never compute digests locally** (e.g., piping `crane manifest` through `sha256sum`). JSON formatting, whitespace, field ordering, and tool versions change the bytes — giving a different hash than the registry's content digest. Always use digests the registry already provides.

| Field | What it is | Why |
|-------|-----------|-----|
| `imageDigest` | Digest of the platform-specific manifest (linux/amd64) | This is what you actually pull and run |
| `indexDigest` | Digest of the multi-arch manifest list (if applicable) | For auditing, future multi-arch, and registry index lookup |

**Must fail if `platform` is empty** — silently locking wrong digests is worse than a clear error.

Resolution strategy per tool:

- **crane**:
  - `indexDigest`: `crane digest repo:tag` (returns the top-level digest — index if multi-arch, manifest if single-arch)
  - `imageDigest`: First check if the top-level manifest is an index (mediaType contains "manifest.list" or "image.index"). If yes, parse the index JSON to find the descriptor matching the target platform and extract its `digest` field (the registry already computed this). If single-arch, `imageDigest` = `indexDigest`.
  - Fallback: `crane digest --platform linux/amd64 repo:tag` if the crane version supports it.

- **skopeo**:
  - `indexDigest`: `skopeo inspect --format '{{.Digest}}' docker://repo:tag` (returns the digest skopeo resolved for that reference — this is the index digest for multi-arch, or the manifest digest for single-arch).
  - `imageDigest`: If the top-level is a manifest list, fetch the raw index via `skopeo inspect --raw docker://repo:tag`, parse the JSON to find the `linux/amd64` descriptor, and read its `digest` field directly (the registry already computed this). If single-arch, `imageDigest` = `indexDigest`.

- **docker** (least capable):
  - `docker pull --platform linux/amd64 repo:tag` + `docker inspect --format '{{index .RepoDigests 0}}'` for imageDigest.
  - `indexDigest` left empty (Docker CLI doesn't expose manifest list digests).

All scanning (trivy), SBOM (syft), and pulling use `@imageDigest` references — never tags — to ensure determinism.

### 3. Archive format: per-image OCI sublayouts (Path A)

**One canonical internal format: OCI image layout, organized as per-image sublayouts.**

A single merged OCI layout with a shared blob store and multi-image index is the "ideal" format, but merging blobs and building a correct multi-image OCI index in bash is error-prone and fragile. Instead, v1 uses per-image OCI sublayouts — each image gets its own self-contained OCI layout directory:

```
biznez-images-v1.0.0/
  images.lock                         # Embedded manifest for self-contained distribution
  oci/
    platform-api/                     # Per-image OCI layout
      oci-layout                      # {"imageLayoutVersion": "1.0.0"}
      index.json
      blobs/sha256/...
    web-app/
      oci-layout
      index.json
      blobs/sha256/...
    agentgateway/
      oci-layout
      index.json
      blobs/sha256/...
    postgres/
      oci-layout
      index.json
      blobs/sha256/...
```

Why per-image sublayouts:
- **OCI standard compliant** — each sublayout is a valid OCI image layout
- **No merge complexity** — no shared blob management or multi-image index construction
- **Clean import path**: `skopeo copy oci:bundle/oci/platform-api docker://registry/targetRepo:tag` per image (or crane equivalent)
- **Acceptable tradeoff**: Less cross-image layer dedup, but for 4 images this is negligible in v1
- **Docker daemon loading**: `skopeo copy oci:bundle/oci/platform-api docker-daemon:name:tag` or `crane push`

**`--format docker-archive`** flag on `export-images` is supported as a compatibility option — it produces a `docker save`-style tarball instead. But the default is OCI.

**`import-images`** detects the format on input: presence of `oci/` directory with per-image subdirectories containing `oci-layout` files indicates the OCI sublayout format; a top-level `manifest.json` indicates docker-archive. Routes accordingly.

**`_img_detect_archive_format()`** must handle the per-image sublayout structure: scan for `oci/*/oci-layout` pattern rather than a single top-level `oci-layout` file.

### 4. Signing scope: release registry only, mirror third-party first

Phase 8 v1 scope for signing:
- **Sign images in your release registry only** — never attempt to sign upstream registries you don't control (ghcr.io/agentgateway, docker.io/library/postgres)
- **Sign checksums file**: `cosign sign-blob` on `checksums.sha256` (single signature covers all artifacts)
- **Optionally sign bundle**: `cosign sign-blob` on the tar.gz archive

**Release registry model:**
`build-release` uses a controlled "release registry" (e.g., `ghcr.io/biznez-agentic`) for all images:
1. Biznez images (platform-api, web-app) are already in the release registry
2. Third-party images (postgres, agentgateway) are **mirrored into the release registry** by digest during build-release (e.g., `crane copy docker.io/library/postgres@sha256:abc ghcr.io/biznez-agentic/thirdparty/postgres@sha256:abc`)
3. After mirroring, **sign all four images** in the release registry — you control it, so signing always works
4. `export-images` then pulls from the release registry (not upstream), ensuring determinism

This avoids:
- Permission failures trying to sign ghcr.io/agentgateway or dockerhub
- Signatures that don't exist in the customer registry after import
- Policy check failures that enforce signatures in the target registry

Phase 8 v1 does NOT include:
- SBOM attestations per image (`cosign attest`) — deferred to v2
- SLSA provenance — deferred to v2

`verify-images` verifies:
- Image signatures via `cosign verify` (key-pair or keyless), using `{registry}/{targetRepo}@{imageDigest}`
- **Tag→digest match**: resolve `{registry}/{targetRepo}:{tag}` and compare to `imageDigest` in images.lock to catch tag drift after import
- Checksums file signature via `cosign verify-blob` (if .sig file exists)

v2 will add `--verify-attestations` for SBOM/provenance attestation checks.

### 5. Build policy: enterprise-first, explicit skips

**Inverted default: `build-release` fails if required tools are missing.** Skips require explicit flags.

`--policy` flag controls enforcement:

| Policy | SBOM | Scan | Sign | Digests | Behaviour |
|--------|------|------|------|---------|-----------|
| `enterprise` (default) | Required | Required | Required | All resolved | Fail if any tool missing |
| `dev` | Optional | Optional | Optional | Best-effort | Warn and skip if tools missing |

Additionally, per-step skip flags override within a policy:
- `--skip-sbom`, `--skip-scan`, `--skip-sign`
- These work in both policies (explicit operator choice)

Tool requirements by policy:

| Tool | `enterprise` | `dev` |
|------|-------------|-------|
| crane or skopeo or docker | Required | Required |
| yq | Required | Required |
| syft | Required | Optional |
| trivy | Required | Optional |
| cosign | Required | Optional |

### 6. images.lock schema: sourceRepo + targetRepo + releaseRepo

```yaml
# images.lock -- DO NOT EDIT (generated by biznez-cli build-release)
version: "0.0.0-dev"
generatedBy:
  tool: "biznez-cli"
  toolVersion: ""
  crane: ""          # or skopeo/docker version used
  syft: ""
  trivy: ""
platform: linux/amd64
releaseRegistry: ""  # Populated by build-release (e.g., ghcr.io/biznez-agentic)
images:
  - name: platform-api
    sourceRepo: "biznez/platform-api"
    targetRepo: "biznez/platform-api"
    releaseRepo: ""  # Populated by build-release (e.g., ghcr.io/biznez-agentic/platform-api)
    tag: "0.0.0-dev"
    imageDigest: ""
    indexDigest: ""
  - name: web-app
    sourceRepo: "biznez/web-app"
    targetRepo: "biznez/web-app"
    releaseRepo: ""
    tag: "0.0.0-dev"
    imageDigest: ""
    indexDigest: ""
  - name: agentgateway
    sourceRepo: "ghcr.io/agentgateway/agentgateway"
    targetRepo: "biznez/thirdparty/agentgateway"
    releaseRepo: ""
    tag: "0.1.0"
    imageDigest: ""
    indexDigest: ""
  - name: postgres
    sourceRepo: "docker.io/library/postgres"
    targetRepo: "biznez/thirdparty/postgres"
    releaseRepo: ""
    tag: "15-alpine"
    imageDigest: ""
    indexDigest: ""
```

Field definitions:

| Field | Purpose |
|-------|---------|
| `name` | Logical name used as identifier (unique within manifest) |
| `sourceRepo` | Full upstream registry reference (provenance only — where images originally came from). Not used at runtime by Phase 8 commands; all operations use `releaseRepo`. |
| `targetRepo` | Name/path under customer registry (where `import-images` pushes to) |
| `releaseRepo` | Controlled registry reference populated by `build-release` (where images are mirrored, signed, and exported from). For Biznez images, same as source. For third-party, the mirrored location under the release registry. |
| `tag` | Image tag |
| `imageDigest` | Platform-specific manifest digest (what you actually pull and run) |
| `indexDigest` | Multi-arch manifest list digest (for auditing, may be empty for single-arch images) |

**Key flow:**
1. `build-release` mirrors all images into the release registry → populates `releaseRepo` for each image
2. `export-images` pulls from `releaseRepo@imageDigest` (not sourceRepo) — deterministic, rate-limit-free, within your control
3. `import-images --registry registry.client.com` pushes from bundle to `registry.client.com/{targetRepo}:{tag}`

On `import-images --registry registry.client.com`:
- `biznez/platform-api:0.1.0` → `registry.client.com/biznez/platform-api:0.1.0`
- `biznez/thirdparty/postgres:15-alpine` → `registry.client.com/biznez/thirdparty/postgres:15-alpine`

Top-level `platform` field applies to all images (v1: always `linux/amd64`). Per-image platform override is a v2 feature for multi-arch. Top-level `releaseRegistry` is the base registry used by `build-release`.

`generatedBy` block records tool versions used during build for audit reproducibility.

### 7. Scan/SBOM against releaseRepo digests, with tool versions

**All runtime actions in Phase 8 use `releaseRepo@imageDigest`** — never `sourceRepo`. `sourceRepo` is provenance only ("where it originally came from"). Once images are mirrored into the release registry, all scanning, SBOM generation, signing, and exporting operate against `releaseRepo@imageDigest`.

```bash
# Scanning (against release registry, by digest):
trivy image --severity HIGH,CRITICAL "ghcr.io/biznez-agentic/platform-api@sha256:abc123..."

# SBOM (against release registry, by digest):
syft "ghcr.io/biznez-agentic/platform-api@sha256:abc123..." -o spdx-json
```

Tool versions are captured in:
1. `images.lock` `generatedBy` block (at generation time)
2. `trivy-report-v{VERSION}.json` includes trivy version in report metadata
3. `sbom-v{VERSION}.json` includes syft version in SPDX creator fields

### 8. CLI modular development (single-file shipping)

To manage growth without a maintainability cliff:

**Development:** `cli/lib/images.sh` contains all Phase 8 functions (parsing, export, import, verify, build-release, helpers). The main `cli/biznez-cli` sources it:
```bash
# Source image/release functions if lib exists (development mode)
_LIB_DIR="$(cd "$(dirname "$0")/lib" 2>/dev/null && pwd)" || true
if [ -n "$_LIB_DIR" ] && [ -f "$_LIB_DIR/images.sh" ]; then
    # shellcheck source=lib/images.sh
    . "$_LIB_DIR/images.sh"
fi
```

**Release:** `make cli-bundle` concatenates `cli/biznez-cli` + `cli/lib/images.sh` into a single distributable file. To prevent duplication issues:
- `cli/lib/images.sh` must be **functions-only** — no top-level executable code, no `set -euo pipefail`, no global variable declarations that duplicate the main file
- The lib file must start with a source guard: `return 0 2>/dev/null || true` at the top (Bash 3.2 friendly) to prevent accidental direct execution
- The bundler strips the guard line and any `#!/usr/bin/env bash` shebang from the lib before concatenation
- A **concrete marker comment** in `cli/biznez-cli` defines the insertion point:
  ```bash
  # === PHASE8_LIB_INSERTION_POINT ===
  ```
  The bundler replaces this marker with the processed lib content. This is deterministic and survives future edits to the main file (no brittle "grep for dispatch" logic).

**Testing:** `shellcheck` runs on both the main file and `lib/images.sh` separately. Unit tests run against the assembled CLI.

Function naming convention for Phase 8: all prefixed with `_img_` or `_rel_` to distinguish from Phase 7 functions:
- `_img_parse_lock()`, `_img_detect_tool()`, `_img_resolve_digest()`, etc.
- `_rel_generate_sbom()`, `_rel_run_scan()`, `_rel_sign_artifacts()`, etc.

## New CLI Commands

### `export-images`

**Flags:** `--manifest <file>`, `--output <file>`, `--format <oci|docker-archive>`, `--platform <os/arch>`

**Logic:**
1. Require `yq` (or `--allow-awk-parser`)
2. Parse `images.lock` → list of image refs
3. Validate `releaseRepo` is populated for all images (fail if empty — means `build-release` hasn't been run)
4. Detect tool (crane/skopeo/docker)
5. For OCI format (default): create per-image OCI sublayouts under `bundle/oci/{name}/`, pulling from `releaseRepo@imageDigest` (not sourceRepo)
   - `crane pull --format oci releaseRepo@imageDigest bundle/oci/{name}/` per image
   - Or `skopeo copy docker://releaseRepo@imageDigest oci:bundle/oci/{name}:tag`
6. For docker-archive: `docker save` / `crane pull --format tarball` each image from releaseRepo
7. Copy `images.lock` into bundle root for self-contained distribution
8. `tar czf` into output archive

### `import-images`

**Flags:** `--archive <file>` (required), `--registry <url>`, `--docker`, `--manifest <file>`

**Two modes:**
- `--registry <url>`: Extract archive, read embedded `images.lock`, for each image:
  - Copy from OCI sublayout to tag: `skopeo copy oci:bundle/oci/{name} docker://{registry}/{targetRepo}:{tag}` (or crane equivalent). Digest is preserved automatically by the copy.
  - **Post-copy verification**: resolve the digest of `{registry}/{targetRepo}:{tag}` and compare to `imageDigest` from images.lock. Fail if mismatch — this ensures the import was deterministic.
- `--docker`: Extract archive, load images into local Docker daemon
  - OCI sublayout: `skopeo copy oci:bundle/oci/{name} docker-daemon:{targetRepo}:{tag}` per image
  - docker-archive: `docker load` directly

**Format detection:** `_img_detect_archive_format()` scans for `oci/*/oci-layout` (per-image sublayouts) vs top-level `manifest.json` (docker-archive).

**Validation:** must specify either `--registry` or `--docker`

### `verify-images`

**Flags:** `--manifest <file>`, `--registry <url>`, `--key <file>`, `--keyless`, `--certificate-identity`, `--certificate-oidc-issuer`, `--skip-tag-check`

**Logic:**
1. Require `cosign`; prefer crane or skopeo for tag→digest verification (remote registry queries)
2. Parse `images.lock` → list of images with digests
3. For each image:
   a. **Tag→digest match check** (unless `--skip-tag-check`): Resolve `{registry}/{targetRepo}:{tag}` digest **remotely** via crane/skopeo and compare to `imageDigest` in images.lock. Catches tag drift after import (e.g., tag re-pointed to different image).
      - **crane**: `crane digest {registry}/{targetRepo}:{tag}` (fast, remote-only)
      - **skopeo**: `skopeo inspect --format '{{.Digest}}' docker://{registry}/{targetRepo}:{tag}` (remote-only)
      - **docker-only fallback**: Warn that tag→digest check requires pulling images locally (slow, surprising). If operator hasn't accepted this overhead, require `--skip-tag-check` when only docker is available.
   b. **Signature verification**: `cosign verify` with key-pair or keyless mode, using `{registry}/{targetRepo}@{imageDigest}`
4. If checksums.sha256.sig exists: `cosign verify-blob` on checksums file
5. Report pass/fail per image (both tag-match and signature), summary at end

### `build-release`

**Flags:** `--version <ver>` (required), `--output-dir <dir>`, `--release-registry <url>` (required unless `--skip-mirror`), `--sign-key <file>`, `--policy <enterprise|dev>`, `--skip-scan`, `--skip-sbom`, `--skip-sign`, `--skip-mirror`, `--allow-awk-parser`

**`--release-registry` is required in both policies** unless `--skip-mirror` is set. This prevents ambiguous runs where `releaseRepo` stays empty and downstream commands (export, scan, sign) have no valid image reference.

**Orchestration steps:**
1. Validate prerequisites based on `--policy` (fail if enterprise + missing tools). Fail if `--release-registry` missing and `--skip-mirror` not set.
2. Record tool versions in `generatedBy`
3. Update `images.lock` version and Biznez image tags from `--version`
4. Resolve `imageDigest` + `indexDigest` for all images (registry-provided digests, platform-specific)
5. **Mirror all images into release registry** (unless `--skip-mirror`):
   - Biznez images: tag/push if not already present
   - Third-party images: `crane copy sourceRepo@imageDigest releaseRegistry/targetRepo@imageDigest`
   - Populate `releaseRepo` field for each image
6. Write updated `images.lock` (with releaseRepo, digests, generatedBy)
7. Export images from `releaseRepo@imageDigest` → `biznez-images-v{VERSION}.tar.gz` (per-image OCI sublayouts)
8. Run Trivy scan (all images by `releaseRepo@imageDigest`) → `trivy-report-v{VERSION}.json` (or skip with `--skip-scan`)
9. Generate SBOM via Syft (all images by `releaseRepo@imageDigest`) → `sbom-v{VERSION}.json` (or skip with `--skip-sbom`)
10. **Sign images** via Cosign — each image in the **release registry** by digest (or skip with `--skip-sign`)
11. **Generate `checksums.sha256`** (portable: sha256sum or shasum -a 256) — covers all output artifacts
12. **Sign checksums file** via `cosign sign-blob checksums.sha256` → `checksums.sha256.sig` (or skip with `--skip-sign`). Optionally also sign the bundle tar.gz.
13. **Write `release-manifest.json`** — audit trail capturing:
    - `version`, `timestamp`, `platform`
    - `tools` (name + version for each: crane/skopeo, yq, syft, trivy, cosign)
    - `images` (name, sourceRepo, releaseRepo, targetRepo, tag, imageDigest, indexDigest)
    - `steps` (each step: name, status [ran/skipped], skip reason if applicable [flag/tool-missing])
    - `policy` used, any `--skip-*` flags passed
14. Print summary of artifacts with sizes

**Checksums-then-sign order:** Generate checksums for all artifacts first, then sign the checksums file. Consumers verify: signature → checksums → files. This is simpler than signing individual artifacts.

## New Utility Functions (in `cli/lib/images.sh`)

| Function | Purpose |
|----------|---------|
| `_img_detect_tool()` | Returns best available image tool: crane, skopeo, or docker |
| `_img_parse_lock()` | Parse images.lock via yq (or awk with `--allow-awk-parser`) to TSV records |
| `_img_get_lock_version()` | Extract version field from images.lock |
| `_img_ref()` | Construct `repo@digest` or `repo:tag` reference |
| `_img_resolve_digest()` | Resolve imageDigest + indexDigest using registry-provided digests only. Fails if platform is empty. |
| `_img_detect_archive_format()` | Detect per-image OCI sublayouts (`oci/*/oci-layout`) vs docker-archive (`manifest.json`) |
| `_img_mirror_to_release()` | Copy image from sourceRepo to releaseRegistry by digest |
| `_img_verify_tag_digest()` | Resolve tag remotely via crane/skopeo and compare to expected imageDigest (tag drift check). Warns/requires --skip-tag-check if docker-only. |
| `_rel_generate_sbom()` | Run syft against each image by digest, produce SPDX JSON |
| `_rel_run_scan()` | Run trivy against each image by digest, produce JSON report |
| `_rel_sign_artifacts()` | Cosign sign images in release registry + sign-blob for checksums file |
| `_rel_generate_checksums()` | Portable sha256 checksums (sha256sum or shasum -a 256) |
| `_rel_record_tool_versions()` | Capture versions of crane/skopeo/docker/yq/syft/trivy/cosign |
| `_rel_write_manifest()` | Write `release-manifest.json` audit trail |

## CLI Changes Summary

- **New exit codes:**
  - `EXIT_RELEASE=9` — supply chain pipeline failures (digest mismatch, scan fail, signature fail, mirror fail)
  - `EXIT_USAGE=11` — user input errors (missing manifest file, missing required flags, invalid arguments)
- **Updated `_cleanup()`:** Use `rm -rf` for directories (Phase 8 commands create temp dirs via `_register_cleanup`)
- **Updated help text:** Add "Commands (P3 -- supply chain)" section with 4 commands
- **Updated dispatch:** Add 4 new case entries (export-images, import-images, verify-images, build-release)
- **Source lib:** Add conditional source of `cli/lib/images.sh`

## release/build-release.sh

Thin wrapper (~80 lines):
- Parses version from `$1` or `$VERSION` env var
- Supports env vars: `OUTPUT_DIR`, `SIGN_KEY`, `SKIP_SCAN`, `SKIP_SBOM`, `SKIP_SIGN`, `POLICY`
- Validates CLI exists and is executable
- Defaults `--policy enterprise` for CI use
- `exec`s `biznez-cli build-release --version "$VERSION" --policy "${POLICY:-enterprise}" ...`

## Testing Strategy

### Unit tests (additions to `tests/test-cli.sh`)
- `--help` lists all 4 new commands (export-images, import-images, verify-images, build-release)
- Each command's `--help` shows expected flags
- `export-images --manifest /nonexistent` exits 11 (`EXIT_USAGE` — user input error, not pipeline failure)
- `import-images` without `--archive` exits 11
- `build-release` without `--version` exits 11
- images.lock awk parser: create temp file with 2 images, verify 2 records parsed
- images.lock awk parser: verify field extraction (name, sourceRepo with URL colons, imageDigest)
- **yq parser tests (conditional)**: If `yq` is available, run the same parser tests using the yq path. If not available, skip with `[SKIP] yq not found` message. This ensures the production code path is tested where possible.

### Integration test (`tests/test-release-integration.sh`, optional/nightly)
Requires Docker + yq. **Must always exercise the yq code path** (fail if yq is not installed). Steps:
1. Start a local registry (`docker run -d -p 5555:5000 registry:2`)
2. Pull a small test image (`alpine:3.19`)
3. Tag + push to local registry as fake biznez images (platform-api, web-app) and third-party (postgres)
4. Run `build-release --version 0.0.1-test --release-registry localhost:5555/biznez --policy dev --skip-sign --skip-sbom --skip-scan`
5. Verify `images.lock` has resolved digests (non-empty imageDigest fields)
6. Verify `releaseRepo` fields are populated for all images
7. Verify `release-manifest.json` exists and contains expected structure (version, tools, steps)
8. Run `export-images` → produces archive
9. Extract archive and verify per-image OCI sublayout structure (`oci/*/oci-layout` exists)
10. Run `import-images --registry localhost:5555/imported` → pushes to registry
11. Verify: pull from `localhost:5555/imported/{targetRepo}@{imageDigest}` succeeds
12. Verify: tag→digest match check (`verify-images --registry localhost:5555/imported --skip-tag-check` not needed — tags should resolve correctly)
13. Cleanup: stop registry container, remove temp files

### Makefile targets

```makefile
cli-bundle:  ## Bundle CLI + lib into single distributable file
	@# Strip source guard, shebang from lib; insert before dispatch
	bash release/bundle-cli.sh cli/biznez-cli cli/lib/images.sh > cli/biznez-cli-bundle
	chmod +x cli/biznez-cli-bundle

build-release:  ## Run full release build pipeline
	release/build-release.sh $(VERSION)

verify-images:  ## Verify image signatures and tag→digest match
	cli/biznez-cli verify-images --manifest helm/biznez-runtime/images.lock \
		--registry $(REGISTRY) --key $(COSIGN_KEY)

test-release-integration:  ## Integration test with local registry (requires Docker + yq)
	bash tests/test-release-integration.sh
```

## Implementation Order

1. `images.lock` — populate new schema with sourceRepo/targetRepo/releaseRepo fields (10 min)
2. `cli/lib/images.sh` — core utility functions: `_img_detect_tool`, `_img_parse_lock`, `_img_resolve_digest` (registry-provided digests only), `_img_ref`, `_img_detect_archive_format` (per-image sublayouts), `_img_mirror_to_release`, `_img_verify_tag_digest`, `_rel_generate_checksums`, `_rel_record_tool_versions`, `_rel_write_manifest` (60 min)
3. `export-images` command in lib — per-image OCI sublayouts, pull from releaseRepo (45 min)
4. `import-images` command in lib — detect sublayout format, push to target registry (45 min)
5. `verify-images` command in lib — signature check + tag→digest match (25 min)
6. `build-release` command + `_rel_generate_sbom`, `_rel_run_scan`, `_rel_sign_artifacts` — mirror first, sign in release registry, checksums-then-sign order, write release-manifest.json (70 min)
7. `cli/biznez-cli` — add source for lib, dispatch entries, help text, EXIT_USAGE=11, updated cleanup (15 min)
8. `release/build-release.sh` wrapper (15 min)
9. `release/bundle-cli.sh` — CLI bundler with dedup protection (15 min)
10. Unit tests in `tests/test-cli.sh` — awk parser + conditional yq parser tests (35 min)
11. Integration test `tests/test-release-integration.sh` — requires Docker + yq, verify sublayouts + releaseRepo + release-manifest.json (50 min)
12. Makefile targets (5 min)
13. shellcheck + test verification (15 min)

## Verification

1. `shellcheck -s bash -e SC1091 cli/biznez-cli cli/lib/images.sh` — zero issues
2. `bash tests/test-cli.sh` — all tests pass (including new Phase 8 tests, conditional yq tests)
3. `make lint` — passes
4. `biznez-cli export-images --help` — shows usage with --format, --manifest
5. `biznez-cli import-images --help` — shows usage with --archive, --registry, --docker
6. `biznez-cli verify-images --help` — shows usage with --key, --keyless, --skip-tag-check
7. `biznez-cli build-release --help` — shows usage with --version, --policy, --release-registry, --skip-*
8. `biznez-cli build-release` without `--version` — exits 11 (`EXIT_USAGE`)
9. `biznez-cli export-images --manifest /nonexistent` — exits 11 (`EXIT_USAGE`)
10. `make cli-bundle` — produces `cli/biznez-cli-bundle` without duplicate shebangs/globals

## Key Patterns to Reuse

- **Output helpers:** `cli/biznez-cli:60-94` (info, ok, warn, error, die)
- **Cleanup mechanism:** `cli/biznez-cli:166-174` (_register_cleanup, _cleanup trap) — updated for rm -rf
- **Flag parsing:** `cli/biznez-cli:1694-1709` (global), per-command while/case patterns
- **`set -euo pipefail` safety:** `|| true`, `|| _rc=$?`, `if/else` wrappers (same patterns as Phase 7)

## Potential Challenges

1. **Bash 3.2 tab IFS:** Use `IFS="$(printf '\t')"` not `IFS=$'\t'`
2. **Large archives:** Multi-GB OCI bundles. v1 uses temp-dir + tar approach; v2 could optimize with streaming
3. **Syft SBOM merge:** Syft generates per-image SPDX. v1 produces individual SBOM files per image combined into an array wrapper. v2 could use spdx-tools merge
4. **sha256sum portability:** macOS has `shasum -a 256` not `sha256sum`. `_rel_generate_checksums()` detects and uses available tool
5. **crane digest platform resolution:** Never hash `crane manifest` output locally. Use `crane digest` for index digest, then parse manifest list descriptors to read platform-specific digest field directly from the index JSON. Must verify this behaviour in integration tests.
6. **Registry mirroring permissions:** `build-release` mirrors third-party images into the release registry. Requires push access. The `--skip-mirror` flag allows bypassing if images are already mirrored by CI.
7. **`_cleanup` for directories:** Current cleanup uses `rm -f`. Must update to detect dirs and use `rm -rf`
8. **cli-bundle function deduplication:** Naive concatenation of main + lib can duplicate globals/shebangs. Solved by keeping lib as functions-only with source guard.
