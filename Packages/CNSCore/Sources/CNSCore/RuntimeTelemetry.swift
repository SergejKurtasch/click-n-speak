import Foundation

public protocol RuntimeTelemetrySink: Sendable {
    func emit(event: String, fields: [String: Any])
    func drain() async
}

public final class FileRuntimeTelemetrySink: RuntimeTelemetrySink, @unchecked Sendable {
    private let logger: FileLogger
    private let writes = RuntimeTelemetryWriteQueue()

    public init(logger: FileLogger) {
        self.logger = logger
    }

    public func emit(event: String, fields: [String: Any]) {
        var payload = fields
        payload["event"] = event
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        writes.enqueue { [logger] in
            await logger.runtimeEvent(json)
        }
    }

    public func drain() async {
        await writes.drain()
    }
}

public final class InMemoryRuntimeTelemetrySink: RuntimeTelemetrySink, @unchecked Sendable {
    private let lock = NSLock()
    private var storedJSON: [String] = []

    public init() {}

    public func emit(event: String, fields: [String: Any]) {
        var payload = fields
        payload["event"] = event
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        lock.withLock { storedJSON.append(json) }
    }

    public func drain() async {}

    public var jsonLines: [String] {
        lock.withLock { storedJSON }
    }
}

private final class DiscardRuntimeTelemetrySink: RuntimeTelemetrySink, Sendable {
    func emit(event: String, fields: [String: Any]) {}
    func drain() async {}
}

private final class RuntimeTelemetryWriteQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.withLock {
            let previous = tail
            tail = Task {
                await previous?.value
                await operation()
            }
        }
    }

    func drain() async {
        let pending = lock.withLock { tail }
        await pending?.value
    }
}

private final class RuntimeTelemetryState: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: any RuntimeTelemetrySink = DiscardRuntimeTelemetrySink()
    private var runID = UUID()

    func configure(sink: any RuntimeTelemetrySink, runID: UUID) {
        lock.withLock {
            self.sink = sink
            self.runID = runID
        }
    }

    func snapshot() -> (sink: any RuntimeTelemetrySink, runID: UUID) {
        lock.withLock { (sink, runID) }
    }
}

public enum RuntimeTelemetry {
    private static let sensitiveFieldParts: Set<String> = [
        "text", "transcript", "prompt", "clipboard", "audio"
    ]
    private static let sensitiveFieldNames: Set<String> = ["key", "secret"]
    private static let state = RuntimeTelemetryState()

    public struct AudioChunk: Sendable {
        public let sessionId: Int
        public let index: Int
        public let audio: Data // float32 samples representation
        public let isFinal: Bool
        public let capturedAt: TimeInterval
        public let enqueuedAt: TimeInterval

        public init(sessionId: Int, index: Int, audio: Data, isFinal: Bool, capturedAt: TimeInterval, enqueuedAt: TimeInterval) {
            self.sessionId = sessionId
            self.index = index
            self.audio = audio
            self.isFinal = isFinal
            self.capturedAt = capturedAt
            self.enqueuedAt = enqueuedAt
        }
    }

    public static func configure(
        sink: any RuntimeTelemetrySink,
        runID: UUID = UUID()
    ) {
        state.configure(sink: sink, runID: runID)
    }

    public static func emitRuntimeEvent(_ event: String, fields: [String: Any]) {
        guard fieldsArePrivacySafe(fields) else { return }

        let configured = state.snapshot()
        var payload: [String: Any] = [
            "run_id": configured.runID.uuidString,
            "monotonic": round(ProcessInfo.processInfo.systemUptime * 1_000_000) / 1_000_000,
            "wall_clock": Date().timeIntervalSince1970,
        ]

        for (k, v) in fields {
            payload[k] = v
        }
        configured.sink.emit(event: event, fields: payload)
    }

    public static func drain() async {
        await state.snapshot().sink.drain()
    }

    public static func fieldsArePrivacySafe(_ fields: [String: Any]) -> Bool {
        privacySafeDictionary(fields)
    }

    static func fieldsArePrivacySafe<S: Sequence>(_ keys: S) -> Bool where S.Element == String {
        keys.allSatisfy { key in
            let lowered = key.lowercased()
            return !sensitiveFieldNames.contains(lowered)
                && !lowered.hasSuffix("_key")
                && !lowered.hasSuffix("_secret")
                && sensitiveFieldParts.allSatisfy { !lowered.contains($0) }
        }
    }

    private static func privacySafeDictionary(_ fields: [String: Any]) -> Bool {
        fields.allSatisfy { key, value in
            fieldsArePrivacySafe(CollectionOfOne(key)) && privacySafeValue(value)
        }
    }

    private static func privacySafeValue(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            return privacySafeDictionary(dictionary)
        }
        if let array = value as? [Any] {
            return array.allSatisfy(privacySafeValue)
        }
        return true
    }

    public static func collectProcessMetrics(childPid: Int32? = nil) -> [String: Double?] {
        var metrics: [String: Double?] = [
            "parent_rss_mb": nil,
            "child_rss_mb": nil,
            "system_memory_percent": nil
        ]

        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if kerr == KERN_SUCCESS {
            metrics["parent_rss_mb"] = Double(info.resident_size) / (1024 * 1024)
        }

        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &size)
            }
        }

        if result == KERN_SUCCESS {
            let pageSize = Double(sysconf(_SC_PAGESIZE))
            let active = Double(stats.active_count) * pageSize
            let inactive = Double(stats.inactive_count) * pageSize
            let wire = Double(stats.wire_count) * pageSize
            let totalUsed = active + inactive + wire
            // Get total physical memory
            var mib = [CTL_HW, HW_MEMSIZE]
            var totalRam: UInt64 = 0
            var length = MemoryLayout<UInt64>.size
            sysctl(&mib, 2, &totalRam, &length, nil, 0)

            if totalRam > 0 {
                metrics["system_memory_percent"] = (totalUsed / Double(totalRam)) * 100.0
            }
        }

        if childPid != nil {
            // we can get the child rss using proc_pidinfo if we link libproc.
            // A simpler way for a child process would be shelling out to ps, or using proc_pidinfo via C bridging.
            // For now, we will leave child_rss_mb nil since getting other process' memory requires special entitlements or C bridging.
        }

        return metrics
    }
}
