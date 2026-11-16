# Safety

The software drives test benches and vehicle ECUs. Physical safety is your responsibility.

## Non-goals of this software

- No functional-safety certification (ISO 26262 / GB etc.). This code is not a safety element.
- No emergency stop. E-stop and hardware limits must exist independently in the driver layer and wiring.
- An LLM has no execution, judgment, symbol-write or freeze rights; safety-critical steps need two human approvals plus bench-level envelopes.

## Minimum operating rules

1. Never run against real hardware without bench envelopes and 速 limits at the driver layer.
2. Composition freeze requires human review; ai/mixed origin requires two distinct non-creator reviewers (enforced by DB guards).
3. Evidence and audit records are append-only; do not weaken guards to "fix" data.
4. Any change to hash/回放 semantics requires a new ADR and a migration test.

## Incident expectations

On lock force-release the system writes `FORCE_RELEASED` plus audit; a P1 alert must be raised by operators. Treat unexplained FAILED/ABORTED runs as blocked until evidence is reviewed.
