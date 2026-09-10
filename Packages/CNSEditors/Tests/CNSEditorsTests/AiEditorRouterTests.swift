import CNSCore
import Testing
@testable import CNSEditors

private actor EditorOperationGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RouterEditorDouble: AiEditing {
    nonisolated let isReady = true
    nonisolated let descriptor: AiEditorDescriptor
    let suffix: String
    let refineGate: EditorOperationGate?
    private(set) var stopCount = 0

    init(
        suffix: String,
        descriptor: AiEditorDescriptor,
        refineGate: EditorOperationGate? = nil
    ) {
        self.suffix = suffix
        self.descriptor = descriptor
        self.refineGate = refineGate
    }

    func refine(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        await refineGate?.pause()
        return RefineResult(text: text + suffix, status: .ok)
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

    @Test("A staged editor can roll back without stopping the previous editor")
    func stagedInstallRollsBack() async throws {
        let router = AiEditorRouter()
        let previousDescriptor = AiEditorDescriptor(
            backend: "local", modelID: "previous", kind: .local
        )
        let previous = RouterEditorDouble(suffix: "-previous", descriptor: previousDescriptor)
        let candidateDescriptor = AiEditorDescriptor(
            backend: "gemini", modelID: "candidate", kind: .cloud
        )
        let candidate = RouterEditorDouble(suffix: "-candidate", descriptor: candidateDescriptor)
        await router.install(previous, descriptor: previousDescriptor, activationGeneration: 1)

        let installation = try #require(await router.stageInstall(
            candidate,
            descriptor: candidateDescriptor,
            activationGeneration: 2
        ))
        #expect(await previous.stopCount == 0)
        await router.rollback(installation)

        #expect(router.currentDescriptorSnapshot == previousDescriptor)
        #expect(await router.refine(
            text: "x", languages: nil, knownTerms: nil, misrecognitions: nil
        ).text == "x-previous")
        #expect(await previous.stopCount == 0)
        #expect(await candidate.stopCount == 1)
        await router.stop()
    }

    @Test("Router stop waits for an active refinement and clears its ownership entry")
    func stopWaitsForActiveRefinement() async {
        let router = AiEditorRouter()
        let gate = EditorOperationGate()
        let descriptor = AiEditorDescriptor(backend: "local", modelID: "qwen", kind: .local)
        let editor = RouterEditorDouble(suffix: "-done", descriptor: descriptor, refineGate: gate)
        await router.install(editor, descriptor: descriptor)
        let refinement = Task {
            await router.refine(
                text: "draft", languages: nil, knownTerms: nil, misrecognitions: nil
            )
        }
        await gate.waitUntilEntered()

        let stop = Task { await router.stop() }
        while router.currentDescriptorSnapshot != .disabled { await Task.yield() }
        #expect(await editor.stopCount == 0)

        await gate.release()
        #expect(await refinement.value.text == "draft-done")
        await stop.value
        #expect(await editor.stopCount == 1)
        #expect(await router.trackedInFlightGenerationCount == 0)
    }
}
