import CNSCore
import CNSDictionary
import Foundation

public enum MenuSessionPhase: String, Sendable, Equatable {
    case idle
    case recording
    case processing
    case fileProcessing
    case failed
}

public struct MenuPermissionSnapshot: Sendable, Equatable {
    public var microphone: PermissionStatus
    public var accessibilityGranted: Bool
    public var setupComplete: Bool

    public init(
        microphone: PermissionStatus = .undetermined,
        accessibilityGranted: Bool = false,
        setupComplete: Bool = false
    ) {
        self.microphone = microphone
        self.accessibilityGranted = accessibilityGranted
        self.setupComplete = setupComplete
    }
}

public enum MenuRuntimePhase: String, Sendable, Equatable {
    case uninitialized
    case preparing
    case ready
    case reconfiguring
    case degraded
    case stopping
}



public struct MenuRuntimeSnapshot: Sendable, Equatable {
    public var phase: MenuRuntimePhase
    public var desiredSTTBackend: String
    public var desiredSTTModel: String
    public var activeSTTBackend: String?
    public var activeSTTModel: String?
    public var desiredEditorBackend: String
    public var activeEditorBackend: String?
    public var activeEditorModel: String?
    public var userMessage: String?
    public var recoveryActions: [RuntimeRecoveryCommand]

    public init(
        phase: MenuRuntimePhase = .uninitialized,
        desiredSTTBackend: String = "local",
        desiredSTTModel: String = "",
        activeSTTBackend: String? = nil,
        activeSTTModel: String? = nil,
        desiredEditorBackend: String = "disabled",
        activeEditorBackend: String? = nil,
        activeEditorModel: String? = nil,
        userMessage: String? = nil,
        recoveryActions: [RuntimeRecoveryCommand] = []
    ) {
        self.phase = phase
        self.desiredSTTBackend = desiredSTTBackend
        self.desiredSTTModel = desiredSTTModel
        self.activeSTTBackend = activeSTTBackend
        self.activeSTTModel = activeSTTModel
        self.desiredEditorBackend = desiredEditorBackend
        self.activeEditorBackend = activeEditorBackend
        self.activeEditorModel = activeEditorModel
        self.userMessage = userMessage
        self.recoveryActions = recoveryActions
    }
}

public enum MenuDownloadPhase: String, Sendable, Equatable {
    case idle
    case downloading
    case validating
    case paused
    case failed
    case completed
    case cancelled
}

public enum MenuLocalModelState: String, Sendable, Equatable {
    case available
    case downloadRequired
    case downloading
    case validating
    case paused
    case active
    case updateAvailable
    case failed
}

public struct MenuDownloadSnapshot: Sendable, Equatable {
    public var phase: MenuDownloadPhase
    public var modelID: String?
    public var fractionCompleted: Double?

    public init(
        phase: MenuDownloadPhase = .idle,
        modelID: String? = nil,
        fractionCompleted: Double? = nil
    ) {
        self.phase = phase
        self.modelID = modelID
        self.fractionCompleted = fractionCompleted
    }
}

public struct MenuHistorySnapshot: Sendable, Equatable {
    public var totalCount: Int
    public var visibleLimit: Int
    public var rows: [PhraseHistoryEntry]
    public var isLoading: Bool

    public init(
        totalCount: Int = 0,
        visibleLimit: Int = 5,
        rows: [PhraseHistoryEntry] = [],
        isLoading: Bool = false
    ) {
        self.totalCount = totalCount
        self.visibleLimit = visibleLimit
        self.rows = rows
        self.isLoading = isLoading
    }
}

/// Immutable source of truth rendered by `MenuBarController`.
public struct MenuState: Sendable, Equatable {
    public var config: Config
    public var session: MenuSessionPhase
    public var permissions: MenuPermissionSnapshot
    public var runtime: MenuRuntimeSnapshot
    public var download: MenuDownloadSnapshot
    public var localModels: [String: MenuLocalModelState]
    public var autostartEnabled: Bool
    public var history: MenuHistorySnapshot
    public var pendingSuggestionCount: Int
    public var updateAvailableVersion: String?
    public var dataMode: Paths.Mode

    public init(
        config: Config,
        session: MenuSessionPhase = .idle,
        permissions: MenuPermissionSnapshot = MenuPermissionSnapshot(),
        runtime: MenuRuntimeSnapshot? = nil,
        download: MenuDownloadSnapshot = MenuDownloadSnapshot(),
        localModels: [String: MenuLocalModelState] = [:],
        autostartEnabled: Bool = false,
        history: MenuHistorySnapshot = MenuHistorySnapshot(),
        pendingSuggestionCount: Int = 0,
        updateAvailableVersion: String? = nil,
        dataMode: Paths.Mode = .dev
    ) {
        self.config = config
        self.session = session
        self.permissions = permissions
        self.runtime = runtime ?? MenuRuntimeSnapshot(
            desiredSTTBackend: config.sttBackend,
            desiredSTTModel: config.sttBackend == "local"
                ? config.sttModelName
                : (config.raw["stt_cloud_model"]?.stringValue ?? ""),
            desiredEditorBackend: config.aiEditorEnabled ? config.aiEditorBackend : "disabled"
        )
        self.download = download
        self.localModels = localModels
        self.autostartEnabled = autostartEnabled
        self.history = history
        self.pendingSuggestionCount = pendingSuggestionCount
        self.updateAvailableVersion = updateAvailableVersion
        self.dataMode = dataMode
    }
}
