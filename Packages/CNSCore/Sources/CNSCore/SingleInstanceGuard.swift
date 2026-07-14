import Foundation

/// Exclusive `flock` on `.instance.lock` so only one instance runs at a time.
/// The OS releases the lock when the process dies, so a crashed prior session is
/// auto-reclaimed. Mirrors `_acquire_instance_lock` / `_release_instance_lock`.
public final class SingleInstanceGuard: @unchecked Sendable {
    // @unchecked: the held file descriptor is only mutated under the internal
    // lifecycle (acquire once, release once); no concurrent access by contract.
    private let lockURL: URL
    private var fd: Int32 = -1

    public init(lockURL: URL) {
        self.lockURL = lockURL
    }

    /// Returns true if this process acquired the lock (is the primary instance).
    public func acquire() -> Bool {
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_WRONLY | O_CREAT, 0o644)
        guard descriptor >= 0 else { return false }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return false
        }
        // Best-effort write of our PID, matching the Python lock file contents.
        ftruncate(descriptor, 0)
        let pid = "\(ProcessInfo.processInfo.processIdentifier)"
        _ = pid.withCString { write(descriptor, $0, strlen($0)) }
        fd = descriptor
        return true
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit {
        release()
    }
}
