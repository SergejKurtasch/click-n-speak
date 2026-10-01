import AppKit
import Darwin
import Foundation

public protocol UpdateProcessOperating: Sendable {
    func isRunning(pid: Int32) -> Bool
    func requestTermination(pid: Int32) throws
    func waitForExit(pid: Int32, timeout: TimeInterval) async throws -> Bool
    func launch(application: URL, arguments: [String]) async throws -> Int32
}

public enum UpdateLifecycleError: LocalizedError, Sendable, Equatable {
    case parentDidNotExit
    case replacementDidNotExit
    case acknowledgementTimedOut

    public var errorDescription: String? {
        switch self {
        case .parentDidNotExit:
            "The running application did not exit before the update deadline"
        case .replacementDidNotExit:
            "The replacement application did not exit before rollback"
        case .acknowledgementTimedOut:
            "The replacement application did not acknowledge a healthy launch"
        }
    }
}

public enum UpdateProcessOperationError: LocalizedError, Sendable, Equatable {
    case processNotFound
    case terminationRequestFailed
    case launchFailed

    public var errorDescription: String? {
        switch self {
        case .processNotFound:
            "The update process could not be resolved"
        case .terminationRequestFailed:
            "The update process did not accept the termination request"
        case .launchFailed:
            "The application launch did not return a process"
        }
    }
}

/// macOS process adapter that conservatively treats unknown process state as running.
public final class SystemUpdateProcessOperator: UpdateProcessOperating, @unchecked Sendable {
    public init() {}

    public func isRunning(pid: Int32) -> Bool {
        guard pid > 1 else { return true }
        if kill(pid_t(pid), 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    public func requestTermination(pid: Int32) throws {
        guard isRunning(pid: pid) else { return }
        guard let application = NSRunningApplication(processIdentifier: pid_t(pid)) else {
            throw UpdateProcessOperationError.processNotFound
        }
        guard application.terminate() else {
            throw UpdateProcessOperationError.terminationRequestFailed
        }
    }

    public func waitForExit(pid: Int32, timeout: TimeInterval) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while isRunning(pid: pid) {
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    public func launch(application: URL, arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = arguments
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(
                at: application,
                configuration: configuration
            ) { runningApplication, error in
                if let runningApplication {
                    continuation.resume(returning: runningApplication.processIdentifier)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: UpdateProcessOperationError.launchFailed)
                }
            }
        }
    }
}

/// Enforces process-exit prerequisites around a recoverable application swap.
public struct UpdateProcessLifecycle: Sendable {
    private let processes: any UpdateProcessOperating
    private let swap: RecoverableAppSwap

    public init(
        processes: any UpdateProcessOperating,
        files: any UpdateFileOperating = SystemUpdateFileOperator()
    ) {
        self.processes = processes
        swap = RecoverableAppSwap(files: files)
    }

    public func installAfterParentExit(
        parentPID: Int32,
        timeout: TimeInterval,
        staged: URL,
        target: URL,
        backup: URL
    ) async throws {
        guard try await processes.waitForExit(pid: parentPID, timeout: timeout) else {
            throw UpdateLifecycleError.parentDidNotExit
        }
        try swap.install(staged: staged, target: target, backup: backup)
    }

    public func launch(application: URL, arguments: [String]) async throws -> Int32 {
        try await processes.launch(application: application, arguments: arguments)
    }

    public func rollbackAfterReplacementExit(
        replacementPID: Int32,
        timeout: TimeInterval,
        target: URL,
        backup: URL,
        failedCandidate: URL
    ) async throws {
        try processes.requestTermination(pid: replacementPID)
        guard try await processes.waitForExit(pid: replacementPID, timeout: timeout) else {
            throw UpdateLifecycleError.replacementDidNotExit
        }
        try swap.rollback(target: target, backup: backup, failedCandidate: failedCandidate)
    }

    public func rollbackWithoutLaunchedReplacement(
        target: URL,
        backup: URL,
        failedCandidate: URL
    ) throws {
        try swap.rollback(target: target, backup: backup, failedCandidate: failedCandidate)
    }

    @discardableResult
    public func restorePreviousApplication(
        replacementPID: Int32?,
        exitTimeout: TimeInterval,
        target: URL,
        backup: URL,
        failedCandidate: URL
    ) async throws -> Int32 {
        if let replacementPID {
            try await rollbackAfterReplacementExit(
                replacementPID: replacementPID,
                timeout: exitTimeout,
                target: target,
                backup: backup,
                failedCandidate: failedCandidate
            )
        } else {
            try rollbackWithoutLaunchedReplacement(
                target: target,
                backup: backup,
                failedCandidate: failedCandidate
            )
        }

        let restoredPID = try await processes.launch(application: target, arguments: [])
        return restoredPID
    }

    public func discardFailedCandidate(at failedCandidate: URL) throws {
        try swap.discardFailedCandidate(at: failedCandidate)
    }

    public func finalizeSuccessfulUpdate(backup: URL) throws {
        try swap.finalize(backup: backup)
    }
}
