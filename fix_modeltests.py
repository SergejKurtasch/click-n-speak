import sys

with open("Packages/CNSCore/Tests/CNSCoreTests/ModelTests.swift", "r") as f:
    content = f.read()

# Instead of testing `activeModelID`, we now test that `inUse` is thrown if registry has a token!

old_test = """    @Test("Model manager prevents deletion of the active model")
    func preventActiveModelDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = Paths(baseDirectory: root)
        let model = ModelInfo(id: "active-model", backend: "local", storage: .singleFile, artifacts: [], manifestVersion: 1)
        
        #expect(throws: ModelValidationError.activeModelDeletion("active-model")) {
            try ModelManager.delete(model, paths: paths, activeModelID: model.id)
        }
        
        // Allowed if active is different
        try ModelManager.delete(model, paths: paths, activeModelID: "another-model")
    }"""

new_test = """    @Test("Model manager prevents deletion of an active model")
    func preventActiveModelDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = Paths(baseDirectory: root)
        let registry = ModelArtifactAccessRegistry()
        let model = ModelInfo(id: "active-model", backend: "local", storage: .singleFile, artifacts: [], manifestVersion: 1)
        
        let token = try registry.acquireUse(modelID: model.id, reason: .preparation(generation: 1))
        
        #expect(throws: ModelArtifactAccessError.inUse(modelID: "active-model", reasons: [.preparation(generation: 1)])) {
            try ModelManager.delete(model, paths: paths, registry: registry)
        }
        
        registry.releaseUse(token)
        
        // Allowed if not in use
        try ModelManager.delete(model, paths: paths, registry: registry)
    }"""

content = content.replace(old_test, new_test)

with open("Packages/CNSCore/Tests/CNSCoreTests/ModelTests.swift", "w") as f:
    f.write(content)
