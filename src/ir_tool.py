#!/usr/bin/env python3
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional

ACTIONS = [
    "write_file",
    "delete",
    "move_or_rename",
    "chmod",
    "git_commit",
]


def _utc_now_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%SZ")


def _default_ir_path(intent_records_dir: Path) -> Path:
    stamp = _utc_now_stamp()
    return intent_records_dir / f"IR-{stamp}.md"


def _normalize_root(root: Path) -> Path:
    return root.expanduser().resolve()


def render_ir(root: Path, actions: List[str], note: str = "", expires_hours: Optional[int] = None) -> str:
    stamp = _utc_now_stamp()
    expires = ""
    if expires_hours is not None:
        exp = datetime.now(timezone.utc).timestamp() + (expires_hours * 3600)
        expires_dt = datetime.fromtimestamp(exp, tz=timezone.utc)
        expires = expires_dt.strftime("%Y-%m-%dT%H:%M:%SZ")

    # Minimal, deterministic template. YAML front-matter is easiest to parse.
    lines = []
    lines.append("---")
    lines.append(f"id: IR-{stamp}")
    lines.append(f"created_utc: {stamp}")
    if expires:
        lines.append(f"expires_utc: {expires}")
    lines.append("actor:")
    lines.append("  name: Brent Williams")
    lines.append("  role: human_operator")
    lines.append("scope:")
    lines.append(f"  root: {str(root)}")
    lines.append("actions_allowed:")
    for a in actions:
        lines.append(f"  - {a}")
    lines.append("approval:")
    lines.append("  required: false")
    lines.append("  approver: null")
    lines.append("  approved_utc: null")
    lines.append("---")
    lines.append("")
    lines.append("# Intent")
    lines.append(note.strip() if note.strip() else "(fill in: what outcome are you authorizing?)")
    lines.append("")
    lines.append("# Notes")
    lines.append("- (optional) what could go wrong?")
    lines.append("- (optional) rollback plan?")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(prog="ir", description="Intent Record helper.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    newp = sub.add_parser("new", help="Create a new Intent Record file.")
    newp.add_argument("--root", default="sandbox", help="Scope root (default: sandbox).")
    newp.add_argument("--actions", nargs="+", required=True, help=f"Allowed actions. Options: {', '.join(ACTIONS)}")
    newp.add_argument("--note", default="", help="Short intent note.")
    newp.add_argument("--expires-hours", type=int, default=24, help="Expiry window in hours (default: 24).")
    newp.add_argument("--dir", default="intent_records", help="Intent records directory (default: intent_records).")
    newp.add_argument("--print", action="store_true", help="Print IR content to stdout instead of writing file.")

    args = ap.parse_args()
    root = _normalize_root(Path(args.root))
    ir_dir = Path(args.dir).expanduser().resolve()
    ir_dir.mkdir(parents=True, exist_ok=True)

    unknown = [a for a in args.actions if a not in ACTIONS]
    if unknown:
        print(f"ERROR: unknown actions: {unknown}")
        print(f"Valid actions: {ACTIONS}")
        return 2

    content = render_ir(root=root, actions=args.actions, note=args.note, expires_hours=args.expires_hours)

    if args.print:
        print(content)
        return 0

    out_path = _default_ir_path(ir_dir)
    out_path.write_text(content, encoding="utf-8")
    print(str(out_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
