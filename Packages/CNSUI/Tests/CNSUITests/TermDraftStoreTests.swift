import Testing
@testable import CNSUI

@Suite
struct TermDraftStoreTests {
    @Test func dirtyTextSurvivesUnchangedRemote() {
        var store = TermDraftStore()
        store.reconcile(["en|swift": "Swift"])
        store.setText("SwiftUI", for: "en|swift")
        store.reconcile(["en|swift": "Swift"])
        #expect(store.draft(for: "en|swift")?.text == "SwiftUI")
        #expect(store.draft(for: "en|swift")?.hasConflict == false)
    }

    @Test func cleanLineAdoptsNewRemote() {
        var store = TermDraftStore()
        store.reconcile(["en|swift": "Swift"])
        store.reconcile(["en|swift": "Swift 2"])
        #expect(store.draft(for: "en|swift")?.text == "Swift 2")
        #expect(store.draft(for: "en|swift")?.baseline == "Swift 2")
        #expect(store.draft(for: "en|swift")?.hasConflict == false)
    }

    @Test func dirtyLineHasConflictIfRemoteChanges() {
        var store = TermDraftStore()
        store.reconcile(["en|swift": "Swift"])
        store.setText("SwiftUI", for: "en|swift")
        store.reconcile(["en|swift": "Swift 2"])
        #expect(store.draft(for: "en|swift")?.text == "SwiftUI")
        #expect(store.draft(for: "en|swift")?.hasConflict == true)
        #expect(store.draft(for: "en|swift")?.remote == "Swift 2")
    }

    @Test func dirtyLineRemovedRemotely() {
        var store = TermDraftStore()
        store.reconcile(["en|swift": "Swift"])
        store.setText("SwiftUI", for: "en|swift")
        store.reconcile([:])
        #expect(store.draft(for: "en|swift")?.text == "SwiftUI")
        #expect(store.draft(for: "en|swift")?.hasConflict == true)
        #expect(store.draft(for: "en|swift")?.remote == nil)
    }

    @Test func cleanLineRemovedRemotely() {
        var store = TermDraftStore()
        store.reconcile(["en|swift": "Swift"])
        store.reconcile([:])
        #expect(store.draft(for: "en|swift") == nil)
    }
    
    @Test func acceptRemote() {
        var store = TermDraftStore()
        store.reconcile(["en|swift": "Swift"])
        store.setText("SwiftUI", for: "en|swift")
        store.reconcile(["en|swift": "Swift 2"])
        store.acceptRemote(for: "en|swift")
        #expect(store.draft(for: "en|swift")?.text == "Swift 2")
        #expect(store.draft(for: "en|swift")?.hasConflict == false)
        #expect(store.draft(for: "en|swift")?.isDirty == false)
    }
    
    @Test func acceptRemoteForDeleted() {
        var store = TermDraftStore()
        store.reconcile(["en|swift": "Swift"])
        store.setText("SwiftUI", for: "en|swift")
        store.reconcile([:])
        store.acceptRemote(for: "en|swift")
        #expect(store.draft(for: "en|swift") == nil)
    }
}
