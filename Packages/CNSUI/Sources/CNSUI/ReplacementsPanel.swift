import AppKit
import CNSDictionary
import CNSCore
import SwiftUI

@MainActor
public final class ReplacementsPanel: NSWindow, RefreshablePanel {
    private let viewModel: ReplacementsViewModel

    public init(coordinator: DictionaryCoordinator, i18n: I18n) {
        let viewModel = ReplacementsViewModel(coordinator: coordinator, i18n: i18n)
        self.viewModel = viewModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = i18n.t("replacements.window_title")
        minSize = NSSize(width: 620, height: 420)
        isReleasedWhenClosed = false
        contentViewController = NSHostingController(rootView: ReplacementsView(viewModel: viewModel))
        center()
    }

    public func refresh() { viewModel.load() }

    public func refreshForPresentation() {
        viewModel.isRejectedExpanded = false
        viewModel.load(resetDrafts: true)
    }

    var replacementCountForTesting: Int {
        viewModel.sections.active.count + viewModel.sections.candidates.count
    }
    var activeReplacementCountForTesting: Int { viewModel.sections.active.count }
    var candidateReplacementCountForTesting: Int { viewModel.sections.candidates.count }
    var rejectedReplacementCountForTesting: Int { viewModel.sections.rejected.count }
    var isRejectedSectionExpandedForTesting: Bool { viewModel.isRejectedExpanded }

    func approveReplacementForTesting(from: String, to: String) {
        viewModel.approve(from: from, to: to)
    }

    func rejectReplacementForTesting(from: String, to: String) {
        viewModel.reject(from: from, to: to)
    }

    func restoreReplacementForTesting(from: String, to: String) {
        viewModel.restore(from: from, to: to)
    }

}

private struct ReplacementsView: View {
    @ObservedObject var viewModel: ReplacementsViewModel

    var body: some View {
        VStack(spacing: 12) {
            Text(viewModel.i18n.t("replacements.description"))
                .foregroundStyle(.secondary)
            HStack {
                TextField(viewModel.i18n.t("replacements.placeholder_from"), text: $viewModel.newFrom)
                    .accessibilityIdentifier("replacements.new-from")
                Image(systemName: "arrow.right")
                    .accessibilityHidden(true)
                TextField(viewModel.i18n.t("replacements.placeholder_to"), text: $viewModel.newTo)
                    .accessibilityIdentifier("replacements.new-to")
                Button(viewModel.i18n.t("btn.save")) { viewModel.addManualPair() }
                    .keyboardShortcut(.defaultAction)
            }
            if viewModel.isEmpty {
                Text(viewModel.i18n.t("replacements.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section(viewModel.sectionTitle("replacements.section_active", count: viewModel.sections.active.count)) {
                        if viewModel.sections.active.isEmpty {
                            emptySectionText("replacements.empty_active")
                        } else {
                            ForEach(viewModel.sections.active) { row in
                                activeRow(row)
                            }
                        }
                    }
                    Section(viewModel.sectionTitle(
                        "replacements.section_candidates",
                        count: viewModel.sections.candidates.count
                    )) {
                        if viewModel.sections.candidates.isEmpty {
                            emptySectionText("replacements.empty_candidates")
                        } else {
                            ForEach(viewModel.sections.candidates) { row in
                                candidateRow(row)
                            }
                        }
                    }
                    Section {
                        DisclosureGroup(isExpanded: $viewModel.isRejectedExpanded) {
                            if viewModel.sections.rejected.isEmpty {
                                emptySectionText("replacements.empty_rejected")
                            } else {
                                ForEach(viewModel.sections.rejected) { row in
                                    rejectedRow(row)
                                }
                            }
                        } label: {
                            Text(viewModel.sectionTitle(
                                "replacements.section_rejected",
                                count: viewModel.sections.rejected.count
                            ))
                            .font(.headline)
                        }
                    }
                }
            }
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            Button(viewModel.i18n.t("replacements.btn_done")) { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(minWidth: 560, minHeight: 380)
    }

    @ViewBuilder
    private func activeRow(_ row: ReplacementRow) -> some View {
        HStack {
            if row.source == "manual" {
                TextField(
                    viewModel.i18n.t("replacements.placeholder_from"),
                    text: viewModel.fromBinding(for: row)
                )
            } else {
                Text(row.from).fontWeight(.semibold)
            }
            Image(systemName: "arrow.right").accessibilityHidden(true)
            if row.source == "manual" {
                TextField(
                    viewModel.i18n.t("replacements.placeholder_to"),
                    text: viewModel.toBinding(for: row)
                )
            } else {
                Text(row.to)
            }
            Spacer()
            Text(row.source == "manual"
                ? viewModel.i18n.t("replacements.badge_manual")
                : viewModel.i18n.t("replacements.badge_auto", ["c": "\(row.count)"]))
                .foregroundStyle(.secondary)
            if row.source == "manual" {
                Button(viewModel.i18n.t("btn.save")) { viewModel.save(row) }
                    .accessibilityIdentifier("replacements.row.\(row.id).save")
            }
            Button(viewModel.i18n.t("replacements.action_reject"), role: .destructive) {
                viewModel.reject(row)
            }
            .accessibilityIdentifier("replacements.row.\(row.id).reject")
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("replacements.row.\(row.id)")
    }

    @ViewBuilder
    private func candidateRow(_ row: ReplacementRow) -> some View {
        HStack {
            Text(row.from).fontWeight(.semibold)
            Image(systemName: "arrow.right").accessibilityHidden(true)
            Text(row.to)
            Spacer()
            Text(viewModel.candidateBadge(row))
                .foregroundStyle(row.state == .readyForReview ? .primary : .secondary)
            Button(viewModel.i18n.t("replacements.action_approve")) {
                viewModel.approve(row)
            }
            .accessibilityIdentifier("replacements.row.\(row.id).approve")
            Button(viewModel.i18n.t("replacements.action_reject"), role: .destructive) {
                viewModel.reject(row)
            }
            .accessibilityIdentifier("replacements.row.\(row.id).reject")
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("replacements.row.\(row.id)")
    }

    @ViewBuilder
    private func rejectedRow(_ row: ReplacementRow) -> some View {
        HStack {
            Text(row.from).fontWeight(.semibold)
            Image(systemName: "arrow.right").accessibilityHidden(true)
            Text(row.to)
            Spacer()
            Button(viewModel.i18n.t("replacements.action_restore")) {
                viewModel.restore(row)
            }
            .accessibilityIdentifier("replacements.row.\(row.id).restore")
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("replacements.row.\(row.id)")
    }

    @ViewBuilder
    private func emptySectionText(_ key: String) -> some View {
        Text(viewModel.i18n.t(key))
            .foregroundStyle(.secondary)
    }
}

@MainActor
private final class ReplacementsViewModel: ObservableObject {
    let i18n: I18n
    @Published private(set) var sections = ReplacementSections()
    @Published var isRejectedExpanded = false
    @Published var newFrom = ""
    @Published var newTo = ""
    @Published var errorMessage: String?
    private let coordinator: DictionaryCoordinator
    private var fromDrafts: [String: String] = [:]
    private var toDrafts: [String: String] = [:]

    init(coordinator: DictionaryCoordinator, i18n: I18n) {
        self.coordinator = coordinator
        self.i18n = i18n
        load(resetDrafts: true)
    }

    func load(resetDrafts: Bool = false) {
        sections = coordinator.replacementSections()
        if resetDrafts {
            fromDrafts.removeAll()
            toDrafts.removeAll()
        }
        for row in sections.active where row.source == "manual" {
            if fromDrafts[row.id] == nil { fromDrafts[row.id] = row.from }
            if toDrafts[row.id] == nil { toDrafts[row.id] = row.to }
        }
    }

    var isEmpty: Bool {
        sections.active.isEmpty && sections.candidates.isEmpty && sections.rejected.isEmpty
    }

    func sectionTitle(_ key: String, count: Int) -> String {
        i18n.t(key, ["n": "\(count)"])
    }

    func candidateBadge(_ row: ReplacementRow) -> String {
        let key = row.state == .readyForReview
            ? "replacements.badge_ready"
            : "replacements.badge_candidate"
        return i18n.t(key, ["c": "\(row.count)"])
    }

    func fromBinding(for row: ReplacementRow) -> Binding<String> {
        Binding(
            get: { self.fromDrafts[row.id] ?? row.from },
            set: { self.fromDrafts[row.id] = $0 }
        )
    }

    func toBinding(for row: ReplacementRow) -> Binding<String> {
        Binding(
            get: { self.toDrafts[row.id] ?? row.to },
            set: { self.toDrafts[row.id] = $0 }
        )
    }

    func addManualPair() {
        let manual = sections.active.filter { $0.source == "manual" }.map { ($0.from, $0.to) }
        perform { try coordinator.saveManualReplacements(manual + [(newFrom, newTo)]) }
        if errorMessage == nil { newFrom = ""; newTo = "" }
    }

    func delete(_ row: ReplacementRow) {
        perform { try coordinator.removeReplacement(row) }
    }

    func save(_ row: ReplacementRow) {
        let edited = (fromDrafts[row.id] ?? row.from, toDrafts[row.id] ?? row.to)
        let replacements = sections.active.filter { $0.source == "manual" }.map { current in
            current.id == row.id ? edited : (current.from, current.to)
        }
        perform { try coordinator.saveManualReplacements(replacements) }
    }

    func approve(_ row: ReplacementRow) {
        perform { try coordinator.approveReplacement(row) }
    }

    func reject(_ row: ReplacementRow) {
        perform { try coordinator.rejectReplacement(row) }
    }

    func restore(_ row: ReplacementRow) {
        perform { try coordinator.restoreReplacement(row) }
    }

    func approve(from: String, to: String) {
        guard let row = find(in: sections.candidates, from: from, to: to) else { return }
        approve(row)
    }

    func reject(from: String, to: String) {
        guard let row = find(in: sections.active + sections.candidates, from: from, to: to) else { return }
        reject(row)
    }

    func restore(from: String, to: String) {
        guard let row = find(in: sections.rejected, from: from, to: to) else { return }
        restore(row)
    }

    private func find(in rows: [ReplacementRow], from: String, to: String) -> ReplacementRow? {
        let fromKey = TermCanonicalizer.canonicalKey(from)
        let toKey = TermCanonicalizer.canonicalKey(to)
        return rows.first {
            TermCanonicalizer.canonicalKey($0.from) == fromKey
                && TermCanonicalizer.canonicalKey($0.to) == toKey
        }
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
