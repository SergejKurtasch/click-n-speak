import CryptoKit
import Foundation

public enum ModelValidationError: LocalizedError, Sendable, Equatable {
    case missingArtifact(String)
    case unsafeArtifactPath(String)
    case wrongSize(path: String, expected: Int64, actual: Int64)
    case checksumMismatch(path: String)
    case invalidFormat(path: String, format: ModelArtifact.Format)
    case activeModelDeletion(String)
    case insufficientDiskSpace(required: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case let .missingArtifact(path): "Model artifact is missing: \(path)"
        case let .unsafeArtifactPath(path): "Model artifact path is unsafe: \(path)"
        case let .wrongSize(path, expected, actual):
            "Model artifact has the wrong size (\(path), expected \(expected), got \(actual))"
        case let .checksumMismatch(path): "Model artifact checksum does not match: \(path)"
        case let .invalidFormat(path, format): "Model artifact has invalid \(format.rawValue) format: \(path)"
        case let .activeModelDeletion(id): "The active model cannot be deleted: \(id)"
        case let .insufficientDiskSpace(required, available):
            "Insufficient disk space (required \(required), available \(available))"
        }
    }
}

public enum ModelValidationState: Sendable, Equatable {
    case unavailable
    case validating
    case valid
    case invalid(String)
}

public enum ModelActivationError: LocalizedError, Sendable {
    case recoveryRequired(previousModel: URL?, destination: URL)

    public var errorDescription: String? {
        switch self {
        case let .recoveryRequired(previousModel, _):
            previousModel == nil
                ? "Model activation failed and the staged model could not be restored."
                : "Model activation failed and automatic rollback could not finish. The previous model was preserved."
        }
    }
}

private struct ArtifactFingerprint: Codable, Sendable, Equatable {
    let inode: UInt64
    let size: Int64
    let modifiedAt: TimeInterval
}

private struct ModelValidationRecord: Codable, Sendable, Equatable {
    let manifestVersion: Int
    let sourceRevision: String
    let artifacts: [String: ArtifactFingerprint]
}

private struct ModelValidationCache: Codable, Sendable {
    var records: [String: ModelValidationRecord] = [:]
}

/// Manages the verified on-disk lifecycle of local models. A model is usable
/// only when its current filesystem fingerprints match a cache entry produced
/// by a complete SHA-256 and format validation.
public enum ModelManager {
    private static let cacheLock = NSLock()
    private static let cacheFileName = ".validation-cache-v1.json"

    public static func isDownloaded(_ model: ModelInfo, paths: Paths) -> Bool {
        cachedValidationState(model, paths: paths) == .valid
    }

    public static func cachedValidationState(
        _ model: ModelInfo,
        paths: Paths
    ) -> ModelValidationState {
        let destination = paths.modelFile(for: model)
        guard FileManager.default.fileExists(atPath: destination.path) else { return .unavailable }
        do {
            let fingerprints = try artifactFingerprints(model: model, root: destination)
            let record = readCache(paths: paths).records[model.id]
            guard record?.manifestVersion == model.manifestVersion,
                  record?.sourceRevision == model.sourceRevision,
                  record?.artifacts == fingerprints else {
                return .invalid("Model requires validation")
            }
            return .valid
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    /// Hash and validate a model away from the main actor. A successful check
    /// records fingerprints so subsequent menu opens never re-hash gigabytes.
    public static func validate(_ model: ModelInfo, paths: Paths) async throws {
        try await Task.detached(priority: .utility) {
            let root = paths.modelFile(for: model)
            let fingerprints = try validateArtifacts(model: model, root: root)
            try saveValidationRecord(model: model, fingerprints: fingerprints, paths: paths)
        }.value
    }

    /// Validate a staging artifact, then replace the installed model using a
    /// same-volume backup. The previous working model is restored on any move
    /// or cache-write failure.
    public static func validateAndActivate(
        stagingURL: URL,
        model: ModelInfo,
        paths: Paths
    ) async throws {
        try await validateAndActivate(
            stagingURL: stagingURL, model: model, paths: paths,
            moveItem: { source, destination in
                try FileManager.default.moveItem(at: source, to: destination)
            },
            writeValidationCache: { data, url in
                try writeCacheData(data, to: url)
            }
        )
    }

    static func validateAndActivate(
        stagingURL: URL,
        model: ModelInfo,
        paths: Paths,
        moveItem: @escaping @Sendable (URL, URL) throws -> Void,
        writeValidationCache: @escaping @Sendable (Data, URL) throws -> Void
    ) async throws {
        try await Task.detached(priority: .utility) {
            let fingerprints = try validateArtifacts(model: model, root: stagingURL)
            let destination = paths.modelFile(for: model)
            let backup = paths.modelsDirectory.appendingPathComponent(
                ".\(model.fileName).previous-\(UUID().uuidString)",
                isDirectory: model.storage.isSnapshot
            )
            let failedCandidate = paths.modelsDirectory.appendingPathComponent(
                ".\(model.fileName).failed-\(UUID().uuidString)",
                isDirectory: model.storage.isSnapshot
            )
            let fm = FileManager.default
            var movedOldModel = false
            do {
                if fm.fileExists(atPath: destination.path) {
                    try moveItem(destination, backup)
                    movedOldModel = true
                }
                try moveItem(stagingURL, destination)
                try saveValidationRecord(
                    model: model,
                    fingerprints: fingerprints,
                    paths: paths,
                    writeData: writeValidationCache
                )
                if movedOldModel {
                    try? fm.removeItem(at: backup)
                }
            } catch {
                let activationError = error
                if movedOldModel {
                    var candidateMovedAside = false
                    if fm.fileExists(atPath: destination.path) {
                        do {
                            try moveItem(destination, failedCandidate)
                            candidateMovedAside = true
                        } catch {
                            throw ModelActivationError.recoveryRequired(
                                previousModel: backup, destination: destination
                            )
                        }
                    }
                    do {
                        try moveItem(backup, destination)
                    } catch {
                        if candidateMovedAside {
                            do {
                                try moveItem(failedCandidate, destination)
                            } catch {
                                // Both artifacts remain in transaction-owned siblings.
                            }
                        }
                        throw ModelActivationError.recoveryRequired(
                            previousModel: backup, destination: destination
                        )
                    }
                    if candidateMovedAside {
                        do {
                            try moveItem(failedCandidate, stagingURL)
                        } catch {
                            // The previous model is active; retain the candidate for diagnosis.
                        }
                    }
                } else if fm.fileExists(atPath: destination.path) {
                    do {
                        try moveItem(destination, stagingURL)
                    } catch {
                        throw ModelActivationError.recoveryRequired(
                            previousModel: nil, destination: destination
                        )
                    }
                }
                throw activationError
            }
        }.value
    }

    /// Move an invalid partial into a bounded quarantine location for diagnosis.
    /// Only the three newest entries are retained.
    public static func quarantineInvalidArtifact(
        at url: URL,
        model: ModelInfo,
        paths: Paths
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let directory = paths.modelsDirectory.appendingPathComponent(".quarantine", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = directory.appendingPathComponent("\(model.id)-\(stamp)-\(UUID().uuidString)")
        try fm.moveItem(at: url, to: destination)
        if let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).sorted(by: {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }) {
            for stale in entries.dropFirst(3) {
                try? fm.removeItem(at: stale)
            }
        }
    }

    public static func delete(
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
    }

    public static func diskUsage(paths: Paths) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: paths.modelsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true,
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    public static func diskUsageForModel(_ model: ModelInfo, paths: Paths) -> Int64 {
        let url = paths.modelFile(for: model)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        if !isDirectory.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    public static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    public static func availableDiskCapacity(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    public static func checkDiskCapacity(
        requiredBytes: Int64,
        availableBytes: Int64,
        safetyMargin: Int64 = 256 * 1_024 * 1_024
    ) throws {
        let required = requiredBytes + safetyMargin
        guard availableBytes >= required else {
            throw ModelValidationError.insufficientDiskSpace(
                required: required,
                available: availableBytes
            )
        }
    }

    private static func validateArtifacts(
        model: ModelInfo,
        root: URL
    ) throws -> [String: ArtifactFingerprint] {
        guard !model.artifacts.isEmpty else {
            throw ModelValidationError.missingArtifact(model.fileName)
        }
        var result: [String: ArtifactFingerprint] = [:]
        for artifact in model.artifacts {
            let url = try artifactURL(artifact, model: model, root: root)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ModelValidationError.missingArtifact(artifact.relativePath)
            }
            let fingerprint = try fingerprint(url)
            guard fingerprint.size == artifact.expectedSize else {
                throw ModelValidationError.wrongSize(
                    path: artifact.relativePath,
                    expected: artifact.expectedSize,
                    actual: fingerprint.size
                )
            }
            try validateFormat(artifact.format, at: url, path: artifact.relativePath)
            guard try sha256(of: url) == artifact.sha256 else {
                throw ModelValidationError.checksumMismatch(path: artifact.relativePath)
            }
            result[artifact.relativePath] = fingerprint
        }
        return result
    }

    private static func artifactFingerprints(
        model: ModelInfo,
        root: URL
    ) throws -> [String: ArtifactFingerprint] {
        var result: [String: ArtifactFingerprint] = [:]
        for artifact in model.artifacts {
            let url = try artifactURL(artifact, model: model, root: root)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ModelValidationError.missingArtifact(artifact.relativePath)
            }
            result[artifact.relativePath] = try fingerprint(url)
        }
        return result
    }

    private static func artifactURL(
        _ artifact: ModelArtifact,
        model: ModelInfo,
        root: URL
    ) throws -> URL {
        guard !artifact.relativePath.isEmpty,
              !artifact.relativePath.hasPrefix("/"),
              !artifact.relativePath.split(separator: "/").contains("..") else {
            throw ModelValidationError.unsafeArtifactPath(artifact.relativePath)
        }
        switch model.storage {
        case .singleFile:
            return root
        case .snapshot:
            let resolved = root.appendingPathComponent(artifact.relativePath).standardizedFileURL
            let prefix = root.standardizedFileURL.path + "/"
            guard resolved.path.hasPrefix(prefix) else {
                throw ModelValidationError.unsafeArtifactPath(artifact.relativePath)
            }
            return resolved
        }
    }

    private static func fingerprint(_ url: URL) throws -> ArtifactFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let date = (attributes[.modificationDate] as? Date) ?? .distantPast
        return ArtifactFingerprint(inode: inode, size: size, modifiedAt: date.timeIntervalSince1970)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validateFormat(
        _ format: ModelArtifact.Format,
        at url: URL,
        path: String
    ) throws {
        switch format {
        case .ggml:
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 4) ?? Data()
            let accepted = [Data("lmgg".utf8), Data("ggml".utf8), Data("GGUF".utf8)]
            guard accepted.contains(prefix) else {
                throw ModelValidationError.invalidFormat(path: path, format: format)
            }
        case .safetensors:
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let lengthData = try handle.read(upToCount: 8), lengthData.count == 8 else {
                throw ModelValidationError.invalidFormat(path: path, format: format)
            }
            let headerLength = lengthData.withUnsafeBytes { raw -> UInt64 in
                raw.loadUnaligned(as: UInt64.self).littleEndian
            }
            guard headerLength > 1, headerLength < 100_000_000,
                  let header = try handle.read(upToCount: Int(headerLength)),
                  header.count == Int(headerLength),
                  (try? JSONSerialization.jsonObject(with: header)) is [String: Any] else {
                throw ModelValidationError.invalidFormat(path: path, format: format)
            }
        case .json:
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
                throw ModelValidationError.invalidFormat(path: path, format: format)
            }
        case .text:
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !data.isEmpty, String(data: data.prefix(64 * 1_024), encoding: .utf8) != nil else {
                throw ModelValidationError.invalidFormat(path: path, format: format)
            }
        }
    }

    private static func cacheURL(paths: Paths) -> URL {
        paths.modelsDirectory.appendingPathComponent(cacheFileName)
    }

    private static func readCache(paths: Paths) -> ModelValidationCache {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let data = try? Data(contentsOf: cacheURL(paths: paths)),
              let cache = try? JSONDecoder().decode(ModelValidationCache.self, from: data) else {
            return ModelValidationCache()
        }
        return cache
    }

    private static func saveValidationRecord(
        model: ModelInfo,
        fingerprints: [String: ArtifactFingerprint],
        paths: Paths,
        writeData: @Sendable (Data, URL) throws -> Void = { data, url in
            try writeCacheData(data, to: url)
        }
    ) throws {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        try paths.ensureModelsDirectory()
        let url = cacheURL(paths: paths)
        var cache: ModelValidationCache
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(ModelValidationCache.self, from: data) {
            cache = decoded
        } else {
            cache = ModelValidationCache()
        }
        cache.records[model.id] = ModelValidationRecord(
            manifestVersion: model.manifestVersion,
            sourceRevision: model.sourceRevision,
            artifacts: fingerprints
        )
        try writeData(JSONEncoder().encode(cache), url)
    }

    private static func removeValidationRecord(modelID: String, paths: Paths) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let url = cacheURL(paths: paths)
        guard let data = try? Data(contentsOf: url),
              var cache = try? JSONDecoder().decode(ModelValidationCache.self, from: data) else {
            return
        }
        cache.records.removeValue(forKey: modelID)
        try? writeCache(cache, to: url)
    }

    private static func writeCache(_ cache: ModelValidationCache, to url: URL) throws {
        try writeCacheData(JSONEncoder().encode(cache), to: url)
    }

    private static func writeCacheData(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: [.atomic])
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}

private extension ModelStorage {
    var isSnapshot: Bool {
        if case .snapshot = self { return true }
        return false
    }
}
