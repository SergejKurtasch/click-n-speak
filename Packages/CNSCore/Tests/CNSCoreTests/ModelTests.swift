import Testing
import Foundation
@testable import CNSCore

@Suite("ModelRegistry")
struct ModelRegistryTests {
    @Test("All whisper models have valid URLs and non-empty fields")
    func whisperModelsValid() {
        for model in ModelRegistry.whisperModels {
            #expect(!model.id.isEmpty)
            #expect(!model.displayName.isEmpty)
            #expect(!model.fileName.isEmpty)
            #expect(model.sizeEstimate > 0)
            #expect(model.kind == .whisper)
            #expect(model.downloadURL.scheme == "https")
            #expect(model.downloadURL.host?.contains("huggingface") == true)
        }
    }

    @Test("All AI editor models have valid URLs and non-empty fields")
    func aiEditorModelsValid() {
        for model in ModelRegistry.aiEditorModels {
            #expect(!model.id.isEmpty)
            #expect(!model.displayName.isEmpty)
            #expect(!model.fileName.isEmpty)
            #expect(model.sizeEstimate > 0)
            #expect(model.kind == .aiEditor)
            #expect(model.downloadURL.scheme == "https")
        }
    }

    @Test("Default IDs resolve to known models")
    func defaultsResolve() {
        #expect(ModelRegistry.whisperModel(id: ModelRegistry.defaultWhisperModelID) != nil)
        #expect(ModelRegistry.aiEditorModel(id: ModelRegistry.defaultAiEditorModelID) != nil)
    }

    @Test("model(id:) finds across both registries")
    func crossRegistryLookup() {
        #expect(ModelRegistry.model(id: "whisper-large-v3-turbo") != nil)
        #expect(ModelRegistry.model(id: "qwen2.5-1.5b-q4") != nil)
        #expect(ModelRegistry.model(id: "nonexistent") == nil)
    }

    @Test("Legacy MLX IDs map correctly")
    func legacyIDMapping() {
        let turbo = ModelRegistry.whisperModelByLegacyID("mlx-community/whisper-large-v3-turbo")
        #expect(turbo?.id == "whisper-large-v3-turbo")

        let large = ModelRegistry.whisperModelByLegacyID("mlx-community/whisper-large-v3-mlx")
        #expect(large?.id == "whisper-large-v3")

        let small = ModelRegistry.whisperModelByLegacyID("mlx-community/whisper-small-mlx")
        #expect(small?.id == "whisper-small")

        // Direct ID also works
        let direct = ModelRegistry.whisperModelByLegacyID("whisper-medium")
        #expect(direct?.id == "whisper-medium")

        // Unknown returns nil
        #expect(ModelRegistry.whisperModelByLegacyID("nonexistent") == nil)
    }

    @Test("No duplicate model IDs")
    func noDuplicateIDs() {
        let allIDs = ModelRegistry.whisperModels.map(\.id) + ModelRegistry.aiEditorModels.map(\.id)
        #expect(Set(allIDs).count == allIDs.count, "Duplicate model IDs found")
    }

    @Test("No duplicate file names")
    func noDuplicateFileNames() {
        let allNames = ModelRegistry.whisperModels.map(\.fileName) + ModelRegistry.aiEditorModels.map(\.fileName)
        #expect(Set(allNames).count == allNames.count, "Duplicate file names found")
    }
}

@Suite("ModelManager")
struct ModelManagerTests {
    private func makeTempPaths() -> Paths {
        let env = ["CNS_DATA_DIR": FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-test-\(UUID().uuidString)").path]
        return Paths(mode: .dev, environment: env)
    }

    @Test("isDownloaded returns false for missing file")
    func missingFile() {
        let paths = makeTempPaths()
        let model = ModelRegistry.whisperModels[0]
        #expect(!ModelManager.isDownloaded(model, paths: paths))
    }

    @Test("isDownloaded returns false for tiny file (< 1MB)")
    func tinyFile() throws {
        let paths = makeTempPaths()
        try paths.ensureModelsDirectory()
        let model = ModelRegistry.whisperModels[0]
        let url = paths.modelFile(for: model)
        // Write a 100-byte file — should be rejected as incomplete.
        try Data(repeating: 0x42, count: 100).write(to: url)
        #expect(!ModelManager.isDownloaded(model, paths: paths))
        try? FileManager.default.removeItem(at: paths.dataDirectory)
    }

    @Test("isDownloaded returns true for file > 1MB")
    func validFile() throws {
        let paths = makeTempPaths()
        try paths.ensureModelsDirectory()
        let model = ModelRegistry.whisperModels[0]
        let url = paths.modelFile(for: model)
        // Write a 2MB file.
        try Data(repeating: 0xAB, count: 2_000_000).write(to: url)
        #expect(ModelManager.isDownloaded(model, paths: paths))
        try? FileManager.default.removeItem(at: paths.dataDirectory)
    }

    @Test("delete removes the file")
    func deleteRemoves() throws {
        let paths = makeTempPaths()
        try paths.ensureModelsDirectory()
        let model = ModelRegistry.whisperModels[0]
        let url = paths.modelFile(for: model)
        try Data(repeating: 0xCD, count: 2_000_000).write(to: url)
        #expect(ModelManager.isDownloaded(model, paths: paths))
        try ModelManager.delete(model, paths: paths)
        #expect(!ModelManager.isDownloaded(model, paths: paths))
        try? FileManager.default.removeItem(at: paths.dataDirectory)
    }

    @Test("delete is a no-op for missing files")
    func deleteNoOp() throws {
        let paths = makeTempPaths()
        let model = ModelRegistry.whisperModels[0]
        // Should not throw.
        try ModelManager.delete(model, paths: paths)
    }

    @Test("diskUsage sums all files in models directory")
    func diskUsage() throws {
        let paths = makeTempPaths()
        try paths.ensureModelsDirectory()
        let dir = paths.modelsDirectory
        try Data(repeating: 0x01, count: 1000).write(to: dir.appendingPathComponent("a.bin"))
        try Data(repeating: 0x02, count: 2000).write(to: dir.appendingPathComponent("b.bin"))
        let usage = ModelManager.diskUsage(paths: paths)
        #expect(usage >= 3000)
        try? FileManager.default.removeItem(at: paths.dataDirectory)
    }

    @Test("formattedSize produces human-readable strings")
    func formattedSize() {
        let small = ModelManager.formattedSize(1024)
        #expect(small.contains("KB") || small.contains("kB") || small.contains("bytes"))
        let large = ModelManager.formattedSize(1_500_000_000)
        #expect(large.contains("GB"))
    }
}

@Suite("Paths — models")
struct PathsModelTests {
    @Test("modelsDirectory is inside dataDirectory")
    func modelsDir() {
        let paths = Paths(mode: .dev, environment: [:])
        #expect(paths.modelsDirectory.path.hasPrefix(paths.dataDirectory.path))
        #expect(paths.modelsDirectory.lastPathComponent == "models")
    }

    @Test("modelFile resolves to modelsDirectory + fileName")
    func modelFile() {
        let paths = Paths(mode: .dev, environment: [:])
        let model = ModelRegistry.whisperModels[0]
        let url = paths.modelFile(for: model)
        #expect(url.lastPathComponent == model.fileName)
        #expect(url.deletingLastPathComponent().path == paths.modelsDirectory.path)
    }

    @Test("whisperModelFile and aiEditorModelFile are in modelsDirectory")
    func defaultModelFiles() {
        let paths = Paths(mode: .dev, environment: [:])
        #expect(paths.whisperModelFile.deletingLastPathComponent().path == paths.modelsDirectory.path)
        #expect(paths.aiEditorModelFile.deletingLastPathComponent().path == paths.modelsDirectory.path)
    }

    @Test("ensureModelsDirectory creates the directory")
    func ensureCreates() throws {
        let env = ["CNS_DATA_DIR": FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-model-\(UUID().uuidString)").path]
        let paths = Paths(mode: .dev, environment: env)
        #expect(!FileManager.default.fileExists(atPath: paths.modelsDirectory.path))
        try paths.ensureModelsDirectory()
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.modelsDirectory.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        try? FileManager.default.removeItem(at: paths.dataDirectory)
    }
}
