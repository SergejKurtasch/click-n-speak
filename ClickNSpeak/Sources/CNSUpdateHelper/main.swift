import AppKit
import CNSCore
import Darwin
import Foundation

private enum HelperError: Error {
    case invalidArguments
    case unsafePath
    case launchFailed
}

private func value(after flag: String, arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private func launch(_ application: URL, token: String? = nil, ack: URL? = nil) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    var arguments = ["-n", application.path]
    if let token, let ack {
        arguments += ["--args", "--update-validation-token", token, "--update-ack-path", ack.path]
    }
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw HelperError.launchFailed }
}

private func write(
    _ record: UpdateSwapTransactionRecord,
    to url: URL
) {
    guard let data = try? JSONEncoder().encode(record) else { return }
    try? data.write(to: url, options: [.atomic])
}

private func run() throws {
    let arguments = ProcessInfo.processInfo.arguments
    guard let pidText = value(after: "--parent-pid", arguments: arguments),
          let parentPID = pid_t(pidText), parentPID > 1,
          let stagedPath = value(after: "--staged", arguments: arguments),
          let targetPath = value(after: "--target", arguments: arguments),
          let backupPath = value(after: "--backup", arguments: arguments),
          let token = value(after: "--token", arguments: arguments),
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

    for _ in 0..<300 where kill(parentPID, 0) == 0 {
        Thread.sleep(forTimeInterval: 0.1)
    }
    let swap = RecoverableAppSwap()
    var record = UpdateSwapTransactionRecord(
        token: token,
        targetPath: target.path,
        backupPath: backup.path,
        phase: .prepared
    )
    write(record, to: recordURL)
    try swap.install(staged: staged, target: target, backup: backup)
    record.phase = .installed
    write(record, to: recordURL)

    do {
        try launch(target, token: token, ack: ack)
        var acknowledged = false
        for _ in 0..<600 {
            if let data = try? Data(contentsOf: ack),
               String(data: data, encoding: .utf8) == token {
                acknowledged = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard acknowledged else { throw HelperError.launchFailed }
        try swap.finalize(backup: backup)
        record.phase = .acknowledged
        write(record, to: recordURL)
        try? FileManager.default.removeItem(at: ack)
    } catch {
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.sergej.clicknspeak"
        ) {
            application.terminate()
        }
        try swap.rollback(target: target, backup: backup)
        record.phase = .rolledBack
        write(record, to: recordURL)
        try? launch(target)
        throw error
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("Click-n-speak update helper failed\n".utf8))
    exit(EXIT_FAILURE)
}
