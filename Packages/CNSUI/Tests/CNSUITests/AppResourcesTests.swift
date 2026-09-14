import AppKit
import CNSCore
import Foundation
import Testing
@testable import CNSUI

@MainActor
@Suite("Application resources")
struct AppResourcesTests {
    private func repositoryRoot() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("locales").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        fatalError("Repository root not found")
    }

    @Test("Every required icon resolves and status icons are templates")
    func requiredIcons() throws {
        let root = repositoryRoot()
        let resources = AppResources(
            localesDirectory: root.appendingPathComponent("locales"),
            iconsDirectory: root.appendingPathComponent("assets/icons")
        )
        #expect(resources.missingRequiredAssets().isEmpty)
        for name in AppResources.requiredMenuBarIcons {
            let image = try #require(resources.menuBarIcon(state: name))
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 22, height: 22))
        }
        #expect(resources.menuItemIcon(name: "api-keys") != nil)
    }

    @Test("Every statically referenced UI key exists and every locale has matching placeholders")
    func completeUILocaleCoverage() throws {
        let root = repositoryRoot()
        let sourceDirectory = root.appendingPathComponent("Packages/CNSUI/Sources/CNSUI")
        let sources = try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let regex = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])(?:t|plural)\(\"([^\"]+)\""#
        )
        var keys = Set<String>()
        for sourceURL in sources {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            keys.formUnion(regex.matches(in: source, range: range).compactMap { match -> String? in
                guard let valueRange = Range(match.range(at: 1), in: source) else { return nil }
                let key = String(source[valueRange])
                return key.contains(#"\("#) ? nil : key
            })
        }
        keys.formUnion([
            "menu.mic_granted", "menu.mic_required",
            "menu.access_granted", "menu.access_required",
            "dialog.file_stage_preparing", "dialog.file_stage_decoding",
            "dialog.file_stage_transcribing", "dialog.file_stage_uploading",
            "dialog.file_stage_refining", "dialog.file_stage_completed",
            "terms.source_manual", "terms.source_auto", "terms.source_correction",
            "suggestions.source_frequency", "suggestions.source_correction", "suggestions.source_both",
            "dialog.api_key_invalid_gemini", "dialog.api_key_invalid_openai",
        ])

        let englishData = try Data(contentsOf: root.appendingPathComponent("locales/en.json"))
        let english = try #require(try JSONValue.parse(data: englishData).objectValue)
        let placeholderRegex = try NSRegularExpression(pattern: #"\{([A-Za-z0-9_]+)\}"#)
        func placeholders(_ value: JSONValue) -> Set<String> {
            let strings = value.stringValue.map { [$0] }
                ?? value.arrayValue?.compactMap(\.stringValue)
                ?? []
            return Set(strings.flatMap { string in
                let range = NSRange(string.startIndex..<string.endIndex, in: string)
                return placeholderRegex.matches(in: string, range: range).compactMap { match in
                    Range(match.range(at: 1), in: string).map { String(string[$0]) }
                }
            })
        }

        let englishKeys = Set(english.keys)
        #expect(keys.subtracting(englishKeys).isEmpty, "English is missing: \(keys.subtracting(englishKeys).sorted())")
        for language in I18n.supportedLangs {
            let data = try Data(contentsOf: root.appendingPathComponent("locales/\(language).json"))
            let object = try #require(try JSONValue.parse(data: data).objectValue)
            #expect(Set(object.keys) == englishKeys, "\(language) locale keys differ from English")
            for key in englishKeys {
                let expected = try #require(english[key])
                let actual = try #require(object[key])
                #expect(placeholders(actual) == placeholders(expected), "\(language).\(key) placeholders differ")
            }
            let i18n = I18n.load(language, localesDirectory: root.appendingPathComponent("locales"))
            for key in keys where english[key]?.stringValue != nil {
                #expect(i18n.t(key) != key, "\(language) falls back to raw key \(key)")
            }
        }
    }

    @Test("Former hard-coded user-facing strings are absent and credentials are never logged")
    func noKnownRawUIStringsOrCredentialLogging() throws {
        let root = repositoryRoot()
        let uiDirectory = root.appendingPathComponent("Packages/CNSUI/Sources/CNSUI")
        let source = try FileManager.default.contentsOfDirectory(
            at: uiDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        for raw in ["Text(\"Select Languages\")", "title: \"Add to Dictionary\"", "p.title = \"Model Download\""] {
            #expect(!source.contains(raw), "Raw UI string remains: \(raw)")
        }
        let menuSource = try String(
            contentsOf: uiDirectory.appendingPathComponent("MenuBarController.swift"),
            encoding: .utf8
        )
        #expect(!menuSource.contains("log(key)"))
        #expect(!menuSource.contains("log(input.stringValue)"))
    }

    @Test("Application update progress has labels in every supported locale")
    func updateProgressLocalization() {
        let root = repositoryRoot()
        let keys = [
            "download.app_downloading",
            "download.app_downloading_percent",
            "download.app_verifying_archive",
            "download.app_staging",
            "download.app_verifying_candidate",
            "download.app_ready",
        ]
        for language in I18n.supportedLangs {
            let i18n = I18n.load(language, localesDirectory: root.appendingPathComponent("locales"))
            for key in keys {
                #expect(i18n.t(key) != key, "Missing \(language).\(key)")
            }
        }
    }
}
