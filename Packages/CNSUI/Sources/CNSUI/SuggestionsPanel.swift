import AppKit
import CNSDictionary
import CNSCore
import SwiftUI

@MainActor
public final class SuggestionsPanel: NSWindow, RefreshablePanel {
    private let viewModel: SuggestionsViewModel

    public init(coordinator: DictionaryCoordinator, i18n: I18n) {
        let viewModel = SuggestionsViewModel(coordinator: coordinator, i18n: i18n)
        self.viewModel = viewModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = i18n.t("suggestions.window_title")
        minSize = NSSize(width: 560, height: 360)
        isReleasedWhenClosed = false
        contentViewController = NSHostingController(rootView: SuggestionsView(viewModel: viewModel))
        center()
    }

    public func refresh() { viewModel.load(resetSelection: true) }
    public func refreshForPresentation() { refresh() }
    var suggestionCountForTesting: Int {
        viewModel.suggestions.values.reduce(0) { $0 + $1.count }
    }

}

private struct SuggestionsView: View {
    @ObservedObject var viewModel: SuggestionsViewModel

    var body: some View {
        VStack(spacing: 12) {
            Text(viewModel.i18n.t("suggestions.description"))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if viewModel.languages.isEmpty {
                Text(viewModel.i18n.t("suggestions.empty"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.languages, id: \.self) { language in
                        Section(language.uppercased()) {
                            ForEach(viewModel.suggestions[language] ?? [], id: \.term) { item in
                                HStack {
                                    Toggle(isOn: viewModel.selectionBinding(item, language: language)) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.term)
                                            Text(viewModel.detail(item))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .accessibilityIdentifier("suggestions.row.\(viewModel.id(item, language: language))")
                                }
                            }
                        }
                    }
                }
            }
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Button(viewModel.i18n.t(viewModel.allSelected
                    ? "suggestions.deselect_all"
                    : "suggestions.select_all")) { viewModel.toggleAll() }
                    .disabled(viewModel.languages.isEmpty)
                Button(viewModel.i18n.t("btn.add_selected")) { viewModel.acceptSelected() }
                    .disabled(viewModel.selected.isEmpty)
                    .keyboardShortcut(.defaultAction)
                Button(viewModel.i18n.t("suggestions.reject_selected"), role: .destructive) {
                    viewModel.rejectSelected()
                }
                .disabled(viewModel.selected.isEmpty)
                Button(viewModel.i18n.t("suggestions.add_all")) { viewModel.addAll() }
                    .disabled(viewModel.languages.isEmpty)
                Button(viewModel.i18n.t("btn.auto_mode")) { viewModel.enableAutoAndAddSelected() }
                    .disabled(viewModel.selected.isEmpty)
                Spacer()
                Button(viewModel.i18n.t("btn.later")) { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 320)
    }
}

@MainActor
private final class SuggestionsViewModel: ObservableObject {
    let i18n: I18n
    @Published private(set) var suggestions: [String: [TermCandidate]] = [:]
    @Published var selected = Set<String>()
    @Published var errorMessage: String?
    private let coordinator: DictionaryCoordinator

    init(coordinator: DictionaryCoordinator, i18n: I18n) {
        self.coordinator = coordinator
        self.i18n = i18n
        load(resetSelection: true)
    }

    var languages: [String] { suggestions.keys.sorted() }
    var allIDs: Set<String> {
        Set(suggestions.flatMap { language, items in
            items.map { id($0, language: language) }
        })
    }
    var allSelected: Bool { !allIDs.isEmpty && selected == allIDs }

    func load(resetSelection: Bool = false) {
        suggestions = coordinator.pendingSuggestions()
        if resetSelection {
            selected = allIDs
        } else {
            selected.formIntersection(allIDs)
        }
    }

    func id(_ item: TermCandidate, language: String) -> String {
        "\(language)||\(TermCanonicalizer.canonicalKey(item.term))"
    }

    func selectionBinding(_ item: TermCandidate, language: String) -> Binding<Bool> {
        let key = id(item, language: language)
        return Binding(
            get: { self.selected.contains(key) },
            set: { isSelected in
                if isSelected { self.selected.insert(key) }
                else { self.selected.remove(key) }
            }
        )
    }

    func detail(_ item: TermCandidate) -> String {
        let source = item.source == "correction" ? "correction"
            : item.source == "both" ? "both" : "frequency"
        return i18n.t("suggestions.count_detail", [
            "count": String(item.count),
            "frequency": String(item.frequencyCount),
            "correction": String(item.correctionCount),
            "source": i18n.t("suggestions.source_\(source)"),
        ])
    }

    func toggleAll() { selected = allSelected ? [] : allIDs }

    func accept(_ item: TermCandidate, language: String) {
        perform { try coordinator.acceptSuggestion(language: language, term: item.term) }
    }

    func reject(_ item: TermCandidate, language: String) {
        perform { try coordinator.rejectSuggestion(language: language, term: item.term) }
    }

    func addAll() { perform { try coordinator.addAllPendingSuggestions() } }

    func acceptSelected() { mutateSelected(accept: true) }
    func rejectSelected() { mutateSelected(accept: false) }

    func enableAutoAndAddSelected() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = i18n.t("suggestions.confirm_auto_title")
        alert.informativeText = i18n.t(
            "suggestions.confirm_auto_body",
            ["n": String(selected.count)]
        )
        alert.addButton(withTitle: i18n.t("suggestions.btn_confirm_auto"))
        alert.addButton(withTitle: i18n.t("btn.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        mutateSelected(accept: true, reload: false)
        guard errorMessage == nil else { return }
        perform {
            try coordinator.setPromptUpdateMode("auto")
        }
    }

    private func mutateSelected(accept: Bool, reload: Bool = true) {
        do {
            for language in languages {
                for item in suggestions[language] ?? [] where selected.contains(id(item, language: language)) {
                    if accept { try coordinator.acceptSuggestion(language: language, term: item.term) }
                    else { try coordinator.rejectSuggestion(language: language, term: item.term) }
                }
            }
            errorMessage = nil
            if reload { load(resetSelection: true) }
        } catch {
            errorMessage = UIErrorLocalization.dictionary(error, i18n: i18n)
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            errorMessage = nil
            load(resetSelection: true)
        } catch {
            errorMessage = UIErrorLocalization.dictionary(error, i18n: i18n)
        }
    }
}
