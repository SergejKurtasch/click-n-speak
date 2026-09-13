content = """import XCTest
@testable import CNSUI
import CNSCore
import AppKit

final class CredentialDialogTests: XCTestCase {
    
    private func repoResources() -> AppResources {
        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return AppResources(
            localesDirectory: repoRoot.appendingPathComponent("locales"),
            iconsDirectory: repoRoot.appendingPathComponent("ClickNSpeak/Resources")
        )
    }

    var sut: MenuBarController!
    
    @MainActor
    override func setUp() async throws {
        try super.setUp()
        
        let resources = repoResources()
        let i18n = I18n.load("en", localesDirectory: resources.localesDirectory)
        let config = Config()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cns-menu-tests-\\(UUID().uuidString)")
        let paths = Paths(mode: .dev, environment: ["CNS_DATA_DIR": directory.path])
        
        sut = MenuBarController(
            config: config,
            i18n: i18n,
            resources: resources,
            paths: paths,
            installStatusItem: false
        )
    }
    
    @MainActor
    func testSaveNewCredential() {
        sut.testKeychain = [:]
        
        var alertShown = false
        var successAlertShown = false
        var changesReported = [String]()
        
        sut.onCredentialsChanged = { provider in
            changesReported.append(provider)
        }
        
        sut.alertRunner = { alert in
            if alert.messageText == "dialog.gemini_key_title" || alert.messageText == "Gemini API Key" {
                alertShown = true
                if let tf = alert.accessoryView as? NSSecureTextField {
                    tf.stringValue = "sk-gemini-test-1234567" // > 20 chars
                }
                return .alertFirstButtonReturn // Save
            } else if alert.messageText == "dialog.credential_saved" || alert.messageText == "Key saved. Availability will be checked upon next use." {
                successAlertShown = true
                return .alertFirstButtonReturn
            }
            return .alertSecondButtonReturn
        }
        
        sut.perform(Selector("onGeminiApiKey"))
        
        XCTAssertTrue(alertShown)
        XCTAssertTrue(successAlertShown)
        XCTAssertEqual(changesReported, ["gemini"])
        
        let stored = sut.testKeychain?["\\(KeychainHelper.defaultService)-\\(KeychainHelper.geminiAccount)"]
        XCTAssertEqual(stored, "sk-gemini-test-1234567")
    }
    
    @MainActor
    func testEnvironmentOverrideDisablesInputs() {
        sut.testEnvironment = ["GOOGLE_API_KEY": "env-key"]
        
        var alertShown = false
        sut.alertRunner = { alert in
            if alert.messageText == "dialog.gemini_key_title" || alert.messageText == "Gemini API Key" {
                alertShown = true
                
                // Assert it says something about environment
                XCTAssertTrue(alert.informativeText.contains("GOOGLE_API_KEY"))
                
                if let tf = alert.accessoryView as? NSSecureTextField {
                    XCTAssertFalse(tf.isEnabled)
                }
                XCTAssertFalse(alert.buttons[0].isEnabled) // Save
                XCTAssertFalse(alert.buttons[2].isEnabled) // Clear
                
                return .alertSecondButtonReturn // Cancel
            }
            return .alertSecondButtonReturn
        }
        
        sut.perform(Selector("onGeminiApiKey"))
        XCTAssertTrue(alertShown)
    }
    
    @MainActor
    func testValidationFailureKeepsText() {
        sut.testKeychain = [:]
        
        var runs = 0
        var validationErrorShown = false
        
        sut.alertRunner = { alert in
            if alert.messageText == "dialog.gemini_key_title" || alert.messageText == "Gemini API Key" {
                runs += 1
                if runs == 1 {
                    if let tf = alert.accessoryView as? NSSecureTextField {
                        tf.stringValue = "short" // Invalid!
                    }
                    return .alertFirstButtonReturn // Save -> causes validation error
                } else if runs == 2 {
                    // Check that text is still there!
                    if let tf = alert.accessoryView as? NSSecureTextField {
                        XCTAssertEqual(tf.stringValue, "short")
                        tf.stringValue = "sk-valid-key-123456789" // fix it
                    }
                    return .alertFirstButtonReturn
                }
            } else if alert.messageText == "dialog.api_key_invalid_title" || alert.messageText == "Invalid API Key" {
                validationErrorShown = true
                return .alertFirstButtonReturn
            } else if alert.messageText == "dialog.credential_saved" {
                return .alertFirstButtonReturn
            }
            return .alertSecondButtonReturn
        }
        
        sut.perform(Selector("onGeminiApiKey"))
        
        XCTAssertEqual(runs, 2)
        XCTAssertTrue(validationErrorShown)
        let stored = sut.testKeychain?["\\(KeychainHelper.defaultService)-\\(KeychainHelper.geminiAccount)"]
        XCTAssertEqual(stored, "sk-valid-key-123456789")
    }
}
"""

with open("Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift", "w") as f:
    f.write(content)
