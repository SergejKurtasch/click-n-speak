import AppKit
import CNSCore

/// Owns the `NSStatusItem` and builds the full menu tree, mirroring
/// `menu_bar.py` `setup_menu` (lines 1099-1331) 1:1 in structure and order.
///
/// Phase 1 scope: every action is a no-op that logs "not implemented: <action>";
/// checkmarks reflect the loaded config; permission status items call the
/// read-only checks. Real handlers arrive in later phases.
///
/// Deviation from the Python menu (documented in SWIFT_MIGRATION_PLAN.md §4.3):
/// the Permissions submenu has two items (Microphone, Accessibility), not three
/// — Input Monitoring is gone because the hotkey uses Carbon RegisterEventHotKey.
@MainActor
public final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem?
    private let config: Config
    private let i18n: I18n
    private let resources: AppResources
    private let log: (String) -> Void
    private let paths: Paths

    /// The built menu tree, exposed for structural tests.
    public let menu: NSMenu

    private var microphoneItem: NSMenuItem?
    private var accessibilityItem: NSMenuItem?

    // MARK: - Model Download

    /// Model downloader — injected by the app so the menu can trigger downloads.
    public var modelDownloader: ModelDownloader?

    /// Download progress panel.
    private lazy var downloadPanel = ModelDownloadPanel(log: log)

    /// - Parameter installStatusItem: when false, no `NSStatusItem` is created,
    ///   so the menu tree can be built and inspected headlessly in tests.
    public init(
        config: Config,
        i18n: I18n,
        resources: AppResources,
        paths: Paths = Paths.resolveDefault(),
        log: @escaping (String) -> Void = { _ in },
        installStatusItem: Bool = true
    ) {
        self.config = config
        self.i18n = i18n
        self.resources = resources
        self.paths = paths
        self.log = log
        self.menu = NSMenu()
        self.statusItem = installStatusItem
            ? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            : nil
        super.init()

        populate(menu: menu)
        menu.delegate = self

        if let statusItem {
            if let icon = resources.menuBarIcon(state: "idle") {
                statusItem.button?.image = icon
            } else {
                statusItem.button?.title = "CnS"
            }
            statusItem.menu = menu
        }
    }

    // MARK: - Menu construction

    private func t(_ key: String) -> String { i18n.t(key) }

    private func item(_ title: String, _ selector: Selector?, checked: Bool = false) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        mi.target = self
        mi.state = checked ? .on : .off
        return mi
    }

    private func populate(menu: NSMenu) {
        menu.autoenablesItems = false

        // Permissions
        let permissions = NSMenuItem(title: t("menu.permissions"), action: nil, keyEquivalent: "")
        let permSub = NSMenu()
        permSub.autoenablesItems = false
        let mic = item(micTitle(), #selector(onMicrophone))
        let acc = item(accessibilityTitle(), #selector(onAccessibility))
        microphoneItem = mic
        accessibilityItem = acc
        permSub.addItem(mic)
        permSub.addItem(acc)
        permissions.submenu = permSub
        menu.addItem(permissions)
        menu.addItem(.separator())

        // Model
        let model = NSMenuItem(title: t("menu.model"), action: nil, keyEquivalent: "")
        model.submenu = buildModelSubmenu()
        menu.addItem(model)

        // API Keys
        let apiKeys = NSMenuItem(title: t("menu.api_keys"), action: nil, keyEquivalent: "")
        let apiSub = NSMenu()
        apiSub.autoenablesItems = false
        apiSub.addItem(item(t("menu.gemini_api_key"), #selector(onGeminiApiKey)))
        apiSub.addItem(item(t("menu.openai_api_key"), #selector(onOpenAIApiKey)))
        apiKeys.submenu = apiSub
        menu.addItem(apiKeys)

        // Languages
        let languages = NSMenuItem(title: t("menu.languages"), action: nil, keyEquivalent: "")
        languages.submenu = buildLanguagesSubmenu()
        menu.addItem(languages)
        menu.addItem(.separator())

        // AI Editor toggle
        menu.addItem(item(t("menu.ai_editor"), #selector(onToggleAIEditor), checked: config.aiEditorEnabled))

        // AI Editor Backend
        let aiBackend = NSMenuItem(title: t("menu.ai_backend"), action: nil, keyEquivalent: "")
        let aiSub = NSMenu()
        aiSub.autoenablesItems = false
        let backend = config.raw["ai_editor_backend"]?.stringValue ?? "local"
        aiSub.addItem(item(t("menu.ai_local"), #selector(onAIBackendLocal), checked: backend == "local"))
        aiSub.addItem(item(t("menu.ai_gemini"), #selector(onAIBackendGemini), checked: backend == "gemini"))
        aiBackend.submenu = aiSub
        menu.addItem(aiBackend)

        menu.addItem(item(t("menu.download_ai_model"), #selector(onDownloadAIModel)))
        menu.addItem(item("Delete Local Model…", #selector(onDeleteLocalModel)))

        // Initial Prompt
        let prompt = NSMenuItem(title: t("menu.initial_prompt"), action: nil, keyEquivalent: "")
        prompt.submenu = buildInitialPromptSubmenu()
        menu.addItem(prompt)

        // Last Phrases
        let lastPhrases = NSMenuItem(title: t("menu.last_phrases"), action: nil, keyEquivalent: "")
        lastPhrases.submenu = NSMenu()
        menu.addItem(lastPhrases)

        menu.addItem(item(t("menu.transcribe_file"), #selector(onTranscribeFile)))
        menu.addItem(.separator())

        menu.addItem(item(t("menu.check_updates"), #selector(onCheckUpdates)))
        menu.addItem(item(t("menu.launch_at_login"), #selector(onToggleAutostart), checked: config.autostart))

        // Advanced
        let advanced = NSMenuItem(title: t("menu.advanced"), action: nil, keyEquivalent: "")
        let advSub = NSMenu()
        advSub.autoenablesItems = false
        advSub.addItem(item(t("menu.edit_config"), #selector(onEditConfig)))
        advSub.addItem(item(t("menu.open_log"), #selector(onOpenLog)))
        advSub.addItem(item(t("menu.reload_config"), #selector(onReloadConfig)))
        advanced.submenu = advSub
        menu.addItem(advanced)

        menu.addItem(item(t("menu.restart"), #selector(onRestart)))
        menu.addItem(.separator())

        // Quit (rumps adds this automatically in the Python app).
        let quit = NSMenuItem(title: quitTitle(), action: #selector(onQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func buildModelSubmenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let backend = config.sttBackend
        let cloudModel = config.raw["stt_cloud_model"]?.stringValue ?? ModelCatalog.defaultCloudSTTModel
        let localModel = config.raw["model_name"]?.stringValue ?? ModelCatalog.defaultWhisperModel

        sub.addItem(sectionHeader(t("menu.stt_cloud_section")))
        for group in ModelCatalog.cloudSTTModels {
            for m in group.models {
                let active = backend == group.backend && cloudModel == m.id
                let mi = item(m.label, #selector(onSelectCloudModel), checked: active)
                mi.representedObject = "\(group.backend)|\(m.id)"
                sub.addItem(mi)
            }
        }
        sub.addItem(.separator())
        sub.addItem(sectionHeader(t("menu.stt_local_section")))
        for m in ModelCatalog.whisperModels {
            let active = backend == "local" && localModel == m.id
            let mi = item("\(m.label) · \(ModelCatalog.size(for: m.id))", #selector(onSelectLocalModel), checked: active)
            mi.representedObject = m.id
            sub.addItem(mi)
        }
        return sub
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
            let mi = item(name, #selector(onSelectPrimaryLanguage), checked: !autoDetect && lang == primary)
            mi.representedObject = lang
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        sub.addItem(sectionHeader(t("menu.additional_languages")))
        for lang in ["ru", "en", "uk", "de", "es", "fr"] where lang != primary {
            let name = LanguageCode.displayNames[lang] ?? lang
            let mi = item(name, #selector(onToggleAdditionalLanguage), checked: additional.contains(lang))
            mi.representedObject = lang
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        sub.addItem(item("Auto — detect language", #selector(onToggleAutoDetect), checked: autoDetect))
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
        sub.addItem(item(t("menu.review_suggestions"), #selector(onReviewSuggestions)))
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

    private func micTitle() -> String {
        t(PermissionStatus.microphoneGranted ? "menu.mic_granted" : "menu.mic_required")
    }

    private func accessibilityTitle() -> String {
        t(PermissionStatus.accessibilityGranted ? "menu.access_granted" : "menu.access_required")
    }

    private func quitTitle() -> String {
        // rumps labels this "Quit <AppName>"; keep it simple and localized-ish.
        "Quit Click-n-speak"
    }

    // MARK: - Action stubs (Phase 1: log only)

    private func stub(_ name: String) { log("not implemented: \(name)") }

    @objc private func onMicrophone() { stub("permissions.microphone") }
    @objc private func onAccessibility() { stub("permissions.accessibility") }
    @objc private func onSelectCloudModel(_ sender: NSMenuItem) { stub("model.cloud:\(sender.representedObject ?? "")") }

    @objc private func onSelectLocalModel(_ sender: NSMenuItem) {
        guard let modelID = sender.representedObject as? String else { return }
        // Map legacy MLX hub IDs (from ModelCatalog) to ModelRegistry entries.
        if let info = ModelRegistry.whisperModelByLegacyID(modelID),
           !ModelManager.isDownloaded(info, paths: paths) {
            startDownload(model: info)
        } else {
            stub("model.local:\(modelID)")
        }
    }

    @objc private func onGeminiApiKey() { stub("api_keys.gemini") }
    @objc private func onOpenAIApiKey() { stub("api_keys.openai") }
    @objc private func onSelectPrimaryLanguage(_ sender: NSMenuItem) { stub("language.primary:\(sender.representedObject ?? "")") }
    @objc private func onToggleAdditionalLanguage(_ sender: NSMenuItem) { stub("language.additional:\(sender.representedObject ?? "")") }
    @objc private func onToggleAutoDetect() { stub("language.auto_detect") }
    @objc private func onToggleAIEditor() { stub("ai_editor.toggle") }
    @objc private func onAIBackendLocal() { stub("ai_editor.backend.local") }
    @objc private func onAIBackendGemini() { stub("ai_editor.backend.gemini") }

    @objc private func onDownloadAIModel() {
        guard let model = ModelRegistry.aiEditorModels.first else { return }
        if ModelManager.isDownloaded(model, paths: paths) {
            log("AI model already downloaded")
            return
        }
        startDownload(model: model)
    }

    @objc private func onDeleteLocalModel() {
        // Show confirmation alert listing all downloaded models.
        let usage = ModelManager.diskUsage(paths: paths)
        guard usage > 0 else {
            let alert = NSAlert()
            alert.messageText = "No Local Models"
            alert.informativeText = "There are no downloaded models to delete."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Local Models?"
        alert.informativeText = "This will free \(ModelManager.formattedSize(usage)) of disk space. You can re-download models at any time."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        do {
            for model in ModelRegistry.whisperModels + ModelRegistry.aiEditorModels {
                try ModelManager.delete(model, paths: paths)
            }
            log("All local models deleted")
        } catch {
            log("Failed to delete models: \(error)")
        }
    }
    @objc private func onEditTerms() { stub("prompt.edit_terms") }
    @objc private func onRevertTerms() { stub("prompt.revert_terms") }
    @objc private func onModeSuggest() { stub("prompt.mode.suggest") }
    @objc private func onModeAuto() { stub("prompt.mode.auto") }
    @objc private func onModeDisabled() { stub("prompt.mode.disabled") }
    @objc private func onReviewSuggestions() { stub("prompt.review_suggestions") }
    @objc private func onEditReplacements() { stub("prompt.edit_replacements") }
    @objc private func onStatistics() { stub("prompt.statistics") }
    @objc private func onTranscribeFile() { stub("transcribe_file") }
    @objc private func onCheckUpdates() { stub("check_updates") }
    @objc private func onToggleAutostart() { stub("launch_at_login") }
    @objc private func onEditConfig() { stub("advanced.edit_config") }
    @objc private func onOpenLog() { stub("advanced.open_log") }
    @objc private func onReloadConfig() { stub("advanced.reload_config") }
    @objc private func onRestart() { stub("restart") }
    @objc private func onQuit() { NSApp.terminate(nil) }

    // MARK: - Download coordination

    private func startDownload(model: ModelInfo) {
        guard let downloader = modelDownloader else {
            log("ModelDownloader not configured — cannot download \(model.id)")
            return
        }
        guard downloader.state != .downloading else {
            log("A download is already in progress")
            return
        }

        downloadPanel.show(modelName: model.displayName) { [weak self] in
            self?.modelDownloader?.cancel()
        }

        downloader.onProgress = { [weak self] bytes, total in
            guard let self else { return }
            self.downloadPanel.update(
                downloadedBytes: bytes,
                totalBytes: total,
                bytesPerSecond: downloader.bytesPerSecond,
                estimatedTimeRemaining: downloader.estimatedTimeRemaining
            )
        }
        downloader.onDone = { [weak self] in
            self?.log("Download complete: \(model.id)")
            self?.downloadPanel.showCompleted()
        }
        downloader.onError = { [weak self] msg in
            self?.log("Download failed: \(msg)")
            self?.downloadPanel.showError(msg)
        }
        downloader.onCancelled = { [weak self] in
            self?.log("Download cancelled: \(model.id)")
            self?.downloadPanel.showCancelled()
        }

        downloader.start(model: model)
    }
}

extension MenuBarController: NSMenuDelegate {
    /// Refresh permission status titles each time the menu opens, matching the
    /// Python `_MainMenuDelegate` behaviour.
    public func menuWillOpen(_ menu: NSMenu) {
        microphoneItem?.title = micTitle()
        accessibilityItem?.title = accessibilityTitle()
    }
}
