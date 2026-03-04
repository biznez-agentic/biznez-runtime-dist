# Fix Frontend Runtime Config: Build Once, Deploy Anywhere

## Context

The frontend Docker image bakes the API URL (`VITE_API_BASE_URL`) into the compiled JavaScript at build time via Vite. Once built, the URL cannot be changed. This means:
- The current image has `https://dev-api.35.246.109.199.nip.io` hardcoded 6+ times in the JS bundle
- Deploying that same image to a new eval environment fails — it still calls the old dev URL
- Every new environment would need a separate image build with a different URL

The Helm chart (dist repo) already creates an `env-config.js` file via ConfigMap and mounts it to `/usr/share/nginx/html/env-config.js`. But the frontend ignores it because:
1. `index.html` has no `<script>` tag loading `env-config.js`
2. The app code reads `import.meta.env.VITE_API_BASE_URL` (baked at build time) instead of `window.__ENV__.API_BASE_URL`

## Goal

Build the frontend image **once** and deploy it to any environment (dev, eval, production) by providing the API URL at deploy time — not at build time.

## Important: No Disruption to Dev Environment

The dev environment currently works with `VITE_API_BASE_URL` baked in at build time. These changes preserve backwards compatibility:
- `import.meta.env.VITE_API_BASE_URL` remains as a fallback in `config.ts`
- If `window.__ENV__` is missing or empty, the app falls back to the build-time value
- The dev CI pipeline can continue passing `VITE_API_BASE_URL` as a Docker build arg — it just becomes the fallback instead of the only source
- No code paths change for dev unless `env-config.js` is loaded with different values

## URL Convention: Base URL Does NOT Include `/api/v1` — Hard Proof

### Evidence from codebase search

**`config.ts` (the canonical config):**
- Line 72: `baseURL` fallback is `http://localhost:8000` (no `/api/v1`)

**`config.js` (duplicate, inconsistent — to be deleted):**
- Line 9: `baseURL` is `http://localhost:8000/api/v1` — this is WRONG and inconsistent with `config.ts`

**`apiClient.ts`** — The bridge between config and OpenAPI:
- Line 41: `OpenAPI.BASE = config.api.baseURL` — sets OpenAPI.BASE from config (no `/api/v1`)
- This is the single point where the config value flows into the generated API client

**Generated OpenAPI services (all include `/api/v1` in their URL paths):**
- `AdminConnectorsService.ts`: `url: '/api/v1/admin/connectors/definitions'`
- `HealthService.ts`: `url: '/api/v1/health'`
- `AgentsService.ts`: `url: '/api/v1/agents'`
- Exception: `RootService.ts`: `url: '/'` (root endpoint, no prefix)

**Manual services (all prepend `/api/v1` themselves):**
- `observabilityService.ts`: `` `${OpenAPI.BASE}/api/v1/observability/...` ``
- `userUsageService.ts`: `` `${OpenAPI.BASE}/api/v1/usage/me...` ``
- `usageService.ts`: `` `${OpenAPI.BASE}/api/v1/admin/usage/...` ``

**Manual hooks (all prepend `/api/v1` themselves):**
- `useDeployment.ts`: `` `${API_BASE_URL}/api/v1/deployments` ``
- `useRuntimes.ts`: `` `${API_BASE_URL}/api/v1/runtimes` ``
- `useAgentRegistration.ts`: `` `${API_BASE_URL}/api/v1/...` ``
- `useWorkspaceCreation.ts`: `` `${API_BASE_URL}/api/v1/...` ``

**Explicit comments confirming convention:**
- `opencodeService.ts` line 86: `"baseURL (from config.api.baseURL) does NOT include /api/v1"`

**Edge case — `api.js`:**
- Line 52: `` `${config.api.baseURL}/auth/refresh` `` — no `/api/v1` prefix. This is either intentional (a root-level auth endpoint) or a bug, but confirms `config.api.baseURL` is expected to be host+port only.

### Conclusion

`API_BASE_URL` must be just the host+port (e.g., `http://localhost:8000`), NOT `http://localhost:8000/api/v1`. Including `/api/v1` would produce double paths like `/api/v1/api/v1/health`.

The Dockerfile currently has `ARG VITE_API_BASE_URL=http://localhost:8000/api/v1` — this is inconsistent with `config.ts` but doesn't break things because when the build arg is set via CI, it overrides the default. **Do not change this Dockerfile default** — it works as-is in dev and changing it risks breaking dev. The runtime `env-config.js` values should use the correct convention (no `/api/v1`).

## Changes

### Runtime Repo Changes (5 files modified, 1 new file)

These changes happen in `biznez-agentic-runtime` (`/Users/manimaun/Documents/code/biznez-agentic-framework`). This dist repo session is read-only for the runtime repo per CLAUDE.md, so these changes need to be made in a runtime repo session.

#### 1. `frontend/index.html` — Load env-config.js before the app (with inline fallback)

Add `<script src="/env-config.js"></script>` in the `<head>`, before the app bundle. Include an inline fallback so the app still works even if env-config.js fails to load (e.g., 404, network error).

```html
<head>
    <meta charset="UTF-8" />
    <link rel="icon" type="image/svg+xml" href="/vite.svg" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>frontend</title>
    <script>window.__ENV__ = window.__ENV__ || {};</script>
    <script src="/env-config.js"></script>
</head>
```

- The inline `<script>` runs first, setting `window.__ENV__` to an empty object.
- If `env-config.js` loads successfully, it overwrites `window.__ENV__` with real values.
- If `env-config.js` fails (404, network error), `window.__ENV__` remains `{}` and `config.ts` falls back to build-time values. The app does not crash.
- Both scripts are regular (not `type="module"`), so they execute synchronously in order.

#### 2. `frontend/public/env-config.js` — New file: default config for local dev

```javascript
// Runtime configuration — overridden per-environment.
// Kubernetes: Helm ConfigMap mounted over this file.
// Local dev: this default is used as-is.
window.__ENV__ = {
  API_BASE_URL: "http://localhost:8000",
  WS_BASE_URL: ""
};
```

- Vite serves `public/` files as-is (no bundling). Ships in the Docker image as the default.
- Helm mounts the ConfigMap over it at deploy time.
- `WS_BASE_URL` defaults to empty string — WebSocket hook auto-derives from `API_BASE_URL` by replacing `http://` with `ws://`.

#### 3. `frontend/src/config/config.ts` — Read runtime config, fallback to build-time

```typescript
// Runtime config (from env-config.js loaded in index.html)
const runtimeEnv = (window as any).__ENV__ || {};

// Warn if runtime config is missing in production (not local dev)
if (!runtimeEnv.API_BASE_URL && import.meta.env.PROD) {
  console.warn('[config] window.__ENV__ not loaded — falling back to build-time config. Check env-config.js is served.');
}

const config: Config = {
  api: {
    baseURL: runtimeEnv.API_BASE_URL || import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000',
    timeout: 30000,
  },
  // ...
  zitadel: {
    // Zitadel config stays build-time for now — same values across all environments.
    // If Zitadel config needs to vary per environment later, add ZITADEL_ISSUER and
    // ZITADEL_CLIENT_ID to window.__ENV__ (env-config.js) and the Helm ConfigMap.
    issuer: runtimeEnv.ZITADEL_ISSUER || import.meta.env.VITE_ZITADEL_ISSUER || 'https://biznez-dev-swfsuq.us1.zitadel.cloud',
    clientId: runtimeEnv.ZITADEL_CLIENT_ID || import.meta.env.VITE_ZITADEL_CLIENT_ID || '353931821110585508',
    redirectUri: `${window.location.origin}/auth/callback`,
    scopes: ['openid', 'profile', 'email', 'offline_access'],
  },
  agentGateway: {
    baseUrl: runtimeEnv.AGENT_GATEWAY_URL || import.meta.env.VITE_AGENT_GATEWAY_URL || 'http://35.246.33.196',
    timeout: 30000,
  },
}
```

- Remove debug `console.log` lines (current lines 66-67).
- The `console.warn` in production helps diagnose missing `env-config.js` without crashing.
- Fallback chain: runtime `window.__ENV__` → build-time `import.meta.env` → hardcoded default.

#### 4. `frontend/src/hooks/useWebSocket.ts` — Read WS_BASE_URL from runtime config

Update `getWsBaseUrl()` (line 18-28) to check runtime config first.

**Important:** The auto-derivation fallback uses `config.api.baseURL` (from config.ts) instead of `OpenAPI.BASE`. This ensures the WebSocket URL always reflects the runtime config, even if `configureApiClient()` hasn't been called yet.

```typescript
import config from '../config/config'

const getWsBaseUrl = (): string => {
  const runtimeEnv = (window as any).__ENV__ || {};
  // 1. Runtime config WS_BASE_URL (explicit override)
  if (runtimeEnv.WS_BASE_URL) {
    return runtimeEnv.WS_BASE_URL;
  }
  // 2. Build-time VITE_WS_BASE_URL
  if (import.meta.env.VITE_WS_BASE_URL) {
    return import.meta.env.VITE_WS_BASE_URL;
  }
  // 3. Auto-derive from API base (http → ws, https → wss)
  const apiBase = config.api.baseURL || window.location.origin;
  return apiBase.replace(/^http/, 'ws');
}
```

**Also update `WebSocketLogViewer.tsx`** (line 74) — it has the same derivation pattern:

```typescript
// Before:
const apiBase = OpenAPI.BASE || window.location.origin
const wsBase = apiBase.replace(/^http/, 'ws')

// After:
import config from '../config/config'
const apiBase = config.api.baseURL || window.location.origin
const wsBase = apiBase.replace(/^http/, 'ws')
```

For eval port-forward: WS_BASE_URL can be left empty — the auto-derivation from `API_BASE_URL` works (`http://localhost:8000` → `ws://localhost:8000`). For production with HTTPS ingress, `wss://` is derived automatically from `https://`.

#### 5. Centralise all direct `import.meta.env` references — Route through config.ts

These files bypass `config.ts` and read `import.meta.env` directly. Replace with `import config from '../config/config'`:

| File | Line | Current | Replace with |
|------|------|---------|-------------|
| `src/context/AuthContext.tsx` | 52 | `import.meta.env.VITE_API_BASE_URL` | `config.api.baseURL` |
| `src/hooks/useAgentRegistration.ts` | 13 | `import.meta.env.VITE_API_BASE_URL` | `config.api.baseURL` |
| `src/hooks/useDeployment.ts` | 20 | `import.meta.env.VITE_API_BASE_URL` | `config.api.baseURL` |
| `src/hooks/useRuntimes.ts` | 18 | `import.meta.env.VITE_API_BASE_URL` | `config.api.baseURL` |
| `src/hooks/useWorkspaceCreation.ts` | 12 | `import.meta.env.VITE_API_BASE_URL` | `config.api.baseURL` |
| `src/services/deploymentService.ts` | 19 | `import.meta.env.VITE_API_BASE_URL` | `config.api.baseURL` |
| `src/services/zitadelService.ts` | 10-11, 51 | `import.meta.env.VITE_ZITADEL_*` | `config.zitadel.issuer`, `.clientId` |

After this, `import.meta.env.VITE_*` only appears in `config.ts` as fallbacks — nowhere else.

**Regarding `src/config/config.js`:** Do NOT delete it yet. First:
1. Search for all imports of `config.js` (vs `config.ts`) across the codebase
2. Note that `api.js`, `agentService.js`, and `authService.js` import `from '../config/config'` — TypeScript/Vite resolution may pick up `.js` over `.ts` depending on config
3. Replace any explicit `.js` imports with extensionless `config` (TypeScript resolution picks up `.ts`)
4. Only delete `config.js` after confirming no imports reference it and build succeeds
5. Verify with `npm run build` — if it succeeds, `config.js` is safe to delete

#### 6. `frontend/nginx.conf` — Exclude env-config.js from aggressive caching

The current nginx.conf caches ALL `.js` files for 1 year (line 74). `env-config.js` must not be cached.

Add before the static assets location block (before line 74):

```nginx
# Runtime config — must not be cached (changes per environment)
location = /env-config.js {
    add_header Cache-Control "no-cache, no-store, must-revalidate";
    add_header Pragma "no-cache";
    add_header Expires "0";
    etag off;
}
```

- Nginx evaluates `location =` (exact match) before `location ~*` (regex), so this takes precedence over the 1-year cache rule.
- `etag off` prevents intermediary proxies from caching based on ETag.

### Dist Repo Changes

#### 1. `helm/biznez-runtime/templates/frontend/configmap.yaml` — JSON-escape values

Use Helm's `toJson` to properly escape values (prevents injection via Helm values containing quotes or special characters):

```yaml
data:
  env-config.js: |
    window.__ENV__ = {
      API_BASE_URL: {{ .Values.frontend.config.apiUrl | default (include "biznez.publicUrl.api" .) | toJson }},
      WS_BASE_URL: {{ .Values.frontend.config.wsUrl | default "" | toJson }}
    };
```

Note: `toJson` wraps the value in double quotes and escapes internal quotes, producing valid JavaScript string literals. This prevents breakage if a value contains `"` or other special characters.

#### 2. `helm/biznez-runtime/values.yaml` — Add wsUrl to frontend config

```yaml
frontend:
  config:
    apiUrl: ""   # Derived from ingress if empty
    wsUrl: ""    # Auto-derived from apiUrl if empty; set for custom WS endpoint
```

#### 3. `infra/values/eval-gke.yaml` — Set eval-specific API URL

```yaml
frontend:
  config:
    apiUrl: "http://localhost:8000"
```

This matches the provision.sh port-forward output: `kubectl port-forward svc/...-backend 8000:8000`. The browser calls `http://localhost:8000/api/v1/...` which hits the port-forward to the backend service.

#### 4. `infra/scripts/provision.sh` — Ensure port-forward output matches ConfigMap

The provision.sh output (line 292) already outputs `backend_portfwd=kubectl port-forward svc/$BACKEND_SVC 8000:8000`. This is consistent with `apiUrl: "http://localhost:8000"` in eval-gke.yaml.

No change needed — provision.sh and eval-gke.yaml are aligned at port 8000.

## How It Works Per Environment

```
Build once → Docker image includes public/env-config.js (localhost:8000 default)

Eval (Helm, port-forward):
  ConfigMap: API_BASE_URL = "http://localhost:8000"
  Port-forward: kubectl port-forward svc/backend 8000:8000
  Browser calls http://localhost:8000/api/v1/... → hits port-forward → backend ✓
  WebSocket: auto-derived ws://localhost:8000/api/v1/ws/... ✓

Dev (Helm, with ingress):
  ConfigMap: API_BASE_URL = "https://dev-api.example.com"
  Same image, different ConfigMap → Browser calls dev URL ✓
  WebSocket: auto-derived wss://dev-api.example.com ✓

Production (Helm):
  ConfigMap: API_BASE_URL = "https://api.biznez.com"
  Same image, different ConfigMap → Browser calls production URL ✓
  WebSocket: auto-derived wss://api.biznez.com ✓

Local dev (npm run dev):
  public/env-config.js has localhost:8000 default
  Vite serves it directly → works as today ✓
  No change to dev workflow
```

## Verification

### Pre-merge (runtime repo)
1. `npm run build` → verify `dist/env-config.js` exists with localhost defaults
2. `dist/index.html` has `<script>window.__ENV__ = window.__ENV__ || {};</script>` then `<script src="/env-config.js"></script>` before the app bundle
3. `grep -r "import.meta.env.VITE_API_BASE_URL" src/` → should only return `config.ts`
4. `grep -r "import.meta.env.VITE_" src/ | grep -v config.ts` → should return nothing
5. `npm run dev` → local dev still works (no regression)
6. Build new Docker image, push to registry

### Pre-merge (dist repo)
7. `helm template` → verify ConfigMap generates `API_BASE_URL` and `WS_BASE_URL` with `toJson` escaping
8. `helm template` with eval values → verify `apiUrl: "http://localhost:8000"`

### Post-deploy
9. Update `images.lock` with new frontend image tag
10. Deploy to eval → port-forward backend on 8000, frontend on 8080
11. Browser devtools Network tab: `/env-config.js` returns ConfigMap content with no-cache headers
12. Frontend connects to `http://localhost:8000/api/v1/...` (not old hardcoded URL)
13. Login works, API calls succeed
14. WebSocket connections work (check browser devtools WS tab)

## CI Guardrails (follow-up)

To prevent this from recurring:

### Runtime repo CI
1. **No hardcoded domains in bundle:** Fail the build if forbidden domains (e.g., `nip.io`, `35.246.*`) appear in the compiled JS bundle:
   ```bash
   npm run build
   if grep -rE '(nip\.io|35\.246\.)' dist/assets/*.js; then
     echo "ERROR: Hardcoded domains found in JS bundle"
     exit 1
   fi
   ```

2. **Centralised config enforcement:** Fail if `import.meta.env.VITE_` is referenced anywhere except `config.ts`:
   ```bash
   VIOLATIONS=$(grep -rn "import.meta.env.VITE_" src/ | grep -v "config/config.ts" || true)
   if [ -n "$VIOLATIONS" ]; then
     echo "ERROR: Direct import.meta.env access outside config.ts:"
     echo "$VIOLATIONS"
     exit 1
   fi
   ```

3. **env-config.js exists in build output:**
   ```bash
   test -f dist/env-config.js || { echo "ERROR: env-config.js missing from build"; exit 1; }
   ```

### Dist repo CI
4. **Post-deploy smoke test:** `curl /env-config.js` on deployed frontend and assert the value matches the intended environment

## Implementation Order

1. **Dist repo changes first** (can be staged independently):
   - Update `configmap.yaml` with `toJson` escaping and `WS_BASE_URL`
   - Add `wsUrl` to `values.yaml`
   - Set eval-specific `apiUrl` in `eval-gke.yaml`
   - These changes are backwards-compatible — the existing frontend ignores `window.__ENV__`

2. **Runtime repo changes** (requires image rebuild):
   - `index.html` — add inline fallback + env-config.js script tag
   - `public/env-config.js` — new file with localhost defaults
   - `config.ts` — read `window.__ENV__`, fallback to `import.meta.env`
   - `useWebSocket.ts` — read runtime config, derive from `config.api.baseURL`
   - `WebSocketLogViewer.tsx` — same WS derivation fix
   - Centralise all `import.meta.env` references through config.ts
   - Safely remove `config.js` (after verifying no imports reference it)
   - `nginx.conf` — no-cache for env-config.js

3. **Build and push new frontend Docker image**

4. **Update `images.lock` in dist repo** with new frontend image tag

5. **Deploy to eval** — verify frontend connects to backend via port-forward
