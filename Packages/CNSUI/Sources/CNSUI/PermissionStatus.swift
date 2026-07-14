import AVFoundation
import ApplicationServices

/// Read-only permission checks for the menu-bar status items. These never
/// trigger a system prompt (that belongs to the Phase 6 wizard). The Swift
/// design drops Input Monitoring entirely — the global hotkey uses Carbon
/// `RegisterEventHotKey`, which needs neither Accessibility nor Input Monitoring
/// (see SWIFT_MIGRATION_PLAN.md §4.3). Only Microphone and Accessibility remain.
public enum PermissionStatus {
    /// Microphone authorization, read-only (`AVCaptureDevice.authorizationStatus`).
    public static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Accessibility trust, read-only (`AXIsProcessTrusted`). Required for the
    /// CGEvent ⌘V injection.
    public static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }
}
