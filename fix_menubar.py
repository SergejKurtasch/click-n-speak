import re

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

# Fix onRuntimeRecoveryRequested type
content = re.sub(
    r'public var onRuntimeRecoveryRequested: \(\(MenuRuntimeRecoveryAction\) -> Void\)\?',
    r'public var onRuntimeRecoveryRequested: ((RuntimeRecoveryCommand) -> Void)?',
    content
)

# Fix double replacement
content = content.replace("alertRunner?(alert) ?? _ = alertRunner?(alert) ?? alert.runModal()", "alertRunner?(alert) ?? alert.runModal()")

# Fix capturing self in Sendable closure
old_lookup = """        let lookup: @Sendable (String, String) -> String? = { s, a in
            if let tk = self.testKeychain { return tk["\\(s)-\\(a)"] }
            return KeychainHelper.getRawKeychainPassword(service: s, account: a)
        }"""
new_lookup = """        let tk = self.testKeychain
        let lookup: @Sendable (String, String) -> String? = { s, a in
            if let testKc = tk { return testKc["\\(s)-\\(a)"] }
            return KeychainHelper.getRawKeychainPassword(service: s, account: a)
        }"""
content = content.replace(old_lookup, new_lookup)

# Ensure onRuntimeRecovery is actually replaced!
# My previous script might have failed because I used the old string. I will just replace the whole function using regex.
on_recovery_pattern = r'    @objc private func onRuntimeRecovery\(_ sender: NSMenuItem\) \{[\s\S]*?(?=    @objc private func)'
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
    }
"""
content = re.sub(on_recovery_pattern, new_on_recovery + "\n", content, count=1)

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
