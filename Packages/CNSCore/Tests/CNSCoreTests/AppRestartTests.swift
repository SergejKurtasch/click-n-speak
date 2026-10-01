import Foundation
import Testing
@testable import CNSCore

private actor RestartEvents {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

@Suite("Application restart handoff")
struct AppRestartTests {
    private enum FixtureError: Error { case launch }

    private func fixture() throws -> (URL, RestartTicket) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ticket = RestartTicket(
            id: UUID(),
            parentPID: 421,
            applicationURL: directory.appendingPathComponent("Click-n-speak.app", isDirectory: true),
            phase: .prepared
        )
        let url = RestartTicketStore.ticketURL(for: ticket.id, in: directory)
        try RestartTicketStore.write(ticket, to: url)
        return (url, ticket)
    }

    @Test("The replacement is launched only after the observed parent exits and authorizes")
    func launchAfterAuthorizedExit() async throws {
        let (url, ticket) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let events = RestartEvents()

        let outcome = await RestartExecutor.run(ticketURL: url, waitForExit: { pid in
            #expect(pid == ticket.parentPID)
            await events.append("wait")
            var authorized = ticket
            authorized.phase = .authorized
            try RestartTicketStore.write(authorized, to: url)
            return true
        }, launch: { application in
            #expect(application == ticket.applicationURL)
            await events.append("launch")
        })

        #expect(outcome == .launched)
        #expect(await events.snapshot() == ["wait", "launch"])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath:
            RestartTicketStore.claimURL(for: ticket.id, in: url.deletingLastPathComponent()).path
        ))
    }

    @Test("A live parent cannot launch a second copy")
    func livingParentBlocksLaunch() async throws {
        let (url, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let events = RestartEvents()

        let outcome = await RestartExecutor.run(ticketURL: url, waitForExit: { _ in
            await events.append("wait")
            return false
        }, launch: { _ in await events.append("launch") })

        #expect(outcome == .parentDidNotExit)
        #expect(await events.snapshot() == ["wait"])
    }

    @Test("A failed termination cancels authorization even if the process later exits")
    func cancelledTicketBlocksLaunch() async throws {
        let (url, ticket) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let events = RestartEvents()

        let outcome = await RestartExecutor.run(ticketURL: url, waitForExit: { _ in
            var cancelled = ticket
            cancelled.phase = .cancelled
            try RestartTicketStore.write(cancelled, to: url)
            return true
        }, launch: { _ in await events.append("launch") })

        #expect(outcome == .cancelled)
        #expect(await events.snapshot().isEmpty)
    }

    @Test("A malformed or foreign ticket cannot launch an application")
    func invalidTicketBlocksLaunch() async throws {
        let (url, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let foreignURL = url.deletingLastPathComponent()
            .appendingPathComponent("restart-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: url, to: foreignURL)
        let events = RestartEvents()

        let outcome = await RestartExecutor.run(ticketURL: foreignURL, waitForExit: { _ in
            await events.append("wait")
            return true
        }, launch: { _ in await events.append("launch") })

        #expect(outcome == .cancelled)
        #expect(await events.snapshot().isEmpty)
    }

    @Test("A consumed ticket cannot be launched twice, including concurrent helper runs")
    func exclusiveClaimAllowsOneLaunch() async throws {
        let (url, ticket) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var authorized = ticket
        authorized.phase = .authorized
        try RestartTicketStore.write(authorized, to: url)
        let events = RestartEvents()

        async let first = RestartExecutor.run(
            ticketURL: url,
            waitForExit: { _ in true },
            launch: { _ in await events.append("launch") }
        )
        async let second = RestartExecutor.run(
            ticketURL: url,
            waitForExit: { _ in true },
            launch: { _ in await events.append("launch") }
        )
        let outcomes = await [first, second]

        #expect(outcomes.filter { $0 == .launched }.count == 1)
        #expect(await events.snapshot() == ["launch"])
        let repeated = await RestartExecutor.run(
            ticketURL: url,
            waitForExit: { _ in true },
            launch: { _ in await events.append("launch") }
        )
        #expect(repeated == .cancelled)
        #expect(await events.snapshot() == ["launch"])
    }

    @Test("A launch failure is recorded and cannot be replayed")
    func failedLaunchIsConsumed() async throws {
        let (url, ticket) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var authorized = ticket
        authorized.phase = .authorized
        try RestartTicketStore.write(authorized, to: url)

        let outcome = await RestartExecutor.run(
            ticketURL: url,
            waitForExit: { _ in true },
            launch: { _ in throw FixtureError.launch }
        )

        #expect(outcome == .launchFailed)
        #expect(try RestartTicketStore.read(from: url).phase == .consumed)
        #expect(FileManager.default.fileExists(
            atPath: RestartTicketStore.failureURL(for: ticket.id, in: url.deletingLastPathComponent()).path
        ))
    }

    @Test("The parent exit observer waits for the original process to leave")
    func observerWaitsForRealProcessExit() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["0.2"]
        try child.run()
        let observer = try RestartParentExitObserver(parentPID: child.processIdentifier)

        #expect(child.isRunning)
        #expect(try await observer.waitForExit(timeout: 2))
        child.waitUntilExit()
        #expect(!child.isRunning)
    }

    @Test("An exit observation deadline does not treat a live parent as exited")
    func observerTimesOutWhileParentLives() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["2"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let observer = try RestartParentExitObserver(parentPID: child.processIdentifier)

        #expect(try await !observer.waitForExit(timeout: 0.05))
        #expect(child.isRunning)
    }

    @Test("Startup cleanup retains claims for authorized tickets but removes completed claims")
    func claimCleanupIsScopedToCompletedTickets() throws {
        let (url, ticket) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let directory = url.deletingLastPathComponent()
        var authorized = ticket
        authorized.phase = .authorized
        try RestartTicketStore.write(authorized, to: url)
        #expect(RestartTicketStore.claim(ticketID: ticket.id, in: directory))
        let claimURL = RestartTicketStore.claimURL(for: ticket.id, in: directory)

        RestartTicketStore.cleanupCompleted(in: directory)
        #expect(FileManager.default.fileExists(atPath: claimURL.path))

        authorized.phase = .consumed
        try RestartTicketStore.write(authorized, to: url)
        RestartTicketStore.cleanupCompleted(in: directory)
        #expect(!FileManager.default.fileExists(atPath: claimURL.path))
    }
}
