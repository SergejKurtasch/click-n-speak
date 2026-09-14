import CNSCore
import Foundation
import Testing
@testable import ClickNSpeak

private actor UnreadyEditor: AiEditing {
    nonisolated let isReady = false
    private(set) var stopCount = 0

    func refine(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        RefineResult(text: text, status: .unchanged)
    }

    func refineFileText(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        RefineResult(text: text, status: .unchanged)
    }

    func stop() async { stopCount += 1 }
}

@Suite("Runtime service preparation")
struct EditorPreparationCleanupTests {
    @Test("An editor that prepares but is not ready is stopped before rejection")
    func unreadyEditorIsStopped() async {
        let inner = UnreadyEditor()
        let service = AccessTokenReleasingEditor(inner: inner, tokens: [])

        await #expect(throws: RuntimePreparationError.self) {
            try await service.prepare()
        }
        #expect(await inner.stopCount == 1)
    }
}
