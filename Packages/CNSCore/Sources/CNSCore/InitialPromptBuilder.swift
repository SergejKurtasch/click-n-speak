import Foundation

/// Abstracts BPE token counting so the initial-prompt builder can be tested and
/// used before a real Whisper tokenizer is available. Phase 1 ships only the
/// heuristic; Phase 2 injects a WhisperKit-backed counter for token-accurate
/// truncation (mirrors `_count_prompt_tokens` in `utils.py`, which uses the
/// mlx_whisper tokenizer when present and falls back to `len(text) // 3`).
public protocol TokenCounting: Sendable {
    func countTokens(_ text: String) -> Int
}

/// Conservative fallback identical to Python's heuristic: `max(1, len // 3)`,
/// where `len` counts unicode scalars (Python `len(str)` counts code points).
public struct HeuristicTokenCounter: TokenCounting {
    public init() {}
    public func countTokens(_ text: String) -> Int {
        max(1, text.unicodeScalars.count / 3)
    }
}

/// Whisper language-hint prefixes and default style sentences, plus the
/// initial-prompt assembly logic from `utils.py`.
public enum LanguageConstants {
    /// `LANG_PROMPTS`.
    public static let langPrompts: [String: String] = [
        "ru": "Русский язык.", "en": "English language.", "de": "Deutscher Text.",
        "es": "Texto en español.", "fr": "Texte en français.", "it": "Testo in italiano.",
        "pt": "Texto em português.", "nl": "Nederlandse tekst.", "pl": "Tekst po polsku.",
        "uk": "Українська мова.", "tr": "Türkçe metin.", "zh": "中文文本。",
        "ko": "한국어 텍스트。", "ar": "نص عربي.",
    ]

    /// `LANG_DEFAULT_CONTEXT`.
    public static let langDefaultContext: [String: String] = [
        "ru": "Это разговорная речь. Используются профессиональные термины и аббревиатуры.",
        "en": "This is spoken language with professional and technical vocabulary.",
        "de": "Dies ist gesprochene Sprache mit Fachbegriffen.",
        "es": "Este es lenguaje hablado con vocabulario técnico y profesional.",
        "fr": "Ceci est du langage parlé avec du vocabulaire professionnel et technique.",
        "it": "Questo è linguaggio parlato con vocabolario professionale e tecnico.",
        "pt": "Esta é linguagem falada com vocabulário profissional e técnico.",
        "nl": "Dit is gesproken taal met professionele en technische woordenschat.",
        "pl": "To jest mowa potoczna z profesjonalnym słownictwem technicznym.",
        "uk": "Це розмовна мова з використанням професійних термінів і абревіатур.",
        "tr": "Bu, profesyonel ve teknik kelime hazinesiyle konuşma dilidir.",
        "zh": "这是口语，使用专业和技术词汇。",
        "ja": "これは専門的・技術的な語彙を使った話し言葉です。",
        "ko": "이것은 전문적이고 기술적인 어휘가 포함된 구어체입니다。",
        "ar": "هذا هو اللغة المنطوقة مع المفردات المهنية والتقنية.",
    ]

    /// Normalised set of language-hint phrases, for filtering during term parsing
    /// (`_LANG_HINT_LOWER`). Python: `canonical_term_key(v.rstrip(". "))`.
    static let langHintLower: Set<String> = Set(
        langPrompts.values.map { value in
            var stripped = Substring(value)
            while let last = stripped.last, last == "." || last == " " { stripped = stripped.dropLast() }
            return TermCanonicalizer.canonicalKey(String(stripped))
        }
    )
}

/// Term-list helpers operating on the dynamic JSON representation. A term entry
/// is either a `.string` (legacy) or a `.object` with `term`/`source`/
/// `use_count`/`last_seen`/`inactive` (v5).
enum TermJSON {
    /// `_term_str`.
    static func termString(_ item: JSONValue) -> String {
        switch item {
        case let .string(s): return s
        case let .object(o): return o["term"]?.stringValue ?? ""
        default: return ""
        }
    }

    /// `_term_is_active`.
    static func isActive(_ item: JSONValue) -> Bool {
        if case let .object(o) = item, o["inactive"]?.isTruthy == true { return false }
        return true
    }

    /// `_term_sort_key`: manual(0) < correction(1) < auto(2); use_count desc; last_seen desc.
    static func sortKey(_ item: JSONValue) -> (Int, Int, String) {
        guard case let .object(o) = item else { return (0, 0, "") }
        let srcOrder: Int
        switch o["source"]?.stringValue ?? "manual" {
        case "manual": srcOrder = 0
        case "correction": srcOrder = 1
        case "auto": srcOrder = 2
        default: srcOrder = 3
        }
        let useCount = -(Int(o["use_count"]?.intValue ?? 0))
        let lastSeen = o["last_seen"]?.stringValue ?? ""
        return (srcOrder, useCount, lastSeen)
    }

    /// `deduplicate_prompt_terms`: case-insensitive dedupe, first occurrence wins.
    static func deduplicate(_ terms: [JSONValue]) -> [JSONValue] {
        var seen = Set<String>()
        var result: [JSONValue] = []
        for item in terms {
            let key = TermCanonicalizer.canonicalKey(termString(item))
            if !key.isEmpty && !seen.contains(key) {
                seen.insert(key)
                result.append(item)
            }
        }
        return result
    }

    /// Stable sort by `sortKey` (Python `sorted` is stable).
    static func sorted(_ terms: [JSONValue]) -> [JSONValue] {
        terms.enumerated().sorted { lhs, rhs in
            let a = sortKey(lhs.element)
            let b = sortKey(rhs.element)
            if a != b {
                if a.0 != b.0 { return a.0 < b.0 }
                if a.1 != b.1 { return a.1 < b.1 }
                if a.2 != b.2 { return a.2 < b.2 }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

/// Splits a comma/newline-separated string into terms (`parse_prompt_terms`).
public enum PromptTerms {
    public static func parse(_ text: String) -> [String] {
        var result: [String] = []
        var seenLower = Set<String>()
        let parts = text.split(whereSeparator: { $0 == "," || $0 == "\n" })
        for part in parts {
            let t = TermCanonicalizer.canonicalize(String(part))
            if t.isEmpty { continue }
            let key = TermCanonicalizer.canonicalKey(t)
            if LanguageConstants.langHintLower.contains(key) { continue }
            if !seenLower.contains(key) {
                seenLower.insert(key)
                result.append(t)
            }
        }
        return result
    }
}

/// Builds the effective Whisper `initial_prompt` from config (`build_initial_prompt`).
public struct InitialPromptBuilder {
    private let tokenCounter: TokenCounting
    private let maxPromptTokens = 200

    public init(tokenCounter: TokenCounting = HeuristicTokenCounter()) {
        self.tokenCounter = tokenCounter
    }

    public func build(config: JSONObject) -> String {
        if config["language_auto_detect"]?.isTruthy == true { return "" }

        let primary = Config.primaryLanguage(config)
        let additional = (config["additional_languages"]?.arrayValue ?? []).compactMap(\.stringValue)

        let allLangs = [primary] + additional.filter { $0 != primary }
        let langHint = allLangs.compactMap { LanguageConstants.langPrompts[$0] }.joined(separator: " ")

        let userTerms = config["user_terms"]?.objectValue ?? JSONObject()

        var raw = (userTerms[primary]?.arrayValue ?? []).filter { TermJSON.isActive($0) }
        for lang in additional where lang != primary {
            raw.append(contentsOf: (userTerms[lang]?.arrayValue ?? []).filter { TermJSON.isActive($0) })
        }
        raw = TermJSON.sorted(raw)
        let terms = TermJSON.deduplicate(raw).map { TermJSON.termString($0) }

        let primaryHasTerms = (userTerms[primary]?.arrayValue ?? []).contains { TermJSON.isActive($0) }

        if terms.isEmpty {
            if let ctx = LanguageConstants.langDefaultContext[primary] {
                return "\(langHint) \(ctx)".trimmingCharacters(in: .whitespaces)
            }
            return langHint.trimmingCharacters(in: .whitespaces)
        }

        let prefix: String
        if !primaryHasTerms, let ctx = LanguageConstants.langDefaultContext[primary] {
            prefix = "\(langHint) \(ctx) "
        } else {
            prefix = "\(langHint) "
        }

        let prefixTokens = tokenCounter.countTokens(prefix)
        let budget = maxPromptTokens - prefixTokens
        var accepted: [String] = []
        var usedTokens = 0
        for term in terms {
            if term.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let fragment = (accepted.isEmpty ? "" : ", ") + term
            let cost = tokenCounter.countTokens(fragment)
            if usedTokens + cost > budget { break }
            accepted.append(term)
            usedTokens += cost
        }

        let result: String
        if !accepted.isEmpty {
            result = (prefix + accepted.joined(separator: ", ")).trimmingCharacters(in: .whitespaces)
        } else if let ctx = LanguageConstants.langDefaultContext[primary] {
            result = "\(langHint) \(ctx)".trimmingCharacters(in: .whitespaces)
        } else {
            result = langHint
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
