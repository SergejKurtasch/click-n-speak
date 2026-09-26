import Foundation
import AppKit
import CNSCore

public enum AppUpdateViewState: Equatable {
    case idle
    case checking(UUID)
    case downloading(UUID)
    case readyToInstall(StagedUpdateHandle)
    case installing(StagedUpdateHandle)
    case failed(UUID, String)
}

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
    private var checkCancellationRequested = false
    
    public private(set) var activeOperationID: UUID?
    public private(set) var readyHandle: StagedUpdateHandle?
    public private(set) var checkOperationID: UUID?
    public private(set) var state: AppUpdateViewState = .idle {
        didSet { onStateChanged?(state) }
    }

    public var onReady: ((StagedUpdateHandle) -> Void)?
    public var onStateChanged: ((AppUpdateViewState) -> Void)?
    public var onInstallRequested: ((StagedUpdateHandle) -> Void)?
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

    deinit {
        checkTask?.cancel()
        activeTask?.cancel()
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        case .idle, .readyToInstall, .failed: false
        }
    }

    @discardableResult
    public func clearReadyHandle(matching handle: StagedUpdateHandle) -> Bool {
        guard readyHandle == handle else { return false }
        readyHandle = nil
        state = .idle
        return true
    }

    @discardableResult
    public func requestInstallation(handle: StagedUpdateHandle) -> Bool {
        guard readyHandle == handle, state == .readyToInstall(handle) else { return false }
        state = .installing(handle)
        onInstallRequested?(handle)
        return true
    }

    public func installationFailed(handle: StagedUpdateHandle) {
        guard readyHandle == handle, state == .installing(handle) else { return }
        state = .readyToInstall(handle)
    }

    public func checkForUpdates(currentVersion: String) {
        guard !isBusy, readyHandle == nil else {
            _ = panel.bringToFront()
            return
        }
        let operationID = UUID()
        checkOperationID = operationID
        checkCancellationRequested = false
        panelGeneration = panel.show(
            modelName: i18n.t("menu.check_updates"),
            onCancel: { [weak self] in self?.cancelCheck(operationID: operationID) },
            onRetry: { [weak self] in self?.checkForUpdates(currentVersion: currentVersion) }
        )
        panel.update(
            fraction: nil,
            message: i18n.t("download.app_checking"),
            generation: panelGeneration
        )
        state = .checking(operationID)
        let checker = self.checker
        checkTask = Task { [weak self] in
            do {
                let update = try await checker(currentVersion)
                guard let self, self.checkOperationID == operationID else { return }
                if self.checkCancellationRequested {
                    self.finishCheckCancelled(operationID: operationID)
                    return
                }
                self.checkOperationID = nil
                self.checkTask = nil
                self.panel.close()
                self.state = .idle
                self.onCheckCompleted?(update)
            } catch {
                guard let self, self.checkOperationID == operationID else { return }
                if self.checkCancellationRequested || error is CancellationError {
                    self.finishCheckCancelled(operationID: operationID)
                    return
                }
                self.checkOperationID = nil
                self.checkTask = nil
                self.state = .failed(operationID, error.localizedDescription)
                self.panel.showError(error.localizedDescription, generation: self.panelGeneration)
                self.onCheckFailed?(error)
            }
        }
    }

    private func cancelCheck(operationID: UUID) {
        guard checkOperationID == operationID, !checkCancellationRequested else { return }
        checkCancellationRequested = true
        checkTask?.cancel()
    }

    private func finishCheckCancelled(operationID: UUID) {
        guard checkOperationID == operationID else { return }
        checkOperationID = nil
        checkTask = nil
        checkCancellationRequested = false
        state = .idle
        panel.showCancelled(generation: panelGeneration)
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
        state = .downloading(operationID)

        let updater = self.updater
        activeTask = Task { [weak self] in
            do {
                let handle = try await updater.downloadAndStage(update: update, operationID: operationID) { [weak self] progress in
                    Task { @MainActor in
                        self?.receiveProgress(progress, operationID: operationID)
                    }
                }
                guard let self else {
                    await updater.cancelAndCleanUp(operationID: operationID)
                    return
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
                self.state = .readyToInstall(handle)
                self.panel.showCompleted(generation: self.panelGeneration)
                self.onReady?(handle)
            } catch is CancellationError {
                guard let self else { return }
                guard self.activeOperationID == operationID else { return }
                self.finishCancelled(operationID: operationID)
            } catch {
                guard let self else { return }
                guard self.activeOperationID == operationID else { return }
                if self.cancellationRequested {
                    self.finishCancelled(operationID: operationID)
                    return
                }
                self.activeOperationID = nil
                self.activeTask = nil
                self.state = .failed(operationID, error.localizedDescription)
                self.panel.showError(error.localizedDescription, generation: self.panelGeneration)
            }
        }
    }

    private func finishCancelled(operationID: UUID) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        activeTask = nil
        cancellationRequested = false
        state = .idle
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
        let updater = self.updater
        Task { await updater.cancelAndCleanUp(operationID: operationID) }
    }
}
