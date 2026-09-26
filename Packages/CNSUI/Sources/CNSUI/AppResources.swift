import AppKit
import CNSCore

/// Locates bundled resources (locales, menu-bar icons) whether the app runs as a
/// `.app` bundle (Resources) or as a raw executable during development
/// (repo-relative fallback, or `CNS_RESOURCES_DIR`).
public struct AppResources: Sendable {
    public static let requiredMenuBarIcons = ["idle", "recording", "processing"]
    public static let requiredMenuItemIcons = [
        "accessibility-ok", "accessibility-warn", "advanced", "ai-editor",
        "check-updates", "copy-phrase", "download-model", "initial-prompt",
        "languages", "last-phrases", "launch-at-login", "microphone-ok",
        "microphone-warn", "model", "permissions-ok", "permissions-warn",
        "restart", "transcribe-file"
    ]
    @MainActor private static var loggedMissingAssets = Set<String>()

    public let localesDirectory: URL
    public let iconsDirectory: URL

    public init(localesDirectory: URL, iconsDirectory: URL) {
        self.localesDirectory = localesDirectory
        self.iconsDirectory = iconsDirectory
    }

    /// Resolve resources for the current run context.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppResources {
        if let override = environment["CNS_RESOURCES_DIR"], !override.isEmpty {
            let base = URL(fileURLWithPath: override, isDirectory: true)
            return AppResources(
                localesDirectory: base.appendingPathComponent("locales"),
                iconsDirectory: base.appendingPathComponent("icons")
            )
        }
        // Bundled .app: locales/ and icons/ sit in Contents/Resources.
        if let resourceURL = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("locales").path) {
            return AppResources(
                localesDirectory: resourceURL.appendingPathComponent("locales"),
                iconsDirectory: resourceURL.appendingPathComponent("icons")
            )
        }
        // Dev fallback: walk up from the executable to find the repo root.
        var dir = URL(fileURLWithPath: CommandLine.arguments.first ?? ".").deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("locales").path) {
                return AppResources(
                    localesDirectory: dir.appendingPathComponent("locales"),
                    iconsDirectory: dir.appendingPathComponent("assets/icons")
                )
            }
            dir = dir.deletingLastPathComponent()
        }
        // Last resort: current directory.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return AppResources(
            localesDirectory: cwd.appendingPathComponent("locales"),
            iconsDirectory: cwd.appendingPathComponent("assets/icons")
        )
    }

    /// Load the app icon (`CnS.png`) used in the HUD. In the bundle it sits at
    /// Resources/CnS.png; in dev it is `assets/CnS.png` (sibling of icons/).
    @MainActor
    public func appIcon() -> NSImage? {
        let candidates = [
            iconsDirectory.deletingLastPathComponent().appendingPathComponent("CnS.png"),
            iconsDirectory.appendingPathComponent("CnS.png"),
        ]
        for url in candidates {
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    /// Load a menu-bar state icon (`idle`/`recording`/`processing`), preferring
    /// the Template variant so it adapts to light/dark menu bars.
    @MainActor
    public func menuBarIcon(state: String) -> NSImage? {
        for name in ["\(state)Template.png", "\(state).png"] {
            let url = iconsDirectory.appendingPathComponent("menubar").appendingPathComponent(name)
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = name.contains("Template")
                image.size = NSSize(width: 22, height: 22)
                return image
            }
        }
        return nil
    }

    /// Load a menu item icon, preferring the Template variant so it adapts to
    /// light/dark mode and selection state.
    @MainActor
    public func menuItemIcon(name: String) -> NSImage? {
        for filename in ["\(name)Template.png", "\(name).png"] {
            let url = iconsDirectory.appendingPathComponent("menu").appendingPathComponent(filename)
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = filename.contains("Template")
                image.size = NSSize(width: 16, height: 16)
                return image
            }
        }
        let symbolName: String?
        switch name {
        case "api-keys": symbolName = "key.fill"
        default: symbolName = nil
        }
        if let symbolName,
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: name) {
            image.isTemplate = true
            return image
        }
        return nil
    }

    @MainActor
    public func missingRequiredAssets() -> [String] {
        var missing: [String] = []
        for state in Self.requiredMenuBarIcons where menuBarIcon(state: state) == nil {
            missing.append("menubar/\(state)")
        }
        for name in Self.requiredMenuItemIcons where menuItemIcon(name: name) == nil {
            missing.append("menu/\(name)")
        }
        if menuItemIcon(name: "api-keys") == nil {
            missing.append("system/api-keys")
        }
        return missing
    }

    @MainActor
    public func logMissingAssetOnce(_ name: String, log: (String) -> Void) {
        guard Self.loggedMissingAssets.insert(name).inserted else { return }
        log("Missing required UI asset: \(name)")
    }
}
