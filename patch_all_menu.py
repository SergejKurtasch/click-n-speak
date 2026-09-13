import sys

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

# 1. onRuntimeRecoveryRequested
content = content.replace(
    "public var onRuntimeRecoveryRequested: ((MenuRuntimeRecoveryAction) -> Void)?",
    "public var onRuntimeRecoveryRequested: ((RuntimeRecoveryCommand) -> Void)?"
)

# 2. Test injections
injection = """
    // Test injections
    public var alertRunner: ((NSAlert) -> NSApplication.ModalResponse)?
    public var testEnvironment: [String: String]?
    public var testKeychain: [String: String]?
    public var testKeychainSetError: Error?
"""
if "// Test injections" not in content:
    content = content.replace("    public var onCredentialsChanged: ((String) -> Void)?", "    public var onCredentialsChanged: ((String) -> Void)?\n" + injection)

# 3. runtimeRecoveryTitle
old_title = """    private func runtimeRecoveryTitle(_ action: MenuRuntimeRecoveryAction) -> String {
        switch action {
        case .downloadModel: t("menu.recovery_download_model")
        case .redownloadModel: t("menu.recovery_redownload_model")
        case .openAPIKeys: t("menu.recovery_open_api_keys")
        case .selectCloudBackend: t("menu.recovery_select_cloud")
        case .keepPreviousRuntime: t("menu.recovery_keep_previous")
        case .retry: t("btn.retry")
        }
    }"""
new_title = """    private func runtimeRecoveryTitle(_ action: RuntimeRecoveryCommand) -> String {
        switch action.kind {
        case .download: return t("menu.recovery_download_model")
        case .redownload: return t("menu.recovery_redownload_model")
        case .openAPIKeys: return t("menu.recovery_open_api_keys")
        case .selectCloudBackend: return t("menu.recovery_select_cloud")
        case .keepPreviousRuntime: return t("menu.recovery_keep_previous")
        case .retry: return t("btn.retry")
        }
    }"""
content = content.replace(old_title, new_title)

# 4. recoveryItem.representedObject
content = content.replace("recoveryItem.representedObject = action.rawValue", "recoveryItem.representedObject = action")

# 5. onRuntimeRecovery
old_on_recovery = """    @objc private func onRuntimeRecovery(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = MenuRuntimeRecoveryAction(rawValue: raw) else { return }
        switch action {
        case .downloadModel:
            recoverLocalModel(redownload: false)
        case .redownloadModel:
            recoverLocalModel(redownload: true)
        case .openAPIKeys:
            if state.runtime.desiredSTTBackend == "openai" {
                onOpenAIApiKey()
            } else {
                onGeminiApiKey()
            }
        case .selectCloudBackend:
            guard let group = ModelCatalog.cloudSTTModels.first,
                  let model = group.models.first else { return }
            var newConfig = config
            newConfig.raw["stt_backend"] = .string(group.backend)
            newConfig.raw["stt_cloud_model"] = .string(model.id)
            onConfigChanged?(newConfig)
        case .keepPreviousRuntime, .retry:
            onRuntimeRecoveryRequested?(action)
        }
    }"""
new_on_recovery = """    @objc private func onRuntimeRecovery(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? RuntimeRecoveryCommand else { return }
        switch action.kind {
        case .download:
            if case .localModel(let id) = action.target, let model = ModelRegistry.whisperModelByLegacyID(id) ?? ModelRegistry.aiEditorModel(id: id) {
                onDownloadRequested?(model)
            } else {
                recoverLocalModel(redownload: false)
            }
        case .redownload:
            if case .localModel(let id) = action.target, let model = ModelRegistry.whisperModelByLegacyID(id) ?? ModelRegistry.aiEditorModel(id: id) {
                ModelManager.quarantineInvalidArtifact(at: paths.modelFile(for: model), model: model, paths: paths)
                onDownloadRequested?(model)
            } else {
                recoverLocalModel(redownload: true)
            }
        case .openAPIKeys:
            if case .cloudProvider(let name) = action.target {
                presentCredentialDialog(provider: name)
            } else {
                if state.runtime.desiredSTTBackend == "openai" {
                    presentCredentialDialog(provider: "openai")
                } else {
                    presentCredentialDialog(provider: "gemini")
                }
            }
        case .selectCloudBackend:
            guard let group = ModelCatalog.cloudSTTModels.first,
                  let model = group.models.first else { return }
            var newConfig = config
            newConfig.raw["stt_backend"] = .string(group.backend)
            newConfig.raw["stt_cloud_model"] = .string(model.id)
            onConfigChanged?(newConfig)
        case .keepPreviousRuntime, .retry:
            onRuntimeRecoveryRequested?(action)
        }
    }"""
content = content.replace(old_on_recovery, new_on_recovery)

# 6. Replace onGeminiApiKey & onOpenAIApiKey with presentCredentialDialog
start_gemini = content.find("    @objc private func onGeminiApiKey() {")
end_openai = content.find("    static func isCredentialFormatValid", start_gemini)
if start_gemini != -1 and end_openai != -1:
    old_api_keys = content[start_gemini:end_openai]
    new_api_keys = """    @objc private func onGeminiApiKey() {
        presentCredentialDialog(provider: "gemini")
    }

    @objc private func onOpenAIApiKey() {
        presentCredentialDialog(provider: "openai")
    }

    private func presentCredentialDialog(provider: String) {
        let isGemini = provider == "gemini"
        let account = isGemini ? KeychainHelper.geminiAccount : KeychainHelper.openAIAccount
        
        let tk = self.testKeychain
        let env = testEnvironment ?? ProcessInfo.processInfo.environment
        let lookup: @Sendable (String, String) -> String? = { s, a in
            if let testKc = tk { return testKc["\\(s)-\\(a)"] }
            return KeychainHelper.getRawKeychainPassword(service: s, account: a)
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
                            testKeychain!["\\(KeychainHelper.defaultService)-\\(account)"] = key
                        } else {
                            try KeychainHelper.setPassword(account: account, password: key)
                        }
                        log("\\(provider.capitalized) API Key saved to Keychain.")
                        
                        let successAlert = NSAlert()
                        successAlert.messageText = t("dialog.credential_saved")
                        successAlert.addButton(withTitle: t("btn.ok"))
                        _ = alertRunner?(successAlert) ?? successAlert.runModal()
                        
                        onCredentialsChanged?(provider)
                    } catch {
                        log("Failed to save \\(provider.capitalized) API Key: \\(error)")
                        presentCredentialPersistenceError()
                        retry = true
                    }
                }
            } else if response == .alertThirdButtonReturn {
                do {
                    if let err = testKeychainSetError { throw err }
                    if testKeychain != nil {
                        testKeychain!.removeValue(forKey: "\\(KeychainHelper.defaultService)-\\(account)")
                    } else {
                        try KeychainHelper.deletePassword(account: account)
                    }
                    log("\\(provider.capitalized) API Key cleared.")
                    onCredentialsChanged?(provider)
                } catch {
                    log("Failed to clear \\(provider.capitalized) API Key: \\(error)")
                    presentCredentialPersistenceError()
                    retry = true
                }
            }
        }
    }
"""
    content = content.replace(old_api_keys, new_api_keys)
else:
    print("Could not find onGeminiApiKey")
    sys.exit(1)

# 7. Replace runModal in the two error helpers
content = content.replace("alert.runModal()", "alertRunner?(alert) ?? alert.runModal()")
# wait, if there are multiple runModal, they might be replaced recursively if I run the script twice.
# but I'm checking out fresh.
content = content.replace("alertRunner?(alert) ?? alertRunner?(alert) ?? alert.runModal()", "alertRunner?(alert) ?? alert.runModal()")

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
