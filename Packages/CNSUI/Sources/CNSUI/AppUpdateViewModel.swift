import Foundation
import AppKit
import CNSCore

@MainActor
public class AppUpdateViewModel {
    private let updater: AppUpdater
    private let panel: ModelDownloadPanel
    private let i18n: I18n
    private let checker: @Sendable (String) async throws -> AppUpdate?
    private var checkTask: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var panelGeneration: Int?
    private var cancellationRequested = false
    
    public private(set) var activeOperationID: UUID?
    public private(set) var readyHandle: StagedUpdateHandle?
    public private(set) var checkOperationID: UUID?

    public var onReady: ((StagedUpdateHandle) -> Void)?
    public var onCheckCompleted: ((AppUpdate?) -> Void)?
    public var onCheckFailed: ((Error) -> Void)?

    public init(
        updater: AppUpdater,
        panel: ModelDownloadPanel,
        i18n: I18n,
        checker: @escaping @Sendable (String) async throws -> AppUpdate? = { version in
            try await UpdateChecker.check(currentVersion: version)
        }
    ) {
        self.updater = updater
        self.panel = panel
        self.i18n = i18n
        self.checker = checker
    }

    public var isBusy: Bool { checkOperationID != nil || activeOperationID != nil }

    public func checkForUpdates(currentVersion: String) {
        guard !isBusy, readyHandle == nil else {
            _ = panel.bringToFront()
            return
        }
        let operationID = UUID()
        checkOperationID = operationID
        checkTask = Task {
            do {
                let update = try await checker(currentVersion)
                guard checkOperationID == operationID else { return }
                checkOperationID = nil
                checkTask = nil
                onCheckCompleted?(update)
            } catch {
                guard checkOperationID == operationID else { return }
                checkOperationID = nil
                checkTask = nil
                onCheckFailed?(error)
            }
        }
    }

    public func startUpdate(update: AppUpdate) {
        guard !isBusy, readyHandle == nil else {
            _ = panel.bringToFront()
            return
        }
        let operationID = UUID()
        self.activeOperationID = operationID
        cancellationRequested = false
        panelGeneration = panel.show(modelName: i18n.t("download.app_update", ["version": update.version]), onCancel: { [weak self] in
            self?.cancelUpdate(operationID: operationID)
        }, onRetry: { [weak self] in
            self?.startUpdate(update: update)
        })

        activeTask = Task {
            do {
                let handle = try await updater.downloadAndStage(update: update, operationID: operationID) { [weak self] progress in
                    Task { @MainActor in
                        self?.receiveProgress(progress, operationID: operationID)
                    }
                }
                guard self.activeOperationID == operationID else { return }
                if self.cancellationRequested {
                    await updater.cancelAndCleanUp(operationID: operationID)
                    self.finishCancelled(operationID: operationID)
                    return
                }
                self.activeOperationID = nil
                self.activeTask = nil
                self.readyHandle = handle
                self.panel.showCompleted(generation: self.panelGeneration)
                self.onReady?(handle)
            } catch is CancellationError {
                guard self.activeOperationID == operationID else { return }
                self.finishCancelled(operationID: operationID)
            } catch {
                guard self.activeOperationID == operationID else { return }
                if self.cancellationRequested {
                    self.finishCancelled(operationID: operationID)
                    return
                }
                self.activeOperationID = nil
                self.activeTask = nil
                self.panel.showError(error.localizedDescription, generation: self.panelGeneration)
            }
        }
    }

    private func finishCancelled(operationID: UUID) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        activeTask = nil
        cancellationRequested = false
        panel.showCancelled(generation: panelGeneration)
    }

    private func receiveProgress(_ progress: AppUpdateProgress, operationID: UUID) {
        guard self.activeOperationID == operationID else { return }
        
        let message: String
        switch progress.stage {
        case .downloading:
            if let fraction = progress.fraction {
                message = i18n.t("download.app_downloading_percent", [
                    "percent": String(Int(max(0, min(1, fraction)) * 100)),
                ])
            } else {
                message = i18n.t("download.app_downloading")
            }
        case .verifyingArchive:
            message = i18n.t("download.app_verifying_archive")
        case .staging:
            message = i18n.t("download.app_staging")
        case .verifyingCandidate:
            message = i18n.t("download.app_verifying_candidate")
        case .ready:
            message = i18n.t("download.app_ready")
        }
        
        guard !cancellationRequested else { return }
        switch progress.stage {
        case .verifyingArchive, .staging, .verifyingCandidate:
            panel.showValidating(generation: panelGeneration)
        case .downloading, .ready:
            break
        }
        panel.update(fraction: progress.fraction, message: message, generation: panelGeneration)
    }

    public func cancelUpdate(operationID: UUID) {
        guard self.activeOperationID == operationID, !cancellationRequested else { return }
        cancellationRequested = true
        activeTask?.cancel()
        Task { await updater.cancelAndCleanUp(operationID: operationID) }
    }
}
