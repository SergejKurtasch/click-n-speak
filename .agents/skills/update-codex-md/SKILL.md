---
name: update-codex-md
description: Review the most recent commit and update the compact AGENTS.md only when project architecture, canonical commands, module ownership, or cross-module invariants changed. Invoke after every successful git commit.
allowed-tools: Bash(git log:*), Bash(git show:*), Bash(git diff:*), Read, Edit, Grep, Glob
---

# update-codex-md

Inspect the HEAD commit and update `AGENTS.md` **only when the change touches
documented project structure**. Bugfixes, refactors inside one module, and
test-only changes do NOT warrant a AGENTS.md update.

## What counts as "architectural"

Update AGENTS.md when the commit:

- **Adds, removes, or renames a production component** under `ClickNSpeak/`,
  `Packages/`, `src/`, `main.py`, or `scripts/` when ownership, process
  architecture, or canonical build steps are affected.
- **Changes a cross-module invariant** — e.g. new thread, new process, new
  signal handler, new permission, new config key, new IPC channel, new queue.
- **Changes module ownership or a public surface** documented in AGENTS.md.
- **Adds or removes a runtime file path** (config, log, dataset, etc.).
- **Changes a canonical verification or release command**.

Do NOT update for:

- Bugfixes that keep the same public API and flow.
- Renaming private variables or internal helpers.
- Test-only changes (`tests/**` without `src/**` changes).
- Dependency-only version bumps.
- Commit-message-only amendments.

## Procedure

1. Inspect what just shipped:
   ```
   git log -1 --format='%H %s'
   git show --stat HEAD
   git diff HEAD~1 HEAD -- AGENTS.md ClickNSpeak/ Packages/ src/ main.py scripts/
   ```
2. Decide against the checklist above. If nothing qualifies, reply:
   `AGENTS.md update not needed — commit is <reason>.`
   and stop.
3. If an update IS warranted, read `AGENTS.md` and the changed source files,
   then edit the specific section(s) that are now stale. Prefer surgical
   `Edit` calls over rewriting whole sections.
4. Keep the root guide below its enforced size budget. Put durable detail in
   an existing focused document and link to it instead of expanding AGENTS.md.
5. Do NOT create a new commit. The user reviews the tracked AGENTS.md change
   separately.
6. End with a one-line summary of what changed and why.

## Tone

Keep AGENTS.md terse and operational — it's a map for an agent, not prose for
a human reader. Match the existing style: tables, short sentences, concrete
function names.
