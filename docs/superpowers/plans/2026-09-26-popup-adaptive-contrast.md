# Popup Adaptive Contrast Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every textual surface in the recording HUD and editable popup remain readable in both macOS Aqua and Dark Aqua appearances.

**Architecture:** Keep `NSVisualEffectView.Material.hudWindow` as the popup background and replace fixed white foreground/background tints with AppKit semantic dynamic colors. AppKit resolves those colors against each window's effective appearance, so the popup follows a live system appearance change without a custom light/dark state machine or notification observer.

**Tech Stack:** Swift 6, AppKit (`NSColor`, `NSAppearance`, `NSVisualEffectView`, `NSTextView`), Swift Testing.

**Spec:** Approved in chat on 2026-09-25 and narrowed on 2026-09-26 to popup contrast only; the reported delivery/focus issue is explicitly out of scope because its cause was a conflicting ChatGPT helper hotkey.

## Global Constraints

- Preserve all pre-existing uncommitted edits in `PreviewPanel.swift` and `PreviewPanelTests.swift`; do not revert, reformat, or rewrite unrelated code.
- Do not modify `CNSInput`, `CNSSession`, hotkey handling, focus restoration, or text delivery.
- Keep the `.hudWindow` material, panel opacity, layout, sizing, keyboard behavior, and popup lifecycle unchanged.
- Use AppKit semantic dynamic colors; do not branch manually on `darkAqua`, cache a Boolean theme, or register an appearance-change observer.
- Cover both `NSAppearance.Name.aqua` and `.darkAqua` with behavior tests that inspect the real popup views and resolve their actual colors under each appearance.
- Follow strict TDD: add the test first, run it and observe the expected failure against the current hard-coded white colors, then change production code.
- Do not commit because the two target files already contain unrelated uncommitted user work; report the incremental edits and verification instead.

---

### Task 1: Resolve Popup Foregrounds and Tints Against Effective Appearance

**Files:**
- Modify: `Packages/CNSUI/Tests/CNSUITests/PreviewPanelTests.swift`
- Modify: `Packages/CNSUI/Sources/CNSUI/PreviewPanel.swift`

**Interfaces:**
- Consumes: the existing `PreviewPanel.show(title:)`, `PreviewPanel.showInteractive(text:title:onConfirm:)`, and `PreviewPanel.showPendingAppend(_:title:)` APIs.
- Produces: no new public API. Tests may add private test helpers inside `PreviewPanelTests` for finding views and resolving `NSColor` values under a supplied `NSAppearance`.

- [ ] **Step 1: Add a failing interactive-popup contrast test**

Add one table-driven Swift Testing test to `PreviewPanelTests`. It must exercise the real `PreviewPanel`, locate the existing views through their accessibility identifiers/types, and cover both Aqua and Dark Aqua.

The test must inspect all interactive text colors that currently use fixed white:

- title field `preview.status`;
- the editor's attributed foreground color at character index `0`;
- `NSTextView.insertionPointColor`;
- pending-append title foreground color at index `0`;
- pending-append body foreground color after the title and newline.

Use literal expected contrast directions derived independently of production code:

```swift
@Test("Interactive popup text resolves dark in Aqua and light in Dark Aqua")
func interactiveColorsFollowAppearance() throws {
    for (appearanceName, expectsLightForeground) in [
        (NSAppearance.Name.aqua, false),
        (.darkAqua, true),
    ] {
        let panel = makePanel()
        panel.showInteractive(text: "Draft", title: "Edit", onConfirm: { _ in })
        panel.showPendingAppend("Pending body", title: "Pending title")

        let window = try #require(editorWindow(containing: "Draft"))
        let appearance = try #require(NSAppearance(named: appearanceName))
        window.appearance = appearance
        let views = descendants(of: window.contentView)
        let title = try #require(views.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "preview.status"
        })
        let editor = try #require(views.compactMap { $0 as? DictionaryAwareTextView }.first)
        let pending = try #require(views.compactMap { $0 as? NSTextView }.first {
            !($0 is DictionaryAwareTextView) && $0.string.contains("Pending body")
        })

        let pendingTitleIndex = 0
        let pendingBodyIndex = ("Pending title\n" as NSString).length
        let colors = [
            try #require(title.textColor),
            try foregroundColor(in: editor, at: 0),
            editor.insertionPointColor,
            try foregroundColor(in: pending, at: pendingTitleIndex),
            try foregroundColor(in: pending, at: pendingBodyIndex),
        ]
        for color in colors {
            let luminance = try resolvedLuminance(color, appearance: appearance)
            if expectsLightForeground {
                #expect(luminance > 0.6)
            } else {
                #expect(luminance < 0.4)
            }
        }
        panel.close()
    }
}
```

Add private test helpers that read the attributed color and resolve it while the supplied appearance is current. The luminance helper must convert to device RGB and use the standard relative-luminance coefficients, without calling production helpers:

```swift
private func foregroundColor(in textView: NSTextView, at index: Int) throws -> NSColor {
    let value = textView.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil)
    return try #require(value as? NSColor)
}

private func resolvedLuminance(_ color: NSColor, appearance: NSAppearance) throws -> CGFloat {
    var resolved: NSColor?
    appearance.performAsCurrentDrawingAppearance {
        resolved = color.usingColorSpace(.deviceRGB)
    }
    let rgb = try #require(resolved)
    return 0.2126 * rgb.redComponent
        + 0.7152 * rgb.greenComponent
        + 0.0722 * rgb.blueComponent
}
```

If Swift's closure typing requires it, assign the result of `performAsCurrentDrawingAppearance` rather than mutating `resolved`; preserve the same behavior.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSUI --filter PreviewPanelTests.interactiveColorsFollowAppearance
```

Expected: the Aqua iteration fails because at least the title/editor/pending colors resolve as white with luminance above `0.6`. A compile error or missing view is not an acceptable RED result; correct the test setup until it fails specifically on foreground contrast.

- [ ] **Step 3: Add a failing non-interactive HUD contrast test**

Add a second table-driven test for `show(title:)` plus `updateText(_:)`. Locate `preview.status` and `preview.live-text`, then assert both resolve dark in Aqua and light in Dark Aqua with the same `0.4`/`0.6` thresholds.

```swift
@Test("Recording HUD text resolves dark in Aqua and light in Dark Aqua")
func hudColorsFollowAppearance() throws {
    for (appearanceName, expectsLightForeground) in [
        (NSAppearance.Name.aqua, false),
        (.darkAqua, true),
    ] {
        let panel = makePanel()
        panel.show(title: "Recording")
        panel.updateText("Live text")

        let window = try #require(NSApp.windows.first { window in
            descendants(of: window.contentView).contains { view in
                (view as? NSTextField)?.accessibilityIdentifier() == "preview.live-text"
            }
        })
        let appearance = try #require(NSAppearance(named: appearanceName))
        window.appearance = appearance
        let fields = descendants(of: window.contentView).compactMap { $0 as? NSTextField }
        let title = try #require(fields.first { $0.accessibilityIdentifier() == "preview.status" })
        let live = try #require(fields.first { $0.accessibilityIdentifier() == "preview.live-text" })

        for color in [try #require(title.textColor), try #require(live.textColor)] {
            let luminance = try resolvedLuminance(color, appearance: appearance)
            if expectsLightForeground {
                #expect(luminance > 0.6)
            } else {
                #expect(luminance < 0.4)
            }
        }
        panel.close()
    }
}
```

- [ ] **Step 4: Run the focused HUD test and verify RED**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSUI --filter PreviewPanelTests.hudColorsFollowAppearance
```

Expected: the Aqua iteration fails on fixed white foreground colors, not on setup or compilation.

- [ ] **Step 5: Replace fixed monochrome colors with semantic dynamic colors**

Make only the following production changes in `PreviewPanel.swift`:

- use `.labelColor` for the normal title, editable body, insertion point, and pending title;
- use `.secondaryLabelColor` for live transcription text and pending body;
- use `NSColor.labelColor.withAlphaComponent(0.08)` for the editable scroll background;
- use `NSColor.labelColor.withAlphaComponent(0.05)` for the pending scroll background;
- restore `.labelColor` after a successful dictionary toast when no incomplete warning is active;
- retain `.systemOrange` for incomplete warnings and `.systemGreen` for success toasts;
- retain `.clear` for transparent surfaces.

Specifically update every fixed-white occurrence in these paths so no later state transition reintroduces the bug:

```swift
titleField?.textColor = .labelColor

.foregroundColor: NSColor.labelColor
.foregroundColor: NSColor.secondaryLabelColor

let restoreColor: NSColor = incompleteWarning == nil ? .labelColor : .systemOrange

configureLabel(title, color: .labelColor, font: .boldSystemFont(ofSize: 13))
scroll.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08)
editor.textColor = .labelColor
editor.insertionPointColor = .labelColor
configureLabel(text, color: .secondaryLabelColor, font: .systemFont(ofSize: 14))

pendingScroll.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05)

.foregroundColor: NSColor.labelColor
.foregroundColor: NSColor.secondaryLabelColor
```

Do not add appearance observers or explicit `if darkAqua` branches. Dynamic `NSColor` instances stored in the view and attributed strings must resolve at draw time using the window's current effective appearance.

- [ ] **Step 6: Run both new tests and verify GREEN**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSUI --filter PreviewPanelTests.interactiveColorsFollowAppearance
swift test --disable-index-store --package-path Packages/CNSUI --filter PreviewPanelTests.hudColorsFollowAppearance
```

Expected: both commands exit `0`; every Aqua and Dark Aqua assertion passes.

- [ ] **Step 7: Run the complete popup test suite**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSUI --filter PreviewPanelTests
```

Expected: exit `0`, no failures.

- [ ] **Step 8: Run the complete CNSUI package suite**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSUI
```

Expected: exit `0`, no failures.

- [ ] **Step 9: Self-review and report without committing**

Inspect only the incremental diff created during this task. Confirm:

- all hard-coded white foregrounds and white monochrome tints in `PreviewPanel` were replaced;
- orange/green semantic status colors remain intact;
- no focus, hotkey, delivery, layout, or lifecycle code changed;
- existing pending-append and adaptive-sizing edits remain intact;
- the report records the exact RED failure, GREEN commands, exit codes, changed files, and any concerns.

Do not stage or commit the files because they contain pre-existing uncommitted work outside this task.
