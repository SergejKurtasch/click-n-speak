from __future__ import annotations

from pathlib import Path

import pytest

from scripts.audit_codex_sources import (
    enabled_skill_records,
    find_duplicate_names,
    inventory_skills,
    strict_errors,
)
from scripts.validate_agent_environment import source_inventory_errors


@pytest.fixture
def fixture_roots() -> tuple[Path, Path]:
    fixtures = Path(__file__).parent / "fixtures" / "codex_sources"
    return fixtures / "system", fixtures / "user"


def test_duplicate_names_group_different_sources(fixture_roots: tuple[Path, Path]) -> None:
    records = inventory_skills(fixture_roots)
    duplicates = find_duplicate_names(records)

    assert tuple(record.path for record in duplicates["cloudflare"]) == (
        fixture_roots[0] / "cloudflare/SKILL.md",
        fixture_roots[1] / "cloudflare/SKILL.md",
    )


def test_inventory_uses_leading_frontmatter_name_and_digest(
    fixture_roots: tuple[Path, Path],
) -> None:
    records = inventory_skills(fixture_roots)

    assert tuple(record.name for record in records) == ("cloudflare", "cloudflare")
    assert all(len(record.digest) == 64 for record in records)
    assert all("fixture body" not in record.digest.casefold() for record in records)


def test_disabled_skill_config_entry_excludes_normalized_source_path(
    fixture_roots: tuple[Path, Path], tmp_path: Path
) -> None:
    config_path = tmp_path / "config.toml"
    disabled_folder = fixture_roots[1] / "cloudflare"
    normalized_variant = disabled_folder.parent / ".." / "user" / "cloudflare"
    config_path.write_text(
        f'[skills]\nconfig = [{{ path = "{normalized_variant}", enabled = false }}]\n',
        encoding="utf-8",
    )

    enabled = enabled_skill_records(inventory_skills(fixture_roots), config_path)

    assert tuple(record.path for record in enabled) == (fixture_roots[0] / "cloudflare/SKILL.md",)


def test_strict_mode_ignores_duplicate_source_disabled_by_skill_config(
    fixture_roots: tuple[Path, Path], tmp_path: Path
) -> None:
    enabled_config_path = tmp_path / "enabled-config.toml"
    config_path = tmp_path / "config.toml"
    source_folder = fixture_roots[1] / "cloudflare"
    enabled_config_path.write_text(
        f'[skills]\nconfig = [{{ path = "{source_folder}", enabled = true }}]\n',
        encoding="utf-8",
    )
    config_path.write_text(
        f'[skills]\nconfig = [{{ path = "{source_folder}", enabled = false }}]\n',
        encoding="utf-8",
    )

    unfiltered_errors = strict_errors(fixture_roots, tmp_path, enabled_config_path)
    errors = strict_errors(fixture_roots, tmp_path, config_path)

    assert "duplicate enabled skill name: cloudflare" in unfiltered_errors
    assert "duplicate enabled skill name: cloudflare" not in errors


def test_source_inventory_rejects_cursor_wrapper_that_copies_six_lines(tmp_path: Path) -> None:
    codex_canonical = tmp_path / ".agents/skills/update-codex-md/SKILL.md"
    canonical = tmp_path / ".claude/skills/update-claude-md/SKILL.md"
    wrapper = tmp_path / ".cursor/skills/update-claude-md/SKILL.md"
    canonical.parent.mkdir(parents=True)
    wrapper.parent.mkdir(parents=True)
    codex_canonical.parent.mkdir(parents=True)
    shared_body = "\n".join(f"Shared instruction {index}." for index in range(6))
    codex_canonical.write_text("---\nname: update-codex-md\n---\nCodex-only instruction.\n", encoding="utf-8")
    canonical.write_text(f"---\nname: update-claude-md\n---\n{shared_body}\n", encoding="utf-8")
    wrapper.write_text(f"---\nname: update-claude-md\n---\n{shared_body}\n", encoding="utf-8")

    assert "Cursor wrapper duplicates more than five canonical skill body lines" in source_inventory_errors(tmp_path)
