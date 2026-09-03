import AppKit
import Foundation
import Testing
@testable import CNSCore
@testable import CNSUI

@MainActor
private final class FakePermissionService: PermissionServicing {
    let setupDoneURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("setup-wizard-test")

    var setupDone = false
    var microphone: CNSCore.PermissionStatus = .granted
    var accessibility = true
    var microphoneRequestResult = true
    var markError: Error?
    private(set) var markCount = 0
    private(set) var openedMicrophoneSettings = 0
    private(set) var openedAccessibilitySettings = 0
    private(set) var accessibilityPromptRequests = 0

    func isSetupDone() -> Bool { setupDone }

    func markSetupDone() throws {
        if let markError { throw markError }
        setupDone = true
        markCount += 1
    }

    func resetSetup() throws {
        setupDone = false
    }

    func microphoneStatus() -> CNSCore.PermissionStatus { microphone }

    func requestMicrophoneAccess() async -> Bool {
        if microphoneRequestResult {
            microphone = .granted
        }
        return microphoneRequestResult
    }

    func openMicrophoneSettings() {
        openedMicrophoneSettings += 1
    }

    func accessibilityGranted() -> Bool { accessibility }

    func requestAccessibilityPrompt() -> Bool {
        accessibilityPromptRequests += 1
        return accessibility
    }

    func openAccessibilitySettings() {
        openedAccessibilitySettings += 1
    }

    func allPermissionsGranted() -> Bool {
        microphone == .granted && accessibility
    }
}

@MainActor
private final class FakeSetupAlertPresenter: SetupAlertPresenting {
    var queuedResponses: [SetupAlertResponse]
    private(set) var requests: [SetupAlertRequest] = []
    private var continuation: CheckedContinuation<SetupAlertResponse, Never>?

    init(responses: [SetupAlertResponse] = []) {
        self.queuedResponses = responses
    }

    func present(_ request: SetupAlertRequest) async -> SetupAlertResponse {
        requests.append(request)
        if !queuedResponses.isEmpty {
            return queuedResponses.removeFirst()
        }
        if request.buttons.count == 1, request.buttons[0] == "Skip" {
            return await withCheckedContinuation { continuation = $0 }
        }
        return .button(0)
    }

    func dismissActive(with response: SetupAlertResponse) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: response)
    }
}

@MainActor
@Suite("Setup wizard", .serialized)
struct SetupWizardTests {
    private func i18n() -> I18n {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("locales").path
            ) {
                return I18n.load("en", localesDirectory: directory.appendingPathComponent("locales"))
            }
            directory = directory.deletingLastPathComponent()
        }
        fatalError("Could not locate repository locales")
    }

    @Test("Already granted permissions complete without presenting UI")
    func alreadyGranted() async {
        let permissions = FakePermissionService()
        let presenter = FakeSetupAlertPresenter()
        let wizard = SetupWizard(permissions: permissions, i18n: i18n(), presenter: presenter)

        let result = await wizard.run()

        #expect(result == .completed)
        #expect(permissions.markCount == 1)
        #expect(presenter.requests.isEmpty)
    }

    @Test("AppKit panel renders every requested button title")
    func appKitPanelButtonTitles() {
        let panel = SetupAlertPanel(
            request: SetupAlertRequest(
                title: "Accessibility Access (Step 1 of 1)",
                body: "A long explanation that must wrap without hiding the actions.",
                buttons: ["Open Settings", "Skip"]
            )
        )

        #expect(panel.actionButtons.map(\.title) == ["Open Settings", "Skip"])
        #expect(panel.actionButtons.allSatisfy { !$0.title.isEmpty && !$0.isHidden })
        #expect(panel.titleLabel.stringValue == "Accessibility Access (Step 1 of 1)")
        #expect(panel.bodyLabel.maximumNumberOfLines == 0)
    }

    @Test("AppKit panel does not create private alert controls")
    func appKitPanelHasOnlyRequestedButtons() {
        let panel = SetupAlertPanel(
            request: SetupAlertRequest(
                title: "Setup Incomplete",
                body: "Still missing: Accessibility",
                buttons: ["OK"]
            )
        )

        let contentButtons = allButtons(in: panel.contentView)
        #expect(contentButtons.count == 1)
        #expect(contentButtons.first?.title == "OK")
    }

    @Test("Explicit skip is persisted")
    func explicitSkip() async {
        let permissions = FakePermissionService()
        permissions.accessibility = false
        let presenter = FakeSetupAlertPresenter(responses: [.button(1)])
        let wizard = SetupWizard(permissions: permissions, i18n: i18n(), presenter: presenter)

        let result = await wizard.run()

        #expect(result == .skipped)
        #expect(permissions.markCount == 1)
    }

    @Test("Accessibility polling completes without a modal run loop")
    func accessibilityTransition() async {
        let permissions = FakePermissionService()
        permissions.accessibility = false
        let presenter = FakeSetupAlertPresenter(responses: [.button(0), .button(0)])
        let wizard = SetupWizard(
            permissions: permissions,
            i18n: i18n(),
            presenter: presenter,
            accessibilityWaitTimeout: .seconds(1),
            permissionPollInterval: .milliseconds(5)
        )

        let grantTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            permissions.accessibility = true
        }
        let result = await wizard.run()
        _ = await grantTask.value

        #expect(result == .completed)
        #expect(permissions.accessibilityPromptRequests == 1)
        #expect(permissions.openedAccessibilitySettings == 1)
        #expect(permissions.markCount == 1)
    }

    @Test("Timeout remains incomplete and does not persist setup")
    func timeoutIsIncomplete() async {
        let permissions = FakePermissionService()
        permissions.accessibility = false
        let presenter = FakeSetupAlertPresenter(responses: [.button(0), .button(0)])
        let wizard = SetupWizard(
            permissions: permissions,
            i18n: i18n(),
            presenter: presenter,
            accessibilityWaitTimeout: .milliseconds(20),
            permissionPollInterval: .milliseconds(5)
        )

        let result = await wizard.run()

        #expect(result == .incomplete)
        #expect(permissions.markCount == 0)
        #expect(!permissions.setupDone)
    }

    private func allButtons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        var result = view is NSButton ? [view as! NSButton] : []
        for subview in view.subviews {
            result.append(contentsOf: allButtons(in: subview))
        }
        return result
    }
}
