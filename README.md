# intent-gate

Minimal refusal boundary for agentic execution: **block destructive filesystem commands unless an explicit Intent Record exists**.

V1 is intentionally small:

- local CLI
- deterministic allow/deny
- human-reviewable intent
- easy to demo in under a minute

## Requirements

- Python 3 (tested with a local `.venv`)
- **GNU Make ≥ 3.82** (macOS `/usr/bin/make` is 3.81 and will fail)

Use the repo wrapper:

```bash
./makew --version
./makew demo
```
---

## 1) The Problem

Agentic systems can execute shell commands that mutate the filesystem.

That creates **irreversible outcomes** and **liability**:

- accidental deletes (`rm`)
- unintended overwrites (`sed`, `truncate`)
- moving/renaming critical files (`mv`)
- copying into restricted locations (`cp`)

When a system can mutate state, "oops" is no longer a minor bug--it's damage.

---

## 2) The Boundary

**Threat model (V1):** the executor/agent is untrusted; the Intent Record channel is trusted; enforcement is local to one machine.

**No mutation without explicit human intent.**

If a command is destructive/mutating, it is **inadmissible** unless a matching, valid Intent Record is provided.

Default posture: **deny**.

## Objections (answered)

**"Can an agent generate its own Intent Record?"**  
Not inside this trust boundary. `intent-gate` assumes the Intent Record is created outside the agent (by a human or a separate trusted UX) and then passed in. The gate verifies scope/expiry/signature/policy constraints before any mutation.

**"Could a vendor turn a checkbox into 'intent' and shift liability?"**  
A checkbox can be turned into an IR, but that's equivalent to issuing broad credentials. intent-gate can't fix bad governance upstream--it makes the governance **explicit, inspectable, and auditable** (scope + expiry + action-class + constraints). If you mint wide IRs, you get wide permissions. Intent-gate is agnostic to how the IR is minted (checkbox, UI workflow, human-written file, etc.). It doesn't adjudicate legitimacy; it enforces only what the IR explicitly grants (scope, expiry, action class, constraints) and logs decision + execution.

**"Isn't this just blockchain/consensus?"**  
No. Blockchains solve multi-party consensus in adversarial networks. `intent-gate` solves a local refusal boundary: deterministic allow/deny + append-only audit for destructive commands. No consensus protocol, no network, no distributed state--just a local gate + append-only log.

---

## 3) The Artifact

The gate composes policy defaults with per-Intent Record constraints.

- `deny_globs` are **unioned** (policy U IR)
- `max_files` comes from the IR **when present**; otherwise the policy default applies

It then makes a deterministic allow/deny decision.

### A) Intent Record (IR)

Think of an Intent Record as *inspectable*, short-lived, scoped credentials for a specific class of mutation.

- who is authorizing (human attestation)
- scope root (what area is allowed)
- expiry
- allowed action classes (e.g., `delete`)
- constraints (e.g., deny globs, max files)
- signature (V1: typed signature)

**Note:** V1 signatures are **not cryptographic identity**; they are a human attestation for demo/audit. Stronger signing can be layered later.

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

Example constraints (abbrev):
```yaml
constraints:
  max_files: 5
  deny_globs:
    - "**/.git/**"
    - "**/*.pem"
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

---

Usage pattern:

- Create an IR: `./src/ir_tool.py new --root sandbox --actions delete --note "..."`
- Execute through the gate: `./src/intent_gate.py --intent <IR_PATH> -- rm foo.txt`

### C) Audit trail

The gate writes an append-only JSONL audit log:
- every attempt yields a decision event
- allowed executions also yield an execution event
- execution events are self-contained for forensics (policy, intent_path, sandbox_root, return code, stdout/stderr previews)

---

## 4) The Demo

### Quick start

```bash
./makew venv
./makew deps
./makew test
./makew demo
```

### One-shot:

```bash
./makew clean && ./makew test && ./makew evidence && ./makew demo
```

### Evidence (deterministic artifacts)

Regenerates reproducible denial artifacts and a scope-mismatch denial transcript:

```bash
./makew evidence
```
Missing-intent denial
- docs/demo_before_denial.txt (baseline; created only if missing)
- docs/demo_after_denial.txt (current run)
- docs/demo_denial_diff.patch (sanitized diff; deterministic)

Scope-mismatch denial
- docs/demo_scope_mismatch_before.txt (baseline; created only if missing)
- docs/demo_scope_mismatch_after.txt (current run)
- docs/demo_scope_mismatch_diff.patch (sanitized diff; deterministic)
- docs/demo_scope_mismatch.txt (compat: copy of scope-mismatch “after”)

Deny-glob lock denial (policy-protected targets)
- docs/demo_deny_glob_before.txt (baseline; created only if missing)
- docs/demo_deny_glob_after.txt (current run)
- docs/demo_deny_glob_diff.patch (sanitized diff; deterministic)

### `make demo` runs three scenarios:

1. **DENY** -- `rm` without an Intent Record  
2. **ALLOW (dry-run)** -- `rm` with a valid Intent Record  
3. **ALLOW (execute)** -- actually deletes the file inside the sandbox
4. Sandbox is empty (or at least `foo.txt` is gone)
5. Audit log shows decision + execution events

After `make demo`, the audit log should contain:
- 3 `"event": "decision"` lines (DENY dry-run, ALLOW dry-run, ALLOW execute)
- 1 `"event": "execution"` line (returncode 0)

```bash
grep -q '"event": "execution"' audit.jsonl && grep -q '"returncode": 0' audit.jsonl
```

### 20-second demo (manual)
```bash
rm -f audit.jsonl
mkdir -p sandbox && echo "hello" > sandbox/foo.txt

# DENY without intent (dry-run)
.venv/bin/python ./src/intent_gate.py --dry-run --print-decision -- rm foo.txt || true

# Create intent + execute
IR=$(.venv/bin/python ./src/ir_tool.py new --root sandbox --actions delete --note "delete foo.txt in sandbox")
.venv/bin/python ./src/intent_gate.py --intent "$IR" -- rm foo.txt

tail -n 4 audit.jsonl
```

### Mini-agent demo (optional)
`src/mini_agent.py` is a deliberately tiny deterministic "agent" that maps simple tasks to filesystem commands
and routes them through the gate (not an LLM; included to demonstrate the workflow end-to-end).
```bash
rm -f audit.jsonl
mkdir -p sandbox && echo "hello" > sandbox/foo.txt

.venv/bin/python ./src/mini_agent.py "delete foo.txt" || true

IR=$(.venv/bin/python ./src/ir_tool.py new --root sandbox --actions delete --note "delete foo.txt in sandbox")
.venv/bin/python ./src/mini_agent.py --intent "$IR" --execute "delete foo.txt"

tail -n 4 audit.jsonl
```
---

## 5) What This Is Not

**This is not:**
- a universal governance layer
- an "AI alignment" solution
- a policy language standard
- an enterprise integration platform
- a sandbox / containment system
- a fundraising pitch
- a network effect product

This is a small enforceable refusal boundary: "no irreversible actions without explicit intent."

---

**Repository Structure**
- src/intent_gate.py -- gatekeeper CLI (allow/deny + execute)
- src/ir_tool.py -- generates YAML front-matter Intent Records
- src/mini_agent.py -- tiny deterministic "agent" routed through intent-gate
- policies/policy.yaml -- command allowlists + defaults
- intent_records/ -- IR templates + (ignored) generated IRs
- tests/ -- pytest coverage
- Makefile -- canonical demo + tests

---

**Design Principles**
- Small, legible, enforceable
- Default deny
- Deterministic decisions
- Human reviewable intent
- Easy to demo quickly

---

## Related Artifact

- **Refusal Boundary Checklist for Agentic Systems**
  - [Markdown](docs/REFUSAL_BOUNDARY_CHECKLIST.md)
  - [PDF](docs/REFUSAL_BOUNDARY_CHECKLIST.pdf)