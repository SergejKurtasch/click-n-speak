# Replacement Pair Lifecycle Design

## Summary

Click-n-speak currently treats every correction-derived replacement pair as an automatic replacement after three observations and displays even one-off pairs in a single undifferentiated list. This creates noisy suggestions, allows accidental grammar changes, and makes a deleted pair reappear when `corrections.json` is rebuilt.

This change separates observed evidence from user decisions. `corrections.json` remains a rebuildable statistical index, while approved and rejected decisions are stored persistently in `config.json`. Only manual or explicitly approved pairs may modify dictated text directly. Unapproved candidates can inform Gemini after two observations but cannot alter text on their own.

## Goals

- Hide replacement pairs observed only once.
- Show a pair as a candidate after its second observation.
- Mark a candidate as ready for review after its third observation.
- Allow direct replacement only for manual and explicitly approved pairs.
- Send non-rejected candidates to Gemini as hints from the second observation onward.
- Persist rejection decisions so an index rebuild cannot resurrect a pair.
- Remove stale observations after 90 days or 300 newer confirmed dictations, whichever occurs first.
- Separate active, candidate, and rejected pairs in the replacement management window.
- Preserve the four replacement pairs that were effectively active before this change.

## Non-goals

- No semantic or grammatical classifier is added to decide whether a pair is linguistically correct.
- Local Qwen prompt behavior is unchanged; it continues not to consume replacement hints.
- The token diff algorithm used to discover replacement evidence is not replaced.
- Existing manual replacement matching semantics remain whole-word/whole-phrase, case-insensitive, longest match first, and non-cascading.

## Chosen Architecture

### Observation and policy are separate

The correction index owns rebuildable observation facts:

- source text (`from`)
- replacement text (`to`)
- observation count
- last-seen timestamp
- last-seen dataset row

The application config owns durable user policy:

- approved automatic replacement pairs
- rejected replacement pairs
- whether the one-time upgrade initialization has completed

Pair identity is the canonicalized `from` and `to` values joined as a stable key. Display capitalization is preserved in stored values, while comparison uses `TermCanonicalizer.canonicalKey`.

This design is preferred over storing approval inside `corrections.json`, because that file can be deleted or rebuilt from the append-only dataset. It is also preferred over converting approved automatic pairs into manual pairs, because preserving provenance is required for understandable UI and migrations.

### Config schema 10

The config schema advances from 9 to 10 and adds:

```json
{
  "approved_auto_replacements": [
    {
      "from": "Проанализирую",
      "to": "Проанализируй",
      "approved_at": "2026-09-04T12:00:00Z"
    }
  ],
  "rejected_replacements": [
    {
      "from": "пример",
      "to": "замена",
      "rejected_at": "2026-09-04T12:00:00Z"
    }
  ],
  "replacement_policy_initialized": true
}
```

Migration to schema 10 creates empty arrays and sets `replacement_policy_initialized` to `false`. At the first `DictionaryCoordinator` initialization after migration, the coordinator updates the correction index from the append-only dataset first. This also rebuilds a schema-4 index as schema 5 before policy seeding. Stale-pair pruning is suppressed for this one bootstrap update so previously effective replacements are not discarded before migration. The coordinator then copies every non-rejected pair with `count >= 3` into `approved_auto_replacements`, prunes stale observations, and atomically persists the config with `replacement_policy_initialized = true`.

If the dataset or index cannot be read, initialization remains false and is retried on the next launch; a transient read failure must not silently discard previously effective pairs. If neither file exists, the installation is considered fresh and initialization completes with an empty approved list.

This one-time seeding preserves the old effective behavior for existing installations. For the current installation it activates these four pairs:

- `Проанализирую` → `Проанализируй`
- `Drylabs` → `Drylabz`
- `Cogni` → `Cognee`
- `продолжу` → `продолжи`

Fresh installations have no prior correction index, so they start with no approved automatic pairs.

### Correction index schema 5

The correction index schema advances from 4 to 5. Each `ReplacementPair` gains `last_seen_row`. A schema-4 index is rebuilt from the append-only dataset so the row values are accurate instead of guessed.

When processing a confirmed dictation, the analyzer updates both `last_seen` and `last_seen_row`. A pair is stale when either condition is true:

- at least 90 days have elapsed since `last_seen`; or
- at least 300 dataset rows have been processed since `last_seen_row`.

Stale observed pairs are removed from the correction index during index updates and when replacement rows are loaded for review. Approval and rejection records are not removed by this cleanup. An approved pair therefore remains active until the user removes it, even if its statistical observation expires.

The 300-row window uses confirmed dataset records, which are the durable representation of completed dictations that can produce correction pairs.

## Pair Lifecycle

An observed pair is classified in this order:

1. If its canonical key is rejected, it is excluded from candidates, direct replacement, and Gemini hints.
2. If its canonical key is manual or approved, it is active.
3. If it is stale, it is removed from the observation index.
4. If `count == 1`, it remains hidden.
5. If `count == 2`, it is a visible candidate and a Gemini hint.
6. If `count >= 3`, it is a visible candidate marked ready for review and a Gemini hint.

User actions have the following effects:

- **Approve candidate:** add it to `approved_auto_replacements`; it becomes active immediately.
- **Reject candidate:** remove any approval and add it to `rejected_replacements`; it disappears from candidates and hints.
- **Delete active automatic pair:** remove approval and add a rejection record.
- **Delete active manual pair:** remove the manual pair and add a rejection record so correction evidence cannot immediately recreate it as a candidate.
- **Edit a manual pair:** replace the manual entry; reject the old canonical pair if the identity changed; clear a rejection matching the new pair.
- **Add a manual pair:** store it in `manual_replacements` and clear a matching rejection or automatic approval.
- **Restore rejected pair:** remove the rejection and add the pair to `approved_auto_replacements`; it becomes active immediately.

Only one active target is allowed for a canonical source phrase. Approving, restoring, or adding a pair that conflicts with another active target returns the existing `conflictingReplacement` error. The user must remove the conflicting active pair first.

Exact duplicates across manual and approved lists are deduplicated. Manual pairs take precedence and retain the `manual` provenance shown in the UI.

## Runtime Data Flow

### Direct text replacement

A dedicated provider query returns only:

1. manual replacements, in configured order;
2. approved automatic replacements, excluding exact duplicates and source conflicts.

`SessionController` uses this query in every fallback path that currently applies `collectMisrecognitions`. Observed-but-unapproved pairs never reach `applyReplacements`, regardless of count.

The existing editor-status policy remains unchanged: direct replacement still runs only in the same disabled, skipped, timeout, error, memory-pressure, and applicable unchanged-result paths. This design changes which pairs are eligible, not when the fallback runs.

### Gemini hints

The Gemini hint query returns, in priority order:

1. manual pairs;
2. approved automatic pairs;
3. non-rejected, non-stale observed pairs with `count >= 2`.

Exact duplicates are removed. The existing cap of 30 hints remains, with each group sorted deterministically and observed candidates sorted by descending count and then canonical source key. Candidate hints guide Gemini but do not guarantee a replacement.

Local Qwen continues to ignore the hint list. This scope does not change its prompt or model behavior.

## Replacement Management UI

`ReplacementsPanel` keeps the manual-entry form at the top and presents three sections:

### Active

- Contains manual and approved automatic pairs.
- Manual rows remain editable.
- Automatic rows retain their observation count when evidence is available.
- Removing a row moves its identity to Rejected.

### Candidates

- Contains non-stale, non-rejected, unapproved pairs with `count >= 2`.
- Count-two rows show a neutral candidate badge.
- Count-three-or-higher rows show a ready-for-review badge.
- Every row has **Approve** and **Reject** actions.
- Count-one observations never appear.

### Rejected

- Collapsed by default and displays its item count in the section header.
- Contains persistent rejection records even when their observations have expired.
- Every row has a **Restore** action, which moves the pair directly to Active.

Rows are sorted by state, descending observation count, and canonical source text. All labels, empty states, badges, actions, and accessibility identifiers are added to every supported localization catalog: English, Russian, Ukrainian, German, Spanish, and French.

The window remains resizable and scrollable. Mutations go through `DictionaryCoordinator`; the SwiftUI view never writes `config.json` or `corrections.json` directly.

## Persistence and Failure Handling

- Config policy mutations use the existing serialized `DictionaryCoordinator` ownership and atomic config save path.
- Correction index updates use the existing atomic JSON write path.
- A failed mutation leaves the last persisted snapshot active and displays a localized error in the panel.
- A missing or malformed correction index produces no candidates but does not erase approved or rejected config policy.
- Unknown future config fields remain preserved by migrations.
- Repeated schema migration and policy initialization are idempotent.

## Testing Strategy

Implementation follows test-driven development.

### CNSCore

- Schema-9 configs migrate to schema 10 with empty policy arrays and pending initialization.
- Schema-10 migration is idempotent and preserves existing policy and unknown fields.
- Migration fixtures and parity expectations advance to schema 10.

### CNSDictionary

- Correction index schema 5 records `last_seen_row` and rebuilds schema-4 data.
- Pairs expire at either the 90-day or 300-row boundary.
- Count-one observations are hidden; count-two and count-three observations receive the correct candidate state.
- One-time initialization approves every pre-existing pair with `count >= 3` exactly once.
- Approve, reject, delete, edit, and restore persist the specified policy transitions.
- Rejected pairs remain rejected after the correction index is rebuilt.
- Direct replacement collection returns manual and approved pairs only.
- Gemini hint collection includes eligible candidates from count two and excludes rejected or stale pairs.
- Duplicate and conflicting source behavior is deterministic.

### CNSSession

- Editor fallback paths do not directly apply an unapproved pair, even at a high count.
- Approved automatic and manual pairs continue to apply in the existing eligible fallback states.
- Gemini receives count-two candidate hints while local Qwen behavior remains unchanged.

### CNSUI

- Panel/view-model tests verify active, candidate, and rejected grouping and their actions.
- Count-one pairs are absent from the rendered review model.
- The rejected section starts collapsed and restore returns an item to Active.
- English and Russian localization keys are covered by the existing localization validation.

### End-to-end verification

- Run the complete Swift verification script.
- Build the macOS application bundle.
- Inspect the migrated runtime config and correction index without exposing dictated text in logs.
- Confirm that the four existing high-frequency pairs are Active, count-two pairs are Candidates, and one-off pairs are absent from the window.

## Acceptance Criteria

- No pair observed once is visible or used.
- A pair observed twice is visible as a candidate and available to Gemini only.
- A pair observed at least three times is visibly ready for review but remains inactive until approved.
- Only manual or approved pairs can directly alter dictated text.
- Rejecting or deleting a pair survives application restart and correction-index rebuild.
- Restoring a rejected pair makes it active.
- Candidate evidence expires after 90 days or 300 later confirmed dictations, whichever occurs first.
- Existing users retain their previously effective count-three-or-higher replacements through one-time migration.
- The current installation begins with exactly the four user-approved high-frequency pairs active.
