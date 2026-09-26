import AppKit
import CNSCore
import Foundation

public enum SetupWizardResult: Sendable, Equatable {
    case completed
    case skipped
    case incomplete
}

public enum SetupWizardState: Sendable, Equatable {
    case idle
    case welcome
    case microphoneExplanation
    case requestingMicrophone
    case microphoneDenied
    case accessibilityExplanation
    case waitingForAccessibility
    case complete
    case skipped
    case failed
}

public struct SetupAlertRequest {
    public let title: String
    public let body: String
    public let buttons: [String]
    public let style: NSAlert.Style

    public init(
        title: String,
        body: String,
        buttons: [String],
        style: NSAlert.Style = .informational
    ) {
        self.title = title
        self.body = body
        self.buttons = buttons
        self.style = style
    }
}

public enum SetupAlertResponse: Sendable, Equatable {
    case button(Int)
    case permissionGranted
    case timedOut
    case closed
}

@MainActor
public protocol SetupAlertPresenting: AnyObject {
    func present(_ request: SetupAlertRequest) async -> SetupAlertResponse
    func dismissActive(with response: SetupAlertResponse)
}

/// Presents setup windows without entering a nested modal run loop.
@MainActor
public final class AppKitSetupAlertPresenter: SetupAlertPresenting {
    private var activeSession: SetupAlertSession?

    public init() {}

    public func present(_ request: SetupAlertRequest) async -> SetupAlertResponse {
        activeSession?.finish(with: .closed)
        return await withCheckedContinuation { continuation in
            let session = SetupAlertSession(
                request: request,
                continuation: continuation,
                onFinish: { [weak self] finished in
                    if self?.activeSession === finished {
                        self?.activeSession = nil
                    }
                }
            )
            activeSession = session
            session.show()
        }
    }

    public func dismissActive(with response: SetupAlertResponse) {
        activeSession?.finish(with: response)
    }
}

@MainActor
private final class SetupAlertSession: NSObject, NSWindowDelegate {
    private let panel: SetupAlertPanel
    private var continuation: CheckedContinuation<SetupAlertResponse, Never>?
    private let onFinish: (SetupAlertSession) -> Void

    init(
        request: SetupAlertRequest,
        continuation: CheckedContinuation<SetupAlertResponse, Never>,
        onFinish: @escaping (SetupAlertSession) -> Void
    ) {
        self.continuation = continuation
        self.onFinish = onFinish
        self.panel = SetupAlertPanel(request: request)
        super.init()

        panel.onButton = { [weak self] index in
            self?.finish(with: .button(index))
        }
        panel.delegate = self
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func finish(with response: SetupAlertResponse) {
        guard let continuation else {
            return
        }
        self.continuation = nil
        panel.delegate = nil
        panel.orderOut(nil)
        onFinish(self)
        continuation.resume(returning: response)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(with: .closed)
        return false
    }
}

/// A purpose-built setup panel. `NSAlert` must be presented through its modal
/// APIs; showing `NSAlert.window` directly leaves its private controls and
/// layout in an undefined state on recent macOS releases.
@MainActor
final class SetupAlertPanel: NSPanel {
    private static let contentWidth: CGFloat = 520
    private static let horizontalPadding: CGFloat = 24
    private static let verticalPadding: CGFloat = 24
    private static let iconSize: CGFloat = 64
    private static let contentSpacing: CGFloat = 20
    private static let textSpacing: CGFloat = 8
    private static let buttonHeight: CGFloat = 34

    var onButton: ((Int) -> Void)?
    private(set) var actionButtons: [NSButton] = []
    private(set) var titleLabel = NSTextField(labelWithString: "")
    private(set) var bodyLabel = NSTextField(wrappingLabelWithString: "")

    init(request: SetupAlertRequest) {
        let textWidth = Self.contentWidth
            - (2 * Self.horizontalPadding)
            - Self.iconSize
            - Self.contentSpacing
        let titleFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 14)
        let titleHeight = Self.textHeight(request.title, font: titleFont, width: textWidth)
        let bodyHeight = Self.textHeight(request.body, font: bodyFont, width: textWidth)
        let textStackHeight = titleHeight + Self.textSpacing + bodyHeight
        let headerHeight = max(Self.iconSize, textStackHeight)
        let contentHeight = Self.verticalPadding
            + headerHeight
            + Self.contentSpacing
            + Self.buttonHeight
            + Self.verticalPadding

        super.init(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.contentWidth,
                height: ceil(contentHeight)
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Click-n-speak"
        level = .floating
        isFloatingPanel = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        animationBehavior = .alertPanel
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let root = NSView(frame: NSRect(origin: .zero, size: contentLayoutRect.size))
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView = root

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSApp.applicationIconImage
            ?? NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Click-n-speak")
        iconView.setAccessibilityLabel("Click-n-speak")

        titleLabel = NSTextField(wrappingLabelWithString: request.title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = titleFont
        titleLabel.maximumNumberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.preferredMaxLayoutWidth = textWidth
        titleLabel.identifier = NSUserInterfaceItemIdentifier("setup-title")

        bodyLabel = NSTextField(wrappingLabelWithString: request.body)
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = bodyFont
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.preferredMaxLayoutWidth = textWidth
        bodyLabel.identifier = NSUserInterfaceItemIdentifier("setup-body")

        let textStack = NSStackView(views: [titleLabel, bodyLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Self.textSpacing
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let headerStack = NSStackView(views: [iconView, textStack])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.alignment = .top
        headerStack.spacing = Self.contentSpacing

        actionButtons = request.buttons.enumerated().map { index, buttonTitle in
            let button = NSButton(title: buttonTitle, target: self, action: #selector(buttonPressed(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.tag = index
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.identifier = NSUserInterfaceItemIdentifier("setup-button-\(index)")
            button.setAccessibilityLabel(buttonTitle)
            if index == 0 {
                button.keyEquivalent = "\r"
            } else if index == 1 {
                button.keyEquivalent = "\u{1b}"
            }
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: Self.buttonHeight),
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            ])
            return button
        }

        let buttonSpacer = NSView()
        buttonSpacer.translatesAutoresizingMaskIntoConstraints = false
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 12
        buttonRow.addArrangedSubview(buttonSpacer)
        for button in actionButtons.reversed() {
            buttonRow.addArrangedSubview(button)
        }

        root.addSubview(headerStack)
        root.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            root.heightAnchor.constraint(equalToConstant: ceil(contentHeight)),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            headerStack.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.verticalPadding),
            headerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.horizontalPadding),
            headerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.horizontalPadding),
            textStack.widthAnchor.constraint(equalToConstant: textWidth),
            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.horizontalPadding),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.horizontalPadding),
            buttonRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.verticalPadding),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        onButton?(sender.tag)
    }

    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(ceil(bounds.height), ceil(font.ascender - font.descender + font.leading))
    }
}

public enum SetupInvocation: Sendable {
    case automatic, manual
}

@MainActor
public final class SetupWizard {
    public static private(set) var isActive = false

    public private(set) var state: SetupWizardState = .idle

    private let permissions: any PermissionServicing
    private let i18n: I18n
    private let presenter: any SetupAlertPresenting
    private let accessibilityWaitTimeout: Duration
    private let permissionPollInterval: Duration
    private let log: @Sendable (String) -> Void

    public init(
        permissions: any PermissionServicing,
        i18n: I18n,
        presenter: any SetupAlertPresenting = AppKitSetupAlertPresenter(),
        accessibilityWaitTimeout: Duration = .seconds(120),
        permissionPollInterval: Duration = .milliseconds(500),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.permissions = permissions
        self.i18n = i18n
        self.presenter = presenter
        self.accessibilityWaitTimeout = accessibilityWaitTimeout
        self.permissionPollInterval = permissionPollInterval
        self.log = log
    }

    public func run(invocation: SetupInvocation = .automatic) async -> SetupWizardResult {
        if invocation == .manual && permissions.allPermissionsGranted() {
            _ = await presenter.present(
                SetupAlertRequest(
                    title: i18n.t("wizard.permissions_already_granted_title"),
                    body: i18n.t("wizard.permissions_already_granted_body"),
                    buttons: [i18n.t("btn.close")]
                )
            )
            return .completed
        }
        guard !Self.isActive else {
            log("Permission setup is already active.")
            return .incomplete
        }

        Self.isActive = true
        defer {
            Self.isActive = false
            if state != .complete && state != .skipped && state != .failed {
                state = .idle
            }
        }

        if permissions.allPermissionsGranted() {
            return markSetupDone(result: .completed)
        }

        state = .welcome
        let missingItems = permissionItemLabels()
        let welcome = await presenter.present(
            SetupAlertRequest(
                title: i18n.t("wizard.welcome_title"),
                body: i18n.t(
                    "wizard.welcome_body",
                    [
                        "total_steps": String(missingItems.count),
                        "perm_word": i18n.plural("wizard.perm_word", missingItems.count),
                        "perm_list": missingItems.map { "  • \($0)" }.joined(separator: "\n")
                    ]
                ),
                buttons: [i18n.t("btn.lets_go"), i18n.t("btn.skip")]
            )
        )
        guard welcome == .button(0) else {
            return markSetupDone(result: .skipped)
        }

        if permissions.microphoneStatus() != .granted {
            let microphoneResult = await runMicrophoneStep()
            guard microphoneResult == .completed else {
                return microphoneResult
            }
        }

        if !permissions.accessibilityGranted() {
            let accessibilityResult = await runAccessibilityStep()
            guard accessibilityResult == .completed else {
                return accessibilityResult
            }
        }

        guard permissions.allPermissionsGranted() else {
            return await showIncompleteResult()
        }

        state = .complete
        _ = await presenter.present(
            SetupAlertRequest(
                title: i18n.t("wizard.all_set_title"),
                body: i18n.t("wizard.all_set_body"),
                buttons: [i18n.t("btn.continue")]
            )
        )
        return markSetupDone(result: .completed)
    }

    private func runMicrophoneStep() async -> SetupWizardResult {
        let stepLabel = currentStepLabel(forAccessibility: false)
        switch permissions.microphoneStatus() {
        case .restricted:
            return await showIncompleteResult()
        case .denied:
            state = .microphoneDenied
            let response = await presenter.present(
                SetupAlertRequest(
                    title: i18n.t("wizard.perm_mic_title", ["label": stepLabel]),
                    body: i18n.t("wizard.perm_mic_denied_body"),
                    buttons: [i18n.t("btn.open_settings"), i18n.t("btn.skip")]
                )
            )
            guard response == .button(0) else {
                return markSetupDone(result: .skipped)
            }
            permissions.openMicrophoneSettings()
            return await waitForPermission(
                title: i18n.t("wizard.perm_mic_title", ["label": stepLabel]),
                body: i18n.t("wizard.perm_mic_denied_body"),
                check: { [permissions] in permissions.microphoneStatus() == .granted }
            )
        case .undetermined:
            state = .microphoneExplanation
            let response = await presenter.present(
                SetupAlertRequest(
                    title: i18n.t("wizard.perm_mic_title", ["label": stepLabel]),
                    body: i18n.t("wizard.perm_mic_first_body"),
                    buttons: [i18n.t("btn.request_access"), i18n.t("btn.skip")]
                )
            )
            guard response == .button(0) else {
                return markSetupDone(result: .skipped)
            }
            state = .requestingMicrophone
            if await permissions.requestMicrophoneAccess() {
                return .completed
            }
            state = .microphoneDenied
            let denied = await presenter.present(
                SetupAlertRequest(
                    title: i18n.t("wizard.perm_mic_not_granted_title"),
                    body: i18n.t("wizard.perm_mic_not_granted_body"),
                    buttons: [i18n.t("btn.open_settings"), i18n.t("btn.skip")],
                    style: .warning
                )
            )
            guard denied == .button(0) else {
                return markSetupDone(result: .skipped)
            }
            permissions.openMicrophoneSettings()
            return await waitForPermission(
                title: i18n.t("wizard.perm_mic_title", ["label": stepLabel]),
                body: i18n.t("wizard.perm_mic_denied_body"),
                check: { [permissions] in permissions.microphoneStatus() == .granted }
            )
        case .granted:
            return .completed
        }
    }

    private func runAccessibilityStep() async -> SetupWizardResult {
        state = .accessibilityExplanation
        let response = await presenter.present(
            SetupAlertRequest(
                title: i18n.t(
                    "wizard.perm_access_title",
                    ["label": currentStepLabel(forAccessibility: true)]
                ),
                body: i18n.t("wizard.perm_access_body"),
                buttons: [i18n.t("btn.open_settings"), i18n.t("btn.skip")]
            )
        )
        guard response == .button(0) else {
            return markSetupDone(result: .skipped)
        }

        permissions.openAccessibilitySettings()
        state = .waitingForAccessibility
        return await waitForPermission(
            title: i18n.t("wizard.perm_access_waiting_title"),
            body: i18n.t("wizard.perm_access_body"),
            check: { [permissions] in permissions.accessibilityGranted() }
        )
    }

    private func waitForPermission(
        title: String,
        body: String,
        check: @escaping @MainActor () -> Bool
    ) async -> SetupWizardResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: accessibilityWaitTimeout)
        let monitor = Task { @MainActor [weak presenter] in
            while !Task.isCancelled {
                if check() {
                    presenter?.dismissActive(with: .permissionGranted)
                    return
                }
                if clock.now >= deadline {
                    presenter?.dismissActive(with: .timedOut)
                    return
                }
                try? await Task.sleep(for: permissionPollInterval)
            }
        }

        let response = await presenter.present(
            SetupAlertRequest(
                title: title,
                body: body,
                buttons: [i18n.t("btn.skip")]
            )
        )
        monitor.cancel()

        switch response {
        case .permissionGranted:
            return .completed
        case .button(0):
            return markSetupDone(result: .skipped)
        case .timedOut, .closed, .button:
            return await showIncompleteResult()
        }
    }

    private func showIncompleteResult() async -> SetupWizardResult {
        state = .failed
        var missing: [String] = []
        if permissions.microphoneStatus() != .granted {
            missing.append(i18n.t("wizard.missing_mic"))
        }
        if !permissions.accessibilityGranted() {
            missing.append(i18n.t("wizard.missing_access"))
        }
        _ = await presenter.present(
            SetupAlertRequest(
                title: i18n.t("wizard.incomplete_title"),
                body: i18n.t("wizard.incomplete_body", ["missing": missing.joined(separator: ", ")]),
                buttons: [i18n.t("btn.ok")],
                style: .warning
            )
        )
        return .incomplete
    }

    private func markSetupDone(result: SetupWizardResult) -> SetupWizardResult {
        do {
            try permissions.markSetupDone()
            state = result == .completed ? .complete : .skipped
            return result
        } catch {
            state = .failed
            log("Failed to persist permission setup state: \(error.localizedDescription)")
            return .incomplete
        }
    }

    private func permissionItemLabels() -> [String] {
        var labels: [String] = []
        if permissions.microphoneStatus() != .granted {
            labels.append(i18n.t("wizard.perm_item_mic"))
        }
        if !permissions.accessibilityGranted() {
            labels.append(i18n.t("wizard.perm_item_access"))
        }
        return labels
    }

    private func currentStepLabel(forAccessibility: Bool) -> String {
        let microphoneNeeded = permissions.microphoneStatus() != .granted
        let accessibilityNeeded = !permissions.accessibilityGranted()
        let total = (microphoneNeeded ? 1 : 0) + (accessibilityNeeded ? 1 : 0)
        let step = forAccessibility && microphoneNeeded ? 2 : 1
        return i18n.t(
            "wizard.step_label",
            ["step": String(step), "total": String(max(1, total))]
        )
    }
}
