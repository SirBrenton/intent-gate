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
pin_ir_expiry_far_future() {
  local ir="$1"
  "$PY" - "$ir" <<'PY'
import sys, re

p = sys.argv[1]
txt = open(p, "r", encoding="utf-8").read()

# If YAML front matter exists, ensure expires_utc is present and pinned.
if txt.lstrip().startswith("---"):
    lines = txt.splitlines(True)
    # find closing front matter ---
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        raise SystemExit("FATAL: IR front matter missing closing ---")

    fm = lines[:end+1]
    body = lines[end+1:]

    # replace if present
    replaced = False
    for i, line in enumerate(fm):
        if re.match(r'^\s*expires_utc\s*:', line):
            fm[i] = "expires_utc: 2099-01-01T00:00:00Z\n"
            replaced = True

    # insert if missing (place near top, after root if possible)
    if not replaced:
        insert_at = None
        for i, line in enumerate(fm):
            if re.match(r'^\s*root\s*:', line):
                insert_at = i + 1
                break
        if insert_at is None:
            insert_at = 1  # after leading ---
        fm.insert(insert_at, "expires_utc: 2099-01-01T00:00:00Z\n")

    open(p, "w", encoding="utf-8").write("".join(fm + body))
    raise SystemExit(0)

# Legacy markdown style: replace "expires:" line if present; otherwise append it.
lines = txt.splitlines(True)
out = []
found = False
for line in lines:
    if re.match(r'^\s*expires\s*:', line):
        out.append("expires: 2099-01-01T00:00:00Z\n")
        found = True
    else:
        out.append(line)
if not found:
    out.append("\nexpires: 2099-01-01T00:00:00Z\n")
open(p, "w", encoding="utf-8").write("".join(out))
PY
}

die() { echo "FATAL: $*" >&2; exit 2; }

escape_sed() { printf '%s' "$1" | sed -e 's/[\/&#]/\\&/g'; }
ROOT_ESC="$(escape_sed "$ROOT")"

run_gate() { "$PY" ./src/intent_gate.py "$@"; }
run_ir()   { "$PY" ./src/ir_tool.py "$@"; }

sanitize() {
  sed -E \
    -e 's/"ts_utc":[[:space:]]*"[^"]+"/"ts_utc": "REDACTED"/g' \
    -e 's#(/Users/)[^" ]+#\1REDACTED#g' \
    -e "s#${ROOT_ESC}#<REPO>#g" \
    -e 's#(/private)?/tmp#<TMP>#g' \
    -e 's#IR-[0-9]{8}-[0-9]{6}Z\.md#IR-REDACTED.md#g' \
    -e 's#intent_records/IR-[0-9]{8}-[0-9]{6}Z\.md#intent_records/IR-REDACTED.md#g'
}

assert_file_contains() {
  local needle="$1"
  local file="$2"
  grep -Fq "$needle" "$file" || die "Expected '$needle' in $file"
}

assert_file_not_contains() {
  local needle="$1"
  local file="$2"
  if grep -Fq "$needle" "$file"; then
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

pin_ir_expiry_far_future "$IR_DG"

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

# -----------------------------
# CASE 4: DENY_GLOB (*.key) (baseline + current + diff)
# -----------------------------

DEMO_DG_KEY_BEFORE="${DEMO_DG_KEY_BEFORE:-$DOCS/demo_deny_glob_key_before.txt}"
DEMO_DG_KEY_AFTER="${DEMO_DG_KEY_AFTER:-$DOCS/demo_deny_glob_key_after.txt}"
DEMO_DG_KEY_DIFF="${DEMO_DG_KEY_DIFF:-$DOCS/demo_deny_glob_key_diff.patch}"

# Create (or reuse) a stable *valid* IR scoped to the sandbox.
# This ensures the denial is due to deny_glob, not signature/root/expiry issues.
IR_DG_PATH="$TMPDIR_REPO/IR_DENY_GLOB.md"
run_ir new \
  --root "$SANDBOX" \
  --actions delete \
  --note "deny-glob (*.key) lock demo (sandbox-scoped delete)" \
  --out "$IR_DG_PATH" >/dev/null
pin_ir_expiry_far_future "$IR_DG_PATH"

needs_regen=0
if [[ ! -f "$IR_DG_PATH" ]]; then
  needs_regen=1
elif ! grep -q '^signature:' "$IR_DG_PATH"; then
  needs_regen=1
elif ! grep -q '^root:' "$IR_DG_PATH"; then
  needs_regen=1
fi

if [[ "$needs_regen" -eq 1 ]]; then
  run_ir new \
    --root "$SANDBOX" \
    --actions delete \
    --note "deny-glob lock demo (sandbox-scoped delete)" \
    --out "$IR_DG_PATH" >/dev/null
fi

pin_ir_expiry_far_future "$IR_DG_PATH"

# Prepare a protected file that should be blocked by deny_glob defaults
echo "secret" > "$SANDBOX/secret.key"

# BEFORE (baseline): create once if missing
if [[ ! -f "$DEMO_DG_KEY_BEFORE" ]]; then
  set +e
  run_gate --dry-run --print-decision --intent "$IR_DG_PATH" -- rm secret.key 2>&1 \
    | sanitize \
    | tee "$DEMO_DG_KEY_BEFORE" >/dev/null
  true
  set -e
fi

# AFTER: always regenerate
set +e
run_gate --dry-run --print-decision --intent "$IR_DG_PATH" -- rm secret.key 2>&1 \
  | sanitize \
  | tee "$DEMO_DG_KEY_AFTER" >/dev/null
true
set -e

# Diff (deterministic because both are sanitized)
diff -u \
  --label "$(basename "$DEMO_DG_KEY_BEFORE")" "$DEMO_DG_KEY_BEFORE" \
  --label "$(basename "$DEMO_DG_KEY_AFTER")"  "$DEMO_DG_KEY_AFTER" \
  > "$DEMO_DG_KEY_DIFF" || true

# Assertions on AFTER (stable invariants only)
assert_file_contains "DENY: argument 'secret.key' matches deny_glob" "$DEMO_DG_KEY_AFTER"
assert_file_contains "Denial Context Snapshot" "$DEMO_DG_KEY_AFTER"
assert_file_contains "Classification: DENY_GLOB_MATCH" "$DEMO_DG_KEY_AFTER"
assert_file_contains "did not influence the denial" "$DEMO_DG_KEY_AFTER"

echo "OK: deny-glob (*.key) lock before/after artifacts + diff regenerated and assertions passed"

# -----------------------------
# CASE 5: SYMLINK_ESCAPE (baseline + current + diff)
# -----------------------------

DEMO_SYM_BEFORE="${DEMO_SYM_BEFORE:-$DOCS/demo_symlink_escape_before.txt}"
DEMO_SYM_AFTER="${DEMO_SYM_AFTER:-$DOCS/demo_symlink_escape_after.txt}"
DEMO_SYM_DIFF="${DEMO_SYM_DIFF:-$DOCS/demo_symlink_escape_diff.patch}"

# Ensure sandbox is clean for this case (avoid zsh rm-star prompt by using explicit globs)
rm -rf -- "$SANDBOX"/* "$SANDBOX"/.??* 2>/dev/null || true
mkdir -p "$SANDBOX" "$TMPDIR_REPO"

# Deterministic victim path (NOT repo root) + symlink in sandbox that points outside sandbox
VICTIM_REL="$TMPDIR_REPO/victim_symlink_escape.txt"
VICTIM_ABS="$ROOT/$VICTIM_REL"

cleanup_case5() {
  rm -f "$VICTIM_ABS" 2>/dev/null || true
}
trap cleanup_case5 EXIT   # <-- MUST be set immediately after victim path is known

printf "TOP_SECRET\n" > "$VICTIM_ABS"
ln -sf "../$VICTIM_REL" "$SANDBOX/link_to_victim.txt"

# Stable valid IR that allows write-like mutation (so denial is due to symlink escape, not IR failures)
IR_SYM="$TMPDIR_REPO/IR_SYMLINK_ESCAPE.md"
run_ir new \
  --root "$SANDBOX" \
  --actions write_over_existing \
  --note "symlink escape test: truncate via sandbox symlink" \
  --out "$IR_SYM" >/dev/null
pin_ir_expiry_far_future "$IR_SYM"

# BEFORE (baseline): create once if missing
if [[ ! -f "$DEMO_SYM_BEFORE" ]]; then
  set +e
  run_gate --dry-run --print-decision --intent "$IR_SYM" -- truncate -s 0 link_to_victim.txt 2>&1 \
    | sanitize | tee "$DEMO_SYM_BEFORE" >/dev/null
  true
  set -e
fi

# AFTER: always regenerate
set +e
run_gate --dry-run --print-decision --intent "$IR_SYM" -- truncate -s 0 link_to_victim.txt 2>&1 \
  | sanitize | tee "$DEMO_SYM_AFTER" >/dev/null
true
set -e

# Diff (deterministic because both are sanitized)
diff -u \
  --label "$(basename "$DEMO_SYM_BEFORE")" "$DEMO_SYM_BEFORE" \
  --label "$(basename "$DEMO_SYM_AFTER")"  "$DEMO_SYM_AFTER" \
  > "$DEMO_SYM_DIFF" || true

# Assertions on AFTER
assert_file_contains "DENY:" "$DEMO_SYM_AFTER"
assert_file_contains "resolves outside sandbox" "$DEMO_SYM_AFTER"
assert_file_contains "Denial Context Snapshot" "$DEMO_SYM_AFTER"
assert_file_contains "Classification: SYMLINK_ESCAPE" "$DEMO_SYM_AFTER"
assert_file_contains "did not influence the denial" "$DEMO_SYM_AFTER"

# Safety proof: victim must remain unchanged (deny was dry-run)
victim_bytes="$(wc -c < "$VICTIM_ABS" | tr -d '[:space:]')"
if [[ "$victim_bytes" -ne 11 ]]; then
  die "Expected ${VICTIM_REL} to remain 11 bytes, got ${victim_bytes}"
fi

echo "OK: symlink-escape lock before/after artifacts + diff regenerated and assertions passed"