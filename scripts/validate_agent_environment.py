#!/usr/bin/env python3
"""Validate the repository-scoped Codex context and enforcement wiring."""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
from pathlib import Path
from typing import Any

import tomllib

try:
    from scripts.audit_codex_sources import wrapper_has_long_duplicate
except ModuleNotFoundError:
    from audit_codex_sources import wrapper_has_long_duplicate

LOGGER = logging.getLogger("validate_agent_environment")
AGENTS_MAX_BYTES = 16 * 1024
NESTED_AGENTS_MAX_BYTES = 4 * 1024
MARKDOWN_LINK = re.compile(r"\[[^\]]+\]\((?!https?://|#)([^)]+\.md)\)")
HISTORICAL_ROOT_MARKERS = ("completed roadmap", "known latency profile", "phase 17")
CANONICAL_VERIFICATION_COMMANDS = (
    "venv/bin/python -m pytest <test-path> -q",
    "swift test --disable-index-store --package-path swift-app/Packages/<Package>",
    "swift test --disable-index-store --package-path swift-app/ClickNSpeak",
    "bash swift-app/scripts/swift_verify.sh",
    "bash swift-app/scripts/swift_build_app.sh release",
)
NESTED_AGENTS_PATHS = (
    Path("swift-app/AGENTS.md"),
    Path("swift-app/ClickNSpeak/AGENTS.md"),
    Path("swift-app/Packages/AGENTS.md"),
    Path("swift-app/Packages/CNSSession/AGENTS.md"),
    Path("swift-app/Packages/CNSDictionary/AGENTS.md"),
    Path("legacy-python/src/AGENTS.md"),
    Path("legacy-python/scripts/AGENTS.md"),
    Path("tests/AGENTS.md"),
)
REQUIRED_RULE_PREFIXES = (
    ("swift", "test"),
    ("bash", "swift-app/scripts/swift_verify.sh"),
    ("bash", "swift-app/scripts/swift_build_app.sh"),
    ("venv/bin/python", "-m", "pytest"),
    ("venv/bin/python", "scripts/validate_agent_environment.py"),
)
PROJECT_ROLES = {
    "researcher": (
        "Findings",
        "Evidence path or URL",
        "uncertainties",
        "no edits",
    ),
    "implementer": (
        "Changed files",
        "Verification commands",
        "Residual risks",
    ),
    "reviewer": (
        "Findings ordered by severity",
        "file:line",
        "Test gaps",
        "no edits",
    ),
}
REQUIRED_CODEX_GITIGNORE_ENTRIES = (
    "!.codex/config.toml",
    "!.codex/agents/",
    "!.codex/agents/**",
)
REQUIRED_ROLE_TOML_KEYS = frozenset(("model", "model_reasoning_effort", "model_instructions_file"))


def extract_markdown_targets(text: str) -> tuple[str, ...]:
    """Return unique repository-local Markdown targets in source order."""
    return tuple(dict.fromkeys(MARKDOWN_LINK.findall(text)))


def _section_body(text: str, heading: str) -> str | None:
    match = re.search(
        rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)",
        text,
        flags=re.MULTILINE | re.DOTALL,
    )
    return match.group(1) if match else None


def _validate_root_guide(root: Path, agents_path: Path) -> list[str]:
    try:
        text = agents_path.read_text(encoding="utf-8")
    except OSError as exc:
        return [f"unable to read AGENTS.md: {exc}"]

    errors: list[str] = []
    for target in extract_markdown_targets(text):
        if not (root / target).is_file():
            errors.append(f"missing AGENTS.md link: {target}")
    lowered = text.casefold()
    if any(marker in lowered for marker in HISTORICAL_ROOT_MARKERS):
        errors.append("AGENTS.md contains historical roadmap detail")
    for command in CANONICAL_VERIFICATION_COMMANDS:
        if sum(line.strip() == command for line in text.splitlines()) > 1:
            errors.append(f"AGENTS.md duplicates canonical verification command: {command}")
    return errors


def _validate_nested_guides(root: Path, root_text: str) -> list[str]:
    errors: list[str] = []
    root_sections = tuple(
        body
        for heading in ("Working rules", "Canonical verification commands")
        if (body := _section_body(root_text, heading))
    )
    for relative_path in NESTED_AGENTS_PATHS:
        path = root / relative_path
        try:
            size = path.stat().st_size
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            errors.append(f"missing nested AGENTS.md: {relative_path}")
            continue
        except OSError as exc:
            errors.append(f"unable to read nested AGENTS.md: {relative_path}: {exc}")
            continue
        if size > NESTED_AGENTS_MAX_BYTES:
            errors.append(f"{relative_path} is {size} bytes; limit is {NESTED_AGENTS_MAX_BYTES} bytes")
        if any(section in text for section in root_sections):
            errors.append(f"{relative_path} duplicates a root AGENTS.md section")
    return errors


def _run_hook(hook_path: Path, root: Path, payload: dict[str, Any]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(hook_path)],
        cwd=root,
        input=json.dumps(payload),
        capture_output=True,
        check=False,
        text=True,
    )


def _validate_hook(root: Path) -> list[str]:
    errors: list[str] = []
    hook_path = root / ".codex" / "hooks" / "post-commit-check.sh"
    if not hook_path.is_file():
        return [f"missing hook: {hook_path.relative_to(root)}"]
    if not os.access(hook_path, os.X_OK):
        errors.append(f"hook is not executable: {hook_path.relative_to(root)}")

    success = _run_hook(
        hook_path,
        root,
        {
            "tool_name": "Bash",
            "tool_input": {"command": "git commit -m 'test: validate hook'"},
            "tool_response": {"exit_code": 0, "output": "[main abc1234] test: validate hook"},
        },
    )
    if success.returncode != 0:
        errors.append(f"post-commit hook exited with {success.returncode}")
    else:
        try:
            response = json.loads(success.stdout)
            context = response["hookSpecificOutput"]["additionalContext"]
        except (json.JSONDecodeError, KeyError, TypeError):
            errors.append("post-commit hook did not emit valid additionalContext JSON")
        else:
            if "update-codex-md" not in context or "AGENTS.md" not in context:
                errors.append("post-commit hook does not route to update-codex-md and AGENTS.md")
            if "CLAUDE.md" in context:
                errors.append("post-commit hook still routes Codex work to CLAUDE.md")

    failed = _run_hook(
        hook_path,
        root,
        {
            "tool_name": "Bash",
            "tool_input": {"command": "git commit -m 'test: failed hook'"},
            "tool_response": {"exit_code": 1, "output": "commit failed"},
        },
    )
    if failed.returncode != 0 or failed.stdout:
        errors.append("post-commit hook must stay silent for failed commits")

    return errors


def _validate_rules(root: Path) -> list[str]:
    rules_path = root / ".codex" / "rules" / "default.rules"
    try:
        rules_text = rules_path.read_text(encoding="utf-8")
    except OSError as exc:
        return [f"unable to read .codex/rules/default.rules: {exc}"]

    errors: list[str] = []
    for prefix in REQUIRED_RULE_PREFIXES:
        rendered = ", ".join(json.dumps(token) for token in prefix)
        marker = f"pattern = [{rendered}]"
        marker_index = rules_text.find(marker)
        if marker_index == -1:
            errors.append(f"missing allow rule: {' '.join(prefix)}")
            continue
        rule_end = rules_text.find("\n)", marker_index)
        rule_block = rules_text[marker_index:] if rule_end == -1 else rules_text[marker_index:rule_end]
        if 'decision = "allow"' not in rule_block:
            errors.append(f"rule is not allow: {' '.join(prefix)}")
    return errors


def _validate_skill(root: Path) -> list[str]:
    skill_path = root / ".agents" / "skills" / "update-codex-md" / "SKILL.md"
    try:
        skill_text = skill_path.read_text(encoding="utf-8")
    except OSError as exc:
        return [f"unable to read update-codex-md skill: {exc}"]

    errors: list[str] = []
    frontmatter = skill_text.split("---", 2)
    if len(frontmatter) < 3 or "name: update-codex-md" not in frontmatter[1].splitlines():
        errors.append("update-codex-md skill has an invalid frontmatter name")
    if "CLAUDE.md" in skill_text:
        errors.append("update-codex-md skill must not route work to CLAUDE.md")
    return errors


def source_inventory_errors(root: Path) -> list[str]:
    """Return source-consolidation errors without inspecting skill body content."""
    wrapper = root / ".cursor" / "skills" / "update-claude-md" / "SKILL.md"
    if not wrapper.is_file():
        return []
    canonicals = (
        root / ".agents" / "skills" / "update-codex-md" / "SKILL.md",
        root / ".claude" / "skills" / "update-claude-md" / "SKILL.md",
    )
    errors = [
        f"missing canonical skill for Cursor wrapper: {path.relative_to(root)}"
        for path in canonicals
        if not path.is_file()
    ]
    if not errors and wrapper_has_long_duplicate(wrapper, canonicals):
        errors.append("Cursor wrapper duplicates more than five canonical skill body lines")
    return errors


def _validate_enforcement(root: Path) -> list[str]:
    required_fragments = {
        root / ".pre-commit-config.yaml": ("id: agent-environment",),
        root / ".github" / "workflows" / "verify.yml": (
            "pre-commit run agent-environment --all-files",
            "python scripts/validate_agent_environment.py",
        ),
    }
    errors: list[str] = []
    for path, fragments in required_fragments.items():
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            errors.append(f"unable to read {path.relative_to(root)}: {exc}")
            continue
        for fragment in fragments:
            if fragment not in text:
                errors.append(f"{path.relative_to(root)} is missing: {fragment}")
    return errors


def _validate_project_roles(root: Path) -> list[str]:
    config_path = root / ".codex" / "config.toml"
    try:
        config = tomllib.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        return [f"invalid .codex/config.toml: {exc}"]

    agents = config.get("agents")
    if not isinstance(agents, dict):
        return [".codex/config.toml must declare agents"]

    errors: list[str] = []
    for role_name, required_fragments in PROJECT_ROLES.items():
        role_definition = agents.get(role_name)
        if not isinstance(role_definition, dict):
            errors.append(f"missing project role: {role_name}")
            continue
        config_file = role_definition.get("config_file")
        expected_config_file = f"agents/{role_name}.toml"
        if config_file != expected_config_file:
            errors.append(f"{role_name} role must use config_file {expected_config_file}")
            continue

        role_path = config_path.parent / config_file
        try:
            role = tomllib.loads(role_path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as exc:
            errors.append(f"invalid {role_name} role configuration: {exc}")
            continue
        missing_keys = sorted(REQUIRED_ROLE_TOML_KEYS - role.keys())
        if missing_keys:
            errors.append(f"{role_name} role is missing required keys: {', '.join(missing_keys)}")
        unexpected_keys = sorted(role.keys() - REQUIRED_ROLE_TOML_KEYS)
        if unexpected_keys:
            errors.append(f"{role_name} role has unexpected keys: {', '.join(unexpected_keys)}")
        if role.get("model") != "gpt-5.6-luna":
            errors.append(f"{role_name} role must set model to gpt-5.6-luna")
        if role.get("model_reasoning_effort") != "medium":
            errors.append(f"{role_name} role must set model_reasoning_effort to medium")
        instruction_file = role.get("model_instructions_file")
        expected_instruction_file = f"{role_name}.md"
        if instruction_file != expected_instruction_file:
            errors.append(f"{role_name} role must use model_instructions_file {expected_instruction_file}")
            continue

        instruction_path = role_path.parent / instruction_file
        try:
            instruction_text = instruction_path.read_text(encoding="utf-8")
        except OSError as exc:
            errors.append(f"unable to read {role_name} role instructions: {exc}")
            continue
        if len(instruction_text.splitlines()) > 20:
            errors.append(f"{role_name} role instructions exceed 20 lines")
        for fragment in required_fragments:
            if fragment not in instruction_text:
                errors.append(f"{role_name} role instructions are missing: {fragment}")
    return errors


def _validate_codex_gitignore(root: Path) -> list[str]:
    ignore_path = root / ".gitignore"
    try:
        entries = set(ignore_path.read_text(encoding="utf-8").splitlines())
    except OSError as exc:
        return [f"unable to read .gitignore: {exc}"]
    return [f".gitignore is missing: {entry}" for entry in REQUIRED_CODEX_GITIGNORE_ENTRIES if entry not in entries]


def validate_repository(root: Path) -> list[str]:
    """Return actionable validation errors for the repository agent setup."""
    errors: list[str] = []
    agents_path = root / "AGENTS.md"
    try:
        agents_size = agents_path.stat().st_size
    except FileNotFoundError:
        errors.append("missing root AGENTS.md")
    else:
        if agents_size > AGENTS_MAX_BYTES:
            errors.append(f"AGENTS.md is {agents_size} bytes; limit is {AGENTS_MAX_BYTES} bytes")
        errors.extend(_validate_root_guide(root, agents_path))
        try:
            root_text = agents_path.read_text(encoding="utf-8")
        except OSError:
            root_text = ""
        errors.extend(_validate_nested_guides(root, root_text))

    required_paths = (
        root / ".codex" / "hooks.json",
        root / ".codex" / "rules" / "default.rules",
        root / ".agents" / "skills" / "update-codex-md" / "SKILL.md",
        root / ".github" / "workflows" / "verify.yml",
    )
    for path in required_paths:
        if not path.is_file():
            errors.append(f"missing agent environment file: {path.relative_to(root)}")

    hooks_config = root / ".codex" / "hooks.json"
    if hooks_config.is_file():
        try:
            config_text = hooks_config.read_text(encoding="utf-8")
            config = json.loads(config_text)
        except (OSError, json.JSONDecodeError) as exc:
            errors.append(f"invalid .codex/hooks.json: {exc}")
        else:
            if str(root) in config_text:
                errors.append(".codex/hooks.json contains an absolute repository path")
            command_strings = [
                hook.get("command", "")
                for group in config.get("hooks", {}).get("PostToolUse", [])
                if isinstance(group, dict)
                for hook in group.get("hooks", [])
                if isinstance(hook, dict)
            ]
            if not any(".codex/hooks/post-commit-check.sh" in command for command in command_strings):
                errors.append("PostToolUse config does not invoke the tracked hook")
            if any(command.lstrip().startswith("/") for command in command_strings):
                errors.append("PostToolUse command contains an absolute executable path")
            matchers = [
                group.get("matcher", "")
                for group in config.get("hooks", {}).get("PostToolUse", [])
                if isinstance(group, dict)
            ]
            if not any("exec_command" in matcher for matcher in matchers):
                errors.append("PostToolUse hook does not match exec_command")

    errors.extend(_validate_rules(root))
    errors.extend(_validate_skill(root))
    errors.extend(source_inventory_errors(root))
    errors.extend(_validate_enforcement(root))
    errors.extend(_validate_hook(root))
    errors.extend(_validate_project_roles(root))
    errors.extend(_validate_codex_gitignore(root))
    return errors


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    root = Path(__file__).resolve().parents[1]
    errors = validate_repository(root)
    if errors:
        for error in errors:
            LOGGER.error(error)
        return 1
    LOGGER.info("Agent environment validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
