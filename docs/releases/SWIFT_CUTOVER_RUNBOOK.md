# Swift Release Rollout and Rollback Runbook

Use this runbook only after the versioned go/no-go report records **GO** and
the machine-readable acceptance summary has zero release-critical failures or
skips. The active product and rollback target are signed Swift releases.

## 1. Identify the candidate

Record the final Git revision, version, macOS/hardware, pinned model revisions,
Team ID, notarization submission, DMG and app-bundle SHA-256 values, and the
manifest SHA-256. Manual evidence must identify the exact candidate, operator,
completion time, evidence path, and artifact SHA-256.

Run acceptance against copies and already-built candidate artifacts; never
target or replace an installed production application. Confirm the release
manifest and release assets are byte-consistent before changing the channel.

## 2. Back up user data

Quit every Click-n-speak instance and resolve exact source and destination
paths. Run `scripts/swift_backup_for_cutover.sh` with an encrypted,
user-controlled destination. Verify its filename/size/SHA-256 inventory before
the first production launch. Do not reset TCC, delete Keychain entries, move
model directories, or rewrite production configuration as part of the backup.

## 3. Roll out the signed Swift release

1. Publish the notarized/stapled DMG and matching JSON manifest.
2. Start with the approved cohort recorded in the go/no-go report.
3. Confirm a clean install and an update from the previous signed Swift release.
4. Monitor only privacy-safe crash, update acknowledgement, latency, memory,
   and backend outcome signals.

Stop rollout for permission hangs, failed injection, data loss or migration
failure, update-loop or rollback failure, repeated crash/hang, audio leaks,
unbounded memory, quality threshold breaches, or private content in diagnostics.

## 4. Roll back safely

For an unacknowledged update, let the signed update helper restore its
same-volume backup and preserve the bounded transaction record.

For a release-wide defect:

1. Stop serving the faulty Swift release as current.
2. Quit the app and preserve privacy-safe logs plus acceptance/transaction
   summaries.
3. Install the previous signed Swift release or a newer signed Swift fix.
4. Verify the backup inventory before restoring data.
5. Prefer compatible data in place; restore a backup only for a measured
   migration/data defect, preserving both copies before deciding.
6. Repeat permission, injection, history, Keychain, and model smoke checks.

Never overwrite newer user data blindly with a pre-release backup. Removing
quarantine attributes, changing the bundle identifier, bypassing signature or
Team ID checks, and editing frozen thresholds are never recovery actions.

## 5. Close the rollback window

Close the window after one complete Swift release cycle without an unresolved
blocker and with approval recorded by the decision owner. Historical cutover
context is retained in
[`docs/archive/SWIFT_CUTOVER_RUNBOOK.md`](../archive/SWIFT_CUTOVER_RUNBOOK.md).
