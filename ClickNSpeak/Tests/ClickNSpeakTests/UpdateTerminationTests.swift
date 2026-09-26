import CNSCore
import Foundation
import Testing
@testable import ClickNSpeak

@MainActor
@Suite("Update installation intent")
struct UpdateTerminationTests {
    @Test("A second installation cannot start while the first is preparing")
    func preparationIsSingleFlight() {
        let intent = UpdateInstallationIntent()
        #expect(intent.beginPreparation())
        #expect(!intent.beginPreparation())
        #expect(intent.isBusy)
        intent.abortPreparation()
        #expect(!intent.isBusy)
    }

    @Test("A failed helper cancellation keeps the update handoff busy")
    func cancellationFailureRetainsHandoff() async throws {
        let intent = UpdateInstallationIntent()
        let handle = UpdateInstallationHandle(transactionID: UUID(), operationID: UUID())
        #expect(intent.beginPreparation())
        intent.markHelperStarted(handle)

        do {
            try await intent.cancelPending { _ in throw CancellationFailure.fixture }
            Issue.record("Expected helper cancellation failure")
        } catch is CancellationFailure {}
        #expect(intent.pendingHandle == handle)
        #expect(intent.isBusy)
        #expect(!intent.beginPreparation())

        try await intent.cancelPending { received in
            #expect(received == handle)
        }
        #expect(intent.pendingHandle == nil)
        #expect(!intent.isBusy)
    }

    private enum CancellationFailure: Error {
        case fixture
    }
}
