#!/usr/bin/env python3
"""
mini_agent.py

A deliberately tiny "agent" that turns a simple task into filesystem commands,
then routes them through intent-gate.

This is NOT an LLM. It's a deterministic task->command mapper.
Purpose: demonstrate the workflow where autonomy is constrained by explicit intent.
"""

from __future__ import annotations

import argparse
import shlex
import subprocess
import sys
from pathlib import Path
from typing import List, Optional


def repo_root_from_file() -> Path:
    # src/mini_agent.py -> repo root
    return Path(__file__).resolve().parent.parent


def build_plan(task: str) -> List[List[str]]:
    """
    Supported tasks (v0):
      - delete <path>
      - rename <src> <dst>
      - copy <src> <dst>
    """
    toks = shlex.split(task)
    if not toks:
        raise ValueError("Empty task.")

    op = toks[0].lower()

    if op == "delete" and len(toks) == 2:
        return [["rm", toks[1]]]

    if op == "rename" and len(toks) == 3:
        return [["mv", toks[1], toks[2]]]

    if op == "copy" and len(toks) == 3:
        return [["cp", toks[1], toks[2]]]

    raise ValueError(
        "Unsupported task. Try:\n"
        "  delete <path>\n"
        "  rename <src> <dst>\n"
        "  copy <src> <dst>\n"
    )


def gate_argv(
    py: str,
    gate_path: Path,
    policy_path: Path,
    sandbox_root: Path,
    audit_path: Path,
    intent_path: Optional[Path],
    cmd: List[str],
    *,
    dry_run: bool,
    print_decision: bool,
) -> List[str]:
    # CRITICAL: run gate via the SAME interpreter as mini_agent (venv-safe)
    argv: List[str] = [
        py,
        str(gate_path),
        "--policy", str(policy_path),
        "--sandbox", str(sandbox_root),
        "--audit", str(audit_path),
    ]

    if intent_path is not None:
        argv += ["--intent", str(intent_path)]

    if dry_run:
        argv += ["--dry-run"]

    if print_decision:
        argv += ["--print-decision"]

    argv += ["--", *cmd]
    return argv


def run(argv: List[str]) -> int:
    p = subprocess.run(argv, text=True)
    return p.returncode


def main() -> int:
    repo_root = repo_root_from_file()

    ap = argparse.ArgumentParser(
        prog="mini-agent",
        description="Minimal agent routed through intent-gate.",
    )
    ap.add_argument("task", help="Task string, e.g. 'delete foo.txt'")
    ap.add_argument("--intent", default=None, help="Path to Intent Record (required for mutating commands).")
    ap.add_argument("--execute", action="store_true", help="Actually execute (default is dry-run).")

    # Defaults are repo-root relative and stable regardless of current directory.
    ap.add_argument("--gate", default=str(repo_root / "src" / "intent_gate.py"), help="Path to intent_gate.py")
    ap.add_argument("--policy", default=str(repo_root / "policies" / "policy.yaml"), help="Path to policy.yaml")
    ap.add_argument("--sandbox", default=str(repo_root / "sandbox"), help="Sandbox root directory")
    ap.add_argument("--audit", default=str(repo_root / "audit.jsonl"), help="Audit log path (JSONL)")

    args = ap.parse_args()

    plan = build_plan(args.task)

    print("PLAN:")
    for i, c in enumerate(plan, 1):
        print(f"  {i}. {' '.join(shlex.quote(x) for x in c)}")
    print()

    py = sys.executable  # <-- the interpreter that launched THIS mini_agent.py

    gate_path = Path(args.gate).expanduser().resolve()
    policy_path = Path(args.policy).expanduser().resolve()
    sandbox_root = Path(args.sandbox).expanduser().resolve()

    audit_path = Path(args.audit).expanduser()
    if not audit_path.is_absolute():
        audit_path = (Path.cwd() / audit_path).resolve()

    intent_path = Path(args.intent).expanduser().resolve() if args.intent else None

    rc_total = 0

    for cmd in plan:
        # 1) Always do a visible dry-run decision first (prints ALLOW/DENY)
        argv_decide = gate_argv(
            py,
            gate_path, policy_path, sandbox_root, audit_path, intent_path, cmd,
            dry_run=True,
            print_decision=True,
        )
        rc_decide = run(argv_decide)
        rc_total = rc_total or rc_decide

        # If we're not executing, stop here.
        if not args.execute:
            continue

        # If the decision denied, do NOT execute.
        if rc_decide != 0:
            continue

        # 2) Execute for real (IMPORTANT: no --print-decision, no --dry-run)
        argv_exec = gate_argv(
            py,
            gate_path, policy_path, sandbox_root, audit_path, intent_path, cmd,
            dry_run=False,
            print_decision=False,
        )
        rc_exec = run(argv_exec)
        rc_total = rc_total or rc_exec

    return rc_total


if __name__ == "__main__":
    raise SystemExit(main())