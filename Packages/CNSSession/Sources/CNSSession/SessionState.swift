import Darwin
import Foundation

/// Read-only lifecycle snapshot for one dictation generation. Mutable
/// transitions are owned exclusively by `SessionController` on MainActor.
public enum SessionState: Sendable, Equatable {
    case idle
    case starting(sessionID: Int, targetPID: pid_t?, appendMode: Bool)
    case recording(sessionID: Int, targetPID: pid_t?, appendMode: Bool)
    case stopping(sessionID: Int)
    case processing(sessionID: Int, overdue: Bool)
    case popup(sessionID: Int, targetPID: pid_t?)
    case injecting(sessionID: Int, targetPID: pid_t?)
    case failed(recoverable: Bool, message: String)

    public var sessionID: Int? {
        switch self {
        case .idle, .failed:
            return nil
        case let .starting(id, _, _), let .recording(id, _, _),
             let .stopping(id), let .processing(id, _),
             let .popup(id, _), let .injecting(id, _):
            return id
        }
    }
}
