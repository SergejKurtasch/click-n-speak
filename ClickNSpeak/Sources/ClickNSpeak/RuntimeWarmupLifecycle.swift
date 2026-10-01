import AppKit
import CNSSession
import Foundation

@MainActor
protocol SessionWarmupControlling: AnyObject, Sendable {
    var isRuntimeIdle: Bool { get }
    var runtimeAvailable: Bool { get }
    var onWarmupIntentCancelled: (() -> Void)? { get set }
    var onWarmupAvailabilityChanged: (() -> Void)? { get set }
    func warmupIfIdle(trigger: WarmupTrigger, full: Bool, language: String?) async -> Bool
    func cancelWarmup()
}

extension SessionController: SessionWarmupControlling {}

@MainActor
final class RuntimeWarmupLifecycle {
    private weak var session: (any SessionWarmupControlling)?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var keepAliveTimer: Timer?
    private var isSleeping = false
    private var started = false
    private var runtimeReady = true
    private var pending: (id: UUID, trigger: WarmupTrigger, delayElapsed: Bool)?
    private var delayedTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private let notificationCenter: NotificationCenter
    private let asyncWait: @Sendable (TimeInterval) async throws -> Void
    private let scheduleTimer: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Timer

    init(
        session: any SessionWarmupControlling,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        asyncWait: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        scheduleTimer: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Timer = { interval, block in
            Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                Task { @MainActor in block() }
            }
        }
    ) {
        self.session = session
        self.notificationCenter = notificationCenter
        self.asyncWait = asyncWait
        self.scheduleTimer = scheduleTimer
    }

    /// Runtime preparation can leave the previous runtime record-capable.
    /// Wake intent waits for the desired runtime to finish activation.
    func setRuntimeReady(_ ready: Bool) {
        runtimeReady = ready
        if ready { consumePendingIfReady() }
    }

    func start() {
        if started { stop() }
        started = true
        isSleeping = false
        session?.onWarmupIntentCancelled = { [weak self] in self?.invalidateIntent() }
        session?.onWarmupAvailabilityChanged = { [weak self] in self?.consumePendingIfReady() }
        keepAliveTimer = scheduleTimer(15 * 60) { [weak self] in
            guard let self, self.started, self.runtimeReady, !self.isSleeping, self.pending == nil,
                  let session = self.session, session.isRuntimeIdle, session.runtimeAvailable else { return }
            self.operationTask = Task { _ = await session.warmupIfIdle(trigger: .keepAlive, full: false, language: nil) }
        }
        sleepObserver = notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSleeping = true
                self.invalidateIntent()
                self.session?.cancelWarmup()
            }
        }
        wakeObserver = notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSleeping = false
                self.schedule(.wake)
            }
        }
        schedule(.startup)
    }

    private func schedule(_ trigger: WarmupTrigger) {
        invalidateIntent()
        // A repeated wake cancels the preceding synthetic operation before
        // installing the new intent. Its reservation remains session-owned.
        if trigger == .wake { session?.cancelWarmup() }
        let id = UUID()
        pending = (id, trigger, false)
        let wait = asyncWait
        delayedTask = Task { [weak self] in
            do { try await wait(1) } catch { return }
            guard !Task.isCancelled, let self, self.pending?.id == id else { return }
            self.delayedTask = nil
            self.pending?.delayElapsed = true
            self.consumePendingIfReady()
        }
    }

    private func consumePendingIfReady() {
        guard started, runtimeReady, !isSleeping, let intent = pending, intent.delayElapsed,
              let session, session.isRuntimeIdle, session.runtimeAvailable else { return }
        pending = nil
        operationTask = Task {
            guard !Task.isCancelled else { return }
            _ = await session.warmupIfIdle(trigger: intent.trigger, full: false, language: nil)
        }
    }

    private func invalidateIntent() {
        pending = nil
        delayedTask?.cancel()
        delayedTask = nil
        operationTask?.cancel()
        operationTask = nil
    }

    func stop() {
        guard started else { return }
        started = false
        invalidateIntent()
        session?.onWarmupIntentCancelled = nil
        session?.onWarmupAvailabilityChanged = nil
        session?.cancelWarmup()
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        if let sleepObserver { notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }
        sleepObserver = nil
        wakeObserver = nil
    }
}
