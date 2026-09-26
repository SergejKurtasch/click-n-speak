import CNSCore
import Foundation
import Testing
@testable import ClickNSpeak

private actor UnreadyEditor: AiEditing {
    nonisolated let isReady = false
    private(set) var stopCount = 0
    private(set) var prewarmCount = 0

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

    func preWarm(languages: [String]?, force: Bool) async -> PrewarmResult {
        prewarmCount += 1
        return .warmed
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

    @Test("The production editor wrapper forwards local prewarm")
    func editorWrapperForwardsPrewarm() async {
        let inner = UnreadyEditor()
        let service = AccessTokenReleasingEditor(inner: inner, tokens: [])

        #expect(await service.preWarm(languages: ["ru", "en"], force: true) == .warmed)
        #expect(await inner.prewarmCount == 1)
    }
}
