# Source Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the repository into independently movable `swift-app/` and
`legacy-python/` directories while keeping Swift as the actively developed
application.

**Architecture:** Preserve the existing internal Swift layout by placing
`ClickNSpeak/` and `Packages/` under `swift-app/`. Place the legacy entry
point, runtime, packaging, and tests under `legacy-python/`. Copy resources
and historical material rather than sharing paths; remove every mandatory
cross-directory repository-path lookup.

**Tech Stack:** SwiftPM/Swift 6, Python 3.11, Bash, pytest, Git.

**Spec:** `docs/superpowers/specs/2026-09-26-source-split-design.md`

## Global Constraints

- Preserve all user-data paths and on-disk formats.
- `swift-app/` and `legacy-python/` must not use runtime symlinks or `../` to
  load the sibling application.
- Move tracked ownership with `git mv`; copy only deliberate duplicated
  resources and historical documents.
- Never stage ignored user configuration, models, virtual environments,
  build output, or generated native vendor artifacts.
- New behavior tests must be written and observed failing before the matching
  implementation change.
- Swift is active development; Python is maintenance-only rollback reference.

---

### Task 1: Establish the split contract and workspace documentation

**Files:**
- Create: `swift-app/README.md`
- Create: `swift-app/AGENTS.md`
- Create: `legacy-python/README.md`
- Create: `legacy-python/AGENTS.md`
- Create: `legacy-python/LEGACY_STATUS.md`
- Modify: root `README.md`, root `AGENTS.md`

**Interfaces:**
- Produces the directory ownership contract used by every later task.
- [x] **Step 1: Create the documentation contract**

Make the root a thin workspace map. State that `swift-app/` is production and
`legacy-python/` is frozen/rollback-only. Do not create a legal license file.

- [x] **Step 2: Run documentation and repository-contract checks**

Run: `venv/bin/python -m pytest tests/test_agent_environment.py -q`

Expected: PASS.

- [x] **Step 3: Commit**

Commit message: `docs: define Swift and legacy source split`

### Task 2: Make the Python application self-contained

**Files:**
- Move: `main.py`, `src/`, Python application tests, `pyproject.toml`,
  `requirements.txt`, `setup.py`, `config.example.json`
- Move: `scripts/build.sh`, `scripts/build_launcher.sh`, `scripts/install.sh`,
  `scripts/make_dmg.sh`, `scripts/make_icons.sh`, `scripts/launcher_py2app.c`,
  `scripts/requirements_app.txt`, `scripts/numba_stub/`,
  `scripts/download_ai_model.py`, `scripts/download_whisper_model.py`,
  `scripts/clean_corrections.py`, `scripts/print_metrics.py`,
  `scripts/term_effectiveness.py`, `scripts/parity_config_bridge.py`,
  `scripts/analyze_runtime_log.py`, `scripts/convert_icons.py`,
  `scripts/convert_icons_template.py`, and `scripts/dev/`
- Copy: `assets/`, `locales/`, `design/`, relevant historical `docs/`
- Create: `tests/test_source_split_layout.py`

**Interfaces:**
- Consumes the ownership contract from Task 1.
- Produces a runnable `legacy-python/` whose Python imports, packaging, and
  resources resolve below its own root.

- [x] **Step 1: Write failing legacy layout and resource tests**

Assert that `main.py`, `src/`, `assets/`, `locales/`, packaging metadata, and
the legacy build entrypoint live below the legacy root. Assert that the
resource resolver accepts the legacy root without a sibling application.

- [x] **Step 2: Run the tests and verify failure**

Run: `venv/bin/python -m pytest tests/test_source_split_layout.py -q`

Expected: FAIL because the folder and resolver do not yet exist.

- [x] **Step 3: Move and adapt the legacy runtime**

Use `git mv` for the Python-owned files. Update Python root/resource lookup,
test bootstrap, and py2app scripts to derive paths from `legacy-python/`.
Copy rather than link runtime assets, locales, design history, and docs.
Keep the root copies of shared resources and Swift-owned scripts for Task 3.
Do not move `tests/parity/`, `test_agent_environment.py`,
`test_audit_codex_sessions.py`, `test_audit_codex_sources.py`,
`test_check_dev_environment.py`, `test_compare_codex_profiles.py`,
`test_validate_codex_config.py`, or `test_swift_permission_reset_script.py`.

- [x] **Step 4: Run focused and full legacy checks**

Run: `venv/bin/python -m pytest tests/test_source_split_layout.py legacy-python/tests/test_transcriber.py legacy-python/tests/test_app_context.py -q`

Then run: `venv/bin/python -m pytest legacy-python/tests -q`

- [x] **Step 5: Commit**

Commit message: `refactor: isolate legacy Python application`

### Task 3: Make the Swift application self-contained

**Files:**
- Move: `ClickNSpeak/`, `Packages/`, Swift-owned scripts, native tests,
  native docs, `assets/`, `locales/`, and `design/`
- Modify: native resource lookup, build/release scripts, Swift tests, and
  Swift acceptance tooling
- Create: `swift-app/scripts/verify_layout.sh`
- Modify: `tests/test_source_split_layout.py`

**Interfaces:**
- Consumes `swift-app/` ownership from Task 1.
- Produces a native tree with the same `ClickNSpeak/Package.swift` to
  `../Packages/` relationship, but no dependency on root runtime resources.

- [x] **Step 1: Write failing native layout checks**

Add a shell check that requires `ClickNSpeak/`, `Packages/`, `assets/`,
`locales/`, and `scripts/swift_verify.sh` beneath `swift-app/`, and rejects
runtime references to `../legacy-python`, `venv/bin/python`, and root
`pyproject.toml` in normal Swift build/test paths.

- [x] **Step 2: Run the check and verify failure**

Run: `bash swift-app/scripts/verify_layout.sh`

Expected: FAIL because the native root has not been moved.

- [x] **Step 3: Move and adapt the native tree**

Use `git mv` for Swift-owned paths. Keep `ClickNSpeak/` and `Packages/`
siblings below `swift-app/`. Make build and resource discovery relative to
the native root. Use `Info.plist` for native release version lookup.

- [x] **Step 4: Replace mandatory Python-dependent native tests**

Replace the Python parent process in restart-helper integration testing with
a Swift helper. Replace Python live config bridging with frozen Swift-owned
fixtures. Keep cross-app parity only as an optional workspace check.

- [x] **Step 5: Run native checks**

Run: `bash swift-app/scripts/verify_layout.sh`

Run: `bash swift-app/scripts/swift_verify.sh`

- [x] **Step 6: Commit**

Commit message: `refactor: isolate Swift production application`

### Task 4: Finish root automation and relocation verification

**Files:**
- Modify: root `.github/workflows/verify.yml`, root README, root AGENTS
- Modify: `swift-app/docs/`, `legacy-python/docs/`
- Modify: source-split layout checks

**Interfaces:**
- Consumes both self-contained trees.
- Produces a thin workspace root and reproducible independent verification.

- [ ] **Step 1: Write failing relocation checks**

Extend the layout check to copy each application tree to a temporary
directory and assert that its focused verification command finds no sibling
path.

- [ ] **Step 2: Run the checks and verify failure**

Run: `venv/bin/python -m pytest tests/test_source_split_layout.py -q`

Expected: FAIL until CI and residual paths are updated.

- [ ] **Step 3: Complete CI and historical snapshots**

Make root CI delegate to independent app commands. Ensure copied docs clearly
label legacy material as a frozen snapshot. Retain no application source or
runtime assets at root; the workspace layout check remains root automation.

- [ ] **Step 4: Run final verification**

Run: `venv/bin/python -m pytest tests/test_source_split_layout.py -q`

Run: `bash swift-app/scripts/swift_verify.sh`

Run: `venv/bin/python -m pytest legacy-python/tests -q`

- [ ] **Step 5: Commit**

Commit message: `ci: verify independent application roots`
