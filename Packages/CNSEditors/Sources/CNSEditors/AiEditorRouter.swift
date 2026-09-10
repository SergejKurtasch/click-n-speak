import CNSCore
import Foundation

public struct AiEditorRouterInstallation: Sendable, Equatable {
    fileprivate let id: Int
}

/// Stable editor endpoint. A runtime swap never stops the service still owned
/// by an in-flight realtime or file request.
public actor AiEditorRouter: AiEditing {
    private struct Entry: Sendable {
        let generation: Int
        let service: any AiEditing
        let descriptor: AiEditorDescriptor
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
    private var retired: [Int: any AiEditing] = [:]
    private var pendingStops = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var isStopping = false
    private let descriptorSnapshot = LockedSnapshot(AiEditorDescriptor.disabled)
    private let readinessSnapshot = LockedSnapshot(false)

    public init() {}

    public nonisolated var isReady: Bool { readinessSnapshot.get() }
    public nonisolated var descriptor: AiEditorDescriptor { descriptorSnapshot.get() }
    public nonisolated var currentDescriptorSnapshot: AiEditorDescriptor { descriptorSnapshot.get() }
    var trackedInFlightGenerationCount: Int { inFlight.count }

    @discardableResult
    public func install(
        _ service: (any AiEditing)?,
        descriptor: AiEditorDescriptor,
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

    /// Stage an editor publication while retaining the previous editor for a
    /// coordinated multi-router commit or rollback.
    public func stageInstall(
        _ service: (any AiEditing)?,
        descriptor: AiEditorDescriptor,
        activationGeneration: Int? = nil
    ) -> AiEditorRouterInstallation? {
        guard !isStopping, pendingInstallation == nil else { return nil }
        let requestedGeneration = activationGeneration ?? (latestActivationGeneration + 1)
        guard requestedGeneration > latestActivationGeneration else { return nil }
        latestActivationGeneration = requestedGeneration
        nextGeneration += 1
        nextInstallationID += 1
        let previous = active
        let candidate: Entry?
        if let service {
            candidate = Entry(generation: nextGeneration, service: service, descriptor: descriptor)
            active = candidate
            descriptorSnapshot.set(descriptor)
            readinessSnapshot.set(service.isReady)
        } else {
            candidate = nil
            active = nil
            descriptorSnapshot.set(.disabled)
            readinessSnapshot.set(false)
        }
        let installation = PendingInstallation(
            id: nextInstallationID,
            candidate: candidate,
            previous: previous
        )
        pendingInstallation = installation
        return AiEditorRouterInstallation(id: installation.id)
    }

    public func commit(_ installation: AiEditorRouterInstallation) async {
        guard let pending = pendingInstallation, pending.id == installation.id else { return }
        pendingInstallation = nil
        await retire(pending.previous)
    }

    public func rollback(_ installation: AiEditorRouterInstallation) async {
        guard let pending = pendingInstallation, pending.id == installation.id else { return }
        pendingInstallation = nil
        active = pending.previous
        descriptorSnapshot.set(pending.previous?.descriptor ?? .disabled)
        readinessSnapshot.set(pending.previous?.service.isReady ?? false)
        await retire(pending.candidate)
    }

    public func refine(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        guard let entry = active else { return RefineResult(text: text, status: .disabled) }
        beginUse(entry.generation)
        let result = await entry.service.refine(
            text: text,
            languages: languages,
            knownTerms: knownTerms,
            misrecognitions: misrecognitions
        )
        await endUse(entry.generation)
        return result
    }

    public func refineFileText(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        guard let entry = active else { return RefineResult(text: text, status: .disabled) }
        beginUse(entry.generation)
        let result = await entry.service.refineFileText(
            text: text,
            languages: languages,
            knownTerms: knownTerms,
            misrecognitions: misrecognitions
        )
        await endUse(entry.generation)
        return result
    }

    public func stop() async {
        guard !isStopping else {
            await waitForDrain()
            return
        }
        isStopping = true
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
        descriptorSnapshot.set(.disabled)
        readinessSnapshot.set(false)
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

    private func stopOwnedService(_ service: any AiEditing) async {
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
