from __future__ import annotations

import logging
import shutil
import subprocess
from collections.abc import Callable
from pathlib import Path

import tomllib

try:
    from scripts.validate_codex_config import validate_codex_config
except ModuleNotFoundError as error:
    if error.name != "scripts":
        raise
    from validate_codex_config import validate_codex_config

LOGGER = logging.getLogger(__name__)


def check_environment(root: Path, which: Callable[[str], str | None]) -> list[str]:
    """Return missing or invalid local development dependencies."""
    errors: list[str] = []
    for command in ("rg", "swift", "git"):
        if which(command) is None:
            errors.append(f"missing command: {command}; install with `brew bundle`")

    for relative_path in ("venv/bin/python", "venv/bin/pre-commit"):
        if not (root / relative_path).is_file():
            errors.append(f"missing file: {relative_path}; create the project virtual environment")

    config_path = root / ".codex" / "config.toml"
    if not config_path.is_file():
        errors.append("missing Codex config: .codex/config.toml")
    else:
        try:
            errors.extend(validate_codex_config(config_path))
        except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError):
            errors.append("unparseable Codex config: .codex/config.toml")

    return errors


def main() -> int:
    """Check the repository-local developer toolchain without changing it."""
    root = Path(__file__).resolve().parents[1]
    ripgrep_path = shutil.which("rg")
    if ripgrep_path is not None:
        subprocess.run([ripgrep_path, "--version"], check=False, capture_output=True, text=True)
    errors = check_environment(root, shutil.which)
    for error in errors:
        LOGGER.error("%s", error)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
