import AppKit
import XCTest
@testable import CNSCore
@testable import CNSDictionary
@testable import CNSTranscription
@testable import CNSUI

@MainActor
final class UIPanelsTests: XCTestCase {
    private let config = Config()

    private func resources() -> AppResources {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("locales").path
            ) {
                return AppResources(
                    localesDirectory: directory.appendingPathComponent("locales"),
                    iconsDirectory: directory.appendingPathComponent("assets/icons")
                )
            }
            directory = directory.deletingLastPathComponent()
        }
        fatalError("Could not locate repository resources")
    }

    private func i18n() -> I18n {
        I18n.load("en", localesDirectory: resources().localesDirectory)
    }

    private func coordinator(config: Config? = nil) -> DictionaryCoordinator {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cns-ui-panels-\(UUID().uuidString)")
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        return DictionaryCoordinator(
            config: config ?? self.config,
            paths: paths,
            phraseHistory: PhraseHistory(fileURL: paths.phraseHistoryFile)
        )
    }

    private func replacementValue(from: String, to: String, timestampKey: String) -> JSONValue {
        var object = JSONObject()
        object["from"] = .string(from)
        object["to"] = .string(to)
        object[timestampKey] = .string(ISOTimestamp.now())
        return .object(object)
    }

    private func replacementFixture() throws -> DictionaryCoordinator {
        var object = JSONObject()
        object["schema_version"] = .int(10)
        object["replacement_policy_initialized"] = .bool(true)
        object["manual_replacements"] = .array([
            replacementValue(from: "manual", to: "Manual", timestampKey: "added_at"),
        ])
        object["approved_auto_replacements"] = .array([
            replacementValue(from: "approved", to: "Approved", timestampKey: "approved_at"),
        ])
        object["rejected_replacements"] = .array([
            replacementValue(from: "blocked", to: "Blocked", timestampKey: "rejected_at"),
        ])
        let source = Config.migrated(object)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cns-ui-replacements-\(UUID().uuidString)")
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        var index = CorrectionIndex.defaultIndex()
        index.processedRows = 10
        let now = ISOTimestamp.now()
        index.replacementPairs["latin"] = [
            ReplacementPair(from: "single", to: "Single", count: 1, lastSeen: now, lastSeenRow: 10),
            ReplacementPair(from: "twice", to: "Twice", count: 2, lastSeen: now, lastSeenRow: 10),
            ReplacementPair(from: "thrice", to: "Thrice", count: 3, lastSeen: now, lastSeenRow: 10),
        ]
        try CorrectionAnalyzer.writeIndex(index, to: paths.correctionsFile)
        return DictionaryCoordinator(
            config: source,
            paths: paths,
            phraseHistory: PhraseHistory(fileURL: paths.phraseHistoryFile)
        )
    }

    func testSuggestionsPanelInstantiation() {
        let i18n = i18n()
        let panel = SuggestionsPanel(coordinator: coordinator(), i18n: i18n)
        XCTAssertEqual(panel.title, i18n.t("suggestions.window_title"))
    }

    func testTermsPanelInstantiation() {
        let i18n = i18n()
        let panel = TermsPanel(coordinator: coordinator(), i18n: i18n)
        XCTAssertEqual(panel.title, i18n.t("terms.window_title"))
    }

    func testReplacementsPanelInstantiation() {
        let i18n = i18n()
        let panel = ReplacementsPanel(coordinator: coordinator(), i18n: i18n)
        XCTAssertEqual(panel.title, i18n.t("replacements.window_title"))
    }

    func testReplacementsPanelClassifiesPolicySectionsAndStartsRejectedCollapsed() throws {
        let panel = ReplacementsPanel(coordinator: try replacementFixture(), i18n: i18n())

        XCTAssertEqual(panel.activeReplacementCountForTesting, 2)
        XCTAssertEqual(panel.candidateReplacementCountForTesting, 2)
        XCTAssertEqual(panel.rejectedReplacementCountForTesting, 1)
        XCTAssertFalse(panel.isRejectedSectionExpandedForTesting)
    }

    func testReplacementsPanelApprovesRejectsAndRestoresRows() throws {
        let coordinator = try replacementFixture()
        let panel = ReplacementsPanel(coordinator: coordinator, i18n: i18n())

        panel.approveReplacementForTesting(from: "twice", to: "Twice")
        XCTAssertTrue(coordinator.replacementSections().active.contains { $0.from == "twice" })

        panel.rejectReplacementForTesting(from: "thrice", to: "Thrice")
        XCTAssertTrue(coordinator.replacementSections().rejected.contains { $0.from == "thrice" })

        panel.restoreReplacementForTesting(from: "blocked", to: "Blocked")
        XCTAssertTrue(coordinator.replacementSections().active.contains { $0.from == "blocked" })
    }

    func testLanguagePickerInstantiation() {
        let i18n = i18n()
        let panel = LanguagePicker(config: config, i18n: i18n) { _ in }
        XCTAssertEqual(panel.title, i18n.t("menu.languages"))
    }

    func testFileDropPanelInstantiation() {
        let i18n = i18n()
        let panel = FileDropPanel(i18n: i18n) { _, _, _ in
            FileTranscriptionResult(text: "fixture result", status: .success)
        }
        XCTAssertEqual(panel.title, i18n.t("dialog.file_drop_title"))
    }

    func testReusablePanelsRefreshFromLatestCoordinatorSnapshot() throws {
        let i18n = i18n()

        let termsCoordinator = coordinator()
        let terms = TermsPanel(coordinator: termsCoordinator, i18n: i18n)
        XCTAssertEqual(terms.termCountForTesting, 0)
        XCTAssertTrue(termsCoordinator.addManualTerm("SwiftUI", language: "en"))
        terms.refreshForPresentation()
        XCTAssertEqual(terms.termCountForTesting, 1)

        let replacementsCoordinator = coordinator()
        let replacements = ReplacementsPanel(coordinator: replacementsCoordinator, i18n: i18n)
        XCTAssertEqual(replacements.replacementCountForTesting, 0)
        try replacementsCoordinator.saveManualReplacements([("ap eye", "API")])
        replacements.refreshForPresentation()
        XCTAssertEqual(replacements.replacementCountForTesting, 1)

        var suggestionConfig = config
        var suggestion = JSONObject()
        suggestion["term"] = .string("SwiftData")
        suggestion["count"] = .int(5)
        suggestion["frequency_count"] = .int(5)
        suggestion["correction_count"] = .int(0)
        suggestion["source"] = .string("frequency")
        var pending = JSONObject()
        pending["en"] = .array([.object(suggestion)])
        suggestionConfig.raw["pending_suggestions"] = .object(pending)
        let suggestionsCoordinator = coordinator(config: suggestionConfig)
        let suggestions = SuggestionsPanel(coordinator: suggestionsCoordinator, i18n: i18n)
        XCTAssertEqual(suggestions.suggestionCountForTesting, 1)
        try suggestionsCoordinator.addAllPendingSuggestions()
        suggestions.refreshForPresentation()
        XCTAssertEqual(suggestions.suggestionCountForTesting, 0)
    }

    func testSuggestionSelectionSurvivesRoutineRefreshAndResetsOnPresentation() throws {
        var source = config
        var first = JSONObject()
        first["term"] = .string("Cognee")
        first["count"] = .int(17)
        first["frequency_count"] = .int(0)
        first["correction_count"] = .int(17)
        first["source"] = .string("correction")
        var second = JSONObject()
        second["term"] = .string("SwiftUI")
        second["count"] = .int(5)
        second["frequency_count"] = .int(0)
        second["correction_count"] = .int(5)
        second["source"] = .string("correction")
        var pending = JSONObject()
        pending["en"] = .array([.object(first), .object(second)])
        source.raw["pending_suggestions"] = .object(pending)

        let panel = SuggestionsPanel(coordinator: coordinator(config: source), i18n: i18n())
        XCTAssertEqual(panel.selectedSuggestionCountForTesting, 2)
        panel.setSuggestionSelectedForTesting(language: "en", term: "SwiftUI", selected: false)
        panel.refresh()
        XCTAssertEqual(panel.selectedSuggestionCountForTesting, 1)
        panel.refreshForPresentation()
        XCTAssertEqual(panel.selectedSuggestionCountForTesting, 2)
    }

    func testAddSelectedRejectsUncheckedSuggestionsAtomically() throws {
        var source = config
        var accepted = JSONObject()
        accepted["term"] = .string("Cognee")
        accepted["count"] = .int(17)
        accepted["frequency_count"] = .int(0)
        accepted["correction_count"] = .int(17)
        accepted["source"] = .string("correction")
        var rejected = JSONObject()
        rejected["term"] = .string("Проверь")
        rejected["count"] = .int(8)
        rejected["frequency_count"] = .int(0)
        rejected["correction_count"] = .int(8)
        rejected["source"] = .string("correction")
        var pending = JSONObject()
        pending["en"] = .array([.object(accepted)])
        pending["ru"] = .array([.object(rejected)])
        source.raw["pending_suggestions"] = .object(pending)
        let coordinator = coordinator(config: source)
        var publishCount = 0
        coordinator.onSnapshotChanged = { _, _ in publishCount += 1 }
        let panel = SuggestionsPanel(coordinator: coordinator, i18n: i18n())
        panel.setSuggestionSelectedForTesting(language: "ru", term: "Проверь", selected: false)

        panel.acceptSelectedForTesting()

        XCTAssertEqual(UserTerms.activeTerms(coordinator.snapshot, lang: "en"), ["Cognee"])
        XCTAssertTrue(UserTerms.activeTerms(coordinator.snapshot, lang: "ru").isEmpty)
        XCTAssertTrue(coordinator.pendingSuggestions().isEmpty)
        XCTAssertNotNil(coordinator.snapshot.raw["skipped_terms"]?.objectValue?["ru"]?.objectValue?["проверь"])
        XCTAssertEqual(publishCount, 1)
    }

    func testLanguagePickerValidatesSupportedLanguagesAndAutoDetect() {
        var source = config
        source.raw["primary_language"] = .string("it")
        source.raw["additional_languages"] = .array([.string("en"), .string("en"), .string("it")])
        source.raw["language_auto_detect"] = .bool(true)
        let model = LanguagePickerViewModel(config: source, i18n: i18n())

        XCTAssertEqual(model.primary, "en")
        XCTAssertTrue(model.additional.isEmpty)
        XCTAssertTrue(model.autoDetect)
        XCTAssertEqual(Set(model.availableLanguages.map(\.code)), Set(["ru", "en", "uk", "de", "es", "fr"]))
    }

    func testFileTypesMatchPythonPickerAndCredentialValidationIsProviderSpecific() {
        for ext in ["wav", "mp3", "flac", "ogg", "opus", "caf", "mp4"] {
            XCTAssertTrue(FileDropView.isSupported(URL(fileURLWithPath: "/tmp/fixture.\(ext)")))
        }
        XCTAssertFalse(FileDropView.isSupported(URL(fileURLWithPath: "/tmp/fixture.txt")))
        XCTAssertTrue(MenuBarController.isCredentialFormatValid("sk-12345678901234567890", provider: "openai"))
        XCTAssertFalse(MenuBarController.isCredentialFormatValid("AIza12345678901234567890", provider: "openai"))
        XCTAssertTrue(MenuBarController.isCredentialFormatValid("AIza12345678901234567890", provider: "gemini"))
        XCTAssertFalse(MenuBarController.isCredentialFormatValid("short key", provider: "gemini"))
    }

    func testDownloadPanelRejectsStaleCallbacksAndOffersLocalizedState() {
        let i18n = i18n()
        let panel = ModelDownloadPanel(i18n: i18n)
        let first = panel.show(modelName: "First", onCancel: {})
        XCTAssertEqual(panel.hidesOnDeactivateForTesting, false)
        XCTAssertTrue(panel.bringToFront())
        let second = panel.show(modelName: "Second", onCancel: {})
        panel.showError("old callback", generation: first)
        XCTAssertEqual(panel.statusForTesting, i18n.t("download.starting"))
        panel.showCancelled(generation: second)
        XCTAssertEqual(panel.statusForTesting, i18n.t("download.cancelled"))
        panel.close()
    }

    func testPanelsRenderSanitizedLightAndDarkSnapshots() throws {
        let panel = TermsPanel(coordinator: coordinator(), i18n: i18n())
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            panel.appearance = NSAppearance(named: appearanceName)
            guard let view = panel.contentView else {
                XCTFail("Missing content view")
                return
            }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                XCTFail("Could not create snapshot")
                return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1_000)
        }
        panel.close()
    }

    func testSetupPanelRendersVisibleActionsInLightAndDarkAppearances() throws {
        let panel = SetupAlertPanel(
            request: SetupAlertRequest(
                title: "Accessibility Access (Step 1 of 1)",
                body: "Accessibility lets Click-n-speak paste the transcribed text into the active application.",
                buttons: ["Open Settings", "Skip"]
            )
        )
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            panel.appearance = NSAppearance(named: appearanceName)
            let view = try XCTUnwrap(panel.contentView)
            view.layoutSubtreeIfNeeded()
            for button in panel.actionButtons {
                XCTAssertFalse(button.title.isEmpty)
                XCTAssertFalse(button.isHidden)
                XCTAssertGreaterThanOrEqual(button.frame.width, 112)
                XCTAssertGreaterThanOrEqual(button.frame.height, 34)
            }
            XCTAssertGreaterThan(panel.titleLabel.frame.width, 250)
            XCTAssertGreaterThan(panel.titleLabel.preferredMaxLayoutWidth, 300)
            XCTAssertGreaterThan(panel.bodyLabel.frame.height, 16)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 10_000)
            if let snapshotDirectory = ProcessInfo.processInfo.environment["CNS_SETUP_SNAPSHOT_DIR"] {
                let fileName = appearanceName == .darkAqua ? "setup-dark.png" : "setup-light.png"
                try png.write(to: URL(fileURLWithPath: snapshotDirectory).appendingPathComponent(fileName))
            }
        }
        panel.close()
    }

    func testSetupPanelOnScreenPreview() {
        guard ProcessInfo.processInfo.environment["CNS_SHOW_SETUP_PANEL"] == "1" else {
            return
        }
        let panel = SetupAlertPanel(
            request: SetupAlertRequest(
                title: "Accessibility Access (Step 1 of 1)",
                body: "Accessibility lets Click-n-speak paste the transcribed text into the active application.",
                buttons: ["Open Settings", "Skip"]
            )
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.1)))
        }
        panel.close()
    }
}
