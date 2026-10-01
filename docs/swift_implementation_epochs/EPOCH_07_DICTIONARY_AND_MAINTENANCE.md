# Epoch 07 — Dictionary, Learning Loop, Prompt Sync, and Maintenance

## Objective

Connect the already ported dictionary/data components into the live application so confirmed corrections improve future transcription exactly as in Python. Complete suggestions, term lifecycle, prompt-file sync, replacements, metrics, decay, and scheduled persistence.

## User-visible result

Edits and manually added terms update the Whisper prompt. Suggestions can be reviewed, accepted, or rejected. Stale automatic terms decay, reused terms reactivate, replacements work, statistics update, and all data survives relaunch without corrupting Python-compatible files.

## Preconditions

- Epoch 03 provides one runtime coordinator and injected paths.
- Epoch 04 provides menu-state events and the shared phrase-history service.
- Epoch 06 provides factual editor results and model metadata.
- Existing config/history/dataset/corrections data formats remain frozen for compatibility.

## Architectural decision

Add a single `DictionaryCoordinator` in `CNSDictionary` or the app composition layer. It owns dictionary mutations and returns updated immutable `Config` snapshots. UI panels emit intents; they must not independently mutate raw JSON.

The coordinator must serialize:

- `user_terms`;
- `prompt_snapshots`;
- `pending_suggestions`;
- `skipped_terms`;
- `initial_prompt` cache;
- prompt text files;
- analysis/decay/metrics timestamps.

## Workstream 1 — Centralize paths and persistence

1. Inject one `Paths` value into session, dictionary coordinator, analyzers, metrics, prompt sync, and panels.
2. Remove `Paths.resolveDefault()` calls from session/user-action code.
3. Add a `ConfigStore` or coordinator-owned atomic persistence method.
4. Track dirty config state and expose `flushIfNeeded()`.
5. Serialize writes so config and prompt-file updates cannot overlap out of order.
6. Keep automated tests entirely in temporary directories.
7. Preserve every config migration supported by the current branch and verify round trips against Python-compatible fixtures.

## Workstream 2 — Complete the confirm/correction pipeline

Refactor the `SessionController` confirmation flow into explicit ordered steps:

```text
capture session metadata
→ append dataset record
→ update corrections index
→ append phrase history
→ deliver/copy text
→ update term usage on the coordinator-owned state path
→ schedule prompt analysis if due
→ publish history/dictionary/metrics invalidations
```

Requirements:

1. Match Python's exact decision about which steps run for empty text, canceled popup, and failed injection.
2. Preserve raw Whisper, AI result/status, final text, actual STT/editor descriptors, prompt hash, and active terms.
3. Use specific error handling so one failed auxiliary write does not silently prevent injection.
4. Do not log transcript or correction content.
5. Add idempotency keyed by session ID so repeated callbacks do not duplicate dataset/history rows.

## Workstream 3 — Port term usage and decay semantics

Implement/verify the Swift equivalent of Python `update_term_usage()` and `apply_decay()`.

1. Match term occurrence and canonical identity rules.
2. Update `last_seen` and `use_count` after the accepted user flow.
3. Reactivate inactive terms when seen again.
4. Never decay manual terms.
5. Preserve the fast/slow decay policies documented by the current Python implementation.
6. Run decay no more than once per 24 hours.
7. Use deterministic injected clock tests for boundary dates and time zones.
8. Rebuild `initial_prompt` whenever active term membership/order changes.

## Workstream 4 — Complete prompt analysis modes

1. Run analysis after `auto_prompt_check_interval` new phrases.
2. Apply the same primary/additional thresholds and lookback window as Python.
3. Merge frequency and correction candidates through canonical term keys.
4. Map latin/cyrillic script buckets to configured language codes through the shared language helper.
5. Implement `suggest`, `auto`, and `disabled` behavior.
6. Preserve the 150-phrase rejected-term cooldown.
7. Record candidate source/count fields using the exact snake_case JSON schema.
8. Publish a pending-suggestion count to `MenuState`.

## Workstream 5 — Make all dictionary mutations transactional

For Add to Dictionary, accept, reject, add all, delete, edit, revert, and prompt-file import:

1. Canonicalize display and identity.
2. Validate the complete mutation against current config.
3. Create/update one-step snapshots where Python does.
4. Rebuild `initial_prompt` using `InitialPromptBuilder`.
5. Atomically save config.
6. Atomically sync the affected prompt text file.
7. Publish one coherent config/menu/panel update.
8. Roll back in-memory state or surface a recoverable error if persistence fails.

No panel may directly edit `config.raw` and then independently save it.

## Workstream 6 — Implement prompt-file synchronization

Add a dedicated prompt-file synchronizer.

1. Write `initial_prompt_<lang>.txt` atomically.
2. Watch external changes without interpreting the app's own write as a user edit.
3. Ignore an empty file when nonempty user terms exist, matching Python's corruption guard.
4. Parse/canonicalize external lines through the shared term parser.
5. Update snapshots and rebuild prompt transactionally.
6. Stop watchers during shutdown and runtime path changes.
7. Test rapid save/rename, empty file, duplicate/case variants, and malformed Unicode.

## Workstream 7 — Complete Suggestions and Terms behavior

Refactor `SuggestionsPanel.swift` and `TermsPanel.swift` to call the coordinator.

Suggestions:

- startup pending alert/badge;
- Review, Add All, Later, and Auto-mode actions;
- per-item accept/reject;
- correct `correction_count` and `frequency_count` decoding;
- grouping by language;
- cooldown persistence.

Terms:

- show term, source, added date, last seen, use count, and inactive state;
- filter/search by language/source/state;
- add/edit/delete/reactivate operations;
- exact canonical identity handling;
- Revert to Previous wired from the menu.

Panels must reload from the latest coordinator snapshot every time they open; do not cache constructor-era config indefinitely.

## Workstream 8 — Complete replacements

1. Define the Python-compatible persistent source for manual replacements.
2. Display manual and correction-derived pairs distinctly.
3. Add/edit/delete manual pairs through the coordinator.
4. Apply replacements at the same pipeline stage as Python.
5. Do not mutate `corrections.json` directly from the UI without validation/atomic save.
6. Test overlapping replacements, casing, word boundaries, multilingual text, and empty values.

## Workstream 9 — Connect maintenance and metrics

Replace `not implemented` callbacks in `AppDelegate`/`MaintenanceScheduler`.

1. Flush dirty config every 60 seconds.
2. Run decay and metrics snapshots no more than once per 24 hours.
3. Flush before model reload and app termination.
4. Append/rotate metrics history using Python-compatible JSONL semantics.
5. Compute notification thresholds and the 30-day notification throttle.
6. Publish current statistics/history to the Statistics UI.
7. Use an injected clock and scheduler in tests.
8. Prevent overlapping duplicate maintenance runs.

## Expected files

Expected additions:

- `Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift`
- config store/transaction abstraction if not placed in `CNSCore`
- prompt-file synchronizer/watcher
- term usage/decay implementation files if missing
- coordinator and integration tests

Primary modifications:

- `SessionController.swift`
- `UserTerms.swift`
- `CorrectionAnalyzer.swift`
- `LogAnalyzer.swift`
- `VocabProvider.swift`
- `Metrics.swift`
- `PhraseHistory.swift`
- `DatasetLogger.swift`
- `InitialPromptBuilder.swift`
- `MaintenanceScheduler.swift`
- `AppDelegate.swift`/runtime coordinator
- `SuggestionsPanel.swift`
- `TermsPanel.swift`
- `ReplacementsPanel.swift`
- `MenuBarController.swift`
- config migrations/fixtures and locale files

## Required automated tests

1. Full correction learning flow: raw → user edit → correction candidate → suggestion → accept → prompt.
2. Confirm callback idempotency and auxiliary-write failure handling.
3. Manual, correction, and auto sort order in prompt.
4. Manual terms never decay; inactive terms reactivate.
5. Exact 150-phrase rejection cooldown boundaries.
6. Script-bucket to language mapping.
7. Suggest/auto/disabled modes.
8. Add/delete/edit/revert transaction and prompt rebuild.
9. Empty prompt-file guard and self-write watcher suppression.
10. Replacement ordering and boundaries.
11. 60-second flush, 24-hour maintenance, and 30-day notification throttle with fake time.
12. Swift/Python fixture round trips for config, history, dataset, corrections, metrics, and prompt files.

## Required manual tests

- Correct a repeated Whisper mistake and accept the resulting suggestion.
- Add a term with Command-D, verify prompt/menu/file, then revert.
- Reject a suggestion and confirm it does not reappear early.
- Edit a prompt file externally and observe safe live import.
- Empty the prompt file and verify terms are not erased.
- Run Terms, Suggestions, Replacements, and Statistics against a large fixture.
- Relaunch between every major mutation and verify persistence.

## Acceptance criteria

- Every dictionary mutation rebuilds and persists the prompt coherently.
- The full learning loop is covered by an integration test.
- No panel retains stale config after reopening.
- Decay, reactivation, cooldown, and maintenance timing match Python.
- Prompt files are atomically synchronized and protected from empty-file loss.
- Statistics and notification throttles use real metrics history.
- Data files remain readable by Python and automated tests never touch production data.
- The full Swift verification gate passes.

## Non-goals

- Final visual conversion/accessibility of all panels; Epoch 08 owns it.
- Model/update distribution security; Epoch 09 owns it.
- Release cutover; Epoch 10 owns it.

## Suggested commit boundaries

1. `refactor: centralize dictionary mutations and persistence`
2. `feat: connect correction and term usage pipeline`
3. `feat: implement prompt analysis modes and cooldown`
4. `feat: synchronize prompt files safely`
5. `feat: complete suggestions terms and replacements behavior`
6. `feat: connect decay metrics and maintenance scheduler`
7. `test: add dictionary learning and compatibility suites`
