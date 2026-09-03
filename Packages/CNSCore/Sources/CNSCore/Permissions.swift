import AppKit
import AVFoundation
import ApplicationServices
import Foundation

public enum PermissionStatus: String, Sendable, Equatable {
    case granted
    case denied
    case restricted
    case undetermined
}

public enum PermissionServiceError: Error, LocalizedError {
    case setupFlagCreationFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .setupFlagCreationFailed(let url):
            return "Could not create the setup marker at \(url.path)"
        }
    }
}

/// Testable permission boundary used by the setup flow and menu.
///
/// The protocol is main-actor isolated because callers immediately reflect the
/// values in AppKit. Long permission waits are implemented with suspending tasks
/// in CNSUI, so this isolation never requires a blocking modal loop.
@MainActor
public protocol PermissionServicing: AnyObject {
    var setupDoneURL: URL { get }

    func isSetupDone() -> Bool
    func markSetupDone() throws
    func resetSetup() throws

    func microphoneStatus() -> PermissionStatus
    func requestMicrophoneAccess() async -> Bool
    func openMicrophoneSettings()

    func accessibilityGranted() -> Bool
    @discardableResult func requestAccessibilityPrompt() -> Bool
    func openAccessibilitySettings()

    func allPermissionsGranted() -> Bool
}

@MainActor
public final class SystemPermissionService: PermissionServicing {
    public let setupDoneURL: URL

    public init(paths: Paths) {
        self.setupDoneURL = paths.setupDoneFile
    }

    public init(setupDoneURL: URL) {
        self.setupDoneURL = setupDoneURL
    }

    public func isSetupDone() -> Bool {
        FileManager.default.fileExists(atPath: setupDoneURL.path)
    }

    public func markSetupDone() throws {
        let directory = setupDoneURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data().write(to: setupDoneURL, options: .atomic)
        guard FileManager.default.fileExists(atPath: setupDoneURL.path) else {
            throw PermissionServiceError.setupFlagCreationFailed(setupDoneURL)
        }
    }

    public func resetSetup() throws {
        guard FileManager.default.fileExists(atPath: setupDoneURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: setupDoneURL)
    }

    public func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .undetermined
        @unknown default:
            return .undetermined
        }
    }

    public func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func openMicrophoneSettings() {
        openSystemSettings(
            urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
    }

    public func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public func requestAccessibilityPrompt() -> Bool {
        // The SDK exposes kAXTrustedCheckOptionPrompt as mutable global state,
        // which Swift 6 rejects under strict concurrency. Its documented CFString
        // value is stable and safe to construct locally.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func openAccessibilitySettings() {
        openSystemSettings(
            urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    public func allPermissionsGranted() -> Bool {
        microphoneStatus() == .granted && accessibilityGranted()
    }

    private func openSystemSettings(urlString: String) {
        guard let url = URL(string: urlString) else {
            return
        }
        NSWorkspace.shared.open(url)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            let settings = NSWorkspace.shared.runningApplications.first { application in
                guard let bundleID = application.bundleIdentifier?.lowercased() else {
                    return false
                }
                return bundleID.contains("systempreferences") || bundleID.contains("systemsettings")
            }
            settings?.activate()
        }
    }
}
