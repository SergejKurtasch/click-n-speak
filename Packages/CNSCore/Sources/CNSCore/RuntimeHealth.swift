import Foundation

public enum PrewarmResult: Sendable, Equatable {
    case warmed
    case skipped
    case failed
}

public struct RestartDecision: Sendable {
    public let shouldRestart: Bool
    public let reason: String?

    public init(shouldRestart: Bool, reason: String? = nil) {
        self.shouldRestart = shouldRestart
        self.reason = reason
    }
}

@MainActor
public final class TranscriberHealthMonitor {
    public let slowSeconds: TimeInterval
    public let severeSeconds: TimeInterval
    public let severePrewarmSeconds: TimeInterval
    public let cooldownSeconds: TimeInterval
    public let longUptimeSeconds: TimeInterval

    private var warmDecodeDurations: [TimeInterval] = []
    private var lastRestartAt: TimeInterval = -Double.greatestFiniteMagnitude
    private var processStartedAt: TimeInterval

    public init(
        slowSeconds: TimeInterval = 6.0,
        severeSeconds: TimeInterval = 10.0,
        severePrewarmSeconds: TimeInterval = 10.0,
        cooldownSeconds: TimeInterval = 20 * 60,
        longUptimeSeconds: TimeInterval = 24 * 60 * 60
    ) {
        self.slowSeconds = slowSeconds
        self.severeSeconds = severeSeconds
        self.severePrewarmSeconds = severePrewarmSeconds
        self.cooldownSeconds = cooldownSeconds
        self.longUptimeSeconds = longUptimeSeconds
        self.processStartedAt = ProcessInfo.processInfo.systemUptime
    }

    private func cooldownElapsed(now: TimeInterval) -> Bool {
        return now - lastRestartAt >= cooldownSeconds
    }

    public func recordDecode(durationSeconds: TimeInterval, coldStart: Bool, now: TimeInterval? = nil) -> RestartDecision {
        let current = now ?? ProcessInfo.processInfo.systemUptime
        if coldStart {
            return RestartDecision(shouldRestart: false)
        }

        warmDecodeDurations.append(durationSeconds)
        if warmDecodeDurations.count > 6 {
            warmDecodeDurations.removeFirst()
        }

        if !cooldownElapsed(now: current) {
            return RestartDecision(shouldRestart: false)
        }

        let values = warmDecodeDurations
        if values.count >= 2 {
            let lastTwo = values.suffix(2)
            if lastTwo.allSatisfy({ $0 >= severeSeconds }) {
                return RestartDecision(shouldRestart: true, reason: "two_consecutive_severe_decodes")
            }
        }

        if values.count >= 3 {
            let lastThree = values.suffix(3)
            if lastThree.allSatisfy({ $0 >= slowSeconds }) {
                return RestartDecision(shouldRestart: true, reason: "three_consecutive_slow_decodes")
            }
        }

        if values.count == 6 {
            let slowCount = values.filter { $0 >= slowSeconds }.count
            if slowCount >= 4 {
                return RestartDecision(shouldRestart: true, reason: "four_slow_decodes_in_window")
            }
        }

        if current - processStartedAt >= longUptimeSeconds && durationSeconds >= slowSeconds {
            return RestartDecision(shouldRestart: true, reason: "slow_decode_after_long_uptime")
        }

        return RestartDecision(shouldRestart: false)
    }

    public func recordPrewarm(
        durationSeconds: TimeInterval,
        outcome: PrewarmResult,
        now: TimeInterval? = nil
    ) -> RestartDecision {
        guard outcome != .skipped else {
            return RestartDecision(shouldRestart: false)
        }
        let current = now ?? ProcessInfo.processInfo.systemUptime
        if !cooldownElapsed(now: current) {
            return RestartDecision(shouldRestart: false)
        }
        if outcome == .failed {
            return RestartDecision(shouldRestart: true, reason: "prewarm_failed")
        }
        if durationSeconds >= severePrewarmSeconds {
            return RestartDecision(shouldRestart: true, reason: "prewarm_severely_slow")
        }
        return RestartDecision(shouldRestart: false)
    }

    public func markRestarted(now: TimeInterval? = nil) {
        let current = now ?? ProcessInfo.processInfo.systemUptime
        lastRestartAt = current
        processStartedAt = current
        warmDecodeDurations.removeAll()
    }
}
