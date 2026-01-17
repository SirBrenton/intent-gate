from pathlib import Path

from src.ir_tool import render_ir


def test_render_ir_has_front_matter(tmp_path: Path):
    root = (tmp_path / "sandbox").resolve()
    txt = render_ir(root=root, actions=["delete"], note="remove temp file", expires_hours=1)
    assert txt.startswith("---\n")
    assert "scope:\n  root: " in txt
    assert "actions_allowed:\n  - delete" in txt
    assert "expires_utc:" in txt


def test_render_ir_default_note(tmp_path: Path):
    root = (tmp_path / "sandbox").resolve()
    txt = render_ir(root=root, actions=["write_file"], note="", expires_hours=1)
    assert "(fill in:" in txt
