import CNSCore
import Foundation

public enum LogAnalyzer {

    public static let termStoplist: Set<String> = TermStoplist.words

    public static let rusFunctionWords: Set<String> = [
        // Personal pronouns
        "я", "мне", "меня", "мной", "мною",
        "ты", "тебя", "тебе", "тобой", "тобою",
        "он", "ему", "его", "него", "ним", "нём",
        "она", "ей", "её", "неё", "ею", "нею",
        "оно",
        "мы", "нас", "нам", "нами",
        "вы", "вас", "вам", "вами",
        "они", "их", "им", "ими", "них", "ними",
        "себя", "себе", "собой", "собою",
        // Demonstratives
        "это", "этот", "эта", "эти", "этих", "этому", "этим", "этими", "этой", "этого",
        "тот", "та", "то", "те", "тех", "тому", "тем", "теми", "той", "того",
        "там", "тут", "туда", "сюда", "здесь",
        // Relative
        "который", "которая", "которое", "которые",
        "которого", "которой", "которых", "которому", "которым", "которыми",
        "кто", "что", "кого", "чего", "кому", "чему", "кем", "чем",
        "где", "куда", "откуда", "когда", "зачем", "почему",
        // Copula
        "есть", "нет", "был", "была", "было", "были", "быть",
        "будет", "будут", "буду", "будем", "будете", "будешь",
        // Modal
        "надо", "нужно", "можно", "нельзя",
        "может", "могут", "могу", "можем", "можете", "можешь",
        "должен", "должна", "должно", "должны",
        "хочет", "хочу", "хотим", "хотите", "хочешь", "хотят",
        "хотел", "хотела", "хотели",
        // Conjunctions
        "и", "а", "но", "или", "ни", "либо",
        "чтобы", "если", "хотя", "потому", "поэтому",
        "однако", "зато", "причём", "притом",
        "да", "как", "так", "вот", "ну", "ли", "же", "бы",
        "даже", "именно", "ведь", "лишь", "всё",
        // Adverbs
        "очень", "просто", "только", "уже", "ещё", "еще", "тоже", "почти",
        "всегда", "никогда", "иногда", "сейчас", "теперь", "потом", "тогда",
        "сначала", "наконец", "сразу", "вдруг", "опять", "снова",
        // Prepositions
        "для", "при", "про", "без", "над", "под", "перед", "после", "через",
        "между", "около", "вместо", "кроме", "против", "вдоль", "среди",
        "из", "от", "до", "по", "за", "на", "в", "к", "со", "об",
        // Language
        "язык", "языке", "языка", "языком", "языки", "языков",
        "русский", "русского", "русскому", "русском",
        "английский", "английском", "английского", "английскому",
        // Verbs
        "сделал", "сделала", "сделали", "делает", "делал", "делала",
        "говорит", "говорят", "говорил", "говорила", "говорили",
        "сказал", "сказала", "сказали", "идёт", "идет", "стал", "стала", "стали"
    ]

    private static let sessionGapSeconds: TimeInterval = 60

    private static func whisperTokenCount(_ word: String) -> Int {
        // No Python tokenizer available, fallback is 3 to pass the `< 3` bigram filter
        return 3
    }

    private static func enWhisperBonus(_ term: String) -> Double {
        let n = whisperTokenCount(term)
        if n >= 4 { return 4.0 }
        if n >= 3 { return 2.5 }
        if n >= 2 { return 1.5 }
        return 1.0
    }

    private static func ruWhisperBonus(_ phrase: String) -> Double {
        let words = phrase.components(separatedBy: .whitespaces)
        let maxN = words.map { whisperTokenCount($0) }.max() ?? 1
        if maxN >= 4 { return 4.0 }
        if maxN >= 3 { return 2.5 }
        if maxN >= 2 { return 1.5 }
        return 1.0
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        if abs(a.count - b.count) > 2 { return 3 }
        let aArr = Array(a)
        let bArr = Array(b)

        let la = aArr.count
        let lb = bArr.count
        if la == 0 { return lb }
        if lb == 0 { return la }

        var row = Array(0...lb)
        for i in 1...la {
            var newRow = [i]
            for j in 1...lb {
                let cost = aArr[i - 1] == bArr[j - 1] ? 0 : 1
                newRow.append(Swift.min(row[j] + 1, newRow[j - 1] + 1, row[j - 1] + cost))
            }
            row = newRow
        }
        return row[lb]
    }

    private static func parseHistoryLines(_ lines: [String]) -> [(Date, String)] {
        var records: [(Date, String)] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        for line in lines {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count != 2 { continue }
            if let ts = formatter.date(from: String(parts[0])) {
                records.append((ts, String(parts[1])))
            }
        }
        return records
    }

    private static func assignSessionIds(_ records: [(Date, String)]) -> [Int] {
        if records.isEmpty { return [] }
        var ids = [0]
        var sid = 0
        for i in 1..<records.count {
            let gap = records[i].0.timeIntervalSince(records[i - 1].0)
            if gap >= sessionGapSeconds {
                sid += 1
            }
            ids.append(sid)
        }
        return ids
    }

    private static func collectEnglishTerms(
        records: [(Date, String)],
        sessionIds: [Int],
        blacklist: Set<String> = [],
        hasCorrectionSignal: ((String) -> Bool)? = nil
    ) -> [(String, Int)] {
        var variantCounts: [String: Int] = [:]
        var termSessions: [String: Set<Int>] = [:]

        for (i, record) in records.enumerated() {
            let text = record.1
            let sid = sessionIds[i]
            var seenLowerInRecord = Set<String>()

            let termRe = /[A-Za-z][A-Za-z0-9+#._-]+/
            let matches = text.matches(of: termRe)

            for match in matches {
                let rawTerm = String(text[match.range])
                let term = TermCanonicalizer.canonicalize(rawTerm)
                if term.isEmpty { continue }
                let lower = TermCanonicalizer.canonicalKey(term)

                if termStoplist.contains(lower) || blacklist.contains(lower) { continue }
                if term.filter({ $0 == "/" }).count > 1 || term.filter({ $0 == "." }).count > 1 { continue }
                if term.count < 3 && term.allSatisfy({ $0.isLetter }) { continue }
                if whisperTokenCount(term) == 1 { continue }

                variantCounts[term, default: 0] += 1
                if !seenLowerInRecord.contains(lower) {
                    termSessions[lower, default: []].insert(sid)
                    seenLowerInRecord.insert(lower)
                }
            }
        }

        var lowerToVariants: [String: [String]] = [:]
        for variant in variantCounts.keys {
            lowerToVariants[variant.lowercased(), default: []].append(variant)
        }

        var candidates: [(String, Int)] = []
        for (lower, variants) in lowerToVariants {
            let hasCorrection = hasCorrectionSignal?(lower) ?? false
            if !hasCorrection && (termSessions[lower]?.count ?? 0) < 2 { continue }

            let best = variants.max { variantCounts[$0]! < variantCounts[$1]! }!
            let total = variants.reduce(0) { $0 + variantCounts[$1]! }
            candidates.append((best, total))
        }

        candidates.sort { Double($0.1) * enWhisperBonus($0.0) > Double($1.1) * enWhisperBonus($1.0) }
        return candidates
    }

    private static func filterNearDuplicates(_ candidates: [(String, Int)]) -> [(String, Int)] {
        var removed = Set<Int>()
        for i in 0..<candidates.count {
            if removed.contains(i) { continue }
            let termI = candidates[i].0.lowercased()
            let lenI = termI.count

            for j in (i + 1)..<candidates.count {
                if removed.contains(j) { continue }
                let termJ = candidates[j].0.lowercased()
                if abs(lenI - termJ.count) > 2 { continue }
                if levenshtein(termI, termJ) <= 1 {
                    removed.insert(j)
                }
            }
        }
        var result: [(String, Int)] = []
        for (idx, c) in candidates.enumerated() {
            if !removed.contains(idx) { result.append(c) }
        }
        return result
    }

    private static func collectRussianBigrams(_ texts: [String]) -> [String: Int] {
        let total = texts.count
        var wordPhraseCount: [String: Int] = [:]

        let rusWordRe = /[А-Яа-яЁё]+/
        for text in texts {
            let lowerText = text.lowercased()
            let matches = lowerText.matches(of: rusWordRe)
            var seen = Set<String>()
            for match in matches {
                let w = String(lowerText[match.range])
                if w.count >= 3 { seen.insert(w) }
            }
            for w in seen { wordPhraseCount[w, default: 0] += 1 }
        }
        let maxWordPhrases = max(10, Int(Double(total) * 0.20))

        var counter: [String: Int] = [:]
        for text in texts {
            let matches = text.matches(of: rusWordRe)
            var words: [String] = []
            for match in matches {
                let w = String(text[match.range]).lowercased()
                if w.count >= 3 { words.append(w) }
            }
            if words.count > 1 {
                for i in 0..<(words.count - 1) {
                    let w1 = words[i]
                    let w2 = words[i + 1]
                    if w1 == w2 { continue }
                    if rusFunctionWords.contains(w1) || rusFunctionWords.contains(w2) { continue }
                    if max(whisperTokenCount(w1), whisperTokenCount(w2)) < 3 { continue }
                    if wordPhraseCount[w1, default: 0] > maxWordPhrases || wordPhraseCount[w2, default: 0] > maxWordPhrases { continue }
                    counter["\(w1) \(w2)", default: 0] += 1
                }
            }
        }

        var toRemove = Set<String>()
        for (bigram, count) in counter {
            let parts = bigram.components(separatedBy: " ")
            let reverse = "\(parts[1]) \(parts[0])"
            let revCount = counter[reverse, default: 0]
            if revCount > 0 {
                let ratio = Double(min(count, revCount)) / Double(max(count, revCount))
                if ratio >= 0.4 {
                    toRemove.insert(bigram)
                    toRemove.insert(reverse)
                }
            }
        }
        for b in toRemove { counter.removeValue(forKey: b) }
        return counter
    }

    public static func getPromptCandidates(
        phraseHistory: any PhraseHistoryProviding,
        lookback: Int = 300,
        minCount: [String: Int] = ["latin": 5, "cyrillic": 8],
        existingLowerByLang: [String: Set<String>] = [:],
        skippedLowerByLang: [String: [String: Int]] = [:],
        currentPhraseCount: Int = 0,
        cooldownPhrases: Int = 150,
        maxPerLang: Int = 15,
        hasCorrectionSignal: ((String) -> Bool)? = nil
    ) -> [String: [TermCandidate]] {

        let latinMin = minCount["latin"] ?? 5
        let cyrillicMin = minCount["cyrillic"] ?? 8

        let lastLines = phraseHistory.lastPhrases(lookback)
        // convert to string array mimicking TSV lines
        let rawLines = lastLines.map { "\($0.timestamp)\t\($0.text)" }
        let records = parseHistoryLines(rawLines)
        if records.isEmpty { return [:] }

        let texts = records.map { $0.1 }
        let sessionIds = assignSessionIds(records)
        var latinRaw = collectEnglishTerms(records: records, sessionIds: sessionIds, blacklist: [], hasCorrectionSignal: hasCorrectionSignal)
        latinRaw = filterNearDuplicates(latinRaw)

        let existingLatin = VocabProvider.existingTermsUnionForScript(
            existingLowerByLang,
            script: "latin"
        )
        let skippedLatin = VocabProvider.skippedPhrasesMergeForScript(
            skippedLowerByLang,
            script: "latin"
        )

        var latinCandidates: [TermCandidate] = []
        for (term, count) in latinRaw {
            if count < latinMin { continue }
            let lower = TermCanonicalizer.canonicalKey(term)
            if existingLatin.contains(lower) { continue }
            let skippedAt = skippedLatin[lower] ?? -1
            if skippedAt >= 0 && (currentPhraseCount - skippedAt) < cooldownPhrases { continue }

            latinCandidates.append(TermCandidate(term: term, count: count, correctionCount: 0, frequencyCount: count, source: "auto"))
            if latinCandidates.count >= maxPerLang { break }
        }

        let cyrillicCounts = collectRussianBigrams(texts)
        let existingCyrillic = VocabProvider.existingTermsUnionForScript(
            existingLowerByLang,
            script: "cyrillic"
        )
        let skippedCyrillic = VocabProvider.skippedPhrasesMergeForScript(
            skippedLowerByLang,
            script: "cyrillic"
        )

        var cyrillicCandidates: [TermCandidate] = []
        let sortedCyrillic = cyrillicCounts.sorted {
            Double($0.value) * ruWhisperBonus($0.key) > Double($1.value) * ruWhisperBonus($1.key)
        }

        for (phrase, count) in sortedCyrillic {
            if count < cyrillicMin { continue }
            let lower = TermCanonicalizer.canonicalKey(phrase)
            if existingCyrillic.contains(lower) { continue }
            let skippedAt = skippedCyrillic[lower] ?? -1
            if skippedAt >= 0 && (currentPhraseCount - skippedAt) < cooldownPhrases { continue }

            cyrillicCandidates.append(TermCandidate(term: phrase, count: count, correctionCount: 0, frequencyCount: count, source: "auto"))
            if cyrillicCandidates.count >= maxPerLang { break }
        }

        var result: [String: [TermCandidate]] = [:]
        if !latinCandidates.isEmpty { result["latin"] = latinCandidates }
        if !cyrillicCandidates.isEmpty { result["cyrillic"] = cyrillicCandidates }
        return result
    }

    public static func getFrequentTerms(
        phraseHistory: any PhraseHistoryProviding,
        maxEnTerms: Int = 20,
        maxRuPhrases: Int = 5,
        lookback: Int = 1000,
        blacklist: Set<String> = []
    ) -> (enTerms: [String], ruBigrams: [String]) {
        let lastLines = phraseHistory.lastPhrases(lookback)
        let rawLines = lastLines.map { "\($0.timestamp)\t\($0.text)" }
        let records = parseHistoryLines(rawLines)
        if records.isEmpty { return ([], []) }

        let sessionIds = assignSessionIds(records)
        let texts = records.map { $0.1 }

        var candidates = collectEnglishTerms(records: records, sessionIds: sessionIds, blacklist: blacklist)
        candidates = filterNearDuplicates(candidates)
        let topEn = candidates.prefix(maxEnTerms).map { $0.0 }

        let ruCounts = collectRussianBigrams(texts)
        let sortedRu = ruCounts.sorted {
            Double($0.value) * ruWhisperBonus($0.key) > Double($1.value) * ruWhisperBonus($1.key)
        }
        let topRu = sortedRu.filter { $0.value >= 3 }.prefix(maxRuPhrases).map { $0.key }

        return (Array(topEn), Array(topRu))
    }
}
