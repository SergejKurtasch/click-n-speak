# Epoch 01 — Critical Foundation

## Objective

Make Swift development deterministic before any broader feature work:

- ordinary builds no longer erase macOS permissions;
- the permission wizard never blocks the main actor while waiting for System Settings;
- `setup_done` uses the same injected path policy as the rest of the app;
- first-run ordering is deterministic;
- every Swift test target compiles and the known session double-completion regression is fixed;
- one repository-wide verification command exists.

This epoch addresses the highest-impact P0 failures and must be completed first.

## User-visible result

A user can launch a stable signed development build, grant Microphone and Accessibility, return from System Settings, and continue through language/model setup without a two-minute hang. Rebuilding normally does not revoke those permissions.

## Scope

### Workstream 1 — Establish the verification gate

Create `scripts/swift_verify.sh` with fail-fast execution of every Swift package test plus the app build.

Implementation requirements:

1. Resolve the repository root from the script location.
2. Run each package using `swift test --package-path <path>` so the script is independent of the current directory.
3. Run `swift build --package-path ClickNSpeak` last.
4. Print concise package names and preserve the failing command's exit status.
5. Do not download models or access production user data.
6. Add an opt-in environment variable for the real-model transcription suite; default verification may omit the large model job but must print that it was not run.

Restore test compilation:

- Update `Packages/CNSUI/Tests/CNSUITests/UIPanelsTests.swift` for the current panel initializers.
- Update `Packages/CNSUI/Tests/CNSUITests/MenuStructureTests.swift` for the intentional two-permission Carbon architecture; remove Input Monitoring expectations.
- Mark actor-sensitive tests in `Packages/CNSCore/Tests/CNSCoreTests/RuntimeHealthTests.swift` correctly with `@MainActor`/async isolation.
- Replace network-dependent waiting in `UpdateCheckerTests.swift` with an injected HTTP client or `URLProtocol` fixture.
- Remove meaningless tests such as checking a non-optional instance against `nil`; replace them with observable behavior assertions.

### Workstream 2 — Stop normal builds from resetting TCC

Modify `scripts/swift_build_app.sh`:

1. Remove all normal-path `tccutil reset` calls.
2. Keep the bundle identifier fixed at `com.sergej.clicknspeak`.
3. Prefer a stable Apple Development signing identity for development bundles when configured.
4. Keep ad-hoc signing as an explicitly labeled fallback, not a production path.
5. Print the resulting signing identity and app location at the end of the build.

Create `scripts/swift_reset_permissions_for_testing.sh`:

1. Require an explicit confirmation flag such as `--confirm-reset`.
2. Reset only Microphone and Accessibility for the fixed bundle ID.
3. Do not reset Input Monitoring; Carbon hotkey does not use it.
4. Explain in the script help that the command is destructive to existing TCC grants.

Create `scripts/swift_verify_bundle.sh`:

1. Verify bundle ID, executable existence, entitlements, and signature.
2. Run `codesign --verify --strict` against the assembled app.
3. Fail if the expected `Info.plist`, locales, icons, or executable are missing.
4. Keep notarization checks out of this epoch; Epoch 09 owns distribution notarization.

### Workstream 3 — Make permissions injectable and testable

Refactor `Packages/CNSCore/Sources/CNSCore/Permissions.swift`.

Target design:

- Introduce a `PermissionServicing` protocol for microphone status/request, Accessibility status/request, opening Settings, and setup-flag operations.
- Implement `SystemPermissionService` with an injected `setupDoneURL` or injected `Paths`.
- Keep read-only TCC checks callable without holding `MainActor`.
- Restrict AppKit operations such as opening System Settings to `@MainActor` methods.
- Use `AXIsProcessTrustedWithOptions` with the prompt option for the explicit first Accessibility request.
- Preserve the intentional two-permission model: Microphone and Accessibility only.

Required semantics:

1. `isSetupDone` reads the injected `paths.setupDoneFile`.
2. `markSetupDone` creates the parent directory and propagates/logs a specific error instead of silently swallowing all failures.
3. A test service can drive `.undetermined`, `.denied`, `.restricted`, and `.granted` transitions without touching real TCC.
4. No service method reads or writes a hard-coded Application Support path.

Add `Packages/CNSCore/Tests/CNSCoreTests/PermissionServiceTests.swift` covering path isolation and setup-flag semantics in a temporary directory.

### Workstream 4 — Replace the blocking wizard with a state machine

Refactor `Packages/CNSUI/Sources/CNSUI/SetupWizard.swift` into an instance-based `@MainActor` controller. Do not retain the current static `Task` plus `runModal()` waiting design.

Recommended states:

```text
idle
welcome
microphoneExplanation
requestingMicrophone
microphoneDenied
accessibilityExplanation
waitingForAccessibility
complete
skipped
failed
```

Implementation requirements:

1. Inject `PermissionServicing` and `I18n`.
2. Expose one async entry point returning a typed result: `completed`, `skipped`, or `incomplete`.
3. Use callback-based alerts/sheets or a dedicated `NSPanel`; never keep a blocking modal alert open while polling an external permission.
4. Poll Accessibility on a cancellable task that sleeps off the main actor and hops to `MainActor` only for UI updates.
5. Recheck immediately when the app becomes active after System Settings.
6. Distinguish user Skip from timeout/closing the window.
7. Cancel polling and remove observers on every terminal path.
8. Guard against a second concurrent wizard instance.
9. Do not require an app restart for the Carbon hotkey path.
10. Localize every visible string and remove stale Input Monitoring text.

Setup-flag rules:

- Mark complete after both permissions are granted.
- Mark complete after an explicit Skip.
- Do not mark complete after timeout, window close, error, or incomplete permission state.

Add UI-level coordinator tests using a fake permission service and a fake alert presenter. Do not invoke real `NSAlert.runModal()` in unit tests.

### Workstream 5 — Make first-run orchestration deterministic

Refactor `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift` and add `ClickNSpeak/Sources/ClickNSpeak/AppLaunchCoordinator.swift`.

Required sequence:

```text
acquire instance lock
→ resolve one Paths value
→ load config/i18n/logging
→ run permission flow if required
→ run language picker if required
→ check/download required model
→ construct/start runtime services
→ enter ready state
```

Implementation requirements:

1. Pass the same `Paths` and `SystemPermissionService` through the complete launch flow.
2. Replace the current wizard/language `if ... else if` branch with sequential outcomes in the same launch.
3. Do not start recording when Microphone permission is missing.
4. Keep the menu available in a limited setup state so the user can retry permissions.
5. If Accessibility is missing but Microphone is granted, explicitly choose and test one behavior: transcription with copy-only delivery, or recording disabled. The UI must explain the chosen behavior.
6. Start model download only after the setup/language decision has completed.
7. Surface launch failures in a recoverable menu state; do not silently continue with unusable services.

### Workstream 6 — Fix the known test-blocking session regression

Make the smallest correct change in `Packages/CNSSession/Sources/CNSSession/SessionController.swift` so canceling an already-finalized popup does not call session completion a second time.

Requirements:

1. `completedSessions` increments exactly once per transcription session.
2. Model reload occurs exactly once at session 20.
3. `session_end` telemetry remains exactly once for the user outcome.
4. Extend the existing failing test with repeated Escape/cancel callback protection.
5. Defer the broader session/audio redesign to Epoch 02.

## Expected files

Primary modifications:

- `scripts/swift_build_app.sh`
- `Packages/CNSCore/Sources/CNSCore/Permissions.swift`
- `Packages/CNSUI/Sources/CNSUI/SetupWizard.swift`
- `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift`
- `Packages/CNSSession/Sources/CNSSession/SessionController.swift`
- affected tests in `CNSCoreTests`, `CNSUITests`, and `CNSSessionTests`
- locale JSON files if stale permission strings must be removed

Expected additions:

- `scripts/swift_verify.sh`
- `scripts/swift_verify_bundle.sh`
- `scripts/swift_reset_permissions_for_testing.sh`
- `ClickNSpeak/Sources/ClickNSpeak/AppLaunchCoordinator.swift`
- permission/wizard coordinator tests and test doubles

## Required automated verification

1. Run `scripts/swift_verify.sh`.
2. Build both debug and release app bundles.
3. Run `scripts/swift_verify_bundle.sh` against each assembled bundle.
4. Verify no test reads the production Application Support directory.
5. Verify the normal build script contains no `tccutil reset` invocation.

## Required manual verification

Test with a stable signed app from a stable filesystem path:

1. Both permissions undetermined.
2. Microphone granted, Accessibility denied.
3. Previously denied Microphone enabled while Settings is open.
4. Accessibility enabled while the waiting UI is visible.
5. User explicitly skips.
6. User closes without granting.
7. Relaunch after incomplete setup.
8. Rebuild/reinstall without losing granted permissions.
9. Russian, English, and German UI.

Record timings. No permission transition may freeze the UI or leave it unresponsive for the 120-second timeout.

## Acceptance criteria

- All Swift test targets compile and pass.
- `scripts/swift_verify.sh` is the documented canonical gate.
- Ordinary debug/release builds do not reset TCC.
- The wizard remains responsive while System Settings is open.
- Permission state is reflected within one second after the app becomes active.
- `setup_done` is written only for complete or explicit-skip outcomes and uses the injected path.
- Language selection can follow permission completion in the same launch.
- A canceled popup does not double-count a completed session.
- No production data is modified by automated verification.

## Non-goals

- Full session/audio state-machine rewrite.
- Dynamic model/backend replacement.
- Menu visual parity beyond the permission/setup state required for this flow.
- Local Qwen implementation.
- Notarized production distribution.

## Suggested commit boundaries

1. `test: add Swift verification gate and repair test compilation`
2. `fix: preserve TCC permissions across Swift builds`
3. `refactor: make permission state injectable`
4. `fix: replace blocking permission wizard flow`
5. `fix: make first-run setup sequential`
6. `fix: complete canceled sessions exactly once`
