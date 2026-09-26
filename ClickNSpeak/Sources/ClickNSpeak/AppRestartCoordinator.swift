import CNSCore
import Foundation

@MainActor
struct RestartHelperHandle {
    let processID: Int32
    let isRunning: () -> Bool
    let terminate: () -> Void
}

/// Owns one ordinary restart request until the AppDelegate termination barrier
/// either authorizes it or cancels it. The helper never receives user content.
@MainActor
final class AppRestartCoordinator {
    private enum State {
        case idle
        case preparing
        case prepared
        case authorized
    }

    private let paths: Paths
    private let applicationURL: URL
    private let helperURL: URL
    private let parentPID: Int32
    private let readyTimeout: Duration
    private let launchHelper: (URL, URL) throws -> RestartHelperHandle
    private var helper: RestartHelperHandle?
    private var state = State.idle
    private(set) var ticketURL: URL?

    var isPending: Bool { state != .idle }

    init(
        paths: Paths,
        applicationURL: URL,
        helperURL: URL,
        parentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        readyTimeout: Duration = .seconds(5),
        launchHelper: ((URL, URL) throws -> RestartHelperHandle)? = nil
    ) {
        self.paths = paths
        self.applicationURL = applicationURL.standardizedFileURL
        self.helperURL = helperURL.standardizedFileURL
        self.parentPID = parentPID
        self.readyTimeout = readyTimeout
        self.launchHelper = launchHelper ?? Self.startSystemHelper
    }

    func prepare() async throws {
        guard state == .idle else { throw AppRestartError.alreadyPending }
        state = .preparing
        let id = UUID()
        let url = RestartTicketStore.ticketURL(for: id, in: paths.restartDirectory)
        ticketURL = url
        do {
            let ticket = RestartTicket(
                id: id,
                parentPID: parentPID,
                applicationURL: applicationURL,
                phase: .prepared
            )
            try RestartTicketStore.write(ticket, to: url)
            let launched = try launchHelper(helperURL, url)
            helper = launched
            let deadline = ContinuousClock.now.advanced(by: readyTimeout)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard launched.isRunning() else { throw AppRestartError.helperNotReady }
                if let ready = try? RestartTicketStore.readReady(
                    ticketID: id,
                    in: paths.restartDirectory
                ), ready.helperPID == launched.processID {
                    state = .prepared
                    return
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw AppRestartError.helperNotReady
        } catch {
            cancel()
            throw error
        }
    }

    func authorizeAfterDrain() throws {
        guard state == .prepared, let helper, helper.isRunning(), let ticketURL else {
            throw AppRestartError.helperNotReady
        }
        var ticket = try RestartTicketStore.read(from: ticketURL)
        guard ticket.phase == .prepared,
              let ready = try? RestartTicketStore.readReady(
                  ticketID: ticket.id,
                  in: paths.restartDirectory
              ), ready.helperPID == helper.processID else {
            throw AppRestartError.helperNotReady
        }
        ticket.phase = .authorized
        try RestartTicketStore.write(ticket, to: ticketURL)
        state = .authorized
    }

    func cancel() {
        if let helper, helper.isRunning() {
            helper.terminate()
        }
        if let ticketURL, var ticket = try? RestartTicketStore.read(from: ticketURL),
           ticket.phase != .consumed {
            ticket.phase = .cancelled
            try? RestartTicketStore.write(ticket, to: ticketURL)
        }
        helper = nil
        ticketURL = nil
        state = .idle
    }

    private static func startSystemHelper(
        at helperURL: URL,
        ticketURL: URL
    ) throws -> RestartHelperHandle {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw AppRestartError.helperMissing
        }
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--ticket", ticketURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return RestartHelperHandle(
            processID: process.processIdentifier,
            isRunning: { process.isRunning },
            terminate: { if process.isRunning { process.terminate() } }
        )
    }
}
