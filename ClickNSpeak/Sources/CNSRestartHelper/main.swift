import CNSCore
import Foundation

private func ticketArgument(_ arguments: [String]) -> URL? {
    guard arguments.count == 3, arguments[1] == "--ticket" else { return nil }
    let url = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    guard url.path == arguments[2] else { return nil }
    return url
}

private func run() async throws -> RestartOutcome {
    guard let ticketURL = ticketArgument(CommandLine.arguments) else {
        throw AppRestartError.invalidTicket
    }
    let paths = Paths.resolveDefault()
    guard ticketURL.deletingLastPathComponent() == paths.restartDirectory.standardizedFileURL else {
        throw AppRestartError.invalidTicket
    }
    let ticket = try RestartTicketStore.read(from: ticketURL)
    guard ticket.phase == .prepared else { throw AppRestartError.invalidTicket }

    let helperURL = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath().standardizedFileURL
    let macOSDirectory = helperURL.deletingLastPathComponent()
    let contentsDirectory = macOSDirectory.deletingLastPathComponent()
    let applicationURL = contentsDirectory.deletingLastPathComponent()
    guard helperURL.lastPathComponent == "CNSRestartHelper",
          macOSDirectory.lastPathComponent == "MacOS",
          contentsDirectory.lastPathComponent == "Contents",
          applicationURL.pathExtension == "app",
          ticket.applicationURL.resolvingSymlinksInPath() == applicationURL,
          FileManager.default.isExecutableFile(
              atPath: applicationURL.appendingPathComponent("Contents/MacOS/ClickNSpeak").path
          ) else {
        throw AppRestartError.invalidTicket
    }

    // Register the original PID before telling the parent we are ready.
    let observer = try RestartParentExitObserver(parentPID: ticket.parentPID)
    try RestartTicketStore.writeReady(
        ticketID: ticket.id,
        helperPID: ProcessInfo.processInfo.processIdentifier,
        in: paths.restartDirectory
    )

    return await RestartExecutor.run(
        ticketURL: ticketURL,
        waitForExit: { parentPID in
            guard parentPID == ticket.parentPID else { throw AppRestartError.invalidTicket }
            return try await observer.waitForExit(timeout: 60)
        },
        launch: { bundleURL in
            guard bundleURL == applicationURL else { throw AppRestartError.invalidTicket }
            let process = Process()
            process.executableURL = bundleURL.appendingPathComponent("Contents/MacOS/ClickNSpeak")
            process.arguments = []
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
    )
}

@main
private enum RestartHelperMain {
    static func main() async {
        do {
            switch try await run() {
            case .launched, .cancelled:
                Foundation.exit(EXIT_SUCCESS)
            case .parentDidNotExit:
                Foundation.exit(2)
            case .launchFailed:
                Foundation.exit(3)
            }
        } catch {
            Foundation.exit(1)
        }
    }
}
