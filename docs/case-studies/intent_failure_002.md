# Intent Failure Case Study 002

## Title: The Wrong Root That Was Technically Allowed

### 1) Real-World Scenario

A developer asked an AI agent to “clean up build artifacts in the project.”  
The agent generated and executed a destructive command using globs:

```bash
rm -rf build/*
```
A small context mistake turned “delete build output” into “delete far more than intended.” Common real-world variants include:

- **Wrong root:** the agent’s working directory was not the repo the human assumed.
- **Symlink surprise:** build/ (or a parent directory) was a symlink pointing outside the intended scope.
- **Empty / wrong variable expansion:** a template like `rm -rf "$TARGET"/*` ran with `TARGET` unset or incorrect, shifting the delete target unexpectedly.

In each case, the shell command was syntactically valid, commonly used, and consistent with the developer’s high-level instruction to “clean up.”

No capability safeguards were violated.
The outcome was still clearly wrong: **irreversible deletion outside the intended boundary.**

## 2) What the Human Believed They Intended

The human believed they were authorizing:

- Deletion of only a specific build output directory
- Cleanup of temporary artifacts, not source or configuration
- A narrow, routine maintenance action

They did not intend to:

- Run a broad recursive delete at the repo root (or outside the repo)
- Destroy uncommitted work
- Affect files outside a clearly scoped cleanup directory

In plain terms: they intended targeted cleanup, not unbounded deletion.

## 3) How the System Interpreted That Intent

The system’s effective reasoning path was:

1. “You asked to clean up build artifacts.”
2. “rm -rf is a valid tool for deleting files.”
3. “build/* looks like the right target.”
4. Therefore: execute it.

From a narrow capability standpoint, this was coherent.
From an intent standpoint, it was dangerously underspecified.

This is the canonical filesystem failure mode:

> Technically valid commands + underspecified boundaries.

The failure was not a bug in capability.
It was a failure to make scope explicit before executing an irreversible action.

## 4) How Intent-Gate Would Have Prevented This

Before allowing mutation, intent-gate forces one explicit commitment:

> “What filesystem scope are you authorizing destructive actions within?”

A minimal Intent Record scopes deletion to an authorized root (e.g., the sandbox), time-bounds it, and constrains blast radius:

```yaml
scope:
  root: /path/to/sandbox
expires: "2099-01-01T00:00:00-08:00"
actions:
  - delete
constraints:
  max_files: 200
  deny_globs:
    - "**/.git/**"
    - "**/*.key"
    - "**/*.pem"
```
If the agent attempted deletion that resolved outside the authorized root (wrong-root, path traversal, symlink escape), the gate would **DENY before any damage occurred** and emit a reproducible denial reason plus an audit event.

No new features are required — this follows directly from existing V1 behavior:
- **Scope enforcement** (IR root must match the authorized execution root)
- **Realpath containment** (deny path escape / symlink resolution outside scope)
- **Default-deny posture** for mutating commands without valid intent

## Conclusion

This case illustrates the core thesis in a filesystem context:

> Autonomy is not the absence of intent — it is the result of it.

The agent was capable and compliant.
The failure was that human intent was insufficiently bounded for an irreversible action.

Intent-gate doesn’t slow down useful automation —
it prevents the class of disasters that only become visible after irreversible damage.

## See also

- [Markdown](docs/case-studies/intent_failure_001.md) 
- [Markdown](docs/narratives/intent_is_boundaries_not_predictions.md)