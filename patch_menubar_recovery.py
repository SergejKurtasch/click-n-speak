with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

import re

# Update runtimeRecoveryTitle
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

# The item creation:
# recoveryItem.representedObject = action.rawValue
# ->
# recoveryItem.representedObject = action.jsonString() or something, let's just use a string representation.
# Wait, Swift struct in Any works: recoveryItem.representedObject = action
content = content.replace("recoveryItem.representedObject = action.rawValue", "recoveryItem.representedObject = action")

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
