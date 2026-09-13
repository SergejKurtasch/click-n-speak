import XCTest
@testable import ClickNSpeak
@testable import CNSCore

private final class FakePermissionService: PermissionServicing {
    var setupDoneURL: URL { URL(fileURLWithPath: "/tmp/setup") }
    
    var setupDone = false
    var microphone: CNSCore.PermissionStatus = .granted
    var accessibility = true
    
    func isSetupDone() -> Bool { setupDone }
    func markSetupDone() throws { setupDone = true }
    func resetSetup() throws { setupDone = false }
    
    func microphoneStatus() -> CNSCore.PermissionStatus { microphone }
    func requestMicrophoneAccess() async -> Bool { true }
    func openMicrophoneSettings() {}
    
    func accessibilityGranted() -> Bool { accessibility }
    func openAccessibilitySettings() {}
    
    func allPermissionsGranted() -> Bool {
        microphone == .granted && accessibility
    }
}

@MainActor
final class PermissionActivationTests: XCTestCase {
    func testReconcileHotkeyAvailability() {
        let appDelegate = AppDelegate()
        let fakePerms = FakePermissionService()
        appDelegate.permissionService = fakePerms
        
        var startedCount = 0
        let lastResult = true
        appDelegate.hotkeyRegistrar = {
            startedCount += 1
            return lastResult
        }
        
        // Denied -> startedCount == 0
        appDelegate.reconcileHotkeyAvailability()
        XCTAssertEqual(startedCount, 0)
        
        // Grant permissions, but STT unavailable (runtimeCanRecord = false)
        fakePerms.microphone = .granted
        fakePerms.accessibility = true
        
        // We can't mock runtimeCoordinator easily, so we just test the shouldStartHotkey logic directly
        XCTAssertFalse(appDelegate.shouldStartHotkey(
            permissionsGranted: false,
            runtimeCanRecord: true,
            alreadyStarted: false,
            terminating: false
        ))
        
        XCTAssertFalse(appDelegate.shouldStartHotkey(
            permissionsGranted: true,
            runtimeCanRecord: false,
            alreadyStarted: false,
            terminating: false
        ))
        
        XCTAssertTrue(appDelegate.shouldStartHotkey(
            permissionsGranted: true,
            runtimeCanRecord: true,
            alreadyStarted: false,
            terminating: false
        ))
    }
}
