import sys
import re

with open("Packages/CNSUI/Sources/CNSUI/TermsPanel.swift", "r") as f:
    content = f.read()

# Add states to TermsViewModel
view_model_vars = """    @Published var newTermLanguage: String
    @Published var showingUndoChooser = false
    @Published var undoChooserLanguage = \"\""""
content = content.replace("    @Published var newTermLanguage: String", view_model_vars)

# Add properties
props = """    var configuredLanguages: [String] {
        [coordinator.snapshot.primaryLanguage] + LanguageCode.dedupeList(
            coordinator.snapshot.additionalLanguages,
            primary: coordinator.snapshot.primaryLanguage
        )
    }

    var canRevertAny: Bool {
        configuredLanguages.contains { coordinator.canRevert(language: $0) }
    }

    var undoChooserLanguages: [String] {
        configuredLanguages.filter { coordinator.canRevert(language: $0) }
    }
"""
content = content.replace("""    var configuredLanguages: [String] {
        [coordinator.snapshot.primaryLanguage] + LanguageCode.dedupeList(
            coordinator.snapshot.additionalLanguages,
            primary: coordinator.snapshot.primaryLanguage
        )
    }""", props)


revert_func = """    func revert(language: String) {
        do {
            try coordinator.revert(language: language)
            errorMessage = nil
            showingUndoChooser = false
            load()
        } catch {
            errorMessage = UIErrorLocalization.dictionary(error, i18n: i18n)
        }
    }
"""
content = re.sub(r'    func revert\(\) \{.*?\n    \}', revert_func, content, flags=re.DOTALL)


# UI updates
old_revert_btn = """                Button(viewModel.i18n.t("menu.revert_terms")) { viewModel.revert() }"""
new_revert_btn = """                Button(viewModel.i18n.t("menu.revert_terms")) {
                    if viewModel.languageFilter != "all" {
                        viewModel.revert(language: viewModel.languageFilter)
                    } else {
                        viewModel.undoChooserLanguage = viewModel.coordinator.snapshot.primaryLanguage
                        if !viewModel.undoChooserLanguages.contains(viewModel.undoChooserLanguage) {
                            viewModel.undoChooserLanguage = viewModel.undoChooserLanguages.first ?? ""
                        }
                        if viewModel.undoChooserLanguage.isEmpty {
                            viewModel.errorMessage = viewModel.i18n.t("ui.error_no_snapshot")
                        } else {
                            viewModel.showingUndoChooser = true
                        }
                    }
                }
                .disabled((viewModel.languageFilter == "all" && !viewModel.canRevertAny) || (viewModel.languageFilter != "all" && !viewModel.coordinator.canRevert(language: viewModel.languageFilter)))
                .popover(isPresented: $viewModel.showingUndoChooser) {
                    VStack {
                        Text(viewModel.i18n.t("terms.undo_prompt"))
                        Picker("", selection: $viewModel.undoChooserLanguage) {
                            ForEach(viewModel.undoChooserLanguages, id: \\.self) {
                                Text($0.uppercased()).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                        HStack {
                            Button(viewModel.i18n.t("btn.cancel")) { viewModel.showingUndoChooser = false }
                            Button(viewModel.i18n.t("menu.revert_terms")) {
                                viewModel.revert(language: viewModel.undoChooserLanguage)
                            }
                        }
                    }
                    .padding()
                }"""
content = content.replace(old_revert_btn, new_revert_btn)

with open("Packages/CNSUI/Sources/CNSUI/TermsPanel.swift", "w") as f:
    f.write(content)
