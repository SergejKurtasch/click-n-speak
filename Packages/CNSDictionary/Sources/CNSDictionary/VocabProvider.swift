import CNSCore
import Foundation

public enum VocabProvider {

    public static let knownTermsCap = 50
    public static let misrecognitionsCap = 30
    public static let misrecognitionsMinCount = 3
    public static let replacementApplyCap = 500

    public static func getLanguageScript(_ langCode: String) -> String {
        let cyrillicLangs: Set<String> = ["ru", "uk", "ua", "be", "bg", "mk", "sr"]
        return cyrillicLangs.contains(LanguageCode.normalize(langCode)) ? "cyrillic" : "latin"
    }

    public static func existingTermsUnionForScript(
        _ existing: [String: Set<String>],
        script: String
    ) -> Set<String> {
        var result = Set<String>()
        for (language, terms) in existing where getLanguageScript(language) == script {
            result.formUnion(terms.map(TermCanonicalizer.canonicalKey))
        }
        return result
    }

    public static func skippedPhrasesMergeForScript(
        _ skipped: [String: [String: Int]],
        script: String
    ) -> [String: Int] {
        var result: [String: Int] = [:]
        for (language, terms) in skipped where getLanguageScript(language) == script {
            for (term, count) in terms {
                let key = TermCanonicalizer.canonicalKey(term)
                guard !key.isEmpty else { continue }
                result[key] = max(result[key] ?? -1, count)
            }
        }
        return result
    }

    private static func sanitizeTerm(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let components = cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return TermCanonicalizer.canonicalize(components.joined(separator: " "))
    }

    public static func normalizeReplacementSide(_ text: String) -> String {
        return sanitizeTerm(text)
    }

    public static func addTermToUserTerms(config: inout JSONValue, lang: String, term: String, source: String = "manual") -> Bool {
        let normalizedLang = lang.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTerm = sanitizeTerm(term)

        if normalizedLang.isEmpty || normalizedTerm.isEmpty {
            return false
        }

        var userTerms = config.objectValue?["user_terms"]?.objectValue ?? JSONObject()
        var currentItems = userTerms[normalizedLang]?.arrayValue ?? []

        var existingLower = Set<String>()
        for item in currentItems {
            if let obj = item.objectValue, let t = obj["term"]?.stringValue {
                let termStr = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !termStr.isEmpty {
                    existingLower.insert(TermCanonicalizer.canonicalKey(termStr))
                }
            } else if let s = item.stringValue {
                let termStr = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !termStr.isEmpty {
                    existingLower.insert(TermCanonicalizer.canonicalKey(termStr))
                }
            }
        }

        if existingLower.contains(TermCanonicalizer.canonicalKey(normalizedTerm)) {
            return false
        }

        let schemaVersion = config.objectValue?["schema_version"]?.intValue ?? 1
        if schemaVersion >= 5 {
            let nowIso = ISO8601DateFormatter().string(from: Date())
            let safeSource = ["manual", "auto", "correction"].contains(source) ? source : "manual"
            var newItem = JSONObject()
            newItem["term"] = .string(normalizedTerm)
            newItem["source"] = .string(safeSource)
            newItem["added_at"] = .string(nowIso)
            newItem["last_seen"] = .string(nowIso)
            newItem["use_count"] = .int(0)
            currentItems.append(.object(newItem))
        } else {
            currentItems.append(.string(normalizedTerm))
        }

        userTerms[normalizedLang] = .array(currentItems)

        if var configObj = config.objectValue {
            configObj["user_terms"] = .object(userTerms)
            config = .object(configObj)
        }
        return true
    }

    private static func termPriority(_ item: JSONValue) -> (Int, Int) {
        if case .string(_) = item { return (0, 0) }
        guard let obj = item.objectValue else { return (0, 0) }

        let src = obj["source"]?.stringValue ?? "manual"
        let sourceRank: Int
        switch src {
        case "manual": sourceRank = 0
        case "correction": sourceRank = 1
        case "auto": sourceRank = 2
        default: sourceRank = 3
        }
        let useCount = Int(obj["use_count"]?.intValue ?? 0)
        return (sourceRank, -useCount)
    }

    private static func termIsActive(_ item: JSONValue) -> Bool {
        if let obj = item.objectValue {
            return !(obj["inactive"]?.boolValue ?? false)
        }
        return true
    }

    private static func termStr(_ item: JSONValue) -> String {
        if let obj = item.objectValue {
            return obj["term"]?.stringValue ?? ""
        } else if let s = item.stringValue {
            return s
        }
        return ""
    }

    public static func collectKnownTerms(config: JSONValue, languages: [String]? = nil, cap: Int = knownTermsCap) -> [String] {
        let userTerms = config.objectValue?["user_terms"]?.objectValue ?? JSONObject()
        var targetLangs: [String] = []

        if let langs = languages {
            targetLangs = Array(NSOrderedSet(array: langs)) as! [String]
        } else {
            let primary = config.objectValue?["primary_language"]?.stringValue ?? "ru"
            targetLangs.append(primary)
            if let arr = config.objectValue?["additional_languages"]?.arrayValue {
                for v in arr {
                    if let l = v.stringValue, l != primary {
                        targetLangs.append(l)
                    }
                }
            }
        }

        var orderedItems: [JSONValue] = []
        for lang in targetLangs {
            let items = userTerms[lang]?.arrayValue ?? []
            for item in items {
                if termIsActive(item) {
                    orderedItems.append(item)
                }
            }
        }

        orderedItems.sort { (a, b) in
            let pa = termPriority(a)
            let pb = termPriority(b)
            if pa.0 != pb.0 { return pa.0 < pb.0 }
            return pa.1 < pb.1
        }

        var seen = Set<String>()
        var result: [String] = []
        for item in orderedItems {
            let sanitized = sanitizeTerm(termStr(item))
            if sanitized.isEmpty { continue }
            let lower = TermCanonicalizer.canonicalKey(sanitized)
            if seen.contains(lower) { continue }
            seen.insert(lower)
            result.append(sanitized)
            if result.count >= cap { break }
        }
        return result
    }

    public static func manualReplacementTuples(config: JSONValue?) -> [(String, String)] {
        guard let config = config?.objectValue else { return [] }
        var out: [(String, String)] = []
        var seen = Set<String>()

        let arr = config["manual_replacements"]?.arrayValue ?? []
        for item in arr {
            guard let obj = item.objectValue else { continue }
            let left = sanitizeTerm(obj["from"]?.stringValue ?? "")
            let right = sanitizeTerm(obj["to"]?.stringValue ?? "")
            if left.isEmpty || right.isEmpty { continue }
            let key = "\(TermCanonicalizer.canonicalKey(left))||\(TermCanonicalizer.canonicalKey(right))"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append((left, right))
        }
        return out
    }

    private static func loadCorrectionsIndex(at path: URL?) -> CorrectionIndex? {
        guard let path else { return nil }
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(CorrectionIndex.self, from: data)
    }

    public static func collectMisrecognitions(
        config: JSONValue? = nil,
        languages: [String]? = nil,
        cap: Int = misrecognitionsCap,
        minCount: Int = misrecognitionsMinCount,
        correctionsURL: URL? = nil
    ) -> [(String, String)] {
        let manual = manualReplacementTuples(config: config)
        if manual.count >= cap { return Array(manual.prefix(cap)) }

        var scripts = Set(["latin", "cyrillic"])
        if let langs = languages {
            scripts = Set(langs.map { getLanguageScript($0) })
        }

        let index = loadCorrectionsIndex(at: correctionsURL)
        let autoPairs = index?.replacementPairs ?? [:]

        var seen = Set<String>()
        for (a, b) in manual {
            seen.insert("\(TermCanonicalizer.canonicalKey(a))||\(TermCanonicalizer.canonicalKey(b))")
        }

        var result = manual
        var allAuto: [ReplacementPair] = []
        for script in scripts {
            if script != "latin" && script != "cyrillic" { continue }
            if let pairs = autoPairs[script] {
                allAuto.append(contentsOf: pairs)
            }
        }
        allAuto.sort { $0.count > $1.count }

        for item in allAuto {
            if item.count < minCount { continue }
            let left = sanitizeTerm(item.from)
            let right = sanitizeTerm(item.to)
            if left.isEmpty || right.isEmpty { continue }
            let ck = "\(TermCanonicalizer.canonicalKey(left))||\(TermCanonicalizer.canonicalKey(right))"
            if seen.contains(ck) { continue }
            seen.insert(ck)
            result.append((left, right))
            if result.count >= cap { break }
        }
        return result
    }

    private static func compileReplacementPattern(_ fromPhrase: String) -> NSRegularExpression? {
        let parts = fromPhrase.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if parts.isEmpty { return nil }
        let inner = parts.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\s+")
        let patternStr = "(?<!\\w)(\(inner))(?!\\w)"
        return try? NSRegularExpression(pattern: patternStr, options: [.caseInsensitive])
    }

    public static func applyReplacements(_ text: String, pairs: [(String, String)]) -> String {
        if text.isEmpty || pairs.isEmpty { return text }

        var matches: [(Int, Int, Int, String)] = []
        for (priority, pair) in pairs.enumerated() {
            let fromPhrase = pair.0
            let toPhrase = pair.1
            guard let pattern = compileReplacementPattern(fromPhrase) else { continue }

            let nsString = text as NSString
            let range = NSRange(location: 0, length: nsString.length)
            let results = pattern.matches(in: text, options: [], range: range)

            for match in results {
                matches.append((match.range.location, match.range.location + match.range.length, priority, toPhrase))
            }
        }
        if matches.isEmpty { return text }

        matches.sort { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if (a.1 - a.0) != (b.1 - b.0) { return (a.1 - a.0) > (b.1 - b.0) } // Longest match wins
            return a.2 < b.2 // Priority
        }

        var out = ""
        var pos = 0
        let nsString = text as NSString

        for match in matches {
            let start = match.0
            let end = match.1
            let toPhrase = match.3

            if start < pos { continue }
            out += nsString.substring(with: NSRange(location: pos, length: start - pos))
            out += toPhrase
            pos = end
        }
        out += nsString.substring(with: NSRange(location: pos, length: nsString.length - pos))
        return out
    }

    public static func collectReplacementPairsForApply(
        config: JSONValue?,
        languages: [String]? = nil,
        cap: Int = replacementApplyCap,
        minCount: Int = misrecognitionsMinCount,
        correctionsURL: URL? = nil
    ) -> [(String, String)] {
        var merged = collectMisrecognitions(
            config: config,
            languages: languages,
            cap: cap,
            minCount: minCount,
            correctionsURL: correctionsURL
        )
        merged.sort { a, b in
            let aKey = TermCanonicalizer.canonicalKey(a.0)
            let bKey = TermCanonicalizer.canonicalKey(b.0)
            if a.0.count != b.0.count { return a.0.count > b.0.count }
            return aKey.count > bKey.count
        }
        return merged
    }
}
