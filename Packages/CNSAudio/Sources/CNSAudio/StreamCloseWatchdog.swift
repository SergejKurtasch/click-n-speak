import Foundation

/// Runs the audio stream teardown off the caller's thread and reports a hang.
///
/// Ported from `_stop_stream_with_timeout` / `_watchdog` in `recorder.py`. Core
/// Audio can deadlock while the device graph is reconfigured (Bluetooth connect,
/// sleep/wake), and a blocked stop would otherwise freeze the stop-and-process
/// path. Two guarantees, both matching the Python behaviour:
///
/// * `close(_:)` never blocks the caller; if the teardown has not finished after
///   `timeout` seconds, `onHang` fires so the app can restart itself.
/// * `awaitPendingClose()` lets the next `start` wait for an in-flight teardown
///   (up to the same timeout) instead of opening a second stream on top of it.
public final class StreamCloseWatchdog: @unchecked Sendable {
    // @unchecked Sendable: `pending` is the only mutable state and is guarded by `lock`.
    private let timeout: TimeInterval
    private let log: @Sendable (String) -> Void
    private let onHang: @Sendable () -> Void

    private let closeQueue = DispatchQueue(label: "com.sergej.clicknspeak.stream-close")
    private let watchQueue = DispatchQueue(label: "com.sergej.clicknspeak.stream-close-watchdog")
    private let lock = NSLock()
    private var pending: DispatchGroup?

    public init(
        timeout: TimeInterval = 12.0,
        log: @escaping @Sendable (String) -> Void = { _ in },
        onHang: @escaping @Sendable () -> Void = {}
    ) {
        self.timeout = timeout
        self.log = log
        self.onHang = onHang
    }

    /// Whether a teardown started earlier has not reported completion yet.
    public var hasPendingClose: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending != nil
    }

    /// Run `stop` on a private queue and watch it. Returns immediately.
    public func close(_ stop: @escaping @Sendable () -> Void) {
        let group = DispatchGroup()
        group.enter()
        lock.lock()
        pending = group
        lock.unlock()

        closeQueue.async {
            stop()
            group.leave()
        }

        watchQueue.async { [weak self] in
            guard let self else { return }
            if group.wait(timeout: .now() + self.timeout) == .timedOut {
                self.log("Audio stream close hung >\(Int(self.timeout))s — triggering proactive restart.")
                self.onHang()
                // Leave `pending` set so the next start refuses to open a stream on
                // top of a stuck one; clear it if the teardown ever does finish.
                group.notify(queue: self.watchQueue) { self.clear(group) }
                return
            }
            self.clear(group)
        }
    }

    /// Wait for an in-flight teardown before opening a new stream.
    /// - Returns: `false` when the teardown is still stuck after `timeout` — the
    ///   caller must not start a new stream in that case.
    public func awaitPendingClose() async -> Bool {
        // Read through a sync helper: NSLock is unavailable in async contexts.
        guard let group = currentPending() else { return true }

        log("Previous stream close still in progress. Waiting up to \(Int(timeout))s…")
        let finished = await withCheckedContinuation { continuation in
            watchQueue.async {
                continuation.resume(returning: group.wait(timeout: .now() + self.timeout) != .timedOut)
            }
        }
        if finished {
            clear(group)
            log("Previous stream close completed. Proceeding with new recording.")
        }
        return finished
    }

    private func currentPending() -> DispatchGroup? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    private func clear(_ group: DispatchGroup) {
        lock.lock()
        if pending === group { pending = nil }
        lock.unlock()
    }
}
