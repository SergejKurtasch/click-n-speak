# Epoch 08 — UI Panels, Localization, and Accessibility

## Objective

Finish all remaining user-facing windows and make their behavior, localization, keyboard interaction, accessibility, and multi-monitor placement match the Python application.

## User-visible result

Every menu action opens a complete, current, localized window. Panels behave correctly in light/dark mode, on multiple displays, with keyboard-only interaction and VoiceOver, and no raw locale keys or stale data appear.

## Preconditions

- Epoch 04 provides a stable menu-state model.
- Epoch 07 provides real coordinators for terms, suggestions, replacements, statistics, and prompt actions.
- Business logic is no longer implemented directly inside view code.

## Architectural decision

Follow the migration's recorded AppKit-first decision for parity-sensitive windows. SwiftUI views may be retained only if they demonstrably meet the same lifecycle, focus, sizing, menu-bar, and accessibility behavior. Do not keep a mixed implementation merely because it already exists.

Before rewriting a panel, separate its presenter/view model from business logic so AppKit conversion remains mechanical.

## Workstream 1 — Create a UI parity inventory

For each Python window, record:

- title and visible strings;
- initial size, minimum size, and resize behavior;
- controls, order, enabled states, shortcuts, and default button;
- data refresh behavior on reopen;
- focus, activation, close, and cancellation behavior;
- empty/loading/error states;
- light/dark screenshots.

Cover:

- setup wizard;
- language picker;
- preview/edit popup;
- suggestions;
- terms;
- replacements;
- file transcription;
- model download;
- statistics;
- API key dialogs;
- About/update/error dialogs.

Store reference screenshots in a test/reference location without personal data.

## Workstream 2 — Standardize panel lifecycle

Introduce a small panel/window controller contract:

1. `show(snapshot:)` always refreshes current data.
2. `close/cancel` removes observers/event monitors.
3. Reopen never displays constructor-era config.
4. Long tasks expose progress and cancellation.
5. Only `@MainActor` touches AppKit.
6. Business mutations go through coordinators and return typed results.
7. Errors are displayed without losing current edits.

## Workstream 3 — Complete the language picker

1. Show it in the same launch after permissions when required.
2. Use canonical locale keys rather than passing English sentences to `i18n.t`.
3. Match the menu's supported language list and deduplication rules.
4. Support primary, additional, and auto-detect semantics consistently.
5. Persist only validated selections through the runtime/config coordinator.
6. Update STT configuration immediately through Epoch 03 activation.
7. Provide keyboard selection, default action, and cancel/close behavior.

## Workstream 4 — Finish the preview/edit popup

Modify `PreviewPanel.swift` and `DictionaryAwareTextView.swift`.

1. Position on the relevant screen: target app, mouse, or active screen according to the Python rule; do not always use `NSScreen.main`.
2. Preserve noninteractive HUD and interactive editor modes.
3. After fade, call `orderOut`/teardown so an invisible panel cannot remain in the window stack.
4. Remove event monitors on every close/deinit path.
5. Localize Add to Dictionary and toast strings.
6. Verify Enter, Escape, Command-D, selection, caret-word, append mode, and focus restoration.
7. Respect Reduce Motion by avoiding or shortening fades.
8. Add VoiceOver labels without exposing transcript in diagnostics.

## Workstream 5 — Finish data-management panels

Using Epoch 07 coordinators:

Suggestions panel:

- grouped, resizable list;
- checkbox selection;
- accept/reject/add-all/later actions;
- current counts and sources;
- empty/loading/error states.

Terms panel:

- columns and filters matching Python;
- add/edit/delete/reactivate/revert;
- current metadata and selection preservation.

Replacements panel:

- manual versus automatic sources;
- add/edit/delete;
- validation and conflict feedback.

Statistics panel:

- current metrics and history/trend presentation;
- refresh and force-compute action where Python provides it;
- no calculation on `MainActor`.

## Workstream 6 — Finish file/model/key panels

File panel:

- browse plus drop;
- supported-type validation;
- progress/cancel/result/error;
- copy/save behavior matching Python.

Model download panel:

- current file/model name;
- determinate progress, speed, ETA, cancel, retry;
- background/menu state synchronization;
- no stale callbacks after close.

API key dialogs:

- secure text entry;
- save/delete/test behavior through Keychain abstraction;
- provider-specific validation;
- never echo or log secret values.

## Workstream 7 — Eliminate localization drift

1. Extract every visible Swift string into canonical locale keys.
2. Add all keys to RU, EN, DE, ES, FR, and UK locale files.
3. Keep pluralization through the existing `I18n` engine.
4. Add a static code-to-locales key audit.
5. Add tests for placeholders and plural arguments.
6. Fail tests on raw key fallback in production UI snapshots.
7. Keep developer diagnostics in English but clearly separate from user-visible text.

## Workstream 8 — Accessibility and keyboard acceptance

1. Add meaningful accessibility labels/roles/help to custom controls.
2. Verify Full Keyboard Access order and default/cancel buttons.
3. Ensure radio/check states are announced.
4. Support VoiceOver table/list navigation.
5. Check contrast without relying only on color for status.
6. Test reduced motion, larger text where AppKit supports it, and high-contrast mode.
7. Verify focus returns to the correct app after popup confirmation/cancel.

## Workstream 9 — Visual regression coverage

1. Add deterministic view snapshots for light/dark and key states.
2. Cover 1x/2x assets and common panel sizes.
3. Test single-display and simulated multi-display placement logic separately from physical manual testing.
4. Compare against sanitized Python references and document intentional deviations.

## Expected files

- all files under `Packages/CNSUI/Sources/CNSUI`
- new panel controllers/presenters/view models as needed
- `Packages/CNSUI/Tests/CNSUITests/*`
- locale JSON files
- reference assets/screenshots and asset-validation helpers
- coordinator callback adaptations in the app target

## Required automated tests

1. Reopen every panel with a changed snapshot; no stale data.
2. Locale key completeness and placeholder validity.
3. Popup key commands, teardown, append, and placement calculations.
4. Panel validation and coordinator intent emission.
5. File/model progress and cancellation state rendering.
6. Accessibility identifiers/roles for custom controls.
7. Light/dark view snapshots with sanitized fixture content.
8. No API key appears in logs or view snapshots after dismissal.

## Required manual tests

- RU, EN, and DE full menu/panel walkthrough.
- Light/dark, Retina, one and two monitors.
- VoiceOver and keyboard-only operation.
- Reduce Motion and increased contrast.
- Reopen panels after external/config changes.
- Popup append/inject against multiple target applications.
- Drag/drop and browse file flows.

## Acceptance criteria

- Every visible action opens a complete and current UI.
- No raw locale key or unintended English string appears.
- Panels refresh on reopen and clean up observers/tasks on close.
- Popup placement and teardown work across displays.
- Keyboard and VoiceOver can complete every primary workflow.
- Visual differences from Python are documented and approved.
- The full Swift verification gate passes.

## Non-goals

- Updater/install rollback and notarization; Epoch 09 owns them.
- Final long-duration soak and production cutover; Epoch 10 owns them.

## Suggested commit boundaries

1. `refactor: standardize Swift panel lifecycle`
2. `feat: complete language and preview panels`
3. `feat: complete dictionary and statistics panels`
4. `feat: complete file model and API key panels`
5. `fix: localize all Swift user interfaces`
6. `feat: add keyboard and accessibility support`
7. `test: add UI parity and visual regression coverage`
