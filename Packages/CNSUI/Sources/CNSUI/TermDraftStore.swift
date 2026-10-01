public struct TermDraft: Equatable, Sendable {
    public let baseline: String
    public var text: String
    public var remote: String?
    
    public var isDirty: Bool { text != baseline }
    public var hasConflict: Bool { isDirty && remote != baseline }
    
    public init(baseline: String, text: String, remote: String? = nil) {
        self.baseline = baseline
        self.text = text
        self.remote = remote ?? baseline
    }
}

public struct TermDraftStore: Sendable {
    private var drafts: [String: TermDraft] = [:]
    
    public init() {}
    
    public mutating func reconcile(_ values: [String: String]) {
        for (id, newValue) in values {
            if var draft = drafts[id] {
                draft.remote = newValue
                if !draft.isDirty {
                    // Clean line adopts new baseline/text
                    draft = TermDraft(baseline: newValue, text: newValue)
                }
                drafts[id] = draft
            } else {
                // New line
                drafts[id] = TermDraft(baseline: newValue, text: newValue)
            }
        }
        
        // Handle removals
        let currentIDs = Set(drafts.keys)
        let newIDs = Set(values.keys)
        let removedIDs = currentIDs.subtracting(newIDs)
        
        for id in removedIDs {
            if let draft = drafts[id], draft.isDirty {
                // Dirty line removed remotely - mark as remote = nil (deleted)
                var updated = draft
                updated.remote = nil
                drafts[id] = updated
            } else {
                // Clean line removed remotely - remove from drafts
                drafts.removeValue(forKey: id)
            }
        }
    }
    
    public mutating func setText(_ text: String, for id: String) {
        guard var draft = drafts[id] else { return }
        draft.text = text
        drafts[id] = draft
    }
    
    public func draft(for id: String) -> TermDraft? {
        drafts[id]
    }
    
    public mutating func acceptRemote(for id: String) {
        guard var draft = drafts[id] else { return }
        if let remote = draft.remote {
            draft = TermDraft(baseline: remote, text: remote)
            drafts[id] = draft
        } else {
            // It was removed remotely and we accepted it, so remove from drafts
            drafts.removeValue(forKey: id)
        }
    }
    
    public mutating func reset(for id: String) {
        guard let draft = drafts[id] else { return }
        drafts[id] = TermDraft(baseline: draft.baseline, text: draft.baseline, remote: draft.remote)
    }
    
    public var allIDs: [String] {
        Array(drafts.keys)
    }
}
