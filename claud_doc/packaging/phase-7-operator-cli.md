# Phase 7: Operator CLI (`cli/biznez-cli`)

## Context

Phases 0-6 are complete. The Helm chart and Docker Compose are fully implemented, but operators currently interact with raw `helm` and `kubectl` commands. Phase 7 creates a single-file bash CLI (`cli/biznez-cli`) that wraps these tools with profile-aware validation, secret generation, health checking, and migration orchestration. The current file is a 4-line placeholder.

## Architecture

**Single-file bash script** (~1,400 lines) with this internal layout:

```
Section 1: Constants, version, exit codes
Section 2: Global state (flags parsed from CLI args)
Section 3: Utility functions (output, color, prereqs, version check, cleanup)
Section 4: Command functions (cmd_validate, cmd_install, etc.) + per-command help
Section 5: Global flag parsing, dispatch (case statement), main help
```

**Command dispatch:** `case "$cmd"` pattern matching subcommand names to `cmd_*` functions.

**No hardcoded application paths:** The CLI never hardcodes uvicorn module paths, backend entrypoints, or container commands. All container command/args are defined by the Helm chart. The only direct `python -c` usage is for Fernet key generation via `docker run`.

**No hardcoded resource names:** Resource names (deployments, services) are discovered via label selectors (`app.kubernetes.io/instance=$RELEASE`, `app.kubernetes.io/component=backend|frontend|gateway`), not constructed by string interpolation. This avoids tight coupling to chart naming conventions and `fullnameOverride`.

**Values parsing strategy:** Do NOT grep raw YAML for effective values. Instead:
- **Pre-install:** rely on `helm template` dry-run against `validate.yaml` as source of truth for all values validation. Only do targeted K8s lookups when secret names are explicitly provided via CLI flags.
- **Post-install:** use `helm get values $RELEASE -n $NAMESPACE` for inspecting deployed configuration.
- The CLI does not attempt to parse multi-file values merging or override resolution — Helm does that.

**Helm passthrough:** Support `--` separator. Everything after `--` is passed directly to `helm`. This prevents argument parsing conflicts and is implemented in the global flag parser from day one.

```bash
# Example:
biznez-cli install -f values.yaml -n prod -- --timeout 10m --atomic
```

**`set -euo pipefail` safety:** All commands that may legitimately return non-zero (grep miss, probe failure, connectivity check) are wrapped with explicit `|| true`, exit code capture, or helper functions that translate exit codes into actionable messages. Never let a "not found" grep silently kill the script.

**Bash 3.2+ compatible:** No associative arrays, no `|&`, no `${var,,}`, no `mapfile`. Use `tr` for case conversion, `cut`/`grep`/`sed` for parsing, indexed arrays only.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Missing prerequisite (kubectl, helm, openssl, docker when needed) |
| 3 | Validation failure |
| 4 | Kubernetes error |
| 5 | Secret error |
| 6 | Health check failure |
| 7 | Migration failure |
| 8 | Network error |
| 10 | User abort |

## Global Flags (all commands)

`--namespace/-n`, `--release/-r`, `--values/-f`, `--profile`, `--no-color`, `--verbose/-v`, `--help/-h`

Plus `--` separator: everything after `--` is passed directly to the underlying `helm` command.

## Commands — Implementation Order

### 1. Scaffolding
- Shebang, `set -euo pipefail`, constants, exit codes
- Output functions: `info()`, `ok()`, `warn()`, `error()`, `die()`, `debug()` — reuse patterns from `compose/setup.sh:48-52`
- Color support with `--no-color` / `NO_COLOR` env var
- `_require_cmd()` prerequisite checker
- `_version_gte()`: robust version comparison
  - Strip leading `v`, extract numeric prefix via `sed 's/[^0-9.].*$//'` (handles `v1.27.3-gke.1`, `3.12.0-rc1`, vendor strings)
  - Compare major.minor via `cut -d. -f1,2`
  - **On parse failure: warn, don't hard-fail** (unknown vendor strings shouldn't block)
- `_cleanup()` trap for temp files
- `_collect_optional()` helper for commands that may fail due to RBAC/API unavailability — captures output, logs failure as warning, continues
- `_find_resource()` helper to discover K8s resource names by label selector:
  ```bash
  _find_resource() {
      local kind="$1" component="$2"
      kubectl get "$kind" \
          -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=$component" \
          -n "$NAMESPACE" -o name 2>/dev/null | head -1
  }
  # Usage: _find_resource deployment backend  -> "deployment.apps/myrelease-biznez-runtime-backend"
  ```
- Script location: `SCRIPT_DIR` -> `REPO_ROOT` -> `CHART_DIR`
- Global flag parsing loop with `--` passthrough support:
  ```bash
  while [ $# -gt 0 ]; do
      case "$1" in
          -n|--namespace) NAMESPACE="$2"; shift 2 ;;
          --)            shift; HELM_PASSTHROUGH=("$@"); break ;;
          *)             break ;;
      esac
  done
  ```
- Dispatch case statement, `--help`, `--version`

### 2. `generate-secrets` (P0)
- Flags: `--format` (yaml|env|raw), `--output` (file path), `--backend-image` (override), `--no-docker-fernet`

**Prerequisites:**
- When container-based mode is used (default): require `docker`. If docker is missing:
  - Exit with code 2 and message: "docker required for container-based Fernet key generation. Use --no-docker-fernet to fall back to openssl/python, or install docker."
- When `--no-docker-fernet` is passed: require `openssl` or `python3`.

**Fernet key generation (ENCRYPTION_KEY):**
- **Primary (unless `--no-docker-fernet`):** container-based, matching Phase 6 approach:
  ```bash
  docker run --rm "${BACKEND_IMAGE}" \
      python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
  ```
  - **Air-gapped check:** Before `docker run`, check if image is available locally:
    ```bash
    if ! docker image inspect "${BACKEND_IMAGE}" >/dev/null 2>&1; then
        warn "Image ${BACKEND_IMAGE} not found locally. Docker will attempt to pull it."
        warn "In air-gapped environments, load the image first: docker load -i <archive>.tar"
    fi
    ```
  - If `docker run` fails (pull failure, image missing, etc.): fall through to fallbacks with warning.
- **Fallback 1:** `python3 -c "import base64,os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())"` (stdlib only — produces URL-safe base64, closer to Fernet format than openssl)
  - Warning: "Generated key is URL-safe base64 but not a true Fernet key. May fail validation if app strictly requires cryptography.fernet.Fernet format."
- **Fallback 2:** `openssl rand -base64 32` (least correct — standard base64 includes `+` and `/` which are not URL-safe)
  - Stronger warning: "Generated key is standard base64, NOT URL-safe. May fail validation if app requires Fernet format. Consider using --backend-image to generate via container."
- Guard all secret generation with `{ set +x; } 2>/dev/null`

**JWT secret:** `openssl rand -base64 32` (fallback: `python3 secrets.token_urlsafe(32)`)

**Postgres password:**
- **Primary:** `openssl rand -hex 24` (hex is URL-safe, no special chars)
- **Fallback:** `python3 -c "import secrets; print(secrets.token_urlsafe(24))"`
- Do NOT `tr -d '/+='` — reduces entropy, causes edge-case surprises in connection strings

**Output formats:**
- `yaml`: K8s Secret manifests with `stringData`, namespaced
- `env`: `KEY=VALUE` lines
- `raw`: one value per line (for `--set` usage)

### 3. `validate` (P0)
- Flags: `-f/--values` (required), `--strict` (fail on lint warnings)

**Scope: render-time validation only.** No network connectivity checks from the operator's machine (DB connectivity, OIDC reachability) — those belong in `health-check` post-install or are offered separately via `oidc-discover`.

**Checks:**
1. **Prerequisites:** kubectl available, helm available. Version check with `_version_gte` (warn on parse failure, don't block).
2. **Namespace:** `kubectl get namespace "$NAMESPACE"` — fail with suggestion to create. Use if/else to capture exit code.
3. **Values file:** exists and is readable.
4. **Helm template dry-run** with proper error capture under `set -e`:
   ```bash
   local _tmpl_out _tmpl_rc=0
   _tmpl_out=$(helm template "$RELEASE" "$CHART_DIR" -f "$VALUES_FILE" \
       --namespace "$NAMESPACE" 2>&1) || _tmpl_rc=$?
   if [ "$_tmpl_rc" -ne 0 ]; then
       error "Helm template validation failed:"
       echo "$_tmpl_out" >&2
       exit $EXIT_VALIDATE
   fi
   ```
   - Uses `$RELEASE` (not `test`) so `.Release.Name` in templates and NOTES matches the actual release name, and errors reference the real install.
   - This exercises all 126 lines of `validate.yaml` guards (required fields, profile mismatches, mutual exclusion, digest checks, PDB/HPA guards)
   - This is the **primary validation mechanism** — no duplicate logic in bash
5. **K8s Secret existence (production only, flag-driven):** If operator provides `--existing-secret <name>`, check it exists via `kubectl get secret`. Otherwise, rely on helm guard failures from step 4.
6. **Helm lint** with same release name and namespace:
   ```bash
   local _lint_out _lint_rc=0
   _lint_out=$(helm lint "$CHART_DIR" -f "$VALUES_FILE" 2>&1) || _lint_rc=$?
   ```
   - Lint warnings are **non-fatal** by default — print them but don't fail.
   - With `--strict`: fail on any lint warning (`exit $EXIT_VALIDATE`).
7. **Production overlay warning** — deterministic rule:
   - Only warn when ALL of these are true:
     - `--profile production` was explicitly passed as a CLI flag (not inferred)
     - Only one `-f` values file was provided
   - Warning text: `"Profile is 'production' but only one values file provided. Consider: -f values.yaml -f values-production.yaml"`
   - This avoids false positives from YAML grepping and doesn't fire when operators know what they're doing with custom overlays.

**What validate does NOT do:**
- Does not test DB connectivity from operator machine (unreliable — different network than cluster)
- Does not test OIDC issuer reachability from operator machine (may be blocked/different)
- Does not try to grep/parse values YAML for effective field values
- Does not duplicate any logic already in `validate.yaml`
- Does not hardcode any application module paths or container commands

### 4. `validate-secrets` (P0)
- **Post-install command** — requires a deployed release to inspect

**Flags:**
- `--release` (required)
- Explicit secret name overrides (convenience flags so operators don't need `helm get values` to work):
  - `--backend-secret <name>`
  - `--db-secret <name>`
  - `--llm-secret <name>`
  - `--langfuse-secret <name>`
  - `--gateway-secret <name>`

**Steps:**
1. If explicit secret name flags are provided, use them directly.
2. Otherwise, discover secret names from deployed release:
   - Try: `helm get values "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null`
   - Fallback: `helm get values "$RELEASE" -n "$NAMESPACE" 2>/dev/null` (YAML output — extract with grep for older Helm versions that don't support `-o json`)
   - If neither works and no explicit flags given: error with message to use explicit `--backend-secret` etc. flags.
3. Check each expected K8s Secret exists and has required keys via **per-key jsonpath with bracket notation** (robust against dots/hyphens in key names):
   ```bash
   _check_secret_key() {
       local secret="$1" key="$2"
       local _val
       _val=$(kubectl get secret "$secret" -n "$NAMESPACE" \
           -o "jsonpath={.data['$key']}" 2>/dev/null) || true
       if [ -z "$_val" ]; then
           return 1
       fi
       return 0
   }
   ```
   This tests key presence individually using bracket notation `{.data['KEY']}` (more robust than dot notation `{.data.KEY}`).
4. Report: table of secret name, expected keys, present/missing status.

**Secrets checked:**
- Backend: `ENCRYPTION_KEY`, `JWT_SECRET_KEY`
- DB: `DATABASE_URL` (external) or `POSTGRES_USER`/`POSTGRES_PASSWORD` (embedded)
- LLM: `LLM_API_KEY` (if `llm.provider != none`)
- Gateway: existence check only (keys are user-defined)
- Langfuse: `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` (if enabled)

### 5. `install` (P0)
- Wraps `helm upgrade --install`
- Runs `cmd_validate` first (skip with `--skip-validation`)
- For eval: optionally runs `cmd_generate_secrets` and pipes to `kubectl apply`
- **Does NOT auto-append `values-production.yaml`.** Production overlay warning is handled by `validate` (see validate step 7).
- Operator can explicitly use `--use-default-production-overlay` flag to auto-append `values-production.yaml` from chart dir.
- Appends `"${HELM_PASSTHROUGH[@]}"` to helm command (everything after `--`)
- On success: runs `cmd_health_check` (skip with `--skip-health-check`)

### 6. `status` (P1)
- Lightweight info command: `helm status "$RELEASE" -n "$NAMESPACE"` + quick pod summary
- Shows: release status, revision, chart version, deployed values profile
- Pod table via label selector: `kubectl get pods -l "app.kubernetes.io/instance=$RELEASE" -n "$NAMESPACE"`
- Service endpoints via label selector
- Useful for demos and quick checks without full health-check

### 7. `uninstall` (P1)
- Wraps `helm uninstall`
- Confirmation prompt: "Uninstall release '$RELEASE' from namespace '$NAMESPACE'? [y/N]" (skip with `--yes`)
- Optional `--delete-namespace` flag: `kubectl delete namespace "$NAMESPACE"` after helm uninstall (with separate confirmation)
- Optional `--delete-pvcs` flag: delete PVCs matching release labels (with warning about data loss)
- Print cleanup summary

### 8. `health-check` (P0)
- Flags: `--timeout` (default 120s), `--wait` (poll until healthy)

**Approach: K8s-native checks first, then endpoint verification via port-forward. All resource names discovered by label selector, never hardcoded.**

**Steps:**
1. **Discover resources by label:**
   ```bash
   _backend_deploy=$(_find_resource deployment backend)
   _frontend_deploy=$(_find_resource deployment frontend)
   _gateway_deploy=$(_find_resource deployment gateway)  # may be empty if gateway disabled
   _backend_svc=$(_find_resource service backend)
   ```
   If backend deployment not found: `die "No backend deployment found for release '$RELEASE'"`

2. **K8s deployment readiness (primary):**
   ```bash
   local _wait_rc=0
   kubectl wait --for=condition=Available "$_backend_deploy" \
       -n "$NAMESPACE" --timeout="${TIMEOUT}s" 2>/dev/null || _wait_rc=$?
   if [ "$_wait_rc" -ne 0 ]; then
       error "Backend deployment not ready within ${TIMEOUT}s"
   fi
   ```

3. **Pod status check:**
   ```bash
   kubectl get pods -l "app.kubernetes.io/instance=$RELEASE" -n "$NAMESPACE" \
       -o jsonpath='...' 2>/dev/null || true
   ```
   Report any pods not in Running/Ready state.

4. **Backend health endpoint (port-forward + curl with readiness loop):**
   - Extract service name from `$_backend_svc` (strip `service/` prefix)
   - Port-forward in background with output logged to temp file
   - **Readiness-verified port selection** — don't just check `kill -0` (process alive ≠ forwarding established). Instead, curl in a loop:
     ```bash
     local _local_port _pf_pid _endpoint_ok=false
     _pf_log=$(mktemp); _register_cleanup "$_pf_log"

     for _local_port in 18000 18001 18002; do
         kubectl port-forward "$_backend_svc" "${_local_port}:8000" \
             -n "$NAMESPACE" >"$_pf_log" 2>&1 &
         _pf_pid=$!

         # Probe the forwarded endpoint (not just kill -0)
         local _attempt=0
         while [ "$_attempt" -lt 5 ]; do
             sleep 1
             if curl -sf --max-time 3 "http://localhost:${_local_port}/api/v1/health" >/dev/null 2>&1; then
                 _endpoint_ok=true
                 break 2  # break both loops
             fi
             _attempt=$((_attempt + 1))
         done

         # Port didn't work — kill and try next
         kill "$_pf_pid" 2>/dev/null; wait "$_pf_pid" 2>/dev/null || true
     done
     ```
   - **Reliable cleanup:** `kill "$_pf_pid" 2>/dev/null; wait "$_pf_pid" 2>/dev/null || true`
   - Fallback: `kubectl exec` if all port-forward attempts fail.

5. **Frontend readiness:** `kubectl wait --for=condition=Available "$_frontend_deploy"` (no exec needed — readiness probe already validates /health).

6. **Gateway (if `$_gateway_deploy` is non-empty):** `kubectl wait --for=condition=Available "$_gateway_deploy"` (readiness probe validates TCP 8080).

7. **Print status table:** component name, expected state, actual state, healthy/unhealthy.

**Why port-forward over exec:**
- exec requires RBAC exec permissions (may be denied in hardened clusters)
- exec assumes wget/curl exists in container (not guaranteed)
- port-forward works through the service, testing actual networking
- exec bypasses readiness gates and service routing

### 9. `migrate` (P0)
- Flags: `--timeout` (default 600s), `--dry-run` (P1)

**Steps:**
1. Render Job YAML with proper error capture:
   ```bash
   local _rendered _render_rc=0
   _rendered=$(helm template "$RELEASE" "$CHART_DIR" -f "$VALUES_FILE" \
       --show-only templates/backend/migration-job.yaml \
       --set migration.mode=hook \
       --namespace "$NAMESPACE" 2>&1) || _render_rc=$?
   ```
   **Note:** `migration-job.yaml` is conditional on `migration.mode=hook`. We override `--set migration.mode=hook` solely to render the template. The rendered Job is applied as a normal `kubectl apply` — not as a Helm hook. This is safe because:
   - Hook annotations (`helm.sh/hook`) are ignored by `kubectl apply` (they're just metadata)
   - The override only affects template rendering, not any installed release
   - The chart was designed so the migration Job template is fully renderable with this override
   - **Risk acknowledgment:** If future chart changes make migration-job.yaml depend on other values set by `migration.mode=hook`, this rendering approach may break. The guard in step 2 catches this.

2. **Verify rendered output contains a Job:**
   ```bash
   if ! echo "$_rendered" | grep -q "^kind: Job"; then
       error "Migration job template did not render a Job resource."
       error "Check values file and chart version. First 50 lines of output:"
       echo "$_rendered" | head -50 >&2
       exit $EXIT_MIGRATE
   fi
   ```

3. **Do NOT strip `helm.sh/hook*` annotations.** These are just metadata annotations — kubectl ignores them completely. Stripping via sed is fragile and unnecessary.

4. **Safe job name rewriting with fallback:**
   - Extract original job name from rendered YAML using awk:
     ```bash
     _orig_name=$(echo "$_rendered" | awk '/^metadata:/{f=1} f && /^  name:/{print $2; exit}')
     ```
   - **Fallback** if awk extraction returns empty (formatting differs):
     ```bash
     if [ -z "$_orig_name" ]; then
         _orig_name=$(echo "$_rendered" | grep '^  name:' | head -1 | awk '{print $2}') || true
     fi
     if [ -z "$_orig_name" ]; then
         error "Could not extract job name from rendered migration template."
         error "First 50 lines of rendered YAML:"
         echo "$_rendered" | head -50 >&2
         exit $EXIT_MIGRATE
     fi
     ```
   - Create new name: `_new_name="${_orig_name}-$(date +%s)"`
   - Replace only the first occurrence via awk:
     ```bash
     _rendered=$(echo "$_rendered" | awk -v old="$_orig_name" -v new="$_new_name" \
         '/^  name:/ && !done { sub(old, new); done=1 } {print}')
     ```
   - Labels/selectors in migration jobs are based on component labels, not job name, so no selector update needed.

5. Apply: `echo "$_rendered" | kubectl apply -f - -n "$NAMESPACE"`

6. Print expectations: "Job has activeDeadlineSeconds=600, backoffLimit=3"

7. Stream logs: `kubectl logs -f "job/$_new_name" -n "$NAMESPACE" 2>/dev/null || true`

8. Wait for completion: `kubectl wait --for=condition=Complete "job/$_new_name" -n "$NAMESPACE" --timeout="${TIMEOUT}s" 2>/dev/null || true`

9. **On failure, auto-print diagnostics:**
   ```bash
   kubectl describe "job/$_new_name" -n "$NAMESPACE" 2>/dev/null || true
   kubectl logs "job/$_new_name" -n "$NAMESPACE" --all-containers --tail=200 2>/dev/null || true
   ```

10. Report success/failure with exit code `EXIT_MIGRATE`.

**`--dry-run` (P1):** Override migration command to `alembic upgrade head --sql` (Alembic's SQL output mode — widely supported). Delete job immediately after log capture.

### 10. `oidc-discover` (P1)
- Flags: `--issuer` (required)
- Fetch `${issuer}/.well-known/openid-configuration` via `curl -sf`
- Display key fields (issuer, jwks_uri, scopes) — pretty-print with `jq` if available, raw JSON if not
- Validate: issuer in response matches `--issuer` flag
- Print suggested `auth.oidc.*` values.yaml snippet

### 11. `support-bundle` (P1)
- Collect to temp dir, archive as `biznez-support-YYYYMMDD-HHMMSS.tar.gz`

**What IS collected (all via `_collect_optional` helper — failure = warning, not abort):**
- `helm list -n $NAMESPACE` (release info)
- `helm get manifest $RELEASE -n $NAMESPACE` (rendered manifests — no secrets in manifests)
- `kubectl get pods,svc,ep,events -n $NAMESPACE -o yaml`
- `kubectl get ingress -n $NAMESPACE -o yaml` (optional — API may not exist, wrapped in `_collect_optional`)
- `kubectl get pvc -n $NAMESPACE -o yaml` (optional, wrapped in `_collect_optional`)
- `kubectl get networkpolicy -n $NAMESPACE -o yaml` (optional — API may not exist, wrapped in `_collect_optional`)
- Pod logs (last 500 lines per component): backend, frontend, gateway (each wrapped in `_collect_optional`)
- `kubectl version --client`
- `helm version`
- `kubectl get nodes -o wide` (optional — **cluster-wide, may fail due to RBAC** — wrapped in `_collect_optional`, IPs redacted via sed)
- User-supplied values file(s) — redacted (see below)

**`_collect_optional` helper pattern:**
```bash
_collect_optional() {
    local label="$1" outfile="$2"; shift 2
    if "$@" > "$outfile" 2>&1; then
        ok "Collected: $label"
    else
        warn "Skipped: $label ($(head -1 "$outfile"))"
        echo "# SKIPPED: $label" > "$outfile"
    fi
}
```

**What is NEVER collected:**
- `kubectl get secret -o yaml` — never dump secrets
- `helm get values --all` — may contain inline secrets from values override
- Pod env var values (no `kubectl exec env` or `kubectl get pod -o yaml` with env inspection)

**Redaction of user values files — multi-format support:**
- Copy the user's values file(s) into the bundle
- Apply layered redaction covering all formats:

**YAML style** (`key: value`):
```bash
sed -E 's/(encryptionKey|jwtSecret|password|apiKey|secretKey|publicKey|databaseUrl):\s*"?[^"]*"?/\1: "***REDACTED***"/g'
```

**ENV style** (`KEY=VALUE`):
```bash
sed -E 's/(ENCRYPTION_KEY|JWT_SECRET_KEY|DATABASE_URL|POSTGRES_PASSWORD|LLM_API_KEY|LANGFUSE_SECRET_KEY|LANGFUSE_PUBLIC_KEY)=.*/\1=***REDACTED***/g'
```

**URL-embedded credentials** (`postgresql://user:pass@host/db`):
```bash
sed -E 's|(postgresql://[^:]+:)[^@]+(@)|\1***REDACTED***\2|g'
```

### 12. `backup-db` (P2)
- Only for embedded postgres (`postgres.enabled=true` — abort with message for external DB)
- Find postgres pod via label selector: `_find_resource pod postgres`
- `kubectl exec $POD -n $NAMESPACE -- pg_dump -U biznez -d biznez_platform --format=custom` > local file
- Default filename: `biznez-backup-$(date +%Y%m%d-%H%M%S).dump`

### 13. `restore-db` (P2)
- Only for embedded postgres
- Confirm: "This will overwrite the current database. Continue? [y/N]"
- Scale backend to 0, `kubectl cp` backup file to pod, `pg_restore`, scale backend back, run `cmd_health_check`

### 14. `upgrade` (P2)
- Run `cmd_validate`, `helm upgrade --wait`, `cmd_health_check`, offer rollback on failure

## Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `cli/biznez-cli` | **Replace** | Full CLI script (~1,400 lines) |
| `tests/test-cli.sh` | **Create** | Unit tests (no cluster: help, version, generate-secrets format, unknown cmd, missing prereqs, exit codes) |
| `tests/smoke-test.sh` | **Replace** | Integration tests with kind (tiered — see below) |
| `Makefile` | **Modify** | Add `shellcheck`, `test-cli`, `test-cli-integration-fast`, `test-cli-integration-full` targets |

## Testing Strategy

### Unit tests (`tests/test-cli.sh`) — no cluster required
- `--help` output contains all command names
- `--version` output contains version string
- Unknown command exits with code 1
- `generate-secrets --format raw --no-docker-fernet` outputs 3 lines (uses openssl/python fallback, no docker needed)
- `generate-secrets --format yaml --no-docker-fernet` outputs valid YAML with `kind: Secret`
- `generate-secrets --format env --no-docker-fernet` outputs KEY=VALUE lines
- Missing prerequisite (PATH=/dev/null) exits with code 2
- `--` passthrough doesn't break argument parsing

### Integration tests (`tests/smoke-test.sh`) — tiered

**Image availability plan for kind:**
- Tests use `tests/values/eval.yaml` which references chart default images
- Before running tests, load images into kind:
  ```bash
  # Either use public images:
  #   backend.image.tag and frontend.image.tag pointing to publicly available tags
  # Or load private images:
  #   kind load docker-image biznez/platform-api:$TAG
  #   kind load docker-image biznez/web-app:$TAG
  ```
- Smoke test script checks `CHART_DIR` resolution (derived from script location via `$SCRIPT_DIR/../cli/biznez-cli` -> resolves `REPO_ROOT`) and fails early if chart dir not found
- Test harness provides a `_setup_kind_images()` function that either loads local images or skips with a warning if images are unavailable

**`smoke-fast`** (default, ~2 min):
1. `generate-secrets --format yaml | kubectl apply -f -`
2. `validate -f tests/values/eval.yaml`
3. `install -f tests/values/eval.yaml --release smoke`
4. `health-check --release smoke --timeout 120`

**`smoke-full`** (opt-in via `--full`, ~5 min):
- Everything in smoke-fast, plus:
5. `migrate --release smoke --timeout 300`
6. `validate-secrets --release smoke`
7. `support-bundle --release smoke`
8. Verify bundle archive created and contains expected files
9. `uninstall --release smoke --yes`

### Makefile targets

```makefile
shellcheck:
    shellcheck -s bash -e SC1091 cli/biznez-cli

test-cli:
    bash tests/test-cli.sh

test-cli-integration-fast:
    bash tests/smoke-test.sh

test-cli-integration-full:
    bash tests/smoke-test.sh --full
```

## Key Patterns to Reuse

- **Secret generation (container-based Fernet):** `compose/setup.sh:113-128` (docker run for Fernet, openssl fallback)
- **Output helpers:** `compose/setup.sh:48-52` (`[INFO]`, `[OK]`, `[WARN]`, `[ERROR]` prefixes)
- **Version comparison:** `compose/setup.sh:75-76` (cut-based major.minor parsing)
- **sed portability:** `compose/setup.sh:150-153` (`sed -i.bak` + `rm .bak` for macOS/Linux)
- **Migration Job spec:** `templates/backend/migration-job.yaml` (rendered via `helm template --show-only`)

## `set -euo pipefail` Safety Patterns

With `set -e` active, any command returning non-zero kills the script. Commands that may legitimately fail must be handled explicitly:

```bash
# Pattern 1: Capture exit code via if/else
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    ok "Namespace $NAMESPACE exists"
else
    die "Namespace $NAMESPACE does not exist. Create it: kubectl create namespace $NAMESPACE"
fi

# Pattern 2: Capture exit code with || for subshell assignment
local _out _rc=0
_out=$(some_command 2>&1) || _rc=$?
if [ "$_rc" -ne 0 ]; then
    error "Command failed: $_out"
    exit $EXIT_VALIDATE
fi

# Pattern 3: || true for optional checks
local _pod_status
_pod_status=$(kubectl get pods -l "..." -o jsonpath='...' 2>/dev/null) || true

# Pattern 4: Explicit || for grep miss
if echo "$output" | grep -q "pattern" 2>/dev/null; then
    # found
else
    # not found — this is expected, not an error
fi

# Pattern 5: Function wrapper for probes
_check_endpoint() {
    local url="$1" timeout="${2:-10}"
    local rc=0
    curl -sf --max-time "$timeout" "$url" >/dev/null 2>&1 || rc=$?
    return $rc
}

# Pattern 6: _collect_optional for support-bundle / cluster-wide commands
_collect_optional() {
    local label="$1" outfile="$2"; shift 2
    if "$@" > "$outfile" 2>&1; then
        ok "Collected: $label"
    else
        warn "Skipped: $label ($(head -1 "$outfile"))"
        echo "# SKIPPED: $label" > "$outfile"
    fi
}
```

## Bash 3.2 Compatibility Notes

### Features to AVOID (Bash 4.0+ only)

| Feature | Alternative |
|---------|-------------|
| `declare -A` (associative arrays) | Multiple simple variables |
| `${var,,}` / `${var^^}` (case) | `echo "$var" \| tr '[:upper:]' '[:lower:]'` |
| `mapfile` / `readarray` | `while IFS= read -r line; do ...; done` |
| `\|&` (pipe stderr) | `2>&1 \|` |
| `coproc` | Temp files or named pipes |
| `&>>` (append both) | `>> file 2>&1` |
| `declare -g` | Assign without declare |
| Negative array indexing | `${arr[${#arr[@]}-1]}` |

### Safe patterns
- Indexed arrays, `[[ ]]`, `printf`, `local`, parameter expansion (`${var:-default}`), arithmetic `$(( ))`
- `sed -i.bak` + `rm .bak` for macOS/Linux portability
- `$RANDOM` is available in Bash 3.2 (but prefer deterministic port sequence over random for port-forward)

## Verification

1. **shellcheck:** `shellcheck -s bash cli/biznez-cli` — zero errors/warnings
2. **Unit tests:** `bash tests/test-cli.sh` — all pass without cluster
3. **Lint:** `make lint` still passes (no Helm changes)
4. **Smoke-fast with kind:**
   - `biznez-cli generate-secrets --format yaml -n test | kubectl apply -f -`
   - `biznez-cli validate -f tests/values/eval.yaml -n test`
   - `biznez-cli install -f tests/values/eval.yaml -n test --release smoke`
   - `biznez-cli health-check -n test --release smoke`
5. **Smoke-full with kind:** adds migrate, validate-secrets, support-bundle, uninstall
6. **Bash 3.2 compatibility:** Test on macOS default bash (`/bin/bash --version`)
