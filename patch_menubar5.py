import sys

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

content = content.replace(
    "public var onRuntimeRecoveryRequested: ((MenuRuntimeRecoveryAction) -> Void)?",
    "public var onRuntimeRecoveryRequested: ((RuntimeRecoveryCommand) -> Void)?"
)

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

if old_on_recovery in content:
    content = content.replace(old_on_recovery, new_on_recovery)
else:
    print("Could not find onRuntimeRecovery")
    sys.exit(1)

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
