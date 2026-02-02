#!/usr/bin/env python3
from __future__ import annotations

import argparse
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import List, Optional

# These are *gate action-classes*, not OS verbs.
# Keep these aligned with src/intent_gate.py and tests/test_intent_gate.py::write_ir().
ACTIONS = [
    "delete",
    "write_over_existing",
    "move_or_rename",
    "copy",
    "chmod",
    "git_commit",
]

DEFAULT_DENY_GLOBS = ["**/.git/**", "**/*.key", "**/*.pem"]
DEFAULT_MAX_FILES = 20


def _utc_now_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%SZ")


def _default_ir_path(intent_records_dir: Path) -> Path:
    stamp = _utc_now_stamp()
    return intent_records_dir / f"IR-{stamp}.md"


def _normalize_root(root: Path) -> Path:
    return root.expanduser().resolve()


def _expires_str(expires_hours: int) -> str:
    exp_dt = datetime.now(timezone.utc) + timedelta(hours=expires_hours)
    return exp_dt.isoformat(timespec="seconds").replace("+00:00", "Z")


def render_ir(
    root: Path,
    actions: List[str],
    note: str = "",
    expires_hours: Optional[int] = 24,
    max_files: int = DEFAULT_MAX_FILES,
    deny_globs: Optional[List[str]] = None,
    signer_name: str = "Brent Williams",
) -> str:
    deny_globs = deny_globs or DEFAULT_DENY_GLOBS
    expires = _expires_str(expires_hours if expires_hours is not None else 24)

    intent_line = note.strip() if note.strip() else "(fill in: what outcome are you authorizing?)"

    # Canonical markdown IR (matches tests/test_intent_gate.py::write_ir()).
    lines: List[str] = []
    lines.append("# Intent Record")
    lines.append("")
    lines.append("## Human")
    lines.append(f"name: {signer_name}")
    lines.append("attestation: I authorize the destructive actions below within the defined scope.")
    lines.append("")
    lines.append("## Scope")
    lines.append(f"root: {str(root)}")
    lines.append(f"expires: {expires}")
    lines.append("")
    lines.append("## Allowed action classes")
    for a in actions:
        lines.append(f"- {a}")
    lines.append("")
    lines.append("## Constraints")
    lines.append(f"- max_files: {max_files}")
    for g in deny_globs:
        lines.append(f"- {g}")
    lines.append("")
    lines.append("## Intent")
    lines.append(intent_line)
    lines.append("")
    lines.append("## Notes")
    lines.append("- (optional) what could go wrong?")
    lines.append("- (optional) rollback plan?")
    lines.append("")
    lines.append("## Signature")
    lines.append("method: local-typed")
    lines.append(f"signature: {signer_name}")
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
    newp.add_argument("--max-files", type=int, default=DEFAULT_MAX_FILES, help="Max files affected (default: 20).")
    newp.add_argument("--deny-glob", action="append", default=None, help="Add deny glob (repeatable).")
    newp.add_argument("--dir", default="intent_records", help="Intent records directory (default: intent_records).")
    newp.add_argument("--print", action="store_true", help="Print IR content to stdout instead of writing file.")
    newp.add_argument("--out", default=None, help="Write IR to this exact path (overwrites).")


    args = ap.parse_args()
    root = _normalize_root(Path(args.root))
    ir_dir = Path(args.dir).expanduser().resolve()
    ir_dir.mkdir(parents=True, exist_ok=True)

    unknown = [a for a in args.actions if a not in ACTIONS]
    if unknown:
        print(f"ERROR: unknown actions: {unknown}")
        print(f"Valid actions: {ACTIONS}")
        return 2

    content = render_ir(
        root=root,
        actions=args.actions,
        note=args.note,
        expires_hours=args.expires_hours,
        max_files=args.max_files,
        deny_globs=args.deny_glob,
    )

    if args.print:
        print(content)
        return 0

    if args.out:
        out_path = Path(args.out).expanduser().resolve()
        out_path.parent.mkdir(parents=True, exist_ok=True)
    else:
        out_path = _default_ir_path(ir_dir)

    out_path.write_text(content, encoding="utf-8")
    print(str(out_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())