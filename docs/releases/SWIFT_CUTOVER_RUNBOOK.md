# Swift Controlled Cutover and Rollback Runbook

Do not execute this runbook until the versioned go/no-go report has a written **GO** decision and the machine-readable acceptance summary has zero release-critical failures and zero release-critical skips.

## 1. Freeze and identify artifacts

Record the final git revision, version, architecture, Team ID, notarization submission, DMG filename, post-staple SHA-256, and manifest SHA-256. Confirm the release manifest and GitHub release assets are byte-consistent before changing the public channel.

Retain these rollback inputs:

- the last shipped Python DMG/application;
- its install instructions and compatible model set;
- the previous signed Swift/updater fixture if applicable;
- a copied, hashed pre-cutover data backup.

## 2. Back up data before first production Swift launch

Quit every Click-n-speak instance. Resolve the exact source and destination paths, then run the backup helper explicitly. Example:

```bash
scripts/swift_backup_for_cutover.sh \
  --source-dir "$HOME/Library/Application Support/Click-n-speak" \
  --dataset "$HOME/.clicknspeak_dataset.jsonl" \
  --destination "/Volumes/EncryptedBackup/Click-n-speak-pre-swift-1.1.0" \
  --candidate-version "1.1.0"
```

The helper has no default source, refuses broad/root/repository targets, never overwrites a destination, copies only known persistence files, and writes filename/size/SHA-256 inventory without content. Store the backup on an encrypted user-controlled volume.

Do not reset TCC, delete Keychain entries, move model directories, or rewrite production config as part of backup.

## 3. Publish to the staged cohort

1. Publish the notarized/stapled DMG and its matching JSON manifest through the existing release channel.
2. Start with the approved limited cohort from the go/no-go report.
3. Confirm one clean install and one update from the previous shipped release after publication.
4. Monitor only privacy-safe crash, update acknowledgement, latency, memory, and backend outcome signals.
5. Keep the Python artifact visible and documented for the complete rollback window.

Do not delete Python source, build scripts, artifacts, or compatibility fixtures in the cutover release.

## 4. Stop conditions

Stop rollout immediately for permission hangs/loss, failed injection, data loss/incompatibility, update-loop or rollback failure, repeated crash/hang, audio-stream leak, unbounded memory growth, a quality threshold breach, or private content in diagnostics.

Removing quarantine attributes, changing the bundle identifier, bypassing Team ID/signature checks, or editing frozen thresholds is never a recovery action.

## 5. Application rollback

For an update transaction that has not acknowledged a healthy launch, allow the signed update helper to restore its same-volume backup automatically. Preserve its bounded transaction record.

For a release-wide defect:

1. stop serving the faulty release as current;
2. quit the Swift app;
3. preserve a copy of privacy-safe logs and the acceptance/transaction summaries;
4. reinstall the retained Python artifact or a higher-version signed Swift fix;
5. verify the backup inventory before restoring any data;
6. prefer using the existing compatible data in place; restore the backup only when a measured migration/data defect requires it;
7. rerun permission, injection, history, Keychain, and model smoke checks.

Never overwrite newer user data blindly with the pre-cutover backup. Compare timestamps/inventory and preserve both copies before any restore decision.

## 6. Close the rollback window

Close only after one full Swift release cycle has completed without an unresolved blocker and the decision owner records approval. Python removal is a separate cleanup epoch and must not be bundled into this cutover.
