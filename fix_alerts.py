import sys

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

old1 = """    private func presentCredentialValidationError(provider: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("dialog.api_key_invalid_title")
        alert.informativeText = t("dialog.api_key_invalid_\\(provider)")
        alert.addButton(withTitle: t("btn.ok"))
        alert.runModal()
    }"""
new1 = """    private func presentCredentialValidationError(provider: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("dialog.api_key_invalid_title")
        alert.informativeText = t("dialog.api_key_invalid_\\(provider)")
        alert.addButton(withTitle: t("btn.ok"))
        _ = alertRunner?(alert) ?? alert.runModal()
    }"""

old2 = """    private func presentCredentialPersistenceError() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = t("dialog.api_key_save_failed_title")
        alert.informativeText = t("dialog.api_key_save_failed_body")
        alert.addButton(withTitle: t("btn.ok"))
        alert.runModal()
    }"""
new2 = """    private func presentCredentialPersistenceError() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = t("dialog.api_key_save_failed_title")
        alert.informativeText = t("dialog.api_key_save_failed_body")
        alert.addButton(withTitle: t("btn.ok"))
        _ = alertRunner?(alert) ?? alert.runModal()
    }"""

content = content.replace(old1, new1)
content = content.replace(old2, new2)

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
