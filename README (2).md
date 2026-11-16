# ATEly

Open, replayable automotive test execution platform.
Deterministic first (P1); AI-assisted composition comes later behind review gates.

ATEly implements the OpenATE PRD v1.2.1 contract with fixes documented in `docs/adr/`.

## Quick start

```bash
docker compose up -d
# API: http://localhost:8080/docs
```

Local dev without Docker:

```bash
createdb ately
psql -v ON_ERROR_STOP=1 -d ately -f db/baseline/baseline.sql
pip install -r server/requirements.txt
uvicorn server.main:app --port 8080
```

The bundled simulation driver lets you run the full loop with no hardware:
project → test case → (script or frozen composition) → task snapshot → run →
attempt → step_execution → verdict → human judgment.

## Layout

```
db/baseline/   fresh-deployment schema, 34+ tables, executed on PG16/PG17
db/ci/         migration & guard verification scripts (used by CI)
server/        FastAPI app: seeding, run loop, judgment API
docs/adr/      architecture decision records (contract fixes)
deploy/        docker-compose, Helm (later)
spi/           driver/step SPI notes
eval/          LLM evaluation harness (M3)
```

## Contract fixes vs PRD v1.2.1

| Fix | What changed |
| --- | --- |
| FIX-1 | Parents carry UNIQUE(project_id, id); children use composite FKs so cross-project references are impossible at the DB layer. |
| FIX-2 | TimescaleDB optional and failure-tolerant; minimal installs never fail on it. |
| FIX-4 | judge_review is append-only with one resolve per attempt; verdict→status mapping lives in the executor. |
| FIX-5 | Freeze requires approve review records; ai/mixed origin requires two distinct non-creator reviewers; all enforced by triggers. |

See `docs/adr/` for rationale.

## Status

v0.1: deterministic execution closed loop, simulated device, RLS, guards.
Verified in sandbox on PostgreSQL 17 (CI matrix runs PostgreSQL 16).
