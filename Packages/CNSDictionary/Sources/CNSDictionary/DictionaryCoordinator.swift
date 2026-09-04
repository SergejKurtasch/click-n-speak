import CNSCore
import Foundation

public struct DictionaryInvalidations: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let config = DictionaryInvalidations(rawValue: 1 << 0)
    public static let history = DictionaryInvalidations(rawValue: 1 << 1)
    public static let terms = DictionaryInvalidations(rawValue: 1 << 2)
    public static let suggestions = DictionaryInvalidations(rawValue: 1 << 3)
    public static let replacements = DictionaryInvalidations(rawValue: 1 << 4)
    public static let metrics = DictionaryInvalidations(rawValue: 1 << 5)
}

public struct DictionaryConfirmation: Sendable {
    public let sessionID: Int
    public let datasetRecord: DatasetRecord
    public let finalText: String
    public let date: Date

    public init(sessionID: Int, datasetRecord: DatasetRecord, finalText: String, date: Date = Date()) {
        self.sessionID = sessionID
        self.datasetRecord = datasetRecord
        self.finalText = finalText
        self.date = date
    }
}

public struct ConfirmationPersistenceResult: Sendable, Equatable {
    public let duplicate: Bool
    public let datasetSaved: Bool
    public let correctionsUpdated: Bool
    public let historySaved: Bool

    public init(
        duplicate: Bool = false,
        datasetSaved: Bool = false,
        correctionsUpdated: Bool = false,
        historySaved: Bool = false
    ) {
        self.duplicate = duplicate
        self.datasetSaved = datasetSaved
        self.correctionsUpdated = correctionsUpdated
        self.historySaved = historySaved
    }
}

public struct DictionaryTerm: Sendable, Equatable, Identifiable {
    public var id: String { "\(language)||\(TermCanonicalizer.canonicalKey(term))" }
    public let language: String
    public let term: String
    public let source: String
    public let addedAt: String?
    public let lastSeen: String?
    public let useCount: Int
    public let inactive: Bool
}

public struct DictionaryNotification: Sendable, Equatable {
    public let titleKey: String
    public let bodyKey: String
}

private actor DictionaryPersistenceWorker {
    private let paths: Paths
    private let phraseHistory: any PhraseHistoryProviding
    private let datasetLogger: DatasetLogger
    private let log: @Sendable (String) -> Void

    init(
        paths: Paths,
        phraseHistory: any PhraseHistoryProviding,
        datasetLogger: DatasetLogger,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.paths = paths
        self.phraseHistory = phraseHistory
        self.datasetLogger = datasetLogger
        self.log = log
    }

    func record(_ confirmation: DictionaryConfirmation) -> ConfirmationPersistenceResult {
        let datasetSaved = datasetLogger.append(confirmation.datasetRecord, at: confirmation.date)
        var correctionsUpdated = false
        if datasetSaved {
            do {
                _ = try CorrectionAnalyzer.updateCorrectionsIndexThrowing(
                    datasetPath: paths.datasetFile,
                    indexPath: paths.correctionsFile
                )
                correctionsUpdated = true
            } catch {
                log("Correction index update failed after session \(confirmation.sessionID): \(error.localizedDescription)")
            }
        }
        let historySaved = confirmation.finalText.isEmpty
            ? false
            : phraseHistory.append(confirmation.finalText, at: confirmation.date)
        return ConfirmationPersistenceResult(
            datasetSaved: datasetSaved,
            correctionsUpdated: correctionsUpdated,
            historySaved: historySaved
        )
    }

    func analyzePromptCandidates(
        existing: [String: Set<String>],
        skipped: [String: [String: Int]],
        minimum: [String: Int],
        lookback: Int,
        now: Date
    ) throws -> PromptAnalysisOutput {
        let currentCount = phraseHistory.count()
        let index = try CorrectionAnalyzer.updateCorrectionsIndexThrowing(
            datasetPath: paths.datasetFile,
            indexPath: paths.correctionsFile
        )
        let corrections = CorrectionAnalyzer.getCorrectionCandidates(
            index: index,
            existingLowerByLang: existing,
            skippedLowerByLang: skipped,
            currentPhraseCount: currentCount,
            minCorrectionCount: minimum,
            cooldownPhrases: 150,
            maxPerLang: 15,
            now: now
        )
        let insertedKeys = Set(index.insertedTerms.values.flatMap(\.keys))
        let frequency = LogAnalyzer.getPromptCandidates(
            phraseHistory: phraseHistory,
            lookback: lookback,
            minCount: minimum,
            existingLowerByLang: existing,
            skippedLowerByLang: skipped,
            currentPhraseCount: currentCount,
            cooldownPhrases: 150,
            maxPerLang: 15,
            hasCorrectionSignal: { insertedKeys.contains($0) }
        )
        return PromptAnalysisOutput(
            currentPhraseCount: currentCount,
            corrections: corrections,
            frequency: frequency
        )
    }
}

private struct PromptAnalysisOutput: Sendable {
    let currentPhraseCount: Int
    let corrections: [String: [TermCandidate]]
    let frequency: [String: [TermCandidate]]
}

@MainActor
public protocol DictionaryCoordinating: AnyObject {
    var snapshot: Config { get }
    var correctionsURL: URL { get }
    func recordConfirmation(_ confirmation: DictionaryConfirmation) async -> ConfirmationPersistenceResult
    func addManualTerm(_ term: String, language: String) -> Bool
}

public enum DictionaryCoordinatorError: LocalizedError {
    case invalidTerm
    case duplicateTerm
    case termNotFound
    case suggestionNotFound
    case noSnapshot
    case invalidReplacement
    case conflictingReplacement

    public var errorDescription: String? {
        switch self {
        case .invalidTerm: "The dictionary term is invalid"
        case .duplicateTerm: "The dictionary term already exists"
        case .termNotFound: "The dictionary term was not found"
        case .suggestionNotFound: "The suggestion was not found"
        case .noSnapshot: "No previous dictionary snapshot is available"
        case .invalidReplacement: "Both replacement values are required"
        case .conflictingReplacement: "One source phrase cannot have multiple replacement targets"
        }
    }
}

/// Single serialized owner for every dictionary/config mutation. Panels emit
/// intents into this object and receive immutable snapshots back; no UI object
/// writes raw config or corrections JSON independently.
@MainActor
public final class DictionaryCoordinator: DictionaryCoordinating {
    public private(set) var snapshot: Config
    public var correctionsURL: URL { paths.correctionsFile }
    public var onSnapshotChanged: ((Config, DictionaryInvalidations) -> Void)?
    public var onNotification: ((DictionaryNotification) -> Void)?
    public private(set) var latestMetricsSnapshot: JSONObject?

    private let paths: Paths
    private let phraseHistory: any PhraseHistoryProviding
    private let persistenceWorker: DictionaryPersistenceWorker
    private let promptBuilder: InitialPromptBuilder
    private let clock: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private var dirty = false
    private var processedSessionIDs = Set<Int>()
    private var analysisRunning = false
    private var maintenanceRunning = false
    private var lastFastPathProcessedRows = 0

    private lazy var promptSynchronizer = PromptFileSynchronizer(
        paths: paths,
        activeLanguages: { [weak self] in self?.activeLanguages() ?? [] },
        onExternalChange: { [weak self] language, text in
            do {
                _ = try self?.importPromptText(text, language: language)
            } catch {
                self?.log("Prompt import failed for \(language): \(error.localizedDescription)")
            }
        },
        log: log
    )

    public init(
        config: Config,
        paths: Paths,
        phraseHistory: any PhraseHistoryProviding,
        datasetLogger: DatasetLogger? = nil,
        promptBuilder: InitialPromptBuilder = InitialPromptBuilder(),
        clock: @escaping @Sendable () -> Date = Date.init,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.snapshot = config
        self.paths = paths
        self.phraseHistory = phraseHistory
        let resolvedDatasetLogger = datasetLogger ?? DatasetLogger(fileURL: paths.datasetFile, log: log)
        self.persistenceWorker = DictionaryPersistenceWorker(
            paths: paths,
            phraseHistory: phraseHistory,
            datasetLogger: resolvedDatasetLogger,
            log: log
        )
        self.promptBuilder = promptBuilder
        self.clock = clock
        self.log = log
        initializeReplacementPolicyIfNeeded()
    }

    public func startPromptWatching() {
        for language in activeLanguages() {
            let url = paths.initialPromptFile(lang: language)
            if !FileManager.default.fileExists(atPath: url.path) {
                do { try promptSynchronizer.write(language: language, terms: termStrings(language: language)) }
                catch { log("Initial prompt file creation failed for \(language): \(error.localizedDescription)") }
            }
        }
        promptSynchronizer.start()
    }

    public func stop() {
        promptSynchronizer.stop()
        do { try flushIfNeeded() }
        catch { log("Final dictionary flush failed: \(error.localizedDescription)") }
    }

    /// Keep this owner aligned after the runtime coordinator persists a menu or
    /// launch-time setting. No callbacks or writes are emitted, preventing an
    /// ownership loop between the two coordinators.
    public func adoptConfiguration(_ config: Config) {
        snapshot = config
        dirty = false
        promptSynchronizer.prime()
    }

    @discardableResult
    public func recordConfirmation(_ confirmation: DictionaryConfirmation) async -> ConfirmationPersistenceResult {
        guard processedSessionIDs.insert(confirmation.sessionID).inserted else {
            return ConfirmationPersistenceResult(duplicate: true)
        }

        let persisted = await persistenceWorker.record(confirmation)

        guard !confirmation.finalText.isEmpty else {
            return persisted
        }

        var updated = snapshot
        if UserTerms.updateUsage(in: &updated, phrase: confirmation.finalText, now: confirmation.date) {
            updated.raw["initial_prompt"] = .string(promptBuilder.build(config: updated.raw))
            snapshot = updated
            dirty = true
            publish([.config, .terms])
        }
        if persisted.historySaved { publish(.history) }
        schedulePromptAnalysisIfDue()
        return persisted
    }

    @discardableResult
    public func addManualTerm(_ term: String, language: String) -> Bool {
        var candidate = snapshot
        guard UserTerms.add(
            to: &candidate,
            lang: language,
            term: term,
            source: .manual,
            now: ISOTimestamp.now(clock())
        ) else { return false }
        do {
            try commit(candidate, promptLanguages: [LanguageCode.normalize(language)], invalidations: [.terms])
            return true
        } catch {
            log("Add-to-dictionary persistence failed: \(error.localizedDescription)")
            return false
        }
    }

    public func terms() -> [DictionaryTerm] {
        guard let byLanguage = snapshot.raw["user_terms"]?.objectValue else { return [] }
        var result: [DictionaryTerm] = []
        for language in byLanguage.keys.sorted() {
            for item in byLanguage[language]?.arrayValue ?? [] {
                let object = item.objectValue
                let term = UserTerms.termString(item)
                guard !term.isEmpty else { continue }
                result.append(DictionaryTerm(
                    language: language,
                    term: term,
                    source: object?["source"]?.stringValue ?? "manual",
                    addedAt: object?["added_at"]?.stringValue,
                    lastSeen: object?["last_seen"]?.stringValue,
                    useCount: Int(object?["use_count"]?.intValue ?? 0),
                    inactive: object?["inactive"]?.isTruthy == true
                ))
            }
        }
        return result
    }

    public func deleteTerm(language: String, term: String) throws {
        let lang = LanguageCode.normalize(language)
        var candidate = snapshot
        var byLanguage = candidate.raw["user_terms"]?.objectValue ?? JSONObject()
        var items = byLanguage[lang]?.arrayValue ?? []
        let key = TermCanonicalizer.canonicalKey(term)
        let before = items.count
        items.removeAll { TermCanonicalizer.canonicalKey(UserTerms.termString($0)) == key }
        guard items.count != before else { throw DictionaryCoordinatorError.termNotFound }
        byLanguage[lang] = .array(items)
        candidate.raw["user_terms"] = .object(byLanguage)
        try commit(candidate, promptLanguages: [lang], invalidations: [.terms])
    }

    public func editTerm(language: String, oldTerm: String, newTerm: String) throws {
        let lang = LanguageCode.normalize(language)
        let clean = UserTerms.sanitize(newTerm)
        guard TermParsing.isValidTerm(clean) else { throw DictionaryCoordinatorError.invalidTerm }
        var candidate = snapshot
        var byLanguage = candidate.raw["user_terms"]?.objectValue ?? JSONObject()
        var items = byLanguage[lang]?.arrayValue ?? []
        let oldKey = TermCanonicalizer.canonicalKey(oldTerm)
        let newKey = TermCanonicalizer.canonicalKey(clean)
        guard !items.contains(where: {
            let key = TermCanonicalizer.canonicalKey(UserTerms.termString($0))
            return key == newKey && key != oldKey
        }) else { throw DictionaryCoordinatorError.duplicateTerm }
        guard let index = items.firstIndex(where: {
            TermCanonicalizer.canonicalKey(UserTerms.termString($0)) == oldKey
        }) else { throw DictionaryCoordinatorError.termNotFound }
        saveSnapshot(in: &candidate, language: lang, items: items)
        if var object = items[index].objectValue {
            object["term"] = .string(clean)
            object["source"] = .string("manual")
            object.remove("inactive")
            items[index] = .object(object)
        } else {
            items[index] = makeTermItem(clean, source: "manual", useCount: 0)
        }
        byLanguage[lang] = .array(items)
        candidate.raw["user_terms"] = .object(byLanguage)
        try commit(candidate, promptLanguages: [lang], invalidations: [.terms])
    }

    public func reactivateTerm(language: String, term: String) throws {
        let lang = LanguageCode.normalize(language)
        var candidate = snapshot
        var byLanguage = candidate.raw["user_terms"]?.objectValue ?? JSONObject()
        var items = byLanguage[lang]?.arrayValue ?? []
        let key = TermCanonicalizer.canonicalKey(term)
        guard let index = items.firstIndex(where: {
            TermCanonicalizer.canonicalKey(UserTerms.termString($0)) == key
        }), var object = items[index].objectValue else { throw DictionaryCoordinatorError.termNotFound }
        object.remove("inactive")
        object["last_seen"] = .string(ISOTimestamp.now(clock()))
        items[index] = .object(object)
        byLanguage[lang] = .array(items)
        candidate.raw["user_terms"] = .object(byLanguage)
        try commit(candidate, promptLanguages: [lang], invalidations: [.terms])
    }

    public func revert(language: String? = nil) throws {
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
    }

    @discardableResult
    public func importPromptText(_ text: String, language: String) throws -> Bool {
        let lang = LanguageCode.normalize(language)
        var candidate = snapshot
        var byLanguage = candidate.raw["user_terms"]?.objectValue ?? JSONObject()
        let previous = byLanguage[lang]?.arrayValue ?? []
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty, !previous.isEmpty { return false }
        let parsed = PromptTerms.parse(stripped)
        if previous.map(UserTerms.termString) == parsed { return false }

        var existing: [String: JSONValue] = [:]
        for item in previous {
            let key = TermCanonicalizer.canonicalKey(UserTerms.termString(item))
            if !key.isEmpty, existing[key] == nil { existing[key] = item }
        }
        let newItems = parsed.map { term in
            existing[TermCanonicalizer.canonicalKey(term)]
                ?? makeTermItem(term, source: "manual", useCount: 0)
        }
        if !previous.isEmpty { saveSnapshot(in: &candidate, language: lang, items: previous) }
        byLanguage[lang] = .array(newItems)
        candidate.raw["user_terms"] = .object(byLanguage)
        try commit(candidate, promptLanguages: [lang], invalidations: [.terms])
        return true
    }

    public func pendingSuggestions() -> [String: [TermCandidate]] {
        guard let pending = snapshot.raw["pending_suggestions"]?.objectValue else { return [:] }
        var result: [String: [TermCandidate]] = [:]
        for language in pending.keys {
            let decoded = (pending[language]?.arrayValue ?? []).compactMap(Self.decodeCandidate)
            if !decoded.isEmpty { result[language] = decoded }
        }
        return result
    }

    public func acceptSuggestion(language: String, term: String) throws {
        let lang = LanguageCode.normalize(language)
        try resolveSuggestions(accepting: [lang: [term]], rejecting: [:])
    }

    public func rejectSuggestion(language: String, term: String) throws {
        let lang = LanguageCode.normalize(language)
        try resolveSuggestions(accepting: [:], rejecting: [lang: [term]])
    }

    /// Applies one review decision in a single config transaction. This keeps
    /// UI refresh callbacks from changing the selection while it is processed.
    public func resolveSuggestions(
        accepting accepted: [String: Set<String>],
        rejecting rejected: [String: Set<String>]
    ) throws {
        let pending = pendingSuggestions()
        let acceptedKeys = Dictionary(uniqueKeysWithValues: accepted.map { language, terms in
            (LanguageCode.normalize(language), Set(terms.map(TermCanonicalizer.canonicalKey)))
        })
        let rejectedKeys = Dictionary(uniqueKeysWithValues: rejected.map { language, terms in
            (LanguageCode.normalize(language), Set(terms.map(TermCanonicalizer.canonicalKey)))
        })
        guard !acceptedKeys.isEmpty || !rejectedKeys.isEmpty else { return }

        var candidate = snapshot
        var skipped = candidate.raw["skipped_terms"]?.objectValue ?? JSONObject()
        var acceptedLanguages = Set<String>()
        var resolvedCount = 0
        let currentPhraseCount = phraseHistory.count()

        for (language, items) in pending {
            let lang = LanguageCode.normalize(language)
            let accepting = acceptedKeys[lang] ?? []
            let rejecting = rejectedKeys[lang] ?? []
            var skippedBucket = skipped[lang]?.objectValue ?? JSONObject()

            for item in items {
                let key = TermCanonicalizer.canonicalKey(item.term)
                if accepting.contains(key) {
                    addCandidate(item, language: lang, to: &candidate)
                    removePending(term: item.term, language: lang, from: &candidate)
                    acceptedLanguages.insert(lang)
                    resolvedCount += 1
                } else if rejecting.contains(key) {
                    skippedBucket[key] = .int(Int64(currentPhraseCount))
                    removePending(term: item.term, language: lang, from: &candidate)
                    resolvedCount += 1
                }
            }

            if !skippedBucket.keys.isEmpty { skipped[lang] = .object(skippedBucket) }
        }

        guard resolvedCount > 0 else { throw DictionaryCoordinatorError.suggestionNotFound }
        candidate.raw["skipped_terms"] = .object(skipped)
        var invalidations: DictionaryInvalidations = [.suggestions]
        if !acceptedLanguages.isEmpty { invalidations.insert(.terms) }
        try commit(candidate, promptLanguages: acceptedLanguages, invalidations: invalidations)
    }

    public func addAllPendingSuggestions() throws {
        let pending = pendingSuggestions()
        guard !pending.isEmpty else { return }
        var candidate = snapshot
        for (language, items) in pending {
            for item in items { addCandidate(item, language: language, to: &candidate) }
        }
        candidate.raw["pending_suggestions"] = .object(JSONObject())
        try commit(
            candidate,
            promptLanguages: Set(pending.keys),
            invalidations: [.terms, .suggestions]
        )
    }

    public func setPromptUpdateMode(_ mode: String) throws {
        guard ["suggest", "auto", "disabled"].contains(mode) else { return }
        var candidate = snapshot
        candidate.raw["prompt_update_mode"] = .string(mode)
        try commit(candidate, promptLanguages: [], invalidations: [.suggestions])
    }

    public func replacementSections(languages: [String]? = nil) -> ReplacementSections {
        let allowedScripts = languages.map { Set($0.map(VocabProvider.getLanguageScript)) }
            ?? Set(["latin", "cyrillic"])
        var index = CorrectionAnalyzer.readIndex(at: paths.correctionsFile)
        if CorrectionAnalyzer.pruneStaleReplacementPairs(in: &index, now: clock()) > 0 {
            do { try CorrectionAnalyzer.writeIndex(index, to: paths.correctionsFile) }
            catch { log("Replacement observation pruning failed: \(error.localizedDescription)") }
        }

        var observationByKey: [String: (ReplacementPair, String)] = [:]
        for bucket in allowedScripts {
            for pair in index.replacementPairs[bucket] ?? [] {
                observationByKey[ReplacementPolicy.key(from: pair.from, to: pair.to)] = (pair, bucket)
            }
        }

        let manual = ReplacementPolicy.decisions(
            in: snapshot,
            key: "manual_replacements",
            timestampKey: "added_at"
        )
        let approved = ReplacementPolicy.decisions(
            in: snapshot,
            key: ReplacementPolicy.approvedKey,
            timestampKey: "approved_at"
        )
        let rejected = ReplacementPolicy.decisions(
            in: snapshot,
            key: ReplacementPolicy.rejectedKey,
            timestampKey: "rejected_at"
        )
        let rejectedKeys = Set(rejected.map { ReplacementPolicy.key(from: $0.from, to: $0.to) })

        var active: [ReplacementRow] = []
        var activeKeys = Set<String>()
        var activeSourceKeys = Set<String>()
        for decision in manual {
            let identity = ReplacementPolicy.key(from: decision.from, to: decision.to)
            guard !rejectedKeys.contains(identity), activeKeys.insert(identity).inserted else { continue }
            activeSourceKeys.insert(ReplacementPolicy.sourceKey(decision.from))
            let observation = observationByKey[identity]
            active.append(ReplacementRow(
                source: "manual",
                bucket: observation?.1 ?? ReplacementPolicy.bucket(for: decision.from),
                from: decision.from,
                to: decision.to,
                count: observation?.0.count ?? 0,
                lastSeen: observation?.0.lastSeen,
                addedAt: decision.timestamp,
                state: .active
            ))
        }
        for decision in approved {
            let identity = ReplacementPolicy.key(from: decision.from, to: decision.to)
            let sourceIdentity = ReplacementPolicy.sourceKey(decision.from)
            guard !rejectedKeys.contains(identity), !activeSourceKeys.contains(sourceIdentity),
                  activeKeys.insert(identity).inserted else { continue }
            activeSourceKeys.insert(sourceIdentity)
            let observation = observationByKey[identity]
            active.append(ReplacementRow(
                source: "auto",
                bucket: observation?.1 ?? ReplacementPolicy.bucket(for: decision.from),
                from: decision.from,
                to: decision.to,
                count: observation?.0.count ?? 0,
                lastSeen: observation?.0.lastSeen,
                addedAt: decision.timestamp,
                state: .active
            ))
        }

        var candidates: [ReplacementRow] = []
        for (identity, observation) in observationByKey {
            let pair = observation.0
            guard pair.count >= 2, !activeKeys.contains(identity), !rejectedKeys.contains(identity) else { continue }
            candidates.append(ReplacementRow(
                source: "auto",
                bucket: observation.1,
                from: pair.from,
                to: pair.to,
                count: pair.count,
                lastSeen: pair.lastSeen,
                addedAt: nil,
                state: pair.count >= 3 ? .readyForReview : .candidate
            ))
        }
        candidates.sort {
            if $0.state != $1.state { return $0.state == .readyForReview }
            if $0.count != $1.count { return $0.count > $1.count }
            return ReplacementPolicy.key(from: $0.from, to: $0.to)
                < ReplacementPolicy.key(from: $1.from, to: $1.to)
        }

        let rejectedRows = rejected.map { decision in
            let identity = ReplacementPolicy.key(from: decision.from, to: decision.to)
            let observation = observationByKey[identity]
            return ReplacementRow(
                source: "auto",
                bucket: observation?.1 ?? ReplacementPolicy.bucket(for: decision.from),
                from: decision.from,
                to: decision.to,
                count: observation?.0.count ?? 0,
                lastSeen: observation?.0.lastSeen,
                addedAt: decision.timestamp,
                state: .rejected
            )
        }
        return ReplacementSections(active: active, candidates: candidates, rejected: rejectedRows)
    }

    public func replacementRows(languages: [String]? = nil) -> [ReplacementRow] {
        let sections = replacementSections(languages: languages)
        return sections.active + sections.candidates
    }

    public func saveManualReplacements(_ pairs: [(String, String)]) throws {
        let previous = ReplacementPolicy.decisions(
            in: snapshot,
            key: "manual_replacements",
            timestampKey: "added_at"
        )
        let approved = ReplacementPolicy.decisions(
            in: snapshot,
            key: ReplacementPolicy.approvedKey,
            timestampKey: "approved_at"
        )
        var rejected = ReplacementPolicy.decisions(
            in: snapshot,
            key: ReplacementPolicy.rejectedKey,
            timestampKey: "rejected_at"
        )
        let previousByKey = Dictionary(uniqueKeysWithValues: previous.map {
            (ReplacementPolicy.key(from: $0.from, to: $0.to), $0)
        })
        let approvedTargetBySource = Dictionary(uniqueKeysWithValues: approved.map {
            (ReplacementPolicy.sourceKey($0.from), TermCanonicalizer.canonicalKey($0.to))
        })
        let now = ISOTimestamp.now(clock())
        var seen = Set<String>()
        var targetBySource = [String: String]()
        var decisions: [ReplacementDecision] = []
        for pair in pairs {
            let from = VocabProvider.normalizeReplacementSide(pair.0)
            let to = VocabProvider.normalizeReplacementSide(pair.1)
            guard !from.isEmpty, !to.isEmpty else { throw DictionaryCoordinatorError.invalidReplacement }
            let sourceKey = ReplacementPolicy.sourceKey(from)
            let targetKey = TermCanonicalizer.canonicalKey(to)
            if let existing = targetBySource[sourceKey], existing != targetKey {
                throw DictionaryCoordinatorError.conflictingReplacement
            }
            if let existing = approvedTargetBySource[sourceKey], existing != targetKey {
                throw DictionaryCoordinatorError.conflictingReplacement
            }
            targetBySource[sourceKey] = targetKey
            let identity = ReplacementPolicy.key(from: from, to: to)
            guard seen.insert(identity).inserted else { continue }
            decisions.append(ReplacementDecision(
                from: from,
                to: to,
                timestamp: previousByKey[identity]?.timestamp ?? now
            ))
        }

        let newKeys = Set(decisions.map { ReplacementPolicy.key(from: $0.from, to: $0.to) })
        let rejectedKeys = Set(rejected.map { ReplacementPolicy.key(from: $0.from, to: $0.to) })
        for old in previous {
            let identity = ReplacementPolicy.key(from: old.from, to: old.to)
            if !newKeys.contains(identity), !rejectedKeys.contains(identity) {
                rejected.append(ReplacementDecision(from: old.from, to: old.to, timestamp: now))
            }
        }
        rejected.removeAll { newKeys.contains(ReplacementPolicy.key(from: $0.from, to: $0.to)) }

        var candidate = snapshot
        candidate.raw["manual_replacements"] = ReplacementPolicy.encode(decisions, timestampKey: "added_at")
        candidate.raw[ReplacementPolicy.approvedKey] = ReplacementPolicy.encode(
            approved.filter { !newKeys.contains(ReplacementPolicy.key(from: $0.from, to: $0.to)) },
            timestampKey: "approved_at"
        )
        candidate.raw[ReplacementPolicy.rejectedKey] = ReplacementPolicy.encode(
            rejected,
            timestampKey: "rejected_at"
        )
        try commit(candidate, promptLanguages: [], invalidations: [.replacements])
    }

    public func approveReplacement(_ row: ReplacementRow) throws {
        try activateReplacement(row, removingRejection: true)
    }

    public func restoreReplacement(_ row: ReplacementRow) throws {
        try activateReplacement(row, removingRejection: true)
    }

    public func rejectReplacement(_ row: ReplacementRow) throws {
        let from = VocabProvider.normalizeReplacementSide(row.from)
        let to = VocabProvider.normalizeReplacementSide(row.to)
        guard !from.isEmpty, !to.isEmpty else { throw DictionaryCoordinatorError.invalidReplacement }
        let identity = ReplacementPolicy.key(from: from, to: to)
        var manual = ReplacementPolicy.decisions(
            in: snapshot,
            key: "manual_replacements",
            timestampKey: "added_at"
        )
        var approved = ReplacementPolicy.decisions(
            in: snapshot,
            key: ReplacementPolicy.approvedKey,
            timestampKey: "approved_at"
        )
        var rejected = ReplacementPolicy.decisions(
            in: snapshot,
            key: ReplacementPolicy.rejectedKey,
            timestampKey: "rejected_at"
        )
        manual.removeAll { ReplacementPolicy.key(from: $0.from, to: $0.to) == identity }
        approved.removeAll { ReplacementPolicy.key(from: $0.from, to: $0.to) == identity }
        if !rejected.contains(where: { ReplacementPolicy.key(from: $0.from, to: $0.to) == identity }) {
            rejected.append(ReplacementDecision(from: from, to: to, timestamp: ISOTimestamp.now(clock())))
        }
        var candidate = snapshot
        candidate.raw["manual_replacements"] = ReplacementPolicy.encode(manual, timestampKey: "added_at")
        candidate.raw[ReplacementPolicy.approvedKey] = ReplacementPolicy.encode(approved, timestampKey: "approved_at")
        candidate.raw[ReplacementPolicy.rejectedKey] = ReplacementPolicy.encode(rejected, timestampKey: "rejected_at")
        try commit(candidate, promptLanguages: [], invalidations: [.replacements])
    }

    public func removeReplacement(_ row: ReplacementRow) throws {
        try rejectReplacement(row)
    }

    public func removeAutomaticReplacement(_ row: ReplacementRow) throws {
        guard row.source == "auto" else { return }
        try rejectReplacement(row)
    }

    public func flushIfNeeded() throws {
        guard dirty else { return }
        try snapshot.saveAtomically(to: paths.configFile)
        dirty = false
    }

    @discardableResult
    public func runDecayIfDue(force: Bool = false) throws -> Int {
        let now = clock()
        if !force, let last = UserTerms.parseTimestamp(snapshot.raw["last_decay_run_ts"]?.stringValue),
           now.timeIntervalSince(last) < 24 * 3_600 { return 0 }
        var candidate = snapshot
        let count = UserTerms.applyDecay(to: &candidate, now: now)
        candidate.raw["last_decay_run_ts"] = .string(ISOTimestamp.now(now))
        let languages = count > 0 ? Set(activeLanguages()) : []
        try commit(candidate, promptLanguages: languages, invalidations: count > 0 ? [.terms] : [])
        return count
    }

    @discardableResult
    public func runMetricsIfDue(force: Bool = false) async throws -> JSONObject? {
        let now = clock()
        if !force, let last = UserTerms.parseTimestamp(snapshot.raw["last_metrics_snapshot_ts"]?.stringValue),
           now.timeIntervalSince(last) < 24 * 3_600 { return latestMetricsSnapshot }
        let metrics = await computeMetricsOffMain(now: now, priority: .utility)
        try await persistMetricsSnapshot(metrics, now: now)
        return metrics
    }

    /// Computes the Statistics window snapshot away from AppKit's main actor,
    /// then serializes the history/config mutation back through the coordinator.
    public func computeMetricsForPresentation() async throws -> JSONObject {
        let now = clock()
        let metrics = await computeMetricsOffMain(now: now, priority: .userInitiated)
        try Task.checkCancellation()
        try await persistMetricsSnapshot(metrics, now: now)
        return metrics
    }

    private func computeMetricsOffMain(now: Date, priority: TaskPriority) async -> JSONObject {
        let datasetURL = paths.datasetFile
        let correctionsURL = paths.correctionsFile
        let rawConfig = snapshot.raw
        return await Task.detached(priority: priority) {
            Metrics.computeMetrics(
                datasetUrl: datasetURL,
                correctionsUrl: correctionsURL,
                config: rawConfig,
                now: now
            )
        }.value
    }

    private func persistMetricsSnapshot(_ metrics: JSONObject, now: Date) async throws {
        let historyURL = paths.metricsHistoryFile
        let history = try await Task.detached(priority: .utility) {
            try Metrics.appendHistory(metrics, to: historyURL, now: now)
            return Metrics.loadHistory(at: historyURL)
        }.value
        try Task.checkCancellation()
        var candidate = snapshot
        maybeScheduleMetricsNotification(metrics, history: history, config: &candidate, now: now)
        candidate.raw["last_metrics_snapshot_ts"] = .string(ISOTimestamp.now(now))
        try commit(candidate, promptLanguages: [], invalidations: [.metrics])
        latestMetricsSnapshot = metrics
    }

    public func runDailyMaintenanceIfDue() {
        guard !maintenanceRunning else { return }
        maintenanceRunning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.maintenanceRunning = false }
            do {
                _ = try self.runDecayIfDue()
                _ = try await self.runMetricsIfDue()
            } catch {
                self.log("Dictionary maintenance failed: \(error.localizedDescription)")
            }
        }
    }

    public func runPromptAnalysis(onDemand: Bool = false) async throws {
        guard !analysisRunning else { return }
        analysisRunning = true
        defer { analysisRunning = false }
        let mode = snapshot.raw["prompt_update_mode"]?.stringValue ?? "suggest"
        if mode == "disabled", !onDemand { return }

        let primary = snapshot.primaryLanguage
        let additional = snapshot.additionalLanguages
        let primaryScript = VocabProvider.getLanguageScript(primary)
        let otherScript = primaryScript == "latin" ? "cyrillic" : "latin"
        let minimum: [String: Int]
        let lookback: Int
        if onDemand {
            minimum = ["latin": 5, "cyrillic": 5]
            lookback = 1_000
        } else {
            minimum = [
                primaryScript: Int(snapshot.raw["auto_prompt_check_min_count_primary"]?.intValue ?? 10),
                otherScript: Int(snapshot.raw["auto_prompt_check_min_count_additional"]?.intValue ?? 5),
            ]
            lookback = Int(snapshot.raw["auto_prompt_lookback"]?.intValue ?? 300)
        }

        let existing = existingTermsByLanguage()
        let skipped = skippedTermsByLanguage()
        let analysisNow = clock()
        let output = try await persistenceWorker.analyzePromptCandidates(
            existing: existing,
            skipped: skipped,
            minimum: minimum,
            lookback: lookback,
            now: analysisNow
        )
        try Task.checkCancellation()
        let merged = remapCandidates(
            mergeCandidates(corrections: output.corrections, frequency: output.frequency),
            primary: primary,
            additional: additional
        )

        var candidate = snapshot
        if !onDemand {
            candidate.raw["last_analysis_phrase_count"] = .int(Int64(output.currentPhraseCount))
        }
        let activeMode = snapshot.raw["prompt_update_mode"]?.stringValue ?? mode
        if activeMode == "auto", !merged.isEmpty {
            for (language, items) in merged {
                for item in items { addCandidate(item, language: language, to: &candidate) }
            }
            try commit(candidate, promptLanguages: Set(merged.keys), invalidations: [.terms, .suggestions])
        } else if activeMode == "suggest" {
            replacePending(with: merged, in: &candidate)
            try commit(candidate, promptLanguages: [], invalidations: [.suggestions])
        } else {
            try commit(candidate, promptLanguages: [], invalidations: [])
        }
    }

    public func scanPromptFilesForTesting() {
        promptSynchronizer.scanForExternalChanges()
    }

    private func schedulePromptAnalysisIfDue() {
        let mode = snapshot.raw["prompt_update_mode"]?.stringValue ?? "suggest"
        guard mode != "disabled" else { return }
        let current = phraseHistory.count()
        let last = Int(snapshot.raw["last_analysis_phrase_count"]?.intValue ?? 0)
        let interval = Int(snapshot.raw["auto_prompt_check_interval"]?.intValue ?? 20)
        let index = CorrectionAnalyzer.readIndex(at: paths.correctionsFile)
        let strong = CorrectionAnalyzer.hasFreshStrongCorrectionSignal(
            index: index,
            currentPhraseCount: current,
            alreadyProcessedRows: lastFastPathProcessedRows
        )
        guard strong || current - last >= interval else { return }
        if strong { lastFastPathProcessedRows = index.processedRows }
        Task { @MainActor [weak self] in
            do { try await self?.runPromptAnalysis() }
            catch { self?.log("Prompt analysis failed: \(error.localizedDescription)") }
        }
    }

    private func initializeReplacementPolicyIfNeeded() {
        guard snapshot.raw["replacement_policy_initialized"]?.boolValue != true else { return }
        do {
            let now = clock()
            var index: CorrectionIndex?
            if FileManager.default.fileExists(atPath: paths.datasetFile.path)
                || FileManager.default.fileExists(atPath: paths.correctionsFile.path) {
                index = try CorrectionAnalyzer.updateCorrectionsIndexThrowing(
                    datasetPath: paths.datasetFile,
                    indexPath: paths.correctionsFile,
                    now: now,
                    pruneStale: false
                )
            }

            let manual = ReplacementPolicy.decisions(
                in: snapshot,
                key: "manual_replacements",
                timestampKey: "added_at"
            )
            var approved = ReplacementPolicy.decisions(
                in: snapshot,
                key: ReplacementPolicy.approvedKey,
                timestampKey: "approved_at"
            )
            let rejected = ReplacementPolicy.decisions(
                in: snapshot,
                key: ReplacementPolicy.rejectedKey,
                timestampKey: "rejected_at"
            )
            let rejectedKeys = Set(rejected.map { ReplacementPolicy.key(from: $0.from, to: $0.to) })
            var activeKeys = Set((manual + approved).map {
                ReplacementPolicy.key(from: $0.from, to: $0.to)
            })
            var targetBySource: [String: String] = [:]
            for decision in manual + approved {
                let source = ReplacementPolicy.sourceKey(decision.from)
                if targetBySource[source] == nil {
                    targetBySource[source] = TermCanonicalizer.canonicalKey(decision.to)
                }
            }
            let approvedAt = ISOTimestamp.now(now)
            if let index {
                for bucket in ["latin", "cyrillic"] {
                    for pair in index.replacementPairs[bucket] ?? [] where pair.count >= 3 {
                        let identity = ReplacementPolicy.key(from: pair.from, to: pair.to)
                        let source = ReplacementPolicy.sourceKey(pair.from)
                        let target = TermCanonicalizer.canonicalKey(pair.to)
                        guard !rejectedKeys.contains(identity), activeKeys.insert(identity).inserted else { continue }
                        if let existing = targetBySource[source], existing != target { continue }
                        targetBySource[source] = target
                        approved.append(ReplacementDecision(from: pair.from, to: pair.to, timestamp: approvedAt))
                    }
                }
            }

            var candidate = snapshot
            candidate.raw[ReplacementPolicy.approvedKey] = ReplacementPolicy.encode(
                approved,
                timestampKey: "approved_at"
            )
            candidate.raw["replacement_policy_initialized"] = .bool(true)
            try candidate.saveAtomically(to: paths.configFile)
            snapshot = candidate

            if var index, CorrectionAnalyzer.pruneStaleReplacementPairs(in: &index, now: now) > 0 {
                do { try CorrectionAnalyzer.writeIndex(index, to: paths.correctionsFile) }
                catch { log("Post-migration replacement pruning failed: \(error.localizedDescription)") }
            }
        } catch {
            log("Replacement policy initialization failed: \(error.localizedDescription)")
        }
    }

    private func activateReplacement(_ row: ReplacementRow, removingRejection: Bool) throws {
        let from = VocabProvider.normalizeReplacementSide(row.from)
        let to = VocabProvider.normalizeReplacementSide(row.to)
        guard !from.isEmpty, !to.isEmpty else { throw DictionaryCoordinatorError.invalidReplacement }
        let identity = ReplacementPolicy.key(from: from, to: to)
        let source = ReplacementPolicy.sourceKey(from)
        let target = TermCanonicalizer.canonicalKey(to)
        let manual = ReplacementPolicy.decisions(
            in: snapshot,
            key: "manual_replacements",
            timestampKey: "added_at"
        )
        var approved = ReplacementPolicy.decisions(
            in: snapshot,
            key: ReplacementPolicy.approvedKey,
            timestampKey: "approved_at"
        )
        var rejected = ReplacementPolicy.decisions(
            in: snapshot,
            key: ReplacementPolicy.rejectedKey,
            timestampKey: "rejected_at"
        )
        for decision in manual + approved where ReplacementPolicy.sourceKey(decision.from) == source {
            if TermCanonicalizer.canonicalKey(decision.to) != target {
                throw DictionaryCoordinatorError.conflictingReplacement
            }
        }
        let isManual = manual.contains { ReplacementPolicy.key(from: $0.from, to: $0.to) == identity }
        let isApproved = approved.contains { ReplacementPolicy.key(from: $0.from, to: $0.to) == identity }
        if !isManual, !isApproved {
            approved.append(ReplacementDecision(from: from, to: to, timestamp: ISOTimestamp.now(clock())))
        }
        if removingRejection {
            rejected.removeAll { ReplacementPolicy.key(from: $0.from, to: $0.to) == identity }
        }
        var candidate = snapshot
        candidate.raw[ReplacementPolicy.approvedKey] = ReplacementPolicy.encode(approved, timestampKey: "approved_at")
        candidate.raw[ReplacementPolicy.rejectedKey] = ReplacementPolicy.encode(rejected, timestampKey: "rejected_at")
        try commit(candidate, promptLanguages: [], invalidations: [.replacements])
    }

    private func commit(
        _ input: Config,
        promptLanguages: Set<String>,
        invalidations: DictionaryInvalidations
    ) throws {
        var candidate = input
        candidate.raw["initial_prompt"] = .string(promptBuilder.build(config: candidate.raw))
        let old = snapshot
        do {
            for language in promptLanguages {
                try promptSynchronizer.write(
                    language: language,
                    terms: termStrings(config: candidate, language: language)
                )
            }
            try candidate.saveAtomically(to: paths.configFile)
        } catch {
            for language in promptLanguages {
                try? promptSynchronizer.write(
                    language: language,
                    terms: termStrings(config: old, language: language)
                )
            }
            throw error
        }
        snapshot = candidate
        dirty = false
        publish(invalidations.union(.config))
    }

    private func publish(_ invalidations: DictionaryInvalidations) {
        onSnapshotChanged?(snapshot, invalidations)
    }

    private func activeLanguages() -> [String] {
        [snapshot.primaryLanguage] + LanguageCode.dedupeList(
            snapshot.additionalLanguages,
            primary: snapshot.primaryLanguage
        )
    }

    private func termStrings(language: String) -> [String] {
        termStrings(config: snapshot, language: language)
    }

    private func termStrings(config: Config, language: String) -> [String] {
        let lang = LanguageCode.normalize(language)
        return (config.raw["user_terms"]?.objectValue?[lang]?.arrayValue ?? [])
            .map(UserTerms.termString)
            .filter { !$0.isEmpty }
    }

    private func saveSnapshot(in config: inout Config, language: String, items: [JSONValue]) {
        var snapshots = config.raw["prompt_snapshots"]?.objectValue ?? JSONObject()
        snapshots[language] = .array(items)
        config.raw["prompt_snapshots"] = .object(snapshots)
    }

    private func makeTermItem(_ term: String, source: String, useCount: Int) -> JSONValue {
        var object = JSONObject()
        let now = ISOTimestamp.now(clock())
        object["term"] = .string(TermCanonicalizer.canonicalize(term))
        object["source"] = .string(source)
        object["added_at"] = .string(now)
        object["last_seen"] = .string(now)
        object["use_count"] = .int(Int64(useCount))
        return .object(object)
    }

    private func addCandidate(_ item: TermCandidate, language: String, to config: inout Config) {
        let source = item.source == "correction" ? "correction" : "auto"
        let lang = LanguageCode.normalize(language)
        var byLanguage = config.raw["user_terms"]?.objectValue ?? JSONObject()
        var items = byLanguage[lang]?.arrayValue ?? []
        let key = TermCanonicalizer.canonicalKey(item.term)
        guard !items.contains(where: {
            TermCanonicalizer.canonicalKey(UserTerms.termString($0)) == key
        }) else { return }
        items.append(makeTermItem(item.term, source: source, useCount: item.frequencyCount))
        byLanguage[lang] = .array(items)
        config.raw["user_terms"] = .object(byLanguage)
    }

    private func removePending(term: String, language: String, from config: inout Config) {
        var pending = config.raw["pending_suggestions"]?.objectValue ?? JSONObject()
        var items = pending[language]?.arrayValue ?? []
        let key = TermCanonicalizer.canonicalKey(term)
        items.removeAll {
            TermCanonicalizer.canonicalKey($0.objectValue?["term"]?.stringValue ?? "") == key
        }
        if items.isEmpty { pending.remove(language) } else { pending[language] = .array(items) }
        config.raw["pending_suggestions"] = .object(pending)
    }

    private static func decodeCandidate(_ value: JSONValue) -> TermCandidate? {
        guard let object = value.objectValue,
              let term = object["term"]?.stringValue, !term.isEmpty else { return nil }
        return TermCandidate(
            term: term,
            count: Int(object["count"]?.intValue ?? 0),
            correctionCount: Int(
                object["correction_count"]?.intValue
                    ?? object["correctionCount"]?.intValue
                    ?? 0
            ),
            frequencyCount: Int(
                object["frequency_count"]?.intValue
                    ?? object["frequencyCount"]?.intValue
                    ?? 0
            ),
            source: object["source"]?.stringValue ?? "frequency"
        )
    }

    private func encodeCandidate(_ item: TermCandidate) -> JSONValue {
        var object = JSONObject()
        object["term"] = .string(TermCanonicalizer.canonicalize(item.term))
        object["count"] = .int(Int64(item.count))
        object["correction_count"] = .int(Int64(item.correctionCount))
        object["frequency_count"] = .int(Int64(item.frequencyCount))
        object["source"] = .string(item.source)
        return .object(object)
    }

    private func existingTermsByLanguage() -> [String: Set<String>] {
        guard let byLanguage = snapshot.raw["user_terms"]?.objectValue else { return [:] }
        return Dictionary(uniqueKeysWithValues: byLanguage.keys.map { language in
            let keys = Set((byLanguage[language]?.arrayValue ?? []).map {
                TermCanonicalizer.canonicalKey(UserTerms.termString($0))
            }.filter { !$0.isEmpty })
            return (language, keys)
        })
    }

    private func skippedTermsByLanguage() -> [String: [String: Int]] {
        guard let skipped = snapshot.raw["skipped_terms"]?.objectValue else { return [:] }
        return Dictionary(uniqueKeysWithValues: skipped.keys.map { language in
            let values = skipped[language]?.objectValue ?? JSONObject()
            return (language, Dictionary(uniqueKeysWithValues: values.keys.map {
                ($0, Int(values[$0]?.intValue ?? 0))
            }))
        })
    }

    private func mergeCandidates(
        corrections: [String: [TermCandidate]],
        frequency: [String: [TermCandidate]]
    ) -> [String: [TermCandidate]] {
        var result: [String: [TermCandidate]] = [:]
        for bucket in Set(corrections.keys).union(frequency.keys) {
            var byKey: [String: TermCandidate] = [:]
            for item in corrections[bucket] ?? [] {
                let key = TermCanonicalizer.canonicalKey(item.term)
                byKey[key] = TermCandidate(
                    term: item.term,
                    count: item.correctionCount,
                    correctionCount: item.correctionCount,
                    frequencyCount: 0,
                    source: "correction"
                )
            }
            for item in frequency[bucket] ?? [] {
                let key = TermCanonicalizer.canonicalKey(item.term)
                if let old = byKey[key] {
                    byKey[key] = TermCandidate(
                        term: old.term,
                        count: old.correctionCount + item.count,
                        correctionCount: old.correctionCount,
                        frequencyCount: item.count,
                        source: "both"
                    )
                } else {
                    byKey[key] = TermCandidate(
                        term: item.term,
                        count: item.count,
                        correctionCount: 0,
                        frequencyCount: item.count,
                        source: "frequency"
                    )
                }
            }
            result[bucket] = Array(byKey.values).sorted {
                if $0.rankingScore != $1.rankingScore { return $0.rankingScore > $1.rankingScore }
                return TermCanonicalizer.canonicalKey($0.term) < TermCanonicalizer.canonicalKey($1.term)
            }.prefix(15).map { $0 }
        }
        return result
    }

    private func remapCandidates(
        _ source: [String: [TermCandidate]],
        primary: String,
        additional: [String]
    ) -> [String: [TermCandidate]] {
        var result: [String: [TermCandidate]] = [:]
        let active = Set([primary] + additional)
        for (bucket, items) in source {
            let language = ["latin", "cyrillic"].contains(bucket)
                ? UserTerms.targetLanguage(forScript: bucket, primary: primary, additional: additional)
                : (active.contains(bucket) ? bucket : primary)
            var current = result[language] ?? []
            var seen = Set(current.map { TermCanonicalizer.canonicalKey($0.term) })
            for item in items where seen.insert(TermCanonicalizer.canonicalKey(item.term)).inserted {
                current.append(item)
            }
            result[language] = current.sorted { $0.rankingScore > $1.rankingScore }
        }
        return result
    }

    private func replacePending(with candidates: [String: [TermCandidate]], in config: inout Config) {
        var pending = JSONObject()
        for (language, items) in candidates {
            let values = items.sorted { $0.rankingScore > $1.rankingScore }.map(encodeCandidate)
            if !values.isEmpty { pending[language] = .array(values) }
        }
        config.raw["pending_suggestions"] = .object(pending)
    }

    private func maybeScheduleMetricsNotification(
        _ metrics: JSONObject,
        history: [JSONObject],
        config: inout Config,
        now: Date
    ) {
        guard config.raw["notify_on_metrics"]?.boolValue ?? true,
              let current = metrics["edit_score_avg"]?.doubleValue else { return }
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        let values = history.compactMap { item -> Double? in
            guard let date = UserTerms.parseTimestamp(item["ts"]?.stringValue), date >= cutoff else { return nil }
            return item["edit_score_avg"]?.doubleValue
        }
        guard values.count >= 5, let baseline = values.min(), baseline > 0,
              current >= baseline * 1.5 else { return }
        if let last = UserTerms.parseTimestamp(config.raw["last_metrics_notification_ts"]?.stringValue),
           now.timeIntervalSince(last) < 30 * 86_400 { return }
        config.raw["last_metrics_notification_ts"] = .string(ISOTimestamp.now(now))
        onNotification?(DictionaryNotification(
            titleKey: "notify.metrics_attention_title",
            bodyKey: "notify.metrics_attention_body"
        ))
    }
}
