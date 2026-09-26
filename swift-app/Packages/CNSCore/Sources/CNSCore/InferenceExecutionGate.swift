import Foundation

public enum InferenceExecutionGateError: Error, Sendable, Equatable {
    case cancelled
}

/// Process-local exclusion gate shared by local Whisper and local Qwen Metal
/// work. A lease is the ownership token and releases exactly once.
public final class InferenceExecutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: UUID?

    public init() {}

    public var isBusy: Bool { lock.withLock { owner != nil } }

    public func tryAcquire() -> InferenceExecutionLease? {
        lock.withLock {
            guard owner == nil else { return nil }
            let token = UUID()
            owner = token
            return InferenceExecutionLease(gate: self, token: token)
        }
    }

    /// Waits cooperatively without occupying a thread. `nil` means the bounded
    /// wait elapsed; cancellation is reported separately.
    public func acquire(timeout: TimeInterval) async throws -> InferenceExecutionLease? {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        repeat {
            try Task.checkCancellation()
            if let lease = tryAcquire() { return lease }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            try await Task.sleep(for: .milliseconds(10))
        } while true
    }

    fileprivate func release(token: UUID) {
        lock.withLock {
            guard owner == token else { return }
            owner = nil
        }
    }
}

public final class InferenceExecutionLease: @unchecked Sendable {
    private let lock = NSLock()
    private weak var gate: InferenceExecutionGate?
    private let token: UUID
    private var released = false

    fileprivate init(gate: InferenceExecutionGate, token: UUID) {
        self.gate = gate
        self.token = token
    }

    public func release() {
        let owner = lock.withLock { () -> InferenceExecutionGate? in
            guard !released else { return nil }
            released = true
            return gate
        }
        owner?.release(token: token)
    }

    deinit { release() }
}
