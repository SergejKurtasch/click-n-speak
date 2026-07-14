import Testing
import Foundation
import AppKit
@testable import CNSUI
@testable import CNSCore

@MainActor
@Suite("Menu structure")
struct MenuStructureTests {
    /// Locate the repo root (which holds `locales/`) by walking up from this
    /// source file, so the test uses the real locale files.
    private func repoResources() -> AppResources {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("locales").path) {
                return AppResources(
                    localesDirectory: dir.appendingPathComponent("locales"),
                    iconsDirectory: dir.appendingPathComponent("assets/icons")
                )
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("Could not locate repo locales/ from \(#filePath)")
    }

    private func makeController(configJSON: String = "{}") throws -> MenuBarController {
        let resources = repoResources()
        let i18n = I18n.load("en", localesDirectory: resources.localesDirectory)
        let value = try JSONValue.parse(configJSON)
        let config = Config.migrated(value.objectValue ?? JSONObject())
        return MenuBarController(config: config, i18n: i18n, resources: resources,
                                 installStatusItem: false)
    }

    private func topTitles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    @Test("Top-level order and titles match the Python menu (with Input Monitoring dropped)")
    func topLevelOrder() throws {
        let c = try makeController()
        let titles = topTitles(c.menu)
        #expect(titles == [
            "Permissions",
            "---",
            "Model",
            "API Keys",
            "Languages",
            "---",
            "AI Editor (Punctuation & Cleanup)",
            "AI Editor Backend ▶",
            "Download AI Editor Model",
            "Initial Prompt",
            "Last Phrases",
            "Transcribe Audio File...",
            "---",
            "Check for Updates",
            "Launch at Login",
            "Advanced",
            "Restart",
            "---",
            "Quit Click-n-speak",
        ])
    }

    @Test("Permissions submenu has two items (Input Monitoring removed)")
    func permissionsSubmenu() throws {
        let c = try makeController()
        let permissions = try #require(c.menu.items.first { $0.title == "Permissions" })
        let sub = try #require(permissions.submenu)
        #expect(sub.items.count == 2)
        #expect(sub.items[0].title.contains("Microphone"))
        #expect(sub.items[1].title.contains("Accessibility"))
    }

    @Test("Model submenu has Cloud and Local sections with all models")
    func modelSubmenu() throws {
        let c = try makeController()
        let model = try #require(c.menu.items.first { $0.title == "Model" })
        let sub = try #require(model.submenu)
        let titles = sub.items.map(\.title)
        #expect(titles.contains("Cloud"))
        #expect(titles.contains("Local models"))
        #expect(titles.contains("Gemini 2.5 Flash-Lite"))
        #expect(titles.contains { $0.hasPrefix("Turbo · ") })
        // 1 header + 6 cloud + separator + 1 header + 5 local = 14 rows.
        #expect(sub.items.count == 14)
    }

    @Test("Local Turbo model is checked by default")
    func defaultModelChecked() throws {
        let c = try makeController()
        let sub = try #require(c.menu.items.first { $0.title == "Model" }?.submenu)
        let turbo = try #require(sub.items.first { $0.title.hasPrefix("Turbo · ") })
        #expect(turbo.state == .on)
    }

    @Test("AI Editor checkmark reflects config")
    func aiEditorChecked() throws {
        let on = try makeController(configJSON: #"{"ai_editor_enabled": true}"#)
        let item = try #require(on.menu.items.first { $0.title.hasPrefix("AI Editor (") })
        #expect(item.state == .on)

        let off = try makeController(configJSON: #"{"ai_editor_enabled": false}"#)
        let item2 = try #require(off.menu.items.first { $0.title.hasPrefix("AI Editor (") })
        #expect(item2.state == .off)
    }

    @Test("Initial Prompt submenu structure")
    func initialPromptSubmenu() throws {
        let c = try makeController()
        let prompt = try #require(c.menu.items.first { $0.title == "Initial Prompt" })
        let sub = try #require(prompt.submenu)
        let titles = sub.items.map { $0.isSeparatorItem ? "---" : $0.title }
        #expect(titles == [
            "Edit Terms…", "Revert Terms…", "---",
            "Auto-update Mode", "---",
            "Review Suggestions", "Edit Replacements…", "Statistics…",
        ])
    }

    @Test("Menu renders in Russian too")
    func russianMenu() throws {
        let resources = repoResources()
        let i18n = I18n.load("ru", localesDirectory: resources.localesDirectory)
        let config = Config.migrated(JSONObject())
        let c = MenuBarController(config: config, i18n: i18n, resources: resources, installStatusItem: false)
        // "Permissions" localized to Russian — just assert it's not the English key.
        let first = c.menu.items.first
        #expect(first?.title != "menu.permissions")
        #expect(first?.title.isEmpty == false)
    }
}
