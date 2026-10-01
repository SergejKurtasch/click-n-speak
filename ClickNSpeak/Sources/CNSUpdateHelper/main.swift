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

private func waitForAcknowledgement(
    token: String,
    candidate: UpdateCandidateIdentity,
    processID: Int32,
    at ack: URL
) async throws -> UpdateLaunchStatus {
    for _ in 0..<600 {
        if let data = try? Data(contentsOf: ack),
           let acknowledgement = try? JSONDecoder().decode(
               UpdateLaunchAcknowledgement.self,
               from: data
           ),
           acknowledgement.matches(token: token, candidate: candidate, processID: processID) {
            return acknowledgement.status
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw UpdateLifecycleError.acknowledgementTimedOut
}

private func transactionFailure(for error: Error) -> UpdateTransactionFailure {
    switch error {
    case UpdateLifecycleError.parentDidNotExit:
        .parentDidNotExit
    case UpdateLifecycleError.acknowledgementTimedOut:
        .acknowledgementTimedOut
    case UpdateLifecycleError.replacementDidNotExit:
        .replacementDidNotExit
    case is AppSwapError:
        .rollbackFailed
    default:
        .launchFailed
    }
}

private func rollbackReplacement(
    processID: Int32?,
    failure: UpdateTransactionFailure,
    lifecycle: UpdateProcessLifecycle,
    store: FileUpdateTransactionStore,
    recordURL: URL,
    target: URL,
    backup: URL,
    failedCandidate: URL,
    record: inout UpdateSwapTransactionRecord
) async throws {
    record.phase = .rollbackPending
    record.failure = failure
    try store.save(record, to: recordURL)
    do {
        _ = try await lifecycle.restorePreviousApplication(
            replacementPID: processID,
            exitTimeout: 10,
            target: target,
            backup: backup,
            failedCandidate: failedCandidate
        )
    } catch {
        record.failure = transactionFailure(for: error)
        try store.save(record, to: recordURL)
        throw error
    }
    record.phase = .rolledBack
    try store.save(record, to: recordURL)
    try lifecycle.discardFailedCandidate(at: failedCandidate)
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
          let transactionID = value(after: "--transaction-id", arguments: arguments),
          UUID(uuidString: transactionID) != nil,
          let candidateVersion = value(after: "--candidate-version", arguments: arguments),
          let candidateBuild = value(after: "--candidate-build", arguments: arguments),
          let candidateSHA256 = value(after: "--candidate-sha256", arguments: arguments),
          candidateSHA256.count == 64,
          candidateSHA256.allSatisfy(\.isHexDigit),
          let candidateExecutableSHA256 = value(
              after: "--candidate-executable-sha256",
              arguments: arguments
          ),
          candidateExecutableSHA256.count == 64,
          candidateExecutableSHA256.allSatisfy(\.isHexDigit),
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
          staged != target,
          backup != target,
          staged != backup,
          target.pathExtension == "app",
          staged.pathExtension == "app",
          backup.pathExtension == "app",
          staged.lastPathComponent == ".Click-n-speak.update-\(transactionID).app",
          backup.lastPathComponent == ".Click-n-speak.backup-\(transactionID).app",
          ack.lastPathComponent == "ack-\(transactionID)",
          recordURL.lastPathComponent == "transaction-\(transactionID).json",
          ack.path.hasPrefix(updateDirectory.path + "/"),
          recordURL.path.hasPrefix(updateDirectory.path + "/") else {
        throw HelperError.unsafePath
    }

    let processes = SystemUpdateProcessOperator()
    let lifecycle = UpdateProcessLifecycle(processes: processes)
    let store = FileUpdateTransactionStore()
    let failedCandidate = installParent.appendingPathComponent(
        ".click-n-speak-failed-\(token).app",
        isDirectory: true
    )
    let candidate = UpdateCandidateIdentity(
        version: candidateVersion,
        build: candidateBuild,
        archiveSHA256: candidateSHA256,
        executableSHA256: candidateExecutableSHA256
    )
    var record = UpdateSwapTransactionRecord(
        token: token,
        transactionID: transactionID,
        targetPath: target.path,
        backupPath: backup.path,
        stagedPath: staged.path,
        failedCandidatePath: failedCandidate.path,
        acknowledgementPath: ack.path,
        candidate: candidate,
        phase: .prepared
    )
    try store.save(record, to: recordURL)
    record.phase = .installing
    try store.save(record, to: recordURL)
    do {
        try await lifecycle.installAfterParentExit(
            parentPID: parentPID,
            timeout: 30,
            staged: staged,
            target: target,
            backup: backup
        )
    } catch {
        record.failure = error is AppSwapError ? .installFailed : transactionFailure(for: error)
        try store.save(record, to: recordURL)
        throw error
    }
    record.phase = .installed
    record.failure = nil
    try store.save(record, to: recordURL)

    let replacementPID: Int32
    do {
        replacementPID = try await lifecycle.launch(
            application: target,
            arguments: [
                "--update-validation-token", token,
                "--update-ack-path", ack.path,
                "--update-candidate-version", candidateVersion,
                "--update-candidate-build", candidateBuild,
                "--update-candidate-sha256", candidateSHA256,
                "--update-candidate-executable-sha256", candidateExecutableSHA256,
            ]
        )
    } catch {
        let launchError = error
        try await rollbackReplacement(
            processID: nil,
            failure: .launchFailed,
            lifecycle: lifecycle,
            store: store,
            recordURL: recordURL,
            target: target,
            backup: backup,
            failedCandidate: failedCandidate,
            record: &record
        )
        throw launchError
    }
    record.replacementProcessID = replacementPID
    record.phase = .launched
    try store.save(record, to: recordURL)

    do {
        record.acknowledgementStatus = try await waitForAcknowledgement(
            token: token,
            candidate: candidate,
            processID: replacementPID,
            at: ack
        )
    } catch {
        let acknowledgementError = error
        try await rollbackReplacement(
            processID: replacementPID,
            failure: transactionFailure(for: acknowledgementError),
            lifecycle: lifecycle,
            store: store,
            recordURL: recordURL,
            target: target,
            backup: backup,
            failedCandidate: failedCandidate,
            record: &record
        )
        throw acknowledgementError
    }

    record.phase = .launchAcknowledged
    record.failure = nil
    try store.save(record, to: recordURL)
    record.phase = .finalizing
    try store.save(record, to: recordURL)
    do {
        try lifecycle.finalizeSuccessfulUpdate(backup: backup)
    } catch {
        record.failure = .finalizeFailed
        try store.save(record, to: recordURL)
        throw error
    }
    record.phase = .finalized
    try store.save(record, to: recordURL)
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
