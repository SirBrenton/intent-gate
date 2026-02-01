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

DEMO_BEFORE="${DEMO_BEFORE:-$DOCS/demo_before_denial.txt}"
DEMO_AFTER="${DEMO_AFTER:-$DOCS/demo_after_denial.txt}"
DEMO_DIFF="${DEMO_DIFF:-$DOCS/demo_denial_diff.patch}"
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

mkdir -p "$DOCS" "$SANDBOX"

rm -f "$AUDIT"
echo "hello" > "$SANDBOX/foo.txt"

# -----------------------------
# BEFORE (baseline): keep committed artifact unless missing
# -----------------------------
if [[ ! -f "$DEMO_BEFORE" ]]; then
  # If someone runs this on a fresh clone, we create the baseline once.
  # It's "historical" by convention; subsequent runs won't overwrite it.
  set +e
  eval "$INTENT_GATE --dry-run --print-decision -- rm foo.txt" 2>&1 \
    | sanitize \
    | tee "$DEMO_BEFORE" >/dev/null
  true
  set -e
fi

# -----------------------------
# AFTER: always regenerate
# -----------------------------
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
# SCOPE_MISMATCH artifact (always regenerate)
# -----------------------------
# NOTE: /tmp becomes /private/tmp on macOS in many contexts; we sanitize both.
IR_BAD="$($IR_TOOL new --root /tmp --actions delete --note "intentional scope mismatch")"

set +e
eval "$INTENT_GATE --dry-run --print-decision --intent \"$IR_BAD\" -- rm foo.txt" 2>&1 \
  | sanitize \
  | tee "$DEMO_SCOPE" >/dev/null
true
set -e

assert_file_contains "DENY: scope.root mismatch" "$DEMO_SCOPE"
assert_file_contains "Denial Context Snapshot" "$DEMO_SCOPE"
assert_file_contains "Classification: SCOPE_MISMATCH" "$DEMO_SCOPE"
assert_file_contains "did not influence the denial" "$DEMO_SCOPE"

echo "OK: scope-mismatch artifact regenerated and assertions passed"
