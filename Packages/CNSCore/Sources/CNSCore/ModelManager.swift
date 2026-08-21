import Foundation

/// Manages the on-disk lifecycle of downloaded models: check presence, delete,
/// and measure disk usage. All paths derive from the shared `Paths.modelsDirectory`.
public enum ModelManager {

    /// Return `true` when the model's file exists and is at least 1 MB
    /// (guards against empty/corrupt partial files left by interrupted writes).
    public static func isDownloaded(_ model: ModelInfo, paths: Paths) -> Bool {
        let url = paths.modelFile(for: model)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        let size = (attrs[.size] as? Int64) ?? 0
        return size > 1_000_000
    }

    /// Delete the model file from disk.
    public static func delete(_ model: ModelInfo, paths: Paths) throws {
        let url = paths.modelFile(for: model)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Total bytes consumed by all downloaded models.
    public static func diskUsage(paths: Paths) -> Int64 {
        let dir = paths.modelsDirectory
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Human-readable size string (e.g. "1.2 GB", "795 MB").
    public static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
