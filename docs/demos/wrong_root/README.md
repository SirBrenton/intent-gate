## Wrong-Root Demo (90 seconds)

This demo shows a canonical agent failure mode:

> A routine cleanup command becomes catastrophic because the agent’s working directory is not what the human assumed.

### What this demonstrates

1) **Baseline (no gate):** wrong-root cleanup causes real damage (in a temp workspace).
2) **With intent-gate:** the same intent is **DENIED before execution** because the target resolves outside the authorized sandbox (escape detection).
3) **Control:** safe, in-sandbox relative deletion is **ALLOWED** (dry-run).

### Run it (from repo root)

```bash
./makew venv
./makew deps
./makew demo-wrong-root
```
Expected:
- baseline shows damage
- DENY: ... escapes sandbox
- ALLOW: Intent Record validated ... (control)

### 4) Commit
```bash
git commit -m "Add wrong-root sandbox escape demo"
```

### 5) Final validation (before PR)
```bash
./makew demo-wrong-root
./makew demo
./makew test
```
