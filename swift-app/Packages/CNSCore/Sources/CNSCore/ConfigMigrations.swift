import Foundation

/// Config schema migrations ported 1:1 from `utils.py`. Each function is
/// idempotent (no-op when `schema_version` already exceeds the target) and
/// operates in place on the dynamic `JSONObject`, mirroring the Python dict code.
public enum ConfigMigrations {
    private static func schemaVersion(_ obj: JSONObject) -> Int {
        Int(obj["schema_version"]?.intValue ?? 1)
    }

    // MARK: v2

    /// `migrate_config_to_v2`: parse comma-separated terms from custom_prompts /
    /// legacy initial_prompt into user_terms, drop v1 keys.
    public static func migrateToV2(_ obj: inout JSONObject, promptBuilder: InitialPromptBuilder) {
        if schemaVersion(obj) >= 2 { return }

        let primary = Config.primaryLanguage(obj)
        let customPrompts = obj["custom_prompts"]?.objectValue ?? JSONObject()
        var candidateLangs = Set(customPrompts.keys)
        if obj["initial_prompt"]?.isTruthy == true { candidateLangs.insert(primary) }

        var userTerms = JSONObject()
        for lang in candidateLangs {
            let source: String
            if let cp = customPrompts[lang]?.stringValue, !cp.isEmpty {
                source = cp
            } else if lang == primary {
                source = obj["initial_prompt"]?.stringValue ?? ""
            } else {
                source = ""
            }
            if !source.isEmpty {
                let terms = PromptTerms.parse(source)
                if !terms.isEmpty {
                    userTerms[lang] = .array(terms.map { .string($0) })
                }
            }
        }

        obj["schema_version"] = .int(2)
        obj["user_terms"] = .object(userTerms)
        obj.setDefault("auto_terms", .object(JSONObject()))
        obj.setDefault("prompt_snapshots", .object(JSONObject()))
        obj.setDefault("pending_suggestions", .object(JSONObject()))
        obj.setDefault("skipped_terms", .object(JSONObject()))
        obj.setDefault("prompt_update_mode", .string("suggest"))
        obj.setDefault("auto_prompt_check_interval", .int(20))
        obj.setDefault("last_analysis_phrase_count", .int(0))

        for key in ["custom_prompts", "previous_prompts", "previous_initial_prompt", "language_hint", "terms_hint"] {
            obj.remove(key)
        }
        obj["initial_prompt"] = .string(promptBuilder.build(config: obj))
    }

    // MARK: v3

    /// `migrate_config_to_v3`: merge auto_terms into user_terms.
    public static func migrateToV3(_ obj: inout JSONObject, promptBuilder: InitialPromptBuilder) {
        if schemaVersion(obj) >= 3 { return }

        if let autoTerms = obj["auto_terms"]?.objectValue, !autoTerms.keys.isEmpty {
            var userTerms = obj["user_terms"]?.objectValue ?? JSONObject()
            for (lang, termsVal) in autoTerms.pairs {
                guard let terms = termsVal.arrayValue, !terms.isEmpty else { continue }
                let current = userTerms[lang]?.arrayValue ?? []
                userTerms[lang] = .array(TermJSON.deduplicate(current + terms))
            }
            obj["user_terms"] = .object(userTerms)
        }

        obj["schema_version"] = .int(3)
        obj.remove("auto_terms")
        obj["initial_prompt"] = .string(promptBuilder.build(config: obj))
    }

    // MARK: v4

    /// `migrate_config_to_v4`: strip language-hint prefixes glued to first term.
    public static func migrateToV4(_ obj: inout JSONObject, promptBuilder: InitialPromptBuilder) {
        if schemaVersion(obj) >= 4 { return }

        let hintPrefixes: [String] = LanguageConstants.langPrompts.values.map { value in
            var stripped = Substring(value)
            while let last = stripped.last, last == "." || last == " " { stripped = stripped.dropLast() }
            return String(stripped) + ". "
        }

        let userTerms = obj["user_terms"]?.objectValue ?? JSONObject()
        var cleaned = JSONObject()
        for (lang, termsVal) in userTerms.pairs {
            var clean: [JSONValue] = []
            for termVal in termsVal.arrayValue ?? [] {
                var t = termVal.stringValue ?? ""
                for prefix in hintPrefixes where t.hasPrefix(prefix) {
                    t = String(t.dropFirst(prefix.count))
                    while let f = t.first, f == " " { t = String(t.dropFirst()) }
                    break
                }
                t = t.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { clean.append(.string(t)) }
            }
            cleaned[lang] = .array(TermJSON.deduplicate(clean))
        }

        obj["user_terms"] = .object(cleaned)
        obj["schema_version"] = .int(4)
        obj["initial_prompt"] = .string(promptBuilder.build(config: obj))
    }

    // MARK: v5

    /// `migrate_config_to_v5`: convert legacy string terms to metadata dicts.
    public static func migrateToV5(_ obj: inout JSONObject, promptBuilder: InitialPromptBuilder, now: String = ISOTimestamp.now()) {
        if schemaVersion(obj) >= 5 { return }

        let userTerms = obj["user_terms"]?.objectValue ?? JSONObject()
        var newUserTerms = JSONObject()
        for (lang, termsVal) in userTerms.pairs {
            var newList: [JSONValue] = []
            for item in termsVal.arrayValue ?? [] {
                switch item {
                case let .string(s):
                    var entry = JSONObject()
                    entry["term"] = .string(s)
                    entry["source"] = .string("manual")
                    entry["added_at"] = .string(now)
                    entry["last_seen"] = .string(now)
                    entry["use_count"] = .int(0)
                    newList.append(.object(entry))
                case .object:
                    newList.append(item)
                default:
                    break
                }
            }
            newUserTerms[lang] = .array(newList)
        }

        obj["user_terms"] = .object(newUserTerms)
        obj["schema_version"] = .int(5)
        obj.setDefault("last_decay_run_ts", .null)
        obj.setDefault("max_dictionary_age_days", .int(60))
        obj["initial_prompt"] = .string(promptBuilder.build(config: obj))
    }

    // MARK: v6

    /// `migrate_config_to_v6`: normalise manual replacement pairs.
    public static func migrateToV6(_ obj: inout JSONObject) {
        if schemaVersion(obj) >= 6 {
            obj.setDefault("manual_replacements", .array([]))
            return
        }

        var cleaned: [JSONValue] = []
        if let raw = obj["manual_replacements"]?.arrayValue {
            for item in raw {
                guard case let .object(o) = item else { continue }
                let fr = (o["from"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                let to = (o["to"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                if fr.isEmpty || to.isEmpty { continue }
                var entry = JSONObject()
                entry["from"] = .string(fr)
                entry["to"] = .string(to)
                if let addedAt = o["added_at"]?.stringValue, !addedAt.trimmingCharacters(in: .whitespaces).isEmpty {
                    entry["added_at"] = .string(addedAt.trimmingCharacters(in: .whitespaces))
                }
                cleaned.append(.object(entry))
            }
        }

        obj["manual_replacements"] = .array(cleaned)
        obj["schema_version"] = .int(6)
    }

    // MARK: v7

    /// `migrate_config_to_v7`: add last_notified_update_version.
    public static func migrateToV7(_ obj: inout JSONObject) {
        if schemaVersion(obj) >= 7 {
            obj.setDefault("last_notified_update_version", .null)
            return
        }
        obj.setDefault("last_notified_update_version", .null)
        obj["schema_version"] = .int(7)
    }

    // MARK: v8

    /// `migrate_config_to_v8`: add language_auto_detect.
    public static func migrateToV8(_ obj: inout JSONObject) {
        if schemaVersion(obj) >= 8 {
            obj.setDefault("language_auto_detect", .bool(false))
            return
        }
        obj.setDefault("language_auto_detect", .bool(false))
        obj["schema_version"] = .int(8)
    }

    // MARK: v9

    /// `migrate_config_to_v9`: add stt_backend / stt_cloud_model.
    public static func migrateToV9(_ obj: inout JSONObject) {
        if schemaVersion(obj) >= 9 {
            obj.setDefault("stt_backend", .string("local"))
            obj.setDefault("stt_cloud_model", .string("gemini-2.5-flash-lite"))
            return
        }
        obj.setDefault("stt_backend", .string("local"))
        obj.setDefault("stt_cloud_model", .string("gemini-2.5-flash-lite"))
        obj["schema_version"] = .int(9)
    }

    // MARK: v10

    /// `migrate_config_to_v10`: add durable replacement approval policy.
    public static func migrateToV10(_ obj: inout JSONObject) {
        obj.setDefault("approved_auto_replacements", .array([]))
        obj.setDefault("rejected_replacements", .array([]))
        obj.setDefault("replacement_policy_initialized", .bool(false))
        if schemaVersion(obj) < 10 {
            obj["schema_version"] = .int(10)
        }
    }

    // MARK: Ukrainian normalization

    /// `normalize_ukrainian_lang_codes`: fold legacy "ua" into "uk".
    public static func normalizeUkrainianLangCodes(_ obj: inout JSONObject) {
        if let primary = obj["primary_language"]?.stringValue {
            obj["primary_language"] = .string(LanguageCode.normalize(primary))
        }
        if let additional = obj["additional_languages"]?.arrayValue {
            let codes = additional.compactMap(\.stringValue)
            let deduped = LanguageCode.dedupeList(codes, primary: obj["primary_language"]?.stringValue)
            obj["additional_languages"] = .array(deduped.map { .string($0) })
        }
        if let legacy = obj["languages"]?.arrayValue {
            let codes = legacy.compactMap(\.stringValue)
            obj["languages"] = .array(LanguageCode.dedupeList(codes).map { .string($0) })
        }

        func mergeLangLists(_ section: String) {
            guard let raw = obj[section]?.objectValue else { return }
            var merged = JSONObject()
            for (lang, valuesVal) in raw.pairs {
                guard let values = valuesVal.arrayValue else { continue }
                let key = LanguageCode.normalize(lang)
                let current = merged[key]?.arrayValue ?? []
                merged[key] = .array(TermJSON.deduplicate(current + values))
            }
            obj[section] = .object(merged)
        }
        mergeLangLists("user_terms")
        mergeLangLists("pending_suggestions")
        mergeLangLists("prompt_snapshots")

        if let skippedRaw = obj["skipped_terms"]?.objectValue {
            var mergedSkipped = JSONObject()
            for (lang, termsVal) in skippedRaw.pairs {
                guard let terms = termsVal.objectValue else { continue }
                let key = LanguageCode.normalize(lang)
                var bucket = mergedSkipped[key]?.objectValue ?? JSONObject()
                for (term, cntVal) in terms.pairs {
                    let canonical = TermCanonicalizer.canonicalKey(term)
                    if canonical.isEmpty { continue }
                    let cnt = Int(cntVal.intValue ?? 0)
                    let existing = bucket[canonical]?.intValue.map(Int.init) ?? -1
                    bucket[canonical] = .int(Int64(max(existing, cnt)))
                }
                mergedSkipped[key] = .object(bucket)
            }
            obj["skipped_terms"] = .object(mergedSkipped)
        }
    }
}

/// UTC ISO-8601 timestamp with microseconds and `+00:00` suffix, matching
/// Python's `datetime.now(timezone.utc).isoformat()`.
public enum ISOTimestamp {
    public static func now(_ date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let micros = (c.nanosecond ?? 0) / 1000
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%06d+00:00",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0, micros
        )
    }
}
