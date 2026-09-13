import sys

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

# Replace onGeminiApiKey and onOpenAIApiKey with a single `presentCredentialDialog` and adapt `onAction` calls.

# First, find onGeminiApiKey
start1 = content.find("    @objc private func onGeminiApiKey() {")
end1 = content.find("    static func isCredentialFormatValid", start1)
if start1 == -1 or end1 == -1:
    print("Could not find onGeminiApiKey block")
    sys.exit(1)

old_methods = content[start1:end1]

new_method = """    @objc private func onGeminiApiKey() {
        presentCredentialDialog(provider: "gemini")
    }

    @objc private func onOpenAIApiKey() {
        presentCredentialDialog(provider: "openai")
    }

    private func presentCredentialDialog(provider: String) {
        let isGemini = provider == "gemini"
        let account = isGemini ? KeychainHelper.geminiAccount : KeychainHelper.openAIAccount
        let metadata = KeychainHelper.getMetadata(account: account)
        
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
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    guard Self.isCredentialFormatValid(key, provider: provider) else {
                        presentCredentialValidationError(provider: provider)
                        retry = true
                        continue
                    }
                    do {
                        try KeychainHelper.setPassword(account: account, password: key)
                        log("\(provider.capitalized) API Key saved to Keychain.")
                        
                        let successAlert = NSAlert()
                        successAlert.messageText = t("dialog.credential_saved")
                        successAlert.addButton(withTitle: t("btn.ok"))
                        successAlert.runModal()
                        
                        onCredentialsChanged?(provider)
                    } catch {
                        log("Failed to save \(provider.capitalized) API Key: \(error)")
                        presentCredentialPersistenceError()
                        retry = true
                    }
                }
            } else if response == .alertThirdButtonReturn {
                do {
                    try KeychainHelper.deletePassword(account: account)
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

content = content.replace(old_methods, new_method + "\n")

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)

