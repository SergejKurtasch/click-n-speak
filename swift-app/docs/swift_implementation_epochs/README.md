# Swift Migration Implementation Epochs

- Date: 2026-08-29
- Branch baseline: `swift_migration`
- Source audit: `docs/SWIFT_PARITY_AUDIT_AND_ROADMAP.md`

## Purpose

This directory converts the parity audit into executable coding plans. Each epoch is intentionally self-contained and can be handed to an implementation agent as a standalone task.

The epochs must be implemented in order. Later plans assume that the public contracts and regression tests from earlier epochs already exist.

## How to use these plans

For a new implementation task, provide the entire epoch file and ask to implement it completely. Example:

> Implement Epoch 01 from `docs/swift_implementation_epochs/EPOCH_01_CRITICAL_FOUNDATION.md`. Do not start Epoch 02. Preserve unrelated working-tree changes, run every required verification command, and report any acceptance criterion that remains unmet.

An epoch is complete only when all of its acceptance criteria pass. Partially completed work must remain in the same epoch; it must not be reclassified as a later task.

## Global implementation rules

These rules apply to every epoch:

1. Python behavior is the compatibility baseline unless an intentional Swift deviation is explicitly recorded.
2. Preserve the shared data formats and release paths used by Python.
3. Never run automated tests against the user's live production data.
4. All AppKit operations remain on `@MainActor`.
5. Audio callbacks must not block and must not perform unbounded allocation or disk/network work.
6. Transcript, prompt, clipboard, and API-key contents must never be written to runtime telemetry.
7. Missing models or credentials must produce an actionable user-visible state; production builds must not silently fall back to `StubTranscriber`.
8. Every fixed defect requires a regression test.
9. Run package tests from the affected package and run the repository-wide Swift verification gate before completing an epoch.
10. Preserve unrelated dirty-worktree changes. Do not reformat or rewrite unaffected files.
11. Use English for Swift code, comments, test names, and commits.
12. If commits are requested, use Conventional Commits and keep one logical change per commit.

## Epoch sequence

| Epoch | Plan | User-visible outcome | Depends on |
|---|---|---|---|
| 01 | [Critical Foundation](EPOCH_01_CRITICAL_FOUNDATION.md) | Stable permissions and deterministic first launch; compilable green test gate | None |
| 02 | [Session and Audio Correctness](EPOCH_02_SESSION_AND_AUDIO_CORRECTNESS.md) | No double completion, start/stop races, stale audio, or hotkey-path warmup | 01 |
| 03 | [Runtime Coordination](EPOCH_03_RUNTIME_COORDINATION.md) | Model/backend/editor selections affect the next session without restart | 02 |
| 04 | [Menu, Status, and History](EPOCH_04_MENU_STATUS_HISTORY.md) | Correct status icons, menu state, permissions, and visible phrase history | 03 |
| 05 | [STT Production Parity](EPOCH_05_STT_PRODUCTION_PARITY.md) | Production-grade local, cloud, and file transcription | 03 |
| 06 | [AI Editor Parity](EPOCH_06_AI_EDITOR_PARITY.md) | Real local Qwen and correct Gemini concurrency/timeouts | 03, 05 |
| 07 | [Dictionary and Maintenance](EPOCH_07_DICTIONARY_AND_MAINTENANCE.md) | Full learning loop, prompt sync, suggestions, decay, and metrics | 04, 06 |
| 08 | [UI, Localization, and Accessibility](EPOCH_08_UI_LOCALIZATION_ACCESSIBILITY.md) | Complete, localized, accessible AppKit UI parity | 04, 07 |
| 09 | [Distribution Hardening](EPOCH_09_DISTRIBUTION_HARDENING.md) | Safe model lifecycle, autostart, signed updates, and recoverable installation | 03, 08 |
| 10 | [Parity Validation and Cutover](EPOCH_10_PARITY_VALIDATION_AND_CUTOVER.md) | Evidence-backed Swift release candidate with Python rollback | 01–09 |

## Repository-wide verification contract

Epoch 01 creates the canonical script `scripts/swift_verify.sh`. Until it exists, run the equivalent commands manually:

```bash
swift test --package-path Packages/CNSCore
swift test --package-path Packages/CNSAudio
swift test --package-path Packages/CNSInput
swift test --package-path Packages/CNSTranscription
swift test --package-path Packages/CNSDictionary
swift test --package-path Packages/CNSSession
swift test --package-path Packages/CNSUI
swift build --package-path ClickNSpeak
```

Model-gated, TCC, signing, audio-device, and UI acceptance checks belong to explicit manual/full-suite jobs and must not be represented as ordinary passing unit tests when they were skipped.

## Completion reporting template

Every epoch handoff should report:

1. Implemented workstreams.
2. Files changed.
3. Automated tests run and exact results.
4. Manual scenarios run and exact results.
5. Acceptance criteria met.
6. Acceptance criteria not met and why.
7. Known risks intentionally deferred to the next epoch.
