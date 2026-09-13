import sys
import re

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "r") as f:
    content = f.read()

old_revert = """    public func revert(language: String? = nil) throws {
        let lang = LanguageCode.normalize(language ?? snapshot.primaryLanguage)
        var candidate = snapshot
        var snapshots = candidate.raw["prompt_snapshots"]?.objectValue ?? JSONObject()
        guard let previous = snapshots[lang]?.arrayValue, !previous.isEmpty else {
            throw DictionaryCoordinatorError.noSnapshot
        }
        var byLanguage = candidate.raw["user_terms"]?.objectValue ?? JSONObject()
        let current = byLanguage[lang]?.arrayValue ?? []
        let normalized = previous.map { item -> JSONValue in
            if let text = item.stringValue {
                return makeTermItem(text, source: "manual", useCount: 0)
            }
            return item
        }
        snapshots[lang] = .array(current)
        byLanguage[lang] = .array(normalized)
        candidate.raw["prompt_snapshots"] = .object(snapshots)
        candidate.raw["user_terms"] = .object(byLanguage)
        try commit(candidate, promptLanguages: [lang], invalidations: [.terms])
    }"""

new_revert = """    public func canRevert(language: String? = nil) -> Bool {
        let lang = LanguageCode.normalize(language ?? snapshot.primaryLanguage)
        let snapshots = snapshot.raw["prompt_snapshots"]?.objectValue ?? JSONObject()
        return snapshots.keys.contains(lang)
    }

    public func revert(language: String? = nil) throws {
        let lang = LanguageCode.normalize(language ?? snapshot.primaryLanguage)
        var candidate = snapshot
        var snapshots = candidate.raw["prompt_snapshots"]?.objectValue ?? JSONObject()
        guard let previous = snapshots[lang]?.arrayValue else {
            throw DictionaryCoordinatorError.noSnapshot
        }
        var byLanguage = candidate.raw["user_terms"]?.objectValue ?? JSONObject()
        let current = byLanguage[lang]?.arrayValue ?? []
        
        var currentDict = [String: JSONValue]()
        for item in current {
            if let text = item.objectValue?["term"]?.stringValue {
                currentDict[TermCanonicalizer.canonicalKey(text)] = item
            } else if let text = item.stringValue {
                currentDict[TermCanonicalizer.canonicalKey(text)] = item
            }
        }
        
        let normalized = previous.map { item -> JSONValue in
            var obj = item.objectValue ?? JSONObject()
            let termText = obj["term"]?.stringValue ?? item.stringValue ?? ""
            let key = TermCanonicalizer.canonicalKey(termText)
            
            if item.stringValue != nil {
                obj["term"] = .string(termText)
                obj["source"] = .string("manual")
                obj["use_count"] = .int(0)
            }
            
            if let currentItem = currentDict[key]?.objectValue {
                if let newUseCount = currentItem["use_count"]?.intValue,
                   let oldUseCount = obj["use_count"]?.intValue,
                   newUseCount > oldUseCount {
                    obj["use_count"] = .int(newUseCount)
                } else if currentItem["use_count"]?.intValue != nil && obj["use_count"] == nil {
                    obj["use_count"] = currentItem["use_count"]
                }
                
                if let newLastSeen = currentItem["last_seen"]?.stringValue,
                   let oldLastSeen = obj["last_seen"]?.stringValue,
                   newLastSeen > oldLastSeen {
                    obj["last_seen"] = .string(newLastSeen)
                } else if currentItem["last_seen"]?.stringValue != nil && obj["last_seen"] == nil {
                    obj["last_seen"] = currentItem["last_seen"]
                }
            }
            return .object(obj)
        }
        
        snapshots[lang] = .array(current)
        byLanguage[lang] = .array(normalized)
        candidate.raw["prompt_snapshots"] = .object(snapshots)
        candidate.raw["user_terms"] = .object(byLanguage)
        try commit(candidate, promptLanguages: [lang], invalidations: [.terms])
    }"""

content = content.replace(old_revert, new_revert)

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "w") as f:
    f.write(content)
