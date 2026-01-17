from pathlib import Path
import yaml

from src.intent_gate import decide, _parse_intent_record_md


def write_policy(p: Path):
    policy = {
        "version": 0.1,
        "read_only_commands": ["ls", "cat", "grep", "find"],
        "requires_intent_commands": ["rm", "mv", "cp", "sed", "truncate"],
        "deny_globs_default": ["**/.git/**", "**/*.key", "**/*.pem"],
        "max_files_default": 50,
    }
    p.write_text(yaml.safe_dump(policy), encoding="utf-8")


def test_ir_tool_output_is_gate_compatible(tmp_path: Path):
    # Arrange
    policy_path = tmp_path / "policy.yaml"
    write_policy(policy_path)
    policy = yaml.safe_load(policy_path.read_text())

    sandbox_root = tmp_path / "sandbox"
    sandbox_root.mkdir()
    (sandbox_root / "foo.txt").write_text("x", encoding="utf-8")

    # Generate an IR in canonical format (same structure ir_tool should emit)
    ir_path = tmp_path / "IR.md"
    ir_path.write_text(
        """\
# Intent Record

## Human
name: Brent Williams
attestation: I authorize the destructive actions below within the defined scope.

## Scope
root: {root}
expires: 2099-01-01T00:00:00-08:00

## Allowed action classes
- delete

## Constraints
- max_files: 20
- **/.git/**
- **/*.key
- **/*.pem

## Signature
method: local-typed
signature: Brent Williams
""".format(root=sandbox_root),
        encoding="utf-8",
    )

    ir = _parse_intent_record_md(ir_path)

    # Act
    d = decide(["rm", "foo.txt"], policy, ir, sandbox_root)

    # Assert
    assert d.allowed is True
