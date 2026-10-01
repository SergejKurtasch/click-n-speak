import CNSCore
import Foundation
import Testing

@Suite("Restart helper process integration")
struct AppRestartHelperIntegrationTests {
    @Test("The helper launches one replacement only after the fixture parent and its lock exit")
    func waitsForParentAndPreservesDevDataDirectory() async throws {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let projectDirectory = packageDirectory.deletingLastPathComponent()
        let python = projectDirectory.appendingPathComponent("venv/bin/python")
        let sourceHelper = packageDirectory.appendingPathComponent(".build/debug/CNSRestartHelper")
        #expect(FileManager.default.isExecutableFile(atPath: sourceHelper.path))
        #expect(FileManager.default.isExecutableFile(atPath: python.path))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-restart-integration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(mode: .dev, environment: [
            "CNS_DATA_DIR": root.appendingPathComponent("profile").path
        ])
        try FileManager.default.createDirectory(at: paths.restartDirectory, withIntermediateDirectories: true)
        let app = root.appendingPathComponent("Click-n-speak.app", isDirectory: true)
        let binaries = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let helperURL = binaries.appendingPathComponent("CNSRestartHelper")
        try FileManager.default.copyItem(at: sourceHelper, to: helperURL)
        let replacementURL = binaries.appendingPathComponent("ClickNSpeak")
        let replacementScript = """
        #!/bin/sh
        exec "$CNS_TEST_PYTHON" -c 'import fcntl, os, sys
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
        status = "acquired"
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            status = "blocked"
        with open(sys.argv[2], "w") as result:
            result.write(status + ":" + os.environ["CNS_DATA_DIR"])
        ' "$CNS_TEST_LOCK" "$CNS_TEST_RESTART_MARKER"
        """
        try replacementScript.write(to: replacementURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: replacementURL.path
        )

        let lockURL = root.appendingPathComponent("fixture.lock")
        let parentReadyURL = root.appendingPathComponent("parent.ready")
        let markerURL = root.appendingPathComponent("replacement.result")
        let parent = Process()
        parent.executableURL = python
        parent.arguments = ["-c", """
        import fcntl, os, sys, time
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        with open(sys.argv[2], "w") as ready:
            ready.write("ready")
        time.sleep(1.0)
        """, lockURL.path, parentReadyURL.path]
        parent.standardOutput = FileHandle.nullDevice
        parent.standardError = FileHandle.nullDevice
        try parent.run()
        defer { if parent.isRunning { parent.terminate() } }
        let parentDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: parentReadyURL.path)
            && ContinuousClock.now < parentDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: parentReadyURL.path))
        #expect(parent.isRunning)

        let ticket = RestartTicket(
            id: UUID(),
            parentPID: parent.processIdentifier,
            applicationURL: app.standardizedFileURL,
            phase: .prepared
        )
        let ticketURL = RestartTicketStore.ticketURL(for: ticket.id, in: paths.restartDirectory)
        try RestartTicketStore.write(ticket, to: ticketURL)
        let helper = Process()
        helper.executableURL = helperURL
        helper.arguments = ["--ticket", ticketURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CNS_DATA_DIR"] = paths.dataDirectory.path
        environment["CNS_TEST_PYTHON"] = python.path
        environment["CNS_TEST_LOCK"] = lockURL.path
        environment["CNS_TEST_RESTART_MARKER"] = markerURL.path
        helper.environment = environment
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        defer { if helper.isRunning { helper.terminate() } }

        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var ready: RestartReady?
        while ready == nil && ContinuousClock.now < readyDeadline {
            ready = try? RestartTicketStore.readReady(ticketID: ticket.id, in: paths.restartDirectory)
            if ready == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(ready?.helperPID == helper.processIdentifier)
        #expect(parent.isRunning)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))

        var authorized = ticket
        authorized.phase = .authorized
        try RestartTicketStore.write(authorized, to: ticketURL)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))

        parent.waitUntilExit()
        let resultDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: markerURL.path)
            && ContinuousClock.now < resultDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        helper.waitUntilExit()
        #expect(helper.terminationStatus == 0)
        #expect(try String(contentsOf: markerURL, encoding: .utf8)
            == "acquired:\(paths.dataDirectory.path)")
        #expect(!FileManager.default.fileExists(atPath: ticketURL.path))
        #expect(FileManager.default.fileExists(atPath:
            RestartTicketStore.claimURL(for: ticket.id, in: paths.restartDirectory).path
        ))
    }
}
