import Foundation

/// Language-code helpers ported from `utils.py`. The app historically stored
/// Ukrainian as "ua" in UI/config; internally everything is normalized to the
/// ISO 639-1 "uk".
public enum LanguageCode {
    /// Canonicalise a language code for internal use (`normalize_lang_code`).
    public static func normalize(_ raw: String?) -> String {
        let code = (raw ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        return code == "ua" ? "uk" : code
    }

    /// Return language codes with stable order and no duplicates (`_dedupe_lang_list`).
    public static func dedupeList(_ languages: [String], primary: String? = nil) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let primaryCode = primary.map { normalize($0) }
        for lang in languages {
            let code = normalize(lang)
            if code.isEmpty { continue }
            if let primaryCode, code == primaryCode { continue }
            if seen.contains(code) { continue }
            seen.insert(code)
            out.append(code)
        }
        return out
    }

    private static let cyrillicLangs: Set<String> = ["ru", "uk", "ua", "be", "bg", "mk", "sr"]

    /// Script family for a configured language: "latin" or "cyrillic"
    /// (`get_language_script`).
    public static func script(_ langCode: String) -> String {
        cyrillicLangs.contains(normalize(langCode)) ? "cyrillic" : "latin"
    }

    /// Dominant script of a term: "latin", "cyrillic", or nil (`detect_term_script`).
    /// nil means no alphabetic chars, or Latin and Cyrillic counts are equal.
    public static func detectTermScript(_ term: String) -> String? {
        var latin = 0
        var cyrillic = 0
        for scalar in term.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) else { continue }
            if scalar.value < 0x400 {
                latin += 1
            } else if scalar.value >= 0x0400 && scalar.value <= 0x052F {
                cyrillic += 1
            }
        }
        if latin == 0 && cyrillic == 0 { return nil }
        if latin > cyrillic { return "latin" }
        if cyrillic > latin { return "cyrillic" }
        return nil
    }

    /// Display names keyed by language code (`LANG_NAMES`).
    public static let displayNames: [String: String] = [
        "ru": "Русский", "en": "English", "uk": "Українська",
        "de": "Deutsch", "fr": "Français", "es": "Español",
        "it": "Italiano", "pl": "Polski", "pt": "Português",
        "zh": "中文", "ja": "日本語", "ko": "한국어",
    ]
}
