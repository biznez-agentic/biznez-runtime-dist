# Plan: Phase 4 -- Networking (Ingress, Gateway API, NetworkPolicy)

## Context

Phases 0-3 are complete. The chart has backend, frontend, postgres, gateway, and migration infrastructure. Three networking placeholder files exist (`ingress.yaml`, `gateway-api.yaml`, `networkpolicy.yaml`). Phase 4 populates them so services are accessible via Ingress (or Gateway API) and NetworkPolicy enforces isolation.

**Repo:** `/Users/manimaun/Documents/code/biznez-runtime-dist`
**Branch:** New branch from current HEAD

---

## Feedback Changelog

### v2 (round 1)

| # | Feedback | Resolution |
|---|----------|------------|
| 1 | Validation file name mismatch | Clarified: all guards append to existing `templates/validate.yaml` (Phase 3 file). No new file, no split. |
| 2 | NetworkPolicy impossible config check too strict | **Removed** the `{{ fail }}` guard entirely. Locked-down clusters are valid. |
| 3 | Frontend ingress rule "allow from any namespace" unsafe | Added `networkPolicy.ingress.allowFromAnyNamespace: false` opt-in flag with `{{ fail }}` guard. |
| 4 | Test #14 expects 4 policies but depends on gateway/postgres enabled | Explicitly set both in `tests/values/networkpolicy.yaml`. |
| 5 | Ingress host counting check brittle | Changed to grep actual hostnames. |
| 6 | Service name/port helpers should fail loudly | Added `{{ fail }}` in helper + inline ingress template validation. |
| 7 | Gateway API CRD check -- make v1 requirement explicit | Made fail message explicit with v1-only statement. |
| 8 | NOTES.txt non-blocking | Confirmed: no `required()` in NOTES.txt, only `{{ if }}` conditionals. |

### v3 (round 2)

| # | Feedback | Resolution |
|---|----------|------------|
| 9 | Validate file: `_validate.tpl` vs `validate.yaml` -- clarify Helm behavior and confirm which exists | **Empirically verified.** Repo has `templates/validate.yaml`. Tested: `_validate.tpl` top-level `{{ fail }}` does NOT execute (underscore files only load `{{ define }}` blocks). `validate.yaml` top-level `{{ fail }}` DOES execute, even with `--show-only` targeting another template. **Keep `validate.yaml`.** See Decision 13 for full rationale. |
| 10 | Gateway API `required` for `gatewayRef.name` -- ensure it's inside the enabled guard; optionally duplicate as validate guard | Added `gatewayRef.name` non-empty check in `validate.yaml` (cleaner error message). The `required` in gateway-api.yaml is kept as defense-in-depth but the validate.yaml guard fires first. |
| 11 | Ingress enabled with empty hosts list -- inline range validation silently passes | Added `validate.yaml` guard: `ingress.enabled=true` requires `len(hosts) > 0`. Also: `tls.enabled=true` requires `len(hosts) > 0`. |
| 12 | Annotation merging: document merge strategy explicitly | Documented: annotations are flat key/value, use `mustMergeOverwrite` (available in Helm's sprig). Build base dict, overwrite with streaming, overwrite with cert-manager, overwrite with per-host (splitByHost). See Decision 14. |
| 13 | Backend ingress "from ingress namespace" -- should only apply when ingress routes to backend | Simplified: apply ingress namespace rule to backend whenever `namespaceSelector` is set AND `ingress.enabled=true`. Since we support path routing to backend, this is always needed when ingress is enabled. No per-route analysis. |
| 14 | Verification #3 -- splitByHost hostname counts not verified | Acknowledged: splitByHost hostname counts are implicitly covered by check #6 (2 Ingress resources) + check #7 (cert-manager annotations). No additional check needed. |
| 15 | Gateway API CRD fail message includes URL -- keep it concise | Shortened message. URL kept but message tightened to 2 lines. |

### v4 (round 3 -- final tweaks before coding)

| # | Feedback | Resolution |
|---|----------|------------|
| 16 | Verification checks #9 and #10 masked by "hosts non-empty" guard | Fixed: both checks now include `--set-json` with a minimal host+path so the intended guard fires. `--set-json` confirmed working in Helm 4.0.0. |
| 17 | Confirm `mustMergeOverwrite` availability | **Verified.** Helm 4.0.0 includes `mustMergeOverwrite` in sprig. Tested with a scratch chart: correctly does shallow last-write-wins merge on flat maps. |
| 18 | Inline ingress validation should also validate `paths` non-empty per host | Added: inline loop checks `len(.paths) == 0` per host and `{{ fail }}`. |
| 19 | Gateway API CRD heuristic -- confirm check is inside `gatewayApi.enabled` guard | Confirmed: CRD check is inside `{{- if .Values.gatewayApi.enabled }}` in `gateway-api.yaml`. Already specified in plan. |
| 20 | NetworkPolicy backend ingress namespace rule -- ensure template condition is exact | Clarified: template must use `{{- if and .Values.ingress.enabled (or (not (empty ...namespaceSelector)) .Values.networkPolicy.ingress.allowFromAnyNamespace) }}`. No accidental fallthrough. |

---

## Files to Create / Modify

### Files to Modify (5)

| # | File | Change |
|---|------|--------|
| 1 | `templates/_helpers.tpl` | Add 3 new helpers: `biznez.ingressServiceName`, `biznez.ingressServicePort`, `biznez.networkPolicy.dnsEgress` |
| 2 | `templates/ingress.yaml` | Replace placeholder with full Ingress template (multiHost + splitByHost modes) with inline service validation |
| 3 | `templates/gateway-api.yaml` | Replace placeholder with HTTPRoute template + CRD check (v1 explicit) |
| 4 | `templates/networkpolicy.yaml` | Replace placeholder with 4 per-component NetworkPolicy resources |
| 5 | `templates/validate.yaml` | Append: TLS validation, ingress mode, ingress hosts non-empty, mutual exclusion, frontend namespace guard, gatewayRef.name guard |

### Files to Update (2)

| # | File | Change |
|---|------|--------|
| 6 | `templates/NOTES.txt` | Add conditional Ingress/GatewayAPI/NetworkPolicy status sections (informational only, no `required()`) |
| 7 | `values.yaml` | Add splitByHost per-host override comments + add `networkPolicy.ingress.allowFromAnyNamespace: false` |

### Test Values to Create (4)

| # | File | Purpose |
|---|------|---------|
| 8 | `tests/values/ingress-multihost.yaml` | Test multiHost mode with TLS + nginx streaming annotations |
| 9 | `tests/values/ingress-splitbyhost.yaml` | Test splitByHost mode with per-host className/annotations + certManager |
| 10 | `tests/values/networkpolicy.yaml` | Test NetworkPolicy with allowAllHttps + explicit gateway/postgres enabled |
| 11 | `tests/values/gatewayapi.yaml` | Test Gateway API HTTPRoutes |

---

## Key Design Decisions

### 1. Ingress modes: multiHost vs splitByHost

- **multiHost** (default): Single Ingress resource with all hosts in one `rules[]` block. Simpler, works for most cases.
- **splitByHost**: One Ingress per host entry. Each can have its own `className` and `annotations` override. Resource naming: `{{ fullname }}-{{ host with dots replaced by dashes, truncated to 63 chars }}`.

### 2. Ingress service name resolution + inline validation

New helper `biznez.ingressServiceName` maps `paths[].service` ("backend", "frontend", "gateway") to `{{ fullname }}-{{ service }}`. New helper `biznez.ingressServicePort` resolves port from `paths[].port` or falls back to the component's `service.port` from values. **Fails with `{{ fail }}` on unknown service names.**

Additionally, the ingress template itself validates each `paths[].service` is set and is one of `backend`, `frontend`, or `gateway` before calling the helpers. This gives a clear error at the ingress template level, not just inside the helper.

### 3. Nginx streaming annotations

When `ingress.applyNginxStreamingAnnotations: true`, the template adds:
- `nginx.ingress.kubernetes.io/proxy-read-timeout: "{{ backend.streaming.proxyReadTimeout }}"`
- `nginx.ingress.kubernetes.io/proxy-send-timeout: "{{ backend.streaming.proxySendTimeout }}"`
- `nginx.ingress.kubernetes.io/proxy-buffering: "{{ backend.streaming.proxyBuffering }}"`
- `nginx.ingress.kubernetes.io/proxy-body-size: "{{ backend.streaming.maxBodySize }}"`

### 4. TLS secret name resolution

- **existingSecret mode**: Uses `ingress.tls.secretName` directly.
- **certManager mode**: Uses `ingress.tls.secretName` if provided, otherwise auto-generates `{{ fullname }}-tls`. cert-manager populates this automatically.

### 5. Gateway API CRD check (v1 explicit, concise message)

`.Capabilities.APIVersions.Has "gateway.networking.k8s.io/v1"` only works on `helm install/upgrade` (live cluster). During `helm template` (no cluster), Capabilities is empty. Use `apps/v1` as a heuristic for "live cluster":
```
if gatewayApi.enabled AND NOT Has("gateway.networking.k8s.io/v1"):
  if Has("apps/v1"):  # live cluster detected, CRDs genuinely missing
    {{ fail "Gateway API CRDs (gateway.networking.k8s.io/v1) not found. Install v1 CRDs first (v1beta1 is not supported)." }}
  # else: helm template mode, skip check
```

### 6. NetworkPolicy: 4 per-component policies

| Component | Ingress From | Egress To |
|-----------|--------------|-----------|
| Backend | frontend, gateway, ingress namespace (conditional) | DNS, postgres, gateway, HTTPS/proxy/cidrs |
| Frontend | ingress namespace (see decision 8) | DNS, backend |
| PostgreSQL | backend only | deny all (`egress: []`) |
| Gateway | backend | DNS, HTTPS/proxy/cidrs, MCP targets |

Postgres and gateway policies are conditional on their respective `enabled` flags.

### 7. DNS egress helper

New helper `biznez.networkPolicy.dnsEgress` renders the DNS egress rule block (namespaceSelector, podSelector, ports with both UDP and TCP). Used by all 3 non-postgres policies.

### 8. Frontend ingress namespace safety

**Problem**: When `networkPolicy.enabled=true` and ingress is enabled, the frontend needs to receive traffic from the ingress controller. If `networkPolicy.ingress.namespaceSelector` is empty, v1 proposed "allow from any namespace" as a fallback -- this is too permissive.

**Solution**: New value `networkPolicy.ingress.allowFromAnyNamespace: false` (default).

Behavior:
- If `namespaceSelector` is configured: use it (targeted allow from ingress controller namespace).
- If `namespaceSelector` is empty AND `allowFromAnyNamespace: true`: allow from any namespace (explicit opt-in).
- If `namespaceSelector` is empty AND `allowFromAnyNamespace: false` AND both `ingress.enabled` and `networkPolicy.enabled`: `{{ fail }}` in validate.yaml with message:
  ```
  "networkPolicy.ingress.namespaceSelector is required when both ingress and networkPolicy are enabled.
   Set it to match your ingress controller's namespace (e.g., {matchLabels: {kubernetes.io/metadata.name: ingress-nginx}}).
   Alternatively, set networkPolicy.ingress.allowFromAnyNamespace=true to allow from any namespace (less secure)."
  ```

### 9. No impossible config guard

**Removed** the `{{ fail }}` that fired when `networkPolicy.enabled=true` AND `allowAllHttps=false` AND no proxy/external CIDRs. A locked-down cluster with only internal egress (DNS + postgres + gateway) is a valid and common configuration. Operators who enable NetworkPolicy know their network topology.

### 10. Mutual exclusion: Ingress + Gateway API

`{{ fail }}` if both `ingress.enabled` and `gatewayApi.enabled` are true. They create conflicting routing and should not be used together.

### 11. Proxy env var injection: deferred

PACKAGING-PLAN mentions injecting `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` into backend/gateway deployments when proxy is configured. This requires modifying Phase 2/3 templates. **Deferred to Phase 4.1** to keep Phase 4 focused on the three networking templates. NetworkPolicy proxy CIDR rules work independently of the env vars.

### 12. NOTES.txt is informational only

`NOTES.txt` uses only `{{ if }}` conditionals and plain text/`{{ .Values.xxx }}` references. **No `{{ required }}` calls.** All fail-fast validation lives in `validate.yaml`. If a value is empty, NOTES.txt shows a placeholder or skips the section gracefully.

### 13. Validation file: `validate.yaml` (not `_validate.tpl`) -- EMPIRICALLY VERIFIED

**Background**: Phase 3 created `templates/validate.yaml` containing top-level `{{ fail }}` guards wrapped in `{{- ... -}}` whitespace trimming (outputs no YAML).

**Empirical test results** (verified in this planning session):

| File | Top-level `{{ fail }}` runs? | Runs with `--show-only` other template? |
|------|------|------|
| `templates/validate.yaml` | YES | YES -- fail fires even when `--show-only templates/backend/deployment.yaml` |
| `templates/_validate.tpl` | NO | NO -- underscore files only load `{{ define }}` blocks; top-level code is ignored |

**Why `_validate.tpl` doesn't work**: Helm processes underscore-prefixed files but only extracts `{{ define }}` blocks from them. Top-level code outside `{{ define }}` is silently discarded. This is documented Helm behavior for template partials.

**Why `validate.yaml` works**: Helm processes ALL non-underscore `.yaml`/`.tpl`/`.txt` files in `templates/`. Even when `--show-only` targets a specific template, Helm must evaluate all templates to resolve cross-template dependencies. The `{{ fail }}` fires during evaluation, before the `--show-only` filter is applied.

**Why not put guards inside `{{ define }}` in `_validate.tpl` and `{{ include }}` them?**: This would require every template to `{{ include }}` the validation helper, creating coupling. The current approach (standalone `validate.yaml` with top-level guards) is self-contained and always runs.

**Decision**: Keep `templates/validate.yaml`. All Phase 4 guards append to this file.

### 14. Annotation merging strategy (NEW in v3)

Ingress annotations are flat key/value maps (not nested). Merge strategy:

1. **Base**: Start with `$annotations := dict` (empty).
2. **User annotations**: `$annotations = mustMergeOverwrite $annotations .Values.ingress.annotations` -- apply user-provided annotations.
3. **Streaming annotations** (if `applyNginxStreamingAnnotations`): `$annotations = mustMergeOverwrite $annotations $streamingAnnotations` -- add nginx SSE timeout annotations.
4. **cert-manager annotation** (if `tls.mode == "certManager"`): `$annotations = mustMergeOverwrite $annotations $certManagerAnnotation`.
5. **splitByHost per-host overrides**: `$annotations = mustMergeOverwrite $annotations $hostAnnotations` -- per-host annotations override everything.

`mustMergeOverwrite` is available in Helm's bundled sprig library. **Verified working in Helm 4.0.0** (tested with a scratch chart -- correctly merges flat maps with last-write-wins). No deep merge needed since annotations are always flat key/value.

For multiHost mode, steps 1-4 produce the final annotation set. For splitByHost, step 5 is added per-host.

### 15. Backend ingress "from ingress namespace" -- conditional on ingress.enabled (NEW in v3, TIGHTENED in v4)

The backend NetworkPolicy ingress rule for "from ingress namespace" (via `namespaceSelector`) is only added when:
- `ingress.enabled=true` (ingress routes traffic to backend via path routing)
- AND `namespaceSelector` is set (or `allowFromAnyNamespace` is true)

If ingress is disabled, the backend only receives traffic from frontend and gateway pods. No ingress namespace rule is needed.

**Template condition must be exact** (v4 clarification):
```
{{- if and .Values.ingress.enabled (or (not (empty .Values.networkPolicy.ingress.namespaceSelector)) .Values.networkPolicy.ingress.allowFromAnyNamespace) }}
- from:
  {{- if not (empty .Values.networkPolicy.ingress.namespaceSelector) }}
  - namespaceSelector:
      {{- toYaml .Values.networkPolicy.ingress.namespaceSelector | nindent 6 }}
  {{- else }}
  - namespaceSelector: {}  # allowFromAnyNamespace=true
  {{- end }}
{{- end }}
```

This prevents accidental fallthrough when `ingress.enabled=false`.

### 16. Gateway API `gatewayRef.name` validation (NEW in v3)

When `gatewayApi.enabled=true`, `gatewayRef.name` must be non-empty. This is enforced in two places:
1. **`validate.yaml`**: `{{ fail }}` guard with clear message: `"gatewayApi.gatewayRef.name is required when gatewayApi is enabled"`. This fires first and gives a clean single-source error.
2. **`gateway-api.yaml`**: `{{ required }}` on `gatewayRef.name` (defense-in-depth, kept as a safety net).

### 17. Ingress enabled requires hosts; each host requires paths (NEW in v3, TIGHTENED in v4)

New `validate.yaml` guards:
- `ingress.enabled=true` AND `len(ingress.hosts) == 0`: `{{ fail "ingress.hosts must contain at least one host when ingress is enabled" }}`
- `ingress.tls.enabled=true` AND `len(ingress.hosts) == 0`: `{{ fail "ingress.hosts must contain at least one host when TLS is enabled" }}`

Per-host path validation in `ingress.yaml` inline loop (v4 addition):
- Each host must have at least one path: `{{ fail "ingress.hosts[].paths must contain at least one path for host '...'" }}` when `.paths` is empty/nil. This runs before the `.service` validation loop, catching hosts with missing paths before they produce confusing empty-rule output.

---

## Template Specifications

### 1. New Helpers in `_helpers.tpl`

**`biznez.ingressServiceName`**: Maps service shorthand to full K8s service name.
```
Params: dict "root" . "service" "backend"
Output: {{ fullname }}-backend
```

**`biznez.ingressServicePort`**: Resolves port for a service. Uses explicit `port` if provided, otherwise falls back to component service port from values.
```
Params: dict "root" . "service" "backend" "port" 8000
Fallbacks: backend->8000, frontend->80, gateway->8080
{{ fail }} on unknown service name with message:
  "Unknown ingress service '{{ .service }}'. Must be one of: backend, frontend, gateway"
```

**`biznez.networkPolicy.dnsEgress`**: Renders the DNS egress rule block from `networkPolicy.egress.dns.*` values.
```
Output: - to: [namespaceSelector + podSelector] ports: [53/UDP, 53/TCP]
```

### 2. `templates/ingress.yaml`

```
Guard: {{- if .Values.ingress.enabled }}
```

**Inline validation** (at top of template, inside guard):
```
{{- range .Values.ingress.hosts }}
  {{- if not .paths }}
  {{- fail (printf "ingress.hosts[].paths must contain at least one path for host '%s'" .host) }}
  {{- end }}
  {{- range .paths }}
    {{- $validServices := list "backend" "frontend" "gateway" }}
    {{- if not (has .service $validServices) }}
    {{- fail (printf "ingress.hosts[].paths[].service must be one of: backend, frontend, gateway. Got: '%s'" (.service | default "<empty>")) }}
    {{- end }}
  {{- end }}
{{- end }}
```

**Annotation assembly** (using `mustMergeOverwrite`, see Decision 14):
1. Start with empty dict
2. Merge `ingress.annotations` (user-provided)
3. If `applyNginxStreamingAnnotations`: merge nginx SSE annotations from `backend.streaming.*`
4. If `tls.mode == "certManager"`: merge `cert-manager.io/cluster-issuer` annotation
5. (splitByHost only) Merge per-host `.annotations` overrides

**multiHost branch** (`ingress.mode == "multiHost"`):
- Single Ingress resource named `{{ fullname }}`
- Labels: `biznez.labels` (not component-specific -- ingress is cross-cutting)
- `ingressClassName`: conditional on `ingress.className`
- TLS block: all hosts in one `tls[]` entry, `secretName` from resolution logic
- Rules: `range .Values.ingress.hosts`, each with `range .paths` using service name/port helpers

**splitByHost branch** (`ingress.mode == "splitByHost"`):
- One Ingress per `ingress.hosts[]` entry, separated by `---`
- Name: `{{ fullname }}-{{ host | replace "." "-" | trunc 63 }}`
- `ingressClassName`: per-host `.className` overrides global
- Annotations: per-host `.annotations` merged on top of base via `mustMergeOverwrite`
- TLS block: single host per Ingress
- Rules: single host with `range .paths`

### 3. `templates/gateway-api.yaml`

```
Guard: {{- if .Values.gatewayApi.enabled }}
CRD check: fail if Has("apps/v1") but NOT Has("gateway.networking.k8s.io/v1")
  Message: "Gateway API CRDs (gateway.networking.k8s.io/v1) not found. Install v1 CRDs first (v1beta1 is not supported)."
```

- One HTTPRoute per `gatewayApi.httpRoutes[]` entry
- Name: `{{ fullname }}-{{ .service }}`
- Labels: `biznez.labels`
- `parentRefs`: `{{ required }} gatewayRef.name`, optional `gatewayRef.namespace`
- `hostnames`: `[.hostname]`
- `rules`: single PathPrefix `/` match, `backendRefs` using service name/port helpers

Note: `{{ required }}` for `gatewayRef.name` is inside the `{{- if .Values.gatewayApi.enabled }}` guard so it only evaluates when Gateway API is active. The `validate.yaml` guard fires first with a cleaner message.

### 4. `templates/networkpolicy.yaml`

```
Guard: {{- if .Values.networkPolicy.enabled }}
```

Renders up to 4 NetworkPolicy resources (backend, frontend, postgres if enabled, gateway if enabled). Each has:
- Name: `{{ fullname }}-{{ component }}`
- Labels: `biznez.componentLabels`
- `podSelector`: `biznez.componentSelectorLabels`
- `policyTypes: [Ingress, Egress]`

**Backend policy:**
- Ingress: from frontend pods, from gateway pods (if enabled), from ingress namespace (if `ingress.enabled` AND (`namespaceSelector` configured OR `allowFromAnyNamespace`))
- Egress: DNS, postgres pods (if enabled), gateway pods (if enabled), allowAllHttps, proxy cidrs, externalServices cidrs

**Frontend policy:**
- Ingress: from ingress namespace (if `namespaceSelector` configured OR `allowFromAnyNamespace`)
- Egress: DNS, backend pods only

**PostgreSQL policy** (conditional on `postgres.enabled`):
- Ingress: from backend pods only
- Egress: `[]` (deny all)

**Gateway policy** (conditional on `gateway.enabled`):
- Ingress: from backend pods
- Egress: DNS, allowAllHttps, proxy cidrs, externalServices cidrs, MCP target namespace selectors

### 5. `templates/validate.yaml` -- Appended Guards

Append after existing migration.mode check in the existing `validate.yaml` file:

**Ingress hosts non-empty** (when `ingress.enabled`):
- Fail if `len(ingress.hosts) == 0`

**TLS hosts non-empty** (when `ingress.enabled` AND `tls.enabled`):
- Fail if `len(ingress.hosts) == 0` (redundant with above but gives TLS-specific message)

**TLS validation** (when `ingress.enabled` AND `tls.enabled`):
- `existingSecret` mode requires `secretName` non-empty
- `certManager` mode requires `clusterIssuer` non-empty
- Unknown TLS mode fails

**Ingress mode validation** (when `ingress.enabled`):
- Must be `multiHost` or `splitByHost`

**Mutual exclusion**:
- Fail if both `ingress.enabled` and `gatewayApi.enabled`

**Frontend ingress namespace guard** (when `networkPolicy.enabled` AND `ingress.enabled`):
- Fail if `namespaceSelector` empty AND `allowFromAnyNamespace` false
- Message includes guidance to set namespaceSelector or opt-in to allowFromAnyNamespace

**Gateway API gatewayRef.name** (when `gatewayApi.enabled`):
- Fail if `gatewayRef.name` is empty

Note: Per-host `paths` non-empty validation is in `ingress.yaml` inline loop (not in validate.yaml) because it needs to iterate over hosts and provide the hostname in the error message.

### 6. `templates/NOTES.txt`

Add conditional sections for **both** eval and production profile blocks. **All output is informational -- no `{{ required }}` calls.**

**Ingress section** (when `ingress.enabled`):
- Mode, hosts list, TLS status
- Uses `{{ if }}` conditionals only

**Gateway API section** (when `gatewayApi.enabled`):
- Routes list, gateway ref
- Uses `{{ if }}` conditionals only

**NetworkPolicy section** (when `networkPolicy.enabled`):
- Egress strategy summary
- Uses `{{ if }}` conditionals only

**Production warning** (when `networkPolicy.enabled=false` in production profile):
- Warning to enable network policies (plain text, not a fail)

### 7. `values.yaml` -- Updates

Add commented `className` and `annotations` keys under the `hosts` example to document splitByHost per-host overrides:
```yaml
  hosts: []
  # - host: api.biznez.example.com
  #   paths:
  #     - path: /
  #       service: backend
  #       port: 8000
  #   # splitByHost per-host overrides (ignored in multiHost mode):
  #   # className: nginx-internal
  #   # annotations:
  #   #   nginx.ingress.kubernetes.io/ssl-redirect: "true"
```

Add new value under `networkPolicy.ingress`:
```yaml
networkPolicy:
  ...
  ingress:
    namespaceSelector: {}
    # Opt-in: allow ingress from any namespace when namespaceSelector is empty.
    # Only relevant when both networkPolicy and ingress are enabled.
    # When false (default), namespaceSelector is required to avoid overly permissive rules.
    allowFromAnyNamespace: false
```

---

## Test Values Files

### `tests/values/ingress-multihost.yaml`
- `ingress.enabled: true`, `mode: multiHost`, `className: nginx`
- Two hosts: `api.biznez.example.com` -> backend:8000, `app.biznez.example.com` -> frontend:80
- `tls.enabled: true`, `mode: existingSecret`, `secretName: biznez-tls`
- `applyNginxStreamingAnnotations: true`
- Include eval.yaml secrets (extend from eval.yaml)

### `tests/values/ingress-splitbyhost.yaml`
- `ingress.enabled: true`, `mode: splitByHost`
- Two hosts with per-host `className` override
- `tls.enabled: true`, `mode: certManager`, `clusterIssuer: letsencrypt-prod`

### `tests/values/networkpolicy.yaml`
- `networkPolicy.enabled: true`
- `networkPolicy.ingress.namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: ingress-nginx}}`
- `egress.allowAllHttps: true`
- **`gateway.enabled: true`** (explicit -- ensures 4 policies)
- **`postgres.enabled: true`** (explicit -- ensures 4 policies)
- **`ingress.enabled: true`** (to trigger backend ingress namespace rule)
- **`ingress.hosts`**: at least one host with backend path (satisfies ingress hosts non-empty guard)

### `tests/values/gatewayapi.yaml`
- `gatewayApi.enabled: true`, `ingress.enabled: false` (mutual exclusion)
- `gatewayRef: {name: main-gateway, namespace: gateway-system}`
- Two routes: backend + frontend

All test values files include the base eval secrets (postgres password, encryption key, JWT secret) to avoid `required` failures.

---

## Verification (25 checks)

```bash
# Working directory: /Users/manimaun/Documents/code/biznez-runtime-dist

# 1. Helm lint with all value files
helm lint helm/biznez-runtime/ -f tests/values/eval.yaml

# --- Ingress: multiHost ---

# 2. multiHost renders single Ingress
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml -f tests/values/ingress-multihost.yaml \
  --show-only templates/ingress.yaml | grep -c "kind: Ingress"
# Expected: 1

# 3a. multiHost Ingress has api hostname (tls + rule = 2 occurrences)
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml -f tests/values/ingress-multihost.yaml \
  --show-only templates/ingress.yaml | grep -c "api.biznez.example.com"
# Expected: 2

# 3b. multiHost Ingress has app hostname (tls + rule = 2 occurrences)
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml -f tests/values/ingress-multihost.yaml \
  --show-only templates/ingress.yaml | grep -c "app.biznez.example.com"
# Expected: 2

# 4. Nginx streaming annotations present
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml -f tests/values/ingress-multihost.yaml \
  --show-only templates/ingress.yaml | grep -c "proxy-read-timeout"
# Expected: 1

# 5. TLS secretName rendered
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml -f tests/values/ingress-multihost.yaml \
  --show-only templates/ingress.yaml | grep -c "secretName: biznez-tls"
# Expected: 1

# --- Ingress: splitByHost ---

# 6. splitByHost renders 2 Ingress resources
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml -f tests/values/ingress-splitbyhost.yaml \
  --show-only templates/ingress.yaml | grep -c "kind: Ingress"
# Expected: 2

# 7. cert-manager annotation present
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml -f tests/values/ingress-splitbyhost.yaml \
  --show-only templates/ingress.yaml | grep -c "cert-manager.io/cluster-issuer"
# Expected: 2 (one per Ingress)

# --- Ingress: disabled ---

# 8. Default eval (ingress disabled) renders no Ingress
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/ingress.yaml 2>&1 | grep -c "kind: Ingress"
# Expected: 0

# --- Ingress: validation ---

# 9. TLS existingSecret without secretName fails
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set ingress.enabled=true --set ingress.tls.enabled=true --set ingress.tls.mode=existingSecret \
  --set-json 'ingress.hosts=[{"host":"x.example.com","paths":[{"path":"/","service":"backend"}]}]' \
  2>&1 | grep -c "secretName"
# Expected: 1 (error message about secretName being required)

# 10. Invalid ingress mode fails
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set ingress.enabled=true --set ingress.mode=invalid \
  --set-json 'ingress.hosts=[{"host":"x.example.com","paths":[{"path":"/","service":"backend"}]}]' \
  2>&1 | grep -c "must be one of"
# Expected: 1 (error message about ingress mode)

# 11. Ingress + Gateway API mutual exclusion fails
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set ingress.enabled=true --set gatewayApi.enabled=true \
  2>&1 | grep -c "not both"
# Expected: 1

# 12. Ingress enabled with empty hosts fails
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set ingress.enabled=true \
  2>&1 | grep -c "at least one host"
# Expected: 1

# 13. Ingress host with empty paths fails
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set ingress.enabled=true \
  --set-json 'ingress.hosts=[{"host":"x.example.com","paths":[]}]' \
  2>&1 | grep -c "at least one path"
# Expected: 1

# --- Gateway API ---

# 14. HTTPRoutes render (helm template mode, CRD check skipped)
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml -f tests/values/gatewayapi.yaml \
  --show-only templates/gateway-api.yaml | grep -c "kind: HTTPRoute"
# Expected: 2

# 15. HTTPRoute has parentRefs
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml -f tests/values/gatewayapi.yaml \
  --show-only templates/gateway-api.yaml | grep -c "parentRefs:"
# Expected: 2

# 16. Gateway API without gatewayRef.name fails
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set gatewayApi.enabled=true \
  2>&1 | grep -c "gatewayRef.name"
# Expected: 1

# --- NetworkPolicy ---

# 17. NetworkPolicy renders 4 policies (backend, frontend, postgres, gateway)
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml -f tests/values/networkpolicy.yaml \
  --show-only templates/networkpolicy.yaml | grep -c "kind: NetworkPolicy"
# Expected: 4

# 18. DNS egress has both UDP and TCP
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml -f tests/values/networkpolicy.yaml \
  --show-only templates/networkpolicy.yaml | grep -c "protocol: UDP"
# Expected: 3 (backend, frontend, gateway -- postgres has no egress)

# 19. PostgreSQL policy has empty egress
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml -f tests/values/networkpolicy.yaml \
  --show-only templates/networkpolicy.yaml | grep -c "egress: \[\]"
# Expected: 1

# 20. Gateway disabled = 3 policies
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml -f tests/values/networkpolicy.yaml \
  --set gateway.enabled=false \
  --show-only templates/networkpolicy.yaml | grep -c "kind: NetworkPolicy"
# Expected: 3

# 21. Postgres disabled = 3 policies
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml -f tests/values/networkpolicy.yaml \
  --set postgres.enabled=false \
  --show-only templates/networkpolicy.yaml | grep -c "kind: NetworkPolicy"
# Expected: 3

# 22. Frontend namespace guard fires when ingress + networkPolicy enabled without namespaceSelector
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --set networkPolicy.enabled=true --set ingress.enabled=true \
  2>&1 | grep -c "namespaceSelector"
# Expected: 1 (error message)

# 23. NetworkPolicy disabled renders nothing
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml \
  --show-only templates/networkpolicy.yaml 2>&1 | grep -c "kind: NetworkPolicy"
# Expected: 0

# --- Cross-cutting ---

# 24. Resource kinds with ingress enabled
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml -f tests/values/ingress-multihost.yaml \
  | grep "^kind:" | sort -u
# Expected: ConfigMap, Deployment, Ingress, Secret, Service, ServiceAccount, StatefulSet

# 25. Full render with all eval defaults (no networking) still works
helm template test helm/biznez-runtime/ -f tests/values/eval.yaml 2>&1 | head -5
# Expected: no errors
```

**Note**: Checks #9 and #10 include `--set-json` with a minimal host+path to bypass the "hosts non-empty" guard so the intended TLS/mode validation fires. `--set-json` confirmed working in Helm 4.0.0.

---

## Exit Criteria

- [ ] Ingress multiHost mode renders single Ingress with multiple hosts
- [ ] Ingress splitByHost mode renders one Ingress per host with per-host overrides
- [ ] TLS existingSecret references secret, no cert-manager annotations
- [ ] TLS certManager adds cert-manager annotation
- [ ] TLS validation: `{{ fail }}` on ambiguous config
- [ ] Nginx streaming annotations applied when `applyNginxStreamingAnnotations: true`
- [ ] Annotation merging uses `mustMergeOverwrite` correctly (flat maps, last-write-wins)
- [ ] Gateway API HTTPRoutes rendered with correct parentRefs and backendRefs
- [ ] Gateway API CRD check fires on live cluster without CRDs, skipped during `helm template`, message explicitly states v1 required
- [ ] Gateway API `gatewayRef.name` validated in validate.yaml + required in template
- [ ] Ingress + Gateway API mutual exclusion enforced
- [ ] Ingress enabled requires non-empty hosts list
- [ ] NetworkPolicy renders per-component policies with correct ingress/egress rules
- [ ] DNS egress includes both UDP and TCP port 53
- [ ] PostgreSQL egress is deny-all
- [ ] Frontend egress limited to backend only
- [ ] Backend ingress namespace rule only added when ingress.enabled=true
- [ ] Frontend ingress namespace guard: fails when namespaceSelector empty + allowFromAnyNamespace false + both ingress and networkPolicy enabled
- [ ] Invalid ingress paths[].service name caught with clear error message
- [ ] All networking templates skipped when disabled (no orphaned resources)
- [ ] NOTES.txt shows networking status when enabled (informational only, no `required()`)
- [ ] All validation guards live in `templates/validate.yaml` (single source of truth)
- [ ] Each ingress host entry requires at least one path (inline validation)
- [ ] All 25 verification checks pass

### Deferred to Phase 4.1

- [ ] Proxy env var injection (`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`) into backend/gateway deployments
- [ ] SSE acceptance test script (curl-based, validates streaming through nginx-ingress)
- [ ] NetworkPolicy smoke test on real cluster

---

## Existing Helpers to Reuse

| Helper | Used By |
|--------|---------|
| `biznez.fullname` | All new templates |
| `biznez.labels` | Ingress, HTTPRoute (cross-cutting, not component-specific) |
| `biznez.componentLabels` / `biznez.componentSelectorLabels` | NetworkPolicy per-component |
| `biznez.publicUrl.frontend` / `biznez.publicUrl.api` | Already reads ingress.hosts -- no changes needed |

## New Helpers to Create

| Helper | Purpose |
|--------|---------|
| `biznez.ingressServiceName` | Maps "backend"/"frontend"/"gateway" to `{{ fullname }}-{{ service }}` |
| `biznez.ingressServicePort` | Resolves port from explicit value or component service port; `{{ fail }}` on unknown service |
| `biznez.networkPolicy.dnsEgress` | Renders DNS egress rule block for NetworkPolicy |
