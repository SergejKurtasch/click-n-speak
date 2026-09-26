import Testing
@testable import CNSCore

@Suite("TermCanonicalizer")
struct TermCanonicalizerTests {
    @Test("Keeps inner symbols, strips boundary punctuation")
    func innerSymbols() {
        #expect(TermCanonicalizer.canonicalize("  C++  ") == "C++")
        #expect(TermCanonicalizer.canonicalize("node.js,") == "node.js")
        #expect(TermCanonicalizer.canonicalize("(v2.1)") == "v2.1")
        #expect(TermCanonicalizer.canonicalize("x-y_z") == "x-y_z")
    }

    @Test("Preserves semantic leading prefixes")
    func semanticPrefixes() {
        #expect(TermCanonicalizer.canonicalize(".NET") == ".NET")
        #expect(TermCanonicalizer.canonicalize("@mention") == "@mention")
        // Verified against Python canonicalize_term: leading dots are stripped
        // one by one until a dot immediately precedes an alphanumeric, which is
        // treated as a semantic prefix and preserved. "...hello" → ".hello".
        #expect(TermCanonicalizer.canonicalize("...hello") == ".hello")
    }

    @Test("Collapses internal whitespace")
    func whitespace() {
        #expect(TermCanonicalizer.canonicalize("machine   learning") == "machine learning")
    }

    @Test("Canonical key lowercases")
    func key() {
        #expect(TermCanonicalizer.canonicalKey("  MLX, ") == "mlx")
    }

    @Test("Empty / punctuation-only yields empty")
    func empty() {
        #expect(TermCanonicalizer.canonicalize("   ") == "")
        #expect(TermCanonicalizer.canonicalize("!!!") == "")
    }
}

@Suite("LanguageCode")
struct LanguageCodeTests {
    @Test("Normalize folds ua → uk")
    func normalize() {
        #expect(LanguageCode.normalize("UA") == "uk")
        #expect(LanguageCode.normalize("  ru ") == "ru")
        #expect(LanguageCode.normalize(nil) == "")
    }

    @Test("Dedupe removes duplicates and primary")
    func dedupe() {
        #expect(LanguageCode.dedupeList(["ua", "en", "en", "uk"], primary: "uk") == ["en"])
        #expect(LanguageCode.dedupeList(["en", "de", "en"]) == ["en", "de"])
    }

    @Test("Script family")
    func script() {
        #expect(LanguageCode.script("ru") == "cyrillic")
        #expect(LanguageCode.script("ua") == "cyrillic")
        #expect(LanguageCode.script("en") == "latin")
    }

    @Test("Detect term script by dominant alphabet")
    func detect() {
        #expect(LanguageCode.detectTermScript("нейросеть") == "cyrillic")
        #expect(LanguageCode.detectTermScript("MLX") == "latin")
        #expect(LanguageCode.detectTermScript("123") == nil)
        #expect(LanguageCode.detectTermScript("ab вг") == nil) // tied
    }
}

@Suite("LanguageSettings")
struct LanguageSettingsTests {
    private func config(
        primary: String = "ru",
        additional: [String] = ["ua", "en", "uk", "ru"],
        autoDetect: Bool = false
    ) -> Config {
        var raw = JSONObject()
        raw["primary_language"] = .string(primary)
        raw["additional_languages"] = .array(additional.map(JSONValue.string))
        raw["language_auto_detect"] = .bool(autoDetect)
        raw["user_terms"] = .object(JSONObject([
            ("de", .array([.string("Wörterbuch")])),
            ("uk", .array([.string("словник")])),
        ]))
        raw["initial_prompt"] = .string("stale")
        return Config(raw: raw)
    }

    @Test("Selecting an explicit primary disables auto-detect and rebuilds prompt")
    func autoToExplicitPrimary() {
        let updated = LanguageSettings.selectPrimary(
            " DE ",
            in: config(additional: ["ua", "en", "de", "uk"], autoDetect: true)
        )

        #expect(updated.primaryLanguage == "de")
        #expect(updated.raw["language_auto_detect"]?.boolValue == false)
        #expect(updated.additionalLanguages == ["uk", "en"])
        #expect(updated.initialPrompt == InitialPromptBuilder().build(config: updated.raw))
        #expect(updated.initialPrompt.contains("Wörterbuch"))
    }

    @Test("Additional-language toggles preserve order and normalize ua to uk")
    func toggleAdditional() {
        let removed = LanguageSettings.toggleAdditional("UA", in: config())
        #expect(removed.additionalLanguages == ["en"])
        #expect(removed.initialPrompt == InitialPromptBuilder().build(config: removed.raw))
        #expect(!removed.initialPrompt.contains("словник"))

        let restored = LanguageSettings.toggleAdditional("ua", in: removed)
        #expect(restored.additionalLanguages == ["en", "uk"])
        #expect(restored.initialPrompt == InitialPromptBuilder().build(config: restored.raw))
        #expect(restored.initialPrompt.contains("словник"))
    }

    @Test("The primary language is excluded from normalized additional languages")
    func primaryExcludedFromAdditional() {
        let updated = LanguageSettings.selectPrimary(
            "ua",
            in: config(additional: ["en", "uk", "UA", "ru"])
        )

        #expect(updated.primaryLanguage == "uk")
        #expect(updated.additionalLanguages == ["en", "ru"])
    }

    @Test("Auto-detect and explicit mode always carry the matching prompt")
    func autoDetectPrompt() {
        let automatic = LanguageSettings.setAutoDetect(true, in: config())
        #expect(automatic.raw["language_auto_detect"]?.boolValue == true)
        #expect(automatic.initialPrompt.isEmpty)

        let explicit = LanguageSettings.setAutoDetect(false, in: automatic)
        #expect(explicit.raw["language_auto_detect"]?.boolValue == false)
        #expect(explicit.initialPrompt == InitialPromptBuilder().build(config: explicit.raw))
        #expect(!explicit.initialPrompt.isEmpty)
    }
}
