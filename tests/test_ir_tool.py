from pathlib import Path
from src.ir_tool import render_ir


def test_render_ir_has_canonical_sections(tmp_path: Path):
    root = (tmp_path / "sandbox").resolve()
    txt = render_ir(root=root, actions=["delete"], note="remove temp file", expires_hours=1)

    assert txt.startswith("# Intent Record\n")
    assert "## Human\n" in txt
    assert "## Scope\n" in txt
    assert f"root: {str(root)}" in txt
    assert "## Allowed action classes\n- delete\n" in txt
    assert "## Constraints\n" in txt
    assert "## Signature\n" in txt
    assert "signature: Brent Williams" in txt


def test_render_ir_default_note(tmp_path: Path):
    root = (tmp_path / "sandbox").resolve()
    txt = render_ir(root=root, actions=["write_file"], note="", expires_hours=1)
    assert "(fill in:" in txt
