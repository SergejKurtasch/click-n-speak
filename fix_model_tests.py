import sys

with open("Packages/CNSCore/Tests/CNSCoreTests/ModelTests.swift", "r") as f:
    content = f.read()

old_test = """    @Test("delete refuses to delete active model")
    func deleteActiveModel() throws {
        let model = ModelRegistry.whisperModel(id: ModelRegistry.defaultWhisperModelID)!
        let paths = try Paths(appSupport: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        try paths.ensureModelsDirectory()
        try Data([0, 1, 2]).write(to: paths.modelFile(for: model))

        #expect(throws: ModelValidationError.activeModelDeletion(model.id)) {
            try ModelManager.delete(model, paths: paths)
        }
        #expect(FileManager.default.fileExists(atPath: paths.modelFile(for: model).path))
        try ModelManager.delete(model, paths: paths)
        #expect(!FileManager.default.fileExists(atPath: paths.modelFile(for: model).path))
    }"""

old_test2 = """    @Test("delete refuses to delete active model")
    func deleteActiveModel() throws {
        let paths = try Paths(appSupport: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        try paths.ensureModelsDirectory()
        let model = singleFileModel(data: validGGML)
        try validGGML.write(to: paths.modelFile(for: model))

        #expect(throws: ModelValidationError.activeModelDeletion(model.id)) {
            try ModelManager.delete(model, paths: paths)
        }
        #expect(FileManager.default.fileExists(atPath: paths.modelFile(for: model).path))
        try ModelManager.delete(model, paths: paths)
        #expect(!FileManager.default.fileExists(atPath: paths.modelFile(for: model).path))
    }"""

new_test = """    @Test("delete refuses to delete active model")
    func deleteActiveModel() throws {
        let paths = try Paths(appSupport: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        try paths.ensureModelsDirectory()
        let model = singleFileModel(data: validGGML)
        try validGGML.write(to: paths.modelFile(for: model))

        let token = try ModelArtifactAccessRegistry.shared.acquireUse(modelID: model.id, reason: .preparation(generation: 1))
        #expect(throws: ModelArtifactAccessError.inUse(modelID: model.id)) {
            try ModelManager.delete(model, paths: paths)
        }
        #expect(FileManager.default.fileExists(atPath: paths.modelFile(for: model).path))
        
        ModelArtifactAccessRegistry.shared.releaseUse(token)
        try ModelManager.delete(model, paths: paths)
        #expect(!FileManager.default.fileExists(atPath: paths.modelFile(for: model).path))
    }"""

if old_test in content:
    content = content.replace(old_test, new_test)
elif old_test2 in content:
    content = content.replace(old_test2, new_test)
else:
    print("Could not find the target string!")

with open("Packages/CNSCore/Tests/CNSCoreTests/ModelTests.swift", "w") as f:
    f.write(content)
