# Swift-only Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Archive the Python application outside Git and leave a root-level Swift-only repository.

**Architecture:** First copy the isolated legacy tree to the approved archive path without user data or ignored artifacts. Then remove the tracked legacy application and promote the independent `swift-app` tree back to the repository root, restoring conventional SwiftPM paths. Workspace tooling remains only when it supports the Swift project and does not depend on the archive.

**Tech Stack:** SwiftPM, Bash, GitHub Actions, Python only for Swift development tooling.

**Spec:** `docs/superpowers/specs/2026-09-26-swift-only-cutover.md`

## Global Constraints

- Archive before removing tracked Python files; never overwrite the archive.
- Do not stage ignored configuration, model artifacts, virtual environments, caches, or build products.
- No application runtime dependency may point to the archive.
- Keep Swift source comments and commits in English; user-facing reports in Russian.

---

### Task 1: Archive the frozen Python application

**Files:**
- External create: `/Users/sergej/Click-n-speak-python-legacy-archive/`
- Source: `legacy-python/`

**Interfaces:** Produces a standalone immutable archive used only outside Git.

- [x] **Step 1: Verify source and destination**

Run a read-only check that `legacy-python/LEGACY_STATUS.md` exists and the
archive destination does not exist. Expected: source exists, destination absent.

- [x] **Step 2: Copy without ignored artifacts**

Use `ditto legacy-python /Users/sergej/Click-n-speak-python-legacy-archive`.
Do not use `mv`, `rm`, or copy any parent workspace files.

- [x] **Step 3: Verify archive identity**

Compare a manifest of tracked source files and SHA-256 content hashes between
`legacy-python/` and the archive. Expected: identical tracked file set and hashes.

### Task 2: Promote the Swift product and retire tracked legacy code

**Files:**
- Move: `swift-app/ClickNSpeak/`, `Packages/`, `assets/`, `locales/`, `design/`,
  active `scripts/`, `docs/`, `spikes/`, and Swift tests to their root ownership.
- Remove from Git: `legacy-python/` and root cross-application Python parity code.
- Modify: root README, AGENTS, CI, Codex rules, active scripts, Swift docs.

**Interfaces:** Produces the root-level SwiftPM layout expected by
`ClickNSpeak/Package.swift` and all release scripts.

- [x] **Step 1: Write failing Swift-only layout checks**

Add a root structural check that requires `ClickNSpeak/Package.swift`,
`Packages/CNSCore/Package.swift`, `assets/`, `locales/`, and
`scripts/swift_verify.sh`, and rejects `legacy-python/` and `swift-app/`.

- [x] **Step 2: Run the check and observe RED**

Run the check before promotion. Expected: it fails because the Swift tree is nested
and the legacy tree exists.

- [x] **Step 3: Promote and prune**

Use `git mv` to promote every active Swift-owned path. Remove the now-archived
legacy tree and cross-app parity/runtime bridge with `git rm`. Update paths in
CI, scripts, tests, guides, and docs. Retain only Swift-owned fixtures; do not
replace a dependency with an archive path.

- [x] **Step 4: Verify GREEN**

Run `bash scripts/swift_verify.sh`, root layout checks, and focused Swift package
tests. If the ignored Whisper binary is absent at its promoted `Packages/...`
location, relocate the user's existing local artifact from the former original
checkout only after the merge decision; otherwise record it as environment setup.

- [x] **Step 5: Commit**

Commit message: `refactor: cut over to Swift-only repository`.

### Task 3: Review and prepare the PR branch

**Files:** root documentation and CI only if Task 2 review finds stale paths.

- [x] **Step 1: Run a whole-branch review**

Check the complete diff for residual Python runtime ownership, archive path
references, stale `swift-app/` paths, and accidental removal of Swift fixtures.

- [x] **Step 2: Run final checks**

Run `bash scripts/swift_verify.sh`, the Swift layout check, and
`git diff --check` for the cutover range. Record any ignored-artifact limitation.

- [x] **Step 3: Commit review fixes when needed**

Use a conventional commit only if review fixes source or documentation.
