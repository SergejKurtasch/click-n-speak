import Foundation
import AppKit
import CNSCore

@MainActor
public class AppUpdateViewModel {
    private let updater: AppUpdater
    private let panel: ModelDownloadPanel
    
    public private(set) var activeOperationID: UUID?
    public private(set) var readyHandle: StagedUpdateHandle?


    public var onReady: ((StagedUpdateHandle) -> Void)?
    public var onInstallRequested: ((StagedUpdateHandle) -> Void)?
    
    public init(updater: AppUpdater, panel: ModelDownloadPanel) {
        self.updater = updater
        self.panel = panel
    }

    public func showReadyAlert(handle: StagedUpdateHandle) {
        let alert = NSAlert()
        alert.messageText = "Update Ready" // Replace with i18n later if needed, but MenuBarController has i18n
        alert.informativeText = "The update has been downloaded. Restart the app to apply it."
        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            onInstallRequested?(handle)
        }
    }


    public func startUpdate(update: AppUpdate) {
        let operationID = UUID()
        self.activeOperationID = operationID
        self.readyHandle = nil
        
        let generation = panel.show(modelName: "App Update \(update.version)", onCancel: { [weak self] in
            self?.cancelUpdate(operationID: operationID)
        }, onRetry: nil)

        Task {
            do {
                let handle = try await updater.downloadAndStage(update: update, operationID: operationID) { [weak self] progress in
                    Task { @MainActor in
                        self?.receiveProgress(progress, operationID: operationID)
                    }
                }
                guard self.activeOperationID == operationID else { return }
                self.activeOperationID = nil
                self.readyHandle = handle
                self.panel.showCompleted(generation: nil)
                self.onReady?(handle)
            } catch let error as CancellationError {
                guard self.activeOperationID == operationID else { return }
                self.activeOperationID = nil
                self.panel.showCancelled(generation: nil)
            } catch {
                guard self.activeOperationID == operationID else { return }
                self.activeOperationID = nil
                self.panel.showError(error.localizedDescription, generation: nil)
            }
        }
    }

    private func receiveProgress(_ progress: AppUpdateProgress, operationID: UUID) {
        guard self.activeOperationID == operationID else { return }
        
        let message: String
        switch progress.stage {
        case .downloading:
            if let fraction = progress.fraction {
                message = "Downloading: \\(Int(fraction * 100))%"
            } else {
                message = "Downloading..."
            }
        case .verifyingArchive:
            message = "Verifying archive..."
        case .staging:
            message = "Staging update..."
        case .verifyingCandidate:
            message = "Verifying candidate..."
        case .ready:
            message = "Ready"
        }
        
        panel.update(fraction: progress.fraction, message: message, generation: nil)
    }

    public func cancelUpdate(operationID: UUID) {
        guard self.activeOperationID == operationID else { return }
        self.activeOperationID = nil
        Task { await updater.cancelAndCleanUp(operationID: operationID) }
    }
}
