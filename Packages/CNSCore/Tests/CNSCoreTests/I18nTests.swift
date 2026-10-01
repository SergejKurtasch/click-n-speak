import Testing
import Foundation
@testable import CNSCore

@Suite("I18n")
struct I18nTests {
    /// Write minimal locale files to a temp directory so the engine is tested
    /// hermetically, without depending on the repo's real locale files.
    private func makeLocales() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cns-i18n-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let en = #"""
        {"greet": "Hello {name}", "only_en": "English only", "terms": ["term", "terms"]}
        """#
        let ru = #"""
        {"greet": "Привет {name}", "terms": ["термин", "термина", "терминов"]}
        """#
        try en.write(to: dir.appendingPathComponent("en.json"), atomically: true, encoding: .utf8)
        try ru.write(to: dir.appendingPathComponent("ru.json"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test("Translation with argument substitution")
    func substitution() throws {
        let dir = try makeLocales()
        let i18n = I18n.load("ru", localesDirectory: dir)
        #expect(i18n.t("greet", ["name": "Сергей"]) == "Привет Сергей")
    }

    @Test("Falls back to English then to the key")
    func fallback() throws {
        let dir = try makeLocales()
        let i18n = I18n.load("ru", localesDirectory: dir)
        #expect(i18n.t("only_en") == "English only")
        #expect(i18n.t("missing_everywhere") == "missing_everywhere")
    }

    @Test("Unknown language loads English")
    func unknownLang() throws {
        let dir = try makeLocales()
        let i18n = I18n.load("xx", localesDirectory: dir)
        #expect(i18n.lang == "en")
        #expect(i18n.t("only_en") == "English only")
    }

    @Test("Russian Slavic plural forms")
    func russianPlurals() throws {
        let dir = try makeLocales()
        let i18n = I18n.load("ru", localesDirectory: dir)
        #expect(i18n.plural("terms", 1) == "термин")   // one
        #expect(i18n.plural("terms", 2) == "термина")  // few
        #expect(i18n.plural("terms", 3) == "термина")
        #expect(i18n.plural("terms", 5) == "терминов") // many
        #expect(i18n.plural("terms", 11) == "терминов")
        #expect(i18n.plural("terms", 21) == "термин")
        #expect(i18n.plural("terms", 22) == "термина")
        #expect(i18n.plural("terms", 25) == "терминов")
    }

    @Test("English two-form plural")
    func englishPlurals() throws {
        let dir = try makeLocales()
        let i18n = I18n.load("en", localesDirectory: dir)
        #expect(i18n.plural("terms", 1) == "term")
        #expect(i18n.plural("terms", 0) == "terms")
        #expect(i18n.plural("terms", 5) == "terms")
    }

    @Test("Ukrainian uses Slavic rules")
    func ukrainianPluralIndex() throws {
        let dir = try makeLocales()
        // uk not in fixtures → loads en strings, but plural index rule follows lang.
        let ukEn = I18n.load("uk", localesDirectory: dir)
        #expect(ukEn.pluralIndex(1) == 0)
        #expect(ukEn.pluralIndex(3) == 1)
        #expect(ukEn.pluralIndex(5) == 2)
        #expect(ukEn.pluralIndex(11) == 2)
    }
}
