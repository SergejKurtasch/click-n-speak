import CNSCore
import Foundation

/// Stable editor endpoint. A runtime swap never stops the service still owned
/// by an in-flight realtime or file request.
public actor AiEditorRouter: AiEditing {
    private struct Entry: Sendable {
        let generation: Int
        let service: any AiEditing
        let descriptor: AiEditorDescriptor
    }

    private var active: Entry?
    private var nextGeneration = 0
    private var latestActivationGeneration = 0
    private var inFlight: [Int: Int] = [:]
    private var retired: [Int: any AiEditing] = [:]
    private let descriptorSnapshot = LockedSnapshot(AiEditorDescriptor.disabled)
    private let readinessSnapshot = LockedSnapshot(false)

    public init() {}

    public nonisolated var isReady: Bool { readinessSnapshot.get() }
    public nonisolated var descriptor: AiEditorDescriptor { descriptorSnapshot.get() }
    public nonisolated var currentDescriptorSnapshot: AiEditorDescriptor { descriptorSnapshot.get() }

    @discardableResult
    public func install(
        _ service: (any AiEditing)?,
        descriptor: AiEditorDescriptor,
        activationGeneration: Int? = nil
    ) -> Bool {
        let requestedGeneration = activationGeneration ?? (latestActivationGeneration + 1)
        guard requestedGeneration > latestActivationGeneration else { return false }
        latestActivationGeneration = requestedGeneration
        nextGeneration += 1
        let previous = active
        if let service {
            active = Entry(generation: nextGeneration, service: service, descriptor: descriptor)
            descriptorSnapshot.set(descriptor)
            readinessSnapshot.set(service.isReady)
        } else {
            active = nil
            descriptorSnapshot.set(.disabled)
            readinessSnapshot.set(false)
        }

        if let previous {
            if inFlight[previous.generation, default: 0] == 0 {
                Task { await previous.service.stop() }
            } else {
                retired[previous.generation] = previous.service
            }
        }
        return true
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
        let services = ([active?.service].compactMap { $0 } + Array(retired.values))
        active = nil
        retired.removeAll()
        latestActivationGeneration = 0
        descriptorSnapshot.set(.disabled)
        readinessSnapshot.set(false)
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
