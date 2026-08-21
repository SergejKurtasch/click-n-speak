import AppKit
import Foundation

/// One `type -> data` pair of a pasteboard item.
public struct PasteboardEntry: Sendable, Equatable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// Every item on the pasteboard with every representation it carried, so a
/// restore puts back file promises, RTF, images — not just plain text.
public struct PasteboardSnapshot: Sendable, Equatable {
    public let items: [[PasteboardEntry]]

    public init(items: [[PasteboardEntry]]) {
        self.items = items
    }
}

public protocol ClipboardAdapting: Sendable {
    func isAvailable() -> Bool
    func snapshot() throws -> PasteboardSnapshot
    /// Replace the contents with `text`; returns the resulting `changeCount`.
    func setText(_ text: String) throws -> Int
    /// Put `snapshot` back, but only if nothing else wrote to the pasteboard
    /// since `expectedChangeCount`. Returns false when the restore was skipped.
    @discardableResult
    func restoreIfUnchanged(_ snapshot: PasteboardSnapshot, expectedChangeCount: Int) throws -> Bool
}

/// `MacPasteboardAdapter` from `injector.py`, one-to-one.
public struct MacPasteboardAdapter: ClipboardAdapting {
    private let log: @Sendable (String) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.log = log
    }

    public func isAvailable() -> Bool { true }

    public func snapshot() throws -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        var items: [[PasteboardEntry]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entries: [PasteboardEntry] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    entries.append(PasteboardEntry(type: type.rawValue, data: data))
                }
            }
            items.append(entries)
        }
        return PasteboardSnapshot(items: items)
    }

    public func setText(_ text: String) throws -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw InjectionError.pasteboardRejectedText
        }
        return pasteboard.changeCount
    }

    @discardableResult
    public func restoreIfUnchanged(
        _ snapshot: PasteboardSnapshot,
        expectedChangeCount: Int
    ) throws -> Bool {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expectedChangeCount else {
            log("Clipboard changed after injection; preserving the user's new content.")
            return false
        }

        let restored: [NSPasteboardItem] = snapshot.items.map { entries in
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            return item
        }

        pasteboard.clearContents()
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
        return true
    }
}
