/// Chooses a spoken language from the configured set using Whisper's
/// audio-only language probabilities. An empty set leaves detection unrestricted.
enum AllowedLanguageSelection {
    static func select(
        allowedLanguages: [String],
        probabilities: [Float],
        languageID: (String) -> Int32
    ) -> String? {
        if allowedLanguages.count == 1 { return allowedLanguages[0] }
        guard !allowedLanguages.isEmpty else { return nil }

        var selected: String?
        var bestProbability: Float = -.infinity
        for language in allowedLanguages {
            let id = Int(languageID(language))
            guard probabilities.indices.contains(id) else { continue }
            let probability = probabilities[id]
            guard probability.isFinite, probability >= 0 else { continue }
            if probability > bestProbability {
                selected = language
                bestProbability = probability
            }
        }
        return selected
    }

    static func prompt(
        for language: String?,
        overrides: [String: String],
        fallback: String?
    ) -> String? {
        guard let language,
              let prompt = overrides[language],
              !prompt.isEmpty else {
            return fallback
        }
        return prompt
    }
}
