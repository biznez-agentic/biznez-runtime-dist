# Plan: Phase 6 -- Docker Compose

## Context

Phases 0-5 are complete. The Helm chart fully supports eval and production Kubernetes deployments with all services, networking, migrations, and production hardening. Phase 6 adds a Docker Compose setup for evaluation/demo deployments **without Kubernetes** -- laptop/VM deployments for demos and PoCs.

The runtime repo (`biznez-agentic-framework`) has a dev-oriented `docker-compose.yml` with hot-reload, Vite dev server, and source mounts. The dist repo (`biznez-runtime-dist`) has placeholder files in `compose/`. This phase replaces those placeholders with production-ready Docker Compose files that use **pre-built images** (not dev hot-reload).

**Repo:** `/Users/manimaun/Documents/code/biznez-runtime-dist`
**Branch:** New branch from current HEAD

---

## Changes from Previous Plan (All Review Feedback Applied)

### Round 1 Feedback (9 items)

| # | Previous Plan | Updated Plan | Why It Matters |
|---|--------------|--------------|----------------|
| 1 | Migration on startup via plain `alembic upgrade head` in backend command | **No migrations by default in Phase 6.** Migrations deferred to Phase 6.1. | Avoids double-migration logic drift vs K8s. Prevents concurrency issues if backend replicas > 1. Preserves original 6 vs 6.1 phase boundary. |
| 2 | nginx.conf mounted to `/etc/nginx/nginx.conf` (server block only) | Mount to **`/etc/nginx/conf.d/default.conf`** (server block only). Base nginx.conf left intact from image. | Mounting a server-block-only file to `/etc/nginx/nginx.conf` breaks nginx -- it needs `events {}`, `http {}`, `include mime.types`, etc. |
| 3 | Fernet key via `python3 -c "from cryptography.fernet import Fernet; ..."` as primary, openssl as fallback | **`openssl` as primary**, stdlib python as fallback. No third-party python deps on host. | Most laptops don't have `cryptography` pip package installed. |
| 4 | Gateway commented out with YAML comments | **Compose profiles**: `profiles: ["gateway"]`. Enable via `docker compose --profile gateway up -d`. | Profiles are cleaner than commenting/uncommenting YAML blocks. Less error-prone. |
| 5 | `VITE_API_BASE_URL` listed in `.env.template` without clarity | Explicit note: **build-time only**. Changing `.env` does NOT affect already-built frontend image. | Prevents confusion where users change VITE_* vars and expect runtime effect. |
| 6 | Verification: 10 static grep checks only | **Added runtime checks**: `docker compose up`, curl health through nginx proxy, nginx -t, SSE smoke test. | Static greps catch file wiring; runtime checks catch actual breakage. |
| 7 | `COMPOSE_PULL_POLICY` in `.env.template` only | Explicit `pull_policy: ${COMPOSE_PULL_POLICY:-if_not_present}` in compose file per service. | The env var alone isn't automatically respected -- must be wired into each service's `pull_policy` field. |
| 8 | nginx SSE: `proxy_buffering off` only | Add `proxy_set_header X-Accel-Buffering no` alongside `proxy_buffering off`. Add `map $http_upgrade $connection_upgrade` for WebSocket. | Improves SSE compatibility. Map-based WebSocket upgrade is more robust. |
| 9 | `depends_on: condition: service_healthy` as sole readiness mechanism | Keep `depends_on` for ordering. **`setup.sh` polls health endpoints** as the actual readiness signal. | `depends_on` with conditions can behave inconsistently. Polling is the reliable layer. |

### Round 2 Feedback (7 items)

| # | Issue | Fix Applied | Why It Matters |
|---|-------|-------------|----------------|
| 1 | Phase 6.1 migration runner path `src.agentic_runtime.migrations.runner` -- module doesn't exist, wrong prefix | **Standardised to Helm canonical command: `alembic upgrade head`** (what Helm default uses). The advisory-lock wrapper `agentic_runtime.db.migration_runner` (no `src.` prefix) is referenced in Helm comments but doesn't exist yet. All compose references now match Helm exactly. | Prevents inventing a compose-only module path. |
| 2 | Two Phase 6.1 approaches described without picking a default | **One-shot `migrate` service is the default** Phase 6.1 approach. `RUN_MIGRATIONS` env var on backend entrypoint is documented as optional shortcut for power users with "not recommended for scaled backends" warning. | One-shot service is safer: no repeated migrations on restart, no scaling footgun, more compose-native. |
| 3 | ENCRYPTION_KEY via `openssl rand -base64 32` may not match Fernet format the app expects | **Primary: generate via backend container** (`docker run --rm ${BACKEND_IMAGE} python -c "from cryptography.fernet import Fernet; ..."`). Fallback: `openssl rand -base64 32` only if container unavailable. | Guarantees the key matches what the app expects. No host python dependency. Docker is already a prerequisite. |
| 4 | nginx `map` directive placement correct in theory but unvalidated against frontend image | **Added `nginx -t` runtime verification step** in both verification checklist and `setup.sh` post-start checks. | Catches include-context issues immediately if frontend image has a custom nginx.conf. |
| 5 | `pull_policy` requires docker compose v2.17+; `COMPOSE_PULL_POLICY=never` with missing images silently fails | **Documented minimum version.** `setup.sh` prints warning if `COMPOSE_PULL_POLICY=never` and images are missing locally (`docker image inspect` check). | Prevents silent failures in air-gapped setups. |
| 6 | Verification heading says "14 checks" but lists 18 | **Fixed numbering.** | Removes review confusion. |
| 7 | Backend healthcheck uses `curl`; may not be in slim images | **Confirmed: backend image (`python:3.11-slim-bookworm`) explicitly installs `curl`** in the Dockerfile. Frontend image (`nginx:1.25-alpine`) has `wget`. Healthchecks match what's installed. Documented the dependency. | No change needed -- dependency is now explicit. |

### Round 3 Feedback (7 items)

| # | Issue | Fix Applied | Why It Matters |
|---|-------|-------------|----------------|
| 1 | Backend command uses `uvicorn src.agentic_runtime.api.main:app` -- potentially wrong import path | **Verified: `src.agentic_runtime.api.main:app` is correct.** Both production Dockerfile CMD and dev docker-compose.yml use this exact path. `PYTHONPATH=/app`, code at `/app/src/agentic_runtime/`, package not installed (runs from source). The `src.` prefix is required for uvicorn (unlike `alembic` which is a CLI tool running from workdir). Added explanatory note to avoid future confusion. | No change to the command, but the inconsistency between uvicorn (`src.` needed) and alembic (no `src.` needed) is now documented to prevent confusion. |
| 2 | Phase 6.1 wording implies advisory-lock runner exists today | **Tightened wording.** Phase 6.1 default (now): one-shot `migrate` service runs `alembic upgrade head`. Future enhancement (separate phase): replace with `agentic_runtime.db.migration_runner` once that module is implemented. No pretense that the lock runner exists today. | Prevents implementers from trying to use a module that doesn't exist yet. |
| 3 | ENCRYPTION_KEY generation via `docker run ... print(...)` outputs to stdout -- could leak in debug/error paths | **Secret capture hardened.** `setup.sh` captures output into a variable, never echoes it. Added note: "Do not run setup.sh with `bash -x` if you care about secret exposure (xtrace prints all variable assignments)." Explicit `set +x` guard around secret generation block even if xtrace was enabled earlier. | Prevents accidental secret exposure in debug mode, CI logs, or error paths. |
| 4 | `pull_policy` version check is documented but not enforced | **Added concrete version check in `setup.sh`.** Parses `docker compose version` output and warns if `COMPOSE_PULL_POLICY` is set but compose version < 2.17. | Without this, users may think `pull_policy` is enforced when compose silently ignores it. |
| 5 | Runtime checks only verify `/health` -- SPA root `/` could still be miswired | **Added SPA content check** (verification step 19): `curl -sf http://localhost:${FRONTEND_PORT:-8080}/ | head -c 100` to verify index.html is actually served. `/health` returning 200 doesn't prove the SPA root is correctly configured. | Catches misconfigured `root` directive or empty `/usr/share/nginx/html`. |
| 6 | Gateway config schema unvalidated at runtime | **Added gateway runtime check** (verification step 21): when `--profile gateway` is enabled, verify container stays running for 10s and check logs for startup errors. If agentgateway exposes `/healthz`, check that too. | Catches schema mismatches between our config and the pinned agentgateway version. |
| 7 | Verification step 13 (`grep "alembic upgrade head"`) could match Phase 6.1 comments if included in compose file | **Clarified: Phase 6.1 migration examples live ONLY in this plan doc, NOT in `docker-compose.yml`.** The compose file contains no commented migration examples. Step 13 grep is clean. | Prevents false positives in verification. |

---

## Key Design Decisions

1. **Pre-built images, not dev mode**: Uses the same multi-stage Dockerfile images as K8s. No source mounts, no hot-reload, no Vite dev server.
2. **Frontend via nginx (port 8080), not Vite (5173)**: The Docker Compose frontend uses the production nginx image, mapped 8080 -> 80 inside the container.
3. **No migrations in Phase 6** (deferred to Phase 6.1): Backend starts uvicorn only. Database must be pre-migrated or migration enabled via Phase 6.1.
4. **Gateway via compose profiles**: Gateway service uses `profiles: ["gateway"]`. Enable with `docker compose --profile gateway up -d`. No commented-out YAML blocks.
5. **Auth mode: local**: No external IdP needed for evaluation. OIDC documented but not default.
6. **Secrets written to .env only**: `setup.sh` never prints secrets to terminal. Secret generation block guarded with `set +x` to prevent xtrace leakage.
7. **Bash 3.2+ compatible**: macOS ships bash 3.2, so no bash 4+ features (no associative arrays, no `${var,,}`).
8. **nginx config mounted to `conf.d/default.conf`**: Server block only; base nginx.conf from image remains intact.
9. **ENCRYPTION_KEY generated via backend container**: Guarantees Fernet format match. No host python third-party dependency. Output captured into variable, never echoed.
10. **Healthchecks match installed tools**: Backend uses `curl` (installed in Dockerfile). Frontend uses `wget` (available in Alpine). Dependency documented.

---

## Files to Create

| # | File | Action | Purpose |
|---|------|--------|---------|
| 1 | `compose/docker-compose.yml` | Overwrite placeholder | Full service stack (~170 lines) |
| 2 | `compose/.env.template` | Overwrite placeholder | Environment variable reference (~130 lines) |
| 3 | `compose/nginx.conf` | Overwrite placeholder | Production nginx server block with API proxy (~80 lines) |
| 4 | `compose/setup.sh` | Overwrite placeholder | Secret generation + startup (~240 lines) |
| 5 | `compose/gateway-config.yaml` | Create new | Minimal gateway config for eval |

---

## Implementation Order

1. Create `compose/gateway-config.yaml`
2. Create `compose/.env.template`
3. Create `compose/nginx.conf`
4. Create `compose/docker-compose.yml`
5. Create `compose/setup.sh`
6. Run verification checks

---

## Step 1: `compose/gateway-config.yaml`

Minimal gateway configuration matching the Helm chart's eval default. Bind on port 8080 with an empty routes list.

**Note:** Validate this schema against the runtime repo's gateway config (`config/agentgateway-local.yaml` / `k8s/mcp-gateway/configmap.yaml`) to ensure compose and helm stay consistent.

```yaml
# Agent Gateway configuration for Docker Compose evaluation.
# Add MCP server targets and routes as needed.
# See: https://github.com/agentgateway/agentgateway
binds:
  - port: 8080
    listeners:
      - name: default
        routes: []
```

---

## Step 2: `compose/.env.template`

All environment variables with comments. Organized by section. Placeholder values for secrets use `CHANGE_ME_*` prefix so `setup.sh` can detect and replace them.

**Sections:**
- Ports (BACKEND_PORT, FRONTEND_PORT, GATEWAY_PORT, POSTGRES_PORT)
- Database (POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD, DATABASE_URL)
- Security (ENCRYPTION_KEY, JWT_SECRET_KEY)
- Authentication (AUTH_MODE=local, OIDC settings commented)
- Application (ENVIRONMENT, LOG_LEVEL, WORKERS, CORS_ORIGINS)
- LLM (LLM_PROVIDER=none, API key placeholders)
- Monitoring (LANGFUSE settings)
- Docker Compose (COMPOSE_PULL_POLICY -- requires docker compose v2.17+)
- Frontend (VITE_API_BASE_URL -- **BUILD-TIME ONLY, see note below**)

**Key env vars from runtime `.env.example` to include:**
- `DATABASE_URL=postgresql://biznez_user:CHANGE_ME_DB_PASSWORD@postgres:5432/biznez_runtime`
- `ENCRYPTION_KEY=CHANGE_ME_ENCRYPTION_KEY`
- `JWT_SECRET_KEY=CHANGE_ME_JWT_SECRET`
- `POSTGRES_PASSWORD=CHANGE_ME_DB_PASSWORD`
- `AUTH_MODE=local` (not `AUTH_TYPE` -- use the Helm chart's naming)
- `CORS_ORIGINS=http://localhost:8080` (nginx port, not Vite 5173)

**VITE_API_BASE_URL note:**
> `VITE_*` variables are baked into the frontend at **build time**. Changing them in `.env` has NO effect on an already-built frontend image. The compose nginx proxy makes this work by routing `/api/` requests to the backend, so the frontend must use relative `/api` paths (not absolute URLs). This variable is documented for reference only -- it does not need to be set for compose deployments using the default images.

**Note on env var naming:** The `.env.template` uses the env var names that the backend application actually expects (from `config.py`). These may differ from the Helm `values.yaml` field names. Document the mapping where it's not obvious.

---

## Step 3: `compose/nginx.conf`

This is a **server block only** file, mounted to `/etc/nginx/conf.d/default.conf` (not `/etc/nginx/nginx.conf`). The base nginx.conf from the `nginx:1.25-alpine` image remains intact and provides the `events {}`, `http {}`, `include mime.types`, etc.

Adapted from `[runtime] frontend/nginx.conf` with these changes:

1. **API proxy enabled** (uncommented) -- routes `/api/` to `http://backend:8000`
2. **WebSocket proxy enabled** (uncommented) -- routes `/ws` to `http://backend:8000` with proper `map`-based `$connection_upgrade`
3. **SSE support** -- `proxy_buffering off` AND `proxy_set_header X-Accel-Buffering no` for `/api/`
4. **Health check** endpoint at `/health` returning 200
5. **SPA fallback** via `try_files $uri $uri/ /index.html`

**Note:** The `map` directive at the top of the file is valid because `conf.d/*.conf` files are included at the `http {}` level by the default nginx.conf. **Validated by `nginx -t` runtime check** (see verification step 16).

```
# WebSocket upgrade map -- must be at http level (conf.d is included at http level)
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    # Health check endpoint
    location = /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # API proxy
    location /api/ {
        proxy_pass http://backend:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
        # SSE support
        proxy_buffering off;
        proxy_cache off;
        proxy_set_header X-Accel-Buffering no;
    }

    # WebSocket proxy
    location /ws {
        proxy_pass http://backend:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
    }

    # SPA routing
    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

---

## Step 4: `compose/docker-compose.yml`

**Services:**

| Service | Image | Port | Notes |
|---------|-------|------|-------|
| `postgres` | `postgres:15-alpine` | `${POSTGRES_PORT:-5432}:5432` | Named volume, pg_isready healthcheck |
| `backend` | `${BACKEND_IMAGE:-ghcr.io/biznez-agentic/runtime-backend:latest}` | `${BACKEND_PORT:-8000}:8000` | **No migrations.** Starts uvicorn only. depends_on postgres (healthy) |
| `frontend` | `${FRONTEND_IMAGE:-ghcr.io/biznez-agentic/runtime-frontend:latest}` | `${FRONTEND_PORT:-8080}:80` | nginx.conf mounted to `conf.d/default.conf`, depends_on backend (started) |
| `gateway` | `${GATEWAY_IMAGE:-ghcr.io/agentgateway/agentgateway:0.1.0}` | `${GATEWAY_PORT:-8090}:8080` | **Profile `gateway`**. Config mount, depends_on backend |

**Key patterns:**
- All ports configurable via `.env` variables
- Image references configurable via `*_IMAGE` env vars (supports air-gapped with local images)
- Explicit `pull_policy: ${COMPOSE_PULL_POLICY:-if_not_present}` per service (requires docker compose v2.17+)
- Single bridge network `biznez-network`
- Named volumes: `postgres-data` (persistent), no backend-logs volume (stdout logging)
- Backend command (**no migrations**):
  ```
  sh -c "uvicorn src.agentic_runtime.api.main:app --host 0.0.0.0 --port 8000 --workers ${WORKERS:-2} --log-level ${LOG_LEVEL:-info}"
  ```
  > **Import path note:** `src.agentic_runtime.api.main:app` is correct (verified in both production Dockerfile and dev docker-compose.yml). `PYTHONPATH=/app` and code lives at `/app/src/agentic_runtime/`, so uvicorn needs the `src.` prefix when running from source. This differs from `alembic` (a CLI tool that runs from workdir `/app` and reads `alembic.ini` -- no Python import path needed). Do not "fix" by removing `src.` -- it will break.
- Frontend mounts `./nginx.conf:/etc/nginx/conf.d/default.conf:ro`
- No source mounts (pre-built images only)
- `restart: unless-stopped` for all services
- Gateway service uses `profiles: ["gateway"]` -- enabled via `docker compose --profile gateway up -d`
- **No Phase 6.1 migration examples in docker-compose.yml.** Migration service definitions live only in this plan doc, not as commented blocks in the compose file.

**Backend environment variables** (from `.env` file):
- `DATABASE_URL`, `ENCRYPTION_KEY`, `JWT_SECRET_KEY`
- `AUTH_MODE`, `ENVIRONMENT`, `LOG_LEVEL`, `WORKERS`
- `CORS_ORIGINS`, LLM keys, Langfuse config

**Healthchecks** (match tools installed in each image's Dockerfile):
- postgres: `pg_isready -U ${POSTGRES_USER:-biznez_user}`
- backend: `curl -f http://localhost:8000/api/v1/health` (curl is installed in backend Dockerfile)
- frontend: `wget --no-verbose --tries=1 --spider http://localhost:80/health` (wget is available in nginx:alpine)

> **Dependency note:** If the backend Dockerfile ever removes the `curl` package, the healthcheck must change to: `python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/api/v1/health').read()"`. Similarly, if the frontend image changes from Alpine, verify `wget` availability.

**depends_on note:**
> `depends_on` with `condition: service_healthy` is used for service ordering but is NOT relied upon as the sole readiness signal. `setup.sh` independently polls health endpoints as the reliable readiness layer.

---

## Step 5: `compose/setup.sh`

Bash script (3.2+ compatible) that:

1. **Checks prerequisites**: docker, docker compose (v2 plugin syntax)
2. **Checks compose version**: Parses `docker compose version` output. If `COMPOSE_PULL_POLICY` is set in `.env` and compose version < 2.17, prints warning: "`pull_policy` requires docker compose v2.17+; your version may silently ignore it."
3. **Copies `.env.template` to `.env`** (if `.env` doesn't exist)
4. **Generates secrets** and replaces `CHANGE_ME_*` placeholders in `.env`:
   - **Secret generation block is guarded with `set +x`** to prevent xtrace from printing secrets. Restores previous trace state after generation.
   - All secrets captured into variables; never echoed to terminal.
   - **ENCRYPTION_KEY: generated via backend container** (primary). This guarantees Fernet format match:
     ```
     _enc_key=$(docker run --rm ${BACKEND_IMAGE:-ghcr.io/biznez-agentic/runtime-backend:latest} \
       python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null)
     ```
     Fallback (if container pull fails): `openssl rand -base64 32` with a warning that the app may reject non-Fernet keys.
   - **JWT_SECRET_KEY**: `openssl rand -base64 32` (primary). Fallback: `python3 -c "import secrets; print(secrets.token_urlsafe(32))"`.
   - **POSTGRES_PASSWORD**: `openssl rand -base64 24` (primary). Fallback: `python3 -c "import secrets; print(secrets.token_urlsafe(24))"`.
   - Updates `DATABASE_URL` with generated postgres password via sed substitution.
   - > **Security note:** Do not run `setup.sh` with `bash -x` (xtrace) if you care about secret exposure. Xtrace prints all variable assignments including secrets. The script guards the secret generation block with `set +x`, but this only works if the script controls xtrace itself.
5. **Air-gapped check**: If `COMPOSE_PULL_POLICY=never` is set in `.env`, runs `docker image inspect` for each required image and warns if any are missing locally.
6. **Never prints secrets to terminal** -- writes to `.env` only. Shows `[OK] Secrets generated and written to .env` message.
7. **Starts services**: `docker compose up -d` (unless `--generate-only`)
8. **Validates nginx config**: `docker compose exec frontend nginx -t` after frontend starts. Warns but does not fail if nginx -t reports issues (frontend may still serve SPA correctly with base nginx.conf).
9. **Waits for health** (polls both services):
   - Polls backend `http://localhost:${BACKEND_PORT:-8000}/api/v1/health` (timeout 60s)
   - Polls frontend `http://localhost:${FRONTEND_PORT:-8080}/health` (timeout 30s)
   - Reports status for each
10. **Prints access URLs**:
    ```
    Frontend: http://localhost:8080
    Backend API: http://localhost:8000/api/v1/health
    ```
11. **Prints admin setup hint** (for local auth mode):
    ```
    Check backend logs for first-run admin credentials:
      docker compose logs backend | grep -i "admin\|password\|created"
    ```

**Error handling:**
- Exits with clear error if docker/docker-compose not found
- Checks if `.env` already has real secrets (no `CHANGE_ME_` prefix) and skips regeneration
- `set -euo pipefail` for safety
- Warns if `COMPOSE_PULL_POLICY=never` and images missing locally
- Warns if compose version < 2.17 and `COMPOSE_PULL_POLICY` is set

**Flags:**
- `--generate-only`: Generate secrets but don't start services
- `--show-secrets`: Print generated secrets to terminal (opt-in)
- `--no-start`: Alias for `--generate-only`

---

## Phase 6.1: Migration Support (Deferred)

> This section documents the deferred migration-on-startup feature. Phase 6.1 migration examples live **only in this plan doc**, NOT as commented blocks in `docker-compose.yml`.

### Current State

The Helm chart's default migration command is:
```
alembic upgrade head
```
Run from workdir `/app` with `PYTHONPATH=/app`. This is a CLI command (not a Python module import), so no `src.` prefix is needed.

The Helm chart also references an advisory-lock wrapper module (commented in `values.yaml`):
```
python -m agentic_runtime.db.migration_runner
```
**This module does not exist yet in the codebase.** It is a placeholder for future hardening work.

### Import Path Clarification

There are two different path conventions at play:

| Context | Path | Why |
|---------|------|-----|
| **uvicorn** (Python import) | `src.agentic_runtime.api.main:app` | Uvicorn resolves Python modules. `PYTHONPATH=/app`, code at `/app/src/`, so `src.` prefix is required. |
| **alembic** (CLI tool) | `alembic upgrade head` | CLI tool, reads `alembic.ini` from workdir `/app`. No Python import path involved. |
| **migration runner** (future Python module) | `python -m agentic_runtime.db.migration_runner` | Per Helm values.yaml comment. The `src.` prefix would likely be needed here too (`src.agentic_runtime.db.migration_runner`) if running from `PYTHONPATH=/app`, but this module doesn't exist yet -- validate when implemented. |

### Phase 6.1 Default: One-Shot `migrate` Service

The **default Phase 6.1 implementation** is a one-shot compose service that runs `alembic upgrade head` before the backend starts:

```yaml
migrate:
  image: ${BACKEND_IMAGE:-ghcr.io/biznez-agentic/runtime-backend:latest}
  command: ["alembic", "upgrade", "head"]
  working_dir: /app
  environment:
    - DATABASE_URL=${DATABASE_URL}
  depends_on:
    postgres:
      condition: service_healthy
  restart: "no"
  networks:
    - biznez-network
```

Backend then depends on migration completion:
```yaml
backend:
  depends_on:
    migrate:
      condition: service_completed_successfully
    postgres:
      condition: service_healthy
```

**Why this is the default:**
- No repeated migrations on restart (one-shot, `restart: "no"`)
- No scaling footgun (migration runs in its own container, not in backend)
- Compose-native pattern (service dependency with completion condition)
- Matches the Helm `mode: hook` pattern (separate Job runs before app starts)

### Future Enhancement: Advisory-Lock Migration Runner

In a later phase (after `agentic_runtime.db.migration_runner` module is implemented):
- Replace `alembic upgrade head` in the migrate service with the advisory-lock runner
- This adds PostgreSQL advisory locks, retry logic, and timeout handling
- Same module used in K8s and compose -- no drift

### Alternative: Backend Entrypoint Migration (Power Users Only)

For single-instance eval deployments, an optional `RUN_MIGRATIONS=true` env var can trigger migration in the backend entrypoint. **Not recommended for scaled backends.**

```
sh -c "alembic upgrade head && uvicorn src.agentic_runtime.api.main:app ..."
```

**Constraints:**
- Do not scale backend replicas > 1 when using this approach
- Migrations re-run on every container restart
- No advisory lock protection

---

## Reference Files

| File (runtime repo) | What was extracted |
|-----|----------------|
| `biznez-agentic-framework/docker-compose.yml` | Service structure, env var patterns, healthchecks, network config. **Confirmed uvicorn path: `src.agentic_runtime.api.main:app`** |
| `biznez-agentic-framework/.env.example` | All env var names and defaults (293 lines) |
| `biznez-agentic-framework/frontend/nginx.conf` | Nginx config structure, security headers, proxy config |
| `biznez-agentic-framework/Dockerfile` | Backend image: python:3.11-slim-bookworm, alembic baked in, curl installed, non-root user, port 8000, `PYTHONPATH=/app`, `WORKDIR /app`. **CMD uses `src.agentic_runtime.api.main:app`** |
| `biznez-agentic-framework/frontend/Dockerfile` | Frontend image: nginx:1.25-alpine, wget available, port 80, `/usr/share/nginx/html` |
| `biznez-agentic-framework/setup.py` | `packages=find_packages(where='src')`, `package_dir={'': 'src'}` -- confirms src-layout |

| File (dist repo) | Status |
|-----|--------|
| `compose/docker-compose.yml` | Placeholder -- to be overwritten |
| `compose/.env.template` | Placeholder -- to be overwritten |
| `compose/nginx.conf` | Placeholder -- to be overwritten |
| `compose/setup.sh` | Placeholder -- to be overwritten |
| `compose/gateway-config.yaml` | Does not exist -- to be created |

---

## Verification (21 checks)

### Static Checks (1-14)

```bash
# Working directory: /Users/manimaun/Documents/code/biznez-runtime-dist

# 1. docker-compose.yml validates
docker compose -f compose/docker-compose.yml config --quiet 2>&1
# Expected: no errors (may warn about missing .env, which is OK)

# 2. .env.template has no real secrets
grep -c "CHANGE_ME" compose/.env.template
# Expected: >= 3 (ENCRYPTION_KEY, JWT_SECRET_KEY, POSTGRES_PASSWORD)

# 3. .env.template documents all required vars
for var in DATABASE_URL ENCRYPTION_KEY JWT_SECRET_KEY POSTGRES_PASSWORD AUTH_MODE; do
  grep -q "$var" compose/.env.template && echo "OK: $var" || echo "MISSING: $var"
done
# Expected: all OK

# 4. nginx.conf has API proxy enabled (not commented)
grep -c "proxy_pass http://backend:8000" compose/nginx.conf
# Expected: >= 1

# 5. nginx.conf has SSE support (both directives)
grep -c "proxy_buffering off" compose/nginx.conf
# Expected: >= 1
grep -c "X-Accel-Buffering" compose/nginx.conf
# Expected: >= 1

# 6. nginx.conf is mounted to conf.d/default.conf (not /etc/nginx/nginx.conf)
grep -c "conf.d/default.conf" compose/docker-compose.yml
# Expected: >= 1

# 7. setup.sh is executable and has correct shebang
head -1 compose/setup.sh
# Expected: #!/usr/bin/env bash

# 8. setup.sh generates ENCRYPTION_KEY via backend container (not host openssl as primary)
grep -c "docker run.*Fernet" compose/setup.sh
# Expected: >= 1

# 9. setup.sh guards secret generation with set +x
grep -c "set +x" compose/setup.sh
# Expected: >= 1

# 10. docker-compose.yml uses configurable ports
grep -c 'BACKEND_PORT\|FRONTEND_PORT\|POSTGRES_PORT' compose/docker-compose.yml
# Expected: >= 3

# 11. docker-compose.yml uses configurable images
grep -c 'BACKEND_IMAGE\|FRONTEND_IMAGE' compose/docker-compose.yml
# Expected: >= 2

# 12. gateway uses profiles (not commented out)
grep -c 'profiles:' compose/docker-compose.yml
# Expected: >= 1

# 13. backend does NOT run alembic or migrations by default
# Note: docker-compose.yml contains NO Phase 6.1 commented migration examples.
# The only command with "alembic" should not appear.
grep "alembic" compose/docker-compose.yml
# Expected: no output (exit code 1)

# 14. VITE_API_BASE_URL is documented as build-time only
grep -c "build-time\|BUILD-TIME\|build.time" compose/.env.template
# Expected: >= 1
```

### Runtime Checks (15-21, require docker)

```bash
# 15. docker compose up -d (on a clean machine with images available)
cd compose && docker compose up -d
# Expected: all services start

# 16. nginx config is valid inside the container
docker compose exec frontend nginx -t
# Expected: "syntax is ok" / "test is successful"

# 17. Frontend health through nginx proxy
curl -f http://localhost:8080/health
# Expected: 200 "healthy"

# 18. Backend health through nginx proxy
curl -f http://localhost:8080/api/v1/health
# Expected: 200 with JSON health response

# 19. SPA root serves index.html (not just /health)
curl -sf http://localhost:8080/ | head -c 100
# Expected: HTML content (e.g., "<!doctype html>" or similar)
# This catches misconfigured root directive or empty /usr/share/nginx/html

# 20. pull_policy version check (if COMPOSE_PULL_POLICY set)
docker compose version --short
# Expected: >= 2.17.0 if COMPOSE_PULL_POLICY is set

# 21. Gateway starts successfully (when profile enabled)
# docker compose --profile gateway up -d gateway
# sleep 10
# docker compose ps gateway | grep -q "running"
# Expected: gateway container running after 10s
# Optional: curl gateway health endpoint if available
```

---

## Exit Criteria

- [ ] `docker compose -f compose/docker-compose.yml config` validates without errors
- [ ] Backend uses pre-built image (not dev hot-reload)
- [ ] Backend command uses `src.agentic_runtime.api.main:app` (verified correct import path)
- [ ] Frontend uses nginx production build on port 8080 (not Vite 5173)
- [ ] **No migrations by default** -- backend starts uvicorn only (migration deferred to Phase 6.1)
- [ ] **No Phase 6.1 migration examples in `docker-compose.yml`** -- examples live only in plan doc
- [ ] Phase 6.1 section documents one-shot `migrate` service as the **default** approach
- [ ] Phase 6.1 uses `alembic upgrade head` (what exists today); advisory-lock runner documented as future enhancement
- [ ] Import path differences between uvicorn (`src.` needed) and alembic (no `src.`) are documented
- [ ] All ports configurable via `.env` (BACKEND_PORT, FRONTEND_PORT, POSTGRES_PORT)
- [ ] All images configurable via `.env` (BACKEND_IMAGE, FRONTEND_IMAGE)
- [ ] `setup.sh` generates ENCRYPTION_KEY **via backend container** (Fernet format guaranteed)
- [ ] `setup.sh` captures secrets into variables, never echoes them; `set +x` guard around generation
- [ ] `setup.sh` generates JWT_SECRET_KEY and POSTGRES_PASSWORD via `openssl` (no host python deps)
- [ ] `setup.sh` writes secrets to `.env` only (not terminal)
- [ ] `setup.sh` is bash 3.2+ compatible (no bash 4+ features)
- [ ] `setup.sh` polls both backend and frontend health endpoints
- [ ] `setup.sh` runs `nginx -t` inside frontend container after start
- [ ] `setup.sh` warns if `COMPOSE_PULL_POLICY=never` and images missing locally
- [ ] `setup.sh` checks compose version and warns if < 2.17 when `COMPOSE_PULL_POLICY` is set
- [ ] `.env.template` documents all variables with comments
- [ ] `.env.template` marks `VITE_*` as build-time only
- [ ] nginx.conf mounted to **`/etc/nginx/conf.d/default.conf`** (not `/etc/nginx/nginx.conf`)
- [ ] nginx.conf proxies `/api/` and `/ws` to backend
- [ ] nginx.conf has SSE support (`proxy_buffering off` + `X-Accel-Buffering no`)
- [ ] nginx.conf uses `map`-based `$connection_upgrade` for WebSocket
- [ ] Backend healthcheck uses `curl` (confirmed installed in Dockerfile)
- [ ] Frontend healthcheck uses `wget` (confirmed available in nginx:alpine)
- [ ] Gateway uses **compose profiles** (not commented-out YAML)
- [ ] Gateway config file exists and schema matches Helm chart's gateway config
- [ ] Gateway container stays running when profile is enabled (runtime check)
- [ ] SPA root `/` serves index.html content (not just `/health` returning 200)
- [ ] PostgreSQL data persists across restarts (named volume)
- [ ] Air-gapped support via `pull_policy: ${COMPOSE_PULL_POLICY:-if_not_present}` per service (documented: requires v2.17+)
