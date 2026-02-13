#!/usr/bin/env bash
set -euo pipefail

# Wrong-root demo:
# - Baseline: wrong cwd + absolute-expanded targets can delete the wrong thing
# - With intent-gate: a wrong-root "escape" attempt is deterministically DENIED (no damage)
# - Control: correct relative delete inside sandbox is ALLOWED (dry-run)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PY="${REPO_ROOT}/.venv/bin/python"
POLICY="${REPO_ROOT}/policies/policy.yaml"

if [[ ! -x "$PY" ]]; then
  echo "ERROR: missing venv python at $PY"
  echo "Run: ./makew venv && ./makew deps"
  exit 1
fi

if [[ ! -f "$POLICY" ]]; then
  echo "ERROR: missing policy at $POLICY"
  exit 1
fi

WORK="$(mktemp -d /tmp/intent-gate-wrong-root.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

SANDBOX="$WORK/sandbox"
WRONGROOT="$WORK/wrongroot"

mkdir -p "$SANDBOX/build" "$WRONGROOT/build"

echo "artifact" > "$SANDBOX/build/artifact.txt"
echo "DO_NOT_DELETE" > "$WRONGROOT/build/important.txt"

echo
echo "== Setup =="
echo "WORK=$WORK"
echo "SANDBOX=$SANDBOX"
echo "WRONGROOT=$WRONGROOT"
echo "WRONGROOT build contains: $WRONGROOT/build/important.txt"

echo
echo "== Create an Intent Record authorizing delete ONLY within the sandbox =="
IR="$("$PY" "$REPO_ROOT/src/ir_tool.py" new \
  --root "$SANDBOX" \
  --actions delete \
  --note "wrong-root demo: allow delete only inside sandbox")"
echo "IR=$IR"

# Reusable gate invocation (safe now that IR exists)
GATE=( "$PY" "$REPO_ROOT/src/intent_gate.py"
  --policy "$POLICY"
  --sandbox "$SANDBOX"
  --dry-run
  --print-decision
  --intent "$IR"
  --
)

echo
echo "== Baseline (no gate): wrong-root cleanup can delete the wrong thing =="
echo "(Simulates an agent forming absolute targets from the wrong cwd.)"
(
  cd "$WRONGROOT"
  echo "Running: rm -rf \"$PWD\"/build/*"
  rm -rf "$PWD"/build/*
)

if [[ -e "$WRONGROOT/build/important.txt" ]]; then
  echo "UNEXPECTED: important.txt still exists (baseline failure did not reproduce)"
  exit 2
else
  echo "OK: baseline shows damage — wrong-root build/important.txt is deleted"
fi

# Restore for gated cases
mkdir -p "$WRONGROOT/build"
echo "DO_NOT_DELETE" > "$WRONGROOT/build/important.txt"

echo
echo "== With intent-gate: wrong-root escape attempt is DENIED (no damage) =="
echo "(Run from inside the sandbox, but try to delete outside it via relative path escape.)"
WR_OUT="$WORK/gate_wrong_root.out"
(
  cd "$SANDBOX"
  set +e
  echo "Running (should DENY): rm -rf ../wrongroot/build/*"
  "${GATE[@]}" rm -rf ../wrongroot/build/* 2>&1 | tee "$WR_OUT"
  rc=${PIPESTATUS[0]}
  set -e
  echo "gate exitcode=$rc (expected non-zero due to DENY)"
)

# Validate we denied (avoid over-specific grep that can break if wording changes)
grep -Eqi '(^DENY:| DENY:|deny|escapes sandbox|outside the sandbox)' "$WR_OUT" || {
  echo "ERROR: expected DENY output not found"
  echo "---- output ----"
  sed -n '1,200p' "$WR_OUT"
  exit 4
}

# Most important invariant: protected file remains
if [[ -e "$WRONGROOT/build/important.txt" ]]; then
  echo "OK: protected file still exists after gate DENY"
else
  echo "ERROR: protected file was deleted even though gate should have denied"
  exit 3
fi

echo
echo "== Control: correct-root deletion INSIDE sandbox should be allowed (dry-run) =="
CTRL_OUT="$WORK/gate_control.out"
(
  cd "$SANDBOX"
  echo "Running (should ALLOW): rm -rf build/*"
  "${GATE[@]}" rm -rf build/* 2>&1 | tee "$CTRL_OUT"
)

grep -q "^ALLOW:" "$CTRL_OUT" || {
  echo "ERROR: expected ALLOW in control run (dry-run)"
  echo "---- output ----"
  sed -n '1,200p' "$CTRL_OUT"
  exit 5
}

echo "OK: control shows ALLOW for relative paths within sandbox"

echo
echo "== Done =="
echo "This demonstrates:"
echo "  - baseline wrong-root absolute targets => damage"
echo "  - gated relative escape (../wrongroot/...) => DENY + no damage"
echo "  - gated in-sandbox relative (build/*) => ALLOW (dry-run)"
