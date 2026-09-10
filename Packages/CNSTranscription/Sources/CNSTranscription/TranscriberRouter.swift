import CNSCore
import Foundation

public struct TranscriberRouterInstallation: Sendable, Equatable {
    fileprivate let id: Int
}

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

    private struct PendingInstallation: Sendable {
        let id: Int
        let candidate: Entry?
        let previous: Entry?
    }

    private var active: Entry?
    private var pendingInstallation: PendingInstallation?
    private var nextGeneration = 0
    private var nextInstallationID = 0
    private var latestActivationGeneration = 0
    private var inFlight: [Int: Int] = [:]
    private var retired: [Int: any Transcribing] = [:]
    private var pendingStops = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var isStopping = false
    private let descriptorSnapshot = LockedSnapshot(TranscriberDescriptor.unavailable)
    private let abortTarget = LockedSnapshot<(any Transcribing)?>(nil)

    public init() {}

    public nonisolated var currentDescriptorSnapshot: TranscriberDescriptor {
        descriptorSnapshot.get()
    }

    var trackedInFlightGenerationCount: Int { inFlight.count }

    @discardableResult
    public func install(
        _ service: any Transcribing,
        descriptor: TranscriberDescriptor,
        activationGeneration: Int? = nil
    ) async -> Bool {
        guard let installation = stageInstall(
            service,
            descriptor: descriptor,
            activationGeneration: activationGeneration
        ) else { return false }
        await commit(installation)
        return true
    }

    /// Publishes a candidate without retiring the previous service. The caller
    /// can stage multiple routers, then either commit all of them or roll back
    /// without depending on an already-started background stop.
    public func stageInstall(
        _ service: any Transcribing,
        descriptor: TranscriberDescriptor,
        activationGeneration: Int? = nil
    ) -> TranscriberRouterInstallation? {
        precondition(descriptor.readiness == .ready)
        guard !isStopping, pendingInstallation == nil else { return nil }
        let requestedGeneration = activationGeneration ?? (latestActivationGeneration + 1)
        guard requestedGeneration > latestActivationGeneration else { return nil }
        latestActivationGeneration = requestedGeneration
        nextGeneration += 1
        nextInstallationID += 1
        let candidate = Entry(generation: nextGeneration, service: service, descriptor: descriptor)
        let previous = active
        active = candidate
        descriptorSnapshot.set(descriptor)
        abortTarget.set(service)
        let installation = PendingInstallation(
            id: nextInstallationID,
            candidate: candidate,
            previous: previous
        )
        pendingInstallation = installation
        return TranscriberRouterInstallation(id: installation.id)
    }

    /// Stage removal of the active transcriber while retaining it for rollback.
    /// Credential deletion uses this to make an invalid cloud client unavailable
    /// without stopping it until the coordinated runtime commit succeeds.
    public func stageDisable(
        activationGeneration: Int? = nil
    ) -> TranscriberRouterInstallation? {
        guard !isStopping, pendingInstallation == nil else { return nil }
        let requestedGeneration = activationGeneration ?? (latestActivationGeneration + 1)
        guard requestedGeneration > latestActivationGeneration else { return nil }
        latestActivationGeneration = requestedGeneration
        nextInstallationID += 1
        let previous = active
        active = nil
        descriptorSnapshot.set(.unavailable)
        abortTarget.set(nil)
        let installation = PendingInstallation(
            id: nextInstallationID,
            candidate: nil,
            previous: previous
        )
        pendingInstallation = installation
        return TranscriberRouterInstallation(id: installation.id)
    }

    public func commit(_ installation: TranscriberRouterInstallation) async {
        guard let pending = pendingInstallation, pending.id == installation.id else { return }
        pendingInstallation = nil
        await retire(pending.previous)
    }

    public func rollback(_ installation: TranscriberRouterInstallation) async {
        guard let pending = pendingInstallation, pending.id == installation.id else { return }
        pendingInstallation = nil
        active = pending.previous
        descriptorSnapshot.set(pending.previous?.descriptor ?? .unavailable)
        abortTarget.set(pending.previous?.service)
        await retire(pending.candidate)
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
        beginUse(entry.generation)
        do {
            try await entry.service.prepare(language: language)
            await endUse(entry.generation)
        } catch {
            await endUse(entry.generation)
            throw error
        }
    }

    public func preWarm() async {
        guard let entry = active else { return }
        beginUse(entry.generation)
        await entry.service.preWarm()
        await endUse(entry.generation)
    }

    public func tokenCount(_ text: String) async -> Int? {
        guard let entry = active else { return nil }
        beginUse(entry.generation)
        let count = await entry.service.tokenCount(text)
        await endUse(entry.generation)
        return count
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
        beginUse(entry.generation)
        await entry.service.reload()
        await endUse(entry.generation)
    }

    public nonisolated func abortInFlight() {
        abortTarget.get()?.abortInFlight()
    }

    public func stop() async {
        guard !isStopping else {
            await waitForDrain()
            return
        }
        isStopping = true
        abortInFlight()
        var owned = retired
        if let active { owned[active.generation] = active.service }
        if let pending = pendingInstallation {
            if let candidate = pending.candidate {
                owned[candidate.generation] = candidate.service
            }
            if let previous = pending.previous {
                owned[previous.generation] = previous.service
            }
        }
        active = nil
        pendingInstallation = nil
        retired.removeAll()
        latestActivationGeneration = 0
        descriptorSnapshot.set(.unavailable)
        abortTarget.set(nil)
        for (generation, service) in owned {
            if inFlight[generation, default: 0] == 0 {
                inFlight.removeValue(forKey: generation)
                await stopOwnedService(service)
            } else {
                retired[generation] = service
            }
        }
        await waitForDrain()
        isStopping = false
    }

    private func beginUse(_ generation: Int) {
        inFlight[generation, default: 0] += 1
    }

    private func endUse(_ generation: Int) async {
        let remaining = max(0, inFlight[generation, default: 1] - 1)
        if remaining == 0 {
            inFlight.removeValue(forKey: generation)
            if let service = retired.removeValue(forKey: generation) {
                await stopOwnedService(service)
            } else {
                resumeDrainWaitersIfNeeded()
            }
        } else {
            inFlight[generation] = remaining
        }
    }

    private func retire(_ entry: Entry?) async {
        guard let entry else { return }
        if inFlight[entry.generation, default: 0] == 0 {
            inFlight.removeValue(forKey: entry.generation)
            await stopOwnedService(entry.service)
        } else {
            retired[entry.generation] = entry.service
        }
    }

    private func stopOwnedService(_ service: any Transcribing) async {
        pendingStops += 1
        await service.stop()
        pendingStops -= 1
        resumeDrainWaitersIfNeeded()
    }

    private func waitForDrain() async {
        while !retired.isEmpty || pendingStops > 0 {
            await withCheckedContinuation { continuation in
                if retired.isEmpty, pendingStops == 0 {
                    continuation.resume()
                } else {
                    drainWaiters.append(continuation)
                }
            }
        }
    }

    private func resumeDrainWaitersIfNeeded() {
        guard retired.isEmpty, pendingStops == 0 else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
