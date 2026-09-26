import ApplicationServices
import CoreGraphics
import Foundation

public protocol KeyboardAdapting: Sendable {
    /// Send ⌘V to the frontmost app.
    func paste() throws
    /// Type `text` directly, without touching the pasteboard.
    func typeText(_ text: String) throws
}

/// `QuartzKeyboardAdapter` from `injector.py`: posts synthetic key events without
/// querying Text Services, which is not safe from a worker thread.
public struct QuartzKeyboardAdapter: KeyboardAdapting {
    private static let virtualKeyV: CGKeyCode = 9
    private static let virtualKeyA: CGKeyCode = 0

    /// Unicode events carry a bounded string; long text goes out in slices with a
    /// short gap so the receiving app's event queue keeps up.
    private let chunkSize: Int
    private let chunkDelay: TimeInterval

    public init(chunkSize: Int = 20, chunkDelay: TimeInterval = 0.005) {
        self.chunkSize = chunkSize
        self.chunkDelay = chunkDelay
    }

    public func paste() throws {
        for isKeyDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: nil,
                virtualKey: Self.virtualKeyV,
                keyDown: isKeyDown
            ) else {
                throw InjectionError.keyboardEventsUnavailable
            }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    public func typeText(_ text: String) throws {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            let slice = Array(units[index..<end])
            try post(slice)
            index = end
            if index < units.count, chunkDelay > 0 {
                Thread.sleep(forTimeInterval: chunkDelay)
            }
        }
    }

    private func post(_ utf16Units: [UInt16]) throws {
        for isKeyDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: nil,
                virtualKey: Self.virtualKeyA,
                keyDown: isKeyDown
            ) else {
                throw InjectionError.keyboardEventsUnavailable
            }
            event.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
            event.post(tap: .cghidEventTap)
        }
    }
}

/// `AXIsProcessTrusted()` without prompting — the same check `is_accessibility_trusted`
/// makes before every injection.
public enum AccessibilityTrust {
    public static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }
}
