import Foundation

public actor GeminiEditor: AiEditing {
    public let isReady: Bool
    private let modelName: String
    private let apiKey: String
    private let urlSession: URLSession
    private var isBusy = false
    
    public init(modelName: String, apiKey: String) {
        self.modelName = modelName
        self.apiKey = apiKey
        self.isReady = !apiKey.isEmpty
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 15.0
        self.urlSession = URLSession(configuration: config)
    }

    public func refine(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        await doRefine(
            text: text,
            languages: languages,
            knownTerms: knownTerms,
            misrecognitions: misrecognitions,
            isFileMode: false
        )
    }

    public func refineFileText(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?
    ) async -> RefineResult {
        await doRefine(
            text: text,
            languages: languages,
            knownTerms: knownTerms,
            misrecognitions: misrecognitions,
            isFileMode: true
        )
    }

    private func doRefine(
        text: String,
        languages: [String]?,
        knownTerms: [String]?,
        misrecognitions: [(String, String)]?,
        isFileMode: Bool
    ) async -> RefineResult {
        guard isReady else {
            return RefineResult(text: text, status: .disabled)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return RefineResult(text: text, status: .disabled)
        }
        if isBusy {
            return RefineResult(text: text, status: .skipped)
        }
        
        isBusy = true
        defer { isBusy = false }
        
        let systemPrompt = isFileMode
            ? AiEditorPrompts.buildFileSystemPromptGemini(languages: languages, knownTerms: knownTerms, misrecognitions: misrecognitions)
            : AiEditorPrompts.buildApiEditorSystemPrompt(languages: languages, knownTerms: knownTerms, misrecognitions: misrecognitions)
        
        let taggedText = isFileMode ? text : "<speech>\n\(text)\n</speech>"
        
        let maxTokens = estimateTokens(text: text, languages: languages)
        
        // Build JSON body
        let jsonBody: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": systemPrompt]]
            ],
            "contents": [
                [
                    "parts": [["text": taggedText]]
                ]
            ],
            "generationConfig": [
                "temperature": 0.0,
                "maxOutputTokens": maxTokens
            ]
        ]
        
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(apiKey)") else {
            return RefineResult(text: text, status: .error)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        } catch {
            return RefineResult(text: text, status: .error)
        }
        
        // Override timeout for file mode
        if isFileMode {
            request.timeoutInterval = 300.0
        }
        
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return RefineResult(text: text, status: .error)
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let firstPart = parts.first,
                  let resultText = firstPart["text"] as? String else {
                return RefineResult(text: text, status: .error)
            }
            
            let cleaned = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                return RefineResult(text: text, status: .error)
            }
            
            // Safety guard: if output is insanely long, fallback
            if cleaned.count > text.count * 3 {
                return RefineResult(text: text, status: .error)
            }
            
            if cleaned == text.trimmingCharacters(in: .whitespacesAndNewlines) {
                return RefineResult(text: text, status: .unchanged)
            }
            
            return RefineResult(text: cleaned, status: .ok)
            
        } catch let urlError as URLError where urlError.code == .timedOut {
            return RefineResult(text: text, status: .timeout)
        } catch {
            return RefineResult(text: text, status: .error)
        }
    }
    
    private func estimateTokens(text: String, languages: [String]?) -> Int {
        let langs = Set(languages ?? [])
        let cjk: Set<String> = ["zh", "ja", "ko"]
        let cyrillic: Set<String> = ["ru", "uk"]
        
        let charsPerToken: Double
        if !langs.isDisjoint(with: cjk) {
            charsPerToken = 1.5
        } else if !langs.isDisjoint(with: cyrillic) {
            charsPerToken = 2.5
        } else if !langs.isEmpty {
            charsPerToken = 3.5
        } else {
            charsPerToken = 2.5
        }
        
        let estimated = Int(Double(text.count) / charsPerToken * 1.2)
        return max(64, estimated)
    }
}
