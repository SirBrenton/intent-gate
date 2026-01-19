#!/usr/bin/env python3
"""
intent-gate (V1)

A minimal "refusal boundary" for agentic execution:
- Default deny for unknown commands.
- Allowlist for read-only commands.
- Require a signed Intent Record for destructive/mutating commands.
- Enforce scope root, expiry, deny_globs, max_files.
- Forbid absolute paths and "double-sandbox" path mistakes.

This is not a sandbox. It's an execution gate + audit trail.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import yaml
from dateutil import parser as dtparser


# -----------------------------
# Models
# -----------------------------

@dataclass
class GateDecision:
    allowed: bool
    reason: str
    normalized_command: str
    files_touched: int = 0


# -----------------------------
# Helpers
# -----------------------------

def _iso_utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _append_audit(audit_path: Path, event: Dict[str, Any]) -> None:
    """
    Append a single JSON event to audit log (JSONL).
    Best-effort: never block the command flow if logging fails.
    """
    try:
        audit_path.parent.mkdir(parents=True, exist_ok=True)
        payload = dict(event)
        payload.setdefault("ts_utc", _iso_utc_now())
        with audit_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(payload, sort_keys=True) + "\n")
    except Exception:
        # Best-effort: do not fail closed on audit write in v1.
        pass


def _load_yaml(path: Path) -> Dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(f"Missing file: {path}")
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def _parse_intent_record_md(path: Path) -> Dict[str, Any]:
    """
    Parse an Intent Record.

    Supports BOTH:
      A) YAML front-matter IR (preferred, emitted by ir_tool.py)
      B) Legacy markdown-heading IR (used in older tests)

    Normalized output shape (what decide() expects):
      {
        "scope": {"root": str, "expires": str},
        "constraints": {"max_files": int|None, "deny_globs": [..]},
        "allowed_action_classes": [..],
        "signature": str,
        "raw_text": str,
      }
    """
    if not path.exists():
        raise FileNotFoundError(f"Missing intent record: {path}")
    text = path.read_text(encoding="utf-8")

    # ---- A) YAML front-matter path ----
    if text.lstrip().startswith("---"):
        lines = text.splitlines()
        if lines and lines[0].strip() == "---":
            end_idx = None
            for i in range(1, len(lines)):
                if lines[i].strip() == "---":
                    end_idx = i
                    break
            if end_idx is None:
                raise ValueError("Intent Record YAML front matter is missing closing '---'")

            fm_text = "\n".join(lines[1:end_idx])
            fm = yaml.safe_load(fm_text) or {}

            scope = fm.get("scope") or {}
            constraints = fm.get("constraints") or {}

            def _as_str(x: Any) -> str:
                # yaml.safe_load may return non-strings (e.g., datetime); normalize safely.
                if x is None:
                    return ""
                return str(x).strip()

            root = _as_str(scope.get("root") or fm.get("root"))
            expires = _as_str(fm.get("expires_utc") or scope.get("expires") or fm.get("expires"))

            actions = fm.get("actions_allowed")
            if actions is None:
                actions = fm.get("actions")
            if actions is None:
                actions = []
            if isinstance(actions, str):
                actions = [actions]

            signature = _as_str(fm.get("signature")).strip('"').strip("'")

            deny_globs = constraints.get("deny_globs") or fm.get("deny_globs") or []
            if isinstance(deny_globs, str):
                deny_globs = [deny_globs]

            max_files = constraints.get("max_files")
            if max_files is None:
                max_files = fm.get("max_files")

            try:
                max_files = int(max_files) if max_files is not None else None
            except Exception:
                max_files = None

            return {
                "scope": {"root": root, "expires": expires},
                "constraints": {"max_files": max_files, "deny_globs": list(deny_globs)},
                "allowed_action_classes": list(actions),
                "signature": signature,
                "raw_text": text,
            }

    # ---- B) Legacy markdown-heading path ----
    def find_line(prefix: str) -> Optional[str]:
        for line in text.splitlines():
            if line.strip().startswith(prefix):
                return line.split(":", 1)[1].strip()
        return None

    def find_list_after(header: str) -> List[str]:
        lines = text.splitlines()
        out: List[str] = [] 
        in_block = False
        for line in lines:
            if re.match(rf"^\s*##\s+{re.escape(header)}\s*$", line):
                in_block = True
                continue
            if in_block:
                if line.strip().startswith("## "):
                    break
                m = re.match(r"^\s*-\s+(.*)\s*$", line)
                if m:
                    out.append(m.group(1).strip())
        return out

    root = find_line("root")
    expires = find_line("expires")
    max_files = find_line("max_files")
    signature = find_line("signature")

    deny_globs = find_list_after("Constraints")
    deny_globs = [g for g in deny_globs if "*" in g or "?" in g or "/" in g or "." in g]

    allowed_actions = find_list_after("Allowed action classes")

    return {
        "scope": {"root": root, "expires": expires},
        "constraints": {"max_files": int(max_files) if max_files else None, "deny_globs": deny_globs},
        "allowed_action_classes": allowed_actions,
        "signature": signature,
        "raw_text": text,
    }


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _parse_dt(dt_str: str) -> datetime:
    dt = dtparser.parse(dt_str)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _match_any_glob(path_str: str, globs: List[str]) -> bool:
    s = path_str.replace("\\", "/")
    for g in globs:
        gg = g.replace("\\", "/")
        if fnmatch.fnmatch(s, gg):
            return True
    return False


def _classify_command(cmd0: str, policy: Dict[str, Any]) -> str:
    ro = set(policy.get("read_only_commands", []) or [])
    mut = set(policy.get("requires_intent_commands", []) or [])
    if cmd0 in ro:
        return "read_only"
    if cmd0 in mut:
        return "mutating"
    return "unknown"


def _estimate_files_touched(cmd: List[str], cwd: Path) -> int:
    touched = 0
    for a in cmd[1:]:
        if a.startswith("-"):
            continue
        p = (cwd / a).resolve()
        try:
            if p.exists():
                touched += 10 if p.is_dir() else 1
        except Exception:
            return 9999
    return touched


# -----------------------------
# Core gate logic
# -----------------------------

def decide(
    cmd: List[str],
    policy: Dict[str, Any],
    intent: Optional[Dict[str, Any]],
    sandbox_root: Path,
) -> GateDecision:
    if not cmd:
        return GateDecision(False, "No command provided.", "")

    cmd0 = cmd[0]
    normalized = " ".join(shlex.quote(x) for x in cmd)
    action_class = _classify_command(cmd0, policy)

    deny_default = policy.get("deny_globs_default", []) or []
    max_files_default = policy.get("max_files_default", 50)

    # 1) Unknown -> deny
    if action_class == "unknown":
        return GateDecision(False, f"DENY: unknown command '{cmd0}' (default deny).", normalized)

    # 2) Read-only -> allow (classification already enforced policy membership)
    if action_class == "read_only":
        return GateDecision(True, "ALLOW: read-only command permitted by policy.", normalized)

    # 3) Mutating -> requires IR + validations
    if action_class == "mutating":
        touched = _estimate_files_touched(cmd, sandbox_root)

        if intent is None:
            return GateDecision(
                False,
                f"DENY: '{cmd0}' requires an Intent Record.",
                normalized,
                files_touched=touched,
            )

        dangerous = {".", "..", "/", "~"}
        for a in cmd[1:]:
            if a.startswith("-"):
                continue
            if a in dangerous:
                return GateDecision(
                    False,
                    f"DENY: dangerous target '{a}' not allowed.",
                    normalized,
                    files_touched=touched,
                )

        for a in cmd[1:]:
            if a.startswith("-"):
                continue
            if os.path.isabs(a):
                return GateDecision(
                    False,
                    "DENY: absolute paths are not allowed (must be relative to sandbox root).",
                    normalized,
                    files_touched=touched,
                )
            if a.replace("\\", "/").startswith("sandbox/"):
                return GateDecision(
                    False,
                    "DENY: do not prefix paths with 'sandbox/' (cwd is already sandbox root). Use relative paths.",
                    normalized,
                    files_touched=touched,
                )

        sig = (intent.get("signature") or "").strip()
        if not sig:
            return GateDecision(False, "DENY: Intent Record missing signature.", normalized, files_touched=touched)

        scope = intent.get("scope") or {}
        root = (scope.get("root") or "").strip()
        expires = (scope.get("expires") or "").strip()
        if not root or not expires:
            return GateDecision(
                False,
                "DENY: Intent Record missing scope.root or scope.expires.",
                normalized,
                files_touched=touched,
            )

        try:
            ir_root = Path(root).expanduser().resolve()
        except Exception:
            return GateDecision(False, "DENY: Intent Record scope.root is invalid.", normalized, files_touched=touched)

        if ir_root != sandbox_root.resolve():
            return GateDecision(
                False,
                f"DENY: scope.root mismatch (IR={ir_root} != sandbox={sandbox_root.resolve()}).",
                normalized,
                files_touched=touched,
            )

        try:
            exp = _parse_dt(expires)
        except Exception:
            return GateDecision(
                False,
                "DENY: Intent Record expires is not parseable datetime.",
                normalized,
                files_touched=touched,
            )

        if _now_utc() > exp:
            return GateDecision(False, "DENY: Intent Record is expired.", normalized, files_touched=touched)

        allowed_classes = set(intent.get("allowed_action_classes") or [])
        cmd_to_needed = {
            "rm": "delete",
            "mv": "move_or_rename",
            "cp": "copy",
            "sed": "write_over_existing",
            "truncate": "write_over_existing",
        }
        needed = cmd_to_needed.get(cmd0, "mutate")
        if needed not in allowed_classes:
            return GateDecision(
                False,
                f"DENY: Intent Record does not allow action '{needed}'.",
                normalized,
                files_touched=touched,
            )

        deny_globs = set(deny_default)
        deny_globs.update(intent.get("constraints", {}).get("deny_globs") or [])
        deny_globs_list = sorted(deny_globs)

        max_files = intent.get("constraints", {}).get("max_files") or max_files_default
        try:
            max_files = int(max_files)
        except Exception:
            max_files = max_files_default

        if touched > max_files:
            return GateDecision(
                False,
                f"DENY: command touches too many files (est={touched} > max={max_files}).",
                normalized,
                files_touched=touched,
            )

        for a in cmd[1:]:
            if a.startswith("-"):
                continue
            p = (sandbox_root / a).resolve()
            try:
                rel = p.relative_to(sandbox_root.resolve()).as_posix()
            except Exception:
                rel = p.as_posix()
            if _match_any_glob(rel, deny_globs_list):
                return GateDecision(
                    False,
                    f"DENY: argument '{a}' matches deny_glob.",
                    normalized,
                    files_touched=touched,
                )

        return GateDecision(True, "ALLOW: Intent Record validated for mutating command.", normalized, files_touched=touched)

    # Defensive fallback (should be unreachable)
    return GateDecision(False, f"DENY: command '{cmd0}' not allowed by policy.", normalized)


def run_command(cmd: List[str], cwd: Path) -> Tuple[int, str, str]:
    p = subprocess.run(cmd, cwd=str(cwd), capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


# -----------------------------
# CLI
# -----------------------------

def main() -> int:
    ap = argparse.ArgumentParser(prog="intent-gate", description="Deterministic refusal boundary for agent execution.")
    ap.add_argument("--policy", default="policies/policy.yaml", help="Path to policy YAML.")
    ap.add_argument("--intent", default=None, help="Path to Intent Record (markdown). Required for mutating commands.")
    ap.add_argument("--sandbox", default="sandbox", help="Sandbox root (must match IR scope.root).")
    ap.add_argument("--audit", default="audit.jsonl", help="Append-only audit log (JSONL).")
    ap.add_argument("--dry-run", action="store_true", help="Decide but do not execute.")
    ap.add_argument("--print-decision", action="store_true", help="Print decision and exit.")
    ap.add_argument("command", nargs=argparse.REMAINDER, help="Command to run (e.g., -- ls -la).")

    args = ap.parse_args()

    policy_path = Path(args.policy)
    sandbox_root = Path(args.sandbox).expanduser().resolve()

    audit_path = Path(args.audit).expanduser()
    if not audit_path.is_absolute():
        audit_path = (Path.cwd() / audit_path).resolve()

    policy = _load_yaml(policy_path)

    intent = None
    if args.intent:
        intent = _parse_intent_record_md(Path(args.intent))

    cmd = args.command
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]

    decision = decide(cmd, policy, intent, sandbox_root)

    # --- decision audit (always) ---
    _append_audit(
        audit_path,
        {
            "event": "decision",
            "allowed": decision.allowed,
            "reason": decision.reason,
            "cmd": decision.normalized_command,
            "files_touched_est": decision.files_touched,
            "policy": str(policy_path),
            "intent_path": str(Path(args.intent).resolve()) if args.intent else None,
            "sandbox_root": str(sandbox_root),
            "dry_run": bool(args.dry_run),
        },
    )

    # Print decision / dry-run paths
    if args.print_decision or args.dry_run:
        print(f"{'ALLOW' if decision.allowed else 'DENY'}: {decision.reason}")
        print(f"cmd: {decision.normalized_command}")
        if decision.files_touched:
            print(f"files_touched_est: {decision.files_touched}")
        return 0 if decision.allowed else 2

    # Hard deny
    if not decision.allowed:
        print(f"DENY: {decision.reason}", file=sys.stderr)
        print(f"cmd: {decision.normalized_command}", file=sys.stderr)
        return 2

    # Execute
    rc, out, err = run_command(cmd, sandbox_root)

    def _preview(s: str, n: int = 2000) -> str:
        s = s or ""
        return s if len(s) <= n else s[:n] + "...(truncated)"

    # --- execution audit (only after running) ---
    _append_audit(
        audit_path,
        {
            "event": "execution",
            "cmd": decision.normalized_command,
            "returncode": rc,
            "stdout_preview": _preview(out),
            "stderr_preview": _preview(err),
            # forensic context
            "policy": str(policy_path),
            "intent_path": str(Path(args.intent).resolve()) if args.intent else None,
            "sandbox_root": str(sandbox_root),
            "dry_run": False,
        },
    )

    if out:
        sys.stdout.write(out)
    if err:
        sys.stderr.write(err)
    return rc

if __name__ == "__main__":
    raise SystemExit(main())