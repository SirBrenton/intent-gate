# PROGRESS

This file tracks intent-gate development milestones and documentary artifacts.

## Current focus (V1)
Minimal refusal boundary for agentic execution:
**block destructive filesystem commands unless an explicit Intent Record exists**.

## Shipped (high signal)
- Deterministic allow/deny gate for mutating shell commands
- Scope enforcement (IR root must match sandbox root)
- Deny-glob protections (e.g., `**/*.pem`, `**/*.key`, `**/.git/**`)
- Symlink escape protection for write-like mutations
- Append-only audit log (decision + execution events)
- Reproducible evidence artifacts (`./makew evidence`)
- Demo workflow (`./makew demo`)

## Docs added
- Case study: `docs/case-studies/intent_failure_001.md`
- Narrative: `docs/narratives/intent_is_boundaries_not_predictions.md`
- Checklist: `docs/REFUSAL_BOUNDARY_CHECKLIST.md` (+ PDF)

## Next (still V1, no scope expansion)
- Keep README “Objections” section pointed to the narrative doc
- Add Case Study 002 (optional): filesystem-specific failure mode (e.g., symlink escape / wrong-root / wildcard delete)