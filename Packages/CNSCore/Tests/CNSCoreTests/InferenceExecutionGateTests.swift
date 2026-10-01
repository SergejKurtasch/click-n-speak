import Foundation
import Testing
@testable import CNSCore

@Suite("InferenceExecutionGate")
struct InferenceExecutionGateTests {
    @Test("A lease excludes another owner and releases exactly once")
    func exclusionAndRelease() {
        let gate = InferenceExecutionGate()
        let first = gate.tryAcquire()
        #expect(first != nil)
        #expect(gate.isBusy)
        #expect(gate.tryAcquire() == nil)

        first?.release()
        first?.release()
        #expect(!gate.isBusy)
        #expect(gate.tryAcquire() != nil)
    }

    @Test("Bounded acquisition waits for release")
    func boundedWait() async throws {
        let gate = InferenceExecutionGate()
        let first = try #require(gate.tryAcquire())
        let waiter = Task { try await gate.acquire(timeout: 0.2) }
        try await Task.sleep(for: .milliseconds(20))
        first.release()
        let second = try await waiter.value
        #expect(second != nil)
        second?.release()
    }

    @Test("Cancellation cannot leak ownership")
    func cancellation() async throws {
        let gate = InferenceExecutionGate()
        let first = try #require(gate.tryAcquire())
        let waiter = Task { try await gate.acquire(timeout: 1) }
        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await waiter.value
        }
        first.release()
        #expect(gate.tryAcquire() != nil)
    }
}
