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
public final class FileDropPanel: NSWindow, RefreshablePanel {
    private let i18n: I18n
    private let onTranscribe: FileTranscriptionAction
    private let onCancel: () -> Void

    public init(
        i18n: I18n,
        onTranscribe: @escaping FileTranscriptionAction,
        onCancel: @escaping () -> Void = {}
    ) {
        self.i18n = i18n
        self.onTranscribe = onTranscribe
        self.onCancel = onCancel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = i18n.t("dialog.file_drop_title")
        minSize = NSSize(width: 440, height: 360)
        isReleasedWhenClosed = false
        refreshForPresentation()
        center()
    }

    public func refreshForPresentation() {
        contentViewController = NSHostingController(rootView: FileDropView(
            i18n: i18n,
            onTranscribe: onTranscribe,
            onCancel: onCancel
        ))
    }

}

struct FileDropView: View {
    let i18n: I18n
    let onTranscribe: FileTranscriptionAction
    let onCancel: () -> Void

    @State private var isTargeted = false
    @State private var transcriptionResult = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var progress = FileTranscriptionProgress(stage: .preparing)
    @State private var activeTask: Task<Void, Never>?
    @State private var refine = false

    var body: some View {
        VStack(spacing: 14) {
            if isProcessing {
                processingView
            } else {
                dropTarget
            }

            Toggle(i18n.t("dialog.file_refine"), isOn: $refine)
                .disabled(isProcessing)

            if !transcriptionResult.isEmpty {
                resultView
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(i18n.t("dialog.file_error_accessibility"))
            }
            if let successMessage {
                Label(successMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 360)
        .onDisappear { cancel() }
    }

    private var processingView: some View {
        VStack(spacing: 12) {
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
            Text(stageLabel)
                .font(.headline)
            if let total = progress.totalUnits, total > 0 {
                Text("\(min(progress.completedUnits, total)) / \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button(i18n.t("btn.cancel"), role: .cancel) { cancel() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("file-transcription.cancel")
        }
        .frame(maxWidth: .infinity, minHeight: 150)
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
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 40))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                Text(i18n.t("dialog.file_drop_hint"))
                    .font(.headline)
                Text(i18n.t("dialog.file_drop_formats"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(i18n.t("dialog.file_browse")) { browse() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("file-transcription.browse")
            }
        }
        .frame(minHeight: 180)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in start(url) }
            }
            return true
        }
    }

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(i18n.t("dialog.file_result"))
                .font(.headline)
            TextEditor(text: $transcriptionResult)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            HStack {
                Spacer()
                Button(i18n.t("dialog.file_copy")) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(transcriptionResult, forType: .string)
                }
                .accessibilityIdentifier("file-transcription.copy")
                Button(i18n.t("dialog.file_save")) { saveResult() }
                    .accessibilityIdentifier("file-transcription.save")
            }
        }
    }

    private var progressFraction: Double? {
        guard let total = progress.totalUnits, total > 0 else { return nil }
        return min(1, Double(progress.completedUnits) / Double(total))
    }

    private var stageLabel: String {
        i18n.t("dialog.file_stage_\(progress.stage.rawValue)")
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
        start(url)
    }

    private func start(_ url: URL) {
        guard Self.isSupported(url) else {
            errorMessage = i18n.t("dialog.file_unsupported")
            return
        }
        activeTask?.cancel()
        isProcessing = true
        errorMessage = nil
        successMessage = nil
        transcriptionResult = ""
        progress = .init(stage: .preparing)
        activeTask = Task {
            let result = await onTranscribe(url, refine) { update in
                Task { @MainActor in progress = update }
            }
            guard !Task.isCancelled else {
                isProcessing = false
                return
            }
            switch result.status {
            case .success:
                transcriptionResult = result.text
            case .noSpeech:
                errorMessage = i18n.t("notify.file_no_speech_body")
            case .cancelled:
                errorMessage = i18n.t("dialog.file_cancelled")
            case let .failed(failure):
                errorMessage = UIErrorLocalization.transcription(failure, i18n: i18n)
            }
            isProcessing = false
            activeTask = nil
        }
    }

    private func cancel() {
        guard isProcessing else { return }
        activeTask?.cancel()
        activeTask = nil
        onCancel()
        isProcessing = false
        errorMessage = i18n.t("dialog.file_cancelled")
    }

    private func saveResult() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = i18n.t("dialog.file_default_name")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try transcriptionResult.write(to: url, atomically: true, encoding: .utf8)
            successMessage = i18n.t("dialog.file_save_success")
            errorMessage = nil
        } catch {
            successMessage = nil
            errorMessage = i18n.t("ui.error_persistence")
        }
    }

    static let supportedExtensions = [
        "wav", "wave", "mp3", "m4a", "aac", "flac", "ogg", "opus", "caf",
        "aif", "aiff", "mp4", "mov", "m4v"
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
