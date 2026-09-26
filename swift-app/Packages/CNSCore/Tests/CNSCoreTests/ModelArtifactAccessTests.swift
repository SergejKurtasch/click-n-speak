import Testing
import Foundation
@testable import CNSCore

@Suite("Model Artifact Access")
struct ModelArtifactAccessTests {
    @Test("Registry isolation and concurrent access")
    func registryConcurrency() async throws {
        let registry = ModelArtifactAccessRegistry()
        let useA = ModelArtifactUse.preparation(generation: 1)
        let useB = ModelArtifactUse.fileTranscription(jobID: UUID())
        
        let tokenA = try registry.acquireUse(modelID: "model-1", reason: useA)
        let tokenB = try registry.acquireUse(modelID: "model-1", reason: useB)
        
        #expect(registry.snapshotReasons(for: "model-1") == [useA, useB])
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let token = try? registry.acquireUse(modelID: "model-2", reason: .preparation(generation: i))
                    if let token = token {
                        registry.releaseUse(token)
                    }
                }
            }
        }
        
        registry.releaseUse(tokenA)
        registry.releaseUse(tokenB)
        #expect(registry.snapshotReasons(for: "model-1").isEmpty)
    }
    
    @Test("Reservation prevents new uses and throws inUse if active")
    func reservationThrows() async throws {
        let registry = ModelArtifactAccessRegistry()
        let token = try registry.acquireUse(modelID: "model-1", reason: .preparation(generation: 1))
        
        #expect(throws: ModelArtifactAccessError.inUse(modelID: "model-1", reasons: [.preparation(generation: 1)])) {
            try registry.reserveDeletion(modelID: "model-1")
        }
        
        registry.releaseUse(token)
        
        let delToken = try registry.reserveDeletion(modelID: "model-1")
        #expect(registry.isDeletionInProgress(for: "model-1"))
        
        #expect(throws: ModelArtifactAccessError.deletionInProgress(modelID: "model-1")) {
            try registry.acquireUse(modelID: "model-1", reason: .preparation(generation: 2))
        }
        
        #expect(throws: ModelArtifactAccessError.deletionInProgress(modelID: "model-1")) {
            try registry.reserveDeletion(modelID: "model-1")
        }
        
        registry.finishDeletion(delToken)
        #expect(!registry.isDeletionInProgress(for: "model-1"))
        
        // Allowed again
        let newToken = try registry.acquireUse(modelID: "model-1", reason: .preparation(generation: 3))
        registry.releaseUse(newToken)
    }
    
    @Test("Invalid finish tokens do not disrupt the state")
    func staleFinishToken() async throws {
        let registry = ModelArtifactAccessRegistry()
        let token = try registry.reserveDeletion(modelID: "model-1")
        
        registry.finishDeletion(UUID())
        #expect(registry.isDeletionInProgress(for: "model-1"))
        
        registry.finishDeletion(token)
        #expect(!registry.isDeletionInProgress(for: "model-1"))
        
        // Double finish is safe
        registry.finishDeletion(token)
    }
}
