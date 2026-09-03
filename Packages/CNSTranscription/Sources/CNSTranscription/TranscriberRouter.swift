import CNSCore
import Foundation

/// Stable transcription endpoint retained by the session for the app lifetime.
/// Candidate preparation happens outside the router; `install` is the atomic
/// activation point. Retired engines are stopped only after their in-flight
/// calls have returned.
public actor TranscriberRouter: Transcribing {
    private struct Entry: Sendable {
        let generation: Int
        let service: any Transcribing
        let descriptor: TranscriberDescriptor
    }

    private var active: Entry?
    private var nextGeneration = 0
    private var latestActivationGeneration = 0
    private var inFlight: [Int: Int] = [:]
    private var retired: [Int: any Transcribing] = [:]
    private let descriptorSnapshot = LockedSnapshot(TranscriberDescriptor.unavailable)
    private let abortTarget = LockedSnapshot<(any Transcribing)?>(nil)

    public init() {}

    public nonisolated var currentDescriptorSnapshot: TranscriberDescriptor {
        descriptorSnapshot.get()
    }

    @discardableResult
    public func install(
        _ service: any Transcribing,
        descriptor: TranscriberDescriptor,
        activationGeneration: Int? = nil
    ) -> Bool {
        precondition(descriptor.readiness == .ready)
        let requestedGeneration = activationGeneration ?? (latestActivationGeneration + 1)
        guard requestedGeneration > latestActivationGeneration else { return false }
        latestActivationGeneration = requestedGeneration
        nextGeneration += 1
        let candidate = Entry(generation: nextGeneration, service: service, descriptor: descriptor)
        let previous = active
        active = candidate
        descriptorSnapshot.set(descriptor)
        abortTarget.set(service)

        if let previous {
            if inFlight[previous.generation, default: 0] == 0 {
                Task { await previous.service.stop() }
            } else {
                retired[previous.generation] = previous.service
            }
        }
        return true
    }

    public func transcribe(_ request: TranscriptionRequest) async -> TranscriptionResult {
        guard let entry = active else {
            return .failed(.init(kind: .unavailable, message: "No transcription runtime is active"))
        }
        beginUse(entry.generation)
        var result = await entry.service.transcribe(request)
        result.backend = entry.descriptor.backend
        result.modelID = entry.descriptor.modelID
        await endUse(entry.generation)
        return result
    }

    public func warmup(language: String?) async {
        guard let entry = active else { return }
        beginUse(entry.generation)
        await entry.service.warmup(language: language)
        await endUse(entry.generation)
    }

    public func prepare(language: String?) async throws {
        guard let entry = active else { throw CocoaError(.featureUnsupported) }
        try await entry.service.prepare(language: language)
    }

    public func preWarm() async {
        guard let entry = active else { return }
        beginUse(entry.generation)
        await entry.service.preWarm()
        await endUse(entry.generation)
    }

    public func tokenCount(_ text: String) async -> Int? {
        guard let entry = active else { return nil }
        return await entry.service.tokenCount(text)
    }

    public func transcribeFile(
        _ request: FileTranscriptionRequest,
        progress: @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult {
        guard let entry = active else {
            return .failed(.init(kind: .unavailable, message: "No transcription runtime is active"))
        }
        beginUse(entry.generation)
        var result = await entry.service.transcribeFile(request, progress: progress)
        result.backend = entry.descriptor.backend
        result.modelID = entry.descriptor.modelID
        await endUse(entry.generation)
        return result
    }

    public func reload() async {
        guard let entry = active else { return }
        await entry.service.reload()
    }

    public nonisolated func abortInFlight() {
        abortTarget.get()?.abortInFlight()
    }

    public func stop() async {
        abortInFlight()
        let services = ([active?.service].compactMap { $0 } + Array(retired.values))
        active = nil
        retired.removeAll()
        latestActivationGeneration = 0
        descriptorSnapshot.set(.unavailable)
        abortTarget.set(nil)
        for service in services { await service.stop() }
    }

    private func beginUse(_ generation: Int) {
        inFlight[generation, default: 0] += 1
    }

    private func endUse(_ generation: Int) async {
        let remaining = max(0, inFlight[generation, default: 1] - 1)
        inFlight[generation] = remaining
        if remaining == 0, let service = retired.removeValue(forKey: generation) {
            await service.stop()
        }
    }
}
