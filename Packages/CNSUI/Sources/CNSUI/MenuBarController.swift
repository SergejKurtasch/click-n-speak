import AppKit
import CNSCore
import CNSDictionary
import CNSTranscription

/// Owns the `NSStatusItem` and builds the full menu tree. The native menu keeps
/// Python feature parity while consolidating model/runtime controls where the
/// Swift implementation can expose factual readiness and download state.
///
/// Deviation from the Python menu (documented in SWIFT_MIGRATION_PLAN.md §4.3):
/// the Permissions submenu has two items (Microphone, Accessibility), not three
/// — Input Monitoring is gone because the hotkey uses Carbon RegisterEventHotKey.
@MainActor
public final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem?
    public private(set) var config: Config
    private var fileDropPanel: FileDropPanel?
    private var suggestionsPanel: SuggestionsPanel?
    private var termsPanel: TermsPanel?
    private var replacementsPanel: ReplacementsPanel?
    private let phraseHistory: any PhraseHistoryProviding
    private let dictionaryCoordinator: DictionaryCoordinator?
    private let i18n: I18n
    private let resources: AppResources
    private let log: (String) -> Void
    private let paths: Paths
    private let permissionService: any PermissionServicing
    public var onConfigChanged: ((Config) -> Void)?
    public var onLanguageSettingsChanged: ((Config) -> Void)?
    public var onConfigurationReloaded: ((Config) throws -> Void)?
    public var onTranscribeFileAction: ((
        URL,
        Bool,
        @escaping @Sendable (FileTranscriptionProgress) -> Void
    ) async -> FileTranscriptionResult)?
    public var onCancelFileTranscription: (() -> Void)?
    public var onSetupRequested: (() -> Void)?
    public var onCredentialsChanged: ((String) -> Void)?
    public var onModelDownloadCompleted: ((String) -> Void)?
    public var onPermissionRefreshRequested: (() -> Void)?
    public var onRevertTermsRequested: (() -> Void)?
    public var onDownloadStateChanged: ((MenuDownloadSnapshot) -> Void)?
    public var onHistorySnapshotChanged: ((MenuHistorySnapshot) -> Void)?
    public var onLocalModelsChanged: (() -> Void)?
    public var onRuntimeRecoveryRequested: ((MenuRuntimeRecoveryAction) -> Void)?

    /// The built menu tree, exposed for structural tests.
    public let menu: NSMenu

    private var microphoneItem: NSMenuItem?
    private var accessibilityItem: NSMenuItem?
    private var permissionsParentItem: NSMenuItem?
    private var autostartItem: NSMenuItem?

    private var lastPhrasesMenu: NSMenu?
    private var historyLoadGeneration = 0
    private var copiedPanel: NSPanel?
    private var menuIsTracking = false
    private var pendingState: MenuState?
    private var renderedState: MenuState
    public private(set) var state: MenuState
    public private(set) var statusIconState: String = "idle"

    // MARK: - Model Download

    /// Model downloader — injected by the app so the menu can trigger downloads.
    public var modelDownloader: ModelDownloader?

    /// Download progress panel.
    private lazy var downloadPanel = ModelDownloadPanel(i18n: i18n, log: log)
    private var appUpdateTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?

    /// - Parameter installStatusItem: when false, no `NSStatusItem` is created,
    ///   so the menu tree can be built and inspected headlessly in tests.
    public init(
        config: Config,
        i18n: I18n,
        resources: AppResources,
        paths: Paths,
        permissionService: (any PermissionServicing)? = nil,
        phraseHistory: (any PhraseHistoryProviding)? = nil,
        dictionaryCoordinator: DictionaryCoordinator? = nil,
        initialState: MenuState? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in },
        installStatusItem: Bool = true
    ) {
        self.config = config
        self.i18n = i18n
        self.resources = resources
        self.paths = paths
        self.permissionService = permissionService ?? SystemPermissionService(paths: paths)
        self.phraseHistory = phraseHistory ?? PhraseHistory(fileURL: paths.phraseHistoryFile, log: log)
        self.dictionaryCoordinator = dictionaryCoordinator
        self.log = log
        self.menu = NSMenu()
        let initial = initialState ?? MenuState(
            config: config,
            autostartEnabled: Autostart.isEnabled(),
            dataMode: paths.mode
        )
        self.state = initial
        self.renderedState = initial
        self.statusItem = installStatusItem
            ? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            : nil
        super.init()

        populate(menu: menu)
        menu.delegate = self

        if let statusItem {
            statusItem.menu = menu
        }
        updateStatusItem(for: initial)
    }

    public func updateConfig(_ newConfig: Config) {
        var updated = state
        updated.config = newConfig
        updated.runtime.desiredSTTBackend = newConfig.sttBackend
        updated.runtime.desiredSTTModel = newConfig.sttBackend == "local"
            ? newConfig.sttModelName
            : (newConfig.raw["stt_cloud_model"]?.stringValue ?? "")
        updated.runtime.desiredEditorBackend = newConfig.aiEditorEnabled
            ? newConfig.aiEditorBackend
            : "disabled"
        apply(updated)
    }

    public func updateRuntimeStatus(_ label: String?) {
        var updated = state
        updated.runtime.userMessage = label
        apply(updated)
    }

    public func apply(_ newState: MenuState) {
        let previous = state
        state = newState
        config = newState.config
        termsPanel?.refresh()
        suggestionsPanel?.refresh()
        replacementsPanel?.refresh()
        updateStatusItem(for: newState)

        if menuIsTracking {
            pendingState = newState
            if previous.history != newState.history {
                renderedState.history = newState.history
                rebuildLastPhrasesMenu()
            }
            updatePermissionsMenu(using: newState.permissions)
            return
        }
        renderedState = newState
        pendingState = nil
        menu.removeAllItems()
        populate(menu: menu)
    }

    public func refreshHistory(reset: Bool) {
        historyLoadGeneration += 1
        let generation = historyLoadGeneration
        let limit = reset ? 5 : state.history.visibleLimit
        var loading = state
        loading.history.visibleLimit = limit
        loading.history.isLoading = true
        publishHistory(loading.history)
        Task { [weak self, phraseHistory] in
            let page = await phraseHistory.loadPage(limit: limit)
            guard let self, generation == self.historyLoadGeneration else { return }
            let snapshot = MenuHistorySnapshot(
                totalCount: page.totalCount,
                visibleLimit: limit,
                rows: page.entries,
                isLoading: false
            )
            self.publishHistory(snapshot)
        }
    }

    public func presentPendingSuggestionsIfNeeded() {
        guard let dictionaryCoordinator else { return }
        let pending = dictionaryCoordinator.pendingSuggestions()
        let count = pending.values.reduce(0) { $0 + $1.count }
        guard Self.shouldPresentPendingSuggestions(config: config, pendingCount: count) else {
            return
        }
        presentSuggestionsPanel(using: dictionaryCoordinator)
    }

    static func shouldPresentPendingSuggestions(config: Config, pendingCount: Int) -> Bool {
        let mode = config.raw["prompt_update_mode"]?.stringValue ?? "suggest"
        return pendingCount > 0 && mode == "suggest"
    }

    private func presentSuggestionsPanel(using coordinator: DictionaryCoordinator) {
        if suggestionsPanel == nil {
            suggestionsPanel = SuggestionsPanel(coordinator: coordinator, i18n: i18n)
        }
        suggestionsPanel?.presentPanel()
    }

    private func publishHistory(_ history: MenuHistorySnapshot) {
        if let onHistorySnapshotChanged {
            onHistorySnapshotChanged(history)
        } else {
            var updated = state
            updated.history = history
            apply(updated)
        }
    }

    // MARK: - Menu construction

    private func t(_ key: String) -> String { i18n.t(key) }
    private func t(_ key: String, _ args: [String: String]) -> String { i18n.t(key, args) }

    private func item(
        _ title: String,
        _ selector: Selector?,
        icon: String? = nil,
        checked: Bool = false,
        id: String? = nil
    ) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        mi.target = self
        mi.state = checked ? .on : .off
        if let id { mi.identifier = NSUserInterfaceItemIdentifier(id) }
        if let icon = icon {
            mi.image = resources.menuItemIcon(name: icon)
        }
        return mi
    }

    private func parentItem(_ title: String, icon: String? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let icon = icon {
            mi.image = resources.menuItemIcon(name: icon)
        }
        return mi
    }

    private func choiceItem(
        _ title: String,
        value: String,
        _ selector: Selector?,
        state: NSControl.StateValue
    ) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        mi.target = self
        mi.representedObject = value
        mi.identifier = NSUserInterfaceItemIdentifier("choice.\(value)")
        mi.state = state
        return mi
    }

    private func updateStatusItem(for state: MenuState) {
        let iconState: String
        switch state.session {
        case .idle, .failed:
            iconState = "idle"
        case .recording:
            iconState = "recording"
        case .processing, .fileProcessing:
            iconState = "processing"
        }
        statusIconState = iconState
        if let icon = resources.menuBarIcon(state: iconState) {
            statusItem?.button?.image = icon
            statusItem?.button?.title = ""
        } else {
            statusItem?.button?.image = nil
            statusItem?.button?.title = "CnS"
            resources.logMissingAssetOnce("menubar/\(iconState)Template.png", log: log)
        }
        statusItem?.button?.toolTip = runtimeLabel(state.runtime)
    }

    private func runtimeLabel(_ runtime: MenuRuntimeSnapshot) -> String {
        if let message = runtime.userMessage, !message.isEmpty { return message }
        switch runtime.phase {
        case .uninitialized:
            return t("menu.runtime_uninitialized")
        case .preparing:
            return t("menu.runtime_preparing")
        case .ready:
            return t("menu.runtime_active")
                .replacingOccurrences(of: "{backend}", with: runtime.activeSTTBackend ?? "—")
                .replacingOccurrences(of: "{model}", with: runtime.activeSTTModel ?? "—")
        case .reconfiguring:
            return t("menu.runtime_pending")
                .replacingOccurrences(of: "{backend}", with: runtime.desiredSTTBackend)
        case .degraded:
            return t("menu.runtime_unavailable")
        case .stopping:
            return t("menu.runtime_stopping")
        }
    }

    private func populate(menu: NSMenu) {
        menu.autoenablesItems = false

        // Permissions
        let permissionSnapshot = renderedState.permissions
        let allPermissionsGranted = permissionSnapshot.microphone == .granted
            && permissionSnapshot.accessibilityGranted
        let permissions = parentItem(
            t("menu.permissions"),
            icon: allPermissionsGranted ? "permissions-ok" : "permissions-warn"
        )
        permissions.identifier = NSUserInterfaceItemIdentifier("permissions")
        permissionsParentItem = permissions
        let permSub = NSMenu()
        permSub.autoenablesItems = false
        let mic = item(
            micTitle(permissionSnapshot),
            #selector(onMicrophone),
            icon: permissionSnapshot.microphone == .granted ? "microphone-ok" : "microphone-warn",
            id: "permission.microphone"
        )
        let acc = item(
            accessibilityTitle(permissionSnapshot),
            #selector(onAccessibility),
            icon: permissionSnapshot.accessibilityGranted ? "accessibility-ok" : "accessibility-warn",
            id: "permission.accessibility"
        )
        microphoneItem = mic
        accessibilityItem = acc
        permSub.addItem(mic)
        permSub.addItem(acc)
        permissions.submenu = permSub
        menu.addItem(permissions)
        menu.addItem(.separator())

        // Model
        let model = parentItem(t("menu.model"), icon: "model")
        model.identifier = NSUserInterfaceItemIdentifier("model")
        model.submenu = buildModelSubmenu()
        menu.addItem(model)
        if shouldShowDownloadProgressItem(renderedState.download) {
            menu.addItem(item(
                downloadProgressMenuTitle(renderedState.download),
                #selector(onShowDownloadProgress),
                icon: "download-model",
                id: "download.progress"
            ))
        }

        // API Keys
        let apiKeys = parentItem(t("menu.api_keys"), icon: "api-keys")
        apiKeys.identifier = NSUserInterfaceItemIdentifier("api-keys")
        let apiSub = NSMenu()
        apiSub.autoenablesItems = false
        apiSub.addItem(item(t("menu.gemini_api_key"), #selector(onGeminiApiKey)))
        apiSub.addItem(item(t("menu.openai_api_key"), #selector(onOpenAIApiKey)))
        apiKeys.submenu = apiSub
        menu.addItem(apiKeys)

        // Languages
        let languages = parentItem(t("menu.languages"), icon: "languages")
        languages.submenu = buildLanguagesSubmenu()
        menu.addItem(languages)
        menu.addItem(.separator())

        // AI Editor Backend. The parent checkmark is factual: on only after
        // the selected editor has prepared successfully, mixed while pending.
        let aiBackend = parentItem(t("menu.ai_backend"), icon: "ai-editor")
        aiBackend.identifier = NSUserInterfaceItemIdentifier("ai-editor.backend")
        aiBackend.state = aiEditorParentState()
        aiBackend.submenu = buildAIEditorSubmenu()
        menu.addItem(aiBackend)
        menu.addItem(item(t("menu.delete_local_model"), #selector(onDeleteLocalModel)))

        // Initial Prompt
        let prompt = parentItem(t("menu.initial_prompt"), icon: "initial-prompt")
        prompt.submenu = buildInitialPromptSubmenu()
        menu.addItem(prompt)

        // Last Phrases
        let historyTitle = renderedState.history.totalCount > 0
            ? "\(t("menu.last_phrases")) (\(renderedState.history.totalCount))"
            : t("menu.last_phrases")
        let lastPhrases = parentItem(historyTitle, icon: "last-phrases")
        lastPhrases.identifier = NSUserInterfaceItemIdentifier("history")
        let lpSubmenu = NSMenu()
        lpSubmenu.autoenablesItems = false
        lpSubmenu.delegate = self
        lastPhrases.submenu = lpSubmenu
        lastPhrasesMenu = lpSubmenu
        menu.addItem(lastPhrases)
        rebuildLastPhrasesMenu()

        menu.addItem(item(t("menu.transcribe_file"), #selector(onTranscribeFile), icon: "transcribe-file"))
        menu.addItem(.separator())
        menu.addItem(item(t("menu.setup"), #selector(onSetup)))
        let updateTitle = renderedState.updateAvailableVersion.map {
            "\(t("menu.check_updates")) — v\($0)"
        } ?? t("menu.check_updates")
        menu.addItem(item(updateTitle, #selector(onCheckUpdates), icon: "check-updates", id: "updates"))
        menu.addItem(item(t("menu.about"), #selector(onAbout)))
        let launchAtLoginItem = item(
            t("menu.launch_at_login"),
            #selector(onToggleAutostart),
            icon: "launch-at-login",
            checked: renderedState.autostartEnabled,
            id: "autostart"
        )
        autostartItem = launchAtLoginItem
        menu.addItem(launchAtLoginItem)

        // Advanced
        let advanced = parentItem(t("menu.advanced"), icon: "advanced")
        let advSub = NSMenu()
        advSub.autoenablesItems = false
        advSub.addItem(item(t("menu.edit_config"), #selector(onEditConfig)))
        advSub.addItem(item(t("menu.open_log"), #selector(onOpenLog)))
        advSub.addItem(item(t("menu.reload_config"), #selector(onReloadConfig)))
        if renderedState.dataMode == .dev {
            advSub.addItem(.separator())
            let dataMode = sectionHeader(t("menu.development_data"))
            dataMode.toolTip = paths.dataDirectory.path
            advSub.addItem(dataMode)
        }
        advanced.submenu = advSub
        menu.addItem(advanced)

        menu.addItem(item(t("menu.restart"), #selector(onRestart), icon: "restart"))
        menu.addItem(.separator())

        // Quit (rumps adds this automatically in the Python app).
        let quit = NSMenuItem(title: t("menu.quit"), action: #selector(onQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func buildModelSubmenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let runtime = renderedState.runtime
        let backend = runtime.desiredSTTBackend
        let cloudModel = backend == "local" ? "" : runtime.desiredSTTModel
        let localModel = backend == "local" ? runtime.desiredSTTModel : config.sttModelName

        let status = sectionHeader(runtimeLabel(runtime))
        status.identifier = NSUserInterfaceItemIdentifier("runtime-status")
        sub.addItem(status)
        for action in runtime.recoveryActions {
            let recoveryItem = item(
                runtimeRecoveryTitle(action),
                #selector(onRuntimeRecovery)
            )
            recoveryItem.representedObject = action.rawValue
            sub.addItem(recoveryItem)
        }
        sub.addItem(.separator())
        sub.addItem(sectionHeader(t("menu.stt_cloud_section")))
        for group in ModelCatalog.cloudSTTModels {
            for m in group.models {
                let desired = backend == group.backend && cloudModel == m.id
                let active = runtime.activeSTTBackend == group.backend && runtime.activeSTTModel == m.id
                let value = "\(group.backend)|\(m.id)"
                let mi = choiceItem(
                    m.label,
                    value: value,
                    #selector(onSelectCloudModel),
                    state: active ? .on : (desired ? .mixed : .off)
                )
                sub.addItem(mi)
            }
        }
        sub.addItem(.separator())
        sub.addItem(sectionHeader(t("menu.stt_local_section")))
        for m in ModelCatalog.whisperModels {
            let desired = backend == "local" && localModel == m.id
            let registryID = ModelRegistry.whisperModelByLegacyID(m.id)?.id
            let active = runtime.activeSTTBackend == "local"
                && (runtime.activeSTTModel == m.id || runtime.activeSTTModel == registryID)
            let availability = renderedState.localModels[m.id] ?? .downloadRequired
            let availabilityLabel: String
            switch availability {
            case .available:
                availabilityLabel = t("menu.model_available")
            case .downloadRequired:
                availabilityLabel = t("menu.model_download_required")
            case .downloading:
                availabilityLabel = t("menu.model_downloading")
            case .validating:
                availabilityLabel = t("menu.model_validating")
            case .paused:
                availabilityLabel = t("menu.model_paused")
            case .active:
                availabilityLabel = t("menu.model_active")
            case .updateAvailable:
                availabilityLabel = t("menu.model_update_available")
            case .failed:
                availabilityLabel = t("menu.model_failed")
            }
            let displayedAvailability = active ? t("menu.model_active") : availabilityLabel
            let title = "\(m.label) · \(ModelCatalog.size(for: m.id)) · \(displayedAvailability)"
            let mi = choiceItem(
                title,
                value: m.id,
                #selector(onSelectLocalModel),
                state: active ? .on : (desired ? .mixed : .off)
            )
            mi.toolTip = active ? t("menu.model_active") : nil
            sub.addItem(mi)
        }
        return sub
    }

    private func buildAIEditorSubmenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let activeBackend = factualActiveEditorBackend
        let desiredBackend = config.aiEditorEnabled ? config.aiEditorBackend : nil

        let local = choiceItem(
            aiEditorLocalTitle(active: activeBackend == "local", desired: desiredBackend == "local"),
            value: "local",
            #selector(onAIBackendLocal),
            state: aiEditorChoiceState(
                backend: "local",
                activeBackend: activeBackend,
                desiredBackend: desiredBackend
            )
        )
        sub.addItem(local)

        let gemini = choiceItem(
            aiEditorGeminiTitle(active: activeBackend == "gemini", desired: desiredBackend == "gemini"),
            value: "gemini",
            #selector(onAIBackendGemini),
            state: aiEditorChoiceState(
                backend: "gemini",
                activeBackend: activeBackend,
                desiredBackend: desiredBackend
            )
        )
        sub.addItem(gemini)

        if desiredBackend == "local", activeBackend != "local" {
            let modelID = normalizedAIEditorModelID
            let availability = renderedState.localModels[modelID] ?? .downloadRequired
            if availability == .downloadRequired || availability == .failed {
                sub.addItem(.separator())
                sub.addItem(item(
                    t("menu.download_ai_model"),
                    #selector(onDownloadAIModel),
                    icon: "download-model"
                ))
            }
        }
        if shouldShowDownloadProgressItem(renderedState.download),
           renderedState.download.modelID == normalizedAIEditorModelID {
            sub.addItem(.separator())
            sub.addItem(item(
                downloadProgressMenuTitle(renderedState.download),
                #selector(onShowDownloadProgress),
                icon: "download-model"
            ))
        }
        return sub
    }

    private var factualActiveEditorBackend: String? {
        guard let backend = renderedState.runtime.activeEditorBackend,
              backend != "disabled" else { return nil }
        return backend
    }

    private var normalizedAIEditorModelID: String {
        ModelRegistry.aiEditorModel(id: config.aiEditorModel)?.id
            ?? ModelRegistry.defaultAiEditorModelID
    }

    private func aiEditorParentState() -> NSControl.StateValue {
        if factualActiveEditorBackend != nil { return .on }
        return config.aiEditorEnabled ? .mixed : .off
    }

    private func aiEditorChoiceState(
        backend: String,
        activeBackend: String?,
        desiredBackend: String?
    ) -> NSControl.StateValue {
        if activeBackend == backend { return .on }
        return desiredBackend == backend ? .mixed : .off
    }

    private func aiEditorLocalTitle(active: Bool, desired: Bool) -> String {
        let modelID = normalizedAIEditorModelID
        let availability = renderedState.localModels[modelID] ?? .downloadRequired
        let status: String
        if active {
            status = t("menu.model_active")
        } else if renderedState.download.modelID == modelID {
            switch renderedState.download.phase {
            case .downloading: status = t("menu.model_downloading")
            case .validating: status = t("menu.model_validating")
            case .failed: status = t("menu.model_failed")
            default: status = localModelAvailabilityTitle(availability)
            }
        } else if desired, availability == .available {
            status = renderedState.runtime.phase == .degraded
                ? t("menu.runtime_unavailable")
                : t("menu.runtime_preparing")
        } else {
            status = localModelAvailabilityTitle(availability)
        }
        return "\(t("menu.ai_local")) · \(status)"
    }

    private func aiEditorGeminiTitle(active: Bool, desired: Bool) -> String {
        let status: String?
        if active {
            status = t("menu.model_active")
        } else if desired {
            status = renderedState.runtime.phase == .degraded
                ? t("menu.runtime_unavailable")
                : t("menu.runtime_preparing")
        } else {
            status = nil
        }
        return status.map { "\(t("menu.ai_gemini")) · \($0)" } ?? t("menu.ai_gemini")
    }

    private func localModelAvailabilityTitle(_ availability: MenuLocalModelState) -> String {
        switch availability {
        case .available: t("menu.model_available")
        case .downloadRequired: t("menu.model_download_required")
        case .downloading: t("menu.model_downloading")
        case .validating: t("menu.model_validating")
        case .paused: t("menu.model_paused")
        case .active: t("menu.model_active")
        case .updateAvailable: t("menu.model_update_available")
        case .failed: t("menu.model_failed")
        }
    }

    private func shouldShowDownloadProgressItem(_ download: MenuDownloadSnapshot) -> Bool {
        switch download.phase {
        case .downloading, .validating, .failed:
            return download.modelID != nil
        case .idle, .paused, .completed, .cancelled:
            return false
        }
    }

    private func downloadProgressMenuTitle(_ download: MenuDownloadSnapshot) -> String {
        let modelName = download.modelID.flatMap { ModelRegistry.model(id: $0)?.displayName }
            ?? download.modelID
            ?? ""
        switch download.phase {
        case .validating:
            return "\(modelName) · \(t("menu.model_validating"))"
        case .failed:
            return "\(modelName) · \(t("menu.model_failed"))"
        default:
            let base = t("download.progress_title", ["label": modelName])
            guard let fraction = download.fractionCompleted else { return base }
            return "\(base) \(Int((fraction * 100).rounded()))%"
        }
    }

    private func buildLanguagesSubmenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let autoDetect = config.raw["language_auto_detect"]?.boolValue ?? false
        let primary = config.primaryLanguage
        let additional = Set(config.additionalLanguages)

        let header = sectionHeader(t("menu.primary_language"))
        sub.addItem(header)
        for lang in ["ru", "en", "uk", "de", "es", "fr"] {
            let name = LanguageCode.displayNames[lang] ?? lang
            let mi = choiceItem(
                name,
                value: lang,
                #selector(onSelectPrimaryLanguage),
                state: !autoDetect && lang == primary ? .on : .off
            )
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        sub.addItem(sectionHeader(t("menu.additional_languages")))
        for lang in ["ru", "en", "uk", "de", "es", "fr"] where lang != primary {
            let name = LanguageCode.displayNames[lang] ?? lang
            let mi = choiceItem(
                name,
                value: lang,
                #selector(onToggleAdditionalLanguage),
                state: additional.contains(lang) ? .on : .off
            )
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        sub.addItem(choiceItem(
            t("menu.auto_detect_language"),
            value: "auto",
            #selector(onToggleAutoDetect),
            state: autoDetect ? .on : .off
        ))
        return sub
    }

    private func buildInitialPromptSubmenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(item(t("menu.edit_terms"), #selector(onEditTerms)))
        sub.addItem(item(t("menu.revert_terms"), #selector(onRevertTerms)))
        sub.addItem(.separator())

        let mode = NSMenuItem(title: t("menu.auto_update_mode"), action: nil, keyEquivalent: "")
        let modeSub = NSMenu()
        modeSub.autoenablesItems = false
        let current = config.raw["prompt_update_mode"]?.stringValue ?? "suggest"
        modeSub.addItem(item(t("menu.mode_suggest"), #selector(onModeSuggest), checked: current == "suggest"))
        modeSub.addItem(item(t("menu.mode_auto"), #selector(onModeAuto), checked: current == "auto"))
        modeSub.addItem(item(t("menu.mode_disabled"), #selector(onModeDisabled), checked: current == "disabled"))
        mode.submenu = modeSub
        sub.addItem(mode)

        sub.addItem(.separator())
        let suggestionsTitle = renderedState.pendingSuggestionCount > 0
            ? "\(t("menu.review_suggestions")) (\(renderedState.pendingSuggestionCount))"
            : t("menu.review_suggestions")
        sub.addItem(item(suggestionsTitle, #selector(onReviewSuggestions)))
        sub.addItem(item(t("menu.edit_replacements"), #selector(onEditReplacements)))
        sub.addItem(item(t("menu.statistics"), #selector(onStatistics)))
        return sub
    }

    private func sectionHeader(_ text: String) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    // MARK: - Permission item titles

    private func micTitle(_ snapshot: MenuPermissionSnapshot) -> String {
        t(snapshot.microphone == .granted ? "menu.mic_granted" : "menu.mic_required")
    }

    private func accessibilityTitle(_ snapshot: MenuPermissionSnapshot) -> String {
        t(snapshot.accessibilityGranted ? "menu.access_granted" : "menu.access_required")
    }

    @objc private func onMicrophone() { permissionService.openMicrophoneSettings() }
    @objc private func onAccessibility() { permissionService.openAccessibilitySettings() }
    @objc private func onSelectCloudModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let parts = id.split(separator: "|")
        if parts.count == 2 {
            var newConfig = config
            newConfig.raw["stt_backend"] = .string(String(parts[0]))
            newConfig.raw["stt_cloud_model"] = .string(String(parts[1]))
            onConfigChanged?(newConfig)
            log("Cloud model set to \(parts[1]) (\(parts[0]))")
        }
    }
    @objc private func onSelectLocalModel(_ sender: NSMenuItem) {
        guard let modelID = sender.representedObject as? String else { return }
        var newConfig = config
        newConfig.raw["stt_backend"] = .string("local")
        newConfig.raw["model_name"] = .string(modelID)
        // Preserve the desired selection while its model downloads. The
        // runtime coordinator keeps the previous active engine until this
        // candidate becomes valid.
        onConfigChanged?(newConfig)
        // Map legacy MLX hub IDs (from ModelCatalog) to ModelRegistry entries.
        if let info = ModelRegistry.whisperModelByLegacyID(modelID),
           !ModelManager.isDownloaded(info, paths: paths) {
            startDownload(model: info)
        } else {
            log("Local model set to \(modelID)")
        }
    }

    @objc private func onRuntimeRecovery(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = MenuRuntimeRecoveryAction(rawValue: raw) else { return }
        switch action {
        case .downloadModel:
            recoverLocalModel(redownload: false)
        case .redownloadModel:
            recoverLocalModel(redownload: true)
        case .openAPIKeys:
            if state.runtime.desiredSTTBackend == "openai" {
                onOpenAIApiKey()
            } else {
                onGeminiApiKey()
            }
        case .selectCloudBackend:
            guard let group = ModelCatalog.cloudSTTModels.first,
                  let model = group.models.first else { return }
            var newConfig = config
            newConfig.raw["stt_backend"] = .string(group.backend)
            newConfig.raw["stt_cloud_model"] = .string(model.id)
            onConfigChanged?(newConfig)
        case .keepPreviousRuntime, .retry:
            onRuntimeRecoveryRequested?(action)
        }
    }

    private func recoverLocalModel(redownload: Bool) {
        let desiredWhisper = ModelRegistry.whisperModelByLegacyID(state.runtime.desiredSTTModel)
        let desiredEditor = config.aiEditorEnabled && config.aiEditorBackend == "local"
            ? (ModelRegistry.aiEditorModel(id: config.aiEditorModel)
                ?? ModelRegistry.aiEditorModel(id: ModelRegistry.defaultAiEditorModelID))
            : nil
        let model = [desiredWhisper, desiredEditor]
            .compactMap { $0 }
            .first { !ModelManager.isDownloaded($0, paths: paths) }
            ?? desiredWhisper
            ?? desiredEditor
        guard let model else { return }
        if redownload {
            ModelManager.quarantineInvalidArtifact(
                at: paths.modelFile(for: model),
                model: model,
                paths: paths
            )
        }
        startDownload(model: model)
    }

    private func runtimeRecoveryTitle(_ action: MenuRuntimeRecoveryAction) -> String {
        switch action {
        case .downloadModel: t("menu.recovery_download_model")
        case .redownloadModel: t("menu.recovery_redownload_model")
        case .openAPIKeys: t("menu.recovery_open_api_keys")
        case .selectCloudBackend: t("menu.recovery_select_cloud")
        case .keepPreviousRuntime: t("menu.recovery_keep_previous")
        case .retry: t("btn.retry")
        }
    }

    @objc private func onGeminiApiKey() {
        let alert = NSAlert()
        alert.messageText = t("dialog.gemini_key_title")
        let existingKey = KeychainHelper.getPassword(
            service: KeychainHelper.defaultService,
            account: KeychainHelper.geminiAccount
        )
        alert.informativeText = t(existingKey == nil
            ? "dialog.gemini_key_body"
            : "dialog.gemini_key_body_existing")

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = existingKey == nil ? nil : "••••••••••••"
        input.setAccessibilityLabel(t("dialog.gemini_key_title"))
        alert.accessoryView = input

        alert.addButton(withTitle: t("btn.save_test"))
        alert.addButton(withTitle: t("btn.cancel"))
        alert.addButton(withTitle: t("btn.clear"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                guard Self.isCredentialFormatValid(key, provider: "gemini") else {
                    presentCredentialValidationError(provider: "gemini")
                    return
                }
                do {
                    try KeychainHelper.setPassword(
                        service: KeychainHelper.defaultService,
                        account: KeychainHelper.geminiAccount,
                        password: key
                    )
                    log("Gemini API Key saved to Keychain.")
                    onCredentialsChanged?("gemini")
                } catch {
                    log("Failed to save Gemini API Key: \(error)")
                    presentCredentialPersistenceError()
                }
            }
        } else if response == .alertThirdButtonReturn {
            do {
                try KeychainHelper.deletePassword(
                    service: KeychainHelper.defaultService,
                    account: KeychainHelper.geminiAccount
                )
                log("Gemini API Key cleared.")
                onCredentialsChanged?("gemini")
            } catch {
                log("Failed to clear Gemini API Key: \(error)")
                presentCredentialPersistenceError()
            }
        }
    }
    @objc private func onOpenAIApiKey() {
        let alert = NSAlert()
        alert.messageText = t("dialog.openai_key_title")
        let existingKey = KeychainHelper.getPassword(
            service: KeychainHelper.defaultService,
            account: KeychainHelper.openAIAccount
        )
        alert.informativeText = t(existingKey == nil
            ? "dialog.openai_key_body"
            : "dialog.openai_key_body_existing")

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = existingKey == nil ? nil : "••••••••••••"
        input.setAccessibilityLabel(t("dialog.openai_key_title"))
        alert.accessoryView = input

        alert.addButton(withTitle: t("btn.save_test"))
        alert.addButton(withTitle: t("btn.cancel"))
        alert.addButton(withTitle: t("btn.clear"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                guard Self.isCredentialFormatValid(key, provider: "openai") else {
                    presentCredentialValidationError(provider: "openai")
                    return
                }
                do {
                    try KeychainHelper.setPassword(
                        service: KeychainHelper.defaultService,
                        account: KeychainHelper.openAIAccount,
                        password: key
                    )
                    log("OpenAI API Key saved to Keychain.")
                    onCredentialsChanged?("openai")
                } catch {
                    log("Failed to save OpenAI API Key: \(error)")
                    presentCredentialPersistenceError()
                }
            }
        } else if response == .alertThirdButtonReturn {
            do {
                try KeychainHelper.deletePassword(
                    service: KeychainHelper.defaultService,
                    account: KeychainHelper.openAIAccount
                )
                log("OpenAI API Key cleared.")
                onCredentialsChanged?("openai")
            } catch {
                log("Failed to clear OpenAI API Key: \(error)")
                presentCredentialPersistenceError()
            }
        }
    }

    static func isCredentialFormatValid(_ key: String, provider: String) -> Bool {
        guard key.count >= 20, key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }
        return provider == "openai" ? key.hasPrefix("sk-") : true
    }

    private func presentCredentialValidationError(provider: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("dialog.api_key_invalid_title")
        alert.informativeText = t("dialog.api_key_invalid_\(provider)")
        alert.addButton(withTitle: t("btn.ok"))
        alert.runModal()
    }

    private func presentCredentialPersistenceError() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = t("dialog.api_key_save_failed_title")
        alert.informativeText = t("dialog.api_key_save_failed_body")
        alert.addButton(withTitle: t("btn.ok"))
        alert.runModal()
    }
    @objc private func onSelectPrimaryLanguage(_ sender: NSMenuItem) {
        guard let lang = sender.representedObject as? String else { return }
        let newConfig = LanguageSettings.selectPrimary(lang, in: config)
        emitLanguageSettings(newConfig)
        log("Primary language set to \(lang)")
    }
    @objc private func onToggleAdditionalLanguage(_ sender: NSMenuItem) {
        guard let lang = sender.representedObject as? String else { return }
        let newConfig = LanguageSettings.toggleAdditional(lang, in: config)
        emitLanguageSettings(newConfig)
        log("Additional language toggled: \(lang)")
    }
    @objc private func onToggleAutoDetect() {
        let current = config.raw["language_auto_detect"]?.boolValue ?? false
        let newConfig = LanguageSettings.setAutoDetect(!current, in: config)
        emitLanguageSettings(newConfig)
        log("Auto detect toggled to \(!current)")
    }

    private func emitLanguageSettings(_ settings: Config) {
        if let onLanguageSettingsChanged {
            onLanguageSettingsChanged(settings)
        } else {
            onConfigChanged?(settings)
        }
    }
    public func checkAndDownloadLocalModelIfNeeded() {
        guard config.sttBackend == "local" else { return }
        let modelID = config.raw["model_name"]?.stringValue ?? ModelCatalog.defaultWhisperModel
        if let info = ModelRegistry.whisperModelByLegacyID(modelID),
           !ModelManager.isDownloaded(info, paths: paths) {
            log("Local model missing on startup, prompting download: \(info.id)")
            startDownload(model: info)
        }
    }

    @objc private func onAIBackendLocal() {
        var newConfig = config
        let shouldDisable = config.aiEditorEnabled && config.aiEditorBackend == "local"
        newConfig.raw["ai_editor_enabled"] = .bool(!shouldDisable)
        if !shouldDisable {
            newConfig.raw["ai_editor_backend"] = .string("local")
        }
        onConfigChanged?(newConfig)
        if shouldDisable {
            log("AI Editor disabled from local backend selection")
            return
        }
        log("AI Editor backend selected: local")
        guard let model = ModelRegistry.aiEditorModel(id: normalizedAIEditorModelID),
              !ModelManager.isDownloaded(model, paths: paths) else { return }
        startDownload(model: model)
    }

    @objc private func onAIBackendGemini() {
        var newConfig = config
        let shouldDisable = config.aiEditorEnabled && config.aiEditorBackend == "gemini"
        newConfig.raw["ai_editor_enabled"] = .bool(!shouldDisable)
        if !shouldDisable {
            newConfig.raw["ai_editor_backend"] = .string("gemini")
        }
        onConfigChanged?(newConfig)
        log(shouldDisable
            ? "AI Editor disabled from Gemini backend selection"
            : "AI Editor backend selected: gemini")
    }

    @objc private func onDownloadAIModel() {
        guard let model = ModelRegistry.aiEditorModels.first else { return }
        if ModelManager.isDownloaded(model, paths: paths) {
            log("AI model already downloaded")
            return
        }
        startDownload(model: model)
    }

    @objc private func onShowDownloadProgress() {
        guard downloadPanel.bringToFront() else {
            log("Download progress window is not available")
            return
        }
        log("Download progress window restored")
    }

    @objc private func onDeleteLocalModel() {
        let installed = (ModelRegistry.whisperModels + ModelRegistry.aiEditorModels).filter {
            FileManager.default.fileExists(atPath: paths.modelFile(for: $0).path)
        }
        guard !installed.isEmpty else {
            let alert = NSAlert()
            alert.messageText = t("dialog.no_local_models_title")
            alert.informativeText = t("dialog.no_local_models_body")
            alert.addButton(withTitle: t("btn.ok"))
            alert.runModal()
            return
        }

        let activeSTT = state.runtime.activeSTTModel
        let activeEditor = state.runtime.activeEditorModel
        let inactive = installed.filter { model in
            switch model.kind {
            case .whisper:
                let activeRegistryID = activeSTT.flatMap {
                    ModelRegistry.whisperModelByLegacyID($0)?.id
                }
                return model.id != activeSTT && model.id != activeRegistryID
            case .aiEditor:
                return model.id != activeEditor
                    && !(model.id == ModelRegistry.defaultAiEditorModelID
                        && activeEditor == "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
            }
        }
        guard !inactive.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = t("dialog.active_model_delete_title")
            alert.informativeText = t("dialog.active_model_delete_body")
            alert.addButton(withTitle: t("btn.ok"))
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("dialog.delete_local_model_title")
        alert.informativeText = t("dialog.delete_local_model_body")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        for model in inactive {
            let size = ModelManager.diskUsageForModel(model, paths: paths)
            picker.addItem(withTitle: "\(model.displayName) · \(ModelManager.formattedSize(size))")
            picker.lastItem?.representedObject = model.id
        }
        picker.setAccessibilityLabel(t("dialog.delete_local_model_picker"))
        alert.accessoryView = picker
        alert.addButton(withTitle: t("btn.delete"))
        alert.addButton(withTitle: t("btn.cancel"))
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        guard let modelID = picker.selectedItem?.representedObject as? String,
              let model = ModelRegistry.model(id: modelID) else { return }

        do {
            try ModelManager.delete(model, paths: paths, activeModelID: nil)
            onLocalModelsChanged?()
            log("Local model deleted: \(model.id)")
        } catch {
            log("Failed to delete models: \(error)")
        }
    }
    @objc private func onEditTerms() {
        guard let dictionaryCoordinator else { return }
        if termsPanel == nil { termsPanel = TermsPanel(coordinator: dictionaryCoordinator, i18n: i18n) }
        termsPanel?.presentPanel()
    }
    @objc private func onSetup() {
        onSetupRequested?()
    }

    @objc private func onAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(
            options: [NSApplication.AboutPanelOptionKey.applicationName: "Click-n-speak"]
        )
    }

    @objc private func onRevertTerms() {
        if let dictionaryCoordinator {
            do { try dictionaryCoordinator.revert() }
            catch { log("Dictionary revert failed: \(error.localizedDescription)") }
        } else {
            onRevertTermsRequested?()
        }
    }
    @objc private func onModeSuggest() {
        if let dictionaryCoordinator {
            do { try dictionaryCoordinator.setPromptUpdateMode("suggest") }
            catch { log("Prompt mode update failed: \(error.localizedDescription)") }
            return
        }
        var newConfig = config
        newConfig.raw["prompt_update_mode"] = .string("suggest")
        onConfigChanged?(newConfig)
        log("Prompt update mode set to suggest")
    }
    @objc private func onModeAuto() {
        if let dictionaryCoordinator {
            do { try dictionaryCoordinator.setPromptUpdateMode("auto") }
            catch { log("Prompt mode update failed: \(error.localizedDescription)") }
            return
        }
        var newConfig = config
        newConfig.raw["prompt_update_mode"] = .string("auto")
        onConfigChanged?(newConfig)
        log("Prompt update mode set to auto")
    }
    @objc private func onModeDisabled() {
        if let dictionaryCoordinator {
            do { try dictionaryCoordinator.setPromptUpdateMode("disabled") }
            catch { log("Prompt mode update failed: \(error.localizedDescription)") }
            return
        }
        var newConfig = config
        newConfig.raw["prompt_update_mode"] = .string("disabled")
        onConfigChanged?(newConfig)
        log("Prompt update mode set to disabled")
    }
    @objc private func onReviewSuggestions() {
        guard let dictionaryCoordinator else { return }
        if !dictionaryCoordinator.pendingSuggestions().isEmpty {
            presentSuggestionsPanel(using: dictionaryCoordinator)
            return
        }
        Task { @MainActor [weak self, weak dictionaryCoordinator] in
            guard let self, let dictionaryCoordinator else { return }
            do { try await dictionaryCoordinator.runPromptAnalysis(onDemand: true) }
            catch { self.log("On-demand prompt analysis failed: \(error.localizedDescription)") }
            self.presentSuggestionsPanel(using: dictionaryCoordinator)
        }
    }
    @objc private func onEditReplacements() {
        guard let dictionaryCoordinator else { return }
        if replacementsPanel == nil {
            replacementsPanel = ReplacementsPanel(coordinator: dictionaryCoordinator, i18n: i18n)
        }
        replacementsPanel?.presentPanel()
    }
    @objc private func onStatistics() {
        if let dictionaryCoordinator {
            statisticsTask?.cancel()
            statisticsTask = Task { [weak self, weak dictionaryCoordinator] in
                guard let self, let dictionaryCoordinator else { return }
                do {
                    let metrics = try await dictionaryCoordinator.computeMetricsForPresentation()
                    try Task.checkCancellation()
                    self.presentStatistics(metrics)
                } catch is CancellationError {
                    return
                } catch {
                    self.log("Metrics computation failed: \(error.localizedDescription)")
                    self.presentStatistics(JSONObject())
                }
                self.statisticsTask = nil
            }
            return
        } else {
            presentStatistics(Metrics.computeMetrics(
                datasetUrl: paths.datasetFile,
                correctionsUrl: paths.correctionsFile,
                config: config.raw
            ))
        }
    }

    private func presentStatistics(_ metrics: JSONObject) {
        func percentage(_ value: Double?) -> String {
            value.map { String(format: "%.1f%%", $0 * 100) } ?? t("stats.not_available")
        }
        func trend(_ value: JSONValue?, positiveGood: Bool) -> String {
            guard let delta = value?.objectValue?["delta"]?.doubleValue else {
                return t("stats.not_available")
            }
            let arrow = delta > 0 ? "↑" : delta < 0 ? "↓" : "→"
            let qualityKey: String
            if abs(delta) < 0.000_000_001 {
                qualityKey = "stats.trend_neutral"
            } else if (delta > 0) == positiveGood {
                qualityKey = "stats.trend_good"
            } else {
                qualityKey = "stats.trend_bad"
            }
            return String(format: "%@ %+.1fpp (%@)", arrow, delta * 100, t(qualityKey))
        }

        let editScore = percentage(metrics["edit_score_avg"]?.doubleValue)
        let activeTerms = metrics["active_terms_count"]?.intValue ?? 0
        let manualTerms = metrics["manual_terms_count"]?.intValue ?? 0
        let automaticTerms = metrics["auto_terms_count"]?.intValue ?? 0
        let correctionTerms = metrics["correction_terms_count"]?.intValue ?? 0
        let dictHitRate = percentage(metrics["hit_rate"]?.doubleValue)
        let windowSize = metrics["window_size"]?.intValue ?? 100
        let accepted = metrics["accepted_total"]?.intValue ?? 0
        let rejected = metrics["rejected_total"]?.intValue ?? 0
        let promptUsed = metrics["prompt_tokens_used"]?.intValue ?? 0
        let promptMaximum = metrics["prompt_tokens_max"]?.intValue ?? 0
        let inactive = metrics["inactive_terms_count"]?.intValue ?? 0

        var lines = [
            t("stats.performance_header", ["n": String(windowSize)]),
            "",
            "\(t("stats.edit_label")): \(editScore)   \(trend(metrics["edit_score_trend"], positiveGood: false))",
            "\(t("stats.hit_rate_label")): \(dictHitRate)   \(trend(metrics["hit_rate_trend"], positiveGood: true))",
            "\(t("stats.active_terms_label")): \(activeTerms) (\(manualTerms) \(t("terms.source_manual")) / \(automaticTerms) \(t("terms.source_auto")) / \(correctionTerms) \(t("terms.source_correction")))",
            "\(t("stats.acceptance_rate_label")): \(percentage(metrics["acceptance_rate"]?.doubleValue)) (\(t("stats.accepted_rejected", ["accepted": String(accepted), "rejected": String(rejected)])))",
            "\(t("stats.prompt_util_label")): \(percentage(metrics["prompt_utilisation"]?.doubleValue)) (\(promptUsed)/\(promptMaximum))",
            "",
            t("stats.inactive_clean", ["n": String(inactive)]),
        ]
        let failedPairs = metrics["failed_pairs"]?.arrayValue?.prefix(5) ?? []
        if !failedPairs.isEmpty {
            lines.append("")
            lines.append(t("stats.failed_pairs_header"))
            for value in failedPairs {
                guard let pair = value.objectValue else { continue }
                let source = pair["from"]?.stringValue ?? ""
                let target = pair["to"]?.stringValue ?? ""
                let count = pair["count"]?.intValue ?? 0
                lines.append("  \"\(source)\" → \"\(target)\" (\(count)×)")
            }
        }

        let alert = NSAlert()
        alert.messageText = t("stats.title")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: t("btn.ok"))
        alert.addButton(withTitle: t("stats.btn_history"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(paths.metricsHistoryFile)
        }
    }

    @objc private func onTranscribeFile() {
        if fileDropPanel == nil {
            let runtimeUnavailableMessage = t("dialog.file_runtime_unavailable")
            fileDropPanel = FileDropPanel(i18n: i18n, onTranscribe: { [weak self] url, refine, progress in
                guard let self = self, let action = self.onTranscribeFileAction else {
                    return .failed(.init(
                        kind: .unavailable,
                        message: runtimeUnavailableMessage
                    ))
                }
                return await action(url, refine, progress)
            }, onCancel: { [weak self] in self?.onCancelFileTranscription?() })
        }
        fileDropPanel?.presentPanel()
    }
    @objc private func onCheckUpdates() {
        Task {
            do {
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                if let update = try await UpdateChecker.check(currentVersion: currentVersion) {
                    let alert = NSAlert()
                    alert.messageText = t("notify.update_available_title")
                    alert.informativeText = t(
                        "dialog.update_available_body",
                        ["version": update.version]
                    )
                    alert.addButton(withTitle: t("btn.download"))
                    alert.addButton(withTitle: t("btn.cancel"))

                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        startAppUpdate(update: update)
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = t("dialog.up_to_date_title")
                    alert.informativeText = t(
                        "dialog.up_to_date_body",
                        ["version": currentVersion]
                    )
                    alert.addButton(withTitle: t("btn.ok"))
                    alert.runModal()
                }
            } catch {
                log("Update check failed: \(error)")
                let alert = NSAlert()
                alert.messageText = t("dialog.update_check_failed_title")
                alert.informativeText = t("dialog.update_check_failed_body")
                alert.addButton(withTitle: t("btn.ok"))
                alert.runModal()
            }
        }
    }

    private func startAppUpdate(update: AppUpdate) {
        appUpdateTask?.cancel()
        let updateGeneration = downloadPanel.show(
            modelName: t("download.app_update", ["version": update.version])
        ) { [weak self] in self?.appUpdateTask?.cancel() } onRetry: { [weak self] in
            self?.startAppUpdate(update: update)
        }

        appUpdateTask = Task {
            do {
                let _ = try await AppUpdater.shared.downloadAndStage(update: update) { _ in }
                try Task.checkCancellation()

                self.downloadPanel.showCompleted(generation: updateGeneration)

                let alert = NSAlert()
                alert.messageText = t("dialog.update_ready_title")
                alert.informativeText = t("dialog.update_ready_body")
                alert.addButton(withTitle: t("btn.restart_now"))
                alert.addButton(withTitle: t("btn.later"))
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    try? await AppUpdater.shared.swapAndRelaunch()
                }
            } catch is CancellationError {
                await AppUpdater.shared.cancelAndCleanUp()
                self.downloadPanel.showCancelled(generation: updateGeneration)
            } catch {
                self.log("App update failed: \(error)")
                self.downloadPanel.showError(
                    self.t("dialog.update_failed_body"),
                    generation: updateGeneration
                )
            }
            self.appUpdateTask = nil
        }
    }

    @objc private func onToggleAutostart() {
        do {
            let enabled = Autostart.status() != .enabled
            let result = try Autostart.setEnabled(enabled)
            let systemEnabled = result == .enabled
            var newConfig = config
            newConfig.raw["autostart"] = .bool(systemEnabled)
            var updated = state
            updated.autostartEnabled = systemEnabled
            updated.config = newConfig
            apply(updated)
            autostartItem?.state = systemEnabled ? .on : .off
            onConfigChanged?(newConfig)
            if result == .requiresApproval {
                presentAutostartAlert(bodyKey: "notify.autostart_requires_approval")
            } else if result == .notFound {
                presentAutostartAlert(bodyKey: "notify.autostart_not_found")
            }
            log("Autostart system status: \(result.rawValue)")
        } catch {
            log("Failed to toggle autostart: \(error)")
            presentAutostartAlert(bodyKey: "notify.autostart_error")
        }
    }

    private func presentAutostartAlert(bodyKey: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("notify.autostart_title")
        alert.informativeText = t(bodyKey)
        alert.addButton(withTitle: t("btn.ok"))
        alert.runModal()
    }
    @objc private func onEditConfig() { openEnsuringFile(paths.configFile, defaultContents: config.serialized()) }
    @objc private func onOpenLog() { openEnsuringFile(paths.logFile, defaultContents: "") }
    @objc private func onReloadConfig() {
        do {
            try reloadConfiguration()
        } catch {
            log("Configuration reload failed; the active configuration was retained.")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = t("config.recovery_title")
            alert.informativeText = t("config.reload_failed")
            alert.addButton(withTitle: t("btn.ok"))
            alert.runModal()
        }
    }

    func reloadConfiguration() throws {
        let newConfig = try Config.loadValidated(from: paths.configFile)
        try onConfigurationReloaded?(newConfig)
        log("Config reloaded from disk")
    }
    @objc private func onRestart() {
        let task = Process()
        task.executableURL = Bundle.main.executableURL
        try? task.run()
        NSApp.terminate(nil)
    }
    @objc private func onQuit() { NSApp.terminate(nil) }

    private func openEnsuringFile(_ url: URL, defaultContents: String) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                try defaultContents.write(to: url, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(url)
        } catch {
            log("Could not prepare requested application file: \(error.localizedDescription)")
        }
    }

    // MARK: - Download coordination

    private func startDownload(model: ModelInfo) {
        guard let downloader = modelDownloader else {
            log("ModelDownloader not configured — cannot download \(model.id)")
            return
        }
        guard downloader.state != .downloading, downloader.state != .validating else {
            log("A download is already in progress")
            return
        }

        let downloadGeneration = downloadPanel.show(
            modelName: model.displayName,
            onCancel: { [weak self] in self?.modelDownloader?.cancel() },
            onRetry: { [weak self] in self?.startDownload(model: model) }
        )
        onDownloadStateChanged?(
            MenuDownloadSnapshot(phase: .downloading, modelID: model.id, fractionCompleted: 0)
        )

        downloader.onProgress = { [weak self] bytes, total in
            guard let self else { return }
            self.downloadPanel.update(
                downloadedBytes: bytes,
                totalBytes: total,
                bytesPerSecond: downloader.bytesPerSecond,
                estimatedTimeRemaining: downloader.estimatedTimeRemaining,
                generation: downloadGeneration
            )
            let fraction = total.flatMap { value in
                value > 0 ? Double(bytes) / Double(value) : nil
            }
            self.onDownloadStateChanged?(
                MenuDownloadSnapshot(
                    phase: .downloading,
                    modelID: model.id,
                    fractionCompleted: fraction
                )
            )
        }
        downloader.onValidationStarted = { [weak self] in
            self?.onDownloadStateChanged?(
                MenuDownloadSnapshot(phase: .validating, modelID: model.id)
            )
        }
        downloader.onDone = { [weak self] in
            self?.log("Download complete: \(model.id)")
            self?.downloadPanel.showCompleted(generation: downloadGeneration)
            self?.onDownloadStateChanged?(
                MenuDownloadSnapshot(phase: .completed, modelID: model.id, fractionCompleted: 1)
            )
            self?.onLocalModelsChanged?()
            self?.onModelDownloadCompleted?(model.id)
        }
        downloader.onError = { [weak self] msg in
            self?.log("Download failed: \(msg)")
            self?.downloadPanel.showError(
                self?.t("download.failed_generic") ?? "",
                generation: downloadGeneration
            )
            self?.onDownloadStateChanged?(
                MenuDownloadSnapshot(phase: .failed, modelID: model.id)
            )
        }
        downloader.onCancelled = { [weak self] in
            self?.log("Download cancelled: \(model.id)")
            self?.downloadPanel.showCancelled(generation: downloadGeneration)
            self?.onDownloadStateChanged?(
                MenuDownloadSnapshot(
                    phase: downloader.canResume ? .paused : .cancelled,
                    modelID: model.id
                )
            )
        }

        downloader.start(model: model)
    }
}

extension MenuBarController: NSMenuDelegate {
    /// Refresh permission status titles each time the menu opens, matching the
    /// Python `_MainMenuDelegate` behaviour.
    public func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu {
            menuIsTracking = true
            let enabled = Autostart.isEnabled()
            autostartItem?.state = enabled ? .on : .off
            if state.autostartEnabled != enabled {
                var updated = state
                updated.autostartEnabled = enabled
                apply(updated)
            }
            onPermissionRefreshRequested?()
        } else if menu === self.lastPhrasesMenu {
            refreshHistory(reset: false)
        }
    }

    public func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuIsTracking = false
        guard let pendingState else { return }
        self.pendingState = nil
        apply(pendingState)
    }

    private func updatePermissionsMenu(using snapshot: MenuPermissionSnapshot) {
        let allGranted = snapshot.microphone == .granted && snapshot.accessibilityGranted
        permissionsParentItem?.image = resources.menuItemIcon(
            name: allGranted ? "permissions-ok" : "permissions-warn"
        )
        microphoneItem?.title = micTitle(snapshot)
        microphoneItem?.image = resources.menuItemIcon(
            name: snapshot.microphone == .granted ? "microphone-ok" : "microphone-warn"
        )
        accessibilityItem?.title = accessibilityTitle(snapshot)
        accessibilityItem?.image = resources.menuItemIcon(
            name: snapshot.accessibilityGranted ? "accessibility-ok" : "accessibility-warn"
        )
    }

    private func rebuildLastPhrasesMenu() {
        guard let menu = lastPhrasesMenu else { return }
        menu.removeAllItems()

        let header = NSMenuItem(title: t("menu.history_hint"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let history = renderedState.history
        let phrases = history.rows.reversed()

        if phrases.isEmpty {
            let title = history.isLoading ? t("menu.history_loading") : t("menu.history_empty")
            let empty = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for (index, item) in phrases.enumerated() {
            let text = item.text
            var title = text
            if title.count > 46 {
                title = String(title.prefix(43)) + "..."
            }
            let mi = NSMenuItem(title: title, action: #selector(onCopyPhrase(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = index
            mi.toolTip = text
            mi.representedObject = text
            mi.image = resources.menuItemIcon(name: "copy-phrase")
            menu.addItem(mi)
        }

        if history.totalCount > history.rows.count {
            menu.addItem(.separator())
            menu.addItem(historyMoreItem())
        }
    }

    private func historyMoreItem() -> NSMenuItem {
        let width: CGFloat = 280
        let height: CGFloat = 28
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let button = NSButton(frame: NSRect(x: 14, y: 3, width: width - 28, height: 22))
        button.setButtonType(.momentaryLight)
        button.title = t("menu.show_more")
        button.target = self
        button.action = #selector(onLoadMorePhrases)
        button.identifier = NSUserInterfaceItemIdentifier("history.show-more")
        button.setAccessibilityLabel(t("menu.show_more"))
        view.addSubview(button)
        let item = NSMenuItem()
        item.identifier = NSUserInterfaceItemIdentifier("history.show-more-item")
        item.view = view
        return item
    }

    @objc private func onCopyPhrase(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        copyPhraseToPasteboard(text)
    }

    public func copyPhraseToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        showCopiedFeedback()
        lastPhrasesMenu?.cancelTracking()
        log("Copied phrase to pasteboard")
    }

    @objc private func onLoadMorePhrases() {
        var updated = state
        updated.history.visibleLimit += 5
        apply(updated)
        refreshHistory(reset: false)
        log("Loading more phrase-history rows: \(updated.history.visibleLimit)")
    }

    private func showCopiedFeedback() {
        guard statusItem != nil else { return }
        copiedPanel?.close()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 130, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
        panel.hasShadow = true
        let label = NSTextField(labelWithString: t("popup.copied"))
        label.alignment = .center
        label.frame = panel.contentView?.bounds.insetBy(dx: 8, dy: 8) ?? .zero
        panel.contentView?.addSubview(label)
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x - 65, y: mouse.y + 12))
        panel.orderFrontRegardless()
        copiedPanel = panel
        Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(750))
            panel?.close()
            if self?.copiedPanel === panel { self?.copiedPanel = nil }
        }
    }
}
