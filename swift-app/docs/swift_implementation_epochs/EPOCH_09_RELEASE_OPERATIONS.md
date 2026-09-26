# Epoch 09 — Release Operations Runbook

This runbook is the operational contract for producing and rolling out a Swift release. The production path is intentionally fail-closed: an ad-hoc signature, a missing Team ID, a changed artifact checksum, or a failed Gatekeeper assessment stops the release.

## 1. Release inputs

The release operator must provide these values from CI secrets or the macOS Keychain, never from a checked-in file:

| Variable | Required value |
|---|---|
| `CNS_PRODUCTION_RELEASE` | `1` |
| `CNS_CODESIGN_IDENTITY` | Developer ID Application identity name or SHA-1 |
| `APPLE_TEAM_ID` | Expected Apple Developer Team ID |
| `CNS_NOTARY_PROFILE` | `notarytool` Keychain profile name |
| `CNS_RELEASE_CHANNEL` | Normally `stable` |
| `CNS_RELEASE_ARCHITECTURE` | `arm64` for the current release |

Create the notarization profile once on the trusted release machine with `xcrun notarytool store-credentials`. Do not pass an Apple ID password or App Store Connect private key through these scripts.

Before building, confirm that `ClickNSpeak/Info.plist` contains the intended version and minimum macOS version and that the current git revision is the reviewed release revision.

## 2. Build and local acceptance

Run from the repository root:

```bash
CNS_PRODUCTION_RELEASE=1 \
CNS_CODESIGN_IDENTITY="Developer ID Application: …" \
APPLE_TEAM_ID="TEAMID" \
CNS_RELEASE_ARCHITECTURE=arm64 \
scripts/swift_build_app.sh release
```

The build script:

1. builds both `ClickNSpeak` and the signed `CNSUpdateHelper`;
2. installs the pinned MLX Metal library and application resources;
3. signs nested code inside-out without using `codesign --deep` as a signing operation;
4. signs the outer application with the hardened runtime and reviewed entitlements;
5. verifies the bundle identifier, Team ID, architectures, nested signatures, resources, and absence of privileged payload directories.

Run the canonical fast regression gate before notarization:

```bash
scripts/swift_verify.sh
```

Real Whisper and Qwen model gates remain separate opt-in release jobs because they require the pinned local model fixtures. They must use the accepted Epoch 05/06 inputs and thresholds.

## 3. Notarize and create final artifacts

Run:

```bash
CNS_CODESIGN_IDENTITY="Developer ID Application: …" \
APPLE_TEAM_ID="TEAMID" \
CNS_NOTARY_PROFILE="click-n-speak-notary" \
CNS_RELEASE_CHANNEL=stable \
CNS_RELEASE_ARCHITECTURE=arm64 \
scripts/notarize_app.sh dist/swift/Click-n-speak.app
```

The script submits and staples the application first, rebuilds the DMG with that stapled application, then submits, staples, and assesses the DMG. Because stapling changes artifact bytes, the trusted JSON manifest is generated only after the final staple.

Expected outputs are:

- `dist/Click-n-speak-<version>-<architecture>.dmg`;
- `dist/Click-n-speak-<version>-<architecture>.manifest.json`.

The manifest binds schema version, application version, channel, architecture, minimum macOS version, bundle identifier, Team ID, DMG filename, exact byte count, and SHA-256 digest. Publish the DMG and its matching manifest in the same GitHub release. The application rejects a release if either object is missing or inconsistent.

## 4. Model manifest maintenance

`ModelRegistry.swift` is the trusted immutable model catalog. Each artifact URL contains a pinned upstream source revision and is paired with an exact size, format, and SHA-256 digest.

When changing a model:

1. use a reviewed immutable upstream revision, never a moving branch name;
2. collect size and digest from that revision;
3. update the catalog entry and increment `ModelRegistry.manifestVersion`;
4. run the complete `ModelRegistry`, `ModelManager`, and downloader policy tests;
5. run the applicable real-model quality gate;
6. never reuse an old source revision with new bytes.

Downloaded bytes remain under the injected application data directory. Incomplete artifacts live in `.downloads/<model-id>/`, are resumed only after matching source metadata and HTTP validators, and are never activated until exact size, format, and checksum validation succeeds.

## 5. Staged rollout

Use this order for a stable release:

1. install the stapled DMG on an isolated clean macOS user and complete the Epoch 10 signed acceptance matrix;
2. update from the previous signed release and confirm that microphone/accessibility grants remain valid;
3. exercise Launch at Login approval, model cancel/relaunch/resume, and one deliberate update failure;
4. publish to an internal or limited cohort;
5. monitor privacy-safe runtime failures and update acknowledgements;
6. widen distribution only after the observation window has no release-blocking regression.

Do not delete or replace the Python release during the staged rollout. It remains the user-visible rollback channel until Epoch 10 cutover is explicitly approved.

## 6. Update rollback behavior

The updater downloads only into the application-controlled updates directory, verifies the manifest and candidate, then asks the bundled helper to perform the same-volume swap. The helper keeps a versioned backup until the new application acknowledges a successful startup token.

If candidate installation, launch, or acknowledgement fails, the helper terminates the candidate when needed and restores the backup. Diagnostic transaction data is bounded and contains no transcript, prompt, clipboard content, or credentials.

Operational rollback for a release-wide problem is:

1. stop widening the release immediately;
2. remove or mark the faulty GitHub release as non-current so clients no longer receive it;
3. publish a higher-version fixed build through the same signed/notarized pipeline;
4. direct affected users to the retained Python release only when an in-place Swift recovery is not possible;
5. preserve the failing artifacts and privacy-safe transaction metadata for investigation.

Never work around a failure by removing quarantine attributes, weakening Team ID checks, disabling Gatekeeper validation, or changing the application bundle identifier.

## 7. External acceptance still required

Automated tests cannot prove the following system properties. Epoch 10 must record evidence from a Developer ID-signed and notarized build:

- fresh-user Gatekeeper installation from the downloaded DMG;
- microphone and accessibility grant persistence across an update;
- `SMAppService` registration and the System Settings approval path;
- process termination during model transfer followed by byte-range resume;
- update from the previous signed version, including forced helper rollback;
- Intel/Rosetta behavior if a non-arm64 distribution is introduced;
- VoiceOver, multi-display, Retina, sleep/wake, and memory-pressure walkthroughs.
