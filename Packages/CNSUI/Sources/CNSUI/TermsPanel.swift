import AppKit
import CNSDictionary
import CNSCore
import SwiftUI

@MainActor
public final class TermsPanel: NSWindow, RefreshablePanel {
    private let viewModel: TermsViewModel

    public init(coordinator: DictionaryCoordinator, i18n: I18n) {
        let viewModel = TermsViewModel(coordinator: coordinator, i18n: i18n)
        self.viewModel = viewModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = i18n.t("terms.window_title")
        minSize = NSSize(width: 700, height: 420)
        isReleasedWhenClosed = false
        contentViewController = NSHostingController(rootView: TermsView(viewModel: viewModel))
        center()
    }

    public func refresh() { viewModel.load(resetDrafts: true) }
    public func refreshForPresentation() { refresh() }
    var termCountForTesting: Int { viewModel.terms.count }

}

private struct TermsView: View {
    @ObservedObject var viewModel: TermsViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField(viewModel.i18n.t("terms.new_placeholder"), text: $viewModel.newTerm)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("terms.new-term")
                Picker(viewModel.i18n.t("terms.col_lang"), selection: $viewModel.newTermLanguage) {
                    ForEach(viewModel.configuredLanguages, id: \.self) {
                        Text($0.uppercased()).tag($0)
                    }
                }
                .frame(width: 120)
                Button(viewModel.i18n.t("terms.add")) { viewModel.addTerm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(viewModel.i18n.t("menu.revert_terms")) { viewModel.revert() }
            }
            HStack {
                TextField(viewModel.i18n.t("terms.col_term"), text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("terms.search")
                Picker(viewModel.i18n.t("terms.col_lang"), selection: $viewModel.languageFilter) {
                    Text(viewModel.i18n.t("terms.filter_all")).tag("all")
                    ForEach(viewModel.languages, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                .pickerStyle(.menu)
                Picker(viewModel.i18n.t("terms.col_source"), selection: $viewModel.sourceFilter) {
                    Text(viewModel.i18n.t("terms.filter_all")).tag("all")
                    ForEach(["manual", "correction", "auto"], id: \.self) {
                        Text(viewModel.sourceLabel($0)).tag($0)
                    }
                }
                .pickerStyle(.menu)
                Picker(viewModel.i18n.t("terms.filter_state"), selection: $viewModel.stateFilter) {
                    Text(viewModel.i18n.t("terms.filter_all")).tag("all")
                    Text(viewModel.i18n.t("terms.state_active")).tag("active")
                    Text(viewModel.i18n.t("terms.state_inactive")).tag("inactive")
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            if viewModel.filteredTerms.isEmpty {
                Text(viewModel.i18n.t("terms.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 12) {
                    Text(viewModel.i18n.t("terms.col_term")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(viewModel.i18n.t("terms.col_lang")).frame(width: 42)
                    Text(viewModel.i18n.t("terms.col_source")).frame(width: 90)
                    Text(viewModel.i18n.t("terms.col_use_count")).frame(width: 45)
                    Text(viewModel.i18n.t("terms.col_added")).frame(width: 86)
                    Text(viewModel.i18n.t("terms.col_last_seen")).frame(width: 86)
                    Spacer().frame(width: 185)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                List(viewModel.filteredTerms) { item in
                    HStack(spacing: 12) {
                        TextField(
                            viewModel.i18n.t("terms.col_term"),
                            text: viewModel.binding(for: item)
                        )
                        .disabled(item.inactive)
                        .onSubmit { viewModel.save(item) }
                        Text(item.language.uppercased()).frame(width: 42)
                        Text(viewModel.sourceLabel(item.source)).frame(width: 90)
                        Text("\(item.useCount)").frame(width: 45)
                        Text(viewModel.dateLabel(item.addedAt)).frame(width: 86)
                        Text(viewModel.dateLabel(item.lastSeen)).frame(width: 86)
                        if item.inactive {
                            Button(viewModel.i18n.t("terms.reactivate")) { viewModel.reactivate(item) }
                        } else {
                            Button(viewModel.i18n.t("btn.save")) { viewModel.save(item) }
                        }
                        Button(viewModel.i18n.t("btn.delete"), role: .destructive) {
                            viewModel.delete(item)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("terms.row.\(item.id)")
                }
            }
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            Button(viewModel.i18n.t("btn.close")) { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(minWidth: 600, minHeight: 360)
    }
}

@MainActor
private final class TermsViewModel: ObservableObject {
    let i18n: I18n
    @Published private(set) var terms: [DictionaryTerm] = []
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var languageFilter = "all"
    @Published var sourceFilter = "all"
    @Published var stateFilter = "all"
    @Published var newTerm = ""
    @Published var newTermLanguage: String
    private let coordinator: DictionaryCoordinator
    private var drafts: [String: String] = [:]

    init(coordinator: DictionaryCoordinator, i18n: I18n) {
        self.coordinator = coordinator
        self.i18n = i18n
        self.newTermLanguage = coordinator.snapshot.primaryLanguage
        load(resetDrafts: true)
    }

    func load(resetDrafts: Bool = false) {
        terms = coordinator.terms()
        if resetDrafts { drafts.removeAll() }
        for item in terms { drafts[item.id] = drafts[item.id] ?? item.term }
        if !configuredLanguages.contains(newTermLanguage) {
            newTermLanguage = coordinator.snapshot.primaryLanguage
        }
    }

    var languages: [String] { Set(terms.map(\.language)).sorted() }
    var configuredLanguages: [String] {
        [coordinator.snapshot.primaryLanguage] + LanguageCode.dedupeList(
            coordinator.snapshot.additionalLanguages,
            primary: coordinator.snapshot.primaryLanguage
        )
    }

    var filteredTerms: [DictionaryTerm] {
        let query = TermCanonicalizer.canonicalKey(searchText)
        return terms.filter { item in
            (languageFilter == "all" || item.language == languageFilter)
                && (sourceFilter == "all" || item.source == sourceFilter)
                && (stateFilter == "all"
                    || (stateFilter == "inactive" ? item.inactive : !item.inactive))
                && (query.isEmpty || TermCanonicalizer.canonicalKey(item.term).contains(query))
        }
    }

    func binding(for item: DictionaryTerm) -> Binding<String> {
        Binding(
            get: { self.drafts[item.id] ?? item.term },
            set: { self.drafts[item.id] = $0 }
        )
    }

    func save(_ item: DictionaryTerm) {
        let replacement = drafts[item.id] ?? item.term
        guard replacement != item.term else { return }
        perform { try coordinator.editTerm(language: item.language, oldTerm: item.term, newTerm: replacement) }
    }

    func delete(_ item: DictionaryTerm) {
        perform { try coordinator.deleteTerm(language: item.language, term: item.term) }
    }

    func reactivate(_ item: DictionaryTerm) {
        perform { try coordinator.reactivateTerm(language: item.language, term: item.term) }
    }

    func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TermParsing.isValidTerm(term) else {
            errorMessage = i18n.t("ui.error_invalid_term")
            return
        }
        guard coordinator.addManualTerm(term, language: newTermLanguage) else {
            errorMessage = i18n.t("ui.error_duplicate_term")
            return
        }
        newTerm = ""
        errorMessage = nil
        load(resetDrafts: true)
    }

    func revert() {
        let language = languageFilter == "all" ? coordinator.snapshot.primaryLanguage : languageFilter
        perform { try coordinator.revert(language: language) }
    }

    func sourceLabel(_ source: String) -> String { i18n.t("terms.source_\(source)") }

    func dateLabel(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return String(value.prefix(10))
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            errorMessage = nil
            load(resetDrafts: true)
        } catch {
            errorMessage = UIErrorLocalization.dictionary(error, i18n: i18n)
        }
    }
}
