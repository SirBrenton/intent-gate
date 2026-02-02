from pathlib import Path
import textwrap

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


def write_ir(p: Path, sandbox_root: Path, actions=None, deny_globs=None, max_files=20, expires="2099-01-01T00:00:00-08:00"):
    actions = actions or ["delete", "write_over_existing", "move_or_rename", "copy"]
    deny_globs = deny_globs or ["**/.git/**", "**/*.key", "**/*.pem"]
    md = f"""\
# Intent Record

## Human
name: Brent Williams
attestation: I authorize the destructive actions below within the defined scope.

## Scope
root: {sandbox_root}
expires: {expires}

## Allowed action classes
""" + "\n".join([f"- {a}" for a in actions]) + f"""

## Constraints
- max_files: {max_files}
""" + "\n".join([f"- {g}" for g in deny_globs]) + """

## Signature
method: local-typed
signature: Brent Williams
"""
    p.write_text(textwrap.dedent(md), encoding="utf-8")


def test_default_deny_unknown(tmp_path: Path):
    policy_path = tmp_path / "policy.yaml"
    write_policy(policy_path)
    policy = yaml.safe_load(policy_path.read_text())
    sandbox_root = tmp_path / "sandbox"
    sandbox_root.mkdir()

    d = decide(["python", "-c", "print(1)"], policy, None, sandbox_root)
    assert d.allowed is False
    assert "unknown command" in d.reason


def test_allow_read_only_ls(tmp_path: Path):
    policy_path = tmp_path / "policy.yaml"
    write_policy(policy_path)
    policy = yaml.safe_load(policy_path.read_text())
    sandbox_root = tmp_path / "sandbox"
    sandbox_root.mkdir()

    d = decide(["ls"], policy, None, sandbox_root)
    assert d.allowed is True


def test_deny_mutating_without_intent(tmp_path: Path):
    policy_path = tmp_path / "policy.yaml"
    write_policy(policy_path)
    policy = yaml.safe_load(policy_path.read_text())
    sandbox_root = tmp_path / "sandbox"
    sandbox_root.mkdir()

    d = decide(["rm", "foo.txt"], policy, None, sandbox_root)
    assert d.allowed is False
    assert "requires an Intent Record" in d.reason


def test_allow_rm_with_valid_intent(tmp_path: Path):
    policy_path = tmp_path / "policy.yaml"
    write_policy(policy_path)
    policy = yaml.safe_load(policy_path.read_text())

    sandbox_root = tmp_path / "sandbox"
    sandbox_root.mkdir()
    (sandbox_root / "foo.txt").write_text("x", encoding="utf-8")

    ir_path = tmp_path / "IR.md"
    write_ir(ir_path, sandbox_root, actions=["delete"])
    ir = _parse_intent_record_md(ir_path)

    d = decide(["rm", "foo.txt"], policy, ir, sandbox_root)
    assert d.allowed is True


def test_deny_root_mismatch(tmp_path: Path):
    policy_path = tmp_path / "policy.yaml"
    write_policy(policy_path)
    policy = yaml.safe_load(policy_path.read_text())

    sandbox_root = tmp_path / "sandbox"
    sandbox_root.mkdir()

    other_root = tmp_path / "other"
    other_root.mkdir()

    ir_path = tmp_path / "IR.md"
    write_ir(ir_path, other_root, actions=["delete"])
    ir = _parse_intent_record_md(ir_path)

    d = decide(["rm", "x.txt"], policy, ir, sandbox_root)
    assert d.allowed is False
    assert "scope.root mismatch" in d.reason


def test_deny_action_not_allowed(tmp_path: Path):
    policy_path = tmp_path / "policy.yaml"
    write_policy(policy_path)
    policy = yaml.safe_load(policy_path.read_text())

    sandbox_root = tmp_path / "sandbox"
    sandbox_root.mkdir()

    ir_path = tmp_path / "IR.md"
    write_ir(ir_path, sandbox_root, actions=["move_or_rename"])  # no delete
    ir = _parse_intent_record_md(ir_path)

    d = decide(["rm", "x.txt"], policy, ir, sandbox_root)
    assert d.allowed is False
    assert "does not allow action 'delete'" in d.reason

def test_deny_glob_match_blocks_delete_at_root(tmp_path: Path):
    policy_path = tmp_path / "policy.yaml"
    write_policy(policy_path)
    policy = yaml.safe_load(policy_path.read_text())

    sandbox_root = tmp_path / "sandbox"
    sandbox_root.mkdir()
    (sandbox_root / "secret.pem").write_text("secret", encoding="utf-8")

    ir_path = tmp_path / "IR.md"
    write_ir(ir_path, sandbox_root, actions=["delete"], deny_globs=[])  # prove policy globs work
    ir = _parse_intent_record_md(ir_path)

    d = decide(["rm", "secret.pem"], policy, ir, sandbox_root)
    assert d.allowed is False

def test_deny_deny_glob_match(tmp_path: Path):
    policy_path = tmp_path / "policy.yaml"
    write_policy(policy_path)
    policy = yaml.safe_load(policy_path.read_text())

    sandbox_root = tmp_path / "sandbox"
    sandbox_root.mkdir()

    # Create a file that matches a default deny_glob
    (sandbox_root / "secret.pem").write_text("top secret", encoding="utf-8")

    # Create an otherwise-valid Intent Record that WOULD allow delete
    ir_path = tmp_path / "IR.md"
    write_ir(ir_path, sandbox_root, actions=["delete"])
    ir = _parse_intent_record_md(ir_path)

    d = decide(["rm", "secret.pem"], policy, ir, sandbox_root)

    assert d.allowed is False
    assert "matches deny_glob" in d.reason
