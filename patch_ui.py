import sys

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

old_code = """        let activeSTT = runtimeSnapshot?.transcriber.modelID
        let activeEditor = runtimeSnapshot?.aiEditor.modelID
        let installed = ModelRegistry.models.filter { ModelManager.isDownloaded($0, paths: paths) }
        let inactive = installed.filter { model in
            if model.capabilities.contains(.stt) {
                return model.id != activeSTT
                    && !(model.id == ModelRegistry.defaultTranscriberModelID
                        && activeSTT == "distil-large-v3-q5_0")
            } else {
                return model.id != activeEditor
                    && !(model.id == ModelRegistry.defaultAiEditorModelID
                        && activeEditor == "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
            }
        }
        guard !inactive.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = t("dialog.active_model_delete_title")
            alert.informativeText = t("dialog.active_model_delete_body")
            alert.addButton(withTitle: t("btn.ok"))
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("dialog.delete_local_model_title")
        alert.informativeText = t("dialog.delete_local_model_body")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        for model in inactive {
            let size = ModelManager.diskUsageForModel(model, paths: paths)
            picker.addItem(withTitle: "\(model.displayName) · \(ModelManager.formattedSize(size))")
            picker.lastItem?.representedObject = model.id
        }
        picker.setAccessibilityLabel(t("dialog.delete_local_model_picker"))
        alert.accessoryView = picker
        alert.addButton(withTitle: t("btn.delete"))
        alert.addButton(withTitle: t("btn.cancel"))
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        guard let modelID = picker.selectedItem?.representedObject as? String,
              let model = ModelRegistry.model(id: modelID) else { return }

        do {
            try ModelManager.delete(model, paths: paths, activeModelID: nil)
            onLocalModelsChanged?()
            log("Local model deleted: \(model.id)")
        } catch {
            log("Failed to delete models: \(error)")
        }"""

new_code = """        let installed = ModelRegistry.models.filter { ModelManager.isDownloaded($0, paths: paths) }
        guard !installed.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = t("dialog.no_local_models_title") // "dialog.active_model_delete_title" fallback? Actually "dialog.active_model_delete_title" if no models, wait no, if none installed, it should probably be a different title but let's keep the existing logic.
            // Oh wait, if `installed.isEmpty`, it used to crash or show something? Let's use active_model_delete_title just in case.
            alert.messageText = t("dialog.active_model_delete_title")
            alert.informativeText = t("dialog.active_model_delete_body")
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
                    if case .downloading = $0 { return true }
                    return false
                }) {
                    reasonText = t("state.downloading")
                } else if reasons.contains(where: {
                    if case .preparation = $0 { return true }
                    return false
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
            // Disable if not available! Wait, NSMenuItem.isEnabled
            if !isEnabled {
                // picker.itemArray.last?.isEnabled = false doesn't work if autoenablesItems is true
                picker.lastItem?.isEnabled = false
            }
        }
        picker.autoenablesItems = false
        picker.setAccessibilityLabel(t("dialog.delete_local_model_picker"))
        alert.accessoryView = picker
        
        // Select first enabled item
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
        }"""
content = content.replace(old_code, new_code)
with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
