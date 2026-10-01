# Replacement Pair Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace automatic count-based text substitution with a persistent approve/reject lifecycle, count-two Gemini hints, stale-candidate cleanup, and a three-section management UI.

**Architecture:** Keep correction observations in rebuildable `corrections.json` schema 5 and durable user decisions in `config.json` schema 10. Add a focused replacement-policy model in `CNSDictionary`; make `DictionaryCoordinator` the only mutation owner; split VocabProvider queries into direct replacements and editor hints; render the resulting active/candidate/rejected sections in SwiftUI.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing/XCTest, SwiftUI/AppKit, dynamic `JSONObject` config, Python 3 migration compatibility, pytest.

**Spec:** `docs/superpowers/specs/2026-09-04-replacement-pair-lifecycle-design.md`

## Global Constraints

- Pair identity is `canonicalKey(from) + "||" + canonicalKey(to)`; preserve display spelling separately.
- Only manual and explicitly approved automatic pairs may reach direct text replacement.
- Non-rejected, non-stale observed pairs become Gemini hints at `count >= 2`.
- A pair is stale at 90 days since `last_seen` or 300 processed dataset rows since `last_seen_row`, whichever occurs first.
- Approval and rejection survive restart and correction-index rebuild.
- The one-time upgrade seeds every existing count-three-or-higher pair as approved before stale observations are pruned.
- All config and replacement mutations remain serialized by `@MainActor DictionaryCoordinator` and use atomic persistence.
- Local Qwen behavior and the existing editor-status fallback matrix do not change.
- No new dependencies are introduced.
- User-facing strings must exist in `en`, `ru`, `uk`, `de`, `es`, and `fr` with matching placeholders.

---

### Task 1: Add config schema 10 in Swift and the Python compatibility path

**Files:**
- Modify: `Packages/CNSCore/Sources/CNSCore/ConfigMigrations.swift`
- Modify: `Packages/CNSCore/Sources/CNSCore/Config.swift`
- Modify: `Packages/CNSCore/Tests/CNSCoreTests/ConfigMigrationTests.swift`
- Modify: `Packages/CNSCore/Tests/CNSCoreTests/Fixtures/migration_expected/legacy_v1.json`
- Modify: `Packages/CNSCore/Tests/CNSCoreTests/Fixtures/migration_expected/real_v6.json`
- Modify: `Packages/CNSCore/Tests/CNSCoreTests/Fixtures/migration_expected/ua_legacy.json`
- Modify: `Packages/CNSCore/Tests/CNSCoreTests/Fixtures/migration_expected/v4_strings.json`
- Modify: `src/utils.py`
- Modify: `src/app.py`
- Modify: `scripts/parity_config_bridge.py`
- Modify: `tests/test_vocab_provider.py`
- Modify: `tests/parity/fixtures/config_schemas.json`
- Modify: `tests/parity/test_parity_contract.py`

**Interfaces:**
- Produces: `ConfigMigrations.migrateToV10(_:)`
- Produces: `migrate_config_to_v10(config: dict) -> dict`
- Produces config keys: `approved_auto_replacements`, `rejected_replacements`, `replacement_policy_initialized`
- Preserves: unknown JSON keys and all prior migration defaults

- [ ] **Step 1: Write failing Swift schema-10 tests**

Add focused expectations to `ConfigMigrationTests.swift`:

```swift
@Test("Schema 9 adds replacement policy defaults")
func replacementPolicyDefaults() {
    var input = JSONObject()
    input["schema_version"] = .int(9)
    input["future_extension"] = .string("preserved")

    let migrated = Config.migrated(input, now: Self.fixedNow)

    #expect(migrated.schemaVersion == 10)
    #expect(migrated.raw["approved_auto_replacements"]?.arrayValue == [])
    #expect(migrated.raw["rejected_replacements"]?.arrayValue == [])
    #expect(migrated.raw["replacement_policy_initialized"]?.boolValue == false)
    #expect(migrated.raw["future_extension"]?.stringValue == "preserved")
}

@Test("Schema 10 replacement policy migration is idempotent")
func replacementPolicyIdempotent() {
    var input = JSONObject()
    input["schema_version"] = .int(10)
    input["approved_auto_replacements"] = .array([.object(JSONObject([
        ("from", .string("Cogni")),
        ("to", .string("Cognee")),
        ("approved_at", .string(Self.fixedNow)),
    ]))])
    input["rejected_replacements"] = .array([])
    input["replacement_policy_initialized"] = .bool(true)

    let once = Config.migrated(input, now: Self.fixedNow)
    let twice = Config.migrated(once.raw, now: Self.fixedNow)

    #expect(JSONValue.object(once.raw).semanticallyEqual(to: .object(twice.raw)))
}
```

Rename the existing reachability test to `reachesV10` and change its expected schema to 10.

- [ ] **Step 2: Run the Swift migration tests and confirm RED**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSCore --filter ConfigMigrationTests
```

Expected: failure because `migrateToV10` and schema-10 defaults do not exist.

- [ ] **Step 3: Write failing Python compatibility tests**

Add to `tests/test_vocab_provider.py`:

```python
def test_migrate_config_to_v10_replacement_policy_defaults() -> None:
    cfg: dict = {"schema_version": 9, "future_extension": {"owner": "test"}}
    migrated = utils.migrate_config_to_v10(cfg)
    assert migrated["schema_version"] == 10
    assert migrated["approved_auto_replacements"] == []
    assert migrated["rejected_replacements"] == []
    assert migrated["replacement_policy_initialized"] is False
    assert migrated["future_extension"] == {"owner": "test"}


def test_migrate_config_to_v10_is_idempotent() -> None:
    cfg: dict = {
        "schema_version": 10,
        "approved_auto_replacements": [
            {"from": "Cogni", "to": "Cognee", "approved_at": "2026-09-04T12:00:00Z"}
        ],
        "rejected_replacements": [],
        "replacement_policy_initialized": True,
    }
    assert utils.migrate_config_to_v10(cfg.copy()) == cfg
```

Extend `config_schemas.json` with a schema-10 fixture and update the parity assertion to expect schema 10 for versions 1 through 10.

- [ ] **Step 4: Run the Python migration tests and confirm RED**

Run:

```bash
source venv/bin/activate && python -m pytest \
  tests/test_vocab_provider.py::test_migrate_config_to_v10_replacement_policy_defaults \
  tests/test_vocab_provider.py::test_migrate_config_to_v10_is_idempotent \
  tests/parity/test_parity_contract.py::test_python_migrates_every_supported_schema_without_unknown_key_loss -q
```

Expected: failure because `migrate_config_to_v10` is undefined and parity stops at schema 9.

- [ ] **Step 5: Implement both migration paths**

Add this idempotent Swift migration and call it immediately after `migrateToV9`:

```swift
public static func migrateToV10(_ obj: inout JSONObject) {
    obj.setDefault("approved_auto_replacements", .array([]))
    obj.setDefault("rejected_replacements", .array([]))
    obj.setDefault("replacement_policy_initialized", .bool(false))
    if schemaVersion(obj) < 10 {
        obj["schema_version"] = .int(10)
    }
}
```

Add the equivalent Python function, import/call it from `src/app.py`, and call it from `scripts/parity_config_bridge.py`:

```python
def migrate_config_to_v10(config: dict) -> dict:
    """Add durable automatic replacement approval and rejection state."""
    config.setdefault("approved_auto_replacements", [])
    config.setdefault("rejected_replacements", [])
    config.setdefault("replacement_policy_initialized", False)
    if config.get("schema_version", 1) < 10:
        config["schema_version"] = 10
    return config
```

Update all four Swift expected migration fixtures with schema 10 and the three exact default keys.

- [ ] **Step 6: Run migration suites and confirm GREEN**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSCore --filter ConfigMigrationTests
source venv/bin/activate && python -m pytest tests/test_vocab_provider.py tests/parity/test_parity_contract.py -q
```

Expected: all selected Swift and Python tests pass.

- [ ] **Step 7: Commit the schema migration**

```bash
git add Packages/CNSCore/Sources/CNSCore/ConfigMigrations.swift \
  Packages/CNSCore/Sources/CNSCore/Config.swift \
  Packages/CNSCore/Tests/CNSCoreTests/ConfigMigrationTests.swift \
  Packages/CNSCore/Tests/CNSCoreTests/Fixtures/migration_expected \
  src/utils.py src/app.py scripts/parity_config_bridge.py \
  tests/test_vocab_provider.py tests/parity/fixtures/config_schemas.json \
  tests/parity/test_parity_contract.py
git commit -m "feat: add replacement policy config schema"
```

---

### Task 2: Upgrade correction observations to schema 5 and enforce staleness

**Files:**
- Modify: `Packages/CNSDictionary/Sources/CNSDictionary/CorrectionAnalyzer.swift`
- Modify: `Packages/CNSDictionary/Tests/CNSDictionaryTests/CorrectionAnalyzerTests.swift`

**Interfaces:**
- Produces: `ReplacementPair.lastSeenRow: Int`
- Produces: `CorrectionAnalyzer.isReplacementPairStale(_:processedRows:now:) -> Bool`
- Produces: `CorrectionAnalyzer.pruneStaleReplacementPairs(in:now:) -> Int`
- Changes: `updateCorrectionsIndexThrowing(datasetPath:indexPath:now:pruneStale:)` with default `Date()` and `true` arguments
- Preserves: one observation per canonical pair per dataset row

- [ ] **Step 1: Write failing schema and boundary tests**

Add tests that construct deterministic dates and rows:

```swift
func testReplacementPairStalenessUsesEitherBoundary() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fresh = ReplacementPair(
        from: "Cogni", to: "Cognee", count: 2,
        lastSeen: ISOTimestamp.now(now.addingTimeInterval(-89 * 86_400)),
        lastSeenRow: 701
    )
    let oldByDate = ReplacementPair(
        from: "Drylabs", to: "Drylabz", count: 2,
        lastSeen: ISOTimestamp.now(now.addingTimeInterval(-90 * 86_400)),
        lastSeenRow: 999
    )
    let oldByRows = ReplacementPair(
        from: "continue", to: "Continue", count: 2,
        lastSeen: ISOTimestamp.now(now),
        lastSeenRow: 700
    )

    XCTAssertFalse(CorrectionAnalyzer.isReplacementPairStale(fresh, processedRows: 1_000, now: now))
    XCTAssertTrue(CorrectionAnalyzer.isReplacementPairStale(oldByDate, processedRows: 1_000, now: now))
    XCTAssertTrue(CorrectionAnalyzer.isReplacementPairStale(oldByRows, processedRows: 1_000, now: now))
}
```

Add a schema-4 rebuild test whose old index contains an inflated pair and whose two dataset rows contain the same correction. Assert schema 5, count 2, and `lastSeenRow == 2` after `updateCorrectionsIndexThrowing`.

- [ ] **Step 2: Run analyzer tests and confirm RED**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSDictionary --filter CorrectionAnalyzerTests
```

Expected: compile/test failure because `lastSeenRow` and staleness helpers do not exist.

- [ ] **Step 3: Implement schema 5 and row tracking**

Extend the model and coding keys:

```swift
public struct ReplacementPair: Codable, Sendable, Equatable {
    public var from: String
    public var to: String
    public var count: Int
    public var lastSeen: String
    public var lastSeenRow: Int
}
```

Set `CorrectionIndex.defaultIndex().schemaVersion` to 5. In `readIndex`, return a default index for any schema below 5 so the next update rebuilds from the append-only dataset. In `upsertReplacementPair`, set and refresh `lastSeenRow` from the already incremented `index.processedRows`.

Implement exact inclusive expiration boundaries:

```swift
public static func isReplacementPairStale(
    _ pair: ReplacementPair,
    processedRows: Int,
    now: Date
) -> Bool {
    let staleByRows = processedRows - pair.lastSeenRow >= 300
    guard let lastSeen = parseTimestamp(pair.lastSeen) else { return true }
    let staleByDate = now.timeIntervalSince(lastSeen) >= 90 * 86_400
    return staleByRows || staleByDate
}
```

`pruneStaleReplacementPairs` removes stale pairs from both script buckets and returns the removal count. Call it after processing new dataset records and before atomically writing the index when `pruneStale == true`. Expose `now: Date = Date()` and `pruneStale: Bool = true` on the update method for deterministic tests and the one-time migration exception.

- [ ] **Step 4: Run analyzer tests and confirm GREEN**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSDictionary --filter CorrectionAnalyzerTests
```

Expected: all analyzer tests pass, including schema rebuild and both expiry boundaries.

- [ ] **Step 5: Commit the observation schema**

```bash
git add Packages/CNSDictionary/Sources/CNSDictionary/CorrectionAnalyzer.swift \
  Packages/CNSDictionary/Tests/CNSDictionaryTests/CorrectionAnalyzerTests.swift
git commit -m "feat: expire stale replacement observations"
```

---

### Task 3: Add durable replacement policy and coordinator transitions

**Files:**
- Create: `Packages/CNSDictionary/Sources/CNSDictionary/ReplacementPolicy.swift`
- Modify: `Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift`
- Modify: `Packages/CNSDictionary/Tests/CNSDictionaryTests/DictionaryCoordinatorTests.swift`

**Interfaces:**
- Produces: `ReplacementRowState.active`, `.candidate`, `.readyForReview`, `.rejected`
- Produces: `ReplacementSections(active:candidates:rejected:)`
- Produces: `DictionaryCoordinator.replacementSections(languages:) -> ReplacementSections`
- Produces: `approveReplacement(_:)`, `rejectReplacement(_:)`, `restoreReplacement(_:)`
- Changes: `saveManualReplacements(_:)` to maintain tombstones and validate against approved targets
- Removes runtime dependence on physical pair deletion from `corrections.json`

- [ ] **Step 1: Write failing lifecycle tests**

Add helpers that write a schema-5 `CorrectionIndex` and tests for all states:

```swift
func testReplacementSectionsHideSinglesAndClassifyRepeatedPairs() throws {
    let paths = makePaths()
    try writeIndex([
        ReplacementPair(from: "once", to: "Once", count: 1, lastSeen: fixedTimestamp, lastSeenRow: 10),
        ReplacementPair(from: "twice", to: "Twice", count: 2, lastSeen: fixedTimestamp, lastSeenRow: 10),
        ReplacementPair(from: "thrice", to: "Thrice", count: 3, lastSeen: fixedTimestamp, lastSeenRow: 10),
    ], processedRows: 10, to: paths.correctionsFile)
    let coordinator = makeCoordinator(config: initializedConfig(), paths: paths, clock: { fixedDate })

    let sections = coordinator.replacementSections()

    XCTAssertEqual(sections.active.count, 0)
    XCTAssertEqual(sections.candidates.map(\.state), [.readyForReview, .candidate])
    XCTAssertFalse(sections.candidates.contains { $0.from == "once" })
}
```

Add separate tests proving:

- first upgrade initialization imports all and only `count >= 3` pairs and sets `replacement_policy_initialized` to true;
- a second coordinator initialization does not reseed a pair deleted after the first initialization;
- approve moves candidate to Active and persists `approved_auto_replacements`;
- reject survives a rewritten/rebuilt correction index;
- delete of a manual or approved row creates a rejection;
- restore removes rejection and creates approval;
- editing a manual pair rejects the old identity and clears a rejection matching the new identity;
- conflicting active targets throw `DictionaryCoordinatorError.conflictingReplacement`.

- [ ] **Step 2: Run coordinator tests and confirm RED**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSDictionary --filter DictionaryCoordinatorTests
```

Expected: compile failure because policy states, sections, and transitions are missing.

- [ ] **Step 3: Implement the focused policy model**

Create `ReplacementPolicy.swift` with these public view models:

```swift
public enum ReplacementRowState: String, Sendable, Equatable {
    case active
    case candidate
    case readyForReview
    case rejected
}

public struct ReplacementSections: Sendable, Equatable {
    public let active: [ReplacementRow]
    public let candidates: [ReplacementRow]
    public let rejected: [ReplacementRow]
}
```

Move `ReplacementRow` from `DictionaryCoordinator.swift` into this file and add `state: ReplacementRowState`. Add internal helpers that:

- parse and canonical-deduplicate `approved_auto_replacements` and `rejected_replacements`;
- serialize decisions with `approved_at` or `rejected_at`;
- compute the stable canonical pair key;
- derive active, candidate, ready-for-review, and rejected rows;
- sort candidates by readiness, descending count, then canonical source;
- resolve manual-over-approved exact duplicates.

- [ ] **Step 4: Implement one-time bootstrap and coordinator mutations**

At the end of `DictionaryCoordinator.init`, call a private synchronous `initializeReplacementPolicyIfNeeded()` after all stored properties are initialized.

The method must:

1. return immediately when `replacement_policy_initialized == true`;
2. call `CorrectionAnalyzer.updateCorrectionsIndexThrowing(..., pruneStale: false)` before reading pairs when either dataset or correction-index file exists;
3. seed every pair with `count >= 3` into approved decisions using the injected clock;
4. prune stale observations only after seeding and atomically persist the schema-5 index;
5. save the entire config atomically, then set the in-memory snapshot;
6. leave initialization false and log a privacy-safe error if reading or saving fails;
7. complete with an empty approval list when neither file exists.

For normal panel loads, `replacementSections(languages:)` calls the default pruning update before deriving rows, so a stale pair disappears even when no new dictation arrived since the last panel opening.

Implement the three transition methods through the existing `commit` method. Replace `removeAutomaticReplacement` with rejection-backed mutation; do not physically delete observations. Update `saveManualReplacements` by comparing canonical old and new sets, writing tombstones for removed identities, clearing tombstones for added identities, and rejecting source-target conflicts across manual and approved active pairs.

- [ ] **Step 5: Run coordinator tests and confirm GREEN**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSDictionary --filter DictionaryCoordinatorTests
```

Expected: all lifecycle, persistence, initialization, idempotency, and conflict tests pass.

- [ ] **Step 6: Commit policy state management**

```bash
git add Packages/CNSDictionary/Sources/CNSDictionary/ReplacementPolicy.swift \
  Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift \
  Packages/CNSDictionary/Tests/CNSDictionaryTests/DictionaryCoordinatorTests.swift
git commit -m "feat: persist replacement approval lifecycle"
```

---

### Task 4: Separate Gemini hints from direct replacements

**Files:**
- Modify: `Packages/CNSDictionary/Sources/CNSDictionary/VocabProvider.swift`
- Modify: `Packages/CNSDictionary/Tests/CNSDictionaryTests/VocabProviderTests.swift`
- Modify: `Packages/CNSSession/Sources/CNSSession/SessionController.swift`
- Modify: `Packages/CNSSession/Tests/CNSSessionTests/SessionControllerTests.swift`

**Interfaces:**
- Produces: `VocabProvider.collectDirectReplacements(config:languages:cap:) -> [(String, String)]`
- Produces: `VocabProvider.collectEditorHints(config:languages:cap:correctionsURL:now:) -> [(String, String)]`
- Preserves: `applyReplacements(_:pairs:)` matching and non-cascading behavior
- Preserves: editor method argument name `misrecognitions`; only its provider changes

- [ ] **Step 1: Write failing provider tests**

Add tests with manual, approved, rejected, count-one, count-two, count-three, and stale pairs:

```swift
func testDirectReplacementsContainOnlyManualAndApprovedPairs() throws {
    let config = replacementConfig(
        manual: [("ap eye", "API")],
        approved: [("Cogni", "Cognee")],
        rejected: []
    )
    let result = VocabProvider.collectDirectReplacements(config: .object(config.raw))
    XCTAssertEqual(result.map(\.0), ["ap eye", "Cogni"])
}

func testEditorHintsIncludeCountTwoAndExcludeRejectedStaleAndSingles() throws {
    let result = VocabProvider.collectEditorHints(
        config: .object(configWithRejectedDrylabs.raw),
        correctionsURL: correctionsURL,
        now: fixedDate
    )
    XCTAssertTrue(result.contains { $0.0 == "Cogni" && $0.1 == "Cognee" })
    XCTAssertFalse(result.contains { $0.0 == "Drylabs" })
    XCTAssertFalse(result.contains { $0.0 == "single" })
    XCTAssertFalse(result.contains { $0.0 == "stale" })
}
```

Also assert priority ordering `manual → approved → observed`, deterministic candidate ordering, exact deduplication, language filtering, and the existing cap of 30.

- [ ] **Step 2: Run provider tests and confirm RED**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSDictionary --filter VocabProviderTests
```

Expected: compile failure because the two explicit provider queries do not exist.

- [ ] **Step 3: Implement the two provider queries**

`collectDirectReplacements` reads no correction observations. It combines manual tuples with approved decisions, gives manual exact duplicates precedence, rejects conflicting duplicate sources deterministically, and applies the requested cap.

`collectEditorHints` starts with direct replacements, then reads schema-5 observations and appends only pairs that satisfy all of these conditions:

```swift
pair.count >= 2
    && !CorrectionAnalyzer.isReplacementPairStale(pair, processedRows: index.processedRows, now: now)
    && !rejectedKeys.contains(ReplacementPolicy.key(from: pair.from, to: pair.to))
```

Keep `collectMisrecognitions` only as a deprecated internal forwarding wrapper to `collectEditorHints` if an unchanged test or package consumer still references it; all application call sites must use the explicit names.

- [ ] **Step 4: Write failing session integration tests**

Add a fixture correction index with an unapproved count-five pair and set `replacement_policy_initialized = true` so bootstrap cannot approve it. Assert:

```swift
@Test("Unapproved automatic pair never changes fallback text")
func unapprovedAutomaticPairIsHintOnly() async {
    let rig = makeReplacementRig(
        source: "Cogni stores memory",
        observed: ("Cogni", "Cognee", 5),
        approved: [],
        editorStatus: .disabled
    )
    await runSession(rig)
    #expect(rig.panel.shownText == "Cogni stores memory")
}

@Test("Approved automatic pair changes eligible fallback text")
func approvedAutomaticPairApplies() async {
    let rig = makeReplacementRig(
        source: "Cogni stores memory",
        observed: ("Cogni", "Cognee", 5),
        approved: [("Cogni", "Cognee")],
        editorStatus: .disabled
    )
    await runSession(rig)
    #expect(rig.panel.shownText == "Cognee stores memory")
}
```

Capture the `misrecognitions` passed to `FakeAiEditor` and assert a count-two candidate reaches a cloud editor while the same pair does not modify local fallback output.

- [ ] **Step 5: Run session tests and confirm RED**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSSession --filter SessionControllerTests
```

Expected: unapproved count-three-or-higher observations are still applied directly by the current implementation.

- [ ] **Step 6: Switch all realtime and file-transcription call sites**

In both `finalize(sessionId:)` and `transcribeFile(url:refine:progress:)`:

- pass `collectEditorHints` to the AI editor;
- pass `collectDirectReplacements` to `applyReplacements`;
- retain `shouldApplyDirectReplacements(after:hintsInPrompt:)` unchanged.

- [ ] **Step 7: Run provider and session suites and confirm GREEN**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSDictionary
swift test --disable-index-store --package-path Packages/CNSSession
```

Expected: both package suites pass; direct replacement and Gemini hint behavior are independently covered.

- [ ] **Step 8: Commit runtime policy separation**

```bash
git add Packages/CNSDictionary/Sources/CNSDictionary/VocabProvider.swift \
  Packages/CNSDictionary/Tests/CNSDictionaryTests/VocabProviderTests.swift \
  Packages/CNSSession/Sources/CNSSession/SessionController.swift \
  Packages/CNSSession/Tests/CNSSessionTests/SessionControllerTests.swift
git commit -m "feat: separate editor hints from direct replacements"
```

---

### Task 5: Build the Active, Candidates, and Rejected UI

**Files:**
- Modify: `Packages/CNSUI/Sources/CNSUI/ReplacementsPanel.swift`
- Modify: `Packages/CNSUI/Tests/CNSUITests/UIPanelsTests.swift`
- Modify: `locales/en.json`
- Modify: `locales/ru.json`
- Modify: `locales/uk.json`
- Modify: `locales/de.json`
- Modify: `locales/es.json`
- Modify: `locales/fr.json`

**Interfaces:**
- Consumes: `ReplacementSections` and coordinator approve/reject/restore transitions
- Produces testing accessors: active/candidate/rejected counts and rejected-section expansion state
- Preserves: resizable `NSWindow`, manual add/edit form, main-thread coordinator ownership

- [ ] **Step 1: Write failing UI model tests**

Extend `UIPanelsTests` with a coordinator whose schema-5 index has one count-one, one count-two, and one count-three pair; put one pair in each durable policy list. Verify:

```swift
XCTAssertEqual(panel.activeReplacementCountForTesting, 2)
XCTAssertEqual(panel.candidateReplacementCountForTesting, 2)
XCTAssertEqual(panel.rejectedReplacementCountForTesting, 1)
XCTAssertFalse(panel.isRejectedSectionExpandedForTesting)
```

Add action tests through narrow panel testing methods:

```swift
panel.approveReplacementForTesting(from: "twice", to: "Twice")
XCTAssertTrue(coordinator.replacementSections().active.contains { $0.from == "twice" })

panel.rejectReplacementForTesting(from: "thrice", to: "Thrice")
XCTAssertTrue(coordinator.replacementSections().rejected.contains { $0.from == "thrice" })

panel.restoreReplacementForTesting(from: "blocked", to: "Blocked")
XCTAssertTrue(coordinator.replacementSections().active.contains { $0.from == "blocked" })
```

- [ ] **Step 2: Run UI tests and confirm RED**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSUI --filter UIPanelsTests
```

Expected: compile failure because section counts and actions do not exist.

- [ ] **Step 3: Refactor the view model around replacement sections**

Replace the single `rows` property with:

```swift
@Published private(set) var sections = ReplacementSections(active: [], candidates: [], rejected: [])
@Published var isRejectedExpanded = false
```

Keep drafts only for manual active rows. Wire candidate buttons to `approveReplacement` and `rejectReplacement`; wire active deletion to rejection-backed coordinator removal; wire restore to `restoreReplacement`. Reload sections after every successful mutation while preserving the rejected expansion state during routine refresh.

- [ ] **Step 4: Render the three sections**

Use one scrollable `List` with `Section` headers for Active and Candidates plus a collapsed `DisclosureGroup` for Rejected. Required behavior:

- Active shows editable manual rows and read-only approved automatic rows.
- Candidates shows a count badge, `candidate` at count two, and `ready for review` at count three or higher.
- Rejected starts collapsed, shows a count in its label, and provides Restore.
- The empty state appears only when all three sections are empty.
- Count-one observations never enter the view model.
- Accessibility identifiers use stable canonical row IDs and action suffixes such as `.approve`, `.reject`, and `.restore`.

- [ ] **Step 5: Replace stale copy in all six locales**

Add the same key set to every locale, with matching `{c}` and `{n}` placeholders:

```text
replacements.section_active
replacements.section_candidates
replacements.section_rejected
replacements.badge_candidate
replacements.badge_ready
replacements.action_approve
replacements.action_reject
replacements.action_restore
replacements.empty_active
replacements.empty_candidates
replacements.empty_rejected
```

Update `replacements.description` so it states that only active pairs replace text, while candidates are learned from popup corrections. Remove wording about toggles and “Delete Selected,” which no longer describes the Swift UI.

- [ ] **Step 6: Run UI and locale coverage tests and confirm GREEN**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSUI
```

Expected: panel lifecycle tests and `completeUILocaleCoverage` pass for all six catalogs.

- [ ] **Step 7: Commit the replacement review UI**

```bash
git add Packages/CNSUI/Sources/CNSUI/ReplacementsPanel.swift \
  Packages/CNSUI/Tests/CNSUITests/UIPanelsTests.swift \
  locales/en.json locales/ru.json locales/uk.json \
  locales/de.json locales/es.json locales/fr.json
git commit -m "feat: add replacement approval interface"
```

---

### Task 6: Verify, review, migrate the development data, and rebuild the app

**Files:**
- Modify if architecture changed: `AGENTS.md` (ignored by Git; update through the project skill)
- Build artifact: `dist/swift/Click-n-speak.app`
- Runtime data, changed only by launching the completed app: `~/Library/Application Support/Click-n-speak/config.json`
- Runtime data, rebuilt only by launching the completed app: `~/Library/Application Support/Click-n-speak/corrections.json`

**Interfaces:**
- Consumes: every preceding task
- Produces: verified and signed development application bundle
- Produces runtime result: four current count-three-or-higher pairs active; count-two pairs candidates; count-one pairs hidden

- [ ] **Step 1: Run focused regression suites**

Run:

```bash
swift test --disable-index-store --package-path Packages/CNSCore
swift test --disable-index-store --package-path Packages/CNSDictionary
swift test --disable-index-store --package-path Packages/CNSSession
swift test --disable-index-store --package-path Packages/CNSUI
source venv/bin/activate && python -m pytest tests/test_vocab_provider.py tests/parity/test_parity_contract.py -q
```

Expected: all commands exit 0.

- [ ] **Step 2: Run the complete Swift verification gate**

Run:

```bash
bash scripts/swift_verify.sh
```

Expected final line: `Swift verification passed`.

- [ ] **Step 3: Request an independent code review and resolve findings**

Use the `requesting-code-review` skill against the complete diff from `198ad06` to `HEAD`. Address every confirmed correctness, persistence, threading, migration, and test-coverage finding. Re-run the smallest affected package suite after each fix.

- [ ] **Step 4: Re-run the complete verification gate after review fixes**

Run:

```bash
bash scripts/swift_verify.sh
```

Expected final line: `Swift verification passed` with no uncommitted source fixes left.

- [ ] **Step 5: Build and verify the application bundle**

Run:

```bash
bash scripts/swift_build_app.sh
```

Expected:

```text
==> Built and verified /Users/sergej/Click-n-speak/dist/swift/Click-n-speak.app
```

The development build intentionally resets TCC through the existing build script; report this explicitly to the user.

- [ ] **Step 6: Launch once and validate the one-time runtime migration**

Launch the newly built app once, then inspect only replacement-policy metadata with a redacting query. Verify:

- `schema_version == 10`;
- `replacement_policy_initialized == true`;
- the approved list contains exactly the four user-approved current pairs;
- the UI model contains the twelve current count-two candidates;
- no count-one observation is visible;
- the rejected list survives a restart smoke test.

Do not print phrase history, raw transcript fields, prompt contents, or unrelated config values.

- [ ] **Step 7: Commit review fixes if any exist**

```bash
git diff --name-only
git add Packages/CNSCore/Sources/CNSCore/Config.swift \
  Packages/CNSCore/Sources/CNSCore/ConfigMigrations.swift \
  Packages/CNSDictionary/Sources/CNSDictionary/CorrectionAnalyzer.swift \
  Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift \
  Packages/CNSDictionary/Sources/CNSDictionary/ReplacementPolicy.swift \
  Packages/CNSDictionary/Sources/CNSDictionary/VocabProvider.swift \
  Packages/CNSSession/Sources/CNSSession/SessionController.swift \
  Packages/CNSUI/Sources/CNSUI/ReplacementsPanel.swift
git commit -m "fix: harden replacement lifecycle"
```

Skip this commit when the review produced no source changes. Confirm `git status --short` is empty before handoff.
