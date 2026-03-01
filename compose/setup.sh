#!/usr/bin/env bash
# =============================================================================
# Biznez Agentic Runtime -- Docker Compose Setup
# =============================================================================
# Generates secrets, creates .env, and starts services.
#
# Usage:
#   ./setup.sh                 # generate secrets + start services
#   ./setup.sh --generate-only # generate secrets only (don't start)
#   ./setup.sh --no-start      # alias for --generate-only
#   ./setup.sh --show-secrets  # print generated secrets to terminal (opt-in)
#
# SECURITY: Do not run with bash -x (xtrace). It prints variable assignments
# including secrets. The script guards generation with set +x, but that only
# works when the script controls xtrace itself.
# =============================================================================
set -euo pipefail

# ---- Globals ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_TEMPLATE="${SCRIPT_DIR}/.env.template"
ENV_FILE="${SCRIPT_DIR}/.env"
GENERATE_ONLY=false
SHOW_SECRETS=false

# ---- Parse flags ------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --generate-only|--no-start) GENERATE_ONLY=true ;;
        --show-secrets) SHOW_SECRETS=true ;;
        -h|--help)
            echo "Usage: $0 [--generate-only|--no-start] [--show-secrets]"
            echo ""
            echo "  --generate-only  Generate secrets and .env but don't start services"
            echo "  --no-start       Alias for --generate-only"
            echo "  --show-secrets   Print generated secrets to terminal (opt-in)"
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown flag: $arg"
            echo "Run $0 --help for usage."
            exit 1
            ;;
    esac
done

# ---- Helpers ----------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; }
die()   { error "$*"; exit 1; }

# ---- Step 1: Check prerequisites -------------------------------------------
info "Checking prerequisites..."

command -v docker >/dev/null 2>&1 || die "docker is not installed. Install Docker first."

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    die "docker compose (v2 plugin) is not available. Install the Compose plugin."
fi

ok "docker and docker compose found."

# ---- Step 2: Check compose version for pull_policy support ------------------
check_compose_version() {
    local version_str
    version_str=$($COMPOSE_CMD version --short 2>/dev/null || echo "0.0.0")
    # Strip leading 'v' if present
    version_str="${version_str#v}"

    local major minor
    major=$(echo "$version_str" | cut -d. -f1)
    minor=$(echo "$version_str" | cut -d. -f2)

    # Check if .env has COMPOSE_PULL_POLICY set
    if [ -f "$ENV_FILE" ] && grep -q "^COMPOSE_PULL_POLICY=" "$ENV_FILE"; then
        local policy
        policy=$(grep "^COMPOSE_PULL_POLICY=" "$ENV_FILE" | cut -d= -f2)
        if [ "$policy" != "if_not_present" ]; then
            if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 17 ]; }; then
                warn "COMPOSE_PULL_POLICY=$policy requires docker compose v2.17+."
                warn "Your version: $version_str. pull_policy may be silently ignored."
            fi
        fi
    fi
}

# ---- Step 3: Create .env from template --------------------------------------
info "Setting up environment file..."

if [ ! -f "$ENV_TEMPLATE" ]; then
    die ".env.template not found at $ENV_TEMPLATE"
fi

if [ -f "$ENV_FILE" ]; then
    info ".env already exists."
else
    cp "$ENV_TEMPLATE" "$ENV_FILE"
    ok "Created .env from template."
fi

# ---- Step 4: Generate secrets -----------------------------------------------
# Check if secrets need generating (any CHANGE_ME_ placeholders remain)
if grep -q "CHANGE_ME" "$ENV_FILE"; then
    info "Generating secrets..."

    # Guard against xtrace leaking secrets
    { set +x; } 2>/dev/null

    # -- ENCRYPTION_KEY (Fernet format via backend container) --
    _backend_image=$(grep "^BACKEND_IMAGE=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)
    _backend_image="${_backend_image:-ghcr.io/biznez-agentic/runtime-backend:latest}"

    _enc_key=""
    _enc_key=$(docker run --rm "$_backend_image" \
        python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" \
        2>/dev/null) || true

    if [ -z "$_enc_key" ]; then
        warn "Could not generate Fernet key via backend container."
        warn "Falling back to openssl. The app may reject non-Fernet keys."
        _enc_key=$(openssl rand -base64 32 2>/dev/null) || \
            _enc_key=$(python3 -c "import base64,os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())" 2>/dev/null) || \
            die "Cannot generate ENCRYPTION_KEY. Install openssl or python3."
    fi

    # -- JWT_SECRET_KEY --
    _jwt_key=""
    _jwt_key=$(openssl rand -base64 32 2>/dev/null) || \
        _jwt_key=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))" 2>/dev/null) || \
        die "Cannot generate JWT_SECRET_KEY. Install openssl or python3."

    # -- POSTGRES_PASSWORD --
    _pg_pass=""
    _pg_pass=$(openssl rand -base64 24 2>/dev/null) || \
        _pg_pass=$(python3 -c "import secrets; print(secrets.token_urlsafe(24))" 2>/dev/null) || \
        die "Cannot generate POSTGRES_PASSWORD. Install openssl or python3."
    # Strip characters that break connection strings
    _pg_pass=$(echo "$_pg_pass" | tr -d '/+=')

    # -- Write secrets to .env (never to terminal) --
    # Use temp file + mv for atomicity
    _tmp_env="${ENV_FILE}.tmp.$$"
    cp "$ENV_FILE" "$_tmp_env"

    # Replace placeholders
    sed -i.bak "s|CHANGE_ME_ENCRYPTION_KEY|${_enc_key}|g" "$_tmp_env"
    sed -i.bak "s|CHANGE_ME_JWT_SECRET|${_jwt_key}|g" "$_tmp_env"
    sed -i.bak "s|CHANGE_ME_DB_PASSWORD|${_pg_pass}|g" "$_tmp_env"
    rm -f "${_tmp_env}.bak"

    mv "$_tmp_env" "$ENV_FILE"

    if [ "$SHOW_SECRETS" = "true" ]; then
        echo ""
        echo "  ENCRYPTION_KEY = $_enc_key"
        echo "  JWT_SECRET_KEY = $_jwt_key"
        echo "  POSTGRES_PASSWORD = $_pg_pass"
        echo ""
    fi

    # Clear secret variables
    _enc_key="" ; _jwt_key="" ; _pg_pass="" ; _backend_image=""

    ok "Secrets generated and written to .env"
else
    ok "Secrets already configured (no CHANGE_ME placeholders found)."
fi

# ---- Step 5: Check compose version -----------------------------------------
check_compose_version

# ---- Step 6: Air-gapped image check ----------------------------------------
if grep -q "^COMPOSE_PULL_POLICY=never" "$ENV_FILE" 2>/dev/null; then
    info "COMPOSE_PULL_POLICY=never detected. Checking local images..."
    _missing=0

    _be_img=$(grep "^BACKEND_IMAGE=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)
    _be_img="${_be_img:-ghcr.io/biznez-agentic/runtime-backend:latest}"
    if ! docker image inspect "$_be_img" >/dev/null 2>&1; then
        warn "Backend image not found locally: $_be_img"
        _missing=1
    fi

    _fe_img=$(grep "^FRONTEND_IMAGE=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)
    _fe_img="${_fe_img:-ghcr.io/biznez-agentic/runtime-frontend:latest}"
    if ! docker image inspect "$_fe_img" >/dev/null 2>&1; then
        warn "Frontend image not found locally: $_fe_img"
        _missing=1
    fi

    if ! docker image inspect "postgres:15-alpine" >/dev/null 2>&1; then
        warn "PostgreSQL image not found locally: postgres:15-alpine"
        _missing=1
    fi

    if [ "$_missing" -eq 1 ]; then
        warn "Some images are missing. Services may fail to start."
        warn "Load images with: docker load -i <image-archive>.tar"
    else
        ok "All required images found locally."
    fi
fi

# ---- Stop here if --generate-only ------------------------------------------
if [ "$GENERATE_ONLY" = "true" ]; then
    ok "Setup complete (--generate-only). Run 'docker compose up -d' to start."
    exit 0
fi

# ---- Step 7: Start services ------------------------------------------------
info "Starting services..."
cd "$SCRIPT_DIR"
$COMPOSE_CMD up -d

# ---- Step 8: Validate nginx config -----------------------------------------
info "Validating nginx configuration..."
sleep 3
if $COMPOSE_CMD exec -T frontend nginx -t 2>&1; then
    ok "nginx config is valid."
else
    warn "nginx -t reported issues. Check frontend container logs."
fi

# ---- Step 9: Wait for health ------------------------------------------------
info "Waiting for services to become healthy..."

_backend_port=$(grep "^BACKEND_PORT=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)
_backend_port="${_backend_port:-8000}"
_frontend_port=$(grep "^FRONTEND_PORT=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)
_frontend_port="${_frontend_port:-8080}"

# Poll backend health
_timeout=60
_elapsed=0
_backend_ok=false
while [ "$_elapsed" -lt "$_timeout" ]; do
    if curl -sf "http://localhost:${_backend_port}/api/v1/health" >/dev/null 2>&1; then
        _backend_ok=true
        break
    fi
    sleep 3
    _elapsed=$((_elapsed + 3))
done

if [ "$_backend_ok" = "true" ]; then
    ok "Backend is healthy (${_elapsed}s)."
else
    warn "Backend did not respond within ${_timeout}s."
    warn "Check logs: docker compose logs backend"
fi

# Poll frontend health
_timeout=30
_elapsed=0
_frontend_ok=false
while [ "$_elapsed" -lt "$_timeout" ]; do
    if curl -sf "http://localhost:${_frontend_port}/health" >/dev/null 2>&1; then
        _frontend_ok=true
        break
    fi
    sleep 2
    _elapsed=$((_elapsed + 2))
done

if [ "$_frontend_ok" = "true" ]; then
    ok "Frontend is healthy (${_elapsed}s)."
else
    warn "Frontend did not respond within ${_timeout}s."
    warn "Check logs: docker compose logs frontend"
fi

# ---- Step 10: Print access info --------------------------------------------
echo ""
echo "============================================="
echo "  Biznez Agentic Runtime is ready!"
echo "============================================="
echo ""
echo "  Frontend:    http://localhost:${_frontend_port}"
echo "  Backend API: http://localhost:${_backend_port}/api/v1/health"
echo ""

# Check auth mode for admin hint
_auth_mode=$(grep "^AUTH_MODE=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)
if [ "${_auth_mode:-local}" = "local" ]; then
    echo "  Auth mode: local"
    echo "  Check backend logs for first-run admin credentials:"
    echo "    docker compose logs backend | grep -i \"admin\\|password\\|created\""
    echo ""
fi

echo "  Useful commands:"
echo "    docker compose logs -f          # follow all logs"
echo "    docker compose ps               # service status"
echo "    docker compose down             # stop services"
echo "    docker compose down -v          # stop + delete data"
echo ""
