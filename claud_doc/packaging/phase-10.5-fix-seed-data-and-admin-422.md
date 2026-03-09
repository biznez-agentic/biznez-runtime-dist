# Fix: Seed Data Missing + Admin Registration 422

## Context

After provisioning eval environment `manimaun17-zxiw` (GitHub Actions run 22798263645), two bootstrap failures:

1. **Seed data missing** — `connector_definitions` (0 rows), `model_pricing` (0 rows) — eval environment has no LLM connectors
2. **Admin registration HTTP 422** — cascading failure: no admin user → no workspace → no runtime registration

## Root Cause Analysis

### Issue 1: Seed Data Not Present

**Root cause:** `init_database_schema.py` on a fresh empty DB:
1. Creates ALL tables via `Base.metadata.create_all()` (raw DDL — no data inserts)
2. Runs `alembic stamp head` — marks ALL migrations as "applied"

Then `alembic upgrade head` finds nothing to do. **The Alembic migrations that INSERT connector definitions and model pricing never execute** — they were stamped without running.

**Evidence:** The eval-gke.yaml migration command (line 30):
```
python3 -u scripts/init_database_schema.py && alembic upgrade head
```

**File:** `/Users/manimaun/Documents/code/biznez-agentic-framework/scripts/init_database_schema.py` (lines 50-62)

`provision.sh` step 9 tries to call `seed-eval-data.sh` but the file doesn't exist — it was referenced in the plan as "PR #34" but was never created.

**Structural note:** This is not a one-off problem. The `create_all() + stamp head` pattern will **continue to skip any future data-bearing Alembic migrations** added upstream. Any new connector definition or pricing migration added to the runtime repo will also be bypassed on fresh eval DBs unless separately handled by this seed script. This must be reviewed whenever connector/model migrations change upstream.

### Issue 2: Admin Registration HTTP 422

**Root cause:** Email `admin@eval.biznez.local` uses `.local` TLD. Pydantic's `EmailStr` (backed by `email-validator` library) rejects `.local` as invalid, returning 422.

**Schema file:** `/Users/manimaun/Documents/code/biznez-agentic-framework/src/agentic_runtime/schemas/auth.py` line 41:
```python
email: EmailStr = Field(..., description="Valid email address")
```

**Cascading:** No access token → steps 13 (workspace) and 14 (runtime) silently skipped.

---

## Verified Schema (from runtime repo models + migrations)

### `connector_definitions` — 15 columns

| Column | Type | Nullable | Notes |
|--------|------|----------|-------|
| `id` | VARCHAR(50) | NO | **PK** — human-readable: `'openai'`, `'anthropic'`, etc. |
| `name` | VARCHAR(100) | NO | Display name |
| `description` | TEXT | YES | |
| `category` | VARCHAR(20) | NO | Check: `'llm'`, `'service'`, `'knowledge'` |
| `auth_type` | VARCHAR(20) | NO | Check: `'oauth'`, `'api_key'`, `'org_provided'`, `'service_account'` |
| `auth_config` | JSON | YES | NULL for OpenAI; JSON for Anthropic/Gemini/Ollama |
| `service_endpoints` | JSON | YES | NULL for LLM connectors |
| `llm_provider` | VARCHAR(50) | YES | e.g. `'openai'`, `'anthropic'` |
| `llm_models` | JSON | YES | Array of model objects with pricing |
| `llm_default_model` | VARCHAR(100) | YES | e.g. `'gpt-4o-mini'` |
| `icon_url` | VARCHAR(255) | YES | |
| `documentation_url` | VARCHAR(255) | YES | |
| `is_active` | BOOLEAN | NO | Default `true` |
| `created_at` | TIMESTAMP | NO | Server default `CURRENT_TIMESTAMP` |
| `updated_at` | TIMESTAMP | NO | Server default `CURRENT_TIMESTAMP` |

**Conflict key:** `ON CONFLICT (id) DO NOTHING` — PK is the only unique constraint.

### `model_pricing` — 11 columns

| Column | Type | Nullable | Notes |
|--------|------|----------|-------|
| `id` | VARCHAR(50) | NO | **PK** — generated: `'mp_gpt4o'`, `'mp_gpt4o_mini'`, etc. |
| `provider` | VARCHAR(50) | NO | e.g. `'openai'` |
| `model` | VARCHAR(100) | NO | e.g. `'gpt-4o'` |
| `input_price_per_million` | DECIMAL(10,4) | NO | |
| `output_price_per_million` | DECIMAL(10,4) | NO | |
| `cache_read_price_per_million` | DECIMAL(10,4) | NO | Default `0` |
| `cache_write_price_per_million` | DECIMAL(10,4) | NO | Default `0` |
| `effective_date` | DATE | NO | All rows use `'2025-01-01'` |
| `is_active` | BOOLEAN | NO | Default `true` |
| `created_at` | TIMESTAMP | NO | Server default `CURRENT_TIMESTAMP` |
| `updated_at` | TIMESTAMP | NO | Server default `CURRENT_TIMESTAMP` |

**Conflict key:** `ON CONFLICT (provider, model, effective_date) DO NOTHING` — unique index `idx_model_pricing_unique` on those three columns.

---

## Fix Plan

### Seed Data Design Decision: Eval Baseline (curated subset)

This script is an **eval-only bootstrap seed** — not a full mirror of runtime migration data. The runtime repo Alembic migrations remain the source of truth for production seed data. This script exists solely because the fresh-DB bootstrap (`init_database_schema.py` + `stamp head`) bypasses all data-bearing migrations.

**Maintenance rule:** When connector or model pricing migrations change in the runtime repo, this seed script must be reviewed and updated to match.

### Fix 1: Create `infra/scripts/seed-eval-data.sh` (NEW file)

Direct SQL inserts into the Postgres pod — no API dependencies, no auth required.

**Idempotency via verified conflict keys:**

| Table | Conflict Key | Verified Against | SQL Pattern |
|-------|-------------|------------------|-------------|
| `connector_definitions` | `id` (PK, VARCHAR(50)) | Model PK in `models/__init__.py:3198` | `INSERT ... ON CONFLICT (id) DO NOTHING` |
| `model_pricing` | `(provider, model, effective_date)` | Unique index `idx_model_pricing_unique` in `models/__init__.py:3727` | `INSERT ... ON CONFLICT (provider, model, effective_date) DO NOTHING` |

**Transaction safety:** Each logical seed set wrapped in `BEGIN; ... COMMIT;`:
- Transaction 1: All connector definitions
- Transaction 2: All model pricing rows

This prevents half-seeded states if one insert fails mid-way.

**The script will:**
1. Accept `--namespace` and `--release` args
2. Discover the Postgres pod via label selector — log which pod is targeted
3. Log each SQL block before execution (e.g. "Seeding connector: openai...")
4. Insert connector definitions with `ON CONFLICT (id) DO NOTHING` (in one transaction)
5. Insert model pricing with `ON CONFLICT (provider, model, effective_date) DO NOTHING` (in one transaction)
6. Verify by checking for specific natural keys (not row counts):
   - Connector IDs: `openai`, `anthropic`, `gemini`, `ollama`
   - Model pricing: spot-check `gpt-4o` and `gpt-4o-mini` for provider `openai`
7. **Surface which specific key failed** in error output (e.g. `"FAIL: missing connector id 'gemini'"`, `"FAIL: missing pricing row openai/gpt-4o"`)
8. Log before/after existence checks and clear exit message
9. Exit non-zero on verification failure

**Eval baseline connector set (4 LLM connectors):**

Gmail excluded from eval baseline — it requires OAuth setup that eval users cannot immediately use, creating noise in the first-run experience. LLM connectors only.

| ID | Name | Category | Auth Type | Source Migration |
|----|------|----------|-----------|-----------------|
| `openai` | OpenAI | llm | org_provided | `phase1_connector_foundation.py` |
| `anthropic` | Anthropic Claude | llm | org_provided | `add_anthropic_connector_definition.py` |
| `gemini` | Google Gemini | llm | org_provided | `add_gemini_connector_definition.py` |
| `ollama` | Ollama | llm | org_provided | `add_ollama_connector_definition.py` |

Each connector insert will include all 15 columns with exact values from the corresponding Alembic migration, including `auth_config` (JSON), `llm_models` (JSON array with per-model pricing), `llm_default_model`, `icon_url`, and `documentation_url`.

**Eval baseline model pricing (7 OpenAI models):**

Mirrors `phase2_day1_model_pricing.py` exactly — including **cache pricing columns** (`cache_read_price_per_million`, `cache_write_price_per_million`).

| ID | Provider | Model | Input/1M | Output/1M | Cache Read/1M | Cache Write/1M | Effective Date |
|----|----------|-------|----------|-----------|---------------|----------------|----------------|
| `mp_gpt4o` | openai | gpt-4o | 2.50 | 10.00 | 1.25 | 2.50 | 2025-01-01 |
| `mp_gpt4o_mini` | openai | gpt-4o-mini | 0.15 | 0.60 | 0.075 | 0.15 | 2025-01-01 |
| `mp_gpt4_turbo` | openai | gpt-4-turbo | 10.00 | 30.00 | 5.00 | 10.00 | 2025-01-01 |
| `mp_gpt35_turbo` | openai | gpt-3.5-turbo | 0.50 | 1.50 | 0.25 | 0.50 | 2025-01-01 |
| `mp_o1` | openai | o1 | 15.00 | 60.00 | 7.50 | 15.00 | 2025-01-01 |
| `mp_o1_mini` | openai | o1-mini | 3.00 | 12.00 | 1.50 | 3.00 | 2025-01-01 |
| `mp_o1_preview` | openai | o1-preview | 15.00 | 60.00 | 7.50 | 15.00 | 2025-01-01 |

**Data sourced from Alembic migrations in runtime repo (read-only):**

| Migration File | Seeds |
|---------------|-------|
| `phase1_connector_foundation.py` | OpenAI connector |
| `add_anthropic_connector_definition.py` | Anthropic connector (9 models) |
| `add_gemini_connector_definition.py` | Gemini connector (8 models) |
| `add_ollama_connector_definition.py` | Ollama connector (18 models) |
| `phase2_day1_model_pricing.py` | OpenAI pricing (7 models) |

### Fix 2: Change admin email in `infra/scripts/provision.sh`

Change `admin@eval.biznez.local` → `admin@eval.biznez.io`

Using `biznez.io` — valid TLD that passes `email-validator`, clearly synthetic (eval-only), consistent with the project domain.

Update in 2 places:
- Line 531: Registration JSON payload
- Line 572: SQL promotion WHERE clause

### Fix 3: Make bootstrap steps fatal in `infra/scripts/provision.sh`

For zero-touch eval, a "succeeded" workflow must deliver a fully working environment. Change the following from warn-and-continue to error-and-exit.

**New exit code:** `EXIT_BOOTSTRAP=5` — distinct from existing `EXIT_KUBE=3` (Kubernetes failures) and `EXIT_HELM=4` (Helm failures). Bootstrap failures (seed data, admin registration, workspace, runtime) are application-level, not infrastructure-level.

| Step | Current Behavior | New Behavior | Exit Code |
|------|-----------------|-------------|-----------|
| Seed data (step 9) | `warn` + continue | `error` + `exit $EXIT_BOOTSTRAP` | 5 |
| Admin registration (step 12) | `warn` + continue | `error` + `exit $EXIT_BOOTSTRAP` | 5 |
| Workspace creation (step 13) | `warn` + continue | `error` + `exit $EXIT_BOOTSTRAP` | 5 |
| Runtime registration (step 14) | `warn` + continue | `error` + `exit $EXIT_BOOTSTRAP` | 5 |

This prevents the workflow from reporting "success" when it delivers a broken eval.

### Execution Order in provision.sh

Ensure clean dependency chain:

```
Step 6:  Helm install (schema init + migrations run via initContainer)
Step 7:  Rollout wait
Step 8:  Health check
Step 9:  Seed eval data  ← seed-eval-data.sh (FATAL on failure)
Step 10: RBAC + kubeconfig
Step 11: Port-forward
Step 12: Admin register + promote (FATAL on failure)
Step 13: Workspace create (FATAL on failure)
Step 14: Runtime register (FATAL on failure)
Step 15: Ingress verify
Step 16: Outputs
```

Seed data runs after health check (DB is ready) but before admin bootstrap (clean dependencies).

---

## Files Modified (2 files)

| # | File | Change |
|---|------|--------|
| 1 | `infra/scripts/seed-eval-data.sh` | **NEW** — Eval-only SQL seed for 4 LLM connectors + 7 pricing rows, transaction-wrapped, key-based verification with specific failure messages |
| 2 | `infra/scripts/provision.sh` | Fix email `.local` → `.io`; add `EXIT_BOOTSTRAP=5`; make steps 9/12/13/14 fatal |

## Verification

1. Provision fresh eval environment via workflow dispatch
2. DB: connector IDs `openai`, `anthropic`, `gemini`, `ollama` all exist
3. DB: `model_pricing` has rows for `gpt-4o`, `gpt-4o-mini` with provider `openai` and correct cache pricing
4. Admin registration returns 201 (not 422)
5. Admin user exists with `is_admin=true`
6. Default workspace created (HTTP 201)
7. GKE runtime registered (HTTP 201)
8. Provision.sh completes with exit code 0 and no `[WARN]` messages on bootstrap steps
9. Re-run bootstrap steps against same environment is idempotent: seed inserts report "already exists", admin login succeeds, no errors

## Maintenance Notes

- **When runtime repo adds new connector migrations:** Review and update `seed-eval-data.sh` to include new connectors in the eval baseline. Follow-up: add a CI check or PR template reminder that flags changes to `alembic/versions/*connector*` or `alembic/versions/*pricing*` files.
- **When runtime repo adds new pricing migrations:** Review and update pricing inserts in `seed-eval-data.sh`.
- **This script does NOT replace runtime migrations:** It is a workaround for the `create_all() + stamp head` bootstrap pattern that skips data-bearing migrations on fresh DBs.
- **If the fresh-DB bootstrap approach is ever fixed upstream** (e.g. running migrations instead of `stamp head`), this script becomes redundant and can be removed.
