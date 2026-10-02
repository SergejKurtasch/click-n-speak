import Foundation
import Testing
@testable import CNSAudio

@Suite("StreamCloseWatchdog")
struct StreamCloseWatchdogTests {
    /// Thread-safe flag: the watchdog fires from its own queue.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("A teardown that finishes in time does not report a hang")
    func normalClose() async {
        let hung = Flag()
        let watchdog = StreamCloseWatchdog(timeout: 0.1, onHang: { hung.set() })

        watchdog.close {}

        #expect(await watchdog.awaitPendingClose() == true)
        try? await Task.sleep(nanoseconds: 600_000_000)  // past the deadline
        #expect(hung.isSet == false)
        #expect(watchdog.hasPendingClose == false)
    }

    @Test("A stuck teardown reports a hang after the deadline")
    func hangingClose() async {
        let hung = Flag()
        let release = DispatchSemaphore(value: 0)
        let watchdog = StreamCloseWatchdog(timeout: 0.05, onHang: { hung.set() })

        watchdog.close { release.wait() }  // never returns until we release it

        #expect(hung.isSet == false)  // not immediately
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(hung.isSet == true)
        release.signal()
    }

    @Test("close() returns immediately instead of blocking the caller")
    func closeDoesNotBlock() async {
        let release = DispatchSemaphore(value: 0)
        let watchdog = StreamCloseWatchdog(timeout: 5)

        let started = Date()
        watchdog.close { release.wait() }
        #expect(Date().timeIntervalSince(started) < 0.1)

        release.signal()
    }

    @Test("A start racing a stuck teardown is refused")
    func startRefusedWhileStuck() async {
        let release = DispatchSemaphore(value: 0)
        let watchdog = StreamCloseWatchdog(timeout: 0.05)

        watchdog.close { release.wait() }

        #expect(await watchdog.awaitPendingClose() == false)
        release.signal()
    }

    @Test("A teardown that completes late clears the pending state")
    func lateCompletionClearsPending() async {
        let hung = Flag()
        let release = DispatchSemaphore(value: 0)
        let watchdog = StreamCloseWatchdog(timeout: 0.05, onHang: { hung.set() })

        watchdog.close { release.wait() }
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(hung.isSet == true)
        #expect(watchdog.hasPendingClose == true)

        release.signal()
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(watchdog.hasPendingClose == false)
        #expect(await watchdog.awaitPendingClose() == true)
    }
}
