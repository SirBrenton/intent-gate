# intent-gate

Minimal refusal boundary for agentic execution: **block destructive filesystem commands unless an explicit Intent Record exists**.

V1 is intentionally small:

- local CLI
- deterministic allow/deny
- human-reviewable intent
- easy to demo in under a minute

---

## 1) The Problem

Agentic systems can execute shell commands that mutate the filesystem.

That creates **irreversible outcomes** and **liability**:

- accidental deletes (`rm`)
- unintended overwrites (`sed`, `truncate`)
- moving/renaming critical files (`mv`)
- copying into restricted locations (`cp`)

When a system can mutate state, "oops" is no longer a minor bug—it's damage.

---

## 2) The Boundary

**No mutation without explicit human intent.**

If a command is destructive/mutating, it is **inadmissible** unless a matching, valid Intent Record is provided.

Default posture: **deny**.

---

## 3) The Artifact

The gate merges policy defaults with per-Intent Record constraints (union), then makes a deterministic allow/deny decision.

Two small pieces:

### A) Intent Record (IR)

A human-readable file that declares:

- who is authorizing
- scope root (what area is allowed)
- expiry
- allowed action classes (e.g., `delete`)
- constraints (e.g., deny globs, max files)
- signature (V1: typed signature)

V1 supports:

- **YAML front-matter IR** (preferred; emitted by `ir_tool.py`)
- **legacy markdown-heading IR** (kept for older tests)

Example (abbrev):

```yaml

id: IR-20260117-201843Z
created_utc: 20260117-201843Z
expires_utc: 2026-01-18T20:18:43Z
signature: "Brent Williams"
scope:
  root: /Users/brentwilliams/intent-gate/sandbox
actions_allowed:
  - delete
  ```
---

### B) Gatekeeper

`src/intent_gate.py` classifies commands:

- **read-only allowlist**: `ls`, `cat`, `grep`, `find`
- **mutating requires intent**: `rm`, `mv`, `cp`, `sed`, `truncate`
- **unknown commands**: default deny

Then enforces:

- signature present
- scope root matches sandbox root
- expiry not passed
- action class allowed (e.g., `rm` ⇒ `delete`)
- deny globs (union of policy + IR)
- max-files estimate
- safety rules (no absolute paths, no `sandbox/` prefix, no dangerous targets like `/`, `.`, `..`)

Usage pattern:

- Create an IR: ./src/ir_tool.py new --root sandbox --actions delete --note "..."
- Execute through the gate: ./src/intent_gate.py --intent <IR_PATH> -- rm foo.txt

---


---

## 4) The Demo

### Quick start

```bash
make venv
make deps
make test
make demo
```
make demo runs three scenarios:
	1.	DENY: rm without an Intent Record
	2.	ALLOW (dry-run): rm with a valid Intent Record
	3.	ALLOW (execute): actually deletes the file inside the sandbox

---

## 5) What This Is Not

**This is not:**
- a universal governance layer
- an “AI alignment” solution
- a policy language standard
- an enterprise integration platform
- a sandbox / containment system
- a fundraising pitch
- a network effect product

This is a small enforceable refusal boundary: “no irreversible actions without explicit intent.”

---

**Repository Structure**
- src/intent_gate.py — gatekeeper CLI (allow/deny + execute)
- src/ir_tool.py — generates YAML front-matter Intent Records
- policies/policy.yaml — command allowlists + defaults
- intent_records/ — IR templates + (ignored) generated IRs
- tests/ — pytest coverage
- Makefile — canonical demo + tests

---

**Design Principles**
- Small, legible, enforceable
- Default deny
- Deterministic decisions
- Human reviewable intent
- Easy to demo quickly
