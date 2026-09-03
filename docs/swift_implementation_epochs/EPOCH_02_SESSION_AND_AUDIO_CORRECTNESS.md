# Epoch 02 — Session and Audio Correctness

## Objective

Replace the fragile Boolean-driven start/stop flow with an explicit, generation-safe session state machine. Guarantee exactly one audio stream, worker, final chunk, and cleanup per session.

## User-visible result

Rapid hotkey presses, short recordings, decode timeouts, popup cancellation, sleep/wake, and microphone failures no longer produce stuck recording state, lost speech, duplicate session counts, or audio leaking into the next recording.

## Preconditions

- Epoch 01 is complete.
- The repository-wide Swift verification gate is green.
- Permission setup no longer races with recorder startup.

## Target state model

Define a public/read-only state snapshot and keep mutable transitions inside `SessionController` on `@MainActor`:

```text
idle
starting(sessionID, targetPID, appendMode)
recording(sessionID, targetPID, appendMode)
stopping(sessionID)
processing(sessionID, overdue)
popup(sessionID, targetPID)
injecting(sessionID, targetPID)
failed(recoverable, message)
```

The exact enum may differ, but it must make illegal combinations such as `isRecording == true && recorderStartPending == true && isProcessing == true` unrepresentable.

## Workstream 1 — Introduce explicit transitions

Modify `Packages/CNSSession/Sources/CNSSession/SessionController.swift`.

1. Introduce `SessionState` and a monotonic `SessionID`/generation.
2. Keep compatibility read-only properties such as `isRecording` only if needed by callers; derive them from `SessionState`.
3. Centralize transitions in named methods and assert/log rejected transitions without transcript content.
4. Add one idempotent `completeSession(id:reason:)` path.
5. Remove dead or competing cleanup methods, including `doFinishCleanup()`.
6. Ensure popup display ends processing but does not count the same session again on Enter/Escape.
7. Ensure user outcome telemetry is emitted once and separately from worker completion telemetry.
8. Preserve append-to-popup and the original target PID across the appended recording.

## Workstream 2 — Make recorder startup cancel-safe

Current recorder startup runs asynchronously after state is marked recording. Replace this with a generation-aware handshake.

1. Store the startup task for the active session.
2. Transition `idle → starting` before invoking `AudioRecorder.start`.
3. Transition to `recording` only after `start` succeeds for the same session ID.
4. A second hotkey during `starting` must request cancellation and wait for start cleanup; the AVAudioEngine must not begin after the session was stopped.
5. On startup failure, finish the chunk stream, hide/update the panel, and return to a recoverable state exactly once.
6. A stale completion from an older start task must stop its engine and perform no UI/state mutation.

Extend `SessionDoubles.swift` with a recorder whose `start()` can be suspended and resumed deterministically.

## Workstream 3 — Guarantee final-tail delivery

Modify `Packages/CNSAudio/Sources/CNSAudio/AudioRecorder.swift` and, if needed, `RingBuffer.swift`.

1. Define one owner of stop ordering.
2. Stop accepting new tap samples.
3. Remove/stop the AVAudioEngine tap.
4. Signal the consumer to drain all already-written samples.
5. Await consumer completion or perform the final drain under a synchronization contract.
6. Emit exactly one final callback.
7. Only then clear callbacks, converter, buffers, and tasks.

Do not cancel the consumer and concurrently call `readAll()` without knowing which samples the consumer already owns.

Add deterministic tests for:

- samples written immediately before stop;
- consumer holding a batch during stop;
- multiple stop calls;
- start after a fully stopped stream;
- stale callbacks after a new session begins.

## Workstream 4 — Keep real-time work bounded

Instrument the AVAudioEngine tap and document its contract.

1. The tap may copy/write bounded audio data and update lock-free/short-lock state.
2. Move AVAudioConverter work and `[Float]` allocation to the consumer task if Instruments shows they execute in the real-time callback.
3. Expose ring-buffer overflow count through a privacy-safe callback or telemetry field.
4. Never log samples or transcript content.
5. Add a stress test with a deliberately slow consumer and verify the overflow policy is bounded and observable.

## Workstream 5 — Restore the Python warmup/health policy

Modify `SessionController`, `RuntimeHealth`, and app lifecycle wiring.

1. Remove `transcriber.preWarm()` from `beginStart()`.
2. Add startup warmup after the model is ready and before entering normal idle.
3. Schedule 15-minute keepalive only while idle.
4. Observe macOS wake and schedule an idle prewarm.
5. Apply health-triggered reload only while idle and respect the 20-minute cooldown.
6. Keep the every-20-completed-sessions reload as a fallback.
7. Flush dirty configuration before reload once Epoch 07 maintenance is connected; define the hook now.

## Workstream 6 — Make abort state thread-safe

Modify `Packages/CNSTranscription/Sources/CNSTranscription/WhisperCppTranscriber.swift`.

1. Replace the `@unchecked Sendable` mutable Boolean abort flag with a lock-protected or atomic value.
2. Reset the flag for each decode generation.
3. Ensure an abort intended for session N cannot abort session N+1.
4. Verify hard watchdog abort releases the blocked decode and model reload happens once.

## Workstream 7 — Align defaults and error recovery

1. Align fresh/fallback chunking defaults with Python: silence `1.0`, target `4.0`, max `8.0`, min speech `1.0`.
2. Treat recorder fatal errors as restart-required while keeping menu actions available.
3. Distinguish no-speech, recorder error, decode timeout, and hard-abort states in UI/telemetry.
4. Do not clear processing state at the soft deadline.

## Expected files

- `Packages/CNSSession/Sources/CNSSession/SessionController.swift`
- optionally a new `Packages/CNSSession/Sources/CNSSession/SessionState.swift`
- `Packages/CNSAudio/Sources/CNSAudio/AudioRecorder.swift`
- `Packages/CNSAudio/Sources/CNSAudio/RingBuffer.swift`
- `Packages/CNSCore/Sources/CNSCore/RuntimeHealth.swift`
- `Packages/CNSTranscription/Sources/CNSTranscription/WhisperCppTranscriber.swift`
- `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift` or launch coordinator lifecycle hooks
- corresponding tests in `CNSAudioTests`, `CNSSessionTests`, and `CNSTranscriptionTests`

## Required automated tests

1. Stop before recorder startup completes.
2. Thirty rapid hotkey toggles with deterministic fake time.
3. Duplicate stop/confirm/cancel callbacks.
4. Final callback racing with consumer drain.
5. Stale audio and decode callbacks from a previous generation.
6. Soft timeout preserves blocked processing state.
7. Hard timeout aborts and reloads once.
8. Append-to-popup preserves target PID.
9. Session 20 reloads once; repeated popup callbacks do not change the count.
10. No hotkey path invokes prewarm.

Run `scripts/swift_verify.sh` after package-level tests.

## Required manual tests

- Short speech, long speech, and silence.
- Rapid Option+Space start/stop cycles.
- Stop immediately after start cue.
- Sleep/wake while idle and while recording.
- Disconnect or change the input device.
- Open popup, start an appended recording, then confirm/cancel.
- Trigger a controlled slow decode and observe “Still working…” without accepting a new recording.

## Acceptance criteria

- Exactly one completion and one user outcome per session ID.
- No engine starts after its session was canceled.
- No final-tail samples are lost or delivered to the next session.
- No stale decode can update the popup.
- Soft timeout never clears processing; hard timeout aborts/reloads once.
- Hotkey startup does not queue synthetic prewarm work.
- Default chunking values match Python.
- Runtime telemetry exposes overflow and timing without private content.
- The full Swift verification gate passes.

## Non-goals

- Dynamic replacement of STT/editor services; Epoch 03 owns it.
- Menu visual redesign; Epoch 04 owns it.
- Cloud/file STT behavior; Epoch 05 owns it.
- Dictionary maintenance and metrics; Epoch 07 owns them.

## Suggested commit boundaries

1. `refactor: model session lifecycle explicitly`
2. `fix: make recorder startup generation-safe`
3. `fix: drain final audio exactly once`
4. `fix: make Whisper abort generation-safe`
5. `fix: restore idle-only warmup policy`
6. `test: cover session and audio lifecycle races`
