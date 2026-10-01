import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon `RegisterEventHotKey`. Replaces the pynput
/// CGEventTap listener in `hotkey_handler.py`. Per SWIFT_MIGRATION_PLAN.md §4.3
/// this needs neither Accessibility nor Input Monitoring, so the whole
/// `_check_start_health` / CGEventTap-failure / macOS-15-TSM-crash machinery is
/// gone. The default binding is Option+Space (`<alt>+<space>`).
@MainActor
public final class HotkeyManager {
    /// A key binding: virtual key code + Carbon modifier mask.
    public struct Binding: Sendable, Equatable {
        public var keyCode: UInt32
        public var modifiers: UInt32
        public init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
        /// Option+Space, the app default.
        public static let optionSpace = Binding(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey)
        )
    }

    private let binding: Binding
    private let onTrigger: @MainActor () -> Void
    private let registration = CarbonHotKeyRegistration()

    public init(binding: Binding = .optionSpace, onTrigger: @escaping @MainActor () -> Void) {
        self.binding = binding
        self.onTrigger = onTrigger
    }

    /// Register the hotkey and install the event handler. Returns false if
    /// registration failed.
    @discardableResult
    public func start() -> Bool {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        return registration.install(binding: binding, callback: hotkeyEventCallback, userData: selfPtr)
    }

    public func stop() {
        registration.uninstall()
    }

    /// Called from the Carbon event callback (main thread) when the hotkey fires.
    fileprivate func fire() {
        onTrigger()
    }
}

/// Owns the Carbon `EventHotKeyRef` / `EventHandlerRef` lifetime outside the
/// main actor so a nonisolated `deinit` can release them (the refs are opaque C
/// pointers, not `Sendable`). Registration/teardown are only driven by the
/// owning `HotkeyManager` on the main thread, so there is no real concurrency.
private final class CarbonHotKeyRegistration: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func install(
        binding: HotkeyManager.Binding,
        callback: @escaping @convention(c) (EventHandlerCallRef?, EventRef?, UnsafeMutableRawPointer?) -> OSStatus,
        userData: UnsafeMutableRawPointer
    ) -> Bool {
        guard hotKeyRef == nil else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &eventType, userData, &eventHandler
        )
        guard installStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x434E5321 /* "CNS!" */), id: 1)
        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            binding.keyCode, binding.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        guard registerStatus == noErr, let ref else {
            teardownHandler()
            return false
        }
        hotKeyRef = ref
        return true
    }

    func uninstall() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        teardownHandler()
    }

    private func teardownHandler() {
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        uninstall()
    }
}

/// C event handler. Carbon dispatches hot-key events on the main run loop, so
/// this runs on the main thread; we bounce to the main actor to call `fire()`.
private func hotkeyEventCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.fire()
    }
    return noErr
}
