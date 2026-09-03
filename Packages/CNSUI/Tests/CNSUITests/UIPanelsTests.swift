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
