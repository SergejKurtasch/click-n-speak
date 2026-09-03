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

    public func refresh() { viewModel.load(resetDrafts: true) }
    public func refreshForPresentation() { refresh() }
    var replacementCountForTesting: Int { viewModel.rows.count }

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
            if viewModel.rows.isEmpty {
                Text(viewModel.i18n.t("replacements.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.rows) { row in
                    HStack {
                        if row.source == "manual" {
                            TextField(
                                viewModel.i18n.t("replacements.placeholder_from"),
                                text: viewModel.fromBinding(for: row)
                            )
                        } else {
                            Text(row.from).fontWeight(.semibold)
                        }
                        Image(systemName: "arrow.right")
                            .accessibilityHidden(true)
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
                        }
                        Button(viewModel.i18n.t("btn.delete"), role: .destructive) {
                            viewModel.delete(row)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("replacements.row.\(row.id)")
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
}

@MainActor
private final class ReplacementsViewModel: ObservableObject {
    let i18n: I18n
    @Published private(set) var rows: [ReplacementRow] = []
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
        rows = coordinator.replacementRows()
        if resetDrafts {
            fromDrafts.removeAll()
            toDrafts.removeAll()
        }
        for row in rows where row.source == "manual" {
            if fromDrafts[row.id] == nil { fromDrafts[row.id] = row.from }
            if toDrafts[row.id] == nil { toDrafts[row.id] = row.to }
        }
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
        let manual = rows.filter { $0.source == "manual" }.map { ($0.from, $0.to) }
        perform { try coordinator.saveManualReplacements(manual + [(newFrom, newTo)]) }
        if errorMessage == nil { newFrom = ""; newTo = "" }
    }

    func delete(_ row: ReplacementRow) {
        if row.source == "manual" {
            let remaining = rows.filter { $0.source == "manual" && $0.id != row.id }.map { ($0.from, $0.to) }
            perform { try coordinator.saveManualReplacements(remaining) }
        } else {
            perform { try coordinator.removeAutomaticReplacement(row) }
        }
    }

    func save(_ row: ReplacementRow) {
        let edited = (fromDrafts[row.id] ?? row.from, toDrafts[row.id] ?? row.to)
        let replacements = rows.filter { $0.source == "manual" }.map { current in
            current.id == row.id ? edited : (current.from, current.to)
        }
        perform { try coordinator.saveManualReplacements(replacements) }
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
