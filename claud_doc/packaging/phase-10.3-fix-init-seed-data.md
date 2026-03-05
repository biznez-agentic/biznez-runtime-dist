# Phase 10.3: Fix init_database_schema.py to Seed Reference Data

## Problem

`scripts/init_database_schema.py` creates all tables via `Base.metadata.create_all()` and then stamps alembic at HEAD. This means `alembic upgrade head` sees nothing to do, so **data-only migrations are skipped**. Two tables end up empty:

1. **`plans`** — Registration fails with FK violation: `plan_id='free' is not present in table plans`
2. **`connector_definitions`** — Connectors page shows empty, no LLM providers available

This affects every fresh eval environment deployment.

## Root Cause

In `scripts/init_database_schema.py` (around line 50-70):
```python
Base.metadata.create_all(bind=engine)  # Creates all tables (DDL only, no data)
# ...
alembic_cfg = Config("alembic.ini")
command.stamp(alembic_cfg, "head")     # Marks ALL migrations as applied
```

The alembic migrations contain INSERT statements for seed data (plans, connector_definitions, etc.) but `stamp("head")` marks them as already run without executing them.

## Fix (Runtime Repo)

### Option A: Add seed calls to init_database_schema.py (Recommended)

After `Base.metadata.create_all()` and before/after stamping, call the seed functions:

**File: `scripts/init_database_schema.py`**

```python
# After creating tables and stamping alembic...

# Seed required reference data
from agentic_runtime.services.plan_service import PlanService
from agentic_runtime.models import DEFAULT_PLANS, DEFAULT_CONNECTOR_DEFINITIONS

with Session(engine) as session:
    # Seed plans
    plan_service = PlanService(session)
    created = plan_service.seed_default_plans()
    if created:
        print(f"[init_database_schema] Seeded {created} default plans")

    # Seed connector definitions
    from agentic_runtime.models import ConnectorDefinition
    for conn_def in DEFAULT_CONNECTOR_DEFINITIONS:
        existing = session.query(ConnectorDefinition).filter_by(id=conn_def['id']).first()
        if not existing:
            session.add(ConnectorDefinition(**conn_def))
    session.commit()
    print("[init_database_schema] Seeded connector definitions")
```

### Option B: Run alembic upgrade instead of stamp

Replace `command.stamp(alembic_cfg, "head")` with `command.upgrade(alembic_cfg, "head")`. This actually runs the migrations (including data inserts) rather than just marking them as done. However, this may fail if the tables already exist from `create_all()`.

### Recommendation

Option A is safer — it's explicit, idempotent, and doesn't change the migration flow.

## Interim Fix (Dist Repo — Already Implemented)

The dist repo's `provision.sh` now calls `seed-eval-data.sh` after Helm install, which inserts the same data via direct SQL. This is a safety net — the runtime repo should still be fixed as the permanent solution.
