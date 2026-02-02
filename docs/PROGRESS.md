# Progress

## 2026-02-01 — Denial Context Snapshot (V0)

Goal:
- Test whether denial explanations increase legibility/acceptability without changing enforcement.

Changes:
- Print a deterministic Denial Context Snapshot on DENY only
- Add explicit anti-claim: context is explanatory only (does not influence decision)
- Fix double "DENY: DENY:" output (presentation-only)
- Add scope-mismatch denial transcript (SCOPE_MISMATCH classification)
- Make evidence artifacts reproducible/deterministic (sanitized diff; stable paths/timestamps)
- Use repo-local GNU Make wrapper (`./makew`) to avoid macOS `/usr/bin/make` 3.81

Evidence (generated via `./makew evidence`, implemented in `scripts/evidence.sh`):
- docs/demo_before_denial.txt (baseline; created only if missing)
- docs/demo_after_denial.txt (current run)
- docs/demo_denial_diff.patch (sanitized deterministic diff)
- docs/demo_scope_mismatch.txt (scope mismatch denial transcript)
