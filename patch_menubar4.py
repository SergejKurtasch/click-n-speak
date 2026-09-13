with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

# Add test injections
injection = """
    // Test injections
    public var alertRunner: ((NSAlert) -> NSApplication.ModalResponse)?
    public var testEnvironment: [String: String]?
    public var testKeychain: [String: String]?
    public var testKeychainSetError: Error?
"""
if "// Test injections" not in content:
    content = content.replace("    public var onCredentialsChanged: ((String) -> Void)?", "    public var onCredentialsChanged: ((String) -> Void)?\n" + injection)

# Fix double assignment `let response = _ = alertRunner...` to `let response = alertRunner...`
content = content.replace("let response = _ = alertRunner?(alert) ?? alert.runModal()", "let response = alertRunner?(alert) ?? alert.runModal()")

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
