import Testing
@testable import CNSTranscription

@Suite("Allowed language selection")
struct AllowedLanguageSelectionTests {
    private let ids: [String: Int32] = ["ru": 0, "en": 1, "zh": 2]

    @Test("Chooses the most probable permitted language even when another language wins globally")
    func constrainsAutomaticDetection() {
        let selected = AllowedLanguageSelection.select(
            allowedLanguages: ["ru", "en"],
            probabilities: [0.12, 0.32, 0.56],
            languageID: { ids[$0] ?? -1 }
        )
        #expect(selected == "en")
    }

    @Test("Preserves the primary language as a deterministic tie break")
    func primaryWinsTie() {
        let selected = AllowedLanguageSelection.select(
            allowedLanguages: ["ru", "en"],
            probabilities: [0.4, 0.4, 0.2],
            languageID: { ids[$0] ?? -1 }
        )
        #expect(selected == "ru")
    }

    @Test("Unrestricted detection keeps Whisper's automatic mode")
    func unrestricted() {
        let selected = AllowedLanguageSelection.select(
            allowedLanguages: [],
            probabilities: [0.1, 0.2, 0.7],
            languageID: { ids[$0] ?? -1 }
        )
        #expect(selected == nil)
    }

    @Test("A single configured language remains forced")
    func singleLanguage() {
        let selected = AllowedLanguageSelection.select(
            allowedLanguages: ["en"],
            probabilities: [],
            languageID: { ids[$0] ?? -1 }
        )
        #expect(selected == "en")
    }

    @Test("Falls back to the general prompt when constrained detection has no matching override")
    func promptFallsBackWhenLanguageIsUnavailable() {
        let fallback = "General context and vocabulary"
        #expect(
            AllowedLanguageSelection.prompt(
                for: nil,
                overrides: ["ru": "Russian context"],
                fallback: fallback
            ) == fallback
        )
        #expect(
            AllowedLanguageSelection.prompt(
                for: "en",
                overrides: ["ru": "Russian context"],
                fallback: fallback
            ) == fallback
        )
        #expect(
            AllowedLanguageSelection.prompt(
                for: "ru",
                overrides: ["ru": "Russian context"],
                fallback: fallback
            ) == "Russian context"
        )
    }
}
