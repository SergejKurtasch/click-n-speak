import CryptoKit
import Foundation
import Testing
@testable import CNSCore

func testDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func testPaths() -> Paths {
    Paths(mode: .dev, environment: [
        "CNS_DATA_DIR": FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-model-test-\(UUID().uuidString)").path,
    ])
}

func singleFileModel(
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

@Suite("Model transfer response policy")
struct ModelTransferPolicyTests {
    @Test("Only a real resume rejection permits one fresh restart")
    func resumeRestartBoundary() {
        let policy = ModelTransferPolicy(attempt: 1, maxAttempts: 3)
        #expect(policy.responseAction(
            statusCode: 200,
            offset: 5,
            contentRange: nil,
            responseLength: 18,
            expectedSize: 18,
            didRestartFresh: false
        ) == .restartFresh)
        #expect(policy.responseAction(
            statusCode: 200,
            offset: 0,
            contentRange: nil,
            responseLength: 18,
            expectedSize: 18,
            didRestartFresh: true
        ) == .accept)
        #expect(policy.responseAction(
            statusCode: 206,
            offset: 0,
            contentRange: "bytes 0-17/18",
            responseLength: 18,
            expectedSize: 18,
            didRestartFresh: true
        ) == .fail)
    }

    @Test("Transient HTTP failures retry at most three attempts with bounded delay")
    func retryBoundary() {
        #expect(ModelTransferPolicy(attempt: 1, maxAttempts: 3)
            .failureOrBoundedRetry(500) == .retry(after: 1))
        #expect(ModelTransferPolicy(attempt: 2, maxAttempts: 3)
            .failureOrBoundedRetry(429) == .retry(after: 2))
        #expect(ModelTransferPolicy(attempt: 3, maxAttempts: 3)
            .failureOrBoundedRetry(503) == .fail)
        #expect(ModelTransferPolicy(attempt: 1, maxAttempts: 3, retryAfter: 90)
            .failureOrBoundedRetry(429) == .retry(after: 30))
        for status in [401, 403, 404, 416] {
            #expect(ModelTransferPolicy(attempt: 1, maxAttempts: 3)
                .failureOrBoundedRetry(status) == .fail)
        }
    }

    @Test("Content range validation covers every bound and length")
    func contentRangeValidation() {
        let policy = ModelTransferPolicy(attempt: 1, maxAttempts: 3)
        #expect(policy.responseAction(
            statusCode: 206,
            offset: 5,
            contentRange: "bytes 5-17/18",
            responseLength: 13,
            expectedSize: 18,
            didRestartFresh: false
        ) == .accept)
        for range in ["bytes 4-17/18", "bytes 5-4/18", "bytes 5-16/18", "bytes 5-17/19", "garbage"] {
            #expect(policy.responseAction(
                statusCode: 206,
                offset: 5,
                contentRange: range,
                responseLength: 13,
                expectedSize: 18,
                didRestartFresh: false
            ) == .fail)
        }
        for length: Int64? in [0, 12, 14] {
            #expect(policy.responseAction(
                statusCode: 206,
                offset: 5,
                contentRange: "bytes 5-17/18",
                responseLength: length,
                expectedSize: 18,
                didRestartFresh: false
            ) == .fail)
        }
        #expect(policy.responseAction(
            statusCode: 200,
            offset: 0,
            contentRange: nil,
            responseLength: nil,
            expectedSize: 18,
            didRestartFresh: false
        ) == .accept)
        #expect(policy.responseAction(
            statusCode: 200,
            offset: 0,
            contentRange: nil,
            responseLength: -1,
            expectedSize: 18,
            didRestartFresh: false
        ) == .fail)
    }
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

    @Test("A failed quarantine move preserves the original artifact")
    func quarantineFailurePreservesArtifact() throws {
        let paths = testPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try paths.ensureModelsDirectory()
        let model = singleFileModel(data: validGGML)
        let installed = paths.modelFile(for: model)
        try validGGML.write(to: installed)
        try Data("blocking-file".utf8).write(
            to: paths.modelsDirectory.appendingPathComponent(".quarantine")
        )

        #expect(throws: (any Error).self) {
            try ModelManager.quarantineInvalidArtifact(at: installed, model: model, paths: paths)
        }
        #expect(try Data(contentsOf: installed) == validGGML)
    }

    @Test("A failed backup restore keeps a usable destination and the previous model")
    func failedRollbackPreservesBothArtifacts() async throws {
        let paths = testPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try paths.ensureModelsDirectory()
        let model = singleFileModel(data: validGGML)
        let installed = paths.modelFile(for: model)
        let previous = Data("lmgg-previous-model".utf8)
        try previous.write(to: installed)
        let staging = paths.modelsDirectory.appendingPathComponent(".fixture.partial")
        try validGGML.write(to: staging)
        await #expect(throws: ModelActivationError.self) {
            try await ModelManager.validateAndActivate(
                stagingURL: staging,
                model: model,
                paths: paths,
                moveItem: { source, destination in
                    if source.lastPathComponent.contains(".previous-") {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    try FileManager.default.moveItem(at: source, to: destination)
                },
                writeValidationCache: { _, _ in throw CocoaError(.fileWriteNoPermission) }
            )
        }

        #expect(try Data(contentsOf: installed) == validGGML)
        let backups = try FileManager.default.contentsOfDirectory(
            at: paths.modelsDirectory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".previous-") }
        #expect(backups.count == 1)
        if let backup = backups.first {
            #expect(try Data(contentsOf: backup) == previous)
        }
    }

    @Test("A validation cache write failure restores the previous installation")
    func failedCacheWriteRestoresWorkingModel() async throws {
        let paths = testPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try paths.ensureModelsDirectory()
        let model = singleFileModel(data: validGGML)
        let installed = paths.modelFile(for: model)
        let previous = Data("lmgg-previous-model".utf8)
        try previous.write(to: installed)
        let staging = paths.modelsDirectory.appendingPathComponent(".fixture.partial")
        try validGGML.write(to: staging)

        await #expect(throws: CocoaError.self) {
            try await ModelManager.validateAndActivate(
                stagingURL: staging,
                model: model,
                paths: paths,
                moveItem: { source, destination in
                    try FileManager.default.moveItem(at: source, to: destination)
                },
                writeValidationCache: { _, _ in throw CocoaError(.fileWriteNoPermission) }
            )
        }

        #expect(try Data(contentsOf: installed) == previous)
        #expect(try Data(contentsOf: staging) == validGGML)
    }

    @Test("Active model deletion is blocked and inactive deletion clears data")
    func deletionProtection() throws {
        let paths = testPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try paths.ensureModelsDirectory()
        let model = singleFileModel(data: validGGML)
        try validGGML.write(to: paths.modelFile(for: model))

        let token = try ModelArtifactAccessRegistry.shared.acquireUse(modelID: model.id, reason: .preparation(generation: 1))
        #expect(throws: ModelArtifactAccessError.inUse(modelID: model.id, reasons: [.preparation(generation: 1)])) {
            try ModelManager.delete(model, paths: paths)
        }
        #expect(FileManager.default.fileExists(atPath: paths.modelFile(for: model).path))
        
        ModelArtifactAccessRegistry.shared.releaseUse(token)
        try ModelManager.delete(model, paths: paths)
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
    @Test("A deletion reservation reports download refusal to the UI")
    func reservationFailureIsVisible() throws {
        let paths = testPaths()
        let registry = ModelArtifactAccessRegistry()
        let model = singleFileModel(data: Data("fixture".utf8))
        let reservation = try registry.reserveDeletion(modelID: model.id)
        defer { registry.finishDeletion(reservation) }
        let downloader = ModelDownloader(paths: paths, registry: registry)
        var receivedError: String?
        downloader.onError = { receivedError = $0 }

        downloader.start(model: model)

        guard case .failed = downloader.state else {
            Issue.record("The download must enter failed state when the artifact is reserved for deletion")
            return
        }
        #expect(receivedError != nil)
    }

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
