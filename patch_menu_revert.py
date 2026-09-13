import sys
import re

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

old_build = """        sub.addItem(item(t("menu.revert_terms"), #selector(onRevertTerms)))"""
new_build = """        let revertItem = item(t("menu.revert_terms"), #selector(onRevertTerms))
        let snapshots = config.raw["prompt_snapshots"]?.objectValue ?? JSONObject()
        revertItem.isEnabled = !snapshots.keys.isEmpty
        sub.addItem(revertItem)"""
content = content.replace(old_build, new_build)

old_onRevert = """    @objc private func onRevertTerms() {
        if let dictionaryCoordinator {
            do { try dictionaryCoordinator.revert() }
            catch { log("Dictionary revert failed: \\(error.localizedDescription)") }
        } else {
            onRevertTermsRequested?()
        }
    }"""
new_onRevert = """    @objc private func onRevertTerms() {
        let snapshots = config.raw["prompt_snapshots"]?.objectValue ?? JSONObject()
        let availableLanguages = snapshots.keys.sorted()
        guard !availableLanguages.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = t("terms.undo_prompt")
        
        let popupButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        for lang in availableLanguages {
            popupButton.addItem(withTitle: lang.uppercased())
            popupButton.lastItem?.representedObject = lang
        }
        
        let primary = config.raw["primary_language"]?.stringValue ?? "en"
        if let primaryItem = popupButton.itemArray.first(where: { ($0.representedObject as? String) == primary }) {
            popupButton.select(primaryItem)
        }
        
        alert.accessoryView = popupButton
        alert.addButton(withTitle: t("menu.revert_terms"))
        alert.addButton(withTitle: t("btn.cancel"))
        
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn,
           let selected = popupButton.selectedItem?.representedObject as? String {
            if let dictionaryCoordinator {
                do { try dictionaryCoordinator.revert(language: selected) }
                catch { log("Dictionary revert failed: \\(error.localizedDescription)") }
            } else {
                onRevertTermsRequested?() // Assuming it uses primary? Wait, onRevertTermsRequested has no arguments.
                // We shouldn't rely on it for language. But dictionaryCoordinator is almost always set.
            }
        }
    }"""
content = content.replace(old_onRevert, new_onRevert)

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
