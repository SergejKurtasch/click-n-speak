import Foundation
import UserNotifications

@MainActor
final class UserNotificationService {
    private let center: UNUserNotificationCenter
    private let log: @Sendable (String) -> Void

    init(
        center: UNUserNotificationCenter = .current(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.center = center
        self.log = log
    }

    func deliver(title: String, body: String) {
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                self?.deliver(title: title, body: body, authorizationStatus: status)
            }
        }
    }

    private func deliver(title: String, body: String, authorizationStatus: UNAuthorizationStatus) {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            addRequest(title: title, body: body)
        case .notDetermined:
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                let errorMessage = error?.localizedDescription
                Task { @MainActor in
                    if let errorMessage {
                        self?.log("Notification authorization failed: \(errorMessage)")
                    } else if granted {
                        self?.addRequest(title: title, body: body)
                    }
                }
            }
        case .denied:
            log("Notification delivery skipped because permission is denied")
        @unknown default:
            log("Notification delivery skipped for an unknown authorization state")
        }
    }

    private func addRequest(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "click-n-speak.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { [log] error in
            if let error { log("Notification delivery failed: \(error.localizedDescription)") }
        }
    }
}
