# Swift Epoch Implementation Status

Last updated: 2026-09-13

Current stability round (separate from the historical implementation epochs below): Epochs 01–05 are code-complete. Epoch 06 observability and candidate-bound acceptance implementation is complete; full deterministic Swift, 58 Python parity tests, and the existing Whisper/Qwen real-model suites passed. The development app/DMG built at `0a631fa` passed bundle verification and mounted-DMG equality. Production cutover remains **NO-GO**: Developer ID/notarization, signed physical workflows, candidate-bound manual evidence, and eight-hour soak are missing. See [current RC readiness](../releases/SWIFT_1.1.0_RC_GO_NO_GO_2026-09-13.md). Historical pass counts below must not be read as current-candidate release approval.

| Epoch | Status | Verification | Deferred external checks |
|---|---|---|---|
| 01 — Critical Foundation | Code complete | `scripts/swift_verify.sh` passed; debug/release bundles passed `swift_verify_bundle.sh` | Full TCC matrix requires a stable Apple signing identity; `security find-identity` currently reports zero valid identities |
| 02 — Session and Audio Correctness | Code complete | Full `scripts/swift_verify.sh` passed (including new race/abort tests) | Device-change and sleep/wake recording matrix requires interactive signed-app testing |
| 03 — Runtime Coordination | Code complete | Full `scripts/swift_verify.sh` passed (routers, activation/rollback, factual dataset metadata, shutdown) | Live backend/key/model switching matrix requires real credentials and downloaded models |
| 04 — Menu, Status, and History | Code complete | Full `scripts/swift_verify.sh` passed (immutable snapshots, assets/locales, 100k-row history, copy/invalidation) | RU/EN screenshot, VoiceOver, Retina, and live menu-tracking checks require interactive app testing |
| 05 — STT Production Parity | Code complete | Full `scripts/swift_verify.sh` passed; 42-phrase release real-model golden gate passed | Live providers, long media, sleep/wake, and memory-pressure checks require credentials or interactive hardware testing |
| 06 — AI Editor Parity | Code complete | Fast editor/core/session/app suites passed; pinned real-Qwen release gate passed; release `.app` passed metallib/signature verification | Live Gemini credentials, interactive backend switching, and deliberate memory-pressure checks remain for Epoch 10 |
| 07 — Dictionary and Maintenance | Code complete | Dictionary/core/session/UI focused suites passed; executable integration build passed | External prompt-file editing and large live-data panel checks remain for Epoch 10 |
| 08 — UI, Localization, and Accessibility | Code complete | `CNSUI` passed 10 XCTest + 34 Swift Testing cases; dictionary and 9 executable integration tests passed; warning-free app build | Signed RU/EN/DE VoiceOver, Retina, multi-monitor, and physical drag/drop walkthrough remains for Epoch 10 |
| 09 — Distribution Hardening | Code complete | `CNSCore` passed 29 XCTest + 61 Swift Testing cases; `CNSUI` passed 10 XCTest + 34 Swift Testing cases; executable passed 9 integration tests; ad-hoc app/DMG assembly and manifest verification passed | Developer ID signing, notarization, clean-user update/TCC, Launch at Login, and interrupted live-download checks require release credentials or interactive system testing |
| 10 — Parity Validation and Cutover | Code complete; cutover NO-GO | Canonical automated-only acceptance: 0 failed, 25 passed, 20 release-critical skips; all Swift suites, parity tests, data bridge, release app, and 9 executable tests passed | Production signing/notarization, clean-machine TCC/update, live models/providers, physical workflows, and eight-hour soak require external evidence |

## Epoch 01 delivered

- Canonical repository-wide Swift verification script.
- Production app builds preserve TCC; development rebuilds reset Accessibility/Microphone by default after ad-hoc signing unless `CNS_RESET_TCC_AFTER_BUILD=0` is explicitly set.
- Explicit permission-reset script with a required confirmation flag remains available for local testing.
- Debug/release bundle smoke-verification script.
- Injected, path-correct `SystemPermissionService`.
- Nonmodal asynchronous permission wizard state machine.
- Sequential permission → language first-run coordination.
- Hotkey gating until required permissions are available.
- Exactly-once popup outcome/session counting regression fix.
- Repaired `CNSCore`, `CNSUI`, and `CNSSession` test targets.

## Epoch 01 verification evidence

- All seven Swift package test suites passed through `scripts/swift_verify.sh`.
- `ClickNSpeak` debug build passed.
- Debug and release `.app` bundles passed signature/resource/bundle-ID verification.
- Shell syntax validation passed for all new/modified Swift build scripts.
- Real-model tests were not selected because no model path was supplied; they are owned by Epoch 05.

## Epoch 02 delivered

- Explicit `SessionState` lifecycle with generation-safe startup and derived compatibility flags.
- Cancel-safe recorder startup and stale-start teardown.
- Async single-owner audio stop/drain contract with exactly one final callback.
- Tap quiescence barrier plus privacy-safe overflow/callback timing telemetry.
- Python-aligned `1.0 / 4.0 / 8.0 / 1.0` chunking defaults.
- Idle-only startup, 15-minute, and wake prewarm policy; no hotkey prewarm.
- Idle-deferred health/periodic reload coordination and pre-reload persistence hook.
- Lock-protected, decode-generation-scoped whisper.cpp abort state.
- Idempotent worker completion and popup outcome handling.

## Epoch 02 verification evidence

- `CNSAudio`, `CNSSession`, and `CNSTranscription` focused suites passed.
- Added deterministic coverage for suspended recorder startup cancellation, rapid hotkey bursts, duplicate final/outcome callbacks, stale audio, soft/hard deadlines, periodic reload, and abort-generation isolation.
- All seven Swift package suites and the executable passed through `scripts/swift_verify.sh`.
- Real-model and interactive hardware/sleep tests remain intentionally gated for Epoch 05/10.

## Epoch 03 delivered

- Stable transcriber/editor routers with factual active-runtime descriptors and safe retirement of replaced services.
- Production runtime factory with typed validation failures for missing/corrupt models, credentials, backends, and models; no production `StubTranscriber` fallback.
- Main-actor runtime coordinator with desired/active state, idle-only swaps, latest-generation wins, activation rollback, partial STT-only recovery, and deterministic shutdown.
- App lifecycle wiring for initial activation, live menu intents, credential/model revalidation, retained timers, hotkey gating, and ordered termination.
- Immutable per-session runtime capture used by privacy-safe telemetry and dataset records (`stt_backend`, STT model, AI backend/model).
- Actionable degraded-state categories while keeping the menu responsive and a previous working runtime intact.

## Epoch 03 verification evidence

- Added router tests for before/after swap routing and exactly-once retirement.
- Added coordinator tests for local → Gemini → OpenAI → local activation, failed-candidate rollback, idle deferral, rapid superseding selections, revalidation, and shutdown.
- Added factory tests for missing/partial models, missing credentials, and the production no-stub invariant.
- Added session coverage proving dataset metadata comes from the runtime captured at session start.
- All seven Swift package suites and the executable passed through `scripts/swift_verify.sh`.
- Real credentials, downloaded models, and menu interactions remain an explicit manual matrix for Epoch 10.

## Epoch 04 delivered

- Immutable `MenuState` snapshots for session, permissions, desired/active runtime, downloads, models, autostart, history, updates, suggestions, and dev/release data mode.
- Event-driven status-bar icon changes for idle, recording, processing, and failure states with template assets and a logged fallback.
- Factual permission parent/child icons refreshed on menu open and app activation; the Carbon two-permission contract remains intact.
- Native model/language/editor check states, including distinct active (`on`) and desired/pending (`mixed`) selections and actual `SMAppService` autostart state.
- One injected `PhraseHistory` shared by session and menu, exactly-once invalidation after a successful append, background page loading, five-row pagination, copy icons, and nonmodal copied feedback.
- Stable menu identifiers, deferred structural rebuilds while AppKit is tracking the menu, safe log/config file creation, and an explicit isolated-development-data label.
- Complete menu-owned locale-key coverage across EN/RU/UK/DE/ES/FR and a system-symbol replacement for the missing API-key icon.

## Epoch 04 verification evidence

- Added snapshot tests for session/runtime/download/update/permission/active-vs-desired states and deferred menu rebuild behavior.
- Added asset-resolution/template tests plus static all-locales coverage for every menu translation key.
- Added temporary-file history tests for 0, 1, 5, 6, 2,000, 20,000, and 100,000 rows; the 100k-inclusive matrix completes off the main actor.
- Added copy privacy and exactly-once history invalidation tests; malformed rows no longer log phrase content.
- All seven Swift package suites and the executable passed through `scripts/swift_verify.sh`.

## Epoch 05 delivered

- Typed STT results distinguish success, no speech, guard skips, timeouts, cancellation, and provider failures while keeping transcript, prompt, and audio content out of runtime telemetry.
- Production local whisper.cpp decoding with generation-safe aborts, Python-aligned guards and hallucination filtering, exact tokenizer support, prompt context, language retry behavior, and explicit runtime descriptors.
- Injected, fixture-testable OpenAI and Gemini STT clients with provider-specific language/prompt payloads, bounded error parsing, independent realtime/file timeout policies, transient retry rules, and cancellation.
- Pull-based AVFoundation media decoding to 16 kHz mono Float32, bounded long-file segmentation, ordered transcript assembly, progress, cancellation, and unchanged source files.
- Cancellable file-transcription contract and drag/drop/browse UI wired to the active runtime and optional editor router.
- whisper.cpp build pinned to the accepted `v1.9.1` bake-off release and a model-gated release verification job with documented thresholds.

## Epoch 05 verification evidence

- Fast coverage includes exact audio-guard boundaries, hallucination filters, abort generations, auto-detect language semantics, cloud 4xx/429/5xx/malformed/timeout/cancellation/retry behavior, MIME detection, file segmentation/order/progress/cancellation, telemetry privacy, and runtime-router stability.
- The release 42-phrase real-model suite passed with aggregate WER `0.043`, Russian WER `0.037`, English WER `0.069`, code-switch WER `0.062`, short-command accuracy `0.800`, term recall `0.833`, warm p50/p95 `2.54/5.35 s`, cold p50/p95 `4.57/6.04 s`, and peak RSS `1724 MB`.
- All seven Swift package suites and the executable passed through `scripts/swift_verify.sh` after a clean sequential rebuild.

## Epoch 06 delivered

- Dedicated `CNSEditors` package with pinned MLX Swift, MLX Swift LM, and Swift Transformers dependencies; editor contracts live in dependency-neutral `CNSCore`.
- Real local Qwen 2.5 1.5B 4-bit inference from the app-managed pinned safetensors snapshot with deterministic readiness, shutdown, and cache release.
- One shared `InferenceExecutionGate` serializes local Whisper and Qwen Metal work; realtime acquisition skips immediately while file jobs use bounded waiting and cancellation-safe leases.
- Python-equivalent warm/cold realtime deadlines, independent file policy, sentence-boundary chunking, ordered assembly, conservative output validation, and original-text fallback for every non-success status.
- Native cached memory-pressure decisions skip only local inference; cloud refinement remains independent of the Metal gate and local memory-pressure policy.
- Hardened Gemini HTTP injection, response/error validation, separate realtime/file clients, and overlap ownership that survives caller-facing timeouts.
- Byte-for-byte prompt golden fixtures, dictionary/misrecognition hint routing, mechanical replacement policy, and factual editor status/model dataset metadata.
- Snapshot-aware model registry/downloader support for the pinned multi-file Qwen model.
- Reproducible `mlx.metallib` generation from the pinned upstream Xcode project, versioned build cache, bundle installation, and bundle verification. This closes the command-line SwiftPM resource gap that otherwise crashes MLX at first inference.

## Epoch 06 verification evidence

- `CNSEditors` fast suite passed all prompt, status, concurrency, timeout, memory-pressure, file-ordering, router, and Gemini tests.
- The release model-gated suite loaded the pinned local Qwen snapshot and passed 15 tests across Russian, English, and mixed-language cleanup in approximately 3 seconds after load.
- The exact two-phase CI path (`build-tests` with testing enabled, install metallib, `test --skip-build`) passed, proving the model gate does not depend on an accidental prior bundle resource.
- `CNSCore` passed 67 tests, `CNSTranscription` passed 38 tests, `CNSSession` passed 33 tests, and the executable suite passed 9 tests during the focused integration cycle.
- A release `Click-n-speak.app` was assembled with the 3.6 MB MLX Metal library and passed strict code-signature, resource, executable, and bundle-identifier verification.

## Epoch 07 delivered

- One main-actor `DictionaryCoordinator` owns term, suggestion, replacement, prompt-file, correction, metrics, decay, and config mutations with atomic persistence and coherent snapshot invalidation.
- The confirmation path is session-idempotent and preserves factual raw/editor/final text metadata while ordering dataset, correction-index, history, usage, and analysis updates before delivery cleanup.
- Python-compatible term usage, reactivation, fast/slow decay, script remapping, suggestion modes, 150-phrase cooldown, and initial-prompt rebuilding are connected to the live app.
- Prompt files are written atomically, watched for external replacement/content changes, protected from empty-file loss, and suppressed when changes originate from the app itself.
- Terms, Suggestions, Replacements, and Statistics now reload coordinator state and route mutations through one transactional owner; Statistics includes real trends, dictionary composition, prompt utilisation, failed pairs, and metrics-history access.
- Real 60-second dirty-config flush and hourly guarded maintenance callbacks are wired, with 24-hour decay/metrics and 30-day notification throttles enforced using persisted timestamps.

## Epoch 07 verification evidence

- `CNSDictionary` passed 15 XCTest cases and 20 Swift Testing cases, including the complete correction-to-prompt learning flow, idempotency, watcher guards, all analysis modes, replacement transactions, decay, metrics history, and Python-compatible JSONL/TSV persistence.
- `CNSCore` passed 12 XCTest cases and 67 Swift Testing cases, including exact deterministic 60-second interval boundaries and all config migration fixtures.
- `CNSSession` passed 34 focused tests proving the coordinator receives factual confirmation metadata exactly once; `CNSUI` passed 5 XCTest cases and 30 Swift Testing cases with coordinator-backed panels.
- The integrated `ClickNSpeak` executable built successfully after the final coordinator and Statistics changes. The only remaining compiler warnings are the legacy notification API, owned by Epoch 08.

## Epoch 08 delivered

- Shared reusable-window lifecycle with refresh-before-presentation and fresh task state for data/file panels.
- Language picker parity for the menu's six supported languages, validated primary/additional/auto-detect state, and default/cancel keyboard actions.
- Multi-display popup placement, complete edge clamping, Reduce Motion behavior, final `orderOut` after fades, monitor teardown, localized dictionary context menu, and VoiceOver metadata.
- Coordinator-backed checkbox Suggestions workflow, Terms add/edit/delete/reactivate/revert and filters, replacement conflict feedback, and off-main-actor Statistics computation.
- File browse/drop parity for Python media extensions, progress/cancel, localized failures, editable result, Copy, and Save As.
- Generation-safe model/app download UI with localized progress/speed/ETA, cancellation, retry, and stale-callback rejection.
- Secure provider-specific API-key validation, Keychain error UI, runtime revalidation, and modern `UserNotifications` delivery without deprecated AppKit notification APIs.
- Exact locale-key and placeholder parity across EN/RU/UK/DE/ES/FR, with static raw-string/raw-key/credential-log guards.
- A maintained UI parity inventory documenting lifecycle, keyboard, accessibility, placement, visual baselines, and the signed-app manual matrix.

## Epoch 08 verification evidence

- `CNSUI` passed 10 XCTest cases and 34 Swift Testing cases, including refresh-on-reopen, light/dark PNG rendering, two-display placement, fade teardown, VoiceOver identifiers, file types, credential formats, stale download callbacks, and complete locale/placeholder audits.
- `CNSDictionary` passed 15 XCTest cases and 20 Swift Testing cases after replacement-conflict and asynchronous metrics integration.
- `ClickNSpeak` passed all 9 runtime integration tests and built without warnings after migration to `UserNotifications`.
- Interactive VoiceOver, physical two-display/Retina, and RU/EN/DE signed-app screenshots remain explicitly assigned to the Epoch 10 manual acceptance matrix.

## Epoch 09 delivered

- Immutable versioned manifests for every local Whisper and Qwen artifact, using pinned upstream revisions, exact byte sizes, SHA-256 digests, format declarations, and minimum-version metadata.
- Detached streaming validation with an inode/size/mtime/manifest cache, atomic validate-and-activate replacement, bounded invalid-artifact quarantine, disk-space preflight, and active-model deletion protection.
- Durable explicit HTTP streaming into app-owned partial files, with persisted source identity, HEAD metadata, ETag/Last-Modified validation, strict Range/Content-Range checks, relaunch recovery, and safe restart of only the current artifact when resumption is rejected.
- Factual per-model menu states for downloading, validating, paused/resumable, installed, active, failed, and update available, plus one-model deletion with active-runtime protection.
- `SMAppService` abstraction that re-queries macOS truth at startup/menu open and surfaces enabled, disabled, approval-required, not-found, and registration failure outcomes before persisting configuration.
- Strict update metadata parsing and semantic-version/channel/architecture/minimum-macOS checks, bounded downloads, exact archive size/checksum validation, app-controlled staging, and cancellation cleanup.
- Candidate verification for bundle ID, Team ID/designated requirement, nested signatures, hardened runtime, Gatekeeper, architecture, newer version, reviewed entitlements, and absence of privileged payloads.
- Signed bundled update helper with same-volume backup, startup-token acknowledgement, bounded transaction records, and rollback after install, launch, or acknowledgement failure.
- Hardened Swift application/DMG build scripts with inside-out signing, production fail-closed gates, Keychain-only notarization credentials, staple/assessment checks, and final post-staple release manifest generation.
- An operational release, model-manifest, staged-rollout, and rollback runbook in `EPOCH_09_RELEASE_OPERATIONS.md`.

## Epoch 09 verification evidence

- `CNSCore` passed 29 XCTest and 61 Swift Testing cases, including checksum/format/truncation failures, cache invalidation, atomic activation, durable relaunch state, changed validators, disk limits, autostart states, update metadata, candidate rejection, staging cleanup, swap success, and rollback failure points.
- `CNSUI` passed 10 XCTest and 34 Swift Testing cases after the new model lifecycle and localized state integration. The HUD animation assertion now waits for the bounded AppKit outcome instead of relying on a fixed scheduler delay.
- `ClickNSpeak` built the main executable and `CNSUpdateHelper` and passed all 9 runtime integration tests.
- A real ad-hoc development application passed strict nested/bundle signature, resource, identifier, and architecture checks; its DMG was assembled and its JSON manifest digest matched the final DMG bytes.
- Shell syntax validation passed for every modified release script and the reviewed entitlements plist passed structural validation.
- Developer ID signing/notarization, TCC persistence across an installed update, Launch at Login approval, and process-kill/resume against a real model host remain explicit Epoch 10 external gates because the current machine has no release identity or notary profile.

## Epoch 10 delivered

- A versioned 45-scenario Swift parity manifest covering permissions, recording, popup/injection, STT, editors, runtime switching, history/menu, dictionary/data, lifecycle failures, model/update/distribution operations, accessibility, privacy, soak, and rollback.
- Frozen fail-closed quality and performance thresholds plus sanitized v1–v9 configuration fixtures and a manual-evidence schema.
- A canonical acceptance runner that validates its contracts, runs the complete Swift and Python parity gates, rebuilds and verifies the release app, supports opt-in real-model gates, writes an atomic machine-readable result, and refuses production GO when release-critical evidence is missing.
- Bidirectional Python ↔ Swift configuration compatibility tests using the real Python migration chain; unknown keys survive and corrupt originals are never mutated.
- Content-free session/HUD/popup/editor/process telemetry, an eight-hour/100-session soak analyzer, and a threshold comparator that fail closed on missing or non-finite metrics.
- A signed-release GO/NO-GO template and current candidate report, soak protocol, cutover/rollback runbook, and a guarded backup utility with explicit source/destination paths and checksummed manifests.
- A strict cutover decision: implementation is complete, but Python remains the shipping fallback until all external release-critical gates produce accepted evidence.

## Epoch 10 verification evidence

- `scripts/swift_acceptance.sh --automated-only` completed with **0 failed, 25 passed, and 20 skipped** scenarios; its aggregate decision is correctly **NO-GO** because every skipped scenario is release-critical.
- The acceptance run passed the complete `scripts/swift_verify.sh` gate across all eight Swift packages and the executable, then rebuilt and strictly verified the ad-hoc release `.app`.
- `CNSCore` passed 29 XCTest and 65 Swift Testing cases; `CNSUI` passed 10 XCTest and 34 Swift Testing cases; the final root executable integration rerun passed all 9 cases.
- The Python parity contract passed all 6 tests, including schema v1–v9 migrations, data-copy safety, evidence composition, frozen thresholds, and telemetry privacy.
- The final acceptance skipped Whisper and Qwen real-model jobs because their explicit environment paths were not supplied; signed TCC/update tests, live providers, physical UI/hardware workflows, and the eight-hour soak also remain external evidence requirements.
- The authoritative machine result is `dist/acceptance/swift-acceptance.json`; the candidate decision and remaining blockers are recorded in `docs/releases/SWIFT_1.1.0_RC_GO_NO_GO.md`.
