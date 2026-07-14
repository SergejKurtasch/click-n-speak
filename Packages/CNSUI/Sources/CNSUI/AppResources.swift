import AppKit
import CNSCore

/// Locates bundled resources (locales, menu-bar icons) whether the app runs as a
/// `.app` bundle (Resources) or as a raw executable during development
/// (repo-relative fallback, or `CNS_RESOURCES_DIR`).
public struct AppResources: Sendable {
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

    /// Load a menu-bar state icon (`idle`/`recording`/`processing`), preferring
    /// the Template variant so it adapts to light/dark menu bars.
    @MainActor
    public func menuBarIcon(state: String) -> NSImage? {
        for name in ["\(state)Template.png", "\(state).png"] {
            let url = iconsDirectory.appendingPathComponent("menubar").appendingPathComponent(name)
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = name.contains("Template")
                return image
            }
        }
        return nil
    }
}
