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
public final class ModelDownloadPanel: NSObject, NSWindowDelegate {

    // MARK: - UI

    private var panel: NSPanel?
    private var titleLabel: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var cancelButton: NSButton?

    private var onCancel: (() -> Void)?
    private var onRetry: (() -> Void)?
    private let i18n: I18n
    private let log: (String) -> Void
    private var generation = 0
    private var terminalState = false
    private var validationInProgress = false

    // MARK: - Init

    public init(i18n: I18n, log: @escaping (String) -> Void = { _ in }) {
        self.i18n = i18n
        self.log = log
        super.init()
    }

    // MARK: - Public API

    /// Show the panel and begin tracking a download.
    @discardableResult
    public func show(
        modelName: String,
        onCancel: @escaping () -> Void,
        onRetry: (() -> Void)? = nil
    ) -> Int {
        generation += 1
        let currentGeneration = generation
        self.onCancel = onCancel
        self.onRetry = onRetry
        terminalState = false
        validationInProgress = false
        buildPanelIfNeeded()

        titleLabel?.stringValue = i18n.t("download.progress_title", ["label": modelName])
        statusLabel?.stringValue = i18n.t("download.starting")
        progressBar?.doubleValue = 0
        progressBar?.isIndeterminate = true
        progressBar?.startAnimation(nil)
        cancelButton?.title = i18n.t("btn.cancel")
        cancelButton?.isEnabled = true
        panel?.standardWindowButton(.closeButton)?.isEnabled = true

        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return currentGeneration
    }

    /// Update progress.  Called from `ModelDownloader.onProgress`.
    public func update(
        downloadedBytes: Int64,
        totalBytes: Int64?,
        bytesPerSecond: Double,
        estimatedTimeRemaining: TimeInterval?,
        generation expectedGeneration: Int? = nil
    ) {
        guard expectedGeneration == nil || expectedGeneration == generation else { return }
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
            parts.append(localizedETA(eta))
        }

        statusLabel?.stringValue = parts.joined(separator: "  —  ")
    }

    /// Model integrity validation cannot be interrupted safely, so the panel
    /// makes that transition explicit and disables cancellation until it ends.
    public func showValidating(generation expectedGeneration: Int? = nil) {
        guard expectedGeneration == nil || expectedGeneration == generation else { return }
        validationInProgress = true
        statusLabel?.stringValue = i18n.t("menu.model_validating")
        progressBar?.isIndeterminate = true
        progressBar?.startAnimation(nil)
        cancelButton?.isEnabled = false
        panel?.standardWindowButton(.closeButton)?.isEnabled = false
    }

    /// Flash a "Done" message and auto-close after a short delay.
    public func showCompleted(generation expectedGeneration: Int? = nil) {
        guard expectedGeneration == nil || expectedGeneration == generation else { return }
        let currentGeneration = generation
        terminalState = true
        validationInProgress = false
        onRetry = nil
        statusLabel?.stringValue = "✓ \(i18n.t("download.complete"))"
        progressBar?.doubleValue = progressBar?.maxValue ?? 100
        cancelButton?.title = i18n.t("btn.close")
        cancelButton?.isEnabled = true
        panel?.standardWindowButton(.closeButton)?.isEnabled = true

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard generation == currentGeneration else { return }
            close()
        }
    }

    /// Show an error and let the user dismiss.
    public func showError(_ message: String, generation expectedGeneration: Int? = nil) {
        guard expectedGeneration == nil || expectedGeneration == generation else { return }
        terminalState = true
        validationInProgress = false
        statusLabel?.stringValue = "✗ \(i18n.t("download.failed", ["message": message]))"
        cancelButton?.title = i18n.t(onRetry == nil ? "btn.close" : "btn.retry")
        cancelButton?.isEnabled = true
        panel?.standardWindowButton(.closeButton)?.isEnabled = true
    }

    /// Show cancelled state and auto-close.
    public func showCancelled(generation expectedGeneration: Int? = nil) {
        guard expectedGeneration == nil || expectedGeneration == generation else { return }
        let currentGeneration = generation
        terminalState = true
        validationInProgress = false
        onRetry = nil
        statusLabel?.stringValue = i18n.t("download.cancelled")
        cancelButton?.isEnabled = false

        Task {
            try? await Task.sleep(for: .seconds(1.0))
            guard generation == currentGeneration else { return }
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
        onRetry = nil
        terminalState = false
        validationInProgress = false
    }

    /// Whether the panel is currently visible.
    public var isVisible: Bool {
        panel?.isVisible ?? false
    }
    /// Restore an existing download window after the user returns through the
    /// menu-bar item. The active download and its generation are unchanged.
    @discardableResult
    public func bringToFront() -> Bool {
        guard let panel else { return false }
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
    var statusForTesting: String? { statusLabel?.stringValue }
    var generationForTesting: Int { generation }
    var hidesOnDeactivateForTesting: Bool? { panel?.hidesOnDeactivate }
    var cancelEnabledForTesting: Bool? { cancelButton?.isEnabled }
    var closeEnabledForTesting: Bool? { panel?.standardWindowButton(.closeButton)?.isEnabled }

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
        p.title = i18n.t("download.window_title")
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.level = .floating
        // A long model download must remain observable when the user switches
        // to another application. It can always be raised again from the tray.
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Prevent the panel from being minimized.
        p.styleMask.remove(.miniaturizable)
        p.delegate = self
        p.setAccessibilityLabel(i18n.t("download.window_title"))

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
        let status = NSTextField(labelWithString: i18n.t("download.starting"))
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(status)
        statusLabel = status
        status.setAccessibilityIdentifier("download.status")

        // Cancel button
        let cancel = NSButton(title: i18n.t("btn.cancel"), target: self, action: #selector(cancelClicked))
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.bezelStyle = .rounded
        contentView.addSubview(cancel)
        cancelButton = cancel
        cancel.setAccessibilityIdentifier("download.cancel")

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
        if terminalState {
            let retry = onRetry
            close()
            retry?()
        } else {
            log("ModelDownloadPanel: cancel clicked")
            onCancel?()
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !validationInProgress else { return false }
        if !terminalState { onCancel?() }
        close()
        return false
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

    private func localizedETA(_ seconds: TimeInterval) -> String {
        let value = max(1, Int(seconds))
        if value < 60 {
            return i18n.t("download.eta_seconds", ["s": String(value)])
        }
        let minutes = value / 60
        if minutes < 60 {
            return i18n.t("download.eta_minutes", ["m": String(minutes)])
        }
        return i18n.t("download.eta_hours", ["h": String(minutes / 60)])
    }
}
