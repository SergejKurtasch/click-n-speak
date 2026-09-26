from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from scripts.check_dev_environment import check_environment


def _create_required_files(root: Path) -> None:
    (root / "venv/bin").mkdir(parents=True)
    (root / "venv/bin/python").touch()
    (root / "venv/bin/pre-commit").touch()


def test_check_environment_reports_missing_ripgrep(tmp_path: Path) -> None:
    _create_required_files(tmp_path)

    errors = check_environment(
        tmp_path,
        lambda command: None if command == "rg" else f"/bin/{command}",
    )

    assert "missing command: rg; install with `brew bundle`" in errors


def test_check_environment_reports_invalid_utf8_codex_config(tmp_path: Path) -> None:
    _create_required_files(tmp_path)
    config_path = tmp_path / ".codex" / "config.toml"
    config_path.parent.mkdir()
    config_path.write_bytes(b"\xff")

    errors = check_environment(tmp_path, lambda command: f"/bin/{command}")

    assert errors == ["unparseable Codex config: .codex/config.toml"]


def test_check_environment_reports_redacted_config_hygiene_issues(tmp_path: Path) -> None:
    """A doctor that omits config hygiene findings is broken."""
    _create_required_files(tmp_path)
    config_path = tmp_path / ".codex" / "config.toml"
    config_path.parent.mkdir()
    config_path.write_text(
        "[mcp_servers.exa]\n"
        'command = "npx"\n'
        'args = ["-y", "exa-mcp@latest"]\n\n'
        "[mcp_servers.exa.env]\n"
        'EXA_API_KEY = "fixture-not-a-real-credential"\n',
        encoding="utf-8",
    )

    errors = check_environment(tmp_path, lambda command: f"/bin/{command}")

    assert errors == [
        "mcp_servers.exa.env.EXA_API_KEY contains a literal credential",
        "mcp_servers.exa uses an unpinned npm package",
    ]
    assert "fixture-not-a-real-credential" not in "\n".join(errors)


def test_check_dev_environment_runs_directly_from_repository_root() -> None:
    """A doctor that crashes when launched as a script is broken."""
    root = Path(__file__).resolve().parents[1]

    result = subprocess.run(
        [sys.executable, "scripts/check_dev_environment.py"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode in {0, 1}
    assert "ModuleNotFoundError" not in result.stderr


def test_check_dev_environment_reraises_missing_validator_dependency(tmp_path: Path) -> None:
    """A missing validator dependency must not trigger the direct-script fallback."""
    source_root = Path(__file__).resolve().parents[1]
    scripts_directory = tmp_path / "scripts"
    scripts_directory.mkdir()
    (scripts_directory / "__init__.py").touch()
    (scripts_directory / "check_dev_environment.py").write_text(
        (source_root / "scripts" / "check_dev_environment.py").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    (scripts_directory / "validate_codex_config.py").write_text(
        "raise ModuleNotFoundError(\"No module named 'missing_validator_dependency'\", "
        'name="missing_validator_dependency")\n',
        encoding="utf-8",
    )

    result = subprocess.run(
        [sys.executable, "-c", "import scripts.check_dev_environment"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode != 0
    assert result.stderr.rstrip().endswith("ModuleNotFoundError: No module named 'missing_validator_dependency'")
