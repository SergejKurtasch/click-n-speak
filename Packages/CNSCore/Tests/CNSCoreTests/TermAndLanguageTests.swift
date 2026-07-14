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
