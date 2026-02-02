#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Paths (repo-relative)
# -----------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY="./.venv/bin/python"
INTENT_GATE="$PY ./src/intent_gate.py"
IR_TOOL="$PY ./src/ir_tool.py"

SANDBOX="${SANDBOX:-sandbox}"
DOCS="${DOCS:-docs}"
TMPDIR_REPO="${TMPDIR_REPO:-tmp}"

DEMO_BEFORE="${DEMO_BEFORE:-$DOCS/demo_before_denial.txt}"
DEMO_AFTER="${DEMO_AFTER:-$DOCS/demo_after_denial.txt}"
DEMO_DIFF="${DEMO_DIFF:-$DOCS/demo_denial_diff.patch}"

# Scope-mismatch artifacts (new: before/after/diff)
DEMO_SCOPE_BEFORE="${DEMO_SCOPE_BEFORE:-$DOCS/demo_scope_mismatch_before.txt}"
DEMO_SCOPE_AFTER="${DEMO_SCOPE_AFTER:-$DOCS/demo_scope_mismatch_after.txt}"
DEMO_SCOPE_DIFF="${DEMO_SCOPE_DIFF:-$DOCS/demo_scope_mismatch_diff.patch}"

# (optional legacy single-file output; keep if you want)
DEMO_SCOPE="${DEMO_SCOPE:-$DOCS/demo_scope_mismatch.txt}"

AUDIT="${AUDIT:-audit.jsonl}"

# -----------------------------
# Helpers
# -----------------------------

die() { echo "FATAL: $*" >&2; exit 2; }

sanitize() {
  # Normalize machine-specific and run-specific bits so artifacts don't churn.
  # - timestamps
  # - absolute paths
  # - /tmp vs /private/tmp
  # - IR filenames with timestamps
  sed -E \
    -e 's/"ts_utc":[[:space:]]*"[^"]+"/"ts_utc": "REDACTED"/g' \
    -e 's#(/Users/)[^" ]+#\1REDACTED#g' \
    -e 's#(/private)?/tmp#<TMP>#g' \
    -e 's#IR-[0-9]{8}-[0-9]{6}Z\.md#IR-REDACTED.md#g' \
    -e 's#intent_records/IR-[0-9]{8}-[0-9]{6}Z\.md#intent_records/IR-REDACTED.md#g'
}

assert_file_contains() {
  local needle="$1"
  local file="$2"
  grep -q "$needle" "$file" || die "Expected '$needle' in $file"
}

assert_file_not_contains() {
  local needle="$1"
  local file="$2"
  if grep -q "$needle" "$file"; then
    die "Did not expect '$needle' in $file"
  fi
}

# -----------------------------
# Preflight / safety
# -----------------------------
if [[ -z "$SANDBOX" || "$SANDBOX" == "/" || "$SANDBOX" == "." || "$SANDBOX" == ".." ]]; then
  die "SANDBOX is unsafe: '$SANDBOX'"
fi

mkdir -p "$DOCS" "$SANDBOX" "$TMPDIR_REPO"

rm -f "$AUDIT"
echo "hello" > "$SANDBOX/foo.txt"

# -----------------------------
# CASE 1: MISSING_INTENT (baseline + current + diff)
# -----------------------------

# BEFORE (baseline): keep committed artifact unless missing
if [[ ! -f "$DEMO_BEFORE" ]]; then
  set +e
  eval "$INTENT_GATE --dry-run --print-decision -- rm foo.txt" 2>&1 \
    | sanitize \
    | tee "$DEMO_BEFORE" >/dev/null
  true
  set -e
fi

# AFTER: always regenerate
set +e
eval "$INTENT_GATE --dry-run --print-decision -- rm foo.txt" 2>&1 \
  | sanitize \
  | tee "$DEMO_AFTER" >/dev/null
true
set -e

# Diff (deterministic because both are sanitized)
diff -u \
  --label "$(basename "$DEMO_BEFORE")" "$DEMO_BEFORE" \
  --label "$(basename "$DEMO_AFTER")"  "$DEMO_AFTER" \
  > "$DEMO_DIFF" || true

# Assertions on AFTER
assert_file_contains "Denial Context Snapshot" "$DEMO_AFTER"
assert_file_contains "did not influence the denial" "$DEMO_AFTER"
assert_file_not_contains "DENY: DENY:" "$DEMO_AFTER"

echo "OK: denial before/after artifacts + diff regenerated and assertions passed"

# -----------------------------
# CASE 2: SCOPE_MISMATCH (baseline + current + diff)
# -----------------------------

# Create (or reuse) a stable "bad" IR on disk, so the transcript is reproducible
# and doesn't depend on a fresh IR path every run.
IR_BAD_PATH="$TMPDIR_REPO/IR_SCOPE_MISMATCH.md"

needs_regen=0
if [[ ! -f "$IR_BAD_PATH" ]]; then
  needs_regen=1
elif ! grep -q '^signature:' "$IR_BAD_PATH"; then
  # Old/bad file (e.g., path-string content) => regenerate
  needs_regen=1
elif ! grep -q '^root:' "$IR_BAD_PATH"; then
  needs_regen=1
fi

if [[ "$needs_regen" -eq 1 ]]; then
  # Write an actual IR file at a stable path (not just a printed path string).
  "$PY" ./src/ir_tool.py new \
    --root /tmp \
    --actions delete \
    --note "intentional scope mismatch" \
    --out "$IR_BAD_PATH" >/dev/null
fi

# BEFORE (baseline): create once if missing
if [[ ! -f "$DEMO_SCOPE_BEFORE" ]]; then
  set +e
  eval "$INTENT_GATE --dry-run --print-decision --intent \"$IR_BAD_PATH\" -- rm foo.txt" 2>&1 \
    | sanitize \
    | tee "$DEMO_SCOPE_BEFORE" >/dev/null
  true
  set -e
fi

# AFTER: always regenerate
set +e
eval "$INTENT_GATE --dry-run --print-decision --intent \"$IR_BAD_PATH\" -- rm foo.txt" 2>&1 \
  | sanitize \
  | tee "$DEMO_SCOPE_AFTER" >/dev/null
true
set -e

# Optional legacy single-file artifact (keep your existing filename around)
cp "$DEMO_SCOPE_AFTER" "$DEMO_SCOPE"

# Diff for scope mismatch
diff -u \
  --label "$(basename "$DEMO_SCOPE_BEFORE")" "$DEMO_SCOPE_BEFORE" \
  --label "$(basename "$DEMO_SCOPE_AFTER")"  "$DEMO_SCOPE_AFTER" \
  > "$DEMO_SCOPE_DIFF" || true

# Assertions on scope-mismatch AFTER
assert_file_contains "DENY: scope.root mismatch" "$DEMO_SCOPE_AFTER"
assert_file_contains "Denial Context Snapshot" "$DEMO_SCOPE_AFTER"
assert_file_contains "Classification: SCOPE_MISMATCH" "$DEMO_SCOPE_AFTER"
assert_file_contains "did not influence the denial" "$DEMO_SCOPE_AFTER"

echo "OK: scope-mismatch before/after artifacts + diff regenerated and assertions passed"
