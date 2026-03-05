#!/usr/bin/env bash
# =============================================================================
# seed-eval-data.sh -- Seed required reference data for eval environments
# =============================================================================
# The runtime's init_database_schema.py creates tables via SQLAlchemy
# metadata.create_all() and stamps alembic at HEAD. This skips data-only
# migrations that INSERT seed rows (plans, connector_definitions).
#
# This script is a safety net that ensures required reference data exists
# after Helm install. It is idempotent (ON CONFLICT DO NOTHING).
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
warn()  { if _color_enabled; then printf '\033[0;33m[WARN]\033[0m  %s\n' "$*" >&2; else printf '[WARN]  %s\n' "$*" >&2; fi; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
NAMESPACE="biznez"
RELEASE="biznez"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)  NAMESPACE="$2"; shift 2 ;;
        --release)    RELEASE="$2"; shift 2 ;;
        *)            warn "Unknown argument: $1"; shift ;;
    esac
done

# ---------------------------------------------------------------------------
# Find postgres pod
# ---------------------------------------------------------------------------
PG_POD=$(kubectl get pod -n "$NAMESPACE" \
    -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=postgres" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true

if [ -z "$PG_POD" ]; then
    warn "No postgres pod found — skipping seed (external DB may be in use)"
    exit 0
fi

info "Seeding reference data via $PG_POD..."

# ---------------------------------------------------------------------------
# Seed plans
# ---------------------------------------------------------------------------
info "Seeding plans table..."
kubectl exec "$PG_POD" -n "$NAMESPACE" -- psql -U biznez -d biznez_platform -c "
INSERT INTO plans (id, name, display_name, description, price_monthly, price_yearly, currency,
    max_organizations, max_agents_per_org, max_users_per_org, max_executions_per_month,
    max_runtimes_per_org, max_connectors_per_org, max_storage_gb, features,
    is_active, is_public, sort_order, created_at, updated_at)
VALUES
('free', 'free', 'Free', 'Get started with basic features.', 0, 0, 'USD',
    1, 3, 5, 1000, 1, 5, 1,
    '{\"basic_analytics\": true, \"community_support\": true, \"api_access\": true}',
    true, true, 1, NOW(), NOW()),
('testing', 'testing', 'Testing (Unlimited)', 'Development/Testing plan with unlimited resources.', 0, 0, 'USD',
    -1, -1, -1, -1, -1, -1, -1,
    '{\"basic_analytics\": true, \"advanced_analytics\": true, \"api_access\": true, \"custom_agents\": true, \"testing_mode\": true}',
    true, true, 0, NOW(), NOW())
ON CONFLICT (id) DO NOTHING;
" 2>&1 || warn "Plans seed failed (table may not exist yet)"

# ---------------------------------------------------------------------------
# Seed connector definitions
# ---------------------------------------------------------------------------
info "Seeding connector_definitions table..."
kubectl exec "$PG_POD" -n "$NAMESPACE" -- psql -U biznez -d biznez_platform -c "
INSERT INTO connector_definitions (id, name, description, category, auth_type,
    auth_config, service_endpoints, llm_provider, llm_models, llm_default_model,
    icon_url, documentation_url, is_active, created_at, updated_at)
VALUES
('openai', 'OpenAI', 'OpenAI GPT models including GPT-4, GPT-4o, and GPT-3.5', 'llm', 'org_provided',
    NULL, NULL, 'openai',
    '[{\"id\":\"gpt-4o\",\"name\":\"GPT-4o\",\"input_cost_per_1k\":0.005,\"output_cost_per_1k\":0.015},
      {\"id\":\"gpt-4o-mini\",\"name\":\"GPT-4o Mini\",\"input_cost_per_1k\":0.00015,\"output_cost_per_1k\":0.0006},
      {\"id\":\"gpt-4-turbo\",\"name\":\"GPT-4 Turbo\",\"input_cost_per_1k\":0.01,\"output_cost_per_1k\":0.03}]',
    'gpt-4o-mini', '/icons/openai.svg', 'https://platform.openai.com/docs', true, NOW(), NOW()),

('anthropic', 'Anthropic', 'Anthropic Claude models including Claude 4 and Claude 3.5 Sonnet', 'llm', 'org_provided',
    NULL, NULL, 'anthropic',
    '[{\"id\":\"claude-sonnet-4-20250514\",\"name\":\"Claude Sonnet 4\",\"input_cost_per_1k\":0.003,\"output_cost_per_1k\":0.015},
      {\"id\":\"claude-3-5-sonnet-20241022\",\"name\":\"Claude 3.5 Sonnet\",\"input_cost_per_1k\":0.003,\"output_cost_per_1k\":0.015},
      {\"id\":\"claude-3-opus-20240229\",\"name\":\"Claude 3 Opus\",\"input_cost_per_1k\":0.015,\"output_cost_per_1k\":0.075}]',
    'claude-sonnet-4-20250514', '/icons/anthropic.svg', 'https://docs.anthropic.com', true, NOW(), NOW()),

('gemini', 'Google Gemini', 'Google Gemini models including Gemini 2.5 Pro and Flash', 'llm', 'org_provided',
    NULL, NULL, 'google',
    '[{\"id\":\"gemini/gemini-2.5-pro\",\"name\":\"Gemini 2.5 Pro\",\"input_cost_per_1k\":0.00125,\"output_cost_per_1k\":0.01},
      {\"id\":\"gemini/gemini-2.5-flash\",\"name\":\"Gemini 2.5 Flash\",\"input_cost_per_1k\":0.00015,\"output_cost_per_1k\":0.0006}]',
    'gemini/gemini-2.5-flash', '/icons/gemini.svg', 'https://ai.google.dev/docs', true, NOW(), NOW()),

('ollama', 'Ollama', 'Self-hosted open-source models via Ollama', 'llm', 'org_provided',
    NULL, NULL, 'ollama',
    '[{\"id\":\"llama3.1:8b\",\"name\":\"Llama 3.1 8B\",\"input_cost_per_1k\":0,\"output_cost_per_1k\":0},
      {\"id\":\"mistral:7b\",\"name\":\"Mistral 7B\",\"input_cost_per_1k\":0,\"output_cost_per_1k\":0}]',
    'llama3.1:8b', '/icons/ollama.svg', 'https://ollama.com', true, NOW(), NOW()),

('gmail', 'Gmail', 'Connect your Gmail account to read, send, and manage emails', 'service', 'oauth',
    '{\"oauth_provider\":\"google\",\"scopes\":[\"https://www.googleapis.com/auth/gmail.readonly\",\"https://www.googleapis.com/auth/gmail.send\",\"https://www.googleapis.com/auth/gmail.modify\"]}',
    '{\"local\":\"http://localhost:8083\",\"dev\":\"https://gmail-connector-dev.run.app\"}',
    NULL, NULL, NULL, '/icons/gmail.svg', 'https://developers.google.com/gmail/api', true, NOW(), NOW())

ON CONFLICT (id) DO NOTHING;
" 2>&1 || warn "Connector definitions seed failed (table may not exist yet)"

ok "Seed data applied"
