import Testing
import Foundation
import AppKit
@testable import CNSUI
@testable import CNSCore
@testable import CNSDictionary

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
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cns-menu-tests-\(UUID().uuidString)")
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        return MenuBarController(config: config, i18n: i18n, resources: resources, paths: paths,
                                 installStatusItem: false)
    }

    private func topTitles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    @Test("Top-level order uses one consolidated AI Editor backend control")
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
            "AI Editor Backend ▶",
            "Delete Local Models...",
            "Initial Prompt",
            "Last Phrases",
            "Transcribe Audio File...",
            "---",
            "Setup...",
            "Check for Updates",
            "About Click-n-speak",
            "Launch at Login",
            "Advanced",
            "Restart",
            "---",
            "Quit Click-n-speak",
        ])
    }

    @Test("Permissions submenu has two items because Carbon needs no Input Monitoring")
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
        // Runtime status + separator + 1 header + 6 cloud + separator + 1 header + 5 local.
        #expect(sub.items.count == 16)
    }

    @Test("Desired Turbo is pending until a factual runtime becomes active")
    func defaultModelChecked() throws {
        let c = try makeController()
        let sub = try #require(c.menu.items.first { $0.title == "Model" }?.submenu)
        let turbo = try #require(sub.items.first { $0.title.hasPrefix("Turbo · ") })
        #expect(turbo.state == .mixed)
    }

    @Test("AI Editor parent and backend choices show disabled, pending, and active states")
    func aiEditorStates() throws {
        let controller = try makeController(configJSON: #"{"ai_editor_enabled": false}"#)
        var parent = try #require(controller.menu.items.first {
            $0.identifier?.rawValue == "ai-editor.backend"
        })
        #expect(parent.state == .off)
        #expect(parent.submenu?.items.allSatisfy { $0.state == .off } == true)

        var pending = controller.state
        pending.config.raw["ai_editor_enabled"] = .bool(true)
        pending.config.raw["ai_editor_backend"] = .string("local")
        pending.runtime.desiredEditorBackend = "local"
        controller.apply(pending)
        parent = try #require(controller.menu.items.first {
            $0.identifier?.rawValue == "ai-editor.backend"
        })
        let pendingLocal = try #require(parent.submenu?.items.first {
            ($0.representedObject as? String) == "local"
        })
        #expect(parent.state == .mixed)
        #expect(pendingLocal.state == .mixed)

        var active = pending
        active.runtime.phase = .ready
        active.runtime.activeEditorBackend = "local"
        active.runtime.activeEditorModel = ModelRegistry.defaultAiEditorModelID
        controller.apply(active)
        parent = try #require(controller.menu.items.first {
            $0.identifier?.rawValue == "ai-editor.backend"
        })
        let activeLocal = try #require(parent.submenu?.items.first {
            ($0.representedObject as? String) == "local"
        })
        #expect(parent.state == .on)
        #expect(activeLocal.state == .on)
    }

    @Test("Backend choices enable, switch, and disable the AI Editor")
    func aiEditorBackendActions() throws {
        let controller = try makeController(configJSON: #"{"ai_editor_enabled": false}"#)
        controller.onConfigChanged = { controller.updateConfig($0) }

        var parent = try #require(controller.menu.items.first {
            $0.identifier?.rawValue == "ai-editor.backend"
        })
        let local = try #require(parent.submenu?.items.first {
            ($0.representedObject as? String) == "local"
        })
        _ = controller.perform(local.action)
        #expect(controller.config.aiEditorEnabled)
        #expect(controller.config.aiEditorBackend == "local")

        parent = try #require(controller.menu.items.first {
            $0.identifier?.rawValue == "ai-editor.backend"
        })
        let gemini = try #require(parent.submenu?.items.first {
            ($0.representedObject as? String) == "gemini"
        })
        _ = controller.perform(gemini.action)
        #expect(controller.config.aiEditorEnabled)
        #expect(controller.config.aiEditorBackend == "gemini")

        parent = try #require(controller.menu.items.first {
            $0.identifier?.rawValue == "ai-editor.backend"
        })
        let selectedGemini = try #require(parent.submenu?.items.first {
            ($0.representedObject as? String) == "gemini"
        })
        _ = controller.perform(selectedGemini.action)
        #expect(!controller.config.aiEditorEnabled)
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

    @Test("Pending suggestion panel is limited to suggest mode")
    func pendingSuggestionPanelModeGuard() throws {
        let suggest = Config.migrated(try JSONValue.parse(#"{"prompt_update_mode":"suggest"}"#).objectValue ?? JSONObject())
        let automatic = Config.migrated(try JSONValue.parse(#"{"prompt_update_mode":"auto"}"#).objectValue ?? JSONObject())
        let disabled = Config.migrated(try JSONValue.parse(#"{"prompt_update_mode":"disabled"}"#).objectValue ?? JSONObject())

        #expect(MenuBarController.shouldPresentPendingSuggestions(config: suggest, pendingCount: 4))
        #expect(!MenuBarController.shouldPresentPendingSuggestions(config: suggest, pendingCount: 0))
        #expect(!MenuBarController.shouldPresentPendingSuggestions(config: automatic, pendingCount: 4))
        #expect(!MenuBarController.shouldPresentPendingSuggestions(config: disabled, pendingCount: 4))
    }

    @Test("Menu renders in Russian too")
    func russianMenu() throws {
        let resources = repoResources()
        let i18n = I18n.load("ru", localesDirectory: resources.localesDirectory)
        let config = Config.migrated(JSONObject())
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cns-menu-ru-\(UUID().uuidString)")
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        let c = MenuBarController(
            config: config,
            i18n: i18n,
            resources: resources,
            paths: paths,
            installStatusItem: false
        )
        // "Permissions" localized to Russian — just assert it's not the English key.
        let first = c.menu.items.first
        #expect(first?.title != "menu.permissions")
        #expect(first?.title.isEmpty == false)
    }
}
