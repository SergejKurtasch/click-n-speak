# Epoch 05 — STT Production Parity

## Objective

Complete and verify all speech-to-text paths: local realtime whisper.cpp, cloud realtime providers, and local/cloud file transcription. Match Python prompt, language, guard, timeout, error, and quality behavior.

## User-visible result

Realtime dictation and file transcription work with every advertised backend. Missing models, invalid keys, unsupported files, network failures, and timeouts produce specific recoverable errors instead of empty unexplained results.

## Preconditions

- Epoch 02 provides generation-safe sessions and watchdogs.
- Epoch 03 provides runtime service activation and factual descriptors.
- The selected local whisper.cpp model can be supplied to the model-gated test job.

## Workstream 1 — Formalize STT outcomes

Extend `Transcribing` without breaking the realtime pipeline.

Current `.empty` conflates guard skips, no speech, provider failure, timeout, and abort. Introduce a typed outcome/error model while preserving a compatibility text helper if needed.

Recommended result metadata:

- text;
- detected language when actually reported;
- outcome: success, noSpeech, guarded, timedOut, aborted, failed;
- actual backend/model descriptor;
- retry count;
- decode duration.

Requirements:

1. Transcript text remains absent from telemetry.
2. Session UI can distinguish no speech from a failed provider.
3. Dataset records only successful/edited user flows but retain factual status metadata.
4. Abort and timeout are separate outcomes.

## Workstream 2 — Complete local whisper.cpp realtime behavior

Modify `WhisperCppTranscriber.swift`, `GuardedTranscriber.swift`, `AudioGuards.swift`, `HallucinationFilter.swift`, and `ChunkContextBuilder.swift`.

1. Preserve the two-stage audio guards:
   - final chunk at or below 0.5 seconds is skipped;
   - non-final chunk shorter than 3 seconds and below the RMS threshold is skipped.
2. Preserve vocabulary prompt plus whole recent chunks without splitting a chunk mid-text.
3. Verify exact tokenizer budgeting against the engine tokenizer.
4. Port Python language filtering/retry behavior, including the silence-padding retry where applicable.
5. Keep hallucination phrase, repetition, subword repetition, and suspicious-script behavior aligned with Python fixtures.
6. Replace production `try!` regex construction with deterministic validated initialization.
7. Implement explicit warm and cold decode deadlines used by the session watchdog policy.
8. Ensure abort callbacks are generation-safe from Epoch 02.
9. Record only duration/backend/model/guard reason in telemetry.
10. Verify model context release and reload do not leak Metal memory.

## Workstream 3 — Build a real-model golden suite

Extend `WhisperCppTranscriberTests.swift` and add test fixtures under a non-user-data fixture directory.

1. Reuse the existing bake-off Russian/English/code-switch corpus where licensing and repository size permit.
2. Store expected normalized transcripts and language expectations.
3. Run through `GuardedTranscriber` and the same context builder used by the app.
4. Measure WER, code-switch WER, short-command accuracy, warm p50/p95, cold p50/p95, and peak RSS.
5. Require an explicit model path environment variable.
6. In normal fast tests, report the job as not selected rather than presenting a skipped model test as parity evidence.
7. Add a documented full command to `scripts/swift_verify.sh`.

Release thresholds must be copied from the accepted bake-off/Python baseline and stored beside the corpus, not embedded as undocumented numbers.

## Workstream 4 — Correct cloud realtime STT

Refactor `CloudSTTTranscriber.swift` and provider request models.

1. Inject an HTTP client/URLSession so requests are fixture-testable.
2. Use separate session configurations for realtime and file operations.
3. Set explicit connect, request, and resource timeouts.
4. Validate all non-2xx responses and decode a bounded provider error message.
5. Never log request audio, prompt, API key, or returned transcript.
6. Pass language hints only when the provider supports them.
7. Pass initial prompt/context according to each provider contract.
8. Do not fabricate detected language from `allowedLanguages.first`.
9. Add bounded retry with jitter only for safe transient errors such as connection loss, 429, and selected 5xx responses.
10. Respect task cancellation immediately and report an aborted outcome.
11. Encode PCM/WAV once per request and avoid extra full-buffer copies where practical.

## Workstream 5 — Implement local file transcription

Implement `WhisperCppTranscriber.transcribeFile` behind a richer file-transcription protocol rather than returning one unstructured string.

Recommended additions:

- `FileTranscriptionRequest` with URL, prompt, language policy, optional refinement flag;
- `FileTranscriptionProgress` with preparation/segment/transcription/refinement stages;
- `FileTranscriptionResult` with text, actual backend/model, language, and status.

Implementation requirements:

1. Decode supported audio/video containers off `MainActor` using AVFoundation.
2. Convert to 16 kHz mono Float32.
3. Segment long media with bounded memory use and sentence-safe text assembly.
4. Forward vocabulary prompt and language policy.
5. Publish progress through `AsyncStream` or an injected callback.
6. Support cancellation between segments and abort the current decode safely.
7. Clean temporary files on success, failure, and cancellation.
8. Preserve input files unchanged.

## Workstream 6 — Correct cloud file transcription

1. Detect the real container/MIME type; never label arbitrary mp3/m4a bytes as wav.
2. Use the provider's supported multipart/upload path or convert locally to a supported format.
3. Avoid unbounded inline base64 for large files.
4. Use the file-specific timeout policy, independent of realtime URLSession limits.
5. Publish upload and processing progress when the API permits it.
6. Bound provider error-body memory.
7. Cancel upload/server polling cleanly.

## Workstream 7 — Wire the file UI contract

Modify `FileDropPanel.swift` only enough to consume the new service contract; Epoch 08 owns final appearance.

1. Support drag-and-drop and `NSOpenPanel` browse.
2. Validate extension/type before starting.
3. Show progress, cancel, success, and actionable error states.
4. Use the active runtime selected by Epoch 03.
5. Route optional AI refinement through the editor router; Epoch 06 completes its implementation.
6. Keep all file decoding/network work off `MainActor`.

## Expected files

- `Packages/CNSTranscription/Sources/CNSTranscription/Transcribing.swift`
- new STT outcome and file-transcription types
- `WhisperCppTranscriber.swift`
- `CloudSTTTranscriber.swift`
- `CloudSTTModels.swift`
- `GuardedTranscriber.swift`
- `AudioGuards.swift`
- `HallucinationFilter.swift`
- `ChunkContextBuilder.swift`
- `Packages/CNSUI/Sources/CNSUI/FileDropPanel.swift`
- runtime/session adaptations for typed results
- local and HTTP-fixture test files
- golden corpus manifest and verification script support

## Required automated tests

1. Guard thresholds at exact boundaries.
2. Language hint absent in auto-detect mode.
3. Provider-specific prompt/language request payloads.
4. HTTP 400, 401, 429, 500, malformed response, timeout, cancellation, and retry exhaustion.
5. MIME detection for wav, mp3, m4a, and supported video fixtures.
6. Long-file segmentation, ordering, progress, cancellation, and cleanup.
7. Local real-model golden suite in the full job.
8. No transcript/prompt/audio fields in emitted telemetry.
9. Runtime router uses the active descriptor throughout a file job.

## Required manual tests

- Warm and cold local dictation in Russian, English, and code-switch speech.
- Gemini/OpenAI realtime with valid, invalid, and removed keys.
- Network loss during a cloud request.
- Short wav, mp3, m4a, video-with-audio, and one-hour fixture.
- Cancel local and cloud file jobs at multiple stages.
- Sleep/wake and memory-pressure checks around local model use.

## Acceptance criteria

- Local quality and latency meet the recorded baseline thresholds.
- No advertised file/backend path remains “not implemented.”
- No cloud path fabricates language or mislabels media type.
- Realtime and file timeout policies are independent.
- Errors are typed, actionable, and privacy-safe.
- Long file processing is bounded, cancellable, and off the main actor.
- Model reload releases resources and the full Swift verification gate passes.

## Non-goals

- Real local Qwen implementation; Epoch 06 owns it.
- Final panel visuals/localization; Epoch 08 owns them.
- Distribution/model checksum policy; Epoch 09 owns release hardening.

## Suggested commit boundaries

1. `refactor: expose typed transcription outcomes`
2. `fix: align local Whisper guards language and timeouts`
3. `test: add real-model transcription parity suite`
4. `fix: harden cloud STT requests and errors`
5. `feat: implement local file transcription`
6. `feat: implement cloud file transcription`
7. `feat: wire cancellable file transcription progress`
