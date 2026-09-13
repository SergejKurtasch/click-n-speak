import sys
import re

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

# Find the start of onDeleteLocalModel
start_idx = content.find("    @objc private func onDeleteLocalModel() {")
# Find the next function
end_idx = content.find("    @objc private func onEditTerms() {")

if start_idx == -1 or end_idx == -1:
    print("Could not find function bounds!")
    sys.exit(1)

old_func = content[start_idx:end_idx]

new_func = """    @objc private func onDeleteLocalModel() {
        let installed = ModelRegistry.models.filter { ModelManager.isDownloaded($0, paths: paths) }
        guard !installed.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = t("dialog.no_local_models_title")
            alert.informativeText = t("dialog.no_local_models_body")
            alert.addButton(withTitle: t("btn.ok"))
            _ = alertRunner?(alert) ?? alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("dialog.delete_local_model_title")
        alert.informativeText = t("dialog.delete_local_model_body")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        
        var anyEnabled = false
        for model in installed {
            let size = ModelManager.diskUsageForModel(model, paths: paths)
            let reasons = ModelArtifactAccessRegistry.shared.snapshotReasons(for: model.id)
            let isDeleting = ModelArtifactAccessRegistry.shared.isDeletionInProgress(for: model.id)
            
            let title: String
            let isEnabled: Bool
            
            if isDeleting {
                title = "\\(model.displayName) · " + t("state.deleting")
                isEnabled = false
            } else if !reasons.isEmpty {
                let reasonText: String
                if reasons.contains(where: { 
                    if case .downloading = $0 { return true }; return false 
                }) {
                    reasonText = t("state.downloading")
                } else if reasons.contains(where: { 
                    if case .preparation = $0 { return true }; return false 
                }) {
                    reasonText = t("state.preparing")
                } else {
                    reasonText = t("state.in_use")
                }
                title = "\\(model.displayName) · " + reasonText
                isEnabled = false
            } else {
                title = "\\(model.displayName) · \\(ModelManager.formattedSize(size))"
                isEnabled = true
                anyEnabled = true
            }
            
            picker.addItem(withTitle: title)
            picker.lastItem?.representedObject = model.id
            if !isEnabled {
                picker.lastItem?.isEnabled = false
            }
        }
        picker.autoenablesItems = false
        picker.setAccessibilityLabel(t("dialog.delete_local_model_picker"))
        alert.accessoryView = picker
        
        if let firstEnabled = picker.itemArray.first(where: { $0.isEnabled }) {
            picker.select(firstEnabled)
        }
        
        let deleteBtn = alert.addButton(withTitle: t("btn.delete"))
        deleteBtn.isEnabled = anyEnabled
        alert.addButton(withTitle: t("btn.cancel"))
        let response = alertRunner?(alert) ?? alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        guard let modelID = picker.selectedItem?.representedObject as? String,
              let model = ModelRegistry.model(id: modelID) else { return }

        do {
            try ModelManager.delete(model, paths: paths)
            onLocalModelsChanged?()
            log("Local model deleted: \\(model.id)")
        } catch {
            log("Failed to delete models: \\(error)")
            let errorAlert = NSAlert()
            errorAlert.alertStyle = .critical
            errorAlert.messageText = t("dialog.delete_failed_title")
            errorAlert.informativeText = error.localizedDescription
            errorAlert.addButton(withTitle: t("btn.ok"))
            _ = alertRunner?(errorAlert) ?? errorAlert.runModal()
        }
    }
"""

content = content[:start_idx] + new_func + content[end_idx:]

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
