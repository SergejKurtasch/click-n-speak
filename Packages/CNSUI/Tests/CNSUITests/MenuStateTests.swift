import AppKit
import CNSDictionary
import CNSCore
import Foundation
import Testing
@testable import CNSUI

private final class MenuHistoryStub: PhraseHistoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var page: PhraseHistoryPage

    init(page: PhraseHistoryPage = PhraseHistoryPage(totalCount: 0, entries: [])) {
        self.page = page
    }

    func append(_ text: String, at date: Date) -> Bool { false }
    func count() -> Int { page.totalCount }
    func lastPhrases(_ n: Int) -> [(timestamp: String, text: String)] {
        page.entries.suffix(n).map { ($0.timestamp, $0.text) }
    }
    func loadPage(limit: Int) async -> PhraseHistoryPage {
        lock.withLock {
            PhraseHistoryPage(
                totalCount: page.totalCount,
                entries: Array(page.entries.suffix(limit))
            )
        }
    }
}

@MainActor
@Suite("Immutable menu state")
struct MenuStateTests {
    private func resources() -> AppResources {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("locales").path) {
                return AppResources(
                    localesDirectory: directory.appendingPathComponent("locales"),
                    iconsDirectory: directory.appendingPathComponent("assets/icons")
                )
            }
            directory.deleteLastPathComponent()
        }
        fatalError("Repository resources not found")
    }

    private func makeController(
        state: MenuState? = nil,
        history: any PhraseHistoryProviding = MenuHistoryStub()
    ) -> MenuBarController {
        let resources = resources()
        let config = state?.config ?? Config.migrated(JSONObject())
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cns-menu-state-\(UUID().uuidString)")
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        return MenuBarController(
            config: config,
            i18n: I18n.load("en", localesDirectory: resources.localesDirectory),
            resources: resources,
            paths: paths,
            phraseHistory: history,
            initialState: state,
            installStatusItem: false
        )
    }

    @Test("Session snapshots select the factual status icon")
    func statusIcons() {
        let controller = makeController()
        for (phase, expected) in [
            (MenuSessionPhase.idle, "idle"),
            (.recording, "recording"),
            (.processing, "processing"),
            (.failed, "idle")
        ] {
            var state = controller.state
            state.session = phase
            controller.apply(state)
            #expect(controller.statusIconState == expected)
        }
    }

    @Test("Permission parent and exactly two children reflect the snapshot")
    func permissionSnapshot() throws {
        let config = Config.migrated(JSONObject())
        let state = MenuState(
            config: config,
            permissions: MenuPermissionSnapshot(
                microphone: .granted,
                accessibilityGranted: false,
                setupComplete: false
            )
        )
        let controller = makeController(state: state)
        let parent = try #require(controller.menu.item(withTitle: "Permissions"))
        let submenu = try #require(parent.submenu)
        #expect(submenu.items.count == 2)
        #expect(submenu.items[0].title.contains("Granted"))
        #expect(submenu.items[1].title.contains("Required"))
        #expect(parent.image != nil)
    }

    @Test("Active and desired models are distinct native states")
    func activeAndDesiredModels() throws {
        var config = Config.migrated(JSONObject())
        config.raw["stt_backend"] = .string("gemini")
        config.raw["stt_cloud_model"] = .string("gemini-2.5-flash-lite")
        let runtime = MenuRuntimeSnapshot(
            phase: .reconfiguring,
            desiredSTTBackend: "gemini",
            desiredSTTModel: "gemini-2.5-flash-lite",
            activeSTTBackend: "local",
            activeSTTModel: "whisper-large-v3-turbo"
        )
        let controller = makeController(state: MenuState(config: config, runtime: runtime))
        let submenu = try #require(controller.menu.item(withTitle: "Model")?.submenu)
        let desired = try #require(submenu.items.first {
            ($0.representedObject as? String) == "gemini|gemini-2.5-flash-lite"
        })
        let active = try #require(submenu.items.first {
            ($0.representedObject as? String) == "mlx-community/whisper-large-v3-turbo"
        })
        #expect(desired.state == .mixed)
        #expect(active.state == .on)
    }

    @Test("Structural changes are deferred until menu tracking ends")
    func defersStructuralRebuild() throws {
        let controller = makeController()
        let editorBefore = try #require(controller.menu.items.first {
            $0.identifier?.rawValue == "ai-editor.backend"
        })
        #expect(editorBefore.state == .off)

        controller.menuWillOpen(controller.menu)
        var updated = controller.state
        updated.config.raw["ai_editor_enabled"] = .bool(true)
        controller.apply(updated)
        let duringTracking = try #require(controller.menu.items.first {
            $0.identifier?.rawValue == "ai-editor.backend"
        })
        #expect(duringTracking.state == .off)

        controller.menuDidClose(controller.menu)
        let afterClose = try #require(controller.menu.items.first {
            $0.identifier?.rawValue == "ai-editor.backend"
        })
        #expect(afterClose.state == .mixed)
    }

    @Test("History copy writes phrase text only")
    func historyCopy() throws {
        let entry = PhraseHistoryEntry(timestamp: "2026-08-29T12:00:00", text: "copy only me")
        let history = MenuHistoryStub(page: PhraseHistoryPage(totalCount: 1, entries: [entry]))
        var state = MenuState(config: Config.migrated(JSONObject()))
        state.history = MenuHistorySnapshot(totalCount: 1, rows: [entry])
        let controller = makeController(state: state, history: history)
        let parent = try #require(controller.menu.items.first { $0.identifier?.rawValue == "history" })
        let submenu = try #require(parent.submenu)
        _ = try #require(submenu.items.first { ($0.representedObject as? String) == entry.text })
        NSPasteboard.general.clearContents()
        controller.copyPhraseToPasteboard(entry.text)
        #expect(NSPasteboard.general.string(forType: .string) == entry.text)
        #expect(NSPasteboard.general.string(forType: .string)?.contains(entry.timestamp) == false)
    }

    @Test("Download and update snapshots remain factual")
    func downloadAndUpdateState() throws {
        var state = MenuState(config: Config.migrated(JSONObject()))
        state.localModels["mlx-community/whisper-large-v3-turbo"] = .downloading
        state.download = MenuDownloadSnapshot(
            phase: .downloading,
            modelID: "whisper-large-v3-turbo",
            fractionCompleted: 0.5
        )
        state.updateAvailableVersion = "2.0.0"
        let controller = makeController(state: state)
        let modelMenu = try #require(controller.menu.item(withTitle: "Model")?.submenu)
        #expect(modelMenu.items.contains { $0.title.contains("Downloading") })
        #expect(controller.menu.items.contains {
            $0.identifier?.rawValue == "download.progress" && $0.title.contains("50")
        })
        #expect(controller.menu.items.contains { $0.title.contains("v2.0.0") })
    }

    @Test("Runtime status row covers preparing, active, degraded, and stopping")
    func runtimeStatusSnapshots() throws {
        let controller = makeController()
        for (phase, expected) in [
            (MenuRuntimePhase.preparing, "Preparing"),
            (.ready, "Active"),
            (.reconfiguring, "Pending"),
            (.degraded, "unavailable"),
            (.stopping, "Stopping")
        ] {
            var state = controller.state
            state.runtime.phase = phase
            state.runtime.activeSTTBackend = "local"
            state.runtime.activeSTTModel = "whisper-large-v3-turbo"
            state.runtime.desiredSTTBackend = "gemini"
            controller.apply(state)
            let submenu = try #require(controller.menu.item(withTitle: "Model")?.submenu)
            let status = try #require(submenu.items.first {
                $0.identifier?.rawValue == "runtime-status"
            })
            #expect(status.title.localizedCaseInsensitiveContains(expected))
        }
    }

    @Test("Degraded runtime exposes its message and recovery actions")
    func degradedRuntimeRecovery() throws {
        var state = MenuState(config: Config.migrated(JSONObject()))
        state.runtime.phase = .degraded
        state.runtime.userMessage = "Credential missing"
        state.runtime.recoveryActions = [.openAPIKeys, .keepPreviousRuntime, .retry]
        let controller = makeController(state: state)
        let submenu = try #require(controller.menu.item(withTitle: "Model")?.submenu)

        let status = try #require(submenu.items.first {
            $0.identifier?.rawValue == "runtime-status"
        })
        #expect(status.title == "Credential missing")
        #expect(submenu.items.contains { $0.title == "Open API Keys" })
        #expect(submenu.items.contains { $0.title == "Keep current runtime" })
        #expect(submenu.items.contains { $0.title == "Retry" })
    }
}
