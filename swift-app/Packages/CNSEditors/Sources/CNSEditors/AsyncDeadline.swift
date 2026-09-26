import Foundation

enum AsyncDeadline {
    /// Returns at the caller deadline without structurally waiting for an
    /// uncooperative operation. The operation owns any execution lease until
    /// it really exits; cancellation only requests early termination.
    static func race<Value: Sendable>(
        operation: Task<Value, Never>,
        timeout: TimeInterval,
        timeoutValue: Value
    ) async -> Value {
        let stream = AsyncStream<Value> { continuation in
            let waiter = Task {
                let value = await operation.value
                continuation.yield(value)
                continuation.finish()
            }
            let timer = Task {
                do {
                    try await Task.sleep(for: .seconds(max(0, timeout)))
                } catch {
                    return
                }
                continuation.yield(timeoutValue)
                continuation.finish()
                operation.cancel()
            }
            continuation.onTermination = { _ in
                waiter.cancel()
                timer.cancel()
            }
        }
        return await withTaskCancellationHandler {
            await stream.first(where: { _ in true }) ?? timeoutValue
        } onCancel: {
            operation.cancel()
        }
    }
}
