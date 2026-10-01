import Foundation

/// Lightweight i18n engine ported from `i18n.py`. Loads `locales/{lang}.json`,
/// falls back to English then to the key itself, and applies Slavic plural rules
/// for RU/UK. Values are either strings (for `t`) or arrays (for `plural`).
public struct I18n: Sendable {
    public static let supportedLangs: Set<String> = ["ru", "en", "uk", "de", "es", "fr"]
    private static let slavic: Set<String> = ["ru", "uk"]

    public let lang: String
    private let strings: JSONObject
    private let fallback: JSONObject

    private init(lang: String, strings: JSONObject, fallback: JSONObject) {
        self.lang = lang
        self.strings = strings
        self.fallback = fallback
    }

    /// Load the locale for `lang` from `localesDirectory`. Unknown codes fall
    /// back to English, matching `i18n.load`.
    public static func load(_ lang: String, localesDirectory: URL) -> I18n {
        var code = (lang).lowercased().trimmingCharacters(in: .whitespaces)
        if !supportedLangs.contains(code) { code = "en" }
        let strings = loadFile(code, in: localesDirectory)
        let fallback = code == "en" ? JSONObject() : loadFile("en", in: localesDirectory)
        return I18n(lang: code, strings: strings, fallback: fallback)
    }

    private static func loadFile(_ lang: String, in dir: URL) -> JSONObject {
        let url = dir.appendingPathComponent("\(lang).json")
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONValue.parse(data: data),
              case let .object(obj) = value else {
            return JSONObject()
        }
        return obj
    }

    /// Translated string for `key`, formatted with `args` (`{name}` placeholders).
    /// Falls back to English, then to the key itself; never fails (`i18n.t`).
    public func t(_ key: String, _ args: [String: String] = [:]) -> String {
        let raw: String
        if let s = strings[key]?.stringValue, !s.isEmpty {
            raw = s
        } else if let s = fallback[key]?.stringValue, !s.isEmpty {
            raw = s
        } else {
            return key
        }
        if args.isEmpty { return raw }
        return Self.format(raw, args)
    }

    /// Correct plural form from an array stored at `key` (`i18n.plural`).
    public func plural(_ key: String, _ n: Int) -> String {
        let forms = strings[key]?.arrayValue ?? fallback[key]?.arrayValue
        guard let forms, !forms.isEmpty else { return String(n) }
        let idx = pluralIndex(n)
        let clamped = min(idx, forms.count - 1)
        return forms[clamped].stringValue ?? String(n)
    }

    /// `_plural_idx`: 0=one, 1=few, 2=many for Slavic; 0=one, 1=other otherwise.
    func pluralIndex(_ n: Int) -> Int {
        if Self.slavic.contains(lang) {
            if n % 10 == 1 && n % 100 != 11 { return 0 }
            if (2...4).contains(n % 10) && (n % 100 < 10 || n % 100 >= 20) { return 1 }
            return 2
        }
        return n == 1 ? 0 : 1
    }

    /// Replace `{name}` placeholders. Mirrors Python `str.format(**kwargs)` for
    /// the simple named-field case the locale files use; on a missing key the
    /// original string is returned unchanged (Python falls back to `raw`).
    static func format(_ template: String, _ args: [String: String]) -> String {
        var result = template
        for (key, value) in args {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }
}
