import sys

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

func_def = """
    private func showErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: t("btn.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
"""

content = content.replace("    private func buildInitialPromptSubmenu() -> NSMenu {", func_def + "    private func buildInitialPromptSubmenu() -> NSMenu {")

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
