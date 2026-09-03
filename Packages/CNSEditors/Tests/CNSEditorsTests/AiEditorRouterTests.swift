import CNSCore
import Testing
@testable import CNSEditors

private actor RouterEditorDouble: AiEditing {
    nonisolated let isReady = true
    nonisolated let descriptor: AiEditorDescriptor
    let suffix: String
    private(set) var stopCount = 0

    init(suffix: String, descriptor: AiEditorDescriptor) {
        self.suffix = suffix
        self.descriptor = descriptor
    }

    func refine(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        RefineResult(text: text + suffix, status: .ok)
    }

    func refineFileText(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        RefineResult(text: text + suffix, status: .ok)
    }

    func stop() async { stopCount += 1 }
}

@Suite("AI editor router")
struct AiEditorRouterTests {
    @Test("Disable and replacement retire each prior editor once")
    func swapAndDisable() async {
        let router = AiEditorRouter()
        let firstDescriptor = AiEditorDescriptor(backend: "local", modelID: "qwen", kind: .local)
        let secondDescriptor = AiEditorDescriptor(backend: "gemini", modelID: "flash", kind: .cloud)
        let first = RouterEditorDouble(suffix: "-one", descriptor: firstDescriptor)
        let second = RouterEditorDouble(suffix: "-two", descriptor: secondDescriptor)

        await router.install(first, descriptor: firstDescriptor)
        #expect(await router.refine(text: "x", languages: nil, knownTerms: nil, misrecognitions: nil).text == "x-one")

        await router.install(second, descriptor: secondDescriptor)
        while await first.stopCount == 0 { await Task.yield() }
        #expect(await first.stopCount == 1)
        #expect(await router.refine(text: "x", languages: nil, knownTerms: nil, misrecognitions: nil).text == "x-two")

        await router.install(nil, descriptor: .disabled)
        while await second.stopCount == 0 { await Task.yield() }
        #expect(await second.stopCount == 1)
        #expect(router.isReady == false)
        #expect(router.descriptor == .disabled)
        #expect(await router.refine(text: "x", languages: nil, knownTerms: nil, misrecognitions: nil).status == .disabled)
    }

    @Test("An older activation generation cannot replace the current editor")
    func staleActivationIsRejected() async {
        let router = AiEditorRouter()
        let descriptor = AiEditorDescriptor(backend: "local", modelID: "current", kind: .local)
        let current = RouterEditorDouble(suffix: "-current", descriptor: descriptor)
        let staleDescriptor = AiEditorDescriptor(backend: "gemini", modelID: "stale", kind: .cloud)
        let stale = RouterEditorDouble(suffix: "-stale", descriptor: staleDescriptor)

        #expect(await router.install(current, descriptor: descriptor, activationGeneration: 9))
        #expect(await router.install(stale, descriptor: staleDescriptor, activationGeneration: 8) == false)
        #expect(await router.refine(
            text: "x", languages: nil, knownTerms: nil, misrecognitions: nil
        ).text == "x-current")
        #expect(router.descriptor == descriptor)
        #expect(await stale.stopCount == 0, "A rejected candidate remains owned by the caller")
    }
}
