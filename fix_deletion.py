import sys

with open("Packages/CNSCore/Tests/CNSCoreTests/ModelTests.swift", "r") as f:
    content = f.read()

target = """    @Test("Active model deletion is blocked and inactive deletion clears data")
    func deletionProtection() throws {"""

import re
# Find the start of the function
start_idx = content.find(target)
if start_idx != -1:
    # Find the end of the function (the first } that is indented 4 spaces)
    end_idx = content.find("    }\n", start_idx) + 6
    
    new_func = """    @Test("Active model deletion is blocked and inactive deletion clears data")
    func deletionProtection() throws {
        let paths = testPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
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
    }\n"""
    
    content = content[:start_idx] + new_func + content[end_idx:]
    with open("Packages/CNSCore/Tests/CNSCoreTests/ModelTests.swift", "w") as f:
        f.write(content)
else:
    print("Could not find function")
