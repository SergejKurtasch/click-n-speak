# Click-n-speak Swift 1.1.0 RC Go/No-Go

> Historical snapshot from 2026-08-31. For current readiness and artifact hashes, see [2026-09-13 RC readiness](SWIFT_1.1.0_RC_GO_NO_GO_2026-09-13.md). The development hashes and scenario counts below are not current release evidence.

Last updated: 2026-08-31

## Candidate identity

- Version: `1.1.0`
- Git base revision: `39bff34698546fe26910eb7d74cf1d9851b5675c` plus the current uncommitted migration implementation
- Architecture: `arm64`
- Development DMG: `Click-n-speak-1.1.0-arm64.dmg`
- Development DMG SHA-256: `e618508f0431866e58b77b2f124186468d0fdf6039429a417622792d01337cb0`
- Bundle ID: `com.sergej.clicknspeak`
- Apple Team ID: not available on this development machine
- Signing/notarization: ad-hoc development signature only; no production notarization claim
- Scenario manifest: `tests/parity/swift_parity_scenarios.json` (45 scenarios)
- Acceptance output: `dist/acceptance/swift-acceptance.json`

The development DMG hash is evidence for deterministic local assembly only. It is not a publishable release artifact. Production notarization changes the final bytes and therefore requires a new post-staple manifest and report update.

## Automated status

| Gate | Result | Evidence |
|---|---|---|
| Canonical automated-only acceptance | Pass / overall NO-GO | 0 failed, 25 passed, 20 release-critical scenarios skipped because external evidence was not supplied |
| Complete Swift verification | Pass | All eight Swift package suites and the executable completed through `scripts/swift_verify.sh` |
| CNSCore final candidate | Pass | 29 XCTest + 65 Swift Testing, including Epoch 10 cross-runtime fixtures |
| Epoch 10 parity contract | Pass | 6 `pytest` cases: manifest, v1–v9 Python migration, thresholds, live-data guard, hybrid evidence policy, and soak privacy |
| Python ↔ Swift config compatibility | Pass | All schema v1–v9 fixtures in both directions; corrupt original remains byte-identical |
| CNSUI final candidate | Pass | 10 XCTest + 34 Swift Testing |
| Executable integration | Pass | 9 Swift Testing cases on the final implementation tree |
| Local Whisper model gate | Skipped in final acceptance | Epoch 05 accepted 42-phrase result; rerun required on the final candidate revision |
| Local Qwen editor gate | Skipped in final acceptance | Epoch 06 accepted model suite; rerun required on the final candidate revision |
| Update/candidate/rollback fixtures | Pass | Epoch 09 CNSCore failure matrices |
| Development release app | Pass | Release `.app` rebuilt by the acceptance runner and passed strict ad-hoc nested signature/resource/architecture checks |
| Development DMG baseline | Pass | Epoch 09 DMG assembly and matching manifest digest; not production-signed or notarized |

The canonical automated-only result is recorded in `dist/acceptance/swift-acceptance.json`: all runnable automated gates passed, with no failures. The strict aggregate decision remains NO-GO because 20 release-critical model, signed-system, physical-workflow, and soak scenarios have no final-candidate evidence.

## Predeclared quality/performance policy

Thresholds are frozen in `tests/parity/quality_thresholds.json`. They cover multilingual WER, short-command accuracy, terminology recall, hotkey-to-HUD and stop-to-popup p95, warm/cold decode, local editor p95, peak/growth RSS, callback duration, and overflow count.

Swift runtime telemetry now emits content-free monotonic measurements for HUD presentation, popup presentation, editor calls, chunk calls, per-session RSS, and audio capture. `scripts/analyze_swift_soak.py` produces a machine-readable soak/metric document and `scripts/compare_swift_parity_metrics.py` applies the frozen thresholds fail-closed.

## Accepted intentional deviation

- Swift uses Carbon for the global hotkey. Input Monitoring is therefore absent from setup and the Permissions menu. Microphone and Accessibility remain required. This deviation is acceptable only after the signed clean-user permission matrix proves a responsive two-permission flow.

No other intentional deviation has been approved.

## Release blockers

- No Developer ID identity or notary profile is available in the current environment; the publishable app/DMG has not been signed, notarized, or stapled.
- The signed clean/incomplete/previously-granted permission matrix is not recorded.
- TCC and Keychain preservation across an update from the prior signed release is not recorded.
- Launch at Login approval through System Settings is not recorded.
- Physical target-app injection, sleep/wake, device reconnect, multi-display/Retina, VoiceOver, and RU/EN/DE workflows are not recorded.
- Live Gemini/OpenAI recovery and process-kill model resume are not recorded.
- The final-candidate Whisper and Qwen model gates need a post-Epoch-10 rerun.
- The required eight-hour signed-app soak and energy review have not run.

## Rollback readiness

- Python source/build infrastructure remains present and unchanged as a distribution fallback.
- Bidirectional schema fixtures prove that Python can reload config after a Swift round-trip.
- Epoch 09 updater fixtures prove automatic app-bundle rollback in temporary paths.
- A real previous-signed-version update and Python fallback using a copied acceptance dataset remain release blockers.

## Decision

**NO-GO for production cutover.**

The code-level epochs are implemented, but release authorization is intentionally withheld until the strict acceptance runner reports zero release-critical failures and zero release-critical skips using production signing and manual/system evidence. The Python application must remain the shipping rollback for at least one full release cycle after a later written GO decision.
