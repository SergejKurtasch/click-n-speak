from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]


def test_legacy_build_refuses_cleanup_without_explicit_opt_in(tmp_path: Path) -> None:
    script_path = tmp_path / "scripts" / "build.sh"
    script_path.parent.mkdir()
    shutil.copy2(PROJECT_ROOT / "scripts" / "build.sh", script_path)

    sentinel = tmp_path / "build" / "agent-guard-sentinel"
    sentinel.parent.mkdir(exist_ok=True)
    sentinel.write_text("preserve", encoding="utf-8")
    result = subprocess.run(
        ["bash", str(script_path)],
        cwd=tmp_path,
        capture_output=True,
        check=False,
        text=True,
        env={key: value for key, value in os.environ.items() if key != "CNS_ALLOW_LEGACY_CLEAN"},
    )

    assert result.returncode == 2
    assert "CNS_ALLOW_LEGACY_CLEAN=1" in result.stderr
    assert sentinel.is_file()
