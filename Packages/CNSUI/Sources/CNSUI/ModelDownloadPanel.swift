import AppKit
import CNSCore

/// Floating panel that shows model download progress with speed, ETA, and a
/// Cancel button. Mirrors `model_download_panel.py` (Python NSPanel with
/// NSProgressIndicator, speed/ETA readout, and Cancel).
///
/// The panel auto-dismisses on completion (with a brief "Done" flash) or when
/// cancelled. All state is driven by external `update(…)` calls from
/// `ModelDownloader`'s callbacks.
@MainActor
public final class ModelDownloadPanel {

    // MARK: - UI

    private var panel: NSPanel?
    private var titleLabel: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var cancelButton: NSButton?

    private var onCancel: (() -> Void)?
    private let log: (String) -> Void

    // MARK: - Init

    public init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    // MARK: - Public API

    /// Show the panel and begin tracking a download.
    public func show(modelName: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        buildPanelIfNeeded()

        titleLabel?.stringValue = "Downloading \(modelName)…"
        statusLabel?.stringValue = "Starting…"
        progressBar?.doubleValue = 0
        progressBar?.isIndeterminate = true
        progressBar?.startAnimation(nil)

        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Update progress.  Called from `ModelDownloader.onProgress`.
    public func update(
        downloadedBytes: Int64,
        totalBytes: Int64?,
        bytesPerSecond: Double,
        estimatedTimeRemaining: TimeInterval?
    ) {
        guard let progressBar else { return }

        if let total = totalBytes, total > 0 {
            progressBar.isIndeterminate = false
            progressBar.maxValue = Double(total)
            progressBar.doubleValue = Double(downloadedBytes)
        }

        // Build status text: "123.4 MB / 795.0 MB  —  12.3 MB/s  —  ~45s"
        var parts: [String] = []
        let downloaded = ModelManager.formattedSize(downloadedBytes)
        if let total = totalBytes {
            parts.append("\(downloaded) / \(ModelManager.formattedSize(total))")
        } else {
            parts.append(downloaded)
        }

        if bytesPerSecond > 0 {
            parts.append("\(ModelManager.formattedSize(Int64(bytesPerSecond)))/s")
        }

        if let eta = estimatedTimeRemaining, eta > 0 {
            parts.append("~\(Self.formatETA(eta))")
        }

        statusLabel?.stringValue = parts.joined(separator: "  —  ")
    }

    /// Flash a "Done" message and auto-close after a short delay.
    public func showCompleted() {
        statusLabel?.stringValue = "✓ Download complete"
        progressBar?.doubleValue = progressBar?.maxValue ?? 100
        cancelButton?.isEnabled = false

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            close()
        }
    }

    /// Show an error and let the user dismiss.
    public func showError(_ message: String) {
        statusLabel?.stringValue = "✗ \(message)"
        cancelButton?.title = "Close"
    }

    /// Show cancelled state and auto-close.
    public func showCancelled() {
        statusLabel?.stringValue = "Download cancelled"
        cancelButton?.isEnabled = false

        Task {
            try? await Task.sleep(for: .seconds(1.0))
            close()
        }
    }

    /// Close and dispose the panel.
    public func close() {
        panel?.orderOut(nil)
        panel = nil
        titleLabel = nil
        progressBar = nil
        statusLabel = nil
        cancelButton = nil
        onCancel = nil
    }

    /// Whether the panel is currently visible.
    public var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Panel construction

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }

        let panelWidth: CGFloat = 400
        let panelHeight: CGFloat = 140
        let padding: CGFloat = 20

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        p.title = "Model Download"
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.level = .floating
        // Prevent the panel from being minimized.
        p.styleMask.remove(.miniaturizable)

        let contentView = p.contentView!

        // Title label
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(title)
        titleLabel = title

        // Progress bar
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 100
        bar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bar)
        progressBar = bar

        // Status label (speed/ETA)
        let status = NSTextField(labelWithString: "Starting…")
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(status)
        statusLabel = status

        // Cancel button
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.bezelStyle = .rounded
        contentView.addSubview(cancel)
        cancelButton = cancel

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: padding),
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),

            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),

            status.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            status.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -12),

            cancel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            cancel.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
        ])

        panel = p
    }

    @objc private func cancelClicked() {
        log("ModelDownloadPanel: cancel clicked")
        onCancel?()
    }

    // MARK: - Helpers

    /// Format seconds into a compact human-readable ETA (e.g. "45s", "2m 10s").
    static func formatETA(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 {
            return "\(s)s"
        }
        let m = s / 60
        let remainder = s % 60
        if m < 60 {
            return remainder > 0 ? "\(m)m \(remainder)s" : "\(m)m"
        }
        let h = m / 60
        let remainderMin = m % 60
        return "\(h)h \(remainderMin)m"
    }
}
