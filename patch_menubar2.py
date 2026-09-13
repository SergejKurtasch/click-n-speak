import sys

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

# Add test injection properties to MenuBarController
injection = """
    // Test injections
    var alertRunner: ((NSAlert) -> NSApplication.ModalResponse)?
    var testEnvironment: [String: String]?
    var testKeychain: [String: String]?
    var testKeychainSetError: Error?
"""
if "// Test injections" not in content:
    content = content.replace("    var onCredentialsChanged: ((String) -> Void)?", "    var onCredentialsChanged: ((String) -> Void)?\n" + injection)

new_method = """    @objc private func onGeminiApiKey() {
        presentCredentialDialog(provider: "gemini")
    }

    @objc private func onOpenAIApiKey() {
        presentCredentialDialog(provider: "openai")
    }

    private func presentCredentialDialog(provider: String) {
        let isGemini = provider == "gemini"
        let account = isGemini ? KeychainHelper.geminiAccount : KeychainHelper.openAIAccount
        
        let env = testEnvironment ?? ProcessInfo.processInfo.environment
        let lookup: @Sendable (String, String) -> String? = { s, a in
            if let tk = self.testKeychain { return tk["\(s)-\(a)"] }
            return KeychainHelper.getPassword(service: s, account: a)
        }
        
        let metadata = KeychainHelper.getMetadata(
            account: account,
            environment: env,
            keychainLookup: lookup
        )
        
        let alert = NSAlert()
        alert.messageText = isGemini ? t("dialog.gemini_key_title") : t("dialog.openai_key_title")
        
        var isEnv = false
        var envVarName = ""
        switch metadata.source {
        case .environment(let name):
            isEnv = true
            envVarName = name
        case .keychain, .none:
            break
        }
        
        if isEnv {
            alert.informativeText = t("dialog.credential_env_override").replacingOccurrences(of: "%@", with: envVarName)
        } else {
            alert.informativeText = metadata.isConfigured
                ? (isGemini ? t("dialog.gemini_key_body_existing") : t("dialog.openai_key_body_existing"))
                : (isGemini ? t("dialog.gemini_key_body") : t("dialog.openai_key_body"))
        }

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = metadata.isConfigured ? "••••••••••••" : nil
        input.setAccessibilityLabel(alert.messageText)
        alert.accessoryView = input
        
        alert.addButton(withTitle: t("btn.save"))
        alert.addButton(withTitle: t("btn.cancel"))
        alert.addButton(withTitle: t("btn.clear"))
        
        if isEnv {
            input.isEnabled = false
            alert.buttons[0].isEnabled = false
            alert.buttons[2].isEnabled = false
        }
        
        var retry = true
        while retry {
            retry = false
            let response = alertRunner?(alert) ?? alert.runModal()
            if response == .alertFirstButtonReturn {
                let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    guard Self.isCredentialFormatValid(key, provider: provider) else {
                        presentCredentialValidationError(provider: provider)
                        retry = true
                        continue
                    }
                    do {
                        if let err = testKeychainSetError { throw err }
                        if testKeychain != nil {
                            testKeychain!["\(KeychainHelper.defaultService)-\(account)"] = key
                        } else {
                            try KeychainHelper.setPassword(account: account, password: key)
                        }
                        log("\(provider.capitalized) API Key saved to Keychain.")
                        
                        let successAlert = NSAlert()
                        successAlert.messageText = t("dialog.credential_saved")
                        successAlert.addButton(withTitle: t("btn.ok"))
                        _ = alertRunner?(successAlert) ?? successAlert.runModal()
                        
                        onCredentialsChanged?(provider)
                    } catch {
                        log("Failed to save \(provider.capitalized) API Key: \(error)")
                        presentCredentialPersistenceError()
                        retry = true
                    }
                }
            } else if response == .alertThirdButtonReturn {
                do {
                    if let err = testKeychainSetError { throw err }
                    if testKeychain != nil {
                        testKeychain!.removeValue(forKey: "\(KeychainHelper.defaultService)-\(account)")
                    } else {
                        try KeychainHelper.deletePassword(account: account)
                    }
                    log("\(provider.capitalized) API Key cleared.")
                    onCredentialsChanged?(provider)
                } catch {
                    log("Failed to clear \(provider.capitalized) API Key: \(error)")
                    presentCredentialPersistenceError()
                    retry = true
                }
            }
        }
    }
"""

start1 = content.find("    @objc private func onGeminiApiKey() {")
end1 = content.find("    static func isCredentialFormatValid", start1)
if start1 != -1 and end1 != -1:
    content = content[:start1] + new_method + "\n" + content[end1:]

# Replace runModal in the two error helpers
content = content.replace("alert.runModal()", "_ = alertRunner?(alert) ?? alert.runModal()")

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)

