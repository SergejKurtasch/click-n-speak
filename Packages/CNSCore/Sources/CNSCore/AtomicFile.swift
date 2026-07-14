import Foundation

/// Atomic file writes: sibling temp file + fsync + rename, matching
/// `write_json_atomic` / `write_text_atomic` in `utils.py`. A crash or SIGKILL
/// mid-write never leaves a partial file in place of the original.
public enum AtomicFile {
    public enum WriteError: Error, Sendable {
        case create(String)
        case write(String)
    }

    public static func writeText(_ text: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmpURL = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let data = text.data(using: .utf8) else {
            throw WriteError.write("Text is not valid UTF-8")
        }

        let fd = open(tmpURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw WriteError.create("open failed: \(String(cString: strerror(errno)))") }

        var cleanupNeeded = true
        defer {
            if cleanupNeeded { try? FileManager.default.removeItem(at: tmpURL) }
        }

        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                let base = buffer.baseAddress!
                while offset < buffer.count {
                    let written = write(fd, base + offset, buffer.count - offset)
                    if written < 0 {
                        throw WriteError.write("write failed: \(String(cString: strerror(errno)))")
                    }
                    offset += written
                }
            }
            if fsync(fd) != 0 {
                throw WriteError.write("fsync failed: \(String(cString: strerror(errno)))")
            }
        } catch {
            close(fd)
            throw error
        }
        close(fd)

        // os.replace equivalent: atomic rename over the destination.
        if rename(tmpURL.path, url.path) != 0 {
            throw WriteError.write("rename failed: \(String(cString: strerror(errno)))")
        }
        cleanupNeeded = false
    }
}
