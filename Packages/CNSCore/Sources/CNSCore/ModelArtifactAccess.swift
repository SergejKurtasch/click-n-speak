import Foundation

public enum ModelArtifactUse: Hashable, Sendable {
    case activeRuntime(descriptor: RuntimeDescriptor)
    case fileTranscription(jobID: UUID)
    case downloading(taskID: UUID)
    case preparation(generation: Int)
}

public enum ModelArtifactAccessError: Error, Sendable, Equatable {
    case inUse(modelID: String, reasons: Set<ModelArtifactUse>)
    case deletionInProgress(modelID: String)
}

public final class ModelArtifactAccessRegistry: @unchecked Sendable {
    public static let shared = ModelArtifactAccessRegistry()
    
    private let lock = NSLock()
    
    private struct UseRecord {
        let modelID: String
        let reason: ModelArtifactUse
    }
    
    private var uses: [UUID: UseRecord] = [:]
    private var deleting: [String: UUID] = [:]
    
    public init() {}
    
    public func acquireUse(modelID: String, reason: ModelArtifactUse) throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        
        if deleting[modelID] != nil {
            throw ModelArtifactAccessError.deletionInProgress(modelID: modelID)
        }
        
        let token = UUID()
        uses[token] = UseRecord(modelID: modelID, reason: reason)
        return token
    }
    
    public func releaseUse(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        uses.removeValue(forKey: token)
    }
    
    public func reserveDeletion(modelID: String) throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        
        if deleting[modelID] != nil {
            throw ModelArtifactAccessError.deletionInProgress(modelID: modelID)
        }
        
        let activeUses = uses.values.filter { $0.modelID == modelID }.map { $0.reason }
        if !activeUses.isEmpty {
            throw ModelArtifactAccessError.inUse(modelID: modelID, reasons: Set(activeUses))
        }
        
        let token = UUID()
        deleting[modelID] = token
        return token
    }
    
    public func finishDeletion(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if let key = deleting.first(where: { $0.value == token })?.key {
            deleting.removeValue(forKey: key)
        }
    }
    
    public func updateReason(_ token: UUID, reason: ModelArtifactUse) {
        lock.lock()
        defer { lock.unlock() }
        if let record = uses[token] {
            uses[token] = UseRecord(modelID: record.modelID, reason: reason)
        }
    }
    
    public func snapshotReasons(for modelID: String) -> Set<ModelArtifactUse> {
        lock.lock()
        defer { lock.unlock() }
        return Set(uses.values.filter { $0.modelID == modelID }.map { $0.reason })
    }
    
    public func isDeletionInProgress(for modelID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deleting[modelID] != nil
    }
}
