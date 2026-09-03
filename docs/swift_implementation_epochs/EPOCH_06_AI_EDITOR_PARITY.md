# Epoch 06 — AI Editor Parity

## Objective

Replace the local AI editor stub with real Qwen inference and make local/cloud editor concurrency, timeout, memory-pressure, prompt, and status behavior match Python.

## User-visible result

Optional text cleanup works with the local Qwen model and Gemini. Editor failures never lose the Whisper transcript, overlapping requests are handled predictably, and file refinement can use a longer policy without weakening realtime latency.

## Preconditions

- Epoch 03 provides editor routing and live reconfiguration.
- Epoch 05 provides factual STT outcomes and the file-transcription contract.
- A reproducible local Qwen model fixture/path is available for the model-gated suite.

## Package boundary decision

Create the originally planned `Packages/CNSEditors` package so MLX and editor-specific code do not remain coupled to STT implementation details.

Move or recreate these responsibilities there:

- `AiEditing` protocol and result/status types;
- editor prompts;
- local Qwen editor;
- Gemini editor;
- shared editor locking/timeout helpers.

Update `CNSSession` and the executable target to depend on `CNSEditors`. Keep only STT code in `CNSTranscription`.

Pin the chosen official MLX Swift dependencies to a reviewed version/revision compatible with Swift 6 and macOS 14. Record the pin and model format in the package manifest/documentation; do not follow an unpinned branch.

## Workstream 1 — Preserve the editor protocol contract

Define or retain:

```text
refine(realtime request) → RefineResult
refineFileText(file request) → RefineResult
isReady
descriptor
stop/release
```

Required statuses on every path:

- `ok`;
- `unchanged`;
- `timeout`;
- `skipped`;
- `error`;
- `disabled`;
- `memory_pressure` for the existing dataset-compatible value, if retained.

Document when `memory_pressure` maps to Python's skipped/disabled semantics so dataset interpretation stays stable.

## Workstream 2 — Add a shared Metal execution gate

Whisper.cpp and local Qwen both use Metal. Add a lightweight `InferenceExecutionGate` in a dependency-neutral package, preferably `CNSCore`.

Requirements:

1. Realtime editor acquisition is non-blocking; busy returns `skipped` immediately.
2. File refinement may wait up to the Python-equivalent acquisition timeout.
3. The gate returns an ownership token/lease released in `defer`.
4. Cancellation and thrown errors cannot leak the lease.
5. Local Whisper and Qwen receive the same gate instance from `RuntimeServiceFactory`.
6. Cloud editors use their own request-overlap gate but do not acquire the Metal gate.
7. Unit tests deterministically prove exclusion and release behavior.

## Workstream 3 — Implement local Qwen inference

Implement `LocalAiEditor` using MLX Swift.

1. Resolve the model through injected `Paths`/model registry.
2. Load lazily or during runtime preparation, then publish readiness.
3. Use the same instruction/chat template and generation parameters as Python where supported.
4. Enforce a bounded output size suitable for cleanup rather than free-form generation.
5. Normalize and validate output; return `unchanged` when equivalent to input.
6. Preserve the original Whisper text for timeout/error/skipped paths.
7. Release model/cache deterministically during runtime swap and shutdown.
8. Keep model and tokenizer work off `MainActor`.
9. Do not log input/output text.

## Workstream 4 — Implement memory-pressure behavior

Add a native memory-pressure monitor using `DispatchSource.makeMemoryPressureSource` or the reviewed macOS API selected during implementation.

1. Cache the current pressure decision for approximately five seconds.
2. Skip only local Qwen refinement under high/critical pressure.
3. Never skip Gemini solely because local memory is pressured.
4. Emit privacy-safe status and optionally one throttled user notification.
5. Avoid repeatedly unloading/reloading the model on short pressure oscillations.

## Workstream 5 — Match realtime and file policies

Realtime local editor:

- non-blocking gate acquisition;
- short bounded timeout matching the accepted Python realtime policy;
- original transcript returned for every non-OK status.

File local editor:

- blocking gate acquisition with bounded wait;
- no realtime 8-second cap;
- split very long text only at sentence boundaries;
- keep each segment within the validated model context budget;
- preserve order and cancellation.

Add separate request types or explicit policy values so realtime/file behavior cannot be mixed accidentally.

## Workstream 6 — Harden Gemini editor

Refactor the moved `GeminiEditor`:

1. Inject an HTTP client/URLSession.
2. Use separate realtime and file timeout configurations.
3. Validate HTTP status and bounded error body.
4. Keep the overlap lock owned by the actual HTTP task after the caller-facing realtime timeout until the network request exits.
5. A second request while busy returns `skipped`, not `disabled`.
6. Support cancellation without corrupting lock state.
7. Preserve known terms and misrecognition pairs in the system prompt.
8. Never log API key, source text, or refined text.

## Workstream 7 — Apply prompts, vocabulary, and replacements consistently

1. Port prompts from Python as golden fixtures, not manually paraphrased variants.
2. Pass `collectKnownTerms` and `collectMisrecognitions` for realtime and file flows.
3. Apply manual replacements at the same pipeline point as Python.
4. Keep automatic replacement behavior distinguishable from AI output in dataset metadata if Python does so.
5. Verify punctuation-only and multilingual cases.

## Workstream 8 — Runtime and dataset integration

1. Build editors through `RuntimeServiceFactory`.
2. Rebuild/activate after backend, model, or Keychain changes.
3. Record the actual editor descriptor and exact refine status captured at session start.
4. Do not mark AI edited when output is unchanged or a fallback was used.
5. File jobs use the editor descriptor active for that job generation.

## Expected files

Expected additions:

- `Packages/CNSEditors/Package.swift`
- `Packages/CNSEditors/Sources/CNSEditors/AiEditing.swift`
- `AiEditorPrompts.swift`
- `LocalAiEditor.swift`
- `GeminiEditor.swift`
- editor policy/locking/memory-pressure files
- `Packages/CNSEditors/Tests/CNSEditorsTests/*`
- `Packages/CNSCore/Sources/CNSCore/InferenceExecutionGate.swift`

Primary modifications:

- remove/move editor sources from `CNSTranscription`
- `Packages/CNSSession/Package.swift`
- `ClickNSpeak/Package.swift`
- `SessionController.swift`
- `RuntimeServiceFactory.swift`
- `AppRuntimeCoordinator.swift`
- file-transcription integration
- dataset metadata tests

## Required automated tests

1. Every refine status path.
2. Two overlapping realtime local requests; second is skipped.
3. Whisper holding the Metal gate skips local Qwen but not Gemini.
4. Realtime timeout returns original text while the underlying task releases safely.
5. Gemini caller timeout leaves the overlap gate held until HTTP completion.
6. File acquisition waits and honors cancellation.
7. Sentence-boundary segmentation and ordering.
8. High memory pressure skips only local editor.
9. Prompt golden tests for known terms and misrecognitions.
10. Runtime swap and dataset factual metadata.
11. Model-gated local Qwen golden cleanup corpus.

## Required manual tests

- Local Qwen on Russian, English, and mixed text.
- Enable/disable and local/Gemini switch without restart.
- Trigger overlapping recordings/refinement.
- Simulate network timeout and invalid Gemini key.
- Refine a long file transcript.
- Observe behavior under memory pressure.
- Confirm that any editor failure still presents the original Whisper text.

## Acceptance criteria

- `LocalAiEditor` contains real inference and no stub fallback.
- Realtime editor latency is bounded and cannot block recording indefinitely.
- Local Metal work is serialized; cloud work is not skipped for local memory pressure.
- File refinement uses its own longer policy and sentence-safe segmentation.
- Gemini overlap lock remains correct across caller timeouts.
- Prompts and vocabulary hints match Python fixtures.
- Dataset records factual editor model/status.
- All fast tests and model-gated editor tests pass.

## Non-goals

- Suggestions/decay/metrics integration; Epoch 07 owns it.
- Final panel visual polish; Epoch 08 owns it.
- Model checksum/update distribution policy; Epoch 09 owns it.

## Suggested commit boundaries

1. `refactor: split editors into a dedicated package`
2. `feat: add shared inference execution gate`
3. `feat: implement local Qwen editor`
4. `feat: add local editor memory-pressure policy`
5. `fix: separate realtime and file refinement policies`
6. `fix: harden Gemini concurrency and timeouts`
7. `test: add editor prompt concurrency and model parity suites`
