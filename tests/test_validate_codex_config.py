from __future__ import annotations

import subprocess
from pathlib import Path

from scripts.validate_codex_config import validate_codex_config

REPOSITORY_ROOT = Path(__file__).parent.parent
FIXTURES = Path(__file__).parent / "fixtures" / "codex_config"
VALIDATOR_SCRIPT = REPOSITORY_ROOT / "scripts" / "validate_codex_config.py"
VENV_PYTHON = REPOSITORY_ROOT / "venv" / "bin" / "python"


def test_validate_codex_config_accepts_environment_reference_and_exact_npm_pin() -> None:
    """A validator that rejects environment-backed credentials or exact pins is broken."""
    assert validate_codex_config(FIXTURES / "secure.toml") == []


def test_validate_codex_config_redacts_literal_credentials_and_unpinned_packages() -> None:
    """A validator that permits literals, latest tags, or missing pins is broken."""
    errors = validate_codex_config(FIXTURES / "insecure.toml")

    assert errors == [
        "mcp_servers.exa.env.EXA_API_KEY contains a literal credential",
        "mcp_servers.exa uses an unpinned npm package",
        "mcp_servers.context7 uses an unpinned npm package",
    ]
    assert "fixture-not-a-real-credential" not in "\n".join(errors)


def test_validate_codex_config_recurses_through_lists_and_matches_sensitive_keys_case_insensitively(
    tmp_path: Path,
) -> None:
    """A validator that misses deeply nested secret-shaped literals is broken."""
    config_path = tmp_path / "nested.toml"
    config_path.write_text(
        "[profiles]\n"
        'items = [{ nested = { aPi_SeCrEt = "fixture-not-a-real-credential" } }]\n\n'
        "[service]\n"
        'ACCESS_TOKEN = "$SERVICE_ACCESS_TOKEN"\n',
        encoding="utf-8",
    )

    errors = validate_codex_config(config_path)

    assert errors == ["profiles.items.0.nested.aPi_SeCrEt contains a literal credential"]
    assert "fixture-not-a-real-credential" not in "\n".join(errors)


def test_validate_codex_config_accepts_concrete_scoped_npm_exec_package(tmp_path: Path) -> None:
    """A validator that treats npm exec itself as an unpinned package is broken."""
    config_path = tmp_path / "npm-exec.toml"
    config_path.write_text(
        '[mcp_servers.context7]\ncommand = "npm"\nargs = ["exec", "--yes", "@upstash/context7-mcp@1.2.3"]\n',
        encoding="utf-8",
    )

    assert validate_codex_config(config_path) == []


def test_validate_codex_config_rejects_unpinned_scoped_npm_exec_package(tmp_path: Path) -> None:
    """A validator that permits an unpinned npm exec package is broken."""
    config_path = tmp_path / "npm-exec-unpinned.toml"
    config_path.write_text(
        '[mcp_servers.context7]\ncommand = "npm"\nargs = ["exec", "--yes", "@scope/pkg"]\n',
        encoding="utf-8",
    )

    errors = validate_codex_config(config_path)

    assert errors == ["mcp_servers.context7 uses an unpinned npm package"]
    assert "@scope/pkg" not in "\n".join(errors)


def test_validate_codex_config_rejects_scoped_latest_ranges_and_non_concrete_versions(tmp_path: Path) -> None:
    """A validator that accepts mutable or incomplete scoped package versions is broken."""
    config_path = tmp_path / "unpinned-scoped.toml"
    config_path.write_text(
        "[mcp_servers.latest]\n"
        'command = "npx"\n'
        'args = ["--yes", "@scope/latest-package@latest"]\n\n'
        "[mcp_servers.range]\n"
        'command = "npx"\n'
        'args = ["--yes", "@scope/range-package@^1.2.3"]\n\n'
        "[mcp_servers.partial]\n"
        'command = "npx"\n'
        'args = ["--yes", "@scope/partial-package@1.2"]\n',
        encoding="utf-8",
    )

    assert validate_codex_config(config_path) == [
        "mcp_servers.latest uses an unpinned npm package",
        "mcp_servers.range uses an unpinned npm package",
        "mcp_servers.partial uses an unpinned npm package",
    ]


def test_validate_codex_config_skips_npm_option_values_before_package(tmp_path: Path) -> None:
    """Cache paths must not hide a later unpinned npx or npm exec package."""
    config_path = tmp_path / "npm-options.toml"
    config_path.write_text(
        "[mcp_servers.npx_cache]\n"
        'command = "npx"\n'
        'args = ["--cache", "/private/tmp/npx-cache", "@scope/example@latest"]\n\n'
        "[mcp_servers.npx_cache_equals]\n"
        'command = "npx"\n'
        'args = ["--cache=/private/tmp/npx-cache", "@scope/example@latest"]\n\n'
        "[mcp_servers.npm_exec_cache]\n"
        'command = "npm"\n'
        'args = ["exec", "--cache", "/private/tmp/npx-cache", "@scope/example@latest"]\n\n'
        "[mcp_servers.delimited]\n"
        'command = "npx"\n'
        'args = ["--yes", "@scope/example@latest", "--", "--stdio"]\n\n'
        "[mcp_servers.package_option]\n"
        'command = "npx"\n'
        'args = ["--package", "@scope/example@latest", "--", "server"]\n\n'
        "[mcp_servers.pinned_package_option]\n"
        'command = "npx"\n'
        'args = ["--package", "@scope/example@1.2.3", "--", "server"]\n',
        encoding="utf-8",
    )

    assert validate_codex_config(config_path) == [
        "mcp_servers.npx_cache uses an unpinned npm package",
        "mcp_servers.npx_cache_equals uses an unpinned npm package",
        "mcp_servers.npm_exec_cache uses an unpinned npm package",
        "mcp_servers.delimited uses an unpinned npm package",
        "mcp_servers.package_option uses an unpinned npm package",
    ]


def test_validate_codex_config_rejects_each_npm_exec_package_option(tmp_path: Path) -> None:
    """Every explicit package dependency must be pinned, not just the first one."""
    config_path = tmp_path / "repeated-package-options.toml"
    config_path.write_text(
        "[mcp_servers.repeated]\n"
        'command = "npm"\n'
        'args = ["exec", "--package", "@scope/pinned@1.2.3", "-p", "@scope/mutable@latest", "--package", "@scope/other@latest", "--", "server"]\n\n'
        "[mcp_servers.launch_target]\n"
        'command = "npm"\n'
        'args = ["exec", "--package", "@scope/pinned@1.2.3", "--", "server"]\n',
        encoding="utf-8",
    )

    assert validate_codex_config(config_path) == [
        "mcp_servers.repeated uses an unpinned npm package",
    ]


def test_validator_cli_validates_fixtures_and_redacts_diagnostics() -> None:
    """The direct CLI must mirror validation results without exposing credentials."""
    secure = subprocess.run(
        [VENV_PYTHON, VALIDATOR_SCRIPT, FIXTURES / "secure.toml"],
        capture_output=True,
        check=False,
        cwd=REPOSITORY_ROOT,
        text=True,
    )
    insecure = subprocess.run(
        [VENV_PYTHON, VALIDATOR_SCRIPT, FIXTURES / "insecure.toml"],
        capture_output=True,
        check=False,
        cwd=REPOSITORY_ROOT,
        text=True,
    )

    assert secure.returncode == 0
    assert insecure.returncode != 0
    assert "mcp_servers.exa.env.EXA_API_KEY contains a literal credential" in insecure.stderr
    assert "fixture-not-a-real-credential" not in insecure.stdout
    assert "fixture-not-a-real-credential" not in insecure.stderr
