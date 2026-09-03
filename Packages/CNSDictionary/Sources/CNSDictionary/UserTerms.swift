import CNSCore
import Foundation

/// Reads and writes `config["user_terms"]`.
///
/// Ported from `add_term_to_user_terms` / `_term_str` / `_term_is_active` in
/// `vocab_provider.py` and `utils.py` and shared by popup, analysis, decay, and
/// dictionary review flows.
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

    /// Python `update_term_usage`: update metadata for terms present in a
    /// confirmed phrase and reactivate any matching inactive entry.
    @discardableResult
    public static func updateUsage(
        in config: inout Config,
        phrase: String,
        now: Date = Date()
    ) -> Bool {
        let phraseLower = phrase.lowercased()
        let tokens = Set(tokenizeForUsage(phraseLower))
        var byLang = config.raw["user_terms"]?.objectValue ?? JSONObject()
        var dirty = false

        for lang in byLang.keys {
            guard var items = byLang[lang]?.arrayValue else { continue }
            for index in items.indices {
                guard var object = items[index].objectValue,
                      let rawTerm = object["term"]?.stringValue else { continue }
                let key = TermCanonicalizer.canonicalKey(rawTerm)
                let found = key.contains(" ") ? phraseLower.contains(key) : tokens.contains(key)
                guard found else { continue }
                object["last_seen"] = .string(ISOTimestamp.now(now))
                object["use_count"] = .int((object["use_count"]?.intValue ?? 0) + 1)
                object.remove("inactive")
                items[index] = .object(object)
                dirty = true
            }
            byLang[lang] = .array(items)
        }
        if dirty { config.raw["user_terms"] = .object(byLang) }
        return dirty
    }

    /// Python `apply_decay`: fast-deactivate unused auto terms after 14 days,
    /// then deactivate low-use non-manual terms after the configured slow age.
    @discardableResult
    public static func applyDecay(
        to config: inout Config,
        now: Date = Date(),
        maxAgeDays: Int? = nil
    ) -> Int {
        let fastCutoff = now.addingTimeInterval(-14 * 86_400)
        let slowDays = maxAgeDays ?? Int(config.raw["max_dictionary_age_days"]?.intValue ?? 60)
        let slowCutoff = now.addingTimeInterval(-TimeInterval(slowDays * 86_400))
        var byLang = config.raw["user_terms"]?.objectValue ?? JSONObject()
        var deactivated = 0

        for lang in byLang.keys {
            guard var items = byLang[lang]?.arrayValue else { continue }
            for index in items.indices {
                guard var object = items[index].objectValue else { continue }
                let source = object["source"]?.stringValue ?? "manual"
                if source == "manual" || object["inactive"]?.isTruthy == true { continue }
                let useCount = Int(object["use_count"]?.intValue ?? 0)

                var shouldDeactivate = false
                if source == "auto", useCount < 1,
                   let addedAt = parseTimestamp(object["added_at"]?.stringValue),
                   addedAt <= fastCutoff {
                    shouldDeactivate = true
                }
                if !shouldDeactivate, useCount < 3,
                   let lastSeen = parseTimestamp(
                       object["last_seen"]?.stringValue ?? object["added_at"]?.stringValue
                   ), lastSeen < slowCutoff {
                    shouldDeactivate = true
                }
                if shouldDeactivate {
                    object["inactive"] = .bool(true)
                    items[index] = .object(object)
                    deactivated += 1
                }
            }
            byLang[lang] = .array(items)
        }
        if deactivated > 0 { config.raw["user_terms"] = .object(byLang) }
        return deactivated
    }

    private static func tokenizeForUsage(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber || character == "_" || character == "'" || character == "-" {
                current.append(character)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func parseTimestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return regular.date(from: value)
    }
}
