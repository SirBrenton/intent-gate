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
    argv: List[str] = [
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
    ap = argparse.ArgumentParser(prog="mini-agent", description="Minimal agent routed through intent-gate.")
    ap.add_argument("task", help='Task string, e.g. \'delete foo.txt\'')
    ap.add_argument("--intent", default=None, help="Path to Intent Record (required for mutating commands).")
    ap.add_argument("--execute", action="store_true", help="Actually execute (default is dry-run).")
    ap.add_argument("--gate", default="src/intent_gate.py", help="Path to intent_gate.py")
    ap.add_argument("--policy", default="policies/policy.yaml", help="Path to policy.yaml")
    ap.add_argument("--sandbox", default="sandbox", help="Sandbox root directory")
    ap.add_argument("--audit", default="audit.jsonl", help="Audit log path (JSONL)")

    args = ap.parse_args()

    plan = build_plan(args.task)

    print("PLAN:")
    for i, c in enumerate(plan, 1):
        print(f"  {i}. {' '.join(shlex.quote(x) for x in c)}")
    print()

    gate_path = Path(args.gate)
    policy_path = Path(args.policy)
    sandbox_root = Path(args.sandbox).expanduser().resolve()

    audit_path = Path(args.audit).expanduser()
    if not audit_path.is_absolute():
        audit_path = (Path.cwd() / audit_path).resolve()

    intent_path = Path(args.intent).expanduser().resolve() if args.intent else None

    rc_total = 0

    for cmd in plan:
        # 1) Always do a visible dry-run decision first (prints ALLOW/DENY)
        argv_decide = gate_argv(
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

        # 2) Execute for real (IMPORTANT: do NOT pass --print-decision or --dry-run,
        # or intent_gate.py will return before execution.)
        argv_exec = gate_argv(
            gate_path, policy_path, sandbox_root, audit_path, intent_path, cmd,
            dry_run=False,
            print_decision=False,
        )
        rc_exec = run(argv_exec)
        rc_total = rc_total or rc_exec

    return rc_total


if __name__ == "__main__":
    raise SystemExit(main())