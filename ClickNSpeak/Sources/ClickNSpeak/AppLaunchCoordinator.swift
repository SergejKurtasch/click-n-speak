import AppKit
import CNSCore
import CNSUI

/// Owns the sequential first-run flow without blocking the AppKit run loop.
@MainActor
final class AppLaunchCoordinator {
    private let i18n: I18n
    private let permissions: any PermissionServicing
    private let log: @Sendable (String) -> Void

    private var wizard: SetupWizard?
    private var languagePicker: LanguagePicker?
    private var isRunning = false

    init(
        i18n: I18n,
        permissions: any PermissionServicing,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.i18n = i18n
        self.permissions = permissions
        self.log = log
    }

    func run(config: Config) async -> Config {
        guard !isRunning else {
            return config
        }
        isRunning = true
        defer { isRunning = false }

        if !permissions.isSetupDone() || !permissions.allPermissionsGranted() {
            _ = await runPermissionSetup(force: true)
        }

        guard !config.languagePickerDone else {
            return config
        }
        return await presentLanguagePicker(config: config)
    }

    @discardableResult
    func runPermissionSetup(force: Bool) async -> SetupWizardResult {
        if !force, permissions.isSetupDone(), permissions.allPermissionsGranted() {
            return .completed
        }
        let wizard = SetupWizard(
            permissions: permissions,
            i18n: i18n,
            log: log
        )
        self.wizard = wizard
        let result = await wizard.run()
        self.wizard = nil
        return result
    }

    private func presentLanguagePicker(config: Config) async -> Config {
        await withCheckedContinuation { continuation in
            let picker = LanguagePicker(
                config: config,
                i18n: i18n,
                onConfigChanged: { [weak self] updated in
                    self?.languagePicker = nil
                    continuation.resume(returning: updated)
                },
                onCancelled: { [weak self] in
                    self?.languagePicker = nil
                    continuation.resume(returning: config)
                }
            )
            languagePicker = picker
            picker.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
