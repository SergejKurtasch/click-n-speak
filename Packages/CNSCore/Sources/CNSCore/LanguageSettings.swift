import Foundation

/// Pure configuration reducer for recognition-language changes. Every result
/// carries normalized, ordered languages and the prompt derived from them.
public enum LanguageSettings {
    public static func selectPrimary(_ language: String, in config: Config) -> Config {
        var updated = config
        let primary = LanguageCode.normalize(language)
        guard !primary.isEmpty else { return rebuildingPrompt(in: normalized(updated)) }

        updated.raw["primary_language"] = .string(primary)
        updated.raw["language_auto_detect"] = .bool(false)
        updated.raw["additional_languages"] = .array(
            LanguageCode.dedupeList(config.additionalLanguages, primary: primary)
                .map(JSONValue.string)
        )
        return rebuildingPrompt(in: updated)
    }

    public static func toggleAdditional(_ language: String, in config: Config) -> Config {
        var updated = normalized(config)
        let language = LanguageCode.normalize(language)
        let primary = updated.primaryLanguage
        guard !language.isEmpty, language != primary else {
            return rebuildingPrompt(in: updated)
        }

        var additional = updated.additionalLanguages
        if let index = additional.firstIndex(of: language) {
            additional.remove(at: index)
        } else {
            additional.append(language)
        }
        updated.raw["additional_languages"] = .array(
            LanguageCode.dedupeList(additional, primary: primary).map(JSONValue.string)
        )
        return rebuildingPrompt(in: updated)
    }

    public static func setAutoDetect(_ enabled: Bool, in config: Config) -> Config {
        var updated = normalized(config)
        updated.raw["language_auto_detect"] = .bool(enabled)
        return rebuildingPrompt(in: updated)
    }

    private static func normalized(_ config: Config) -> Config {
        var updated = config
        let primary = LanguageCode.normalize(config.primaryLanguage)
        updated.raw["primary_language"] = .string(primary)
        updated.raw["additional_languages"] = .array(
            LanguageCode.dedupeList(config.additionalLanguages, primary: primary)
                .map(JSONValue.string)
        )
        return updated
    }

    private static func rebuildingPrompt(in config: Config) -> Config {
        var updated = config
        updated.raw["initial_prompt"] = .string(InitialPromptBuilder().build(config: updated.raw))
        return updated
    }
}
