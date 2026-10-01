# Click-n-speak Swift Release Go/No-Go

## Candidate identity

- Version:
- Git revision:
- Architecture:
- macOS / hardware:
- DMG filename:
- DMG SHA-256:
- App bundle SHA-256:
- Whisper model revision:
- Qwen model revision:
- Bundle ID: `com.sergej.clicknspeak`
- Apple Team ID:
- Signing identity:
- Notarization submission/evidence:
- Acceptance summary:
- Manual evidence schema v2 (operator, completed_at, artifact path + SHA-256):

## Automated gates

| Gate | Result | Evidence |
|---|---|---|
| Fast Swift packages/application | Pending | `scripts/swift_verify.sh` |
| Python ↔ Swift data compatibility | Pending | `tests/parity` |
| Local Whisper model corpus | Pending | model-gated `CNSTranscription` suite |
| Local Qwen editor corpus | Pending | model-gated `CNSEditors` suite |
| Release build/signature | Pending | `scripts/swift_build_app.sh release` |
| Candidate/update/rollback fixtures | Pending | `CNSCore` updater suites |
| Scenario acceptance summary | Pending | machine-readable JSON |

## Manual/system gates

| Gate | Result | Evidence |
|---|---|---|
| Signed permission matrix | Pending | |
| Dictation/injection target matrix | Pending | |
| RU/EN/DE + VoiceOver/display matrix | Pending | |
| Sleep/wake and audio-device recovery | Pending | |
| Live cloud backends and network recovery | Pending | |
| Model cancel/process-kill/resume | Pending | |
| Clean install/update/TCC/autostart/rollback | Pending | |
| Eight-hour soak | Pending | |

## Quality and performance

Record the machine-readable comparison against `tests/parity/quality_thresholds.json`. Do not change thresholds after inspecting candidate measurements.

| Metric group | Result | Evidence |
|---|---|---|
| STT quality | Pending | |
| Local/cloud latency | Pending | |
| HUD/popup latency | Pending | |
| Memory after 1/20/100 sessions | Pending | |
| Audio callback/overflow | Pending | |
| Energy impact | Pending | Instruments/manual evidence |

## Data and rollback

- Sanitized copied dataset used:
- Original copy hash/inventory:
- Python reload result:
- Swift migration result:
- Rollback artifact/version:
- Rollback instructions verified:

## Intentional deviations

- Swift uses a Carbon global hotkey and does not require Input Monitoring. This is accepted only if the signed two-permission workflow passes.

Add any other deviation with owner and approval. An undocumented deviation is a blocker.

## Unresolved blockers

- List every release-critical failure or skipped scenario from the acceptance summary.

## Decision

**Decision: NO-GO until every release-critical scenario passes.**

- Decision owner:
- Decision date:
- Approval reference:
- Rollout cohort:
- Rollback window end:

The Python artifact and rollback instructions must remain available for at least one complete Swift release cycle.
