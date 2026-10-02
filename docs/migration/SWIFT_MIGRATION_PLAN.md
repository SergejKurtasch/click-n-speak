# Swift implementation plan

The SwiftPM application is now the repository's sole product. `ClickNSpeak/`
is the composition root; domain packages live under `Packages/`; native
resources, tests, release tooling, and acceptance fixtures use root-relative
paths.

## Current architecture

- `CNSCore` owns configuration, migrations, paths, persistence, telemetry, and
  update safety.
- `CNSAudio` owns recording, buffering, voice activity detection, and chunking.
- `CNSTranscription` owns local/cloud transcription and media decoding.
- `CNSEditors` owns local and cloud editing behind the editor protocol.
- `CNSDictionary` owns terms, corrections, history, metrics, and datasets.
- `CNSUI` owns menu, popup, settings, onboarding, and accessibility surfaces.

The app target assembles these packages without runtime lookups outside the
repository. User data paths and persisted schemas remain stable across
releases.

## Verification milestones

1. Run the root layout and agent-environment checks.
2. Run focused package tests for the changed package.
3. Run `bash scripts/swift_verify.sh` before release work.
4. Run opt-in model suites only with explicit local model paths.
5. Run `scripts/swift_acceptance.py` for a signed release candidate and retain
   the generated evidence with the candidate artifacts.

The historical migration rationale is retained in
[`docs/archive/SWIFT_MIGRATION_PLAN.md`](../archive/SWIFT_MIGRATION_PLAN.md).
