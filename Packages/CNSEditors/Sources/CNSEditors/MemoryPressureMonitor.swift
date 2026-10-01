import Darwin
import Dispatch
import Foundation

public protocol MemoryPressureProviding: Sendable {
    func isHigh() -> Bool
}

/// Native, cached macOS memory-pressure decision. Python treats only critical
/// pressure (level 4) as a reason to skip local Qwen; warning remains usable.
public final class MemoryPressureMonitor: MemoryPressureProviding, @unchecked Sendable {
    public typealias Sampler = @Sendable () -> Bool

    private struct Cache {
        var value = false
        var sampledAt: TimeInterval = -.infinity
    }

    private let lock = NSLock()
    private let cacheDuration: TimeInterval
    private let sampler: Sampler
    private var cache = Cache()
    private var source: DispatchSourceMemoryPressure?

    public init(
        cacheDuration: TimeInterval = 5,
        sampler: @escaping Sampler = MemoryPressureMonitor.sampleCriticalPressure
    ) {
        self.cacheDuration = cacheDuration
        self.sampler = sampler
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "com.sergej.clicknspeak.memory-pressure")
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let high = source.data.contains(.critical)
            self.lock.withLock {
                self.cache = Cache(
                    value: high,
                    sampledAt: ProcessInfo.processInfo.systemUptime
                )
            }
        }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }

    public func isHigh() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = lock.withLock({
            now - cache.sampledAt < cacheDuration ? cache.value : nil
        }) {
            return cached
        }
        let sampled = sampler()
        lock.withLock { cache = Cache(value: sampled, sampledAt: now) }
        return sampled
    }

    public static func sampleCriticalPressure() -> Bool {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return status == 0 && level >= 4
    }
}
