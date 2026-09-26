import AppKit
import CNSSession
import Foundation
import Testing
@testable import ClickNSpeak

@MainActor
private func waitUntil(
    _ condition: @MainActor @escaping () -> Bool,
    timeout: Duration = .seconds(1)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

@MainActor
final class MockSessionWarmupControlling: SessionWarmupControlling {
    var warmupCalls: [(trigger: WarmupTrigger, full: Bool, language: String?)] = []
    var cancelWarmupCalls = 0
    var isRuntimeIdle = true
    var runtimeAvailable = true
    var onWarmupIntentCancelled: (() -> Void)?
    var onWarmupAvailabilityChanged: (() -> Void)?

    func warmupIfIdle(trigger: WarmupTrigger, full: Bool, language: String?) async -> Bool {
        warmupCalls.append((trigger, full, language))
        return true
    }

    func cancelWarmup() {
        cancelWarmupCalls += 1
        onWarmupIntentCancelled?()
    }
}

@Suite
@MainActor
struct RuntimeWarmupLifecycleTests {
    @Test
    func desiredRuntimePreparationDelaysWakeEvenWithUsableOldRuntime() async throws {
        let session = MockSessionWarmupControlling()
        let center = NotificationCenter()
        let lifecycle = RuntimeWarmupLifecycle(session: session, notificationCenter: center,
            asyncWait: { _ in }, scheduleTimer: { _, _ in Timer() })
        defer { lifecycle.stop() }
        lifecycle.setRuntimeReady(false)
        lifecycle.start()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(session.warmupCalls.isEmpty)
        lifecycle.setRuntimeReady(true)
        lifecycle.setRuntimeReady(true)
        #expect(await waitUntil { session.warmupCalls.count == 1 })
        #expect(session.warmupCalls.count == 1)
        #expect(session.warmupCalls.last?.trigger == .wake)
    }

    @Test
    func stopCancelsActiveWarmup() async throws {
        let session = MockSessionWarmupControlling()
        let lifecycle = RuntimeWarmupLifecycle(session: session, notificationCenter: NotificationCenter(),
            asyncWait: { _ in }, scheduleTimer: { _, _ in Timer() })
        defer { lifecycle.stop() }
        lifecycle.start()
        try await Task.sleep(for: .milliseconds(10))
        let previous = session.cancelWarmupCalls
        lifecycle.stop()
        #expect(session.cancelWarmupCalls == previous + 1)
    }

    @Test
    func userActionBeforeDelayCancelsPendingIntent() async throws {
        let session = MockSessionWarmupControlling()
        let lifecycle = RuntimeWarmupLifecycle(session: session, notificationCenter: NotificationCenter(),
            asyncWait: { _ in try await Task.sleep(for: .milliseconds(40)) },
            scheduleTimer: { _, _ in Timer() })
        defer { lifecycle.stop() }
        lifecycle.start()
        session.cancelWarmup()
        try await Task.sleep(for: .milliseconds(60))
        #expect(session.warmupCalls.isEmpty)
    }

    @Test
    func unavailableRuntimeConsumesPendingWakeOnceWhenReady() async throws {
        let session = MockSessionWarmupControlling()
        session.runtimeAvailable = false
        let center = NotificationCenter()
        let lifecycle = RuntimeWarmupLifecycle(session: session, notificationCenter: center,
            asyncWait: { _ in }, scheduleTimer: { _, _ in Timer() })
        defer { lifecycle.stop() }
        lifecycle.start()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(session.warmupCalls.isEmpty)
        session.runtimeAvailable = true
        session.onWarmupAvailabilityChanged?()
        session.onWarmupAvailabilityChanged?()
        #expect(await waitUntil { session.warmupCalls.count == 1 })
        #expect(session.warmupCalls.count == 1)
        #expect(session.warmupCalls.last?.trigger == .wake)
    }

    @Test
    func testStartupTrigger() async throws {
        let session = MockSessionWarmupControlling()
        let nc = NotificationCenter()

        let lifecycle = RuntimeWarmupLifecycle(
            session: session,
            notificationCenter: nc,
            asyncWait: { _ in },
            scheduleTimer: { _, _ in Timer() }
        )
        defer { lifecycle.stop() }

        lifecycle.start()

        #expect(await waitUntil { session.warmupCalls.count == 1 })
        #expect(session.warmupCalls.last?.trigger == .startup)
    }

    @Test
    func testWakeTrigger() async throws {
        let session = MockSessionWarmupControlling()
        let nc = NotificationCenter()

        let lifecycle = RuntimeWarmupLifecycle(
            session: session,
            notificationCenter: nc,
            asyncWait: { _ in },
            scheduleTimer: { _, _ in Timer() }
        )
        defer { lifecycle.stop() }

        lifecycle.start()
        #expect(await waitUntil { session.warmupCalls.count == 1 })
        session.warmupCalls.removeAll()

        nc.post(name: NSWorkspace.didWakeNotification, object: nil)

        #expect(await waitUntil { session.warmupCalls.count == 1 })
        #expect(session.warmupCalls.last?.trigger == .wake)
    }

    @Test
    func testSleepCancelsWarmup() async throws {
        let session = MockSessionWarmupControlling()
        let nc = NotificationCenter()

        let lifecycle = RuntimeWarmupLifecycle(
            session: session,
            notificationCenter: nc,
            asyncWait: { _ in },
            scheduleTimer: { _, _ in Timer() }
        )
        defer { lifecycle.stop() }

        lifecycle.start()
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(session.cancelWarmupCalls == 0)

        nc.post(name: NSWorkspace.willSleepNotification, object: nil)

        #expect(session.cancelWarmupCalls == 1)
    }
}
