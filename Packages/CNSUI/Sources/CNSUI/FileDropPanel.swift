import AppKit
import CNSCore
import CNSTranscription
import SwiftUI
import UniformTypeIdentifiers

public typealias FileTranscriptionAction = (
    URL,
    Bool,
    @escaping @Sendable (FileTranscriptionProgress) -> Void
) async -> FileTranscriptionResult

@MainActor
public final class FileTranscriptionViewModel: ObservableObject {
    public let i18n: I18n

    @Published public var transcriptionResult = ""
    @Published public var refine = false
    @Published public private(set) var isProcessing = false
    @Published public private(set) var isCancelling = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var successMessage: String?
    @Published public private(set) var progress = FileTranscriptionProgress(stage: .preparing)
    @Published public private(set) var refinementMessage: String?
    @Published public private(set) var refinementOutcome: FileRefinementOutcome = .notRequested
    @Published public private(set) var isEditorAvailable = false
    @Published public private(set) var editorUnavailableReason: String?
    public private(set) var jobID: UUID?

    private let onTranscribe: FileTranscriptionAction
    private let onCancel: () -> Void
    private var activeTask: Task<Void, Never>?

    public init(
        i18n: I18n,
        onTranscribe: @escaping FileTranscriptionAction,
        onCancel: @escaping () -> Void = {}
    ) {
        self.i18n = i18n
        self.onTranscribe = onTranscribe
        self.onCancel = onCancel
    }

    public func updateEditorAvailability(isActive: Bool, isPreparing: Bool) {
        if isPreparing {
            isEditorAvailable = false
            editorUnavailableReason = i18n.t("dialog.editor_preparing_reason")
        } else if !isActive {
            isEditorAvailable = false
            editorUnavailableReason = i18n.t("dialog.editor_disabled_reason")
        } else {
            isEditorAvailable = true
            editorUnavailableReason = nil
        }
        if !isEditorAvailable { refine = false }
    }

    @discardableResult
    public func start(_ url: URL) -> Bool {
        guard activeTask == nil, jobID == nil else {
            errorMessage = i18n.t("dialog.file_busy")
            return false
        }
        guard MediaFormatCapabilities.supports(url) else {
            errorMessage = i18n.t("dialog.file_unsupported")
            return false
        }

        let currentID = UUID()
        let shouldRefine = refine && isEditorAvailable
        jobID = currentID
        isProcessing = true
        isCancelling = false
        errorMessage = nil
        successMessage = nil
        refinementMessage = nil
        refinementOutcome = .notRequested
        transcriptionResult = ""
        progress = .init(stage: .preparing)

        activeTask = Task { [weak self] in
            guard let self else { return }
            let result = await onTranscribe(url, shouldRefine) { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.receiveProgress(update, jobID: currentID)
                }
            }
            receiveResult(result, jobID: currentID)
        }
        return true
    }

    public func cancel() {
        guard isProcessing, !isCancelling, activeTask != nil else { return }
        isCancelling = true
        errorMessage = nil
        activeTask?.cancel()
        onCancel()
    }

    func receiveProgress(_ update: FileTranscriptionProgress, jobID callbackID: UUID) {
        guard callbackID == jobID, isProcessing, !isCancelling else { return }
        // A provider may finish STT before optional refinement. The terminal
        // result, not an intermediate provider callback, completes the UI job.
        guard update.stage != .completed else { return }
        if progress.stage == .refining, update.stage != .refining { return }
        progress = update
    }

    func receiveResult(_ result: FileTranscriptionResult, jobID callbackID: UUID) {
        guard callbackID == jobID else { return }
        var result = result
        if isCancelling { result.status = .cancelled }
        if !result.text.isEmpty { transcriptionResult = result.text }

        switch result.status {
        case .success:
            progress = .init(stage: .completed, completedUnits: 1, totalUnits: 1)
        case .noSpeech:
            errorMessage = i18n.t("notify.file_no_speech_body")
        case .cancelled:
            errorMessage = i18n.t("dialog.file_cancelled")
        case let .failed(failure):
            errorMessage = UIErrorLocalization.transcription(failure, i18n: i18n)
        }
        
        refinementOutcome = result.refinement
        switch result.refinement {
        case .notRequested:
            refinementMessage = nil
        case .applied:
            refinementMessage = i18n.t("dialog.refinement_applied")
        case .unchanged:
            refinementMessage = i18n.t("dialog.refinement_unchanged")
        case .unavailable:
            refinementMessage = i18n.t("dialog.refinement_unavailable")
        case .skipped:
            refinementMessage = i18n.t("dialog.refinement_skipped")
        case .timedOut:
            refinementMessage = i18n.t("dialog.refinement_timeout")
        case .failed:
            refinementMessage = i18n.t("dialog.refinement_failed")
        case .notRun:
            if result.status == .success {
                refinementMessage = i18n.t("dialog.refinement_not_run")
            } else {
                refinementMessage = nil
            }
        }
        
        isProcessing = false
        isCancelling = false
        activeTask = nil
        jobID = nil
    }

    func recordSaveSuccess() {
        successMessage = i18n.t("dialog.file_save_success")
        errorMessage = nil
    }

    func recordSaveFailure() {
        successMessage = nil
        errorMessage = i18n.t("ui.error_persistence")
    }
}

@MainActor
public final class FileDropPanel: NSWindow, RefreshablePanel {
    private let viewModel: FileTranscriptionViewModel

    public init(
        i18n: I18n,
        onTranscribe: @escaping FileTranscriptionAction,
        onCancel: @escaping () -> Void = {}
    ) {
        let viewModel = FileTranscriptionViewModel(
            i18n: i18n,
            onTranscribe: onTranscribe,
            onCancel: onCancel
        )
        self.viewModel = viewModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = i18n.t("dialog.file_drop_title")
        minSize = NSSize(width: 440, height: 360)
        isReleasedWhenClosed = false
        contentViewController = NSHostingController(rootView: FileDropView(viewModel: viewModel))
        center()
    }

    public func refreshForPresentation() {}
    
    public func updateEditorAvailability(isActive: Bool, isPreparing: Bool) {
        viewModel.updateEditorAvailability(isActive: isActive, isPreparing: isPreparing)
    }

    var viewModelForTesting: FileTranscriptionViewModel { viewModel }
}

struct FileDropView: View {
    @ObservedObject var viewModel: FileTranscriptionViewModel

    @State private var isTargeted = false

    private var i18n: I18n { viewModel.i18n }

    var body: some View {
        VStack(spacing: 14) {
            if viewModel.isProcessing {
                processingView
            } else {
                dropTarget
            }

            Toggle(i18n.t("dialog.file_refine"), isOn: $viewModel.refine)
                .disabled(viewModel.isProcessing || !viewModel.isEditorAvailable)

            if let reason = viewModel.editorUnavailableReason {
                Label(reason, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("file-transcription.editor-unavailable")
            }

            if !viewModel.transcriptionResult.isEmpty {
                resultView
            }

            if let message = viewModel.refinementMessage {
                Label(
                    message,
                    systemImage: refinementNeedsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle"
                )
                .foregroundStyle(refinementNeedsAttention ? .orange : .secondary)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("file-transcription.refinement-status")
            }

            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(i18n.t("dialog.file_error_accessibility"))
            }
            if let successMessage = viewModel.successMessage {
                Label(successMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 360)
    }

    private var processingView: some View {
        VStack(spacing: 12) {
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
            Text(viewModel.isCancelling ? i18n.t("dialog.file_cancelling") : stageLabel)
                .font(.headline)
            if let total = viewModel.progress.totalUnits, total > 0 {
                Text("\(min(viewModel.progress.completedUnits, total)) / \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button(i18n.t("btn.cancel"), role: .cancel) { viewModel.cancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.isCancelling)
                .accessibilityIdentifier("file-transcription.cancel")
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private var refinementNeedsAttention: Bool {
        switch viewModel.refinementOutcome {
        case .unavailable, .skipped, .timedOut, .failed, .notRun: true
        case .notRequested, .applied, .unchanged: false
        }
    }

    private var dropTarget: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary,
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .background(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)

            VStack(spacing: 10) {
                if viewModel.transcriptionResult.isEmpty {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 40))
                        .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                    Text(i18n.t("dialog.file_drop_hint"))
                        .font(.headline)
                    Text(Self.formatDescription(i18n: i18n))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(i18n.t("dialog.file_drop_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button(i18n.t("dialog.file_browse")) { browse() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("file-transcription.browse")
            }
        }
        .frame(minHeight: viewModel.transcriptionResult.isEmpty ? 180 : 76)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in viewModel.start(url) }
            }
            return true
        }
    }

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(i18n.t("dialog.file_result"))
                .font(.headline)
            TextEditor(text: $viewModel.transcriptionResult)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            HStack {
                Spacer()
                Button(i18n.t("dialog.file_copy")) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(viewModel.transcriptionResult, forType: .string)
                }
                .accessibilityIdentifier("file-transcription.copy")
                Button(i18n.t("dialog.file_save")) { saveResult() }
                    .accessibilityIdentifier("file-transcription.save")
            }
        }
    }

    private var progressFraction: Double? {
        guard let total = viewModel.progress.totalUnits, total > 0 else { return nil }
        return min(1, Double(viewModel.progress.completedUnits) / Double(total))
    }

    private var stageLabel: String {
        i18n.t("dialog.file_stage_\(viewModel.progress.stage.rawValue)")
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = viewModel.start(url)
    }

    private func saveResult() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = i18n.t("dialog.file_default_name")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try viewModel.transcriptionResult.write(to: url, atomically: true, encoding: .utf8)
            viewModel.recordSaveSuccess()
        } catch {
            viewModel.recordSaveFailure()
        }
    }

    static let supportedExtensions = MediaFormatCapabilities.supportedExtensions

    static func isSupported(_ url: URL) -> Bool {
        MediaFormatCapabilities.supports(url)
    }

    static func formatDescription(i18n: I18n) -> String {
        i18n.t("dialog.file_drop_formats", [
            "formats": MediaFormatCapabilities.displayExtensions.joined(separator: " · ")
        ])
    }
}
