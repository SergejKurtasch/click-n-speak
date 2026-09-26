# Epoch 04 — Menu, Status, and Phrase History Parity

## Objective

Make the status item and menu an accurate, native, live view of application state. Restore Python-equivalent phrase-history behavior and eliminate misleading icons, stale checkmarks, raw localization keys, and debug-path ambiguity.

## User-visible result

The menu-bar icon changes for idle, recording, and processing. Permissions and active models have correct icons and states. Newly confirmed phrases appear immediately, can be copied with feedback, and pagination works without the confusing close/reopen behavior.

## Preconditions

- Epoch 02 publishes stable session state.
- Epoch 03 publishes active/desired runtime state.
- Epoch 01 provides an injectable permission service and deterministic paths.

## Architectural decision

Introduce an immutable `MenuState` snapshot. `MenuBarController` renders that snapshot and emits user intents; it must not independently infer runtime truth from `Config`, Keychain, TCC, or filesystem state.

Suggested snapshot sections:

- session status;
- permission status;
- desired/active STT and editor descriptors;
- model download/update state;
- language/config selections;
- autostart system status;
- history count/page;
- pending suggestion count;
- data mode (`dev` or `release`).

## Workstream 1 — Add menu state binding

Add `Packages/CNSUI/Sources/CNSUI/MenuState.swift` and refactor `MenuBarController.swift`.

1. Add `apply(_ state: MenuState)` on `@MainActor`.
2. Update existing items in place where possible.
3. If a structural rebuild is required, defer it until menu tracking ends.
4. Keep stable item identifiers to support tests and targeted updates.
5. Separate render methods from action methods.
6. Actions emit typed intents/callbacks; they do not directly claim activation succeeded.
7. Refresh permission snapshots when the menu opens and after app activation.

## Workstream 2 — Bind status-bar icons to session state

Modify `AppResources.swift`, `MenuBarController.swift`, and coordinator wiring.

1. Map `idle`, `starting/recording`, and `stopping/processing` to explicit icon names.
2. Use template images for monochrome menu-bar rendering in light/dark mode.
3. Provide a text fallback only when a required asset cannot load; log the missing asset name once.
4. Add an optional nonintrusive update/error badge only if an existing asset supports it; do not overload recording semantics.
5. Add tests that call `apply` and inspect the current status image identifier/state.

## Workstream 3 — Restore permission icon semantics

1. Render parent permission state and both child states.
2. Use color/status assets only where color carries granted/warning meaning, matching Python behavior.
3. Keep the submenu at two entries: Microphone and Accessibility.
4. Clicking a denied permission opens the correct Settings pane; clicking granted state may recheck but must not reset it.
5. Display setup retry/incomplete state without raw technical errors.

## Workstream 4 — Repair asset coverage

1. Enumerate every asset name referenced by Swift UI.
2. Add or replace the missing `api-keys` asset.
3. Verify 1x/2x dimensions and `isTemplate` behavior.
4. Add `AppResourcesTests` that fail for a missing required icon.
5. Keep generated/source image scripts deterministic if assets are regenerated.

## Workstream 5 — Use native menu semantics

Refactor custom model/language rows in `MenuBarController.swift`.

1. Prefer `NSMenuItem.state` and native on/mixed/off rendering for radio/check choices.
2. If custom views remain necessary for download/delete controls, expose their state through a small typed view class and test that class directly.
3. Restore Python model-row meanings: active, available, download required, downloading, failed, and deletable.
4. Preserve keyboard navigation, menu highlighting, disabled state, and VoiceOver labels.
5. Do not rebuild the full menu synchronously from inside a control action.
6. Synchronize Launch at Login with actual `SMAppService.status`, not only `config.autostart`.
7. Replace the `onRevertTerms` placeholder with a typed intent; Epoch 07 supplies dictionary behavior.

## Workstream 6 — Inject one phrase-history service

Refactor `MenuBarController` so it receives a shared `PhraseHistory` or a `PhraseHistoryProviding` protocol.

1. Construct the service once from the launch `Paths` value.
2. Use the same service in `SessionController` and menu.
3. Publish a history-changed event after a confirmed phrase append.
4. Never call `Paths.resolveDefault()` from history consumers.
5. Show an explicit development-data label in debug diagnostics/About, not inside every history row.
6. Release acceptance must use the Python-compatible production path.

## Workstream 7 — Port Python history-menu behavior

1. Fix the localization-key mismatch (`menu.history_more` versus the canonical locale key).
2. Show the newest five phrases initially.
3. Add the same incremental “Show more” behavior as Python.
4. Keep the menu open for pagination if AppKit permits the established custom-item behavior.
5. Add the copy icon and short nonmodal copied feedback.
6. Reset pagination on the same lifecycle event as Python.
7. Refresh immediately after a successful phrase append.
8. Preserve TSV parsing and do not expose timestamps in the copied phrase.
9. Load/count large history off the main actor and return immutable display rows.
10. Never log phrase contents.

## Workstream 8 — Localize menu-owned UI

1. Route Quit, About, setup, update, model, file, error, and confirmation strings through `I18n`.
2. Create missing locale keys in every supported JSON file.
3. Add a static test that every key referenced by `MenuBarController` exists in all locales.
4. Open/create Log and Config files safely before asking `NSWorkspace` to reveal them.

## Expected files

Expected additions:

- `Packages/CNSUI/Sources/CNSUI/MenuState.swift`
- optional typed menu row/view files
- `Packages/CNSUI/Tests/CNSUITests/AppResourcesTests.swift`
- history/menu state test doubles

Primary modifications:

- `Packages/CNSUI/Sources/CNSUI/MenuBarController.swift`
- `Packages/CNSUI/Sources/CNSUI/AppResources.swift`
- `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift`
- `AppRuntimeCoordinator` state publication
- `Packages/CNSSession/Sources/CNSSession/SessionController.swift`
- `Packages/CNSDictionary/Sources/CNSDictionary/PhraseHistory.swift`
- `Packages/CNSUI/Tests/CNSUITests/MenuStructureTests.swift`
- locale JSON and icon assets

## Required automated tests

1. Menu snapshots for idle, recording, processing, degraded, downloading, and update-available states.
2. Two permission items only, with correct parent/child statuses.
3. Active versus desired model rendering.
4. All referenced assets exist.
5. All referenced locale keys exist in every locale.
6. History counts 0, 1, 5, 6, 2,000, 20,000, and 100,000.
7. A confirmed phrase invalidates and refreshes history once.
8. Copy action copies only the phrase text.
9. Menu state remains stable across deferred structural updates.
10. Tests use temporary history files exclusively.

## Required manual tests

- Compare Python and Swift menu order/screenshots in RU and EN.
- Verify light/dark mode and Retina rendering.
- Record a phrase and watch status icons plus immediate history insertion.
- Exercise Show More and copy feedback.
- Open the menu repeatedly while a model download progresses.
- Grant/revoke permissions and confirm live icon changes.
- Run a release-path acceptance check against a safe copy of the existing 1,824-entry history.

## Acceptance criteria

- Status icon accurately follows session state without polling lag.
- Permission, backend, model, editor, autostart, and download states are factual.
- No required icon is missing and no raw locale key is visible.
- History appears immediately after confirmation and large histories do not block the menu.
- Debug and release data sources cannot be confused silently.
- Menu keyboard navigation and native highlighting work.
- The full Swift verification gate passes.

## Non-goals

- Suggestions/terms/replacements behavior; Epoch 07 owns it.
- Full panel redesign; Epoch 08 owns it.
- STT/file processing internals; Epoch 05 owns them.
- Distribution signing/notarization; Epoch 09 owns it.

## Suggested commit boundaries

1. `refactor: render menu from immutable state`
2. `fix: bind status and permission icons`
3. `fix: restore native model and language menu state`
4. `refactor: share phrase history service`
5. `feat: restore phrase history menu behavior`
6. `test: validate menu assets localization and history`
