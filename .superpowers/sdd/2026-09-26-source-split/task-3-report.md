# Task 3 report — Swift production isolation

## Result

The production Swift application now lives under `swift-app/`. `ClickNSpeak/`
and `Packages/` remain siblings, and native scripts, resources, native tests,
Swift documentation, and Swift-owned fixtures are below the same movable root.

## TDD evidence

- RED: `bash swift-app/scripts/verify_layout.sh` failed before the move with
  `Missing Swift application path: .../swift-app/ClickNSpeak/Package.swift`.
- GREEN: the same command passed after the move with
  `Swift application layout is self-contained`.
- GREEN: `swift test --disable-index-store --package-path swift-app/Packages/CNSCore --filter ParityDataCompatibilityTests`
  passed 2 tests. The compatibility test uses a copied Swift-owned JSON fixture
  and never launches Python.

## Moved and created material

- Moved `ClickNSpeak/`, `Packages/`, native `scripts/`, `assets/`, `locales/`,
  and `design/` into `swift-app/`.
- Moved `tests/test_swift_permission_reset_script.py` to `swift-app/tests/`.
- Copied native docs, STT golden fixtures, parity scenario/threshold inputs,
  and `config_schemas.json` into `swift-app/`.
- Created `swift-app/scripts/verify_layout.sh`.
- Replaced the restart-helper Python fixture process with `/bin/sleep` and a
  local shell replacement fixture.
- Replaced the live Python parity bridge with deterministic Swift migration and
  round-trip tests.

## Validation

- `bash swift-app/scripts/verify_layout.sh` — PASS.
- CNSCore parity focused test — PASS (2 tests).
- `swift test --disable-index-store --package-path swift-app/ClickNSpeak --filter AppRestartHelperIntegrationTests` —
  not completed: the checkout lacks the ignored
  `Packages/CNSTranscription/Vendor/whisper.xcframework` binary artifact.
- Full `bash swift-app/scripts/swift_verify.sh` — not run to completion for the
  same missing vendor artifact.
- Root pytest layout/native tests — deferred to the parent task because root
  Task 2 integration checks are still being repaired.

## Known risks

- The acceptance scenario snapshot still contains historical cross-app Python
  scenario entries; it is no longer a mandatory native build/test dependency,
  while the mandatory CNSCore parity test is fully Swift-owned.
- Model-backed tests remain environment-bound and require ignored model/vendor
  artifacts.
