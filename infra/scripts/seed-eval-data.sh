#!/usr/bin/env bash
# =============================================================================
# seed-eval-data.sh -- Insert connector definitions + model pricing for eval
# =============================================================================
# Workaround for fresh-DB bootstrap (init_database_schema.py + stamp head)
# that skips data-bearing Alembic migrations.
#
# MAINTENANCE: When runtime repo connector/pricing migrations change,
# update this script to match.
#
# Usage:
#   ./seed-eval-data.sh --namespace biznez --release biznez
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
NO_COLOR="${NO_COLOR:-false}"
_color_enabled() { [ "$NO_COLOR" = "false" ] && [ -t 1 ]; }

info()  { if _color_enabled; then printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; else printf '[INFO]  %s\n' "$*"; fi; }
ok()    { if _color_enabled; then printf '\033[0;32m[OK]\033[0m    %s\n' "$*"; else printf '[OK]    %s\n' "$*"; fi; }
error() { if _color_enabled; then printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; else printf '[ERROR] %s\n' "$*" >&2; fi; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
NAMESPACE="biznez"
RELEASE="biznez"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --release)   RELEASE="$2"; shift 2 ;;
        *)           error "Unknown argument: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Discover Postgres pod
# ---------------------------------------------------------------------------
info "Discovering Postgres pod in namespace=$NAMESPACE release=$RELEASE..."
PG_POD=$(kubectl get pod -n "$NAMESPACE" \
    -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=postgres" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true

if [ -z "$PG_POD" ]; then
    error "No Postgres pod found for release=$RELEASE in namespace=$NAMESPACE"
    exit 1
fi
info "Using Postgres pod: $PG_POD"

# ---------------------------------------------------------------------------
# Helper: execute SQL via psql in the Postgres pod
# ---------------------------------------------------------------------------
run_sql() {
    kubectl exec "$PG_POD" -n "$NAMESPACE" -- \
        psql -U biznez -d biznez_platform -tA -c "$1" 2>&1
}

run_sql_block() {
    kubectl exec "$PG_POD" -n "$NAMESPACE" -i -- \
        psql -U biznez -d biznez_platform --set=ON_ERROR_STOP=1 2>&1
}

# ---------------------------------------------------------------------------
# Seed connector definitions (4 LLM connectors, transaction-wrapped)
# ---------------------------------------------------------------------------
info "Seeding connector definitions..."

CONNECTOR_SQL=$(cat <<'EOSQL'
BEGIN;

-- Connector: openai
INSERT INTO connector_definitions (
    id, name, description, category, auth_type, auth_config, service_endpoints,
    llm_provider, llm_models, llm_default_model, icon_url, documentation_url, is_active
) VALUES (
    'openai',
    'OpenAI',
    'OpenAI GPT models including GPT-4, GPT-4o, and GPT-3.5',
    'llm',
    'org_provided',
    NULL,
    NULL,
    'openai',
    '[{"id": "gpt-4o", "name": "GPT-4o", "input_cost_per_1k": 0.005, "output_cost_per_1k": 0.015}, {"id": "gpt-4o-mini", "name": "GPT-4o Mini", "input_cost_per_1k": 0.00015, "output_cost_per_1k": 0.0006}, {"id": "gpt-4-turbo", "name": "GPT-4 Turbo", "input_cost_per_1k": 0.01, "output_cost_per_1k": 0.03}, {"id": "gpt-3.5-turbo", "name": "GPT-3.5 Turbo", "input_cost_per_1k": 0.0005, "output_cost_per_1k": 0.0015}]'::jsonb,
    'gpt-4o-mini',
    '/icons/openai.svg',
    'https://platform.openai.com/docs',
    true
) ON CONFLICT (id) DO NOTHING;

-- Connector: anthropic
INSERT INTO connector_definitions (
    id, name, description, category, auth_type, auth_config, service_endpoints,
    llm_provider, llm_models, llm_default_model, icon_url, documentation_url, is_active
) VALUES (
    'anthropic',
    'Anthropic Claude',
    'Anthropic''s Claude family of AI assistants. Industry-leading models for reasoning, coding, and analysis.',
    'llm',
    'org_provided',
    '{"api_key_required": true, "api_base": "https://api.anthropic.com", "env_var": "ANTHROPIC_API_KEY", "help_url": "https://console.anthropic.com/settings/keys"}'::jsonb,
    NULL,
    'anthropic',
    '[{"id": "claude-opus-4-5-20251101", "name": "Claude Opus 4.5", "category": "flagship", "input_cost_per_1k": 0.005, "output_cost_per_1k": 0.025}, {"id": "claude-sonnet-4-5-20250929", "name": "Claude Sonnet 4.5", "category": "general", "input_cost_per_1k": 0.003, "output_cost_per_1k": 0.015, "is_default": true}, {"id": "claude-haiku-4-5-20251101", "name": "Claude Haiku 4.5", "category": "fast", "input_cost_per_1k": 0.001, "output_cost_per_1k": 0.005}, {"id": "claude-opus-4-1-20250805", "name": "Claude Opus 4.1", "category": "flagship", "input_cost_per_1k": 0.015, "output_cost_per_1k": 0.075}, {"id": "claude-sonnet-4-20250514", "name": "Claude Sonnet 4", "category": "general", "input_cost_per_1k": 0.003, "output_cost_per_1k": 0.015}, {"id": "claude-3-5-sonnet-20241022", "name": "Claude 3.5 Sonnet", "category": "general", "input_cost_per_1k": 0.003, "output_cost_per_1k": 0.015}, {"id": "claude-3-opus-20240229", "name": "Claude 3 Opus", "category": "legacy", "input_cost_per_1k": 0.015, "output_cost_per_1k": 0.075}, {"id": "claude-3-sonnet-20240229", "name": "Claude 3 Sonnet", "category": "legacy", "input_cost_per_1k": 0.003, "output_cost_per_1k": 0.015}, {"id": "claude-3-haiku-20240307", "name": "Claude 3 Haiku", "category": "legacy", "input_cost_per_1k": 0.00025, "output_cost_per_1k": 0.00125}]'::jsonb,
    'claude-sonnet-4-5-20250929',
    '/icons/anthropic.svg',
    'https://docs.anthropic.com/',
    true
) ON CONFLICT (id) DO NOTHING;

-- Connector: gemini
INSERT INTO connector_definitions (
    id, name, description, category, auth_type, auth_config, service_endpoints,
    llm_provider, llm_models, llm_default_model, icon_url, documentation_url, is_active
) VALUES (
    'gemini',
    'Google Gemini',
    'Google''s Gemini family of multimodal AI models. Supports text, vision, and image generation via Google AI Studio.',
    'llm',
    'org_provided',
    '{"api_key_required": true, "api_base": "https://generativelanguage.googleapis.com/v1", "env_var": "GOOGLE_API_KEY", "help_url": "https://aistudio.google.com/app/apikey"}'::jsonb,
    NULL,
    'gemini',
    '[{"id": "gemini-3-pro-preview", "name": "Gemini 3 Pro", "category": "general", "input_cost_per_1k": 0.00125, "output_cost_per_1k": 0.005, "is_preview": true}, {"id": "gemini-3-flash-preview", "name": "Gemini 3 Flash", "category": "fast", "input_cost_per_1k": 0.000075, "output_cost_per_1k": 0.0003, "is_preview": true}, {"id": "gemini-2.5-pro", "name": "Gemini 2.5 Pro", "category": "general", "input_cost_per_1k": 0.00125, "output_cost_per_1k": 0.005}, {"id": "gemini-2.5-flash", "name": "Gemini 2.5 Flash", "category": "fast", "input_cost_per_1k": 0.000075, "output_cost_per_1k": 0.0003, "is_default": true}, {"id": "gemini-2.5-flash-lite", "name": "Gemini 2.5 Flash Lite", "category": "compact", "input_cost_per_1k": 0.000025, "output_cost_per_1k": 0.0001}, {"id": "gemini-2.0-flash", "name": "Gemini 2.0 Flash", "category": "fast", "input_cost_per_1k": 0.0001, "output_cost_per_1k": 0.0004}, {"id": "gemini-2.0-flash-lite", "name": "Gemini 2.0 Flash Lite", "category": "compact", "input_cost_per_1k": 0.000075, "output_cost_per_1k": 0.0003}, {"id": "gemini-2.5-flash-image", "name": "Gemini 2.5 Flash Image", "category": "image", "input_cost_per_1k": 0.000134, "output_cost_per_1k": 0.0}]'::jsonb,
    'gemini-2.5-flash',
    '/icons/gemini.svg',
    'https://ai.google.dev/gemini-api/docs',
    true
) ON CONFLICT (id) DO NOTHING;

-- Connector: ollama
INSERT INTO connector_definitions (
    id, name, description, category, auth_type, auth_config, service_endpoints,
    llm_provider, llm_models, llm_default_model, icon_url, documentation_url, is_active
) VALUES (
    'ollama',
    'Ollama',
    'Run open-source LLMs locally or via Ollama Cloud. Supports Llama, Mistral, Gemma, DeepSeek, Qwen, and more.',
    'llm',
    'org_provided',
    '{"deployment_modes": ["self_hosted", "cloud"], "self_hosted": {"api_base_required": true, "api_key_optional": true, "default_api_base": "http://localhost:11434"}, "cloud": {"api_base": "https://ollama.com", "api_key_required": true}}'::jsonb,
    NULL,
    'ollama',
    '[{"id": "deepseek-r1:8b", "name": "DeepSeek R1 8B", "category": "reasoning", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "qwen3-coder:30b", "name": "Qwen3 Coder 30B", "category": "coding", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "deepseek-coder-v2:16b", "name": "DeepSeek Coder V2 16B", "category": "coding", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "qwen3-vl:30b", "name": "Qwen3 VL 30B", "category": "vision", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "qwen3-vl:8b", "name": "Qwen3 VL 8B", "category": "vision", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "qwen3-vl:4b", "name": "Qwen3 VL 4B", "category": "vision", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "qwen3:30b", "name": "Qwen3 30B", "category": "general", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "qwen2.5:7b", "name": "Qwen 2.5 7B", "category": "general", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "gpt-oss:120b", "name": "GPT-OSS 120B", "category": "general", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "gpt-oss:20b", "name": "GPT-OSS 20B", "category": "general", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "gemma3:27b", "name": "Gemma 3 27B", "category": "general", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "gemma3:12b", "name": "Gemma 3 12B", "category": "general", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "gemma3:4b", "name": "Gemma 3 4B", "category": "general", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "gemma3:1b", "name": "Gemma 3 1B", "category": "general", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "gemma2:2b", "name": "Gemma 2 2B", "category": "general", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "llama3.2", "name": "Llama 3.2", "category": "general", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0, "is_default": true}, {"id": "mistral", "name": "Mistral 7B", "category": "general", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}, {"id": "phi3", "name": "Phi-3", "category": "general", "input_cost_per_1k": 0.0, "output_cost_per_1k": 0.0}]'::jsonb,
    'llama3.2',
    '/icons/ollama.svg',
    'https://ollama.com',
    true
) ON CONFLICT (id) DO NOTHING;

COMMIT;
EOSQL
)

info "Inserting 4 LLM connector definitions (openai, anthropic, gemini, ollama)..."
echo "$CONNECTOR_SQL" | run_sql_block || {
    error "Failed to insert connector definitions"
    exit 1
}
ok "Connector definitions inserted"

# ---------------------------------------------------------------------------
# Seed model pricing (7 OpenAI models, transaction-wrapped)
# ---------------------------------------------------------------------------
info "Seeding model pricing..."

PRICING_SQL=$(cat <<'EOSQL'
BEGIN;

INSERT INTO model_pricing (
    id, provider, model, input_price_per_million, output_price_per_million,
    cache_read_price_per_million, cache_write_price_per_million,
    effective_date, is_active
) VALUES
    ('mp_gpt4o',       'openai', 'gpt-4o',         2.50,  10.00, 1.25,  2.50,  '2025-01-01', true),
    ('mp_gpt4o_mini',  'openai', 'gpt-4o-mini',    0.15,   0.60, 0.075, 0.15,  '2025-01-01', true),
    ('mp_gpt4_turbo',  'openai', 'gpt-4-turbo',   10.00,  30.00, 5.00,  10.00, '2025-01-01', true),
    ('mp_gpt35_turbo', 'openai', 'gpt-3.5-turbo',  0.50,   1.50, 0.25,  0.50,  '2025-01-01', true),
    ('mp_o1',          'openai', 'o1',             15.00,  60.00, 7.50,  15.00, '2025-01-01', true),
    ('mp_o1_mini',     'openai', 'o1-mini',         3.00,  12.00, 1.50,  3.00,  '2025-01-01', true),
    ('mp_o1_preview',  'openai', 'o1-preview',     15.00,  60.00, 7.50,  15.00, '2025-01-01', true)
ON CONFLICT (provider, model, effective_date) DO NOTHING;

COMMIT;
EOSQL
)

info "Inserting 7 OpenAI model pricing rows..."
echo "$PRICING_SQL" | run_sql_block || {
    error "Failed to insert model pricing"
    exit 1
}
ok "Model pricing inserted"

# ---------------------------------------------------------------------------
# Verification: check specific natural keys
# ---------------------------------------------------------------------------
info "Verifying seed data..."
ERRORS=0

# Verify connector IDs
for cid in openai anthropic gemini ollama; do
    EXISTS=$(run_sql "SELECT id FROM connector_definitions WHERE id = '$cid';") || true
    EXISTS=$(echo "$EXISTS" | tr -d '[:space:]')
    if [ "$EXISTS" = "$cid" ]; then
        ok "Connector '$cid' exists"
    else
        error "FAIL: missing connector id '$cid'"
        ERRORS=$((ERRORS + 1))
    fi
done

# Verify all 7 model pricing rows
for model_name in gpt-4o gpt-4o-mini gpt-4-turbo gpt-3.5-turbo o1 o1-mini o1-preview; do
    EXISTS=$(run_sql "SELECT model FROM model_pricing WHERE provider = 'openai' AND model = '$model_name';") || true
    EXISTS=$(echo "$EXISTS" | tr -d '[:space:]')
    if [ "$EXISTS" = "$model_name" ]; then
        ok "Pricing row openai/$model_name exists"
    else
        error "FAIL: missing pricing row openai/$model_name"
        ERRORS=$((ERRORS + 1))
    fi
done

if [ "$ERRORS" -gt 0 ]; then
    error "Seed verification failed with $ERRORS error(s)"
    exit 1
fi

ok "Eval seed data verified: 4 connectors, 7 pricing rows"
