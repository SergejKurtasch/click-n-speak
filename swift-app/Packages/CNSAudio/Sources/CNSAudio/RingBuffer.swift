import Foundation
import os

/// Fixed-capacity single-producer/single-consumer float sample buffer between
/// the audio tap (producer) and the VAD/chunker consumer task. The tap must do
/// nothing but write here (SWIFT_MIGRATION_PLAN.md §4.5).
///
/// Guarded by an `OSAllocatedUnfairLock`. The AVAudioEngine tap runs on its own
/// dispatch queue (not the hard real-time render thread), so a brief uncontended
/// lock is acceptable; the consumer drains in large reads.
public final class SampleRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private var storage: [Float]
    private var head = 0   // next read index
    private var count = 0  // valid samples available
    private let lock = OSAllocatedUnfairLock()

    /// - Parameter capacitySeconds/sampleRate: sized to survive consumer stalls.
    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    public convenience init(capacitySeconds: Double, sampleRate: Int) {
        self.init(capacity: max(1, Int(capacitySeconds * Double(sampleRate))))
    }

    /// Append samples. On overflow the oldest samples are dropped to make room
    /// (consumer fell behind). Returns the number of oldest samples discarded.
    @discardableResult
    public func write(_ samples: [Float]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var dropped = 0
        for sample in samples {
            let tail = (head + count) % capacity
            storage[tail] = sample
            if count == capacity {
                head = (head + 1) % capacity // overwrite oldest
                dropped += 1
            } else {
                count += 1
            }
        }
        return dropped
    }

    /// Read up to `maxCount` samples in FIFO order, removing them.
    public func read(maxCount: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let n = min(maxCount, count)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = storage[(head + i) % capacity]
        }
        head = (head + n) % capacity
        count -= n
        return out
    }

    /// Drain all available samples.
    public func readAll() -> [Float] {
        read(maxCount: availableCount)
    }

    public var availableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        head = 0
        count = 0
    }
}
