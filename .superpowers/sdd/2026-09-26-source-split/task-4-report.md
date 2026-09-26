# Task 4 report — workspace completion and relocation verification

## Result

The repository root now contains workspace automation and documentation only.
The Swift and legacy application trees each have a dependency-free structural
verification command, and the layout test copies each tree into an isolated
temporary directory before invoking that command.

## TDD evidence

- RED: `venv/bin/python -m pytest tests/test_source_split_layout.py -q`
  failed because the copied legacy tree had no `scripts/verify_layout.py`.
- GREEN: the same relocation test passes after adding the local legacy
  verifier. The Swift copy passes `bash scripts/verify_layout.sh`; the legacy
  copy passes `python scripts/verify_layout.py` without importing runtime
  dependencies.

## Changes

- Added `legacy-python/scripts/verify_layout.py` with local path and sibling
  dependency checks.
- Extended root layout tests to verify independent copies and reject residual
  application sources/resources at root.
- Removed the empty tracked root `src/AGENTS.md`, so root `src/` disappears.
- Updated GitHub Actions to invoke `bash swift-app/scripts/swift_verify.sh`.
- Added explicit production/frozen-snapshot labels under `swift-app/docs/` and
  `legacy-python/docs/`.

## Validation

- `venv/bin/python -m pytest tests/test_source_split_layout.py tests/test_agent_environment.py -q` — 28 passed.
- `bash swift-app/scripts/verify_layout.sh` — passed.
- `venv/bin/python -m pytest legacy-python/tests -q` — 428 passed, 1 skipped,
  2 failed because macOS process enumeration is denied by the sandbox
  (`psutil` raises `PermissionError` in process-watchdog tests).
- `bash swift-app/scripts/swift_verify.sh` — blocked before compilation because
  the sandbox cannot write `/Users/sergej/.cache/clang/ModuleCache`.
- `git diff --check` — passed.

## Residual limitation

The two failing legacy watchdog tests and the Swift verification failure are
environment-bound permission issues; no application assertion failed in the
Task 4 checks.
