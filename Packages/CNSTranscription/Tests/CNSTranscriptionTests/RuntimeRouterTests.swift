import CNSCore
import Foundation
import Testing
@testable import CNSTranscription

private actor RouterTranscriberDouble: Transcribing {
    let output: String
    let fileDelayNanoseconds: UInt64
    private(set) var requestCount = 0
    private(set) var fileRequestCount = 0
    private(set) var stopCount = 0

    init(output: String, fileDelayNanoseconds: UInt64 = 0) {
        self.output = output
        self.fileDelayNanoseconds = fileDelayNanoseconds
    }

    func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        requestCount += 1
        return TranscriptionResult(text: output)
    }

    func stop() async { stopCount += 1 }

    func transcribeFile(
        _ request: FileTranscriptionRequest,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult {
        fileRequestCount += 1
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

}
