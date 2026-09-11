import CNSCore
import Foundation

private enum HelperError: Error {
    case invalidArguments
    case unsafePath
}

private func value(after flag: String, arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private func write(
    _ record: UpdateSwapTransactionRecord,
    to url: URL
) {
    guard let data = try? JSONEncoder().encode(record) else { return }
    try? data.write(to: url, options: [.atomic])
}

private func waitForAcknowledgement(token: String, at ack: URL) async throws {
    for _ in 0..<600 {
        if let data = try? Data(contentsOf: ack),
           String(data: data, encoding: .utf8) == token {
            return
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw UpdateLifecycleError.acknowledgementTimedOut
}

private func run() async throws {
    let arguments = ProcessInfo.processInfo.arguments
    guard let pidText = value(after: "--parent-pid", arguments: arguments),
          let parentPID = Int32(pidText), parentPID > 1,
          let stagedPath = value(after: "--staged", arguments: arguments),
          let targetPath = value(after: "--target", arguments: arguments),
          let backupPath = value(after: "--backup", arguments: arguments),
          let token = value(after: "--token", arguments: arguments),
          UUID(uuidString: token) != nil,
          let ackPath = value(after: "--ack", arguments: arguments),
          let recordPath = value(after: "--record", arguments: arguments) else {
        throw HelperError.invalidArguments
    }

    let staged = URL(fileURLWithPath: stagedPath).standardizedFileURL
    let target = URL(fileURLWithPath: targetPath).standardizedFileURL
    let backup = URL(fileURLWithPath: backupPath).standardizedFileURL
    let ack = URL(fileURLWithPath: ackPath).standardizedFileURL
    let recordURL = URL(fileURLWithPath: recordPath).standardizedFileURL
    let installParent = target.deletingLastPathComponent()
    let updateDirectory = Paths.resolveDefault().updatesDirectory.standardizedFileURL
    guard staged.deletingLastPathComponent() == installParent,
          backup.deletingLastPathComponent() == installParent,
          target.pathExtension == "app",
          staged.pathExtension == "app",
          backup.pathExtension == "app",
          ack.path.hasPrefix(updateDirectory.path + "/"),
          recordURL.path.hasPrefix(updateDirectory.path + "/") else {
        throw HelperError.unsafePath
    }

    let processes = SystemUpdateProcessOperator()
    let lifecycle = UpdateProcessLifecycle(processes: processes)
    let failedCandidate = installParent.appendingPathComponent(
        ".click-n-speak-failed-\(token).app",
        isDirectory: true
    )
    var record = UpdateSwapTransactionRecord(
        token: token,
        targetPath: target.path,
        backupPath: backup.path,
        phase: .prepared
    )
    write(record, to: recordURL)
    try await lifecycle.installAfterParentExit(
        parentPID: parentPID,
        timeout: 30,
        staged: staged,
        target: target,
        backup: backup
    )
    record.phase = .installed
    write(record, to: recordURL)

    var replacementPID: Int32?
    do {
        replacementPID = try await lifecycle.launch(
            application: target,
            arguments: ["--update-validation-token", token, "--update-ack-path", ack.path]
        )
        try await waitForAcknowledgement(token: token, at: ack)
    } catch {
        _ = try await lifecycle.restorePreviousApplication(
            replacementPID: replacementPID,
            exitTimeout: 10,
            target: target,
            backup: backup,
            failedCandidate: failedCandidate
        )
        record.phase = .rolledBack
        write(record, to: recordURL)
        throw error
    }

    try lifecycle.finalizeSuccessfulUpdate(backup: backup)
    record.phase = .acknowledged
    write(record, to: recordURL)
    try? FileManager.default.removeItem(at: ack)
}

Task {
    do {
        try await run()
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("Click-n-speak update helper failed\n".utf8))
        exit(EXIT_FAILURE)
    }
}
dispatchMain()
