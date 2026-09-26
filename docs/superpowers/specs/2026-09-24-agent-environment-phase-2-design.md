# Agent Environment Phase 2 Design

## Context

The first phase reduced the automatically injected project guide, corrected
canonical test commands, set the default subagent model/effort, and added
repository-owned validation through pre-commit and CI. The remaining work
should improve precision without adding another large unconditional prompt.

## Goals

- Keep automatically injected instructions small, stable, and non-conflicting.
- Load specialized instructions only for the role or task that needs them.
- Make missing local tools and stale Codex configuration fail during setup,
  not halfway through an agent session.
- Remove duplicate skill sources and duplicate global instruction files.
- Reduce compaction, approval, and token overhead with measurable session
  boundaries and model-routing experiments.
- Remove plaintext credentials from Codex configuration and pin executable
  MCP dependencies to reviewed versions.

## Non-goals

- No product-runtime changes in `ClickNSpeak/`, `Packages/`, or `src/`.
- No automatic deletion of user skills, sessions, or global configuration.
- No transcript or prompt content in generated telemetry.
- No global model downgrade without a measured comparison on representative
  tasks.

## Design

### 1. Context contract and focused documentation

The root `AGENTS.md` remains under 16 KiB and contains only universal rules,
the module map, canonical commands, and cross-module invariants. Detailed
architecture and workflow guidance moves to focused documents linked by task
area. Subtree `AGENTS.md` files hold only directory-specific constraints and
remain below 4 KiB each. A validator enforces byte limits, broken links,
duplicate canonical commands, and forbidden historical markers in the root
guide.

### 2. Role-scoped subagent profiles

Project-local Codex configuration declares three roles: `researcher`,
`implementer`, and `reviewer`. Each role uses a small TOML layer with Luna at
medium effort and a role-specific instruction file. Role prompts must describe
the output contract and scope, not repeat the root guide.

### 3. Reproducible local toolchain

A read-only doctor checks `rg`, Swift, the repository Python environment,
pre-commit, and Codex config parsing. A `Brewfile` declares ripgrep so a fresh
machine can reproduce the expected search tool. The doctor emits actionable
commands but never installs packages itself.

### 4. Skills and instruction-source consolidation

An inventory command groups skills by declared name, real path, and content
digest. A reviewed allow/disable list removes duplicate project-visible skill
entries while retaining one canonical source. The parent `/Users/sergej/AGENTS.md`
is removed only after a dry-run proves the same durable rules live in the
global Codex guide or the repository guide. Claude and Cursor retain only thin
wrappers around their explicitly named canonical instruction source.

### 5. MCP and credential hygiene

MCP packages use exact reviewed versions rather than `@latest` or unversioned
launches. Secrets come from environment or Keychain-backed launch setup, not
`config.toml`. The existing exposed credential is rotated before its plaintext
copy is removed. Broad wildcard command permissions and trusted-code paths are
reduced to the smallest reviewed prefixes. Validation reports secret-shaped
TOML values without printing their contents.

### 6. Session boundaries and measurement

A privacy-safe audit reads rollout metadata and tool names only. It reports
logical sessions, root/subagent turns, compactions, approvals, input tokens,
failed command lookups, and subagent model/effort distribution for a selected
date range. No user messages, model text, command arguments, or tool output are
written to reports.

The workflow uses a fresh root task for a new objective, a projectless research
task only for work with no repository, and `fork_turns: none` for independent
subagents unless recent dialogue is essential. More than two compactions on
one objective triggers a deliberate handoff checkpoint, not another automatic
continuation.

### 7. Root-model experiment

Keep the current root default unchanged while comparing an `efficient` profile
against the current `deep` profile on ten representative task classes. Promote
a cheaper default only if completion rate, regression rate, and human rework do
not worsen beyond the acceptance thresholds below.

## Acceptance criteria

- Root `AGENTS.md` stays at or below 16,384 bytes and all routed documents
  exist.
- Every configured subagent role parses under `codex --strict-config` or the
  strictest supported equivalent and resolves to Luna/medium.
- `scripts/check_dev_environment.py` identifies a missing `rg` before agent
  work begins.
- Skill inventory contains no duplicate enabled skill names for this project.
- No credential-shaped literal or unpinned npm MCP package remains in the
  effective Codex configuration.
- A 14-day audit report contains only aggregate counts and timestamps.
- Compared with the baseline audit, approval prompts fall by at least 70%,
  `command not found` events for canonical tools fall to zero, median initial
  prompt input falls by at least 50%, and compactions per completed root task
  fall by at least 30%.
- The efficient root profile is adopted only if at least 9 of 10 benchmark
  tasks complete without extra user correction and its regression/rework count
  is no higher than the deep profile.
