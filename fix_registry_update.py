import sys

with open("Packages/CNSCore/Sources/CNSCore/ModelArtifactAccess.swift", "r") as f:
    content = f.read()

update_func = """    public func updateReason(_ token: UUID, reason: ModelArtifactUse) {
        lock.lock()
        defer { lock.unlock() }
        if let record = uses[token] {
            uses[token] = UseRecord(modelID: record.modelID, reason: reason)
        }
    }
    
    public func snapshotReasons(for modelID: String) -> Set<ModelArtifactUse> {"""

content = content.replace("    public func snapshotReasons(for modelID: String) -> Set<ModelArtifactUse> {", update_func)

with open("Packages/CNSCore/Sources/CNSCore/ModelArtifactAccess.swift", "w") as f:
    f.write(content)
