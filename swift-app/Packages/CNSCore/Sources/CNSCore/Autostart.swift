import Foundation
import ServiceManagement

public enum AutostartSystemStatus: String, Sendable, Equatable {
    case enabled
    case disabled
    case requiresApproval
    case notFound
    case unsupported
}

public enum AutostartError: LocalizedError, Sendable, Equatable {
    case unsupportedOS
    case requestedStateNotReached(expectedEnabled: Bool, actual: AutostartSystemStatus)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            "Launch at Login requires macOS 13 or newer"
        case let .requestedStateNotReached(expected, actual):
            "Launch at Login did not reach the requested state (expected \(expected), got \(actual.rawValue))"
        }
    }
}

/// Abstraction keeps unit tests from registering the development application as
/// a real login item.
@MainActor
public protocol AutostartServicing: AnyObject {
    func status() -> AutostartSystemStatus
    func register() throws
    func unregister() throws
}

@MainActor
public final class SystemAutostartService: AutostartServicing {
    public static let shared = SystemAutostartService()

    private init() {}

    public func status() -> AutostartSystemStatus {
        guard #available(macOS 13.0, *) else { return .unsupported }
        switch SMAppService.mainApp.status {
        case .enabled: return AutostartSystemStatus.enabled
        case .notRegistered: return AutostartSystemStatus.disabled
        case .requiresApproval: return AutostartSystemStatus.requiresApproval
        case .notFound: return AutostartSystemStatus.notFound
        @unknown default: return AutostartSystemStatus.notFound
        }
    }

    public func register() throws {
        guard #available(macOS 13.0, *) else { throw AutostartError.unsupportedOS }
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        guard #available(macOS 13.0, *) else { throw AutostartError.unsupportedOS }
        try SMAppService.mainApp.unregister()
    }
}

public enum Autostart {
    @MainActor
    public static func status(
        using service: any AutostartServicing = SystemAutostartService.shared
    ) -> AutostartSystemStatus {
        service.status()
    }

    @MainActor
    public static func isEnabled(
        using service: any AutostartServicing = SystemAutostartService.shared
    ) -> Bool {
        status(using: service) == .enabled
    }

    /// Config is a desired preference only. The returned status is a fresh
    /// system query after register/unregister and is the only state callers may
    /// persist or render.
    @MainActor
    @discardableResult
    public static func setEnabled(
        _ enabled: Bool,
        using service: any AutostartServicing = SystemAutostartService.shared
    ) throws -> AutostartSystemStatus {
        let before = service.status()
        if enabled {
            if before != .enabled {
                try service.register()
            }
        } else if before != .disabled, before != .notFound {
            try service.unregister()
        }

        let after = service.status()
        if enabled {
            guard after == .enabled || after == .requiresApproval else {
                throw AutostartError.requestedStateNotReached(
                    expectedEnabled: true,
                    actual: after
                )
            }
        } else {
            guard after == .disabled || after == .notFound else {
                throw AutostartError.requestedStateNotReached(
                    expectedEnabled: false,
                    actual: after
                )
            }
        }
        return after
    }
}
