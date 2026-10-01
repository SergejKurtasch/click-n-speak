from __future__ import annotations

import json
import subprocess
from pathlib import Path

import tomllib

from scripts.validate_agent_environment import validate_repository

PROJECT_ROOT = Path(__file__).resolve().parents[1]
HOOK_PATH = PROJECT_ROOT / ".codex" / "hooks" / "post-commit-check.sh"


def _write_minimal_agent_environment(root: Path) -> None:
    """Create the files required by the validator in an isolated repository."""
    (root / "AGENTS.md").write_text("# Agent Guide\n", encoding="utf-8")
    (root / ".gitignore").write_text(
        ".codex/*\n!.codex/config.toml\n!.codex/agents/\n!.codex/agents/**\n",
        encoding="utf-8",
    )
    (root / ".codex" / "hooks").mkdir(parents=True)
    (root / ".codex" / "rules").mkdir(parents=True)
    (root / ".agents" / "skills" / "update-codex-md").mkdir(parents=True)
    (root / ".github" / "workflows").mkdir(parents=True)

    hook_path = root / ".codex" / "hooks" / "post-commit-check.sh"
    hook_path.write_text(
        "#!/bin/sh\n"
        "payload=$(cat)\n"
        'case "$payload" in\n'
        "  *'\"exit_code\": 0'*)\n"
        '    printf \'%s\\n\' \'{"hookSpecificOutput": {"additionalContext": '
        '"update-codex-md AGENTS.md"}}\'\n'
        "    ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    hook_path.chmod(0o755)
    (root / ".codex" / "hooks.json").write_text(
        '{"hooks":{"PostToolUse":[{"matcher":"Bash|exec_command",'
        '"hooks":[{"command":".codex/hooks/post-commit-check.sh"}]}]}}',
        encoding="utf-8",
    )
    rules = "\n".join(
        f'pattern = [{", ".join(json.dumps(token) for token in prefix)}]\ndecision = "allow"\n)'
        for prefix in (
            ("swift", "test"),
            ("bash", "scripts/swift_verify.sh"),
            ("bash", "scripts/swift_build_app.sh"),
            ("venv/bin/python", "-m", "pytest"),
            ("venv/bin/python", "scripts/validate_agent_environment.py"),
        )
    )
    (root / ".codex" / "rules" / "default.rules").write_text(rules, encoding="utf-8")
    (root / ".agents" / "skills" / "update-codex-md" / "SKILL.md").write_text(
        "---\nname: update-codex-md\n---\n",
        encoding="utf-8",
    )
    (root / ".pre-commit-config.yaml").write_text("id: agent-environment\n", encoding="utf-8")
    (root / ".github" / "workflows" / "verify.yml").write_text(
        "pre-commit run agent-environment --all-files\npython scripts/validate_agent_environment.py\n",
        encoding="utf-8",
    )
    agents_directory = root / ".codex" / "agents"
    agents_directory.mkdir(parents=True)
    (root / ".codex" / "config.toml").write_text(
        "[agents.researcher]\n"
        "description = 'Research role'\n"
        "config_file = 'agents/researcher.toml'\n\n"
        "[agents.implementer]\n"
        "description = 'Implementation role'\n"
        "config_file = 'agents/implementer.toml'\n\n"
        "[agents.reviewer]\n"
        "description = 'Review role'\n"
        "config_file = 'agents/reviewer.toml'\n",
        encoding="utf-8",
    )
    for role_name in ("researcher", "implementer", "reviewer"):
        (agents_directory / f"{role_name}.toml").write_text(
            f"model = 'gpt-5.6-luna'\nmodel_reasoning_effort = 'medium'\nmodel_instructions_file = '{role_name}.md'\n",
            encoding="utf-8",
        )
    (agents_directory / "researcher.md").write_text(
        "# Researcher\n\nOutput contract:\n- Findings\n- Evidence path or URL\n- uncertainties\n- no edits\n",
        encoding="utf-8",
    )
    (agents_directory / "implementer.md").write_text(
        "# Implementer\n\nOutput contract:\n- Changed files\n- Verification commands\n- Residual risks\n",
        encoding="utf-8",
    )
    (agents_directory / "reviewer.md").write_text(
        "# Reviewer\n\nOutput contract:\n- Findings ordered by severity\n- file:line\n- Test gaps\n- no edits\n",
        encoding="utf-8",
    )
    for relative_path in (
        "ClickNSpeak/AGENTS.md",
        "Packages/AGENTS.md",
        "Packages/CNSSession/AGENTS.md",
        "Packages/CNSDictionary/AGENTS.md",
        "src/AGENTS.md",
        "scripts/AGENTS.md",
        "tests/AGENTS.md",
    ):
        guide_path = root / relative_path
        guide_path.parent.mkdir(parents=True, exist_ok=True)
        guide_path.write_text("# Scoped Guide\n", encoding="utf-8")


def _run_hook(payload: dict[str, object]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(HOOK_PATH)],
        cwd=PROJECT_ROOT,
        input=json.dumps(payload),
        capture_output=True,
        check=False,
        text=True,
    )


def test_repository_agent_environment_is_consistent() -> None:
    assert validate_repository(PROJECT_ROOT) == []


def test_project_roles_are_luna_medium() -> None:
    config = tomllib.loads((PROJECT_ROOT / ".codex/config.toml").read_text(encoding="utf-8"))
    for role_name in ("researcher", "implementer", "reviewer"):
        role_path = PROJECT_ROOT / ".codex" / config["agents"][role_name]["config_file"]
        role = tomllib.loads(role_path.read_text(encoding="utf-8"))
        assert role["model"] == "gpt-5.6-luna"
        assert role["model_reasoning_effort"] == "medium"


def test_validator_rejects_role_with_wrong_reasoning_effort(tmp_path: Path) -> None:
    _write_minimal_agent_environment(tmp_path)
    (tmp_path / ".codex" / "agents" / "reviewer.toml").write_text(
        "model = 'gpt-5.6-luna'\nmodel_reasoning_effort = 'high'\nmodel_instructions_file = 'reviewer.md'\n",
        encoding="utf-8",
    )

    assert "reviewer role must set model_reasoning_effort to medium" in validate_repository(tmp_path)


def test_validator_rejects_role_with_wrong_model(tmp_path: Path) -> None:
    _write_minimal_agent_environment(tmp_path)
    (tmp_path / ".codex" / "agents" / "researcher.toml").write_text(
        "model = 'gpt-5.6-sol'\nmodel_reasoning_effort = 'medium'\nmodel_instructions_file = 'researcher.md'\n",
        encoding="utf-8",
    )

    assert "researcher role must set model to gpt-5.6-luna" in validate_repository(tmp_path)


def test_validator_rejects_role_with_wrong_instruction_file(tmp_path: Path) -> None:
    _write_minimal_agent_environment(tmp_path)
    (tmp_path / ".codex" / "agents" / "reviewer.toml").write_text(
        "model = 'gpt-5.6-luna'\nmodel_reasoning_effort = 'medium'\nmodel_instructions_file = 'other.md'\n",
        encoding="utf-8",
    )

    assert "reviewer role must use model_instructions_file reviewer.md" in validate_repository(tmp_path)


def test_validator_rejects_missing_role_output_contract(tmp_path: Path) -> None:
    _write_minimal_agent_environment(tmp_path)
    (tmp_path / ".codex" / "agents" / "implementer.md").write_text(
        "# Implementer\n\nOutput contract:\n- Changed files\n- Verification commands\n",
        encoding="utf-8",
    )

    assert "implementer role instructions are missing: Residual risks" in validate_repository(tmp_path)


def test_validator_rejects_role_instructions_over_twenty_lines(tmp_path: Path) -> None:
    _write_minimal_agent_environment(tmp_path)
    instruction_path = tmp_path / ".codex" / "agents" / "researcher.md"
    instruction_path.write_text("\n".join("line" for _ in range(21)), encoding="utf-8")

    assert "researcher role instructions exceed 20 lines" in validate_repository(tmp_path)


def test_validator_rejects_missing_role_toml_key(tmp_path: Path) -> None:
    _write_minimal_agent_environment(tmp_path)
    (tmp_path / ".codex" / "agents" / "implementer.toml").write_text(
        "model = 'gpt-5.6-luna'\nmodel_instructions_file = 'implementer.md'\n",
        encoding="utf-8",
    )

    assert "implementer role is missing required keys: model_reasoning_effort" in validate_repository(tmp_path)


def test_validator_rejects_extra_role_toml_key(tmp_path: Path) -> None:
    _write_minimal_agent_environment(tmp_path)
    (tmp_path / ".codex" / "agents" / "researcher.toml").write_text(
        "model = 'gpt-5.6-luna'\n"
        "model_reasoning_effort = 'medium'\n"
        "model_instructions_file = 'researcher.md'\n"
        "extra_override = 'disallowed'\n",
        encoding="utf-8",
    )

    assert "researcher role has unexpected keys: extra_override" in validate_repository(tmp_path)


def test_validator_requires_narrow_codex_ignore_exceptions(tmp_path: Path) -> None:
    _write_minimal_agent_environment(tmp_path)
    (tmp_path / ".gitignore").write_text(".codex/*\n", encoding="utf-8")

    assert ".gitignore is missing: !.codex/agents/**" in validate_repository(tmp_path)


def test_validator_rejects_missing_local_markdown_target(tmp_path: Path) -> None:
    _write_minimal_agent_environment(tmp_path)
    (tmp_path / "AGENTS.md").write_text(
        "Read [runtime](docs/architecture/missing.md).\n",
        encoding="utf-8",
    )

    assert "missing AGENTS.md link: docs/architecture/missing.md" in validate_repository(tmp_path)


def test_validator_rejects_historical_roadmap_in_root_guide(tmp_path: Path) -> None:
    _write_minimal_agent_environment(tmp_path)
    (tmp_path / "AGENTS.md").write_text(
        "## Phase 17 completed roadmap\n",
        encoding="utf-8",
    )

    assert "AGENTS.md contains historical roadmap detail" in validate_repository(tmp_path)


def test_validator_rejects_duplicate_canonical_command(tmp_path: Path) -> None:
    _write_minimal_agent_environment(tmp_path)
    (tmp_path / "AGENTS.md").write_text(
        "venv/bin/python -m pytest <test-path> -q\nvenv/bin/python -m pytest <test-path> -q\n",
        encoding="utf-8",
    )

    assert (
        "AGENTS.md duplicates canonical verification command: venv/bin/python -m pytest <test-path> -q"
    ) in validate_repository(tmp_path)


def test_hooks_config_invokes_tracked_hook_portably() -> None:
    config = json.loads((PROJECT_ROOT / ".codex/hooks.json").read_text(encoding="utf-8"))
    command = config["hooks"]["PostToolUse"][0]["hooks"][0]["command"]
    payload = {
        "tool_name": "Bash",
        "tool_input": {"command": "git commit -m 'fix: configured hook'"},
        "tool_response": {"exit_code": 0, "output": "[main abc1234] fix: configured hook"},
    }

    result = subprocess.run(
        command,
        cwd=PROJECT_ROOT,
        input=json.dumps(payload),
        capture_output=True,
        check=False,
        shell=True,
        text=True,
    )

    assert not command.lstrip().startswith("/")
    assert result.returncode == 0
    assert "update-codex-md" in json.loads(result.stdout)["hookSpecificOutput"]["additionalContext"]


def test_post_commit_hook_supports_exec_command_payload() -> None:
    result = _run_hook(
        {
            "tool_name": "exec_command",
            "tool_input": {"cmd": "git commit -m 'fix: example'"},
            "tool_response": {"exit_code": 0, "output": "[main abc1234] fix: example"},
        }
    )

    assert result.returncode == 0
    response = json.loads(result.stdout)
    context = response["hookSpecificOutput"]["additionalContext"]
    assert "update-codex-md" in context
    assert "AGENTS.md" in context
    assert "CLAUDE.md" not in context


def test_post_commit_hook_supports_canonical_bash_payload() -> None:
    result = _run_hook(
        {
            "tool_name": "Bash",
            "tool_input": {"command": "git commit -m 'fix: canonical hook'"},
            "tool_response": {
                "exit_code": 0,
                "output": "[main abc1234] fix: canonical hook",
            },
        }
    )

    assert result.returncode == 0
    response = json.loads(result.stdout)
    assert "update-codex-md" in response["hookSpecificOutput"]["additionalContext"]


def test_post_commit_hook_ignores_failed_commit() -> None:
    result = _run_hook(
        {
            "tool_name": "exec_command",
            "tool_input": {"cmd": "git commit -m 'fix: example'"},
            "tool_response": {"exit_code": 1, "output": "commit failed"},
        }
    )

    assert result.returncode == 0
    assert result.stdout == ""


def test_post_commit_hook_ignores_response_without_exit_code() -> None:
    result = _run_hook(
        {
            "tool_name": "Bash",
            "tool_input": {"command": "git commit -m 'fix: unknown result'"},
            "tool_response": {"output": "[main abc1234] fix: unknown result"},
        }
    )

    assert result.returncode == 0
    assert result.stdout == ""


def test_post_commit_hook_ignores_commit_tree() -> None:
    result = _run_hook(
        {
            "tool_name": "exec_command",
            "tool_input": {"cmd": "git commit-tree HEAD^{tree}"},
            "tool_response": {"exit_code": 0, "output": "abc1234"},
        }
    )

    assert result.returncode == 0
    assert result.stdout == ""
