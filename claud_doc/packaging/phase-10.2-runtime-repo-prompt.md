# Frontend Runtime Config Fix — Runtime Repo Implementation Prompt

## Problem

The frontend Docker image bakes the API URL into the compiled JavaScript at build time via Vite's `import.meta.env.VITE_API_BASE_URL`. Once built, the URL **cannot be changed**. The current deployed image has `https://dev-api.35.246.109.199.nip.io` hardcoded 6+ times in the JS bundle.

**Result:** Deploying the same image to a different environment (eval, production) fails — the browser still calls the old dev URL. Every new environment currently needs a separate image build.

## What the Dist Repo (Helm Chart) Already Does

The Helm chart in `biznez-runtime-dist` already:
1. **Creates a ConfigMap** (`templates/frontend/configmap.yaml`) that generates `env-config.js` containing `window.__ENV__ = { API_BASE_URL: "...", WS_BASE_URL: "..." };`
2. **Mounts it** (`templates/frontend/deployment.yaml` lines 54-57) to `/usr/share/nginx/html/env-config.js` via subPath
3. **Triggers pod restart** on ConfigMap change via `checksum/config` annotation (line 18)

**But the frontend app completely ignores it** because:
- `index.html` has no `<script>` tag loading `env-config.js`
- All code reads `import.meta.env.VITE_API_BASE_URL` (baked at build time) instead of `window.__ENV__.API_BASE_URL`

This task fixes the frontend to read `window.__ENV__` at runtime, with build-time values as fallback.

## URL Convention — CRITICAL

`API_BASE_URL` must be just the host+port (e.g., `http://localhost:8000`), **NOT** `http://localhost:8000/api/v1`.

Evidence:
- `config.ts` line 72: fallback is `http://localhost:8000` (no `/api/v1`)
- All generated OpenAPI services include `/api/v1` in their URL paths (e.g., `url: '/api/v1/health'`)
- All manual services prepend `/api/v1` themselves (e.g., `` `${OpenAPI.BASE}/api/v1/observability/...` ``)
- All manual hooks prepend `/api/v1` themselves (e.g., `` `${API_BASE_URL}/api/v1/deployments` ``)
- `opencodeService.ts` line 86 has explicit comment: `"baseURL (from config.api.baseURL) does NOT include /api/v1"`
- Including `/api/v1` would produce double paths like `/api/v1/api/v1/health`

Note: `config.js` (the JS duplicate) has `http://localhost:8000/api/v1` — this is WRONG and inconsistent with `config.ts`. It will be deleted as part of this work.

Note: The Dockerfile has `ARG VITE_API_BASE_URL=http://localhost:8000/api/v1` — do NOT change this. It works in dev CI where the build arg is overridden. Changing the default risks breaking dev.

---

## Files to Change (6 files modified, 1 new file)

All paths are relative to `frontend/` in the `biznez-agentic-runtime` repo.

---

### 1. `index.html` — Add env-config.js loading with inline fallback

**Current file (lines 1-13):**
```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <link rel="icon" type="image/svg+xml" href="/vite.svg" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>frontend</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
```

**Change:** Add two `<script>` tags in `<head>`, before `</head>`:

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

**Why the inline script first:**
- Sets `window.__ENV__` to an empty object as a safety net
- If `env-config.js` loads successfully, it overwrites `window.__ENV__` with real values
- If `env-config.js` fails (404, network error), `window.__ENV__` remains `{}` and `config.ts` falls back to build-time values
- The app never crashes due to `window.__ENV__` being undefined

Both scripts are regular (not `type="module"`), so they execute synchronously before the app bundle.

---

### 2. `public/env-config.js` — NEW FILE: default config for local dev

**Create this new file at `frontend/public/env-config.js`:**

```javascript
// Runtime configuration — overridden per-environment.
// Kubernetes: Helm ConfigMap mounted over this file.
// Local dev: this default is used as-is.
window.__ENV__ = {
  API_BASE_URL: "http://localhost:8000",
  WS_BASE_URL: ""
};
```

**Why:**
- Vite serves `public/` files as-is (no bundling). This file appears in `dist/` after build.
- In Docker image: ships as the default at `/usr/share/nginx/html/env-config.js`
- In Kubernetes: Helm ConfigMap is mounted OVER this file via subPath (already wired in deployment.yaml)
- In local dev (`npm run dev`): Vite serves it directly, so local dev works unchanged
- `WS_BASE_URL` defaults to empty string — the WebSocket code auto-derives from `API_BASE_URL`

---

### 3. `src/config/config.ts` — Read runtime config, fallback to build-time

**Current lines 65-72:**
```typescript
// Debug logging
console.log('ENV VITE_API_BASE_URL:', import.meta.env.VITE_API_BASE_URL)
console.log('Final baseURL will be:', import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000')

const config: Config = {
  // API Configuration
  api: {
    baseURL: import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000',
```

**Current lines 110-122:**
```typescript
  // Phase 5.4: ZITADEL Authentication
  zitadel: {
    issuer: import.meta.env.VITE_ZITADEL_ISSUER || 'https://biznez-dev-swfsuq.us1.zitadel.cloud',
    clientId: import.meta.env.VITE_ZITADEL_CLIENT_ID || '353931821110585508',
    redirectUri: `${window.location.origin}/auth/callback`,
    scopes: ['openid', 'profile', 'email', 'offline_access'],
  },

  // Phase 5.4: Agent Gateway (MCP)
  agentGateway: {
    baseUrl: import.meta.env.VITE_AGENT_GATEWAY_URL || 'http://35.246.33.196',
    timeout: 30000, // 30 seconds
  },
```

**Changes:**

1. **Delete lines 65-67** (the two `console.log` debug lines)

2. **Add runtime config reading** before the `const config` declaration:
```typescript
// Runtime config (from env-config.js loaded in index.html)
const runtimeEnv = (window as any).__ENV__ || {};

// Warn if runtime config is missing in production (not local dev)
if (!runtimeEnv.API_BASE_URL && import.meta.env.PROD) {
  console.warn('[config] window.__ENV__ not loaded — falling back to build-time config. Check env-config.js is served.');
}
```

3. **Update api.baseURL** (line 72):
```typescript
    baseURL: runtimeEnv.API_BASE_URL || import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000',
```

4. **Update zitadel config** (lines 112-113) with comment:
```typescript
  // Zitadel config stays build-time for now — same values across all environments.
  // If Zitadel config needs to vary per environment later, add ZITADEL_ISSUER and
  // ZITADEL_CLIENT_ID to window.__ENV__ (env-config.js) and the Helm ConfigMap.
  zitadel: {
    issuer: runtimeEnv.ZITADEL_ISSUER || import.meta.env.VITE_ZITADEL_ISSUER || 'https://biznez-dev-swfsuq.us1.zitadel.cloud',
    clientId: runtimeEnv.ZITADEL_CLIENT_ID || import.meta.env.VITE_ZITADEL_CLIENT_ID || '353931821110585508',
    redirectUri: `${window.location.origin}/auth/callback`,
    scopes: ['openid', 'profile', 'email', 'offline_access'],
  },
```

5. **Update agentGateway** (line 120):
```typescript
    baseUrl: runtimeEnv.AGENT_GATEWAY_URL || import.meta.env.VITE_AGENT_GATEWAY_URL || 'http://35.246.33.196',
```

**Fallback chain:** `window.__ENV__` (runtime) → `import.meta.env` (build-time) → hardcoded default.

---

### 4. `src/hooks/useWebSocket.ts` — Use config.api.baseURL instead of OpenAPI.BASE

**Current `getWsBaseUrl()` (lines 18-28):**
```typescript
const getWsBaseUrl = (): string => {
  // Use VITE_WS_BASE_URL if explicitly set, otherwise derive from API base
  if (import.meta.env.VITE_WS_BASE_URL) {
    return import.meta.env.VITE_WS_BASE_URL
  }
  // Derive from OpenAPI.BASE (e.g., http://localhost:8000 -> ws://localhost:8000)
  // Don't append /api/v1 since WS endpoints may be at /ws/... or /api/v1/ws/...
  const apiBase = OpenAPI.BASE || window.location.origin
  const wsBase = apiBase.replace(/^http/, 'ws')
  return wsBase
}
```

**Replace with:**
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

**Why `config.api.baseURL` instead of `OpenAPI.BASE`:** `OpenAPI.BASE` is set in `apiClient.ts` via `configureApiClient()`. If this function runs before `configureApiClient()` is called, `OpenAPI.BASE` would be the default (empty or wrong). Using `config.api.baseURL` directly ensures the runtime config value is always used.

---

### 5. `src/components/WebSocketLogViewer.tsx` — Same WS derivation fix

**Current (around lines 72-77):**
```typescript
    // Connect to WebSocket - dynamically derive from OpenAPI.BASE
    // OpenAPI.BASE is set from VITE_API_BASE_URL (e.g., http://localhost:8000 or https://dev-api.example.com)
    const apiBase = OpenAPI.BASE || window.location.origin
    // Convert http:// to ws:// and https:// to wss://
    const wsBase = apiBase.replace(/^http/, 'ws')
    const wsUrl = `${wsBase}/api/v1/ws/logs/${executionId}?token=${accessToken}`
```

**Replace with:**
```typescript
    import config from '../config/config'
    // ...
    // Connect to WebSocket - derive from runtime config
    const apiBase = config.api.baseURL || window.location.origin
    // Convert http:// to ws:// and https:// to wss://
    const wsBase = apiBase.replace(/^http/, 'ws')
    const wsUrl = `${wsBase}/api/v1/ws/logs/${executionId}?token=${accessToken}`
```

(Move the `import config` to the top of the file with the other imports.)

---

### 6. Centralise all direct `import.meta.env` references — Route through config.ts

These files read `import.meta.env.VITE_*` directly, bypassing `config.ts`. Replace each with an import from config.

**6a. `src/context/AuthContext.tsx` line 52:**
```typescript
// Before:
const apiBaseUrl = import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000'

// After:
import config from '../config/config'  // (add to top-level imports)
const apiBaseUrl = config.api.baseURL
```

**6b. `src/hooks/useAgentRegistration.ts` line 13:**
```typescript
// Before:
const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000'

// After:
import config from '../config/config'  // (add to top-level imports)
const API_BASE_URL = config.api.baseURL
```

**6c. `src/hooks/useDeployment.ts` line 20:**
```typescript
// Before:
const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000'

// After:
import config from '../config/config'
const API_BASE_URL = config.api.baseURL
```

**6d. `src/hooks/useRuntimes.ts` line 18:**
```typescript
// Before:
const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000'

// After:
import config from '../config/config'
const API_BASE_URL = config.api.baseURL
```

**6e. `src/hooks/useWorkspaceCreation.ts` line 12:**
```typescript
// Before:
const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000'

// After:
import config from '../config/config'
const API_BASE_URL = config.api.baseURL
```

**6f. `src/services/deploymentService.ts` line 19:**
```typescript
// Before:
const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000'

// After:
import config from '../config/config'
const API_BASE_URL = config.api.baseURL
```

**6g. `src/services/zitadelService.ts` lines 10-11 and 51:**
```typescript
// Before (lines 10-11):
  import.meta.env.VITE_ZITADEL_ISSUER || 'https://biznez-dev-swfsuq.us1.zitadel.cloud'
const ZITADEL_CLIENT_ID = import.meta.env.VITE_ZITADEL_CLIENT_ID || '353931821110585508'

// After:
import config from '../config/config'
const ZITADEL_ISSUER = config.zitadel.issuer
const ZITADEL_CLIENT_ID = config.zitadel.clientId

// Before (line 51):
const GOOGLE_IDP_ID = import.meta.env.VITE_ZITADEL_GOOGLE_IDP_ID || ''

// After (keep as-is — GOOGLE_IDP_ID is not in config.ts yet, add it or leave with import.meta.env):
// If adding to config.ts, add: googleIdpId: runtimeEnv.ZITADEL_GOOGLE_IDP_ID || import.meta.env.VITE_ZITADEL_GOOGLE_IDP_ID || ''
// Otherwise leave this one line as-is for now.
```

---

### 7. Delete `src/config/config.js` — SAFELY

**Current `config.js` (the JS duplicate):**
- Has `baseURL: 'http://localhost:8000/api/v1'` — INCONSISTENT with `config.ts`
- Missing `zitadel` and `agentGateway` sections
- Three `.js` files import from `'../config/config'`: `api.js`, `agentService.js`, `authService.js`

**Steps:**
1. Check if `api.js`, `agentService.js`, `authService.js` are still used or have `.ts` replacements
2. If they have `.ts` replacements that are actually imported by the app, the `.js` versions may be dead code
3. If they're still used: Vite resolves `from '../config/config'` — it may pick up `.js` or `.ts` depending on Vite config. Verify by checking if removing `config.js` still builds
4. **Test:** `rm src/config/config.js && npm run build` — if it succeeds, the deletion is safe
5. If it fails, the `.js` importers need to be converted to `.ts` or the import paths updated

---

### 8. `nginx.conf` — Exclude env-config.js from aggressive caching

**Current (lines 73-78):**
```nginx
        # Static assets with aggressive caching
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
            access_log off;
        }
```

**Add BEFORE this block (before line 73):**
```nginx
        # Runtime config — must not be cached (changes per environment)
        location = /env-config.js {
            add_header Cache-Control "no-cache, no-store, must-revalidate";
            add_header Pragma "no-cache";
            add_header Expires "0";
            etag off;
        }

```

Nginx evaluates `location =` (exact match) before `location ~*` (regex), so `/env-config.js` gets no-cache headers while all other `.js` files keep the 1-year cache.

---

## Verification Checklist

After making all changes:

```bash
# 1. Build succeeds
npm run build

# 2. env-config.js exists in build output
test -f dist/env-config.js && echo "OK" || echo "MISSING"

# 3. index.html has the script tags
grep 'env-config.js' dist/index.html

# 4. import.meta.env.VITE_API_BASE_URL only in config.ts
grep -rn "import.meta.env.VITE_API_BASE_URL" src/
# Should ONLY return src/config/config.ts

# 5. No other import.meta.env.VITE_ references outside config.ts (except VITE_WS_BASE_URL in useWebSocket.ts and VITE_MCP_GATEWAY_ENABLED in ChatPage.tsx which are fine)
grep -rn "import.meta.env.VITE_" src/ | grep -v "config/config.ts"

# 6. Local dev still works
npm run dev
# Open browser, verify API calls go to localhost:8000

# 7. No config.js left (if deletion was safe)
test -f src/config/config.js && echo "STILL EXISTS" || echo "DELETED OK"
```

---

## What Happens After These Changes

1. **Build a new frontend Docker image** and push to Artifact Registry
2. **Update `images.lock`** in `biznez-runtime-dist` with the new image tag
3. **Deploy to eval** — the Helm ConfigMap injects `API_BASE_URL: "http://localhost:8000"` into `env-config.js`
4. **Port-forward:** `kubectl port-forward svc/...-backend 8000:8000` and `svc/...-frontend 8080:80`
5. **Browser** loads `env-config.js` (ConfigMap content), reads `window.__ENV__.API_BASE_URL`, calls `http://localhost:8000/api/v1/...` via port-forward
6. Same image can be deployed to dev (with `https://dev-api.example.com`) or production (with `https://api.biznez.com`) — just change the Helm values

---

## Reference: Files that already import config correctly

These files already use `import config from '../config/config'` and DON'T need changes:
- `src/services/apiClient.ts` — sets `OpenAPI.BASE = config.api.baseURL` (line 41)
- `src/services/api.js` — uses `config.api.baseURL` (may be dead code, has `.ts` equivalent)
- `src/services/authService.js` — uses config (may be dead code, has `.ts` equivalent at `authService.ts`)
- `src/services/agentService.js` — uses config (may be dead code)
- `src/services/mcpGatewayService.ts` — uses `config.agentGateway.baseUrl`
- `src/services/dockerHubCatalogService.ts` — uses config

---

## Reference: Dist Repo Helm Chart (Already Done — PR #30)

The dist repo changes are already committed on branch `Feature/4-Mar-Fix-FE-Runtime-config` (PR #30):

- **`templates/frontend/configmap.yaml`**: Uses `toJson` for safe value escaping, includes `WS_BASE_URL`
- **`templates/frontend/deployment.yaml`**: Already mounts `env-config.js` via subPath at `/usr/share/nginx/html/env-config.js` (lines 54-57)
- **`values.yaml`**: Added `frontend.config.wsUrl` parameter
- **`infra/values/eval-gke.yaml`**: Set `apiUrl: "http://localhost:8000"` matching provision.sh port-forward

No further dist repo changes needed after the runtime repo work.
