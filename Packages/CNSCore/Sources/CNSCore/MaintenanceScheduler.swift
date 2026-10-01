import Foundation

/// Decides whether a periodic task is due based on elapsed wall-clock time.
/// Injecting `now` makes the schedule logic unit-testable without real timers,
/// mirroring the Python `*_if_due` guards.
public struct IntervalGate: Sendable {
    public let interval: TimeInterval
    public private(set) var lastRun: Date?

    public init(interval: TimeInterval, lastRun: Date? = nil) {
        self.interval = interval
        self.lastRun = lastRun
    }

    public func shouldRun(now: Date) -> Bool {
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= interval
    }

    public mutating func markRun(now: Date) {
        lastRun = now
    }
}

/// Drives the periodic maintenance hooks the Python app runs on rumps timers:
/// a 60 s dirty-config flush and a 3600 s daily-maintenance tick (decay +
/// metrics). The 0.3 s main-thread-queue drain is intentionally NOT ported —
/// Swift uses `@MainActor` directly (SWIFT_MIGRATION_PLAN.md §4.2).
@MainActor
public final class MaintenanceScheduler {
    public var flushInterval: TimeInterval
    public var maintenanceInterval: TimeInterval

    private let onFlush: @MainActor () -> Void
    private let onMaintenance: @MainActor () -> Void

    private var flushTimer: Timer?
    private var maintenanceTimer: Timer?

    public init(
        flushInterval: TimeInterval = 60,
        maintenanceInterval: TimeInterval = 3600,
        onFlush: @escaping @MainActor () -> Void,
        onMaintenance: @escaping @MainActor () -> Void
    ) {
        self.flushInterval = flushInterval
        self.maintenanceInterval = maintenanceInterval
        self.onFlush = onFlush
        self.onMaintenance = onMaintenance
    }

    public func start() {
        stop()
        flushTimer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFlush() }
        }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: maintenanceInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMaintenance() }
        }
    }

    public func stop() {
        flushTimer?.invalidate()
        maintenanceTimer?.invalidate()
        flushTimer = nil
        maintenanceTimer = nil
    }
}
