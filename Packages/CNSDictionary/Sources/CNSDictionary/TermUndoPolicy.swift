import Foundation
import CNSCore

enum TermUndoPolicy {
    static func capturePreviousTerms(from snapshot: Config, into candidate: inout Config, languages: Set<String>) {
        var snapshots = candidate.raw["prompt_snapshots"]?.objectValue ?? JSONObject()
        let oldByLanguage = snapshot.raw["user_terms"]?.objectValue ?? JSONObject()
        let newByLanguage = candidate.raw["user_terms"]?.objectValue ?? JSONObject()
        
        for lang in languages {
            let oldTerms = oldByLanguage[lang]?.arrayValue ?? []
            let newTerms = newByLanguage[lang]?.arrayValue ?? []
            
            if oldTerms != newTerms {
                snapshots[lang] = .array(oldTerms)
            }
        }
        
        candidate.raw["prompt_snapshots"] = .object(snapshots)
    }
}
