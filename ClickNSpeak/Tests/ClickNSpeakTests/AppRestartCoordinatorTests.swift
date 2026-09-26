import CNSCore
import Foundation
import Testing
@testable import ClickNSpeak

@MainActor
@Suite("Restart coordination")
struct AppRestartCoordinatorTests {
    private final class HelperState {
        var isRunning = true
        var launchCount = 0
        var terminateCount = 0
    }

    private func makeFixture(
        writeReady: Bool = true,
        helperRunning: Bool = true
    ) -> (AppRestartCoordinator, HelperState, Paths) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-restart-coordinator-\(UUID().uuidString)", isDirectory: true)
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        let state = HelperState()
        state.isRunning = helperRunning
        let coordinator = AppRestartCoordinator(
            paths: paths,
            applicationURL: directory.appendingPathComponent("Click-n-speak.app", isDirectory: true),
            helperURL: directory.appendingPathComponent("CNSRestartHelper"),
            parentPID: 421,
            readyTimeout: .milliseconds(50),
            launchHelper: { url, ticketURL in
                #expect(url.lastPathComponent == "CNSRestartHelper")
                state.launchCount += 1
                let ticket = try RestartTicketStore.read(from: ticketURL)
                #expect(ticket.parentPID == 421)
                #expect(ticket.phase == .prepared)
                if writeReady {
                    try RestartTicketStore.writeReady(
                        ticketID: ticket.id,
                        helperPID: 422,
                        in: paths.restartDirectory
                    )
                }
                return RestartHelperHandle(
                    processID: 422,
                    isRunning: { state.isRunning },
                    terminate: {
                        state.terminateCount += 1
                        state.isRunning = false
                    }
                )
            }
        )
        return (coordinator, state, paths)
    }

    @Test("Preparation waits for the exact helper and authorization follows drain")
    func prepareThenAuthorize() async throws {
        let (coordinator, state, paths) = makeFixture()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }

        try await coordinator.prepare()
        #expect(coordinator.isPending)
        #expect(state.launchCount == 1)
        #expect(state.terminateCount == 0)
        let ticketURL = try #require(coordinator.ticketURL)
        #expect(try RestartTicketStore.read(from: ticketURL).phase == .prepared)

        try coordinator.authorizeAfterDrain()
        #expect(try RestartTicketStore.read(from: ticketURL).phase == .authorized)
        #expect(state.terminateCount == 0)
    }

    @Test("Failed drain cancels the helper so a later ordinary quit cannot restart")
    func failedDrainCancelsTicket() async throws {
        let (coordinator, state, paths) = makeFixture()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try await coordinator.prepare()
        let ticketURL = try #require(coordinator.ticketURL)

        coordinator.cancel()

        #expect(!coordinator.isPending)
        #expect(state.terminateCount == 1)
        #expect(try RestartTicketStore.read(from: ticketURL).phase == .cancelled)
        #expect(throws: AppRestartError.self) {
            try coordinator.authorizeAfterDrain()
        }
    }

    @Test("Missing readiness cancels the prepared request without requesting termination")
    func helperReadinessFailure() async throws {
        let (coordinator, state, paths) = makeFixture(writeReady: false)
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }

        await #expect(throws: AppRestartError.self) {
            try await coordinator.prepare()
        }

        #expect(!coordinator.isPending)
        #expect(state.launchCount == 1)
        #expect(state.terminateCount == 1)
    }

    @Test("A missing bundled helper leaves the application running")
    func missingHelperDoesNotPrepareRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-missing-restart-helper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        let coordinator = AppRestartCoordinator(
            paths: paths,
            applicationURL: directory.appendingPathComponent("Click-n-speak.app"),
            helperURL: directory.appendingPathComponent("missing-helper")
        )

        await #expect(throws: AppRestartError.self) {
            try await coordinator.prepare()
        }
        #expect(!coordinator.isPending)
    }

    @Test("Readiness from a different helper PID is rejected at authorization")
    func staleReadinessCannotAuthorize() async throws {
        let (coordinator, state, paths) = makeFixture()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try await coordinator.prepare()
        let ticketURL = try #require(coordinator.ticketURL)
        let ticket = try RestartTicketStore.read(from: ticketURL)
        try RestartTicketStore.writeReady(
            ticketID: ticket.id,
            helperPID: 999,
            in: paths.restartDirectory
        )

        #expect(throws: AppRestartError.self) {
            try coordinator.authorizeAfterDrain()
        }
        #expect(state.terminateCount == 0)
        coordinator.cancel()
    }

    @Test("A dead helper cannot authorize a restart after a long drain")
    func deadHelperCannotAuthorize() async throws {
        let (coordinator, state, paths) = makeFixture()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try await coordinator.prepare()
        let ticketURL = try #require(coordinator.ticketURL)
        state.isRunning = false

        #expect(throws: AppRestartError.self) {
            try coordinator.authorizeAfterDrain()
        }
        #expect(try RestartTicketStore.read(from: ticketURL).phase == .prepared)
        coordinator.cancel()
    }

    @Test("A repeated click does not create another helper")
    func repeatedPreparationIsRejected() async throws {
        let (coordinator, state, paths) = makeFixture()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try await coordinator.prepare()

        await #expect(throws: AppRestartError.self) {
            try await coordinator.prepare()
        }

        #expect(state.launchCount == 1)
        coordinator.cancel()
    }

    @Test("The termination barrier authorizes restart before releasing the instance lock")
    func successfulTerminationAuthorizesBeforeRelease() async throws {
        let (coordinator, _, paths) = makeFixture()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try await coordinator.prepare()
        let ticketURL = try #require(coordinator.ticketURL)
        var phaseAtRelease: RestartTicketPhase?

        let accepted = try AppDelegate.completeTermination(
            outcome: .completed,
            restart: coordinator,
            restartRequested: true,
            releaseLock: {
                phaseAtRelease = try? RestartTicketStore.read(from: ticketURL).phase
            }
        )

        #expect(accepted)
        #expect(phaseAtRelease == .authorized)
    }

    @Test("A refused termination cancels restart before a future ordinary quit")
    func rejectedTerminationCannotRestartLater() async throws {
        let (coordinator, state, paths) = makeFixture()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try await coordinator.prepare()
        let ticketURL = try #require(coordinator.ticketURL)
        var releaseCount = 0

        let rejected = try AppDelegate.completeTermination(
            outcome: .dictionaryFailed,
            restart: coordinator,
            restartRequested: true,
            releaseLock: { releaseCount += 1 }
        )
        #expect(!rejected)
        #expect(releaseCount == 0)
        #expect(state.terminateCount == 1)
        #expect(try RestartTicketStore.read(from: ticketURL).phase == .cancelled)

        let ordinaryQuit = try AppDelegate.completeTermination(
            outcome: .completed,
            restart: coordinator,
            restartRequested: false,
            releaseLock: { releaseCount += 1 }
        )
        #expect(ordinaryQuit)
        #expect(releaseCount == 1)
        #expect(try RestartTicketStore.read(from: ticketURL).phase == .cancelled)
    }

    @Test("An ordinary quit never authorizes a prepared restart")
    func ordinaryQuitCancelsPreparedRequest() async throws {
        let (coordinator, state, paths) = makeFixture()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try await coordinator.prepare()
        let ticketURL = try #require(coordinator.ticketURL)

        let accepted = try AppDelegate.completeTermination(
            outcome: .completed,
            restart: coordinator,
            restartRequested: false,
            releaseLock: {}
        )

        #expect(accepted)
        #expect(state.terminateCount == 1)
        #expect(try RestartTicketStore.read(from: ticketURL).phase == .cancelled)
    }

    @Test("A dead helper prevents lock release after the drain")
    func deadHelperPreventsTermination() async throws {
        let (coordinator, state, paths) = makeFixture()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory) }
        try await coordinator.prepare()
        state.isRunning = false
        var released = false

        #expect(throws: AppRestartError.self) {
            try AppDelegate.completeTermination(
                outcome: .completed,
                restart: coordinator,
                restartRequested: true,
                releaseLock: { released = true }
            )
        }

        #expect(!released)
        #expect(!coordinator.isPending)
    }
}
