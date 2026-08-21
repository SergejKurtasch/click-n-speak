import CNSCore
import Foundation

/// Reads and writes `config["user_terms"]`.
///
/// Ported from `add_term_to_user_terms` / `_term_str` / `_term_is_active` in
/// `vocab_provider.py` and `utils.py`. Only the popup's ⌘D path is needed in
/// Phase 3; the analyzers, decay and review panels arrive in Phase 5.
public enum UserTerms {
    public enum Source: String, Sendable {
        case manual, auto, correction
    }

    /// The term string of a v5 dict entry or a legacy plain string (`_term_str`).
    public static func termString(_ value: JSONValue) -> String {
        if let s = value.stringValue { return s }
        return value.objectValue?["term"]?.stringValue ?? ""
    }

    /// False only for entries explicitly deactivated by decay (`_term_is_active`).
    public static func isActive(_ value: JSONValue) -> Bool {
        guard let obj = value.objectValue else { return true }
        return !(obj["inactive"]?.isTruthy ?? false)
    }

    /// Active term strings for one language, in stored order.
    public static func activeTerms(_ config: Config, lang: String) -> [String] {
        guard let byLang = config.raw["user_terms"]?.objectValue,
              let list = byLang[LanguageCode.normalize(lang)]?.arrayValue else { return [] }
        return list.filter(isActive).map(termString).filter { !$0.isEmpty }
    }

    /// Add `term` to `user_terms[lang]`, case-insensitively deduplicated.
    /// Mutates `config` only; the caller owns rebuilding the prompt and saving.
    /// - Returns: true only when a new term was inserted.
    @discardableResult
    public static func add(
        to config: inout Config,
        lang: String,
        term: String,
        source: Source = .manual,
        now: String = ISOTimestamp.now()
    ) -> Bool {
        let normalizedLang = LanguageCode.normalize(lang)
        let normalizedTerm = sanitize(term)
        guard !normalizedLang.isEmpty, !normalizedTerm.isEmpty else { return false }

        var byLang = config.raw["user_terms"]?.objectValue ?? JSONObject()
        var items = byLang[normalizedLang]?.arrayValue ?? []
        let existing = Set(items.map { TermCanonicalizer.canonicalKey(termString($0)) })
        guard !existing.contains(TermCanonicalizer.canonicalKey(normalizedTerm)) else { return false }

        if config.schemaVersion >= 5 {
            var entry = JSONObject()
            entry["term"] = .string(normalizedTerm)
            entry["source"] = .string(source.rawValue)
            entry["added_at"] = .string(now)
            entry["last_seen"] = .string(now)
            entry["use_count"] = .int(0)
            items.append(.object(entry))
        } else {
            items.append(.string(normalizedTerm))
        }

        byLang[normalizedLang] = .array(items)
        config.raw["user_terms"] = .object(byLang)
        return true
    }

    /// Which configured language a term belongs to, by dominant script
    /// (`detect_term_script` + `target_lang_for_script_bucket`). A term with no
    /// letters, or an even Latin/Cyrillic split, goes to the primary language.
    public static func targetLanguage(for term: String, config: Config) -> String {
        let primary = config.primaryLanguage
        guard let script = LanguageCode.detectTermScript(term) else { return primary }
        return targetLanguage(
            forScript: script,
            primary: primary,
            additional: config.additionalLanguages
        )
    }

    /// `target_lang_for_script_bucket`.
    public static func targetLanguage(
        forScript script: String,
        primary: String,
        additional: [String]
    ) -> String {
        let primaryCode = LanguageCode.normalize(primary)
        if LanguageCode.script(primaryCode) == script { return primaryCode }
        for code in additional.map(LanguageCode.normalize) where LanguageCode.script(code) == script {
            return code
        }
        return primaryCode
    }

    /// `_sanitize_term`: single line, no double quotes, canonical boundaries.
    public static func sanitize(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return TermCanonicalizer.canonicalize(collapsed)
    }
}
