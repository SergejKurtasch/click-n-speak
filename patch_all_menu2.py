import re

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

# 1
content = re.sub(
    r'public var onRuntimeRecoveryRequested: \(\(MenuRuntimeRecoveryAction\) -> Void\)\?',
    r'public var onRuntimeRecoveryRequested: ((RuntimeRecoveryCommand) -> Void)?',
    content
)

# 2
content = re.sub(
    r'recoveryItem.representedObject = action.rawValue',
    r'recoveryItem.representedObject = action',
    content
)

# 3
old_title_pattern = r'    private func runtimeRecoveryTitle\(_ action: MenuRuntimeRecoveryAction\) -> String \{[\s\S]*?    \}'
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
content = re.sub(old_title_pattern, new_title, content)

# 4
old_recovery_pattern = r'    @objc private func onRuntimeRecovery\(_ sender: NSMenuItem\) \{[\s\S]*?(?=    @objc private func)'
new_recovery = """    @objc private func onRuntimeRecovery(_ sender: NSMenuItem) {
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
content = re.sub(old_recovery_pattern, new_recovery, content)

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
