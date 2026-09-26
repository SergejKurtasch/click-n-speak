import CNSCore
import Foundation
import Testing
@testable import CNSTranscription

private actor RouterOperationGate {
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

private actor RouterTranscriberDouble: Transcribing {
    let output: String
    let fileDelayNanoseconds: UInt64
    let prepareGate: RouterOperationGate?
    let tokenCountGate: RouterOperationGate?
    let reloadGate: RouterOperationGate?
    let fileGate: RouterOperationGate?
    private(set) var requestCount = 0
    private(set) var fileRequestCount = 0
    private(set) var stopCount = 0

    init(
        output: String,
        fileDelayNanoseconds: UInt64 = 0,
        prepareGate: RouterOperationGate? = nil,
        tokenCountGate: RouterOperationGate? = nil,
        reloadGate: RouterOperationGate? = nil,
        fileGate: RouterOperationGate? = nil
    ) {
        self.output = output
        self.fileDelayNanoseconds = fileDelayNanoseconds
        self.prepareGate = prepareGate
        self.tokenCountGate = tokenCountGate
        self.reloadGate = reloadGate
        self.fileGate = fileGate
    }

    func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        requestCount += 1
        return TranscriptionResult(text: output)
    }

    func stop() async { stopCount += 1 }

    func prepare(language: String?) async throws {
        await prepareGate?.pause()
    }

    func tokenCount(_ text: String) async -> Int? {
        await tokenCountGate?.pause()
        return text.count
    }

    func reload() async {
        await reloadGate?.pause()
    }

    func transcribeFile(
        _ request: FileTranscriptionRequest,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult {
        fileRequestCount += 1
        await fileGate?.pause()
        if fileDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: fileDelayNanoseconds)
        }
        return FileTranscriptionResult(text: output, status: .success, segmentCount: 1)
    }
}

@Suite("Runtime service routers")
struct RuntimeRouterTests {
    private let request = TranscriptionRequest(audio: [0.1], isFinalChunk: true)

    @Test("Requests before and after a transcriber swap use the active engine")
    func transcriberSwap() async {
        let router = TranscriberRouter()
        let local = RouterTranscriberDouble(output: "local")
        let cloud = RouterTranscriberDouble(output: "cloud")

        await router.install(
            local,
            descriptor: TranscriberDescriptor(backend: "local", modelID: "turbo", kind: .local)
        )
        #expect(await router.transcribe(request).text == "local")

        await router.install(
            cloud,
            descriptor: TranscriberDescriptor(backend: "gemini", modelID: "flash", kind: .cloud)
        )
        while await local.stopCount == 0 { await Task.yield() }
        #expect(await router.transcribe(request).text == "cloud")
        #expect(router.currentDescriptorSnapshot.backend == "gemini")
        #expect(await local.stopCount == 1)
        #expect(await cloud.stopCount == 0)
    }

    @Test("A file job retains its starting runtime descriptor across a swap")
    func fileJobDescriptorIsStable() async {
        let router = TranscriberRouter()
        let local = RouterTranscriberDouble(output: "local-file", fileDelayNanoseconds: 40_000_000)
        let cloud = RouterTranscriberDouble(output: "cloud")
        let localDescriptor = TranscriberDescriptor(
            backend: "local", modelID: "turbo", kind: .local
        )
        await router.install(local, descriptor: localDescriptor)
        let request = FileTranscriptionRequest(url: URL(fileURLWithPath: "fixture.wav"))
        let task = Task { await router.transcribeFile(request) { _ in } }
        while await local.fileRequestCount == 0 { await Task.yield() }

        await router.install(
            cloud,
            descriptor: TranscriberDescriptor(backend: "openai", modelID: "gpt-4o", kind: .cloud)
        )
        #expect(await local.stopCount == 0)
        let result = await task.value

        #expect(result.text == "local-file")
        #expect(result.backend == localDescriptor.backend)
        #expect(result.modelID == localDescriptor.modelID)
        #expect(await local.stopCount == 1)
        #expect(router.currentDescriptorSnapshot.backend == "openai")
    }

    @Test("An older activation generation cannot replace the current engine")
    func staleActivationIsRejected() async {
        let router = TranscriberRouter()
        let current = RouterTranscriberDouble(output: "current")
        let stale = RouterTranscriberDouble(output: "stale")
        let descriptor = TranscriberDescriptor(backend: "local", modelID: "current", kind: .local)

        #expect(await router.install(current, descriptor: descriptor, activationGeneration: 7))
        #expect(await router.install(
            stale,
            descriptor: TranscriberDescriptor(backend: "openai", modelID: "stale", kind: .cloud),
            activationGeneration: 6
        ) == false)
        #expect(await router.transcribe(request).text == "current")
        #expect(router.currentDescriptorSnapshot == descriptor)
        #expect(await stale.stopCount == 0, "A rejected candidate remains owned by the caller")
    }

    @Test("A staged transcriber can roll back without stopping the previous engine")
    func stagedInstallRollsBack() async throws {
        let router = TranscriberRouter()
        let previous = RouterTranscriberDouble(output: "previous")
        let candidate = RouterTranscriberDouble(output: "candidate")
        let previousDescriptor = TranscriberDescriptor(
            backend: "local", modelID: "previous", kind: .local
        )
        await router.install(previous, descriptor: previousDescriptor, activationGeneration: 1)

        let installation = try #require(await router.stageInstall(
            candidate,
            descriptor: TranscriberDescriptor(
                backend: "openai", modelID: "candidate", kind: .cloud
            ),
            activationGeneration: 2
        ))
        #expect(await previous.stopCount == 0)
        await router.rollback(installation)

        #expect(router.currentDescriptorSnapshot == previousDescriptor)
        #expect(await router.transcribe(request).text == "previous")
        #expect(await previous.stopCount == 0)
        #expect(await candidate.stopCount == 1)
        await router.stop()
    }

    @Test("A staged transcriber disable supports rollback and commit")
    func stagedDisableIsTransactional() async throws {
        let router = TranscriberRouter()
        let service = RouterTranscriberDouble(output: "active")
        let descriptor = TranscriberDescriptor(
            backend: "gemini", modelID: "cloud", kind: .cloud
        )
        await router.install(service, descriptor: descriptor, activationGeneration: 1)

        let rollbackToken = try #require(
            await router.stageDisable(activationGeneration: 2)
        )
        #expect(router.currentDescriptorSnapshot == .unavailable)
        #expect(await service.stopCount == 0)
        await router.rollback(rollbackToken)
        #expect(router.currentDescriptorSnapshot == descriptor)
        #expect(await router.transcribe(request).text == "active")
        #expect(await service.stopCount == 0)

        let commitToken = try #require(
            await router.stageDisable(activationGeneration: 3)
        )
        await router.commit(commitToken)
        #expect(router.currentDescriptorSnapshot == .unavailable)
        #expect(await service.stopCount == 1)
        let unavailable = await router.transcribe(request)
        if case let .failed(failure) = unavailable.outcome {
            #expect(failure.kind == .unavailable)
        } else {
            Issue.record("Expected unavailable transcription outcome")
        }
    }

    @Test("Prepare, token counting, and reload retain a retired engine")
    func auxiliaryOperationsRetainRetiredEngine() async throws {
        let router = TranscriberRouter()
        let prepareGate = RouterOperationGate()
        let tokenCountGate = RouterOperationGate()
        let reloadGate = RouterOperationGate()
        let old = RouterTranscriberDouble(
            output: "old",
            prepareGate: prepareGate,
            tokenCountGate: tokenCountGate,
            reloadGate: reloadGate
        )
        let replacement = RouterTranscriberDouble(output: "new")
        await router.install(
            old,
            descriptor: TranscriberDescriptor(backend: "local", modelID: "old", kind: .local)
        )

        let prepare = Task { try await router.prepare(language: "ru") }
        let tokenCount = Task { await router.tokenCount("abc") }
        let reload = Task { await router.reload() }
        await prepareGate.waitUntilEntered()
        await tokenCountGate.waitUntilEntered()
        await reloadGate.waitUntilEntered()

        await router.install(
            replacement,
            descriptor: TranscriberDescriptor(backend: "openai", modelID: "new", kind: .cloud)
        )
        #expect(await old.stopCount == 0)

        await prepareGate.release()
        await tokenCountGate.release()
        await reloadGate.release()
        try await prepare.value
        #expect(await tokenCount.value == 3)
        await reload.value
        while await old.stopCount == 0 { await Task.yield() }

        #expect(await old.stopCount == 1)
        #expect(await router.trackedInFlightGenerationCount == 0)
        await router.stop()
    }

    @Test("Router stop waits for an active file request before stopping its engine")
    func stopWaitsForActiveUse() async {
        let router = TranscriberRouter()
        let fileGate = RouterOperationGate()
        let service = RouterTranscriberDouble(output: "file", fileGate: fileGate)
        await router.install(
            service,
            descriptor: TranscriberDescriptor(backend: "local", modelID: "old", kind: .local)
        )
        let request = FileTranscriptionRequest(url: URL(fileURLWithPath: "fixture.wav"))
        let file = Task { await router.transcribeFile(request) { _ in } }
        await fileGate.waitUntilEntered()

        let stop = Task { await router.stop() }
        while router.currentDescriptorSnapshot != .unavailable { await Task.yield() }
        #expect(await service.stopCount == 0)

        await fileGate.release()
        _ = await file.value
        await stop.value
        #expect(await service.stopCount == 1)
        #expect(await router.trackedInFlightGenerationCount == 0)
    }

}
