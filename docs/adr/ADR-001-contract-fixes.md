# ADR-0001 Contract fixes over OpenATE PRD v1.2.1

Status: accepted. Applies at v0.1.

## Context

The PRD v1.2.1 static-checked contract left several real gaps we verified on a live PostgreSQL:

1. RLS checks only the row's own `project_id`; single-column FKs let a user reference another project's `script`/`task`/`device`. Fixed by parents carrying `UNIQUE(project_id,id)` and children using composite FKs.
2. `pg_available_extensions` is not proof that `shared_preload_libraries` includes `timescaledb`; minimal installs would fail. Fixed by try/except and plain-table fallback.
3. Backfill + `SET NOT NULL` migrations on legacy data can fail mid-way on orphan rows; that path lives in `db/migrations` with `db/precheck` queries, not in this fresh-deploy baseline.
4. Verdict→status mapping after human judgment was unspecified. Mapping is now code-owned (`PASS→PASSED`, `FAIL→FAILED`, `INCONCLUSIVE→ERROR`, `NOT_APPLICABLE→SKIPPED`) and `judge_review` is one-resolve-per-attempt (partial unique index).
5. Freeze could be satisfied without an `approve` review; ai/mixed origins had no dual-approval guarantee; a creator could approve their own work. All three now enforced by triggers (`guard_composition_version`, `guard_composition_review_insert`).

## Consequences

- Cross-project references are impossible at the DB layer, not just unlikely at the app layer.
- Failed approve attempts cannot poison later freeze decisions because the creator-approve row is rejected at insert time.
- Minimal deployments (no TimescaleDB) are first-class; time-series is optional.
