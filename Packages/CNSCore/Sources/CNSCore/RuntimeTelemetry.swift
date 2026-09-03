import Foundation

public enum RuntimeTelemetry {
    private static let sensitiveFieldParts: Set<String> = [
        "text", "transcript", "prompt", "clipboard", "audio"
    ]

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

    public static func emitRuntimeEvent(_ event: String, fields: [String: Any]) {
        guard fieldsArePrivacySafe(fields.keys) else {
            print("ERROR: Sensitive runtime telemetry field is forbidden")
            return
        }

        var payload: [String: Any] = [
            "event": event,
            "monotonic": round(ProcessInfo.processInfo.systemUptime * 1000000) / 1000000
        ]

        for (k, v) in fields {
            payload[k] = v
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            if let jsonString = String(data: data, encoding: .utf8) {
                print("runtime_event \(jsonString)")
            }
        } catch {
            print("ERROR: Failed to encode telemetry event: \(error)")
        }
    }

    static func fieldsArePrivacySafe<S: Sequence>(_ keys: S) -> Bool where S.Element == String {
        keys.allSatisfy { key in
            let lowered = key.lowercased()
            return sensitiveFieldParts.allSatisfy { !lowered.contains($0) }
        }
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
