import Testing
@testable import CNSCore
@testable import CNSDictionary

@Suite("UserTerms")
struct UserTermsTests {
    private func makeConfig(primary: String = "ru", additional: [String] = ["en"]) -> Config {
        var obj = JSONObject()
        obj["schema_version"] = .int(9)
        obj["primary_language"] = .string(primary)
        obj["additional_languages"] = .array(additional.map { .string($0) })
        return Config(raw: obj)
    }

    @Test("A new term is stored as a v5 entry")
    func addsV5Entry() {
        var config = makeConfig()
        #expect(UserTerms.add(to: &config, lang: "ru", term: "нейросеть") == true)

        let entry = config.raw["user_terms"]?.objectValue?["ru"]?.arrayValue?.first?.objectValue
        #expect(entry?["term"]?.stringValue == "нейросеть")
        #expect(entry?["source"]?.stringValue == "manual")
        #expect(entry?["use_count"]?.intValue == 0)
        #expect(entry?["added_at"]?.stringValue != nil)
    }

    @Test("Duplicates are rejected case-insensitively")
    func rejectsDuplicates() {
        var config = makeConfig()
        #expect(UserTerms.add(to: &config, lang: "en", term: "Whisper") == true)
        #expect(UserTerms.add(to: &config, lang: "en", term: "whisper") == false)
        #expect(config.raw["user_terms"]?.objectValue?["en"]?.arrayValue?.count == 1)
    }

    @Test("Empty and punctuation-only terms are rejected")
    func rejectsEmpty() {
        var config = makeConfig()
        #expect(UserTerms.add(to: &config, lang: "ru", term: "   ") == false)
        #expect(UserTerms.add(to: &config, lang: "ru", term: "...") == false)
        #expect(UserTerms.add(to: &config, lang: "", term: "термин") == false)
    }

    @Test("Inner punctuation survives sanitising, boundaries do not")
    func sanitises() {
        #expect(UserTerms.sanitize("  node.js  ") == "node.js")
        #expect(UserTerms.sanitize("C++,") == "C++")
        // Double quotes become single ones, and the trailing quote is then
        // stripped as boundary punctuation — same as the Python _sanitize_term.
        #expect(UserTerms.sanitize("say \"this\"") == "say 'this")
        #expect(UserTerms.sanitize("multi\nline term") == "multi line term")
    }

    @Test("Terms route to the language matching their script")
    func routesByScript() {
        let config = makeConfig(primary: "ru", additional: ["en"])
        #expect(UserTerms.targetLanguage(for: "нейросеть", config: config) == "ru")
        #expect(UserTerms.targetLanguage(for: "Whisper", config: config) == "en")
        // No letters, or a Latin/Cyrillic tie → primary.
        #expect(UserTerms.targetLanguage(for: "2026", config: config) == "ru")
        #expect(UserTerms.targetLanguage(for: "abвг", config: config) == "ru")
    }

    @Test("With no matching additional language, terms fall back to primary")
    func fallsBackToPrimary() {
        let config = makeConfig(primary: "ru", additional: [])
        #expect(UserTerms.targetLanguage(for: "Whisper", config: config) == "ru")
    }

    @Test("Only active terms are listed")
    func listsActiveTerms() {
        var config = makeConfig()
        UserTerms.add(to: &config, lang: "ru", term: "первый")
        UserTerms.add(to: &config, lang: "ru", term: "второй")

        // Deactivate the second entry the way decay does.
        var byLang = config.raw["user_terms"]!.objectValue!
        var items = byLang["ru"]!.arrayValue!
        var second = items[1].objectValue!
        second["inactive"] = .bool(true)
        items[1] = .object(second)
        byLang["ru"] = .array(items)
        config.raw["user_terms"] = .object(byLang)

        #expect(UserTerms.activeTerms(config, lang: "ru") == ["первый"])
    }
}
