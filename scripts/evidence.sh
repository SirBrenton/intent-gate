#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Paths (repo-relative)
# -----------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY="./.venv/bin/python"

SANDBOX="${SANDBOX:-sandbox}"
DOCS="${DOCS:-docs}"
TMPDIR_REPO="${TMPDIR_REPO:-tmp}"

# -----------------------------
# Evidence artifact paths
# -----------------------------
# CASE 1: Missing intent
DEMO_BEFORE="${DEMO_BEFORE:-$DOCS/demo_before_denial.txt}"
DEMO_AFTER="${DEMO_AFTER:-$DOCS/demo_after_denial.txt}"
DEMO_DIFF="${DEMO_DIFF:-$DOCS/demo_denial_diff.patch}"

# CASE 2: Scope mismatch
DEMO_SCOPE_BEFORE="${DEMO_SCOPE_BEFORE:-$DOCS/demo_scope_mismatch_before.txt}"
DEMO_SCOPE_AFTER="${DEMO_SCOPE_AFTER:-$DOCS/demo_scope_mismatch_after.txt}"
DEMO_SCOPE_DIFF="${DEMO_SCOPE_DIFF:-$DOCS/demo_scope_mismatch_diff.patch}"
DEMO_SCOPE="${DEMO_SCOPE:-$DOCS/demo_scope_mismatch.txt}" # compat single-file

# CASE 3: Deny-glob lock
DEMO_DG_BEFORE="${DEMO_DG_BEFORE:-$DOCS/demo_deny_glob_before.txt}"
DEMO_DG_AFTER="${DEMO_DG_AFTER:-$DOCS/demo_deny_glob_after.txt}"
DEMO_DG_DIFF="${DEMO_DG_DIFF:-$DOCS/demo_deny_glob_diff.patch}"
DEMO_DG="${DEMO_DG:-$DOCS/demo_deny_glob.txt}" # optional compat single-file (ok if you don't commit it)

AUDIT="${AUDIT:-audit.jsonl}"

# -----------------------------
# Helpers
# -----------------------------
die() { echo "FATAL: $*" >&2; exit 2; }

run_gate() { "$PY" ./src/intent_gate.py "$@"; }
run_ir()   { "$PY" ./src/ir_tool.py "$@"; }

sanitize() {
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
if [[ ! -f "$DEMO_BEFORE" ]]; then
  set +e
  run_gate --dry-run --print-decision -- rm foo.txt 2>&1 \
    | sanitize | tee "$DEMO_BEFORE" >/dev/null
  true
  set -e
fi

set +e
run_gate --dry-run --print-decision -- rm foo.txt 2>&1 \
  | sanitize | tee "$DEMO_AFTER" >/dev/null
true
set -e

diff -u \
  --label "$(basename "$DEMO_BEFORE")" "$DEMO_BEFORE" \
  --label "$(basename "$DEMO_AFTER")"  "$DEMO_AFTER" \
  > "$DEMO_DIFF" || true

assert_file_contains "Denial Context Snapshot" "$DEMO_AFTER"
assert_file_contains "did not influence the denial" "$DEMO_AFTER"
assert_file_not_contains "DENY: DENY:" "$DEMO_AFTER"

echo "OK: denial before/after artifacts + diff regenerated and assertions passed"

# -----------------------------
# CASE 2: SCOPE_MISMATCH (baseline + current + diff)
# -----------------------------
IR_BAD_PATH="$TMPDIR_REPO/IR_SCOPE_MISMATCH.md"

needs_regen=0
if [[ ! -f "$IR_BAD_PATH" ]]; then
  needs_regen=1
elif ! grep -q '^signature:' "$IR_BAD_PATH"; then
  needs_regen=1
elif ! grep -q '^root:' "$IR_BAD_PATH"; then
  needs_regen=1
fi

if [[ "$needs_regen" -eq 1 ]]; then
  run_ir new \
    --root /tmp \
    --actions delete \
    --note "intentional scope mismatch" \
    --out "$IR_BAD_PATH" >/dev/null
fi

if [[ ! -f "$DEMO_SCOPE_BEFORE" ]]; then
  set +e
  run_gate --dry-run --print-decision --intent "$IR_BAD_PATH" -- rm foo.txt 2>&1 \
    | sanitize | tee "$DEMO_SCOPE_BEFORE" >/dev/null
  true
  set -e
fi

set +e
run_gate --dry-run --print-decision --intent "$IR_BAD_PATH" -- rm foo.txt 2>&1 \
  | sanitize | tee "$DEMO_SCOPE_AFTER" >/dev/null
true
set -e

cp "$DEMO_SCOPE_AFTER" "$DEMO_SCOPE"

diff -u \
  --label "$(basename "$DEMO_SCOPE_BEFORE")" "$DEMO_SCOPE_BEFORE" \
  --label "$(basename "$DEMO_SCOPE_AFTER")"  "$DEMO_SCOPE_AFTER" \
  > "$DEMO_SCOPE_DIFF" || true

assert_file_contains "DENY: scope.root mismatch" "$DEMO_SCOPE_AFTER"
assert_file_contains "Denial Context Snapshot" "$DEMO_SCOPE_AFTER"
assert_file_contains "Classification: SCOPE_MISMATCH" "$DEMO_SCOPE_AFTER"
assert_file_contains "did not influence the denial" "$DEMO_SCOPE_AFTER"

echo "OK: scope-mismatch before/after artifacts + diff regenerated and assertions passed"

# -----------------------------
# CASE 3: DENY_GLOB_LOCK (baseline + current + diff)
# -----------------------------
rm -f "$SANDBOX/secret.pem"
echo "secret" > "$SANDBOX/secret.pem"

IR_DG="$TMPDIR_REPO/IR_DENY_GLOB_LOCK.md"
run_ir new \
  --root "$SANDBOX" \
  --actions delete \
  --note "test deny-glob lock" \
  --out "$IR_DG" >/dev/null

if [[ ! -f "$DEMO_DG_BEFORE" ]]; then
  set +e
  run_gate --dry-run --print-decision --intent "$IR_DG" -- rm secret.pem 2>&1 \
    | sanitize | tee "$DEMO_DG_BEFORE" >/dev/null
  true
  set -e
fi

set +e
run_gate --dry-run --print-decision --intent "$IR_DG" -- rm secret.pem 2>&1 \
  | sanitize | tee "$DEMO_DG_AFTER" >/dev/null
true
set -e

# Optional compat file (harmless; you can choose to not commit it)
cp "$DEMO_DG_AFTER" "$DEMO_DG" 2>/dev/null || true

diff -u \
  --label "$(basename "$DEMO_DG_BEFORE")" "$DEMO_DG_BEFORE" \
  --label "$(basename "$DEMO_DG_AFTER")"  "$DEMO_DG_AFTER" \
  > "$DEMO_DG_DIFF" || true

assert_file_contains "DENY: argument 'secret.pem' matches deny_glob" "$DEMO_DG_AFTER"
assert_file_contains "Denial Context Snapshot" "$DEMO_DG_AFTER"

echo "OK: deny-glob lock before/after artifacts + diff regenerated and assertions passed"