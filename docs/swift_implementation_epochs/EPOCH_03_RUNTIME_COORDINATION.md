# Epoch 03 — Runtime Coordination and Live Reconfiguration

## Objective

Make the active runtime match the user's selected configuration. Model, STT backend, AI editor, and API-key changes must take effect safely without restarting the app and without silently replacing a failed service with a stub.

## User-visible result

When a user selects local Whisper, Gemini, OpenAI, a different model, or a different AI editor, the menu shows a pending state, validates prerequisites, activates the new service while idle, and then shows it as active. A failed activation leaves the previous working service intact and explains the failure.

## Preconditions

- Epoch 01 has deterministic startup and permissions.
- Epoch 02 exposes a reliable idle/non-idle session state.
- The full Swift verification gate is green.

## Architectural decision

Keep cross-package composition in the executable target to avoid dependency cycles.

Add `AppRuntimeCoordinator` under `ClickNSpeak/Sources/ClickNSpeak`. It owns desired and active runtime configuration and uses swappable protocol routers that `SessionController` can retain for its lifetime.

Recommended collaborators:

- `TranscriberRouter`: actor conforming to `Transcribing`, forwarding to the currently active engine.
- `AiEditorRouter`: actor conforming to `AiEditing`, forwarding to the active editor or returning `.disabled`.
- `RuntimeServiceFactory`: builds concrete local/cloud engines from validated configuration.
- `AppRuntimeCoordinator`: `@MainActor` orchestration, state publication, persistence, and safe swap timing.

If Swift protocol isolation makes a router unsuitable, recreate `SessionController` only through a single coordinator-owned factory and atomically rebind hotkey/menu callbacks. Do not allow ad hoc recreation from menu actions.

## Runtime state model

Define a sendable state snapshot:

```text
uninitialized
preparing(desired)
ready(active)
reconfiguring(active, desired)
degraded(active?, actionableError)
stopping
```

`active` must include the actual STT backend/model and AI editor backend/model. Never infer active runtime solely from `Config`.

## Workstream 1 — Add routers and runtime descriptors

In `CNSTranscription`:

1. Add a stable `TranscriberDescriptor` containing backend, model ID, local/cloud kind, and readiness.
2. Add an equivalent `AiEditorDescriptor`.
3. Implement `TranscriberRouter` with serialized `install`, `currentDescriptor`, and protocol forwarding.
4. During a swap, allow an in-flight call to finish or abort it only through an explicit coordinator policy; do not deallocate an engine under an active decode.
5. On successful install, stop the old engine after the new one is ready.
6. On failed preparation, keep forwarding to the old engine.
7. Implement `AiEditorRouter` with the same active/desired distinction.

Tests must prove that requests before and after a swap reach the expected backend and that a failed candidate never replaces the active engine.

## Workstream 2 — Implement the service factory

Add `ClickNSpeak/Sources/ClickNSpeak/RuntimeServiceFactory.swift`.

Inputs:

- `Config`;
- injected `Paths`;
- model registry/manager;
- Keychain credential provider;
- logger;
- shared Metal execution gate required later by Epoch 06.

Factory behavior:

1. Validate local model file existence and basic integrity before creating Whisper.
2. Resolve Gemini/OpenAI keys by the canonical Keychain service/account names.
3. Return typed preparation errors: model missing, credential missing, unsupported backend, corrupted model, initialization failure.
4. Never return `StubTranscriber` in a normal app build.
5. Permit a stub only through an explicit test/demo dependency.
6. Wrap concrete STT engines with `GuardedTranscriber` in one place.
7. Build an editor only when enabled and prerequisites are satisfied.

## Workstream 3 — Implement `AppRuntimeCoordinator`

Add `ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift`.

Responsibilities:

1. Own `desiredConfig` and `activeRuntime`.
2. Receive config-change intents from menu/panels rather than already-persisted “active” changes.
3. Classify changes:
   - immediate data-only update;
   - requires STT replacement;
   - requires editor replacement;
   - requires both;
   - requires app restart.
4. Wait for `SessionController` to become idle before swapping inference services.
5. Prepare and warm the candidate service before marking it active.
6. Persist config only after successful activation, or persist desired state separately with an explicit pending/error marker.
7. Publish state changes to menu and diagnostics.
8. Serialize multiple rapid selection changes; the latest desired generation wins.
9. Cancel or supersede obsolete candidate preparation without touching the active service.
10. Provide a deterministic `shutdown()` that stops routers and pending tasks.

## Workstream 4 — Rewire `AppDelegate`

Refactor `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift`:

1. Remove inline transcriber/editor selection blocks.
2. Construct routers and `SessionController` once.
3. Construct `AppRuntimeCoordinator` and perform initial activation after permissions/language/model setup.
4. Bind menu config intents to coordinator methods.
5. Bind API-key save completion to a coordinator revalidation request.
6. Bind model download completion to candidate validation and activation.
7. Retain and invalidate the background update timer.
8. On app termination, stop hotkey, cancel session work, stop recorder, shutdown runtime, flush state/logs, and release the instance lock in that order.

## Workstream 5 — Make session metadata factual

Modify `SessionController` data logging:

1. Obtain an immutable runtime descriptor at session start.
2. Carry that descriptor through the session generation.
3. Write the actual STT model ID, backend, AI model, and refine status to dataset records.
4. Do not use mutable `config.sttBackend` as a proxy for the engine that produced the transcript.
5. Use the same descriptor in privacy-safe telemetry.

## Workstream 6 — Add actionable degraded states

Define user-facing recovery actions:

- Missing local model → Download / Select Cloud Backend.
- Missing API key → Open API Keys.
- Invalid key → Edit Key / Keep Previous Backend.
- Model initialization failure → Retry / Re-download / Keep Previous Backend.
- No active STT at first launch → recording disabled with a clear menu status.

The status-bar app must remain responsive and configurable in a degraded state.

## Expected files

Expected additions:

- `ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift`
- `ClickNSpeak/Sources/ClickNSpeak/RuntimeServiceFactory.swift`
- `Packages/CNSTranscription/Sources/CNSTranscription/TranscriberRouter.swift`
- `Packages/CNSTranscription/Sources/CNSTranscription/AiEditorRouter.swift`
- runtime coordinator/router tests

Primary modifications:

- `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift`
- `Packages/CNSSession/Sources/CNSSession/SessionController.swift`
- `Packages/CNSTranscription/Sources/CNSTranscription/Transcribing.swift`
- `Packages/CNSTranscription/Sources/CNSTranscription/AiEditing.swift`
- menu callbacks and model-download completion wiring
- dataset record types if factual backend/model fields require expansion

## Required automated tests

1. Local → Gemini → OpenAI → local activation.
2. Missing credential leaves previous engine active.
3. Missing/corrupt model leaves previous engine active.
4. Selection during recording remains pending until idle.
5. Two rapid selections install only the newest generation.
6. Model download completion activates the desired model once.
7. API-key update activates the pending cloud backend.
8. Dataset metadata identifies the actual engine used at session start.
9. Shutdown stops active and pending services once.
10. Production factory cannot create `StubTranscriber`.

## Required manual tests

- Change every STT backend from the menu without restarting.
- Change local model after a completed download.
- Remove or invalidate a key and verify recovery UI.
- Change backend while recording and observe pending state.
- Quit while a new model is warming.
- Relaunch and confirm persisted desired/active state converges correctly.

## Acceptance criteria

- The next idle session uses the newly activated backend/model/editor.
- The menu distinguishes desired, preparing, active, and failed states.
- Failed activation never destroys the previous working runtime.
- Missing prerequisites never produce silent empty transcripts through a stub.
- Dataset and telemetry report the actual service used.
- All active/pending runtime work is stopped on termination.
- The full Swift verification gate passes.

## Non-goals

- Full STT algorithm/file-flow parity; Epoch 05 owns it.
- Real local Qwen inference; Epoch 06 owns it.
- Final menu visuals; Epoch 04 owns them.
- Update signature/notarization flow; Epoch 09 owns it.

## Suggested commit boundaries

1. `feat: add swappable transcription and editor routers`
2. `feat: add runtime service factory`
3. `refactor: coordinate active and desired runtime state`
4. `refactor: wire app lifecycle through runtime coordinator`
5. `fix: log factual runtime model metadata`
6. `test: cover runtime activation and rollback`
