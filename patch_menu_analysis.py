import sys

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "r") as f:
    content = f.read()

# Replace onModeSuggest, onModeAuto, onModeDisabled, onReviewSuggestions
old_onModeSuggest = """    @objc private func onModeSuggest() {
        if let dictionaryCoordinator {
            do { try dictionaryCoordinator.setPromptUpdateMode("suggest") }
            catch { log("Prompt mode update failed: \\(error.localizedDescription)") }
            return
        }"""
new_onModeSuggest = """    @objc private func onModeSuggest() {
        if let dictionaryCoordinator {
            do { try dictionaryCoordinator.setPromptUpdateMode("suggest") }
            catch {
                log("Prompt mode update failed: \\(error.localizedDescription)")
                showErrorAlert(message: UIErrorLocalization.dictionary(error, i18n: i18n))
            }
            return
        }"""
content = content.replace(old_onModeSuggest, new_onModeSuggest)

old_onModeAuto = """    @objc private func onModeAuto() {
        if let dictionaryCoordinator {
            do { try dictionaryCoordinator.setPromptUpdateMode("auto") }
            catch { log("Prompt mode update failed: \\(error.localizedDescription)") }
            return
        }"""
new_onModeAuto = """    @objc private func onModeAuto() {
        if let dictionaryCoordinator {
            do { try dictionaryCoordinator.setPromptUpdateMode("auto") }
            catch {
                log("Prompt mode update failed: \\(error.localizedDescription)")
                showErrorAlert(message: UIErrorLocalization.dictionary(error, i18n: i18n))
            }
            return
        }"""
content = content.replace(old_onModeAuto, new_onModeAuto)

old_onModeDisabled = """    @objc private func onModeDisabled() {
        if let dictionaryCoordinator {
            do { try dictionaryCoordinator.setPromptUpdateMode("disabled") }
            catch { log("Prompt mode update failed: \\(error.localizedDescription)") }
            return
        }"""
new_onModeDisabled = """    @objc private func onModeDisabled() {
        if let dictionaryCoordinator {
            do { try dictionaryCoordinator.setPromptUpdateMode("disabled") }
            catch {
                log("Prompt mode update failed: \\(error.localizedDescription)")
                showErrorAlert(message: UIErrorLocalization.dictionary(error, i18n: i18n))
            }
            return
        }"""
content = content.replace(old_onModeDisabled, new_onModeDisabled)

old_onReview = """        Task { @MainActor [weak self, weak dictionaryCoordinator] in
            guard let self, let dictionaryCoordinator else { return }
            do { try await dictionaryCoordinator.runPromptAnalysis(onDemand: true) }
            catch { self.log("On-demand prompt analysis failed: \\(error.localizedDescription)") }
            self.presentSuggestionsPanel(using: dictionaryCoordinator)
        }"""
new_onReview = """        Task { @MainActor [weak self, weak dictionaryCoordinator] in
            guard let self, let dictionaryCoordinator else { return }
            do {
                try await dictionaryCoordinator.runPromptAnalysis(onDemand: true)
                self.presentSuggestionsPanel(using: dictionaryCoordinator)
            } catch {
                self.log("On-demand prompt analysis failed: \\(error.localizedDescription)")
                self.showErrorAlert(message: UIErrorLocalization.dictionary(error, i18n: self.i18n))
            }
        }"""
content = content.replace(old_onReview, new_onReview)

with open("Packages/CNSUI/Sources/CNSUI/MenuBarController.swift", "w") as f:
    f.write(content)
