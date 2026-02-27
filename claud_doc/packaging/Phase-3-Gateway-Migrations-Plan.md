# Plan: Phase 3 -- Gateway & Migrations (v4 -- final)

## Context

Phase 0 (repo scaffold), Phase 1 (Chart.yaml, values.yaml, _helpers.tpl), and Phase 2 (core service templates) are complete. The chart produces a working backend + frontend + postgres stack. Phase 3 adds the **Agent Gateway** (MCP proxy) service and **database migration infrastructure** so the full four-service stack runs and migrations can be executed in all three modes (auto/hook/manual).

**Repo:** `/Users/manimaun/Documents/code/biznez-runtime-dist`
**Branch:** New branch from current HEAD (to be created at implementation time)

---

## Feedback Addressed (v1 -> v2 -> v3)

### v1 -> v2 changes

| # | Feedback | Resolution |
|---|----------|------------|
| 1 | Migration mode naming inconsistency | Canonical set: `auto \| hook \| manual`. `auto` = initContainer. Add `{{ fail }}` guard. |
| 2 | RBAC expectations conflict with Phase 2 | **Option A:** Phase 3 stays ServiceAccount-only. No Role/RoleBinding. |
| 3 | Migration runner needs workingDir guard | Added `migration.workingDir` (default `/app`). |
| 4 | Gateway secret envFrom references missing secret | `envFrom` conditional on secrets existing. |
| 5 | Gateway config may not match binary schema | Known-good config in eval.yaml. |
| 6 | Gateway probes -- tcpSocket vs httpGet | Keeping tcpSocket. |
| 7 | Migration job conditional precision | Renders only when `mode == "hook"`. |
| 8 | `ttlSecondsAfterFinished` nil check wrong | Fixed nil check. |
| 9 | initContainers parent conditional | Fixed to OR waitForDb and migration auto. |
| 10 | Manual mode verification expects error | Fixed to grep -c kind check. |
| 11 | Advisory lock exit criteria mismatch | Deferred to Phase 3.1. |
| 12 | Migration resources/securityContext overrides | Added `migration.resources` and `migration.containerSecurityContext`. |
| 13 | Verification grep commands unreliable | Rewrote with `--show-only` and `grep -c`. |

### v2 -> v3 changes

| # | Feedback | Resolution |
|---|----------|------------|
| 14 | Gateway config example inconsistent with runtime binary schema | **Fixed:** `values.yaml` `gateway.config` now uses the actual `binds`-based schema that the agentgateway binary expects. Removed incorrect `listeners/targets/routes` top-level keys. `tests/values/eval.yaml` uses a known-good minimal `binds` config copied from the runtime reference. |
| 15 | Migration fail-fast guard in wrong place | **Fixed:** Created `templates/_validate.tpl` for all validation guards. Always processed by Helm regardless of `--show-only` target. |
| 16 | `--show-only` with empty output and `wc -l` is fragile | **Fixed:** All "should render nothing" checks use `grep -c "kind: ..."` expecting 0, not `wc -l`. |
| 17 | Gateway `checksum/secret` can't checksum existingSecret | **Acknowledged:** `checksum/secret` only covers chart-generated secrets. Document that `existingSecret` rotation requires manual rollout restart. |
| 18 | Migration securityContext merge logic overcomplicated | **Simplified:** Use `biznez.containerSecurityContext` with backend component directly (same as initContainer). Override via `migration.containerSecurityContext` only if non-empty, using a simple conditional (not mustMergeOverwrite). |
| 19 | `migration.resources` defaulting with empty map | **Fixed:** Use `{{- if empty .Values.migration.resources }}` then `backend.resources` else `migration.resources`. |
| 20 | Verification #13 helm.sh/hook count brittle | **Fixed:** Check `helm.sh/hook:` and `helm.sh/hook-delete-policy:` separately, each expected 1. |
| 21 | Migration job should include workingDir check | **Added:** Check #24 verifies `workingDir` in migration-job.yaml. |

### v3 -> v4 changes (final pre-implementation pass)

| # | Feedback | Resolution |
|---|----------|------------|
| 22 | Gateway minimal config must be verbatim from runtime, not simplified | **Fixed:** eval.yaml config copied verbatim from runtime reference minimal structure: `binds[].port` + `binds[].listeners[].name` + `binds[].listeners[].routes`. Confirmed no `address`/`bindHost`/`protocol` fields required at bind level. |
| 23 | `_validate.tpl` must output nothing (no stray whitespace) | **Confirmed:** All content wrapped in `{{- ... -}}` (whitespace-trimming delimiters). No `---` separator. |
| 24 | Migration securityContext override replaces defaults entirely | **Documented:** Added values.yaml comment: "Replaces all defaults; set full context explicitly if overriding." |
| 25 | waitForDb disabled + auto migration = potential crashloop | **Documented:** Added values.yaml comment under waitForDb: disabling with `migration.mode: auto` can cause migration failures if DB isn't ready. |
| 26 | `--set migration.jobTtlSeconds=null` shell robustness | **Noted:** Verification uses `--set-json 'migration.jobTtlSeconds=null'` for robustness. |
| 27 | Verification grep patterns tightened | **Fixed:** Check #8 uses `grep -c "  binds:"` (indented, avoids comment matches). Checks #6/#7 use `grep -c "envFrom:"` (with colon). |

---

## Files to Create / Modify

### New Files (6)

| # | File | Purpose |
|---|------|---------|
| 1 | `templates/gateway/deployment.yaml` | Agent Gateway Deployment (conditional on `gateway.enabled`) |
| 2 | `templates/gateway/service.yaml` | Gateway ClusterIP service with MCP + admin ports |
| 3 | `templates/gateway/configmap.yaml` | Gateway YAML configuration (binds-based passthrough) |
| 4 | `templates/gateway/secret.yaml` | Gateway secrets -- MCP target API keys (conditional) |
| 5 | `templates/backend/migration-job.yaml` | Migration Job (renders **only** when `migration.mode == "hook"`) |
| 6 | `templates/_validate.tpl` | Validation guards (migration.mode check, future guards) |

### Files to Modify (3)

| # | File | Change |
|---|------|--------|
| 7 | `templates/backend/deployment.yaml` | Add migration initContainer when `migration.mode == "auto"`. Fix `initContainers:` parent conditional. |
| 8 | `helm/biznez-runtime/values.yaml` | Update `gateway.config` to `binds`-based schema. Add `migration.command`, `migration.workingDir`, `migration.resources`, `migration.containerSecurityContext`. |
| 9 | `tests/values/eval.yaml` | Add `migration.mode: auto`, known-good `binds`-based gateway config. |

### Files to Delete (1)

| # | File | Reason |
|---|------|--------|
| 10 | `templates/gateway/_placeholder.tpl` | Replaced by real gateway templates |

---

## Key Design Decisions

### 1. Gateway config mount path and args
From the runtime reference (`k8s/mcp-gateway/deployment.yaml`):
- Config mounted at `/etc/agentgateway/config.yaml` (readOnly)
- Container args: `["-f", "/etc/agentgateway/config.yaml"]`
- Two ports: `mcp` (8080) and `admin` (15000)

### 2. Gateway secret injection: conditional `envFrom`
Gateway uses `envFrom` to inject the entire secret as env vars (keys are user-defined, must match `${VAR}` refs in gateway config).

**Critical guard:** The `envFrom` secretRef block is only rendered when a secret actually exists:
```yaml
{{- if or .Values.gateway.existingSecret (not (empty .Values.gateway.secrets)) }}
          envFrom:
            - secretRef:
                name: {{ include "biznez.gatewaySecretName" . }}
{{- end }}
```
This prevents referencing a non-existent secret when `gateway.enabled=true` but no secrets are configured.

### 3. Gateway config: `binds`-based schema (matching runtime binary)
The agentgateway binary expects a `binds`-based YAML structure. The runtime reference (`k8s/mcp-gateway/configmap.yaml`) confirms the top-level key is `binds`, with `listeners` nested inside each bind entry.

**`values.yaml` `gateway.config`** uses the actual binary schema:
```yaml
gateway:
  config:
    binds:
      - port: 8080
        listeners:
          - name: default
            routes: []
```

The ConfigMap renders `gateway.config` as-is using `toYaml`. This is a passthrough -- the chart does NOT validate the config structure; the gateway binary does. But by using the correct schema in defaults and test values, we ensure the eval profile produces a config the binary actually accepts.

### 4. Migration command and workingDir
No `migration_runner.py` module exists yet in the runtime repo. Phase 3 uses `alembic upgrade head` directly. The Helm template uses configurable `migration.command` and `migration.workingDir` fields.

**Default command:** `["alembic", "upgrade", "head"]`
**Default workingDir:** `/app` (where the backend image has `alembic.ini` and the `alembic/` directory)

Override to `["python", "-m", "agentic_runtime.db.migration_runner"]` once that module is created in the runtime repo.

### 5. Migration mode: canonical set with fail-fast
Allowed values: `auto | hook | manual`
- `auto` = initContainer on backend deployment (runs before backend starts)
- `hook` = Helm pre-install/pre-upgrade Job
- `manual` = no migration resources rendered; operator runs migrations externally

**Fail-fast guard** in `templates/_validate.tpl` (always processed by Helm):
```yaml
{{- $validModes := list "auto" "hook" "manual" }}
{{- if not (has .Values.migration.mode $validModes) }}
{{- fail (printf "migration.mode must be one of: auto, hook, manual. Got: %s" .Values.migration.mode) }}
{{- end }}
```
This catches typos at `helm template` / `helm install` time regardless of which templates are being rendered.

### 6. Helm hook annotations for `hook` mode
- `helm.sh/hook: pre-install,pre-upgrade`
- `helm.sh/hook-weight: "-5"` (run before anything else)
- `helm.sh/hook-delete-policy: before-hook-creation`

### 7. `ttlSecondsAfterFinished` conditional rendering
```yaml
{{- if ne .Values.migration.jobTtlSeconds nil }}
ttlSecondsAfterFinished: {{ .Values.migration.jobTtlSeconds }}
{{- end }}
```
When `jobTtlSeconds` is explicitly `null` in values, the field is omitted entirely. When set to a number (including 0), it's rendered.

### 8. RBAC: ServiceAccount only (no Role/RoleBinding in Phase 3)
Phase 2 created only a ServiceAccount. Phase 3 keeps this unchanged:
- Migration jobs only need network access to PostgreSQL, not K8s API permissions.
- Gateway only routes MCP traffic, no K8s API interaction.
- The `biznez-cli migrate` workflow (future) uses the **operator's** kubectl permissions, not the in-cluster ServiceAccount.
- Role/RoleBinding will be added in a later phase if needed.

### 9. Gateway probes: tcpSocket
Keeping tcpSocket (confirmed by runtime reference). Values already specify appropriate `initialDelaySeconds`, `periodSeconds`, `failureThreshold`. Passed through via `toYaml`.

### 10. Gateway checksum/secret limitation
`checksum/secret` annotation only covers chart-generated secrets (it hashes the template output). When using `gateway.existingSecret`, the chart cannot read the secret content (no cluster access at render time), so changes to the external secret do NOT trigger pod restarts. Operators must run `kubectl rollout restart` after rotating secrets referenced via `existingSecret`. This is documented in the gateway deployment template as a comment.

### 11. Advisory lock: deferred to Phase 3.1
The advisory-lock wrapper (`migration_runner.py`) is a runtime-repo change, not a Helm chart change. Phase 3 delivers the Helm infrastructure (job template, initContainer, configurable command). Phase 3.1 (runtime repo) delivers the advisory-lock module. Once created, operators switch `migration.command` to `["python", "-m", "agentic_runtime.db.migration_runner"]`.

---

## Template Specifications

### 1. `templates/_validate.tpl`

Always processed by Helm. Outputs nothing on success (all content uses `{{- ... -}}` whitespace-trimming delimiters), fails on invalid config. No `---` YAML separator.

```yaml
{{- /*
Validation guards. Always processed by Helm regardless of --show-only target.
Outputs nothing -- fail-fast only. All delimiters use whitespace trimming.
*/ -}}
{{- $validModes := list "auto" "hook" "manual" -}}
{{- if not (has .Values.migration.mode $validModes) -}}
{{- fail (printf "migration.mode must be one of: auto, hook, manual. Got: %s" .Values.migration.mode) -}}
{{- end -}}
```

Future validation guards (e.g., production profile checks, impossible network policy config) will also go here.

### 2. `templates/gateway/deployment.yaml`

```
Conditional: {{- if .Values.gateway.enabled }}
```

**Pod spec:**
- `serviceAccountName` (conditional on `rbac.create`)
- `podSecurityContext` via shared helper
- Checksum annotations:
  - `checksum/config`: always (configmap hash)
  - `checksum/secret`: only when `!gateway.existingSecret` AND `gateway.secrets` is non-empty
- Comment: `# NOTE: When using gateway.existingSecret, secret rotation requires: kubectl rollout restart deployment/{{ fullname }}-gateway`

**Container spec:**
- Name: `gateway`
- Image: `{{ include "biznez.imageRef" (dict "root" . "image" .Values.gateway.image) }}`
- Args: `["-f", "/etc/agentgateway/config.yaml"]`
- Ports: `mcp` (8080/TCP), `admin` (15000/TCP)
- `envFrom`: **conditional** -- only rendered when `gateway.existingSecret` is set OR `gateway.secrets` is non-empty
  ```yaml
  {{- if or .Values.gateway.existingSecret (not (empty .Values.gateway.secrets)) }}
            envFrom:
              - secretRef:
                  name: {{ include "biznez.gatewaySecretName" . }}
  {{- end }}
  ```
- `env`: `gateway.extraEnv` (toYaml passthrough)
- Probes: `gateway.probes.liveness` and `gateway.probes.readiness` (toYaml passthrough)
- Resources: `gateway.resources`
- Security context: shared helper `biznez.containerSecurityContext`
- Volume mounts:
  - `/tmp` (shared helper)
  - `/etc/agentgateway` (configMap volume, readOnly)
  - `gateway.extraVolumeMounts`

**Volumes:**
- `tmp` (shared helper)
- `gateway-config` (configMap: `{{ fullname }}-gateway`)
- `gateway.extraVolumes`

**Extensibility:** `nodeSelector`, `tolerations`, `affinity`, `podAnnotations`

### 3. `templates/gateway/service.yaml`

```
Conditional: {{- if .Values.gateway.enabled }}
```

- Type: `{{ .Values.gateway.service.type | default "ClusterIP" }}`
- Ports:
  - `mcp`: port `{{ .Values.gateway.service.port }}` (8080), targetPort `mcp`
  - `admin`: port `{{ .Values.gateway.service.adminPort }}` (15000), targetPort `admin`
- Selector: `biznez.componentSelectorLabels` with component `gateway`
- Annotations: `gateway.service.annotations`

### 4. `templates/gateway/configmap.yaml`

```
Conditional: {{- if .Values.gateway.enabled }}
```

- Name: `{{ fullname }}-gateway`
- Data key: `config.yaml`
- Value: `{{ toYaml .Values.gateway.config | nindent 4 }}` (passthrough of entire gateway.config block)

### 5. `templates/gateway/secret.yaml`

```
Conditional: {{- if and .Values.gateway.enabled (not .Values.gateway.existingSecret) (not (empty .Values.gateway.secrets)) }}
```

Three-way conditional: gateway must be enabled, no existingSecret, AND secrets map must be non-empty.

- Name: `{{ fullname }}-gateway`
- Type: `Opaque`
- Data:
  ```
  {{- range $key, $value := .Values.gateway.secrets }}
  {{ $key }}: {{ $value | b64enc | quote }}
  {{- end }}
  ```

### 6. `templates/backend/migration-job.yaml`

```
Conditional: {{- if eq .Values.migration.mode "hook" }}
```

Renders **only** when mode is exactly `"hook"`. Not for `auto` or `manual`.

**Job metadata:**
- Name: `{{ fullname }}-migration`
- Annotations:
  - `helm.sh/hook: pre-install,pre-upgrade`
  - `helm.sh/hook-weight: "-5"`
  - `helm.sh/hook-delete-policy: before-hook-creation`
- Labels: `biznez.componentLabels` with component `migration`

**Job spec:**
- `backoffLimit: 3`
- `activeDeadlineSeconds: 600`
- `ttlSecondsAfterFinished`: conditional
  ```
  {{- if ne .Values.migration.jobTtlSeconds nil }}
  ttlSecondsAfterFinished: {{ .Values.migration.jobTtlSeconds }}
  {{- end }}
  ```

**Pod template:**
- `restartPolicy: Never`
- `serviceAccountName` (conditional on `rbac.create`)
- `podSecurityContext` via shared helper

**Container:**
- Name: `migration`
- Image: same as backend (`biznez.imageRef` with `.Values.backend.image`)
- `workingDir: {{ .Values.migration.workingDir | default "/app" | quote }}`
- Command: `{{ toYaml .Values.migration.command | nindent 12 }}`
- `envFrom`: same as backend (`biznez.backend.envFrom` helper)
- `env`: same as backend (`biznez.backend.envVars` helper)
- Resources (with safe empty-map defaulting):
  ```yaml
  {{- if empty .Values.migration.resources }}
          resources:
            {{- toYaml .Values.backend.resources | nindent 12 }}
  {{- else }}
          resources:
            {{- toYaml .Values.migration.resources | nindent 12 }}
  {{- end }}
  ```
- Security context (simplified -- reuse backend directly, conditional override only if non-empty):
  ```yaml
  {{- if empty .Values.migration.containerSecurityContext }}
          securityContext:
            {{- include "biznez.containerSecurityContext" (dict "root" . "component" .Values.backend) | nindent 12 }}
  {{- else }}
          securityContext:
            {{- toYaml .Values.migration.containerSecurityContext | nindent 12 }}
  {{- end }}
  ```
  When `migration.containerSecurityContext` is empty (default), uses the same shared helper as backend. When explicitly set, uses the override directly. No complicated merge logic.
- Volume mounts: `/tmp` (shared helper)

**Volumes:** `tmp` (shared helper)

### 7. `templates/backend/deployment.yaml` -- Modifications

**Change 1: Fix initContainers parent conditional**

Current:
```yaml
{{- if .Values.backend.waitForDb.enabled }}
      initContainers:
        - name: wait-for-db
          ...
{{- end }}
```

New:
```yaml
{{- if or .Values.backend.waitForDb.enabled (eq .Values.migration.mode "auto") }}
      initContainers:
{{- if .Values.backend.waitForDb.enabled }}
        - name: wait-for-db
          ...
{{- end }}
{{- if eq .Values.migration.mode "auto" }}
        - name: run-migrations
          image: {{ include "biznez.imageRef" (dict "root" . "image" .Values.backend.image) }}
          imagePullPolicy: {{ include "biznez.imagePullPolicy" (dict "root" . "image" .Values.backend.image) }}
          securityContext:
            {{- include "biznez.containerSecurityContext" (dict "root" . "component" .Values.backend) | nindent 12 }}
          workingDir: {{ .Values.migration.workingDir | default "/app" | quote }}
          command:
            {{- toYaml .Values.migration.command | nindent 12 }}
          envFrom:
            {{- include "biznez.backend.envFrom" . | nindent 12 }}
          env:
            {{- include "biznez.backend.envVars" . | nindent 12 }}
          volumeMounts:
            {{- include "biznez.tmpVolumeMount" . | nindent 12 }}
{{- end }}
{{- end }}
```

The ordering is:
1. `wait-for-db` (if `backend.waitForDb.enabled`) -- ensures DB is accepting connections
2. `run-migrations` (if `migration.mode == "auto"`) -- runs Alembic before backend starts

**Note:** Migration mode fail-fast guard is NOT in this file -- it's in `_validate.tpl`.

**Note:** If `backend.waitForDb.enabled: false` but `migration.mode: auto`, the migration initContainer may start before postgres is ready (especially with embedded postgres). This is expected -- the user explicitly disabled wait-for-db. Add a comment in `values.yaml` under `waitForDb`: "Disabling waitForDb with migration.mode=auto can cause migration failures if the database is not ready."

### 8. Delete `templates/gateway/_placeholder.tpl`

Remove the placeholder file since real gateway templates now exist.

### 9. `values.yaml` updates

**Gateway config -- change to `binds`-based schema:**

```yaml
gateway:
  # ...existing fields unchanged...

  # Gateway YAML configuration (rendered into ConfigMap).
  # Structure must match the agentgateway binary's expected schema.
  # The binary uses a binds-based config with listeners nested inside each bind.
  # See: https://github.com/agentgateway/agentgateway for schema docs.
  config:
    binds:
      - port: 8080
        listeners:
          - name: default
            routes: []
    # Example with targets and auth:
    # binds:
    #   - port: 8080
    #     listeners:
    #       - name: mcp-gateway
    #         routes:
    #           - name: tavily-route
    #             matches:
    #               - path:
    #                   pathPrefix: "/org_dev001/tavily"
    #             policies:
    #               jwtAuth:
    #                 mode: strict
    #                 issuer: "https://idp.example.com"
    #                 audiences: ["app-client-id"]
    #                 jwks:
    #                   url: "https://idp.example.com/.well-known/jwks.json"
    #             backends:
    #               - mcp:
    #                   targets:
    #                     - name: tavily-mcp
    #                       mcp:
    #                         host: "https://mcp.tavily.com/mcp"
```

**Migration section -- add new fields:**

```yaml
migration:
  # Mode: auto | hook | manual
  #   auto: initContainer runs migrations before backend starts
  #   hook: Helm pre-install/pre-upgrade Job (blocks deploy until migration completes)
  #   manual: no migration resources rendered; operator runs migrations externally
  mode: auto

  # Job TTL (seconds after completion) for hook mode.
  # Set to null to omit (for clusters without TTL controller).
  jobTtlSeconds: 600

  # Migration command. Override when using advisory-lock wrapper module:
  #   command: ["python", "-m", "agentic_runtime.db.migration_runner"]
  command:
    - alembic
    - upgrade
    - head

  # Working directory for migration container.
  # Must contain alembic.ini and alembic/ directory.
  workingDir: /app

  # Resource overrides for migration containers.
  # Defaults to backend.resources if empty.
  resources: {}

  # Security context overrides for migration containers.
  # Defaults to backend security context if empty.
  # WARNING: Setting this replaces all defaults; provide the full context explicitly.
  containerSecurityContext: {}
```

### 10. `tests/values/eval.yaml` update

```yaml
# ... existing content (global, backend, postgres sections) ...

migration:
  mode: auto

# Known-good minimal gateway config matching agentgateway binary schema.
# Uses the binds-based structure that the binary expects.
# Copied from runtime reference: k8s/mcp-gateway/configmap.yaml (minimal version).
gateway:
  config:
    binds:
      - port: 8080
        listeners:
          - name: default
            routes: []
```

---

## Existing Helpers to Reuse

| Helper | Used By |
|--------|---------|
| `biznez.fullname` | All new templates |
| `biznez.componentLabels` / `biznez.componentSelectorLabels` | Gateway deployment/service, migration job |
| `biznez.imageRef` / `biznez.imagePullPolicy` | Gateway deployment, migration job/initContainer |
| `biznez.gatewaySecretName` | Gateway deployment envFrom (conditional), gateway secret |
| `biznez.podSecurityContext` / `biznez.containerSecurityContext` | All new templates |
| `biznez.backend.envFrom` / `biznez.backend.envVars` | Migration job + initContainer |
| `biznez.tmpVolume` / `biznez.tmpVolumeMount` | Gateway deployment, migration job |
| `biznez.serviceAccountName` | Gateway deployment, migration job |

---

## Verification

After all files are created/modified, run these checks:

```bash
# Working directory: /Users/manimaun/Documents/code/biznez-runtime-dist

# 1. Helm lint
helm lint helm/biznez-runtime/

# 2. Full template render -- no errors
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml

# --- Gateway checks ---

# 3a. Gateway deployment renders when enabled
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/gateway/deployment.yaml | grep -c "kind: Deployment"
# Expected: 1

# 3b. Gateway service renders when enabled
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/gateway/service.yaml | grep -c "kind: Service"
# Expected: 1

# 3c. Gateway configmap renders when enabled
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/gateway/configmap.yaml | grep -c "kind: ConfigMap"
# Expected: 1

# 3d. Gateway secret NOT rendered when secrets map is empty (default)
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/gateway/secret.yaml 2>&1 | grep -c "kind: Secret"
# Expected: 0

# 3e. Gateway secret renders when secrets provided
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set gateway.secrets.TEST_KEY=test123 \
  --show-only templates/gateway/secret.yaml | grep -c "kind: Secret"
# Expected: 1

# 4. Gateway disabled skips all gateway resources
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set gateway.enabled=false \
  --show-only templates/gateway/deployment.yaml 2>&1 | grep -c "kind: Deployment"
# Expected: 0

# 5. Gateway existingSecret skips chart-generated secret
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set gateway.existingSecret=my-gw-secret \
  --show-only templates/gateway/secret.yaml 2>&1 | grep -c "kind: Secret"
# Expected: 0

# 6. Gateway deployment does NOT have envFrom when no secrets configured
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/gateway/deployment.yaml | grep -c "envFrom:"
# Expected: 0

# 7. Gateway deployment HAS envFrom when existingSecret set
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set gateway.existingSecret=my-gw-secret \
  --show-only templates/gateway/deployment.yaml | grep -c "envFrom:"
# Expected: 1

# 8. Gateway configmap contains binds-based config (indented to avoid comment matches)
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/gateway/configmap.yaml | grep -c "  binds:"
# Expected: 1

# 9. Gateway deployment has config mount at /etc/agentgateway
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/gateway/deployment.yaml | grep -c "/etc/agentgateway"
# Expected: 1

# --- Migration checks ---

# 10. Migration initContainer rendered when mode=auto
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set migration.mode=auto \
  --show-only templates/backend/deployment.yaml | grep -c "run-migrations"
# Expected: 1

# 11. Migration initContainer includes workingDir
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set migration.mode=auto \
  --show-only templates/backend/deployment.yaml | grep -c "workingDir"
# Expected: 1

# 12. Migration hook Job renders when mode=hook
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set migration.mode=hook \
  --show-only templates/backend/migration-job.yaml | grep -c "kind: Job"
# Expected: 1

# 13a. Migration hook Job has helm.sh/hook annotation
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set migration.mode=hook \
  --show-only templates/backend/migration-job.yaml | grep -c "helm.sh/hook:"
# Expected: 1

# 13b. Migration hook Job has hook-delete-policy annotation
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set migration.mode=hook \
  --show-only templates/backend/migration-job.yaml | grep -c "helm.sh/hook-delete-policy:"
# Expected: 1

# 14. No migration Job when mode=manual
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set migration.mode=manual \
  --show-only templates/backend/migration-job.yaml 2>&1 | grep -c "kind: Job"
# Expected: 0

# 15. No migration initContainer when mode=manual
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set migration.mode=manual \
  --show-only templates/backend/deployment.yaml | grep -c "run-migrations"
# Expected: 0

# 16. No migration initContainer when mode=hook
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set migration.mode=hook \
  --show-only templates/backend/deployment.yaml | grep -c "run-migrations"
# Expected: 0

# 17. Migration job uses same DATABASE_URL env as backend
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set migration.mode=hook \
  --show-only templates/backend/migration-job.yaml | grep -c "DATABASE_URL"
# Expected: 1

# 18. ttlSecondsAfterFinished rendered with default value (600)
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set migration.mode=hook \
  --show-only templates/backend/migration-job.yaml | grep -c "ttlSecondsAfterFinished"
# Expected: 1

# 19. ttlSecondsAfterFinished omitted when null
# Using --set-json for robust null handling across shells
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set migration.mode=hook --set-json 'migration.jobTtlSeconds=null' \
  --show-only templates/backend/migration-job.yaml | grep -c "ttlSecondsAfterFinished"
# Expected: 0

# 20. Invalid migration mode fails with clear message
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set migration.mode=typo 2>&1 | grep -c "must be one of"
# Expected: 1

# --- Resource kind checks ---

# 21. Verify resource kinds with mode=auto (default eval)
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml | grep "^kind:" | sort -u
# Expected: ConfigMap, Deployment, Secret, Service, ServiceAccount, StatefulSet
# (No Job because mode=auto uses initContainer, not hook Job.
#  No Role/RoleBinding -- Phase 2 only has ServiceAccount.)

# 22. Verify resource kinds with mode=hook (Job appears)
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set migration.mode=hook | grep "^kind:" | sort -u
# Expected: ConfigMap, Deployment, Job, Secret, Service, ServiceAccount, StatefulSet

# --- Additional migration job checks ---

# 23. Migration initContainer renders even when waitForDb is disabled
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set migration.mode=auto --set backend.waitForDb.enabled=false \
  --show-only templates/backend/deployment.yaml | grep -c "run-migrations"
# Expected: 1

# 24. Migration job includes workingDir
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set migration.mode=hook \
  --show-only templates/backend/migration-job.yaml | grep -c "workingDir"
# Expected: 1
```

---

## Exit Criteria

- [ ] Gateway Deployment renders when `gateway.enabled: true`
- [ ] Gateway skipped entirely when `gateway.enabled: false`
- [ ] Gateway config YAML uses `binds`-based schema matching binary expectations
- [ ] Gateway secrets injected via `envFrom` only when secrets exist
- [ ] Gateway deployment does NOT reference a missing secret when no secrets configured
- [ ] Gateway `existingSecret` rotation limitation documented in template comment
- [ ] Migration initContainer blocks backend startup when `mode: auto`
- [ ] Migration initContainer renders even when `waitForDb` is disabled
- [ ] Migration hook Job runs with correct Helm annotations when `mode: hook`
- [ ] No migration resources rendered when `mode: manual`
- [ ] Invalid migration mode fails at template time with clear error message (via `_validate.tpl`)
- [ ] Migration job and initContainer use identical env vars as backend Deployment
- [ ] `ttlSecondsAfterFinished` omitted when set to null
- [ ] `workingDir` set correctly so alembic finds `alembic.ini`
- [ ] `migration.resources` defaults to `backend.resources` when empty (safe empty-map handling)
- [ ] `migration.containerSecurityContext` defaults to backend when empty (no overcomplicated merge)
- [ ] No Role/RoleBinding resources (ServiceAccount only, consistent with Phase 2)
- [ ] All 24 verification checks pass

### Deferred to Phase 3.1 (Runtime Repo Enhancement)

- [ ] `migration_runner.py` module with `pg_try_advisory_lock(738291456)` wrapper
- [ ] Advisory lock prevents concurrent migrations
- [ ] Lock ID `738291456` documented as constant
- [ ] 30 retries, 2s apart = 60s max wait
- [ ] Once created, operators switch `migration.command` to `["python", "-m", "agentic_runtime.db.migration_runner"]`

---

## Git Workflow

1. Create branch (name TBD, from current HEAD)
2. Create 6 new files, modify 3 existing files, delete 1 placeholder
3. Run all 24 verification checks
4. Commit and push
5. Create PR to `main`
