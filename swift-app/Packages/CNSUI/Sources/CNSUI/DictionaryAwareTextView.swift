import AppKit

/// The popup's editor, with "Add to Dictionary" (⌘D) at the top of its context
/// menu. Ported from `DictionaryAwareTextView` in `preview_panel.py`.
final class DictionaryAwareTextView: NSTextView {
    var onAddToDictionary: (() -> Void)?
    var addToDictionaryTitle = ""

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        let item = NSMenuItem(
            title: addToDictionaryTitle,
            action: #selector(addToDictionary(_:)),
            keyEquivalent: "d"
        )
        item.keyEquivalentModifierMask = .command
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func addToDictionary(_ sender: Any?) {
        onAddToDictionary?()
    }
}
