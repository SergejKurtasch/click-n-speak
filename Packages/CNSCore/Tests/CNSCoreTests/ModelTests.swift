import CryptoKit
import Foundation
import Testing
@testable import CNSCore

private func testDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func testPaths() -> Paths {
    Paths(mode: .dev, environment: [
        "CNS_DATA_DIR": FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-model-test-\(UUID().uuidString)").path,
    ])
}

private func singleFileModel(
    data: Data,
    checksum: String? = nil,
    expectedSize: Int64? = nil,
    format: ModelArtifact.Format = .ggml,
    id: String = "fixture-model"
) -> ModelInfo {
    let url = URL(string: "https://example.invalid/fixture.bin")!
    let artifact = ModelArtifact(
        relativePath: "fixture.bin",
        downloadURL: url,
        expectedSize: expectedSize ?? Int64(data.count),
        sha256: checksum ?? testDigest(data),
        format: format
    )
    return ModelInfo(
        id: id,
        displayName: "Fixture",
        downloadURL: url,
        fileName: "fixture.bin",
        sizeEstimate: artifact.expectedSize,
        kind: .whisper,
        sourceRevision: "fixture-revision",
        artifacts: [artifact]
    )
}

@Suite("ModelRegistry")
struct ModelRegistryTests {
    @Test("Every model has a complete immutable artifact manifest")
    func manifestsAreComplete() {
        for model in ModelRegistry.whisperModels + ModelRegistry.aiEditorModels {
            #expect(!model.id.isEmpty)
            #expect(model.manifestVersion == ModelRegistry.manifestVersion)
            #expect(model.sourceRevision.count == 40)
            #expect(!model.artifacts.isEmpty)
            #expect(model.sizeEstimate == model.artifacts.reduce(0) { $0 + $1.expectedSize })
            for artifact in model.artifacts {
                #expect(artifact.downloadURL.scheme == "https")
                #expect(artifact.downloadURL.absoluteString.contains(model.sourceRevision))
                #expect(artifact.expectedSize > 0)
                #expect(artifact.sha256.count == 64)
                #expect(artifact.sha256.allSatisfy { $0.isHexDigit })
            }
        }
    }

    @Test("Default IDs and legacy IDs resolve")
    func lookups() {
        #expect(ModelRegistry.whisperModel(id: ModelRegistry.defaultWhisperModelID) != nil)
        #expect(ModelRegistry.aiEditorModel(id: ModelRegistry.defaultAiEditorModelID) != nil)
        #expect(ModelRegistry.model(id: "qwen2.5-1.5b-q4") != nil)
        #expect(ModelRegistry.model(id: "nonexistent") == nil)
        #expect(ModelRegistry.whisperModelByLegacyID("mlx-community/whisper-large-v3-turbo")?.id == "whisper-large-v3-turbo")
        #expect(ModelRegistry.whisperModelByLegacyID("whisper-medium")?.id == "whisper-medium")
    }

    @Test("Registry IDs and installation paths are unique")
    func noDuplicates() {
        let models = ModelRegistry.whisperModels + ModelRegistry.aiEditorModels
        #expect(Set(models.map(\.id)).count == models.count)
        #expect(Set(models.map(\.fileName)).count == models.count)
    }
}

@Suite("ModelManager validation")
struct ModelManagerTests {
    private let validGGML = Data("lmgg-model-fixture".utf8)

    @Test("Presence without cryptographic validation is not installed")
    func unvalidatedPresenceIsRejected() throws {
        let paths = testPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try paths.ensureModelsDirectory()
        let model = singleFileModel(data: validGGML)
        try validGGML.write(to: paths.modelFile(for: model))
        #expect(!ModelManager.isDownloaded(model, paths: paths))
        #expect(ModelManager.cachedValidationState(model, paths: paths) != .valid)
    }

    @Test("Exact size, format and checksum produce a reusable validation cache")
    func validArtifactAndCache() async throws {
        let paths = testPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try paths.ensureModelsDirectory()
        let model = singleFileModel(data: validGGML)
        try validGGML.write(to: paths.modelFile(for: model))
        try await ModelManager.validate(model, paths: paths)
        #expect(ModelManager.isDownloaded(model, paths: paths))

        try Data("lmgg-tampered-data".utf8).write(to: paths.modelFile(for: model))
        #expect(!ModelManager.isDownloaded(model, paths: paths))
    }

    @Test("Truncation, checksum mismatch and wrong format fail independently")
    func failureMatrix() async throws {
        let paths = testPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try paths.ensureModelsDirectory()

        let truncated = singleFileModel(data: validGGML, expectedSize: Int64(validGGML.count + 1))
        try validGGML.write(to: paths.modelFile(for: truncated))
        await #expect(throws: ModelValidationError.self) {
            try await ModelManager.validate(truncated, paths: paths)
        }

        let badChecksum = singleFileModel(data: validGGML, checksum: String(repeating: "0", count: 64))
        try validGGML.write(to: paths.modelFile(for: badChecksum))
        await #expect(throws: ModelValidationError.self) {
            try await ModelManager.validate(badChecksum, paths: paths)
        }

        let wrongFormatData = Data("not-a-ggml-model".utf8)
        let wrongFormat = singleFileModel(data: wrongFormatData)
        try wrongFormatData.write(to: paths.modelFile(for: wrongFormat))
        await #expect(throws: ModelValidationError.self) {
            try await ModelManager.validate(wrongFormat, paths: paths)
        }
    }

    @Test("Validated staging activates atomically")
    func atomicActivation() async throws {
        let paths = testPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try paths.ensureModelsDirectory()
        let model = singleFileModel(data: validGGML)
        let staging = paths.modelsDirectory.appendingPathComponent(".fixture.partial")
        try validGGML.write(to: staging)

        try await ModelManager.validateAndActivate(stagingURL: staging, model: model, paths: paths)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try Data(contentsOf: paths.modelFile(for: model)) == validGGML)
        #expect(ModelManager.isDownloaded(model, paths: paths))
    }

    @Test("Invalid staging never replaces the working installation")
    func invalidStagingPreservesWorkingModel() async throws {
        let paths = testPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try paths.ensureModelsDirectory()
        let model = singleFileModel(data: validGGML)
        let installed = paths.modelFile(for: model)
        let working = Data("existing-working-model".utf8)
        try working.write(to: installed)
        let staging = paths.modelsDirectory.appendingPathComponent(".fixture.partial")
        try Data("corrupt".utf8).write(to: staging)

        await #expect(throws: ModelValidationError.self) {
            try await ModelManager.validateAndActivate(stagingURL: staging, model: model, paths: paths)
        }
        #expect(try Data(contentsOf: installed) == working)
    }

    @Test("Active model deletion is blocked and inactive deletion clears data")
    func deletionProtection() throws {
        let paths = testPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try paths.ensureModelsDirectory()
        let model = singleFileModel(data: validGGML)
        try validGGML.write(to: paths.modelFile(for: model))

        #expect(throws: ModelValidationError.activeModelDeletion(model.id)) {
            try ModelManager.delete(model, paths: paths, activeModelID: model.id)
        }
        #expect(FileManager.default.fileExists(atPath: paths.modelFile(for: model).path))
        try ModelManager.delete(model, paths: paths, activeModelID: "another-model")
        #expect(!FileManager.default.fileExists(atPath: paths.modelFile(for: model).path))
    }

    @Test("Disk-space preflight includes its safety margin")
    func diskSpacePreflight() throws {
        try ModelManager.checkDiskCapacity(requiredBytes: 100, availableBytes: 200, safetyMargin: 50)
        #expect(throws: ModelValidationError.insufficientDiskSpace(required: 150, available: 149)) {
            try ModelManager.checkDiskCapacity(requiredBytes: 100, availableBytes: 149, safetyMargin: 50)
        }
    }

    @Test("Resume requires stable source identity and an HTTP validator")
    func resumePolicy() {
        let model = singleFileModel(data: validGGML)
        let artifact = model.artifacts[0]
        let saved = DownloadResumeMetadata(
            modelID: model.id,
            manifestVersion: model.manifestVersion,
            sourceRevision: model.sourceRevision,
            artifactPath: artifact.relativePath,
            downloadURL: artifact.downloadURL,
            expectedSize: artifact.expectedSize,
            sha256: artifact.sha256,
            etag: "stable-etag",
            lastModified: nil
        )
        let matching = RemoteArtifactMetadata(
            etag: "stable-etag",
            lastModified: nil,
            acceptsByteRanges: true,
            contentLength: artifact.expectedSize
        )
        #expect(ModelResumePolicy.canResume(saved: saved, model: model, artifact: artifact, remote: matching))

        let changed = RemoteArtifactMetadata(
            etag: "changed-etag",
            lastModified: nil,
            acceptsByteRanges: true,
            contentLength: artifact.expectedSize
        )
        #expect(!ModelResumePolicy.canResume(saved: saved, model: model, artifact: artifact, remote: changed))

        let noRange = RemoteArtifactMetadata(
            etag: "stable-etag",
            lastModified: nil,
            acceptsByteRanges: false,
            contentLength: artifact.expectedSize
        )
        #expect(!ModelResumePolicy.canResume(saved: saved, model: model, artifact: artifact, remote: noRange))

        #expect(ModelResumePolicy.responseAllowsResume(
            statusCode: 206,
            contentRange: "bytes 5-17/18",
            offset: 5,
            expectedSize: 18,
            responseLength: 13
        ))
        #expect(!ModelResumePolicy.responseAllowsResume(
            statusCode: 200,
            contentRange: nil,
            offset: 5,
            expectedSize: 18,
            responseLength: 18
        ))
    }

    @Test("Disk usage counts regular model files")
    func diskUsage() throws {
        let paths = testPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try paths.ensureModelsDirectory()
        try Data(repeating: 1, count: 1_000).write(to: paths.modelsDirectory.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 2_000).write(to: paths.modelsDirectory.appendingPathComponent("b.bin"))
        #expect(ModelManager.diskUsage(paths: paths) >= 3_000)
        #expect(!ModelManager.formattedSize(1_500_000_000).isEmpty)
    }
}

@MainActor
@Suite("ModelDownloader durable state")
struct ModelDownloaderPersistenceTests {
    @Test("A persisted streamed partial is resumable after a new downloader is created")
    func relaunchRestoresResumeState() throws {
        let paths = testPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try paths.ensureModelsDirectory()
        let data = Data("lmgg-model-fixture".utf8)
        let model = singleFileModel(data: data)
        let artifact = model.artifacts[0]
        let directory = paths.modelsDirectory
            .appendingPathComponent(".downloads", isDirectory: true)
            .appendingPathComponent(model.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(data.prefix(5)).write(to: directory.appendingPathComponent("artifact.partial"))
        let metadata = DownloadResumeMetadata(
            modelID: model.id,
            manifestVersion: model.manifestVersion,
            sourceRevision: model.sourceRevision,
            artifactPath: artifact.relativePath,
            downloadURL: artifact.downloadURL,
            expectedSize: artifact.expectedSize,
            sha256: artifact.sha256,
            etag: "stable",
            lastModified: nil
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))

        let downloader = ModelDownloader(paths: paths, diskCapacity: { _ in 1_000_000_000 })
        #expect(downloader.canResume(model: model))
    }
}

@Suite("Paths — models")
struct PathsModelTests {
    @Test("All model paths remain inside the injected data directory")
    func pathsRemainInjected() throws {
        let paths = testPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        #expect(paths.modelsDirectory.path.hasPrefix(paths.dataDirectory.path))
        #expect(paths.whisperModelFile.deletingLastPathComponent() == paths.modelsDirectory)
        #expect(paths.aiEditorModelFile.deletingLastPathComponent() == paths.modelsDirectory)
        try paths.ensureModelsDirectory()
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.modelsDirectory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
