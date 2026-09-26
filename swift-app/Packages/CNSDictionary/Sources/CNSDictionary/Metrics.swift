import CNSCore
import Foundation

public enum Metrics {
    public static let historyRotateBytes: Int = 1_000_000
    public static let historyKeepDays: Int = 365


    private static func parseIso(_ ts: String?) -> Date? {
        guard let ts = ts else { return nil }
        let normalized = ts.replacingOccurrences(of: "Z", with: "+00:00")
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: normalized) { return date }
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return regular.date(from: normalized)
    }

    private static func tokenize(_ text: String) -> Set<String> {
        let tokenRe = /[A-Za-zА-Яа-яЁё][A-Za-zА-Яа-яЁё0-9+#._-]+/
        var res = Set<String>()
        for match in text.matches(of: tokenRe) {
            res.insert(String(text[match.range]).lowercased())
        }
        return res
    }

    private static func safeRatio(_ numerator: Double, _ denominator: Double) -> Double? {
        return denominator <= 0 ? nil : numerator / denominator
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

    private static func editScoreChar(base: String, final: String) -> Double {
        let maxLen = max(base.count, final.count, 1)
        return Double(levenshtein(base, final)) / Double(maxLen)
    }

    private static func readDatasetTail(url: URL, limit: Int) -> [JSONObject] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var rows: [JSONObject] = []
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let tail = lines.suffix(limit)
        for line in tail {
            if let v = try? JSONValue.parse(line), let obj = v.objectValue {
                rows.append(obj)
            }
        }
        return rows
    }

    private static func readCorrections(url: URL) -> JSONObject {
        guard FileManager.default.fileExists(atPath: url.path) else { return JSONObject() }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return JSONObject() }
        if let v = try? JSONValue.parse(content), var data = v.objectValue {
            var pairs = data["replacement_pairs"]?.objectValue ?? JSONObject()
            if pairs["latin"] == nil, let en = pairs["en"] {
                pairs["latin"] = en
                pairs["cyrillic"] = pairs["ru"]
                data["replacement_pairs"] = .object(pairs)
            }
            return data
        }
        return JSONObject()
    }

    private static func splitWindows(_ records: [JSONObject], windowSize: Int) -> ([JSONObject], [JSONObject]) {
        if windowSize <= 0 { return (records, []) }
        let current = Array(records.suffix(windowSize))
        let previous = Array(records.dropLast(current.count).suffix(windowSize))
        return (current, previous)
    }

    private static func windowEditScore(_ records: [JSONObject]) -> Double? {
        var values: [Double] = []
        for row in records {
            let userFinal = row["user_final"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            if userFinal.isEmpty { continue }
            let base = (row["ai_edited"]?.stringValue ?? row["raw_whisper"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            values.append(editScoreChar(base: base, final: userFinal))
        }
        if values.isEmpty { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func activeTermsByLang(_ config: JSONObject) -> [String: [String]] {
        var out: [String: [String]] = [:]
        guard let userTerms = config["user_terms"]?.objectValue else { return out }
        for lang in userTerms.keys {
            let itemsVal = userTerms[lang]!
            guard let items = itemsVal.arrayValue else { continue }
            var terms: [String] = []
            for item in items {
                let isActive = item.objectValue?["inactive"]?.boolValue == false || item.objectValue?["inactive"] == nil
                if isActive {
                    let term = item.objectValue?["term"]?.stringValue ?? item.stringValue ?? ""
                    if !term.isEmpty { terms.append(term) }
                }
            }
            if !terms.isEmpty { out[lang] = terms }
        }
        return out
    }

    private static func dictionaryHitRate(_ records: [JSONObject], config: JSONObject) -> Double? {
        if records.isEmpty { return nil }
        var activeTerms: [String] = []
        for terms in activeTermsByLang(config).values {
            activeTerms.append(contentsOf: terms)
        }
        if activeTerms.isEmpty { return 0.0 }
        let activeLowers = Set(activeTerms.map { TermCanonicalizer.canonicalKey($0) })
        var hits = 0
        var valid = 0
        for row in records {
            let final = row["user_final"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            if final.isEmpty { continue }
            valid += 1
            let tokens = tokenize(final)
            if !activeLowers.isDisjoint(with: tokens) { hits += 1 }
        }
        if valid == 0 { return nil }
        return Double(hits) / Double(valid)
    }

    private static func termsCatalogueHealth(_ config: JSONObject, now: Date) -> JSONObject {
        var active = 0
        var inactive = 0
        var bySource: [String: Int] = ["manual": 0, "auto": 0, "correction": 0]
        var oldestAgeDays = 0

        guard let userTerms = config["user_terms"]?.objectValue else {
            var res = JSONObject()
            res["active_terms_count"] = .int(Int64(active))
            res["inactive_terms_count"] = .int(Int64(inactive))
            res["manual_terms_count"] = .int(Int64(bySource["manual"]!))
            res["auto_terms_count"] = .int(Int64(bySource["auto"]!))
            res["correction_terms_count"] = .int(Int64(bySource["correction"]!))
            res["oldest_active_age_days"] = .int(Int64(oldestAgeDays))
            return res
        }

        for key in userTerms.keys {
            let itemsVal = userTerms[key]!
            guard let items = itemsVal.arrayValue else { continue }
            for item in items {
                if let obj = item.objectValue {
                    if obj["inactive"]?.boolValue == true {
                        inactive += 1
                    } else {
                        active += 1
                        let src = obj["source"]?.stringValue ?? "manual"
                        bySource[src, default: 0] += 1
                        let seen = parseIso(obj["last_seen"]?.stringValue ?? obj["added_at"]?.stringValue)
                        if let s = seen {
                            let age = max(0, Int(now.timeIntervalSince(s) / 86400))
                            oldestAgeDays = max(oldestAgeDays, age)
                        }
                    }
                } else {
                    active += 1
                    bySource["manual", default: 0] += 1
                }
            }
        }

        var res = JSONObject()
        res["active_terms_count"] = .int(Int64(active))
        res["inactive_terms_count"] = .int(Int64(inactive))
        res["manual_terms_count"] = .int(Int64(bySource["manual"] ?? 0))
        res["auto_terms_count"] = .int(Int64(bySource["auto"] ?? 0))
        res["correction_terms_count"] = .int(Int64(bySource["correction"] ?? 0))
        res["oldest_active_age_days"] = .int(Int64(oldestAgeDays))
        return res
    }

    private static func candidateFunnel(_ config: JSONObject) -> JSONObject {
        let pending = config["pending_suggestions"]?.objectValue ?? JSONObject()
        let skipped = config["skipped_terms"]?.objectValue ?? JSONObject()
        let userTerms = config["user_terms"]?.objectValue ?? JSONObject()

        var pendingNow = 0
        for key in pending.keys { pendingNow += pending[key]!.arrayValue?.count ?? 0 }

        var rejectedTotal = 0
        for key in skipped.keys { rejectedTotal += skipped[key]!.objectValue?.keys.count ?? 0 }

        var acceptedTotal = 0
        for key in userTerms.keys {
            let itemsVal = userTerms[key]!
            for item in itemsVal.arrayValue ?? [] {
                if let obj = item.objectValue {
                    let src = obj["source"]?.stringValue
                    if src == "auto" || src == "correction" {
                        acceptedTotal += 1
                    }
                }
            }
        }

        let proposedTotal = acceptedTotal + rejectedTotal + pendingNow
        let denominator = acceptedTotal + rejectedTotal
        let acceptanceRate = denominator > 0 ? Double(acceptedTotal) / Double(denominator) : nil

        var res = JSONObject()
        res["proposed_total"] = .int(Int64(proposedTotal))
        res["accepted_total"] = .int(Int64(acceptedTotal))
        res["rejected_total"] = .int(Int64(rejectedTotal))
        res["pending_now"] = .int(Int64(pendingNow))
        if let ar = acceptanceRate {
            res["acceptance_rate"] = .double(ar)
        } else {
            res["acceptance_rate"] = .null
        }
        res["acceptance_rate_scope"] = .string("lifetime")
        return res
    }

    private static func promptUtilisation(_ config: JSONObject) -> JSONObject {
        let prompt = InitialPromptBuilder().build(config: config)
        let used = HeuristicTokenCounter().countTokens(prompt)
        let maximum = 200
        var res = JSONObject()
        res["prompt_tokens_used"] = .int(Int64(used))
        res["prompt_tokens_max"] = .int(Int64(maximum))
        res["prompt_utilisation"] = .double(min(1, Double(used) / Double(maximum)))
        return res
    }

    private static func correctionRecurrence(
        _ corrections: JSONObject,
        now: Date,
        lookbackDays: Int = 30,
        minRecentCount: Int = 3
    ) -> JSONObject {
        let pairs = corrections["replacement_pairs"]?.objectValue ?? JSONObject()
        let cutoff = now.addingTimeInterval(-TimeInterval(lookbackDays * 86400))
        var failing: [JSONObject] = []

        for bucket in ["latin", "cyrillic"] {
            guard let items = pairs[bucket]?.arrayValue else { continue }
            for item in items {
                guard let obj = item.objectValue else { continue }
                let count = Int(obj["count"]?.intValue ?? 0)
                if count < minRecentCount { continue }
                let seen = parseIso(obj["last_seen"]?.stringValue)
                if seen == nil || seen! < cutoff { continue }

                var f = JSONObject()
                f["bucket"] = .string(bucket)
                f["from"] = .string(obj["from"]?.stringValue ?? "")
                f["to"] = .string(obj["to"]?.stringValue ?? "")
                f["count"] = .int(Int64(count))
                f["last_seen"] = obj["last_seen"] ?? .null
                failing.append(f)
            }
        }
        failing.sort { ($0["count"]?.intValue ?? 0) > ($1["count"]?.intValue ?? 0) }

        var res = JSONObject()
        res["failed_pairs"] = .array(failing.map { .object($0) })
        res["failed_pairs_count"] = .int(Int64(failing.count))
        res["lookback_days"] = .int(Int64(lookbackDays))
        return res
    }

    private static func trend(_ current: Double?, _ previous: Double?) -> JSONObject {
        var res = JSONObject()
        guard let c = current, let p = previous else {
            res["delta"] = .null
            res["direction"] = .string("none")
            return res
        }
        let delta = c - p
        res["delta"] = .double(delta)
        if abs(delta) < 1e-9 {
            res["direction"] = .string("flat")
        } else if delta > 0 {
            res["direction"] = .string("up")
        } else {
            res["direction"] = .string("down")
        }
        return res
    }

    public static func computeMetrics(
        datasetUrl: URL,
        correctionsUrl: URL,
        config: JSONObject,
        windowSize: Int = 100,
        now: Date = Date()
    ) -> JSONObject {
        let records = readDatasetTail(url: datasetUrl, limit: max(windowSize * 2, 200))
        let (current, previous) = splitWindows(records, windowSize: windowSize)
        let corrections = readCorrections(url: correctionsUrl)

        let currentEdit = windowEditScore(current)
        let previousEdit = windowEditScore(previous)
        let currentHit = dictionaryHitRate(current, config: config)
        let previousHit = dictionaryHitRate(previous, config: config)

        let termsHealth = termsCatalogueHealth(config, now: now)
        let funnel = candidateFunnel(config)
        let prompt = promptUtilisation(config)
        let recurrence = correctionRecurrence(corrections, now: now)

        var out = JSONObject()
        out["ts"] = .string(ISOTimestamp.now(now))
        out["window_size"] = .int(Int64(windowSize))
        out["dataset_records_total"] = .int(Int64(records.count))
        out["current_window_count"] = .int(Int64(current.count))
        out["previous_window_count"] = .int(Int64(previous.count))

        out["edit_score_avg"] = currentEdit != nil ? .double(currentEdit!) : .null
        out["edit_score_prev_avg"] = previousEdit != nil ? .double(previousEdit!) : .null
        out["edit_score_trend"] = .object(trend(currentEdit, previousEdit))

        out["hit_rate"] = currentHit != nil ? .double(currentHit!) : .null
        out["hit_rate_prev"] = previousHit != nil ? .double(previousHit!) : .null
        out["hit_rate_trend"] = .object(trend(currentHit, previousHit))

        for k in termsHealth.keys { out[k] = termsHealth[k]! }
        for k in funnel.keys { out[k] = funnel[k]! }
        for k in prompt.keys { out[k] = prompt[k]! }
        for k in recurrence.keys { out[k] = recurrence[k]! }

        return out
    }

    public static func loadHistory(at url: URL) -> [JSONObject] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n").compactMap { line in
            guard let value = try? JSONValue.parse(String(line)) else { return nil }
            return value.objectValue
        }
    }

    public static func appendHistory(
        _ snapshot: JSONObject,
        to url: URL,
        keepDays: Int = historyKeepDays,
        now: Date = Date()
    ) throws {
        var entries = loadHistory(at: url)
        entries.append(snapshot)
        if keepDays > 0 {
            let cutoff = now.addingTimeInterval(-TimeInterval(keepDays * 86_400))
            entries = entries.filter { item in
                guard let date = parseIso(item["ts"]?.stringValue) else { return true }
                return date >= cutoff
            }
        }
        let payload = entries
            .map { JSONValue.object($0).serializedJSONLine() }
            .joined(separator: "\n")
        try AtomicFile.writeText(payload.isEmpty ? "" : payload + "\n", to: url)
        try rotateHistoryIfNeeded(at: url)
    }

    private static func rotateHistoryIfNeeded(at url: URL) throws {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > historyRotateBytes else { return }
        let backup = URL(fileURLWithPath: url.path + ".1")
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        try FileManager.default.moveItem(at: url, to: backup)
    }
}
