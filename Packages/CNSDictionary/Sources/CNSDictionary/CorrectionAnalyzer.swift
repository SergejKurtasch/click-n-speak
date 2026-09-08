import CNSCore
import Foundation

// MARK: - Models

public struct InsertedTerm: Codable, Sendable, Equatable {
    public var term: String
    public var count: Int
    public var weightedCount: Double
    public var firstSeen: String
    public var lastSeen: String
    public var lastSeenRow: Int

    private enum CodingKeys: String, CodingKey {
        case term
        case count
        case weightedCount = "weighted_count"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case lastSeenRow = "last_seen_row"
    }

    public init(
        term: String,
        count: Int,
        weightedCount: Double,
        firstSeen: String,
        lastSeen: String,
        lastSeenRow: Int
    ) {
        self.term = term
        self.count = count
        self.weightedCount = weightedCount
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.lastSeenRow = lastSeenRow
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        term = try values.decode(String.self, forKey: .term)
        count = try values.decodeIfPresent(Int.self, forKey: .count) ?? 0
        weightedCount = try values.decodeIfPresent(Double.self, forKey: .weightedCount) ?? Double(count)
        firstSeen = try values.decodeIfPresent(String.self, forKey: .firstSeen) ?? ""
        lastSeen = try values.decodeIfPresent(String.self, forKey: .lastSeen) ?? firstSeen
        lastSeenRow = try values.decodeIfPresent(Int.self, forKey: .lastSeenRow) ?? 0
    }
}

public struct ReplacementPair: Codable, Sendable, Equatable {
    public var from: String
    public var to: String
    public var count: Int
    public var lastSeen: String
    public var lastSeenRow: Int

    private enum CodingKeys: String, CodingKey {
        case from, to, count
        case lastSeen = "last_seen"
        case lastSeenRow = "last_seen_row"
    }

    public init(from: String, to: String, count: Int, lastSeen: String, lastSeenRow: Int = 0) {
        self.from = from
        self.to = to
        self.count = count
        self.lastSeen = lastSeen
        self.lastSeenRow = lastSeenRow
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        from = try values.decode(String.self, forKey: .from)
        to = try values.decode(String.self, forKey: .to)
        count = try values.decodeIfPresent(Int.self, forKey: .count) ?? 0
        lastSeen = try values.decodeIfPresent(String.self, forKey: .lastSeen) ?? ""
        lastSeenRow = try values.decodeIfPresent(Int.self, forKey: .lastSeenRow) ?? 0
    }
}

public struct CorrectionIndex: Codable, Sendable {
    public var schemaVersion: Int
    public var lastProcessedTs: String?
    public var lastProcessedOffset: UInt64?
    public var processedRows: Int
    public var insertedTerms: [String: [String: InsertedTerm]]
    public var replacementPairs: [String: [ReplacementPair]]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case lastProcessedTs = "last_processed_ts"
        case lastProcessedOffset = "last_processed_offset"
        case processedRows = "processed_rows"
        case insertedTerms = "inserted_terms"
        case replacementPairs = "replacement_pairs"
    }

    public static func defaultIndex() -> CorrectionIndex {
        CorrectionIndex(
            schemaVersion: 5,
            lastProcessedTs: nil,
            lastProcessedOffset: nil,
            processedRows: 0,
            insertedTerms: ["latin": [:], "cyrillic": [:]],
            replacementPairs: ["latin": [], "cyrillic": []]
        )
    }
}

public enum CorrectionIndexReadError: LocalizedError, Sendable, Equatable {
    case rebuildRequired(schemaVersion: Int)

    public var errorDescription: String? {
        switch self {
        case let .rebuildRequired(schemaVersion):
            "Correction index schema \(schemaVersion) must be rebuilt from the dataset"
        }
    }
}

// MARK: - Diff Opcodes
enum Opcode {
    case equal, delete, insert, replace
}

struct OpcodeChunk {
    let type: Opcode
    let i1: Int
    let i2: Int
    let j1: Int
    let j2: Int
}

struct DiffWorkspace {
    let allocatedCells: Int
    let limited: Bool
}

func getOpcodes<T: Equatable>(
    _ source: [T], _ target: [T], reportWorkspace: (DiffWorkspace) -> Void = { _ in }
) -> [OpcodeChunk] {
    var prefix = 0
    while prefix < min(source.count, target.count), source[prefix] == target[prefix] { prefix += 1 }
    var sourceEnd = source.count
    var targetEnd = target.count
    while sourceEnd > prefix, targetEnd > prefix, source[sourceEnd - 1] == target[targetEnd - 1] {
        sourceEnd -= 1
        targetEnd -= 1
    }
    let a = Array(source[prefix..<sourceEnd])
    let b = Array(target[prefix..<targetEnd])
    let m = a.count
    let n = b.count
    func restoreIndices(_ window: [OpcodeChunk]) -> [OpcodeChunk] {
        var result: [OpcodeChunk] = []
        if prefix > 0 { result.append(OpcodeChunk(type: .equal, i1: 0, i2: prefix, j1: 0, j2: prefix)) }
        result += window.map { OpcodeChunk(type: $0.type, i1: $0.i1 + prefix, i2: $0.i2 + prefix, j1: $0.j1 + prefix, j2: $0.j2 + prefix) }
        if sourceEnd < source.count {
            result.append(OpcodeChunk(type: .equal, i1: sourceEnd, i2: source.count, j1: targetEnd, j2: target.count))
        }
        return result
    }
    if m == 0 {
        reportWorkspace(DiffWorkspace(allocatedCells: 0, limited: false))
        return restoreIndices(n == 0 ? [] : [OpcodeChunk(type: .insert, i1: 0, i2: 0, j1: 0, j2: n)])
    }
    if n == 0 {
        reportWorkspace(DiffWorkspace(allocatedCells: 0, limited: false))
        return restoreIndices([OpcodeChunk(type: .delete, i1: 0, i2: m, j1: 0, j2: 0)])
    }

    let cellCount = (m + 1).multipliedReportingOverflow(by: n + 1)
    guard !cellCount.overflow, cellCount.partialValue <= 1_000_000 else {
        reportWorkspace(DiffWorkspace(allocatedCells: 0, limited: true))
        return []
    }
    reportWorkspace(DiffWorkspace(allocatedCells: cellCount.partialValue, limited: false))
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

    for i in 0...m { dp[i][0] = i }
    for j in 0...n { dp[0][j] = j }

    for i in 1...m {
        for j in 1...n {
            if a[i - 1] == b[j - 1] {
                dp[i][j] = dp[i - 1][j - 1]
            } else {
                dp[i][j] = 1 + min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
            }
        }
    }

    var i = m
    var j = n
    var ops: [OpcodeChunk] = []

    while i > 0 || j > 0 {
        if i > 0 && j > 0 && a[i - 1] == b[j - 1] {
            ops.append(OpcodeChunk(type: .equal, i1: i - 1, i2: i, j1: j - 1, j2: j))
            i -= 1
            j -= 1
        } else if i > 0 && j > 0 && dp[i][j] == dp[i - 1][j - 1] + 1 {
            ops.append(OpcodeChunk(type: .replace, i1: i - 1, i2: i, j1: j - 1, j2: j))
            i -= 1
            j -= 1
        } else if i > 0 && dp[i][j] == dp[i - 1][j] + 1 {
            ops.append(OpcodeChunk(type: .delete, i1: i - 1, i2: i, j1: j, j2: j))
            i -= 1
        } else if j > 0 && dp[i][j] == dp[i][j - 1] + 1 {
            ops.append(OpcodeChunk(type: .insert, i1: i, i2: i, j1: j - 1, j2: j))
            j -= 1
        }
    }
    ops.reverse()

    var merged: [OpcodeChunk] = []
    for op in ops {
        if let last = merged.last, last.type == op.type {
            merged[merged.count - 1] = OpcodeChunk(type: op.type, i1: last.i1, i2: op.i2, j1: last.j1, j2: op.j2)
        } else {
            merged.append(op)
        }
    }
    return restoreIndices(merged)
}

// MARK: - Analyzer

public enum CorrectionAnalyzer {

    private static let maxPairTokenLen = 30
    private static let replacementMaxAgeSeconds: TimeInterval = 90 * 86_400
    private static let replacementMaxRowAge = 300

    private static func parseTimestamp(_ value: String) -> Date? {
        let normalized = value.replacingOccurrences(of: "Z", with: "+00:00")
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: normalized) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: normalized)
    }

    public static func isReplacementPairStale(
        _ pair: ReplacementPair,
        processedRows: Int,
        now: Date
    ) -> Bool {
        if processedRows - pair.lastSeenRow >= replacementMaxRowAge { return true }
        guard let lastSeen = parseTimestamp(pair.lastSeen) else { return true }
        return now.timeIntervalSince(lastSeen) >= replacementMaxAgeSeconds
    }

    @discardableResult
    public static func pruneStaleReplacementPairs(
        in index: inout CorrectionIndex,
        now: Date
    ) -> Int {
        var removed = 0
        for bucket in ["latin", "cyrillic"] {
            var pairs = index.replacementPairs[bucket] ?? []
            let originalCount = pairs.count
            pairs.removeAll { isReplacementPairStale($0, processedRows: index.processedRows, now: now) }
            removed += originalCount - pairs.count
            index.replacementPairs[bucket] = pairs
        }
        return removed
    }

    public static func writeIndex(_ index: CorrectionIndex, to indexPath: URL) throws {
        let data = try JSONEncoder().encode(index)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try AtomicFile.writeText(text, to: indexPath)
    }

    public static func readIndex(at path: URL) -> CorrectionIndex {
        (try? readIndexThrowing(at: path)) ?? CorrectionIndex.defaultIndex()
    }

    /// Loads a trustworthy schema-5 index. Older schemas require a full
    /// dataset rebuild because their counters or row-age metadata cannot be
    /// recovered from the index alone.
    public static func readIndexThrowing(at path: URL) throws -> CorrectionIndex {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return CorrectionIndex.defaultIndex()
        }
        let data = try Data(contentsOf: path)
        var index = try JSONDecoder().decode(CorrectionIndex.self, from: data)
        if index.schemaVersion < 2 {
            if index.insertedTerms["latin"] == nil { index.insertedTerms["latin"] = index.insertedTerms["en"] ?? [:] }
            if index.insertedTerms["cyrillic"] == nil { index.insertedTerms["cyrillic"] = index.insertedTerms["ru"] ?? [:] }
            if index.replacementPairs["latin"] == nil { index.replacementPairs["latin"] = index.replacementPairs["en"] ?? [] }
            if index.replacementPairs["cyrillic"] == nil { index.replacementPairs["cyrillic"] = index.replacementPairs["ru"] ?? [] }
            index.insertedTerms.removeValue(forKey: "en")
            index.insertedTerms.removeValue(forKey: "ru")
            index.replacementPairs.removeValue(forKey: "en")
            index.replacementPairs.removeValue(forKey: "ru")
        }
        if index.schemaVersion < 3 { cleanReplacementPairs(in: &index) }
        guard index.schemaVersion >= 5 else {
            throw CorrectionIndexReadError.rebuildRequired(schemaVersion: index.schemaVersion)
        }
        index.schemaVersion = 5
        if index.insertedTerms["latin"] == nil { index.insertedTerms["latin"] = [:] }
        if index.insertedTerms["cyrillic"] == nil { index.insertedTerms["cyrillic"] = [:] }
        if index.replacementPairs["latin"] == nil { index.replacementPairs["latin"] = [] }
        if index.replacementPairs["cyrillic"] == nil { index.replacementPairs["cyrillic"] = [] }
        return index
    }

    private static func cleanReplacementPairs(in index: inout CorrectionIndex) {
        for bucket in ["latin", "cyrillic"] {
            var merged: [String: ReplacementPair] = [:]
            for pair in index.replacementPairs[bucket] ?? [] {
                let from = TermCanonicalizer.canonicalize(pair.from)
                let to = TermCanonicalizer.canonicalize(pair.to)
                guard !from.isEmpty, !to.isEmpty,
                      TermCanonicalizer.canonicalKey(from) != TermCanonicalizer.canonicalKey(to),
                      !isHallucinationPair(from, to) else { continue }
                let key = "\(TermCanonicalizer.canonicalKey(from))||\(TermCanonicalizer.canonicalKey(to))"
                if var existing = merged[key] {
                    existing.count += pair.count
                    if pair.lastSeen > existing.lastSeen {
                        existing.lastSeen = pair.lastSeen
                        existing.lastSeenRow = pair.lastSeenRow
                    } else if pair.lastSeen == existing.lastSeen {
                        existing.lastSeenRow = max(existing.lastSeenRow, pair.lastSeenRow)
                    }
                    merged[key] = existing
                } else {
                    merged[key] = ReplacementPair(
                        from: from,
                        to: to,
                        count: pair.count,
                        lastSeen: pair.lastSeen,
                        lastSeenRow: pair.lastSeenRow
                    )
                }
            }
            index.replacementPairs[bucket] = merged.values.sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return TermCanonicalizer.canonicalKey($0.from) < TermCanonicalizer.canonicalKey($1.from)
            }
        }
    }

    private static func tokenize(_ text: String) -> [String] {
        let tokenRe = /[A-Za-zА-Яа-яЁё][A-Za-zА-Яа-яЁё0-9+#._-]*/
        return text.matches(of: tokenRe).map { String(text[$0.range]) }
    }

    private static func normCmp(_ text: String) -> String {
        let lowered = text.lowercased()
        let punctStripRe = /[^\w\s]/
        let stripped = lowered.replacing(punctStripRe, with: "")
        return stripped.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func langBucket(_ token: String) -> String? {
        let cyrillicRe = /[А-Яа-яЁё]/
        let latinRe = /[A-Za-z]/
        let hasCyr = token.contains(cyrillicRe)
        let hasLat = token.contains(latinRe)
        if hasCyr && !hasLat { return "cyrillic" }
        if hasLat && !hasCyr { return "latin" }
        return nil
    }

    private static func isHallucinationPair(_ fromStr: String, _ toStr: String) -> Bool {
        let hallucinationRepeatRe = /(.{2,4})\1{7,}/
        for s in [fromStr, toStr] {
            let tokens = s.components(separatedBy: .whitespaces)
            for t in tokens {
                if t.count > maxPairTokenLen { return true }
                if t.contains(hallucinationRepeatRe) { return true }
            }
        }
        return false
    }

    private static func isValidTerm(_ token: String) -> Bool {
        let canon = TermCanonicalizer.canonicalize(token)
        if canon.count < 2 { return false }
        let lower = TermCanonicalizer.canonicalKey(canon)
        if TermStoplist.words.contains(lower) || LogAnalyzer.rusFunctionWords.contains(lower) {
            return false
        }

        let digitsOnlyRe = /^\d+$/
        if canon.contains(digitsOnlyRe) { return false }
        if langBucket(canon) == nil { return false }

        // Python falls back to three BPE tokens when the Whisper tokenizer is
        // unavailable. CNSDictionary intentionally has no model dependency, so
        // this path uses that same include-by-default fallback.
        return true
    }

    private static func hasTechnicalShape(_ token: String) -> Bool {
        let canon = TermCanonicalizer.canonicalize(token)
        let uppercaseCount = canon.reduce(into: 0) { count, character in
            if character.isUppercase { count += 1 }
        }
        return uppercaseCount >= 2
            || canon.contains(where: \.isNumber)
            || canon.contains(where: { "+#._@".contains($0) })
    }

    private static func stableReplacementTargets(
        in index: CorrectionIndex,
        minimumCount: Int = 2
    ) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for bucket in ["latin", "cyrillic"] {
            for pair in index.replacementPairs[bucket] ?? [] where pair.count >= minimumCount {
                let targetTokens = tokenize(pair.to)
                guard targetTokens.count == 1, let target = targetTokens.first else { continue }
                result[bucket, default: []].insert(TermCanonicalizer.canonicalKey(target))
            }
        }
        return result
    }

    private static func upsertInserted(index: inout CorrectionIndex, token: String, ts: String, weight: Double) {
        let canon = TermCanonicalizer.canonicalize(token)
        guard let lang = langBucket(canon), isValidTerm(canon) else { return }

        let key = TermCanonicalizer.canonicalKey(canon)
        var existing = index.insertedTerms[lang]?[key]

        if existing == nil {
            index.insertedTerms[lang]?[key] = InsertedTerm(
                term: canon, count: 1, weightedCount: weight,
                firstSeen: ts, lastSeen: ts, lastSeenRow: index.processedRows
            )
        } else {
            existing!.count += 1
            existing!.weightedCount += weight
            existing!.lastSeen = ts
            existing!.lastSeenRow = index.processedRows
            if existing!.term.lowercased() == existing!.term && canon.contains(where: { $0.isUppercase }) {
                existing!.term = canon
            }
            index.insertedTerms[lang]?[key] = existing
        }
    }

    private static func upsertReplacementPair(index: inout CorrectionIndex, fromTokens: [String], toTokens: [String], ts: String) {
        let fromCanon = fromTokens.map { TermCanonicalizer.canonicalize($0) }.filter { !$0.isEmpty }
        let toCanon = toTokens.map { TermCanonicalizer.canonicalize($0) }.filter { !$0.isEmpty }

        guard !fromCanon.isEmpty, !toCanon.isEmpty else { return }
        guard fromCanon.count <= 4, toCanon.count <= 4 else { return }

        var toLangs = Set<String>()
        for t in toCanon {
            if let l = langBucket(t) { toLangs.insert(l) }
        }
        guard toLangs.count == 1, let lang = toLangs.first else { return }

        for t in toCanon {
            if !isValidTerm(t) { return }
        }

        let fromStr = fromCanon.joined(separator: " ")
        let toStr = toCanon.joined(separator: " ")

        if TermCanonicalizer.canonicalKey(fromStr) == TermCanonicalizer.canonicalKey(toStr) { return }
        if isHallucinationPair(fromStr, toStr) { return }

        var pairs = index.replacementPairs[lang] ?? []
        for i in 0..<pairs.count {
            if TermCanonicalizer.canonicalKey(pairs[i].from) == TermCanonicalizer.canonicalKey(fromStr) &&
               TermCanonicalizer.canonicalKey(pairs[i].to) == TermCanonicalizer.canonicalKey(toStr) {
                pairs[i].count += 1
                pairs[i].lastSeen = ts
                pairs[i].lastSeenRow = index.processedRows
                index.replacementPairs[lang] = pairs
                return
            }
        }
        pairs.append(ReplacementPair(
            from: fromStr,
            to: toStr,
            count: 1,
            lastSeen: ts,
            lastSeenRow: index.processedRows
        ))
        index.replacementPairs[lang] = pairs
    }

    private static func processDiff(
        index: inout CorrectionIndex,
        sourceText: String,
        userText: String,
        ts: String,
        countedInserted: inout Set<String>,
        countedReplacements: inout Set<String>
    ) {
        let srcTokens = tokenize(sourceText)
        let usrTokens = tokenize(userText)
        let srcLower = Set(srcTokens.map(normCmp))

        let ops = getOpcodes(srcTokens.map(normCmp), usrTokens.map(normCmp)) { workspace in
            guard workspace.limited else { return }
            RuntimeTelemetry.emitRuntimeEvent("dictionary_analysis", fields: [
                "outcome": "analysis_limit",
                "source_count": srcTokens.count,
                "target_count": usrTokens.count,
                "allocated_cells": workspace.allocatedCells,
            ])
        }

        for op in ops {
            if op.type == .equal || op.type == .delete { continue }
            let toToks = Array(usrTokens[op.j1..<op.j2])

            if op.type == .insert || op.type == .replace {
                for t in toToks {
                    let canonical = TermCanonicalizer.canonicalize(t)
                    guard let bucket = langBucket(canonical), isValidTerm(canonical) else { continue }
                    let observationKey = "\(bucket)||\(TermCanonicalizer.canonicalKey(canonical))"
                    guard countedInserted.insert(observationKey).inserted else { continue }
                    let weight = srcLower.contains(normCmp(t)) ? 0.5 : 1.0
                    upsertInserted(index: &index, token: canonical, ts: ts, weight: weight)
                }
            }
            if op.type == .replace {
                let fromTokens = Array(srcTokens[op.i1..<op.i2])
                let fromKey = TermCanonicalizer.canonicalKey(fromTokens.joined(separator: " "))
                let toKey = TermCanonicalizer.canonicalKey(toToks.joined(separator: " "))
                let observationKey = "\(fromKey)||\(toKey)"
                if countedReplacements.insert(observationKey).inserted {
                    upsertReplacementPair(
                        index: &index,
                        fromTokens: fromTokens,
                        toTokens: toToks,
                        ts: ts
                    )
                }
            }
        }
    }

    public static func updateCorrectionsIndex(
        datasetPath: URL,
        indexPath: URL
    ) -> CorrectionIndex {
        (try? updateCorrectionsIndexThrowing(datasetPath: datasetPath, indexPath: indexPath))
            ?? readIndex(at: indexPath)
    }

    public static func updateCorrectionsIndexThrowing(
        datasetPath: URL,
        indexPath: URL,
        now: Date = Date(),
        pruneStale: Bool = true
    ) throws -> CorrectionIndex {
        let datasetExists = FileManager.default.fileExists(atPath: datasetPath.path)
        var index: CorrectionIndex
        if datasetExists {
            // Any unreadable/obsolete index can be rebuilt from the canonical
            // append-only dataset without losing observations.
            index = (try? readIndexThrowing(at: indexPath)) ?? CorrectionIndex.defaultIndex()
        } else {
            // Without the dataset, silently replacing an existing bad index
            // would make one-time replacement approvals unrecoverable.
            index = try readIndexThrowing(at: indexPath)
        }

        guard datasetExists else {
            if pruneStale, pruneStaleReplacementPairs(in: &index, now: now) > 0 {
                try writeIndex(index, to: indexPath)
            }
            return index
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: datasetPath.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let storedOffset = index.lastProcessedOffset
        let canResumeFromOffset = storedOffset.map { $0 <= fileSize } ?? false
        let startOffset = canResumeFromOffset ? (storedOffset ?? 0) : 0
        let handle = try FileHandle(forReadingFrom: datasetPath)
        defer { try? handle.close() }
        try handle.seek(toOffset: startOffset)
        let newData = try handle.readToEnd() ?? Data()
        guard let content = String(data: newData, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }

        var lastDate: Date?
        if !canResumeFromOffset, let lastTs = index.lastProcessedTs {
            lastDate = parseTimestamp(lastTs)
        }

        var records: [(Date, String, String, String, String)] = []
        for line in content.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            guard let json = try? JSONValue.parse(s) else { continue }
            guard let obj = json.objectValue else { continue }
            guard let tsStr = obj["timestamp"]?.stringValue,
                  let d = parseTimestamp(tsStr) else { continue }

            if let ld = lastDate, d <= ld { continue }

            let raw = obj["raw_whisper"]?.stringValue ?? ""
            let base = obj["ai_edited"]?.stringValue ?? raw
            let userFinal = obj["user_final"]?.stringValue ?? ""
            if userFinal.isEmpty { continue }

            records.append((d, tsStr, raw, base, userFinal))
        }

        records.sort { $0.0 < $1.0 }

        for (_, tsStr, raw, base, userFinal) in records {
            index.processedRows += 1
            var countedInserted = Set<String>()
            var countedReplacements = Set<String>()
            processDiff(
                index: &index,
                sourceText: base,
                userText: userFinal,
                ts: tsStr,
                countedInserted: &countedInserted,
                countedReplacements: &countedReplacements
            )
            if normCmp(raw) != normCmp(base) {
                processDiff(
                    index: &index,
                    sourceText: raw,
                    userText: userFinal,
                    ts: tsStr,
                    countedInserted: &countedInserted,
                    countedReplacements: &countedReplacements
                )
            }
            index.lastProcessedTs = tsStr
        }
        index.lastProcessedOffset = fileSize
        if pruneStale { pruneStaleReplacementPairs(in: &index, now: now) }
        try writeIndex(index, to: indexPath)

        return index
    }

    public static func removeReplacementPairFromIndex(
        bucket: String,
        fromText: String,
        toText: String,
        indexPath: URL
    ) -> Bool {
        (try? removeReplacementPairFromIndexThrowing(
            bucket: bucket,
            fromText: fromText,
            toText: toText,
            indexPath: indexPath
        )) ?? false
    }

    public static func removeReplacementPairFromIndexThrowing(
        bucket: String,
        fromText: String,
        toText: String,
        indexPath: URL
    ) throws -> Bool {
        guard bucket == "latin" || bucket == "cyrillic" else { return false }
        var index = readIndex(at: indexPath)

        let fk = TermCanonicalizer.canonicalKey(TermCanonicalizer.canonicalize(fromText))
        let tk = TermCanonicalizer.canonicalKey(TermCanonicalizer.canonicalize(toText))

        var pairs = index.replacementPairs[bucket] ?? []
        let originalCount = pairs.count
        pairs.removeAll {
            TermCanonicalizer.canonicalKey($0.from) == fk &&
            TermCanonicalizer.canonicalKey($0.to) == tk
        }

        if pairs.count == originalCount { return false }

        index.replacementPairs[bucket] = pairs
        try writeIndex(index, to: indexPath)
        return true
    }

    public static func getCorrectionCandidates(
        index: CorrectionIndex,
        existingLowerByLang: [String: Set<String>],
        skippedLowerByLang: [String: [String: Int]],
        currentPhraseCount: Int,
        minCorrectionCount: [String: Int] = ["latin": 2, "cyrillic": 2],
        cooldownPhrases: Int = 100,
        maxPerLang: Int = 20,
        maxAgeDays: Int = 60,
        now: Date = Date()
    ) -> [String: [TermCandidate]] {
        var result: [String: [TermCandidate]] = [:]
        let ageLimit = now.addingTimeInterval(-TimeInterval(maxAgeDays * 86_400))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatterNoFrac = ISO8601DateFormatter()
        formatterNoFrac.formatOptions = [.withInternetDateTime]
        let stableTargets = stableReplacementTargets(in: index)

        for lang in ["latin", "cyrillic"] {
            let existing = VocabProvider.existingTermsUnionForScript(existingLowerByLang, script: lang)
            let skipped = VocabProvider.skippedPhrasesMergeForScript(skippedLowerByLang, script: lang)
            let terms = index.insertedTerms[lang] ?? [:]
            var items: [TermCandidate] = []

            for (_, payload) in terms {
                let minimumCount = minCorrectionCount[lang] ?? 2
                if payload.weightedCount < Double(minimumCount) { continue }
                if existing.contains(TermCanonicalizer.canonicalKey(payload.term)) { continue }
                let key = TermCanonicalizer.canonicalKey(payload.term)
                let skippedAt = skipped[key] ?? -1
                if skippedAt >= 0, currentPhraseCount - skippedAt < cooldownPhrases { continue }
                if !hasTechnicalShape(payload.term), stableTargets[lang]?.contains(key) != true {
                    continue
                }

                var seenDt: Date? = formatter.date(from: payload.lastSeen.replacingOccurrences(of: "Z", with: "+00:00"))
                if seenDt == nil { seenDt = formatterNoFrac.date(from: payload.lastSeen.replacingOccurrences(of: "Z", with: "+00:00")) }

                if let dt = seenDt, dt < ageLimit { continue }

                items.append(TermCandidate(term: payload.term, count: payload.count, correctionCount: payload.count, frequencyCount: 0, source: "correction"))
            }

            items.sort {
                if $0.correctionCount != $1.correctionCount {
                    return $0.correctionCount > $1.correctionCount
                }
                return TermCanonicalizer.canonicalKey($0.term) < TermCanonicalizer.canonicalKey($1.term)
            }

            if !items.isEmpty {
                result[lang] = Array(items.prefix(maxPerLang))
            }
        }
        return result
    }

    public static func hasFreshStrongCorrectionSignal(
        index: CorrectionIndex,
        currentPhraseCount: Int,
        recentPhraseWindow: Int = 10,
        minCount: Int = 2,
        alreadyProcessedRows: Int = 0
    ) -> Bool {
        let latestRow = index.processedRows
        if latestRow <= 0 || latestRow <= alreadyProcessedRows { return false }

        for lang in ["latin", "cyrillic"] {
            if let dict = index.insertedTerms[lang] {
                for payload in dict.values {
                    if payload.count < minCount { continue }
                    if latestRow - payload.lastSeenRow <= recentPhraseWindow { return true }
                }
            }
        }
        return false
    }
}
