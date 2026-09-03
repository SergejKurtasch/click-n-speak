import CNSCore
import Foundation

/// Owns the Python-compatible `initial_prompt_<lang>.txt` files. Polling the
/// small active-language set mirrors the Python one-second watcher and also
/// survives editors that save by atomically replacing the file.
@MainActor
public final class PromptFileSynchronizer {
    private let paths: Paths
    private let activeLanguages: () -> [String]
    private let onExternalChange: (String, String) -> Void
    private let log: @Sendable (String) -> Void
    private var observedContents: [String: String] = [:]
    private var timer: Timer?

    public init(
        paths: Paths,
        activeLanguages: @escaping () -> [String],
        onExternalChange: @escaping (String, String) -> Void,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.paths = paths
        self.activeLanguages = activeLanguages
        self.onExternalChange = onExternalChange
        self.log = log
    }

    public func start(interval: TimeInterval = 1) {
        stop()
        prime()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanForExternalChanges() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func prime() {
        for language in activeLanguages() {
            let lang = LanguageCode.normalize(language)
            guard observedContents[lang] == nil else { continue }
            let url = paths.initialPromptFile(lang: lang)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                observedContents[lang] = text
            }
        }
    }

    public func write(language: String, terms: [String]) throws {
        let lang = LanguageCode.normalize(language)
        let text = terms.joined(separator: ", ")
        try AtomicFile.writeText(text, to: paths.initialPromptFile(lang: lang))
        observedContents[lang] = text
    }

    public func scanForExternalChanges() {
        for language in activeLanguages() {
            let lang = LanguageCode.normalize(language)
            let url = paths.initialPromptFile(lang: lang)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                guard let previous = observedContents[lang] else {
                    observedContents[lang] = text
                    continue
                }
                guard text != previous else { continue }
                observedContents[lang] = text
                onExternalChange(lang, text)
            } catch {
                log("Prompt watcher could not read \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
