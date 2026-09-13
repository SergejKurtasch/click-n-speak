import re

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "r") as f:
    content = f.read()

# Replace MenuRuntimeRecoveryAction with RuntimeRecoveryCommand
content = content.replace("MenuRuntimeRecoveryAction", "RuntimeRecoveryCommand")
content = content.replace("RuntimeRecoveryAction", "RuntimeRecoveryCommand")

old_recovery1 = """    private func recoveryActions(
        for error: Error,
        deactivatedCredential: Bool
    ) -> [RuntimeRecoveryCommand] {
        if deactivatedCredential { return [.openAPIKeys] }
        if case let RuntimePreparationError.credentialMissing(backend) = error,
           invalidatedCredentialProviders.contains(backend.lowercased()) {
            return [.openAPIKeys]
        }
        if let activeRuntime, runtimeUsesPendingCredential(activeRuntime) {
            if error is RuntimePreparationError {
                return [.retry, .openAPIKeys]
            }
            return [.retry]
        }
        return recoveryActions(for: error)
    }"""
new_recovery1 = """    private func recoveryActions(
        for error: Error,
        deactivatedCredential: Bool
    ) -> [RuntimeRecoveryCommand] {
        if deactivatedCredential {
            let provider = (error as? RuntimePreparationError).flatMap { e -> String? in
                if case .credentialMissing(let b) = e { return b.lowercased() }
                return nil
            } ?? "gemini"
            return [RuntimeRecoveryCommand(kind: .openAPIKeys, target: .cloudProvider(name: provider))]
        }
        if case let RuntimePreparationError.credentialMissing(backend) = error,
           invalidatedCredentialProviders.contains(backend.lowercased()) {
            return [RuntimeRecoveryCommand(kind: .openAPIKeys, target: .cloudProvider(name: backend.lowercased()))]
        }
        if let activeRuntime, runtimeUsesPendingCredential(activeRuntime) {
            if let prepError = error as? RuntimePreparationError {
                var cmds = [RuntimeRecoveryCommand(kind: .retry, target: .general)]
                if case .credentialMissing(let b) = prepError {
                    cmds.append(RuntimeRecoveryCommand(kind: .openAPIKeys, target: .cloudProvider(name: b.lowercased())))
                }
                return cmds
            }
            return [RuntimeRecoveryCommand(kind: .retry, target: .general)]
        }
        return recoveryActions(for: error)
    }"""

old_recovery2 = """    private func recoveryActions(for error: Error) -> [RuntimeRecoveryCommand] {
        guard let error = error as? RuntimePreparationError else {
            return [.retry, .keepPreviousRuntime]
        }
        switch error {
        case .modelMissing:
            return [.downloadModel, .selectCloudBackend, .keepPreviousRuntime]
        case .modelCorrupted:
            return [.redownloadModel, .selectCloudBackend, .keepPreviousRuntime]
        case .credentialMissing:
            return [.openAPIKeys, .keepPreviousRuntime]
        case .unsupportedBackend, .unsupportedModel, .initializationFailed:
            return [.retry, .keepPreviousRuntime]
        }
    }"""
new_recovery2 = """    private func recoveryActions(for error: Error) -> [RuntimeRecoveryCommand] {
        guard let error = error as? RuntimePreparationError else {
            return [
                RuntimeRecoveryCommand(kind: .retry, target: .general),
                RuntimeRecoveryCommand(kind: .keepPreviousRuntime, target: .general)
            ]
        }
        switch error {
        case .modelMissing(let id):
            return [
                RuntimeRecoveryCommand(kind: .download, target: .localModel(id: id)),
                RuntimeRecoveryCommand(kind: .selectCloudBackend, target: .general),
                RuntimeRecoveryCommand(kind: .keepPreviousRuntime, target: .general)
            ]
        case .modelCorrupted(let id):
            return [
                RuntimeRecoveryCommand(kind: .redownload, target: .localModel(id: id)),
                RuntimeRecoveryCommand(kind: .selectCloudBackend, target: .general),
                RuntimeRecoveryCommand(kind: .keepPreviousRuntime, target: .general)
            ]
        case .credentialMissing(let backend):
            return [
                RuntimeRecoveryCommand(kind: .openAPIKeys, target: .cloudProvider(name: backend)),
                RuntimeRecoveryCommand(kind: .keepPreviousRuntime, target: .general)
            ]
        case .unsupportedBackend, .unsupportedModel, .initializationFailed:
            return [
                RuntimeRecoveryCommand(kind: .retry, target: .general),
                RuntimeRecoveryCommand(kind: .keepPreviousRuntime, target: .general)
            ]
        }
    }"""

content = content.replace(old_recovery1, new_recovery1)
content = content.replace(old_recovery2, new_recovery2)

with open("ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift", "w") as f:
    f.write(content)
