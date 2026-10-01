import AppKit
import CNSCore
import CNSUI

/// The recovery path owns no profile services. Loading and migration finish in
/// memory before an explicit restore preserves the original and replaces it.
@MainActor
final class ConfigRecoveryCoordinator {
    private let configURL: URL

    init(configURL: URL) {
        self.configURL = configURL
    }

    func reload() throws -> Config {
        try Config.loadValidated(from: configURL)
    }

    func restore(from backupURL: URL) throws -> Config {
        // Read the selected file directly: a missing backup must never be
        // interpreted as a request to create a default profile.
        let candidate = try Config(validating: Data(contentsOf: backupURL))
        let original = try Data(contentsOf: configURL)
        let preservedURL = configURL.deletingLastPathComponent().appendingPathComponent(
            "\(configURL.lastPathComponent).recovery-\(UUID().uuidString).bak"
        )
        // Exclusive creation plus synchronization ensures we do not replace an
        // earlier recovery copy or discard the original before it is durable.
        try original.write(to: preservedURL, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: preservedURL)
        defer { try? handle.close() }
        try handle.synchronize()
        try candidate.saveAtomically(to: configURL)
        return candidate
    }

    func present() -> Config? {
        let language = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        let i18n = I18n.load(language, localesDirectory: AppResources.resolve().localesDirectory)
        var bodyKey = "config.recovery_body"
        while true {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = i18n.t("config.recovery_title")
            alert.informativeText = i18n.t(bodyKey)
            alert.addButton(withTitle: i18n.t("config.recovery_open"))
            alert.addButton(withTitle: i18n.t("config.recovery_restore"))
            alert.addButton(withTitle: i18n.t("config.recovery_retry"))
            alert.addButton(withTitle: i18n.t("config.recovery_quit"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.open(configURL)
            case .alertSecondButtonReturn:
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.directoryURL = configURL.deletingLastPathComponent()
                panel.message = i18n.t("config.recovery_choose")
                panel.prompt = i18n.t("config.recovery_restore")
                if panel.runModal() == .OK, let selectedURL = panel.url {
                    do { return try restore(from: selectedURL) }
                    catch { bodyKey = "config.recovery_restore_failed" }
                }
            case .alertThirdButtonReturn:
                do { return try reload() }
                catch { bodyKey = "config.recovery_body" }
            default:
                NSApp.terminate(nil)
                return nil
            }
        }
    }
}
