# Epoch 10 — Final Parity Validation, Soak, and Cutover

## Objective

Produce objective evidence that the Swift application can replace Python without losing functionality, data, quality, performance, or recoverability. Fix only release-blocking parity defects found by this validation and perform a controlled cutover with a Python rollback path.

## User-visible result

A signed Swift release candidate behaves like the Python application across first launch, dictation, editing, injection, menu/history, learning, file transcription, updates, and long-running lifecycle scenarios.

## Preconditions

- Epochs 01–09 meet all acceptance criteria.
- Fast, model-gated, UI, signing, and manual verification jobs are documented and reproducible.
- A signed/notarized release candidate and a signed prior-version updater fixture exist.
- Production data is backed up before any acceptance test that uses a copied real-world dataset.

## Rule for this epoch

Do not add new product features. Any discovered issue is classified as:

- release blocker: fix now with a regression test;
- accepted intentional deviation: document and approve;
- post-cutover improvement: record separately without weakening parity criteria.

## Workstream 1 — Create a parity scenario manifest

Add `tests/parity/swift_parity_scenarios.json` or an equivalent typed manifest.

Each scenario must include:

- stable ID;
- Python reference behavior;
- Swift expected behavior;
- required permissions/models/network;
- fixture IDs, never private transcript data;
- automated/manual classification;
- pass/fail evidence location;
- allowed intentional deviation.

Cover all scenarios in the audit:

- clean/incomplete/previously granted permissions;
- recording, silence, multichunk, rapid hotkey, timeout, append popup;
- Enter/Escape/empty/Command-D;
- stable PID and clipboard preservation;
- local/cloud/file STT;
- local/Gemini editing;
- model/key/backend changes;
- history/menu/dictionary/suggestions/replacements/statistics;
- sleep/wake/device disconnect/network loss;
- download/autostart/update/rollback.

## Workstream 2 — Add an acceptance harness

Create `scripts/swift_acceptance.sh` to orchestrate non-destructive checks.

1. Run `scripts/swift_verify.sh`.
2. Run the model-gated STT/editor suites when model paths are supplied.
3. Build the release app and run bundle/signing verification.
4. Create temporary data fixtures for schema/data tests.
5. Generate a machine-readable summary with pass/fail/skipped and durations.
6. Fail if a release-critical scenario is skipped.
7. Never reset TCC automatically.
8. Never read/write the live production directory unless an explicit copy/import path is supplied.

## Workstream 3 — Prove data compatibility

Build sanitized fixtures for every config schema supported by the branch and representative large files.

Required tests:

1. Python fixture → Swift load/migrate/save → Python reload.
2. Swift fixture → Python load/update/save → Swift reload.
3. Preserve unknown forward-compatible config keys where the current contract requires it.
4. Phrase history append/count/read for small and large data.
5. Dataset/corrections/metrics JSONL round trips.
6. Prompt file sync and empty-file protection.
7. Keychain account names and values remain compatible without exposing secrets.
8. Migration failure leaves the original file recoverable.

## Workstream 4 — Measure quality and latency

Run Python and Swift on the same sanitized audio corpus and hardware state.

Collect:

- overall WER;
- Russian, English, and code-switch WER;
- short-command accuracy;
- hotkey-to-HUD latency;
- stop-to-popup p50/p95;
- warm/cold decode p50/p95;
- local editor latency/status distribution;
- cloud request latency/error distribution;
- resident/peak memory after startup, 1, 20, and 100 sessions;
- idle/recording energy impact;
- audio callback duration and overflow count.

Use `ProcessInfo.systemUptime`/monotonic clocks and privacy-safe telemetry. Define pass thresholds before viewing final results, based on the accepted Python/bake-off baseline.

## Workstream 5 — Run UI and accessibility parity review

1. Compare sanitized Python/Swift screenshots for all main states.
2. Run RU, EN, and DE complete workflows.
3. Verify all supported locales for missing keys/placeholders.
4. Run light/dark, Retina, one/two-display layouts.
5. Complete keyboard-only and VoiceOver workflows.
6. Record intentional visual differences with approval.

## Workstream 6 — Run lifecycle and failure soak tests

Perform at least one eight-hour signed-app soak with scripted/manual events:

- repeated recordings and long idle intervals;
- 20/100-session model reload points;
- sleep/wake cycles;
- input-device disconnect/reconnect;
- cloud network loss and recovery;
- model/editor switches;
- file transcription cancellation;
- model download cancellation/resume;
- quit/relaunch during safe stages.

Monitor:

- crash/hang;
- unreleased audio stream;
- leaked task/timer/event monitor;
- unbounded memory growth;
- stale popup or status state;
- duplicated/lost history/dataset rows;
- private content in logs.

Any release-blocking issue receives a focused regression test before rerunning the affected soak segment.

## Workstream 7 — Validate install, update, and rollback

On a clean macOS user or clean test machine:

1. Install the previous signed application.
2. Grant permissions and create sanitized data.
3. Update to the Swift release candidate.
4. Verify TCC, data, autostart, models, and Keychain compatibility.
5. Trigger a controlled update failure and verify automatic rollback.
6. Verify the Python fallback can still read the data if Swift is rolled back.
7. Confirm the single-instance guard does not conflict across transition versions.

## Workstream 8 — Add a release go/no-go report

Create a versioned report under `docs/releases/` containing:

- candidate version/commit/artifact hashes;
- signing identity and notarization evidence;
- automated/manual scenario summary;
- quality/performance comparison;
- known intentional deviations;
- unresolved blockers;
- rollback artifact and instructions;
- final go/no-go decision.

The report must link to machine-readable results but contain no transcript, clipboard, key, or personal history content.

## Workstream 9 — Controlled cutover

Only after a written go decision:

1. Back up production config/history/dataset/corrections/metrics/prompt files.
2. Publish the signed/notarized Swift artifact through the existing channel.
3. Keep the Python artifact and rollback instructions available for at least one release cycle.
4. Monitor privacy-safe crash, latency, and update signals.
5. Do not delete Python source/build infrastructure in the cutover release.
6. Open a separate cleanup epoch after the rollback window closes.

## Expected files

- `tests/parity/*` fixtures and scenario manifest
- `scripts/swift_acceptance.sh`
- performance/compatibility harnesses under `scripts/` or `tests/`
- sanitized screenshot references
- release report template and one candidate report under `docs/releases/`
- focused source/test changes only for blockers found during validation

## Required automated verification

- full fast Swift gate;
- local Whisper and Qwen model-gated suites;
- cloud HTTP fixture suites;
- data round-trip suite;
- menu/UI snapshots;
- release build and signed bundle verification;
- update/swap rollback fixture suite;
- machine-readable acceptance summary with zero release-critical skips.

## Required manual/system verification

- complete permission matrix on signed app;
- complete dictation/injection workflow across target apps;
- physical audio-device and sleep/wake scenarios;
- multi-monitor, VoiceOver, and keyboard workflows;
- clean install/update/rollback;
- eight-hour soak.

## Acceptance criteria

- Every release-critical parity scenario passes.
- No critical test is skipped.
- STT quality and latency meet predeclared thresholds.
- No observed data incompatibility or loss.
- No permission hang or TCC loss across update.
- No crash, unrecoverable hang, audio leak, or unbounded memory growth in soak.
- Signed update and rollback succeed on a clean environment.
- A written go/no-go report is approved.
- The Python rollback remains available for one release cycle.

## Non-goals

- New product features.
- Removing Python code or build infrastructure.
- Large architectural refactors unrelated to a measured release blocker.

## Suggested commit boundaries

1. `test: add Swift parity scenario manifest`
2. `test: add release acceptance harness`
3. `test: add Python Swift data compatibility suite`
4. `perf: add parity performance measurements`
5. Focused `fix:` commits for discovered blockers
6. `docs: add Swift release go-no-go report`
