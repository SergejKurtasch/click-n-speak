# Epoch 08 UI Parity Inventory

This inventory records the production Swift window contract after Epoch 08. It is the checklist for the signed-app manual matrix in Epoch 10. Reference images must use synthetic text only and belong in `Packages/CNSUI/Tests/References/`.

| Surface | Swift owner | Size / lifecycle | Primary controls and keyboard | Refresh / long task behavior | Accessibility and placement |
|---|---|---|---|---|---|
| Permission setup | `SetupWizard` | Sequential nonblocking `NSAlert` flow; no nested modal run loop while polling | Default action advances; Skip/close is explicit | Reads live microphone/accessibility state every poll; setup flag is written only for completed/explicitly skipped flows | Native alert roles; System Settings activation is explicit |
| Language picker | `LanguagePicker` | 450×500, minimum 400×450, resizable, one launch-owned instance | Primary menu, additional toggles, auto-detect, Return=Save, Escape=Cancel | Validates the same six languages as the menu, normalizes/deduplicates before emitting `Config` | Stable accessibility identifiers for primary/additional/auto/save |
| Dictation HUD/editor | `PreviewPanel` | 400×120 HUD / 400×160 editor; fresh layout when mode changes | Return=Confirm, Escape=Cancel, Command-D=Add term, selection/caret-word, append mode | Exactly one outcome; all event monitors/tasks removed on close, mode change, or deinit; fade ends with `orderOut` | Pointer display selection plus visible-frame clamping; Reduce Motion supported; editor/status identifiers and help |
| Suggestions | `SuggestionsPanel` | 660×460, minimum 560×360, resizable, reusable | Checkbox list; select/deselect all, accept/reject selected, add all, confirmed auto mode, Escape=Later | `presentPanel()` reloads coordinator state and resets selection | Grouped native list semantics and stable row identifiers; counts include history/correction source |
| Terms | `TermsPanel` | 820×600, minimum 700×420, resizable, reusable | Add, edit, save, delete, reactivate, revert; language/source/state/search filters; Return adds/saves, Escape closes | `presentPanel()` reloads coordinator state and resets stale drafts | Column labels, system colors, stable search/new-term/row identifiers |
| Replacements | `ReplacementsPanel` | 820×600, minimum 620×420, resizable, reusable | Add/edit/delete manual pairs; delete automatic pairs; Return adds, Escape closes | `presentPanel()` reloads coordinator state and resets stale drafts; conflicts remain visible with localized feedback | Manual/automatic source remains textual, not color-only; stable row/input identifiers |
| File transcription | `FileDropPanel` + `FileTranscriptionViewModel` | 500×440, minimum 440×360, resizable, reusable | Drop/Browse, AI refinement toggle, progress, Cancel, editable result, Copy, Save As | Panel-owned state survives close/reopen; cancellation retains ownership until the task exits; job IDs reject stale progress/results; completed unsaved or partial text remains available | Drop/browse/cancel/copy/save identifiers; localized error role; Python media-extension set |
| Model/app download | `ModelDownloadPanel` | 400×140 floating AppKit panel, recreated after close | Determinate/indeterminate progress, speed, localized ETA, Cancel, Retry/Close | Generation tokens reject stale callbacks; close requests cancellation; completion/cancellation auto-dismiss | Native progress/button roles and stable status/cancel identifiers |
| Statistics | `MenuBarController.presentStatistics` | Native alert created per request | OK, Open metrics history | Force computation runs off the main actor; coordinator serializes history/config persistence afterward | Text includes trends and labels in addition to arrows, so meaning does not depend on color |
| API keys | `MenuBarController` | Native alerts created per request | Secure entry, Save and Test, Clear, Cancel | Format validation precedes Keychain write; runtime revalidation tests the desired provider; failures are shown without echoing the key | Secure text fields receive provider labels; logs contain actions/errors but never key values |
| About/update/error | AppKit standard About and localized `NSAlert` surfaces | Created from current bundle/runtime state | Native default/cancel actions | Update/download callbacks are generation-safe and cancellable | Standard AppKit accessibility roles |

## AppKit/SwiftUI decision

Parity-sensitive transient surfaces remain pure AppKit: setup alerts, preview/editor, model download, statistics, credentials, update, About, and error dialogs. Data-heavy forms retain SwiftUI only inside an AppKit-owned `NSWindow`; business mutations live in coordinators/view models, reusable windows implement `RefreshablePanel`, automated tests prove refresh-on-reopen, keyboard actions, light/dark rendering, and accessibility identifiers. This is an intentional composition, not two competing lifecycle owners.

The native file workflow intentionally keeps export user-directed: the result stays editable in the reusable panel and is exported only through **Copy** or **Save As**. Unlike the Python compatibility implementation, Swift does not silently write Markdown into Downloads or replace the clipboard after transcription. Any future auto-export behavior must be an explicit setting with collision-safe naming and visible persistence failures.

## Automated visual and localization baseline

- The UI suite renders sanitized Terms content in Aqua and Dark Aqua and verifies nonempty PNG output.
- Popup placement is tested against two simulated displays, including negative coordinates and edge clamping.
- All six locale files must have exactly the English key set and identical placeholder sets.
- Every literal UI localization key referenced by `CNSUI` must resolve without raw-key fallback.
- Known former raw strings and credential-to-log patterns fail static tests.

## Manual reference matrix deferred to Epoch 10

Capture sanitized RU, EN, and DE images for Aqua/Dark Aqua at 2×; repeat the popup on both sides of a two-display layout. Complete keyboard-only, VoiceOver, Reduce Motion, Increase Contrast, and real drag/drop checks in the signed release app. Record any approved visual difference beside the matching file in `Packages/CNSUI/Tests/References/README.md`.
