import AppKit

/// Shared lifecycle contract for reusable menu-bar windows. Business state is
/// refreshed before every presentation and dismissal remains explicit.
@MainActor
public protocol RefreshablePanel: AnyObject {
    func refreshForPresentation()
    func dismissPanel()
}

public extension RefreshablePanel where Self: NSWindow {
    func presentPanel() {
        refreshForPresentation()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismissPanel() {
        close()
    }
}
