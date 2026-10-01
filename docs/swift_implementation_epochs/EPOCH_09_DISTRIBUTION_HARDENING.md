# Epoch 09 — Model Lifecycle, Autostart, Updates, and Distribution Hardening

## Objective

Make model downloads, launch-at-login, application updates, signing, notarization, installation, and rollback safe enough for a production Swift release.

## User-visible result

Models download and validate reliably, Launch at Login reflects macOS truth, signed updates install without losing permissions, and a failed or tampered update rolls back instead of breaking the application.

## Preconditions

- Epoch 01 established stable development signing and no automatic TCC resets.
- Epoch 03 owns runtime activation and shutdown.
- Epoch 08 completed all model/update/key UI states.
- Release Team ID, Developer ID certificate, notarization credentials, and distribution channel are available through secure build configuration.

## Security invariants

1. Never activate a model based only on existence or a minimal file-size check.
2. Never execute/install an update that fails bundle ID, Team ID, signature, version, or notarization validation.
3. Never log credentials, API keys, notarization secrets, or signed download URLs.
4. Never overwrite the only working application before a validated replacement and rollback path exist.
5. Never use `xattr -dr com.apple.quarantine` as a substitute for signing/notarization.

## Workstream 1 — Define validated model artifacts

Extend `ModelRegistry.swift`/`ModelCatalog.swift` with an immutable artifact manifest:

- model ID and backend;
- expected file name;
- expected byte size or accepted range;
- cryptographic checksum;
- download URL/source version;
- model format/version;
- optional minimum app version.

Requirements:

1. Keep the manifest versioned with the app or fetch a signed manifest.
2. Verify checksum off `MainActor` before activation.
3. Download to a `.partial` staging file and rename atomically only after validation.
4. Quarantine/delete invalid partial artifacts without replacing a working model.
5. Publish validation progress and errors to runtime/menu state.
6. Protect the active model from deletion until RuntimeCoordinator switches away.

## Workstream 2 — Make downloads resumable and recoverable

Refactor `ModelDownloader.swift` and `ModelManager.swift`.

1. Persist resume metadata or use a durable range-download strategy.
2. Validate server range/ETag/Last-Modified before resuming.
3. If resumption is unsafe, discard only the partial file and restart cleanly.
4. Restore download state after relaunch.
5. Support one active download per artifact and serialize conflicting actions.
6. On cancel, keep or remove partial data according to the documented resume policy.
7. Do not retain stale callbacks after panel close/runtime shutdown.
8. Add disk-space preflight and actionable insufficient-space errors.
9. Ensure model directory creation and writes use injected `Paths`.

## Workstream 3 — Complete per-model lifecycle UI/actions

1. Show installed, validating, downloading, paused/resumable, failed, active, and update-available states.
2. Allow deleting one inactive model at a time.
3. Require a safe backend switch before deleting the active model.
4. Revalidate existing model files at startup without hashing repeatedly on every menu open; cache validation by inode/size/mtime plus manifest version.
5. Activate newly validated models through RuntimeCoordinator, never directly from the downloader callback.

## Workstream 4 — Make autostart reflect system truth

Refactor `Autostart.swift` and menu binding.

1. Query `SMAppService.status` at startup and whenever the menu opens.
2. Treat config as desired preference, not authoritative system status.
3. On toggle, call register/unregister, requery status, and only then persist the resulting state.
4. Surface `.requiresApproval`, `.notFound`, and registration failures with actionable guidance.
5. Add protocol abstraction and deterministic tests without mutating the developer machine's login items.

## Workstream 5 — Harden update metadata and download

Refactor `UpdateChecker.swift` and `AppUpdater.swift`.

1. Inject HTTP/download clients and eliminate network-dependent unit tests.
2. Validate release metadata schema, semantic version ordering, architecture, minimum macOS, and channel.
3. Download into an app-controlled writable staging directory.
4. Validate archive/DMG checksum from trusted release metadata.
5. Bound response and archive sizes.
6. Support cancellation and cleanup of abandoned staging data.
7. Do not write `.app.new` directly into `/Applications` before permission/staging decisions.

## Workstream 6 — Verify the replacement application

Before swap, verify:

1. expected bundle ID `com.sergej.clicknspeak`;
2. expected Team ID/designated requirement;
3. valid nested code signatures;
4. hardened runtime and expected entitlements;
5. notarization/Gatekeeper assessment;
6. expected executable architecture;
7. version is newer than the current app;
8. no unexpected privileged helper or executable payload.

Use `SecStaticCode`/Security framework where practical and keep command-line checks in build/acceptance scripts.

## Workstream 7 — Implement recoverable swap and relaunch

Because the running app cannot safely replace itself in place, use a small signed update helper or reviewed external swap process.

Required sequence:

```text
download and validate candidate
→ request app shutdown/flush
→ move current app to versioned backup on the same volume
→ atomically move candidate into place
→ launch candidate with validation token
→ candidate reports successful startup
→ delete backup later
```

Failure behavior:

- if move/launch/startup validation fails, restore backup;
- preserve user data and TCC identity;
- retain bounded diagnostic metadata without transcript content;
- never leave both app paths ambiguous to the single-instance guard.

## Workstream 8 — Production signing and notarization

Refactor `scripts/swift_build_app.sh`, `scripts/make_swift_dmg.sh`, and `scripts/notarize_app.sh`.

1. Build release with a reproducible configuration.
2. Sign nested code/resources in the correct inside-out order.
3. Apply reviewed entitlements only; remove unused privileges.
4. Sign the outer `.app` with Developer ID and hardened runtime.
5. Verify with `codesign --verify --strict` and `spctl`.
6. Build/sign the DMG.
7. Submit with `notarytool`, wait for success, and staple tickets.
8. Verify the stapled app/DMG offline where possible.
9. Keep credentials in Keychain/CI secrets, never repository files or command output.
10. Produce a manifest containing version, hashes, Team ID, and artifact sizes.

## Expected files

- `Packages/CNSCore/Sources/CNSCore/ModelRegistry.swift`
- `ModelDownloader.swift`
- `ModelManager.swift`
- `Autostart.swift`
- `UpdateChecker.swift`
- `AppUpdater.swift`
- runtime/menu/model UI integration files
- update helper target and tests if selected
- `scripts/swift_build_app.sh`
- `scripts/swift_verify_bundle.sh`
- `scripts/make_swift_dmg.sh`
- `scripts/notarize_app.sh`
- release artifact manifest tooling

## Required automated tests

1. Valid/invalid checksum, truncation, wrong model format, and atomic activation.
2. Resume with matching and changed ETag.
3. Cancellation/relaunch/disk-space failure.
4. Active-model deletion protection.
5. Autostart registered, unregistered, requires approval, and failed states through a fake service.
6. Update metadata/channel/version validation.
7. Candidate wrong bundle ID, Team ID, signature, architecture, version, and checksum.
8. Swap success and rollback after each failure point using temporary app fixtures.
9. No update path touches production `/Applications` in unit tests.

## Required manual/system tests

- Signed clean install on a fresh macOS user account.
- TCC grants before and after an update signed by the same identity.
- Launch at Login registration and System Settings approval flow.
- Model download cancel/resume across relaunch.
- Update from the previous signed release.
- Simulated network/disk failure during each update stage.
- Deliberately corrupted model and candidate app.
- Gatekeeper assessment on a downloaded/stapled DMG.

## Acceptance criteria

- Only checksum-validated models can become active.
- Model downloads recover cleanly across cancellation/relaunch.
- Launch at Login UI matches `SMAppService.status`.
- Only correctly signed/notarized candidates from the expected Team ID can install.
- Update swap is recoverable at every tested failure point.
- Normal installation/update preserves user data and TCC grants.
- Build/notarization secrets never enter the repository or logs.
- The full Swift verification and signed-bundle acceptance gates pass.

## Non-goals

- Final quality/performance sign-off and production cutover; Epoch 10 owns them.
- Removing the Python rollback application.

## Suggested commit boundaries

1. `feat: validate model artifacts before activation`
2. `feat: persist resumable model downloads`
3. `fix: synchronize autostart with macOS status`
4. `fix: validate update metadata and candidates`
5. `feat: add recoverable app update swap`
6. `build: harden Swift signing and notarization`
7. `test: add model and updater failure matrices`
