# Dictionary Panels and Statistics UI

### Overview
This commit fulfills the remaining items from Epoch 03 for the Dictionary Panels and Statistics presentation:

- Introduced a `TermDraftStore` struct that maintains user's unsaved edits (`TermDraft`) while robustly merging concurrent backend changes (`reconcile`).
- Eliminated unconditional resets (`resetDrafts: true`) on menu reloads so the UI retains changes in both `TermsPanel` and `ReplacementsPanel`.
- Implemented Conflict Resolution in `TermsPanel` — if an edited term was updated/deleted remotely, saving it correctly presents a conflict UI (with newly localized strings "Term changed elsewhere" / "Add as new").
- Introduced `addManualTermValidated` to `DictionaryCoordinating` allowing `TermsPanel` to distinguish validation/I/O errors from identical duplicates.
- Refactored the `Statistics` menu item into a SwiftUI `StatisticsPanel` with an explicit `StatisticsPresentationState` (idle, loading, ready, failed). This accurately reflects waiting states and network errors, instead of erroneously falling back to zeros.

### Changes
- **CNSDictionary/DictionaryCoordinator**: `addManualTermValidated`
- **CNSUI/TermDraftStore**: New type to reconcile text edits safely.
- **CNSUI/StatisticsPanel** & **StatisticsPresentationState**: New async statistics renderer.
- **CNSUI/TermsPanel** & **ReplacementsPanel**: Wired up non-destructive refreshing and conflict resolution.
- **locales/**: Russian and English labels for conflict states.
- **Tests**: Replaced testing assumptions, added regression test in `UIPanelsTests`.

### Validation
Ran `swift_verify.sh` to ensure structural, behavioral, and AppKit-panel integrity across all modules.
