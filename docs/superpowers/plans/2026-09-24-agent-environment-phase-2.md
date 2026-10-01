# Agent Environment Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Сделать контекст Codex для Click-n-speak компактным, специализированным, воспроизводимым и измеримым без загрузки исторических деталей в каждую задачу.

**Architecture:** Корневой `AGENTS.md` остаётся небольшим контрактом, а детали маршрутизируются в узкие документы и role-профили. Репозиторные валидаторы проверяют контекст, инструменты и безопасную конфигурацию; отдельный privacy-safe аудит измеряет эффект по метаданным сессий.

**Tech Stack:** Python 3.11+, `pathlib`, `tomllib`, `unittest`/pytest, Codex TOML configuration, shell hooks, Homebrew Bundle, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-24-agent-environment-phase-2-design.md`

## Global Constraints

- Не менять продуктовый runtime в `ClickNSpeak/`, `Packages/` или `src/`.
- Не записывать тексты сообщений, prompts, команды, tool outputs или credentials в отчёты.
- Не удалять skills, sessions или global config автоматически; сначала dry-run и ручной review.
- `AGENTS.md` должен оставаться не больше 16,384 bytes.
- Python запускать через `venv/bin/python`; Swift/Git/shell не оборачивать в activation venv.
- Каждый task заканчивается отдельным проверяемым результатом и Conventional Commit.

---

### Task 1: Enforce the context contract and split durable detail

**Files:**
- Create: `docs/architecture/runtime-ownership.md`
- Create: `docs/architecture/safety-invariants.md`
- Create: `docs/operations/verification.md`
- Create: `ClickNSpeak/AGENTS.md`
- Create: `Packages/AGENTS.md`
- Create: `Packages/CNSSession/AGENTS.md`
- Create: `Packages/CNSDictionary/AGENTS.md`
- Create: `src/AGENTS.md`
- Create: `scripts/AGENTS.md`
- Create: `tests/AGENTS.md`
- Modify: `AGENTS.md`
- Modify: `scripts/validate_agent_environment.py`
- Modify: `tests/test_agent_environment.py`

**Interfaces:**
- Consumes: `validate_repository(root: Path) -> list[str]`.
- Produces: `extract_markdown_targets(text: str) -> tuple[str, ...]` and a root-guide contract that rejects missing local links, oversized content, duplicate canonical commands, and historical roadmap language.

- [ ] **Step 1: Write failing contract tests**

Add tests using temporary repositories, so failures do not depend on the live checkout:

```python
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
```

- [ ] **Step 2: Run the focused tests and confirm RED**

Run:

```bash
venv/bin/python -m pytest tests/test_agent_environment.py -q
```

Expected: both new tests fail because local-link and historical-marker checks do not exist.

- [ ] **Step 3: Add the minimal validator behavior**

Implement deterministic Markdown target extraction and repository-local resolution:

```python
MARKDOWN_LINK = re.compile(r"\[[^\]]+\]\((?!https?://|#)([^)]+\.md)\)")
HISTORICAL_ROOT_MARKERS = ("completed roadmap", "known latency profile", "phase 17")


def extract_markdown_targets(text: str) -> tuple[str, ...]:
    """Return unique repository-local Markdown targets in source order."""
    return tuple(dict.fromkeys(MARKDOWN_LINK.findall(text)))
```

For each extracted target, resolve from repository root and reject missing files. Compare historical markers case-insensitively. Keep `AGENTS_MAX_BYTES = 16 * 1024`.

- [ ] **Step 4: Add subtree-scoped guides**

Keep every nested guide below 4,096 bytes and include only constraints unique
to that subtree:

- `ClickNSpeak/AGENTS.md`: AppKit lifecycle, composition root, packaging.
- `Packages/AGENTS.md`: Swift package boundaries and shared protocol rules.
- `Packages/CNSSession/AGENTS.md`: state machine, activity ownership, delivery.
- `Packages/CNSDictionary/AGENTS.md`: persistence, acknowledgements, correction learning.
- `src/AGENTS.md`: Python compatibility/parity and main-thread boundaries.
- `scripts/AGENTS.md`: safe build/acceptance entrypoints and opt-in model suites.
- `tests/AGENTS.md`: fixture ownership, deterministic tests, no real models by default.

Extend the validator to reject a nested guide above 4,096 bytes or one that
duplicates the root `Working rules` or `Canonical verification commands`
sections verbatim.

- [ ] **Step 5: Move durable detail into focused documents**

Write the three documents with these exact responsibilities:

- `runtime-ownership.md`: composition roots, service ownership, snapshot lifetimes, activity exclusivity.
- `safety-invariants.md`: startup validation, transaction boundaries, telemetry privacy, model/update recovery.
- `verification.md`: fast tests, full verification, release build, real-model opt-in gates, failure triage.

Replace detail in `AGENTS.md` with task-routing links only. Do not copy the archived 69 KB snapshot wholesale.

- [ ] **Step 6: Verify size, links, and tests**

Run:

```bash
wc -c AGENTS.md
venv/bin/python scripts/validate_agent_environment.py
venv/bin/python -m pytest tests/test_agent_environment.py -q
```

Expected: size at or below 16,384 bytes; validator exits 0; tests pass.

- [ ] **Step 7: Commit the documentation contract**

```bash
git add AGENTS.md ClickNSpeak/AGENTS.md Packages/AGENTS.md Packages/CNSSession/AGENTS.md Packages/CNSDictionary/AGENTS.md src/AGENTS.md scripts/AGENTS.md tests/AGENTS.md docs/architecture docs/operations scripts/validate_agent_environment.py tests/test_agent_environment.py
git commit -m "docs: route agent context to focused guides"
```

---

### Task 2: Add role-scoped Luna subagents

**Files:**
- Create: `.codex/config.toml`
- Create: `.codex/agents/researcher.toml`
- Create: `.codex/agents/implementer.toml`
- Create: `.codex/agents/reviewer.toml`
- Create: `.codex/agents/researcher.md`
- Create: `.codex/agents/implementer.md`
- Create: `.codex/agents/reviewer.md`
- Modify: `.gitignore`
- Modify: `scripts/validate_agent_environment.py`
- Modify: `tests/test_agent_environment.py`

**Interfaces:**
- Consumes: Codex `agents.<name>.description` and `agents.<name>.config_file` project configuration.
- Produces: three selectable roles whose config layers set `model = "gpt-5.6-luna"`, `model_reasoning_effort = "medium"`, and `model_instructions_file` to the matching Markdown file.

- [ ] **Step 1: Write failing role-schema tests**

```python
def test_project_roles_are_luna_medium() -> None:
    config = tomllib.loads((PROJECT_ROOT / ".codex/config.toml").read_text(encoding="utf-8"))
    for role_name in ("researcher", "implementer", "reviewer"):
        role_path = PROJECT_ROOT / config["agents"][role_name]["config_file"]
        role = tomllib.loads(role_path.read_text(encoding="utf-8"))
        assert role["model"] == "gpt-5.6-luna"
        assert role["model_reasoning_effort"] == "medium"
```

- [ ] **Step 2: Confirm RED**

Run `venv/bin/python -m pytest tests/test_agent_environment.py::test_project_roles_are_luna_medium -q`.

Expected: fail because `.codex/config.toml` does not exist.

- [ ] **Step 3: Declare the roles**

Create `.codex/config.toml`:

```toml
[agents.researcher]
description = "Read-only evidence collection with explicit sources and uncertainties."
config_file = "agents/researcher.toml"

[agents.implementer]
description = "Bounded implementation with tests, preserved user changes, and concise handoff."
config_file = "agents/implementer.toml"

[agents.reviewer]
description = "Independent correctness review ordered by severity with file and line evidence."
config_file = "agents/reviewer.toml"
```

Each role TOML contains:

```toml
model = "gpt-5.6-luna"
model_reasoning_effort = "medium"
model_instructions_file = "researcher.md"
```

Use the matching Markdown filename for each role.

- [ ] **Step 4: Write minimal role instructions**

Limit each file to 20 lines. Require these outputs:

- Researcher: findings, evidence path/URL, uncertainty, no edits.
- Implementer: changed files, verification commands/results, residual risk.
- Reviewer: severity-ordered findings with file:line, then test gaps; no edits unless requested.

Do not repeat language, Git, venv, or project-map rules already in `AGENTS.md`.

- [ ] **Step 5: Validate the effective configuration**

Run:

```bash
/Applications/ChatGPT.app/Contents/Resources/codex features list
venv/bin/python -m pytest tests/test_agent_environment.py -q
```

Expected: Codex parses user plus project config; all role tests pass.

- [ ] **Step 6: Commit role-scoped configuration**

```bash
git add .codex/config.toml .codex/agents .gitignore scripts/validate_agent_environment.py tests/test_agent_environment.py
git commit -m "chore: add focused subagent roles"
```

---

### Task 3: Make the local toolchain reproducible and fail fast

**Files:**
- Create: `Brewfile`
- Create: `scripts/check_dev_environment.py`
- Create: `tests/test_check_dev_environment.py`
- Modify: `scripts/build.sh`
- Create: `tests/test_legacy_build_guard.py`
- Modify: `.pre-commit-config.yaml`
- Modify: `.github/workflows/verify.yml`
- Modify: `docs/operations/verification.md`

**Interfaces:**
- Produces: `check_environment(root: Path, which: Callable[[str], str | None]) -> list[str]`.
- Checks: `rg`, `swift`, `git`, `venv/bin/python`, `venv/bin/pre-commit`, and a parseable Codex config.

- [ ] **Step 1: Write a missing-tool test**

```python
def test_check_environment_reports_missing_ripgrep(tmp_path: Path) -> None:
    (tmp_path / "venv/bin").mkdir(parents=True)
    (tmp_path / "venv/bin/python").touch()
    (tmp_path / "venv/bin/pre-commit").touch()

    errors = check_environment(tmp_path, lambda command: None if command == "rg" else f"/bin/{command}")

    assert "missing command: rg; install with `brew bundle`" in errors
```

- [ ] **Step 2: Confirm RED**

Run `venv/bin/python -m pytest tests/test_check_dev_environment.py -q`.

Expected: import failure because the doctor does not exist.

- [ ] **Step 3: Implement the read-only doctor**

Use `shutil.which`, `Path.is_file`, `subprocess.run(..., check=False)`, and `logging`. Never install packages or print environment values. Return one error per missing dependency and exit 1 when non-empty.

- [ ] **Step 4: Declare ripgrep**

Create `Brewfile`:

```ruby
brew "ripgrep"
```

Document `brew bundle` as setup and `venv/bin/python scripts/check_dev_environment.py` as the first diagnostic command.

- [ ] **Step 5: Guard the destructive legacy Python build**

Before any `xattr`, `chmod`, or `rm`, resolve `REPO_ROOT` from the script
location and require `CNS_ALLOW_LEGACY_CLEAN=1`. Use absolute targets derived
from `REPO_ROOT`; never clean from the caller's current directory.

Add this regression test:

```python
def test_legacy_build_refuses_cleanup_without_explicit_opt_in() -> None:
    sentinel = PROJECT_ROOT / "build" / "agent-guard-sentinel"
    sentinel.parent.mkdir(exist_ok=True)
    sentinel.write_text("preserve", encoding="utf-8")
    try:
        result = subprocess.run(
            ["bash", "scripts/build.sh"],
            cwd=PROJECT_ROOT,
            capture_output=True,
            check=False,
            text=True,
            env={
                key: value
                for key, value in os.environ.items()
                if key != "CNS_ALLOW_LEGACY_CLEAN"
            },
        )
        assert result.returncode == 2
        assert "CNS_ALLOW_LEGACY_CLEAN=1" in result.stderr
        assert sentinel.is_file()
    finally:
        sentinel.unlink(missing_ok=True)
```

Document `scripts/build.sh` as legacy Python packaging. The canonical Swift
build remains `bash scripts/swift_build_app.sh release` and must not require
this opt-in.

- [ ] **Step 6: Wire the doctor into pre-commit and CI**

Add a local pre-commit hook with `language: system`, `pass_filenames: false`, and entry `venv/bin/python scripts/check_dev_environment.py`. In CI, run the same script before repository-contract tests; install ripgrep on Ubuntu with `sudo apt-get install -y ripgrep`.

- [ ] **Step 7: Verify without mutating product files**

```bash
venv/bin/python -m pytest tests/test_check_dev_environment.py -q
venv/bin/python -m pytest tests/test_legacy_build_guard.py -q
venv/bin/python scripts/check_dev_environment.py
venv/bin/pre-commit validate-config
```

Expected: all pass and `rg --version` resolves.

- [ ] **Step 8: Commit the toolchain preflight**

```bash
git add Brewfile scripts/check_dev_environment.py scripts/build.sh tests/test_check_dev_environment.py tests/test_legacy_build_guard.py .pre-commit-config.yaml .github/workflows/verify.yml docs/operations/verification.md
git commit -m "chore: add agent toolchain preflight"
```

---

### Task 4: Consolidate skills and instruction sources safely

**Files:**
- Create: `scripts/audit_codex_sources.py`
- Create: `tests/fixtures/codex_sources/`
- Create: `tests/test_audit_codex_sources.py`
- Create: `docs/operations/codex-source-inventory.md`
- Modify: `scripts/validate_agent_environment.py`
- Modify: `.claude/skills/update-claude-md/SKILL.md`
- Modify: `.cursor/skills/update-claude-md/SKILL.md`
- External review: `/Users/sergej/.codex/config.toml`
- External review: `/Users/sergej/.codex/AGENTS.md`
- External review: `/Users/sergej/AGENTS.md`

**Interfaces:**
- Produces: `inventory_skills(roots: Sequence[Path]) -> tuple[SkillRecord, ...]` where `SkillRecord` contains `name`, `path`, and SHA-256 digest.
- Produces: `find_duplicate_names(records: Sequence[SkillRecord]) -> dict[str, tuple[SkillRecord, ...]]`.

- [ ] **Step 1: Build a duplicate-skill fixture and failing test**

```python
def test_duplicate_names_group_different_sources(fixture_roots: tuple[Path, Path]) -> None:
    records = inventory_skills(fixture_roots)
    duplicates = find_duplicate_names(records)

    assert tuple(record.path for record in duplicates["cloudflare"]) == (
        fixture_roots[0] / "cloudflare/SKILL.md",
        fixture_roots[1] / "cloudflare/SKILL.md",
    )
```

- [ ] **Step 2: Confirm RED, then implement the inventory**

Run `venv/bin/python -m pytest tests/test_audit_codex_sources.py -q` and confirm import failure. Implement YAML-frontmatter name extraction without adding a YAML dependency: read only the leading `---` block and parse the single `name:` scalar.

- [ ] **Step 3: Generate a reviewable inventory**

Run:

```bash
venv/bin/python scripts/audit_codex_sources.py \
  --skill-root /Users/sergej/.codex/skills \
  --skill-root /Users/sergej/.agents/skills \
  --output /private/tmp/click-n-speak-skill-inventory.json
```

Expected: JSON contains paths, names, and digests only; no skill body text.

- [ ] **Step 4: Choose one canonical source per duplicate**

Record each decision in `docs/operations/codex-source-inventory.md`. Prefer system/project skills first, then one user root. Disable redundant user entries through `skills.config` in `~/.codex/config.toml`; do not delete directories in this task.

- [ ] **Step 5: Consolidate global instruction files**

Diff `/Users/sergej/.codex/AGENTS.md` and `/Users/sergej/AGENTS.md`. Copy any unique durable rule into the global guide, back up the parent file outside the repository, then remove the parent copy only after a fresh Codex prompt shows one global block and one project block.

- [ ] **Step 6: Reduce Claude and Cursor copies to thin wrappers**

Keep `.agents/skills/update-codex-md/SKILL.md` canonical for Codex. Make the
Claude skill explicitly own `CLAUDE.md`; make the Cursor skill a short wrapper
that delegates to the Claude skill without copying its decision checklist.
Add a source-inventory check that fails if the wrapper body duplicates more
than five consecutive non-frontmatter lines from either canonical skill.

- [ ] **Step 7: Verify no duplicate effective sources**

```bash
/Applications/ChatGPT.app/Contents/Resources/codex debug prompt-input --help
venv/bin/python scripts/audit_codex_sources.py --strict
venv/bin/python -m pytest tests/test_audit_codex_sources.py -q
```

Expected: no duplicate enabled skill name and no duplicated global instruction block.

- [ ] **Step 8: Commit the inventory tooling**

```bash
git add scripts/audit_codex_sources.py tests/fixtures/codex_sources tests/test_audit_codex_sources.py docs/operations/codex-source-inventory.md scripts/validate_agent_environment.py .claude/skills/update-claude-md/SKILL.md .cursor/skills/update-claude-md/SKILL.md
git commit -m "chore: audit Codex instruction sources"
```

---

### Task 5: Pin MCP dependencies and remove plaintext credentials

**Files:**
- Create: `scripts/validate_codex_config.py`
- Create: `tests/fixtures/codex_config/secure.toml`
- Create: `tests/fixtures/codex_config/insecure.toml`
- Create: `tests/test_validate_codex_config.py`
- Modify: `scripts/check_dev_environment.py`
- External modify: `/Users/sergej/.codex/config.toml`
- External modify: `/Users/sergej/Click-n-speak/.claude/settings.local.json`

**Interfaces:**
- Produces: `validate_codex_config(path: Path) -> list[str]`.
- Rejects: secret-shaped literal values and npm package arguments that are `@latest` or omit an exact version.
- Never returns or logs the secret value.

- [ ] **Step 1: Write secure/insecure fixture tests**

```python
def test_validator_rejects_plaintext_secret_without_echoing_it() -> None:
    errors = validate_codex_config(FIXTURES / "insecure.toml")

    assert "mcp_servers.exa.env.EXA_API_KEY contains a literal credential" in errors
    assert all("fixture-secret-value" not in error for error in errors)


def test_validator_rejects_unpinned_npx_package() -> None:
    errors = validate_codex_config(FIXTURES / "insecure.toml")

    assert "mcp_servers.context7 uses unpinned npm package @upstash/context7-mcp@latest" in errors
```

- [ ] **Step 2: Confirm RED and implement recursive validation**

Use `tomllib` and key-name matching for `KEY`, `TOKEN`, `SECRET`, `PASSWORD`, and `CREDENTIAL`. Redact all values. Treat scoped npm packages as pinned only when the final `@` suffix is a concrete version such as `@1.2.3`.

- [ ] **Step 3: Rotate the exposed provider credential**

Revoke the existing key in the provider console, create a replacement, and place it in the launch environment or macOS Keychain-backed startup mechanism. This external mutation requires explicit confirmation at execution time. Do not paste the replacement into chat, shell history, a file patch, or test fixtures.

- [ ] **Step 4: Pin reviewed MCP package versions**

Resolve installed/current versions with `npm view <package> version`, inspect release notes, and replace `@latest`/unversioned package args with exact versions. Capture the chosen package/version pairs in `docs/operations/codex-source-inventory.md`.

- [ ] **Step 5: Validate the effective configuration**

Before validation, replace broad `Bash(git *)`, `Bash(bash *)`, and
`Bash(python3 *)` entries in `.claude/settings.local.json` with the reviewed
command prefixes actually used by this repository. Reduce
`NODE_REPL_TRUSTED_CODE_PATHS` to the plugin/runtime directories that execute
trusted code; do not include a writable parent directory when a narrower path
works. Preserve a backup and diff it without printing credential values.

```bash
venv/bin/python scripts/validate_codex_config.py /Users/sergej/.codex/config.toml
/Applications/ChatGPT.app/Contents/Resources/codex mcp list
/Applications/ChatGPT.app/Contents/Resources/codex features list
```

Expected: validator exits 0; every MCP starts or reports configured without exposing environment values; Codex parses config.

- [ ] **Step 6: Commit only the validator and documentation**

```bash
git add scripts/validate_codex_config.py scripts/check_dev_environment.py tests/fixtures/codex_config tests/test_validate_codex_config.py docs/operations/codex-source-inventory.md
git commit -m "chore: validate Codex credential hygiene"
```

---

### Task 6: Add privacy-safe 14-day session metrics and boundary policy

**Files:**
- Create: `scripts/audit_codex_sessions.py`
- Create: `tests/fixtures/codex_sessions/`
- Create: `tests/test_audit_codex_sessions.py`
- Create: `docs/operations/agent-session-policy.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Produces: `summarize_rollouts(paths: Iterable[Path], start: datetime, end: datetime) -> SessionSummary`.
- `SessionSummary` contains counts only: logical sessions, root/subagent/guardian turns, compactions, approvals, input tokens, missing-command events, and model/effort distribution.

- [ ] **Step 1: Write a privacy-boundary test**

```python
def test_summary_omits_content_fields(session_fixture: Path) -> None:
    summary = summarize_rollouts([session_fixture], START, END)
    payload = json.dumps(asdict(summary), sort_keys=True)

    assert "private transcript" not in payload
    assert "git commit -m" not in payload
    assert summary.compactions == 1
    assert summary.approvals == 2
```

- [ ] **Step 2: Confirm RED and implement streaming JSONL parsing**

Read one line at a time. Extract only timestamps, item/event type, model, effort, token counters, tool name, approval status, and normalized error category. Never retain raw messages, command arguments, tool outputs, or hook context.

- [ ] **Step 3: Add the explicit session-boundary policy**

Document:

- New objective → new root task.
- Independent subagent → `fork_turns: "none"` and a self-contained task.
- Recent conversation required → smallest sufficient positive fork count.
- Two compactions on one objective → write a concise handoff checkpoint and continue in a fresh task.
- Do not spawn a subagent for a single dependent command or a task shorter than its coordination overhead.

Link this document from the task-routing section of `AGENTS.md` without copying the policy body.

- [ ] **Step 4: Generate baseline and comparison reports**

```bash
venv/bin/python scripts/audit_codex_sessions.py \
  --sessions-root /Users/sergej/.codex/sessions \
  --days 14 \
  --output /private/tmp/click-n-speak-codex-baseline.json
```

Repeat after 14 days to `/private/tmp/click-n-speak-codex-comparison.json`. Keep both outside Git.

- [ ] **Step 5: Verify report schema and privacy**

```bash
venv/bin/python -m pytest tests/test_audit_codex_sessions.py -q
venv/bin/python scripts/audit_codex_sessions.py --days 14 --validate-only
```

Expected: tests pass; validation reports zero content-bearing fields.

- [ ] **Step 6: Commit metrics and policy**

```bash
git add scripts/audit_codex_sessions.py tests/fixtures/codex_sessions tests/test_audit_codex_sessions.py docs/operations/agent-session-policy.md AGENTS.md
git commit -m "chore: measure Codex session efficiency"
```

---

### Task 7: Benchmark root model/effort profiles before changing defaults

**Files:**
- Create: `docs/operations/codex-profile-benchmark.md`
- Create: `scripts/compare_codex_profiles.py`
- Create: `tests/test_compare_codex_profiles.py`
- External create: `/Users/sergej/.codex/efficient.config.toml`
- External create: `/Users/sergej/.codex/deep.config.toml`
- External modify after acceptance only: `/Users/sergej/.codex/config.toml`

**Interfaces:**
- Produces: `compare_profiles(results: Sequence[TaskResult]) -> ProfileComparison`.
- `TaskResult` contains profile, task class, completion, user corrections, regressions, wall time, input tokens, and output tokens; it contains no task text.

- [ ] **Step 1: Write acceptance-threshold tests**

```python
def test_efficient_profile_requires_nine_clean_completions() -> None:
    comparison = compare_profiles(_results(efficient_clean=8, deep_clean=10))
    assert comparison.promote_efficient is False


def test_efficient_profile_can_win_without_more_rework() -> None:
    comparison = compare_profiles(
        _results(efficient_clean=9, deep_clean=9, efficient_rework=1, deep_rework=1)
    )
    assert comparison.promote_efficient is True
```

- [ ] **Step 2: Confirm RED and implement deterministic comparison**

Promotion requires at least 9/10 clean efficient completions, no more regressions or user corrections than deep, and lower median input-plus-output tokens. Wall time is reported but is not sufficient by itself.

- [ ] **Step 3: Create two explicit profiles**

`efficient.config.toml`:

```toml
model = "gpt-5.6-sol"
model_reasoning_effort = "medium"
```

`deep.config.toml`:

```toml
model = "gpt-5.6-sol"
model_reasoning_effort = "xhigh"
```

Both inherit the validated Luna/medium subagent defaults from the base config.

- [ ] **Step 4: Run ten paired representative tasks**

Use the same frozen repository revision for both profiles and these classes: small bug diagnosis, focused unit fix, Swift concurrency review, Python parity check, config migration, test failure triage, documentation update, release-script review, multi-file refactor plan, and regression review. Record aggregate result fields only.

- [ ] **Step 5: Compute the decision**

```bash
venv/bin/python scripts/compare_codex_profiles.py \
  --input /private/tmp/click-n-speak-profile-results.json \
  --output /private/tmp/click-n-speak-profile-comparison.json
```

If `promote_efficient` is true, change the base root effort to `medium`. Otherwise retain `xhigh` and use `--profile efficient` only for bounded routine tasks.

- [ ] **Step 6: Verify and commit benchmark tooling**

```bash
venv/bin/python -m pytest tests/test_compare_codex_profiles.py -q
git add docs/operations/codex-profile-benchmark.md scripts/compare_codex_profiles.py tests/test_compare_codex_profiles.py
git commit -m "chore: benchmark Codex execution profiles"
```

---

## Final integration gate

- [ ] Run `venv/bin/python scripts/validate_agent_environment.py`.
- [ ] Run `venv/bin/python scripts/check_dev_environment.py`.
- [ ] Run the five focused Python test files added by this plan.
- [ ] Run `venv/bin/pre-commit run --all-files` in a clean worktree.
- [ ] Run `/Applications/ChatGPT.app/Contents/Resources/codex features list` and `codex mcp list` to prove configuration parses.
- [ ] Start one fresh Codex task and confirm the model-visible instructions contain one global guide, the compact project guide, and no archived roadmap.
- [ ] Generate the second 14-day aggregate report and compare all spec acceptance thresholds.
- [ ] Request an independent code/config review before merging the final task.
