import AppKit
import CNSCore
import CNSUI

enum StartupStorageIssue: Equatable {
    case dataDirectory
    case instanceLock
    case initialConfiguration

    var messageKey: String {
        switch self {
        case .dataDirectory: "startup.storage_directory_body"
        case .instanceLock: "startup.storage_lock_body"
        case .initialConfiguration: "startup.storage_config_body"
        }
    }
}

enum StartupStorageOutcome: Equatable {
    case ready
    case anotherInstance
}

/// Pauses startup until the failed storage operation succeeds or the user quits.
/// The retry closure captures only the operation that failed; no profile owner
/// or runtime is created while this coordinator is unresolved.
@MainActor
final class StartupStorageRecoveryCoordinator {
    let issue: StartupStorageIssue
    private let operation: () throws -> StartupStorageOutcome
    private(set) var outcome: StartupStorageOutcome?

    init(issue: StartupStorageIssue, operation: @escaping () throws -> StartupStorageOutcome) {
        self.issue = issue
        self.operation = operation
    }

    @discardableResult
    func retry() throws -> StartupStorageOutcome {
        let completed = try operation()
        outcome = completed
        return completed
    }

    func present() {
        let language = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        let i18n = I18n.load(language, localesDirectory: AppResources.resolve().localesDirectory)
        while outcome == nil {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = i18n.t("startup.storage_title")
            alert.informativeText = i18n.t(issue.messageKey)
            alert.addButton(withTitle: i18n.t("btn.retry"))
            alert.addButton(withTitle: i18n.t("config.recovery_quit"))
            if alert.runModal() == .alertFirstButtonReturn {
                do { try retry() }
                catch { continue }
            } else {
                NSApp.terminate(nil)
                return
            }
        }
    }
}
