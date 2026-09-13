import sys

with open("Packages/CNSCore/Sources/CNSCore/ModelManager.swift", "r") as f:
    content = f.read()

old_delete = """    public static func delete(
        _ model: ModelInfo,
        paths: Paths,
        activeModelID: String? = nil
    ) throws {
        guard model.id != activeModelID else {
            throw ModelValidationError.activeModelDeletion(model.id)
        }
        let url = paths.modelFile(for: model)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        removeValidationRecord(modelID: model.id, paths: paths)
    }"""

new_delete = """    public static func delete(
        _ model: ModelInfo,
        paths: Paths,
        registry: ModelArtifactAccessRegistry = .shared
    ) throws {
        let token = try registry.reserveDeletion(modelID: model.id)
        defer { registry.finishDeletion(token) }

        let url = paths.modelFile(for: model)
        
        let modelsDir = paths.modelsDirectory.standardizedFileURL.path + "/"
        let resolved = url.standardizedFileURL
        guard resolved.path.hasPrefix(modelsDir) else {
            throw ModelValidationError.unsafeArtifactPath(url.path)
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        removeValidationRecord(modelID: model.id, paths: paths)
    }"""

content = content.replace(old_delete, new_delete)
with open("Packages/CNSCore/Sources/CNSCore/ModelManager.swift", "w") as f:
    f.write(content)
