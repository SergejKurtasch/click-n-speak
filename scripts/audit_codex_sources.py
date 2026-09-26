#!/usr/bin/env python3
"""Inventory Codex skill sources without exposing their instruction bodies."""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Sequence

import tomllib

LOGGER = logging.getLogger("audit_codex_sources")
FRONTMATTER_NAME = re.compile(r"^name:\s*(?P<value>[^#\n]+?)\s*$", re.MULTILINE)
DEFAULT_SKILL_ROOTS = (Path.home() / ".codex" / "skills", Path.home() / ".agents" / "skills")
DEFAULT_CONFIG_PATH = Path.home() / ".codex" / "config.toml"
WRAPPER_PATH = Path(".cursor/skills/update-claude-md/SKILL.md")
CANONICAL_SKILL_PATHS = (
    Path(".agents/skills/update-codex-md/SKILL.md"),
    Path(".claude/skills/update-claude-md/SKILL.md"),
)
EXTERNAL_GLOBAL_GUIDES = (Path.home() / ".codex" / "AGENTS.md", Path.home() / "AGENTS.md")


@dataclass(frozen=True, slots=True)
class SkillRecord:
    """A skill's stable public inventory fields."""

    name: str
    path: Path
    digest: str


def _leading_frontmatter(text: str) -> str | None:
    """Return the initial YAML-like block without parsing an entire YAML document."""
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---", 4)
    if end == -1:
        return None
    return text[4:end]


def _frontmatter_name(path: Path) -> str | None:
    """Read the one supported name scalar from a skill's leading frontmatter."""
    try:
        frontmatter = _leading_frontmatter(path.read_text(encoding="utf-8"))
    except OSError as exc:
        LOGGER.warning("Unable to read skill metadata at %s: %s", path, exc)
        return None
    if frontmatter is None:
        return None
    match = FRONTMATTER_NAME.search(frontmatter)
    if match is None:
        return None
    value = match.group("value").strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        value = value[1:-1]
    return value or None


def _digest(path: Path) -> str:
    """Return the SHA-256 digest of the source file."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory_skills(roots: Sequence[Path]) -> tuple[SkillRecord, ...]:
    """Return named skill records found below roots, preserving root priority."""
    records: list[SkillRecord] = []
    for root in roots:
        if not root.is_dir():
            LOGGER.warning("Skill root is unavailable: %s", root)
            continue
        for path in sorted(root.rglob("SKILL.md"), key=lambda item: item.as_posix()):
            name = _frontmatter_name(path)
            if name is None:
                LOGGER.warning("Skipping skill without a leading frontmatter name: %s", path)
                continue
            try:
                digest = _digest(path)
            except OSError as exc:
                LOGGER.warning("Unable to digest skill at %s: %s", path, exc)
                continue
            records.append(SkillRecord(name=name, path=path, digest=digest))
    return tuple(records)


def find_duplicate_names(records: Sequence[SkillRecord]) -> dict[str, tuple[SkillRecord, ...]]:
    """Group repeated skill names while retaining source priority and paths."""
    grouped: dict[str, list[SkillRecord]] = {}
    for record in records:
        grouped.setdefault(record.name, []).append(record)
    return {name: tuple(group) for name, group in grouped.items() if len(group) > 1}


def _normalized_path(path: Path, base: Path) -> Path:
    """Resolve a configured skill folder path against its configuration file."""
    expanded = path.expanduser()
    return (expanded if expanded.is_absolute() else base / expanded).resolve(strict=False)


def _configured_skill_sources(config_path: Path) -> dict[Path, bool]:
    """Return normalized ``skills.config`` folder paths and enabled decisions."""
    try:
        config = tomllib.loads(config_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise ValueError(f"unable to parse skills config at {config_path}") from exc
    skills = config.get("skills")
    if skills is None:
        return {}
    if not isinstance(skills, dict):
        raise ValueError(f"skills config must be a table: {config_path}")
    entries = skills.get("config")
    if entries is None:
        return {}
    if not isinstance(entries, list):
        raise ValueError(f"skills.config must be an array: {config_path}")

    configured: dict[Path, bool] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError(f"skills.config entry must be a table: {config_path}")
        path = entry.get("path")
        enabled = entry.get("enabled")
        if not isinstance(path, str) or not isinstance(enabled, bool):
            raise ValueError(f"skills.config entry requires path and enabled: {config_path}")
        normalized = _normalized_path(Path(path), config_path.parent)
        if normalized in configured:
            raise ValueError(f"skills.config repeats a source path: {config_path}")
        configured[normalized] = enabled
    return configured


def enabled_skill_records(records: Sequence[SkillRecord], config_path: Path) -> tuple[SkillRecord, ...]:
    """Exclude skill records whose containing folder is disabled in ``skills.config``."""
    configured = _configured_skill_sources(config_path)
    return tuple(record for record in records if configured.get(_normalized_path(record.path.parent, Path.cwd()), True))


def _body_lines(path: Path) -> tuple[str, ...]:
    """Return non-empty skill body lines after the leading frontmatter block."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        LOGGER.warning("Unable to read skill body at %s: %s", path, exc)
        return ()
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end != -1:
            text = text[end + 4 :]
    return tuple(line.strip() for line in text.splitlines() if line.strip())


def wrapper_has_long_duplicate(wrapper: Path, canonicals: Sequence[Path], limit: int = 5) -> bool:
    """Return whether a wrapper copies more than limit consecutive canonical body lines."""
    wrapper_lines = _body_lines(wrapper)
    if len(wrapper_lines) <= limit:
        return False
    for canonical in canonicals:
        canonical_lines = _body_lines(canonical)
        windows = {canonical_lines[index : index + limit + 1] for index in range(len(canonical_lines) - limit)}
        if any(wrapper_lines[index : index + limit + 1] in windows for index in range(len(wrapper_lines) - limit)):
            return True
    return False


def strict_errors(
    roots: Sequence[Path], repository_root: Path, config_path: Path = DEFAULT_CONFIG_PATH
) -> tuple[str, ...]:
    """Return non-sensitive source-consolidation failures for strict verification."""
    records = inventory_skills(roots)
    try:
        enabled_records = enabled_skill_records(records, config_path)
    except ValueError:
        errors = [f"invalid skills.config: {config_path}"]
    else:
        errors = [f"duplicate enabled skill name: {name}" for name in find_duplicate_names(enabled_records)]
    if wrapper_has_long_duplicate(
        repository_root / WRAPPER_PATH,
        tuple(repository_root / path for path in CANONICAL_SKILL_PATHS),
    ):
        errors.append("Cursor wrapper duplicates more than five canonical skill body lines")
    global_guide, parent_guide = EXTERNAL_GLOBAL_GUIDES
    if parent_guide.is_file():
        errors.append(f"external parent instruction source pending approval: {parent_guide}")
    if not global_guide.is_file():
        errors.append(f"missing external global instruction guide: {global_guide}")
    return tuple(errors)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skill-root", action="append", type=Path, default=[])
    parser.add_argument("--config-path", type=Path, default=DEFAULT_CONFIG_PATH)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--strict", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Write an inventory JSON document and optionally enforce consolidation checks."""
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    arguments = _parser().parse_args(argv)
    roots = tuple(arguments.skill_root) or DEFAULT_SKILL_ROOTS
    records = inventory_skills(roots)
    payload = {"skills": [{**asdict(record), "path": str(record.path)} for record in records]}
    rendered = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if arguments.output is None:
        sys.stdout.write(rendered)
    else:
        arguments.output.write_text(rendered, encoding="utf-8")
        LOGGER.info("Wrote skill inventory to %s", arguments.output)
    if not arguments.strict:
        return 0
    errors = strict_errors(roots, Path.cwd(), arguments.config_path)
    for error in errors:
        LOGGER.error(error)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
