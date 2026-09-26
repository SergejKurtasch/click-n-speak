# Swift 1.1.0 RC readiness — 2026-09-13

**Decision: NO-GO for production cutover.** The deterministic and local real-model gates passed, but there is no production-signed candidate or candidate-bound physical/soak evidence. This report supersedes the 2026-08-31 snapshot for current readiness; it does not turn the development artifact into a release candidate.

## Verified development artifact

| Identifier | Value |
|---|---|
| Source commit embedded in signed `Info.plist` | `0a631fa8dcd0f9a991e7610c5eacbe04622e39dd` |
| Version / architecture | `1.1.0` / `arm64` |
| App | `dist/swift/Click-n-speak.app` |
| Canonical app-tree SHA-256 | `fef6de005a24fea75a311c7921e6cbd57f3891dfbc2db4c0a0db2745544d0865` |
| DMG | `dist/Click-n-speak-1.1.0-arm64.dmg` |
| DMG SHA-256 | `4346e85e3a933cc0680c7bb537ee5e82d734eea3636017cb52adfb2911393355` |
| Release manifest | `dist/Click-n-speak-1.1.0-arm64.manifest.json` (schema 1, matching git revision/version/DMG digest) |
| Signature | Ad-hoc development signature; no notarization |

The app was assembled with `CNS_RESET_TCC_AFTER_BUILD=0`, passed `swift_verify_bundle.sh`, and left TCC records untouched. The DMG was mounted read-only and its embedded app matched the canonical app-tree hash. These ignored `dist/` artifacts are local development evidence, not distributable production files.

## Checks completed

| Gate | Result | Scope |
|---|---|---|
| Full deterministic Swift verification | Passed | All eight Swift packages and `ClickNSpeak`; both real-model flags disabled for this fast run |
| Python parity / acceptance schema | Passed | 58 parity tests; 60 scenarios validate-only; ruff, mypy, bash syntax; all 11 original audit probes mapped to permanent selected tests |
| Python ↔ Swift v10 config roundtrip | Passed | 3 targeted Swift tests, including exact approved/rejected decision metadata preservation |
| Local Whisper golden | Passed | Existing ggml large-v3-turbo model; 42 sanitized phrases; WER 0.043, RU 0.037, EN 0.069, code-switch 0.062, peak RSS 1808 MB |
| Local Qwen golden | Passed | Existing Qwen 2.5 1.5B 4-bit snapshot; one selected real-model golden test |
| Development app / DMG integrity | Passed | Ad-hoc bundle verification, release manifest digest, and mounted-DMG app-tree equality |

The model commands ran on the current runtime source, but were not recorded by a clean-checkout, production-signed `swift_acceptance.sh` invocation. Their pass results must not be reused as final candidate-bound release evidence.

## Open release gates

- `security find-identity -v -p codesigning` reports **0 valid identities**. Developer ID signing, notarization/stapling, and two-version signed update/rollback verification are unavailable.
- No clean-user signed-app TCC matrix, physical microphone/injection/accessibility/device/sleep-wake matrix, RU/EN/DE/VoiceOver/Retina/multi-display walkthrough, Launch at Login check, or live-provider fault matrix has been recorded.
- No eight-hour/100-session signed-app soak, energy review, or consented sanitized manual-evidence package exists.
- No production candidate hashes exist. The strict acceptance runner was not invoked: this checkout contains separate user-owned edits/untracked material and lacks production signing/manual prerequisites. `--validate-only` is schema validation, not an acceptance pass.
- A packaged, tested Python rollback artifact and real previous-signed-version migration remain to be demonstrated.

The frozen thresholds remain in `tests/parity/quality_thresholds.json`. A future GO requires a clean exact commit, signed/stapled app and DMG with matching manifest, independently logged model/system/soak gates, and zero release-critical failures or missing prerequisites for those exact hashes.
