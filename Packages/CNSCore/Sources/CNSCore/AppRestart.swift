import Darwin
import Foundation

public enum RestartTicketPhase: String, Codable, Sendable {
    case prepared
    case authorized
    case consumed
    case cancelled
}

public struct RestartTicket: Codable, Sendable, Equatable {
    public let id: UUID
    public let parentPID: Int32
    public let applicationURL: URL
    public var phase: RestartTicketPhase

    public init(id: UUID, parentPID: Int32, applicationURL: URL, phase: RestartTicketPhase) {
        self.id = id
        self.parentPID = parentPID
        self.applicationURL = applicationURL
        self.phase = phase
    }
}

public struct RestartReady: Codable, Sendable, Equatable {
    public let ticketID: UUID
    public let helperPID: Int32

    public init(ticketID: UUID, helperPID: Int32) {
        self.ticketID = ticketID
        self.helperPID = helperPID
    }
}

public enum RestartOutcome: Sendable, Equatable {
    case launched
    case cancelled
    case parentDidNotExit
    case launchFailed
}

public enum AppRestartError: Error, Sendable {
    case alreadyPending
    case helperMissing
    case helperNotReady
    case invalidTicket
    case parentObservationFailed
}

public enum RestartTicketStore {
    public static func ticketURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("restart-\(id.uuidString).json")
    }

    public static func readyURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("ready-\(id.uuidString).json")
    }

    public static func claimURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("claim-\(id.uuidString).lock")
    }

    public static func failureURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("failure-\(id.uuidString).txt")
    }

    public static func write(_ ticket: RestartTicket, to url: URL) throws {
        guard isValid(ticket, at: url) else { throw AppRestartError.invalidTicket }
        try AtomicFile.writeData(JSONEncoder().encode(ticket), to: url)
    }

    public static func read(from url: URL) throws -> RestartTicket {
        let ticket = try JSONDecoder().decode(RestartTicket.self, from: Data(contentsOf: url))
        guard isValid(ticket, at: url) else { throw AppRestartError.invalidTicket }
        return ticket
    }

    public static func writeReady(ticketID: UUID, helperPID: Int32, in directory: URL) throws {
        guard helperPID > 1 else { throw AppRestartError.invalidTicket }
        let ready = RestartReady(ticketID: ticketID, helperPID: helperPID)
        try AtomicFile.writeData(
            JSONEncoder().encode(ready),
            to: readyURL(for: ticketID, in: directory)
        )
    }

    public static func readReady(ticketID: UUID, in directory: URL) throws -> RestartReady {
        let data = try Data(contentsOf: readyURL(for: ticketID, in: directory))
        let ready = try JSONDecoder().decode(RestartReady.self, from: data)
        guard ready.ticketID == ticketID, ready.helperPID > 1 else {
            throw AppRestartError.invalidTicket
        }
        return ready
    }

    /// This exclusive claim remains even if a launch attempt fails. A second
    /// helper must never replay the same authorized restart ticket.
    public static func claim(ticketID: UUID, in directory: URL) -> Bool {
        let url = claimURL(for: ticketID, in: directory)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        _ = fsync(descriptor)
        close(descriptor)
        return true
    }

    public static func recordFailure(ticketID: UUID, in directory: URL) {
        try? AtomicFile.writeText("launch_failed\n", to: failureURL(for: ticketID, in: directory))
    }

    public static func finishSuccessfulLaunch(ticketID: UUID, ticketURL: URL) {
        try? FileManager.default.removeItem(at: ticketURL)
        try? FileManager.default.removeItem(
            at: readyURL(for: ticketID, in: ticketURL.deletingLastPathComponent())
        )
    }

    /// Called after the replacement process has acquired the single-instance
    /// lock. It only removes claims with no authorized, unconsumed ticket.
    public static func cleanupCompleted(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in files where url.lastPathComponent.hasPrefix("claim-")
            && url.pathExtension == "lock" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: String(stem.dropFirst("claim-".count))) else { continue }
            let ticketURL = ticketURL(for: id, in: directory)
            if let ticket = try? read(from: ticketURL), ticket.phase != .consumed {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func isValid(_ ticket: RestartTicket, at url: URL) -> Bool {
        ticket.parentPID > 1
            && ticket.applicationURL.isFileURL
            && ticket.applicationURL.pathExtension == "app"
            && ticket.applicationURL.standardizedFileURL == ticket.applicationURL
            && url.standardizedFileURL.lastPathComponent == "restart-\(ticket.id.uuidString).json"
    }
}

public enum RestartExecutor {
    public static func run(
        ticketURL: URL,
        waitForExit: @escaping @Sendable (Int32) async throws -> Bool,
        launch: @escaping @Sendable (URL) async throws -> Void
    ) async -> RestartOutcome {
        guard let original = try? RestartTicketStore.read(from: ticketURL),
              original.phase == .prepared || original.phase == .authorized else {
            return .cancelled
        }
        let exited: Bool
        do {
            exited = try await waitForExit(original.parentPID)
        } catch {
            return .parentDidNotExit
        }
        guard exited else { return .parentDidNotExit }
        guard var current = try? RestartTicketStore.read(from: ticketURL),
              current.id == original.id,
              current.parentPID == original.parentPID,
              current.applicationURL == original.applicationURL,
              current.phase == .authorized else {
            return .cancelled
        }
        let directory = ticketURL.deletingLastPathComponent()
        guard RestartTicketStore.claim(ticketID: current.id, in: directory) else {
            return .cancelled
        }
        current.phase = .consumed
        do {
            try RestartTicketStore.write(current, to: ticketURL)
        } catch {
            RestartTicketStore.recordFailure(ticketID: current.id, in: directory)
            return .launchFailed
        }
        do {
            try await launch(current.applicationURL)
            RestartTicketStore.finishSuccessfulLaunch(ticketID: current.id, ticketURL: ticketURL)
            return .launched
        } catch {
            RestartTicketStore.recordFailure(ticketID: current.id, in: directory)
            return .launchFailed
        }
    }
}

/// Registers NOTE_EXIT before the helper announces readiness. That event is
/// tied to the original process rather than a later process reusing the PID.
public final class RestartParentExitObserver: @unchecked Sendable {
    private let descriptor: Int32

    public init(parentPID: Int32) throws {
        guard parentPID > 1 else { throw AppRestartError.parentObservationFailed }
        let queue = kqueue()
        guard queue >= 0 else { throw AppRestartError.parentObservationFailed }
        var event = kevent(
            ident: UInt(parentPID),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else {
            close(queue)
            throw AppRestartError.parentObservationFailed
        }
        descriptor = queue
    }

    deinit { close(descriptor) }

    public func waitForExit(timeout: TimeInterval) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var result = kevent()
            var period = timespec(tv_sec: 0, tv_nsec: 100_000_000)
            let count = kevent(descriptor, nil, 0, &result, 1, &period)
            if count == 1 {
                return (result.fflags & UInt32(NOTE_EXIT)) != 0
            }
            if count < 0 && errno != EINTR {
                throw AppRestartError.parentObservationFailed
            }
        }
        return false
    }
}
