# Swift Signed-App Soak Protocol

Use only a copied/sanitized data directory and a signed/notarized release candidate. Never point the soak at the live production data directory.

## Preconditions

- Record candidate version, git revision, DMG SHA-256, Team ID, macOS/hardware, model revisions, and network configuration.
- Confirm a clean checkout at the exact candidate commit and that the prebuilt app, DMG, and release manifest are frozen. Acceptance mounts the DMG read-only and compares its app with the candidate bundle; it does not rebuild either artifact.
- Confirm `scripts/swift_acceptance.sh --production --candidate-app <app> --candidate-dmg <dmg> --candidate-release-manifest <manifest> --candidate-model-revisions '{"whisper":"<pinned revision>","qwen":"<pinned revision>"}' --manual-evidence <file>` is otherwise ready to run. Supply the required model test paths and opt-in environment variables for the real-model gates.
- Freeze `tests/parity/quality_thresholds.json`; do not edit it after observing candidate results.
- Keep the Python rollback artifact and copied dataset available.

## Minimum eight-hour sequence

1. Start from a clean app launch and record one cold local decode.
2. Complete at least 100 sanitized sessions, including silence, short commands, multichunk speech, append-to-popup, Enter, Escape, and Command-D.
3. Cross the 20-session reload point and the 100-session memory observation point.
4. Include long idle periods and at least two sleep/wake cycles.
5. Disconnect/reconnect the selected input device once while idle and once during a controlled recording.
6. Exercise Gemini/OpenAI network loss and recovery without placing credentials in evidence.
7. Switch local/cloud STT and local/cloud/disabled editor backends only while following the UI state contract.
8. Cancel a long file transcription and a model download; terminate/relaunch during a model transfer and verify validated resume.
9. Quit/relaunch at safe idle points and confirm exactly one instance, no stale popup, and coherent history/dataset counts.

## Evidence collection

Capture the application log containing `runtime_event` records, but do not attach transcript, prompt, clipboard, audio, credentials, or user-history content. Summarize it with:

```bash
source venv/bin/activate
python scripts/analyze_swift_soak.py \
  --log /path/to/copied/soak.log \
  --quality-metrics /path/to/model-quality.json \
  --output /path/to/soak-summary.json
python scripts/compare_swift_parity_metrics.py \
  --candidate /path/to/soak-summary.json \
  --output /path/to/metric-acceptance.json
```

Record Instruments Energy Log evidence separately because application telemetry cannot measure system energy impact reliably.

## Immediate failure conditions

- crash, unrecoverable hang, stale audio stream, or duplicate active instance;
- missing/duplicated history or dataset row for a confirmed session;
- transcript/prompt/clipboard/audio/key data in structured telemetry or acceptance evidence;
- unbounded RSS growth or a frozen-threshold violation;
- lost permission, broken injection, stale popup/status, failed resume validation, or unrecoverable update state.

Any failure gets a focused regression test and the affected soak segment is rerun. A shortened rerun cannot replace the full eight-hour final-candidate soak.
