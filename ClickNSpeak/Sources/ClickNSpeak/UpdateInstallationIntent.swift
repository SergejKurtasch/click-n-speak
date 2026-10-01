import CNSCore

/// Holds the update handoff until its helper has either been allowed to install
/// after termination or has been confirmed stopped after a refused shutdown.
@MainActor
final class UpdateInstallationIntent {
    private enum Phase {
        case idle
        case preparing
        case waiting(UpdateInstallationHandle)
    }

    private var phase: Phase = .idle

    var isBusy: Bool {
        if case .idle = phase { return false }
        return true
    }

    var isPreparing: Bool {
        if case .preparing = phase { return true }
        return false
    }

    var pendingHandle: UpdateInstallationHandle? {
        if case let .waiting(handle) = phase { return handle }
        return nil
    }

    func beginPreparation() -> Bool {
        guard case .idle = phase else { return false }
        phase = .preparing
        return true
    }

    func markHelperStarted(_ handle: UpdateInstallationHandle) {
        guard case .preparing = phase else { return }
        phase = .waiting(handle)
    }

    func abortPreparation() {
        guard case .preparing = phase else { return }
        phase = .idle
    }

    func cancelPending(
        using cancellation: (UpdateInstallationHandle) async throws -> Void
    ) async throws {
        guard let handle = pendingHandle else { return }
        try await cancellation(handle)
        if pendingHandle == handle { phase = .idle }
    }
}
