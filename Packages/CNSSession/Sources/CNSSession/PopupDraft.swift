import CNSDictionary
import CNSCore
import Darwin
import Foundation

/// Durable provenance for all recordings contributing to one editable popup.
public struct PopupDraft: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public let sessionID: Int
        public let rawWhisper: String
        public let aiEdited: String?
        public let aiStatus: String?
        public let presentedText: String
        public let runtime: RuntimeDescriptor
        public let promptHash: String
        public let detectedLanguage: String?

        public init(
            sessionID: Int,
            rawWhisper: String,
            aiEdited: String?,
            aiStatus: String?,
            presentedText: String,
            runtime: RuntimeDescriptor,
            promptHash: String,
            detectedLanguage: String?
        ) {
            self.sessionID = sessionID
            self.rawWhisper = rawWhisper
            self.aiEdited = aiEdited
            self.aiStatus = aiStatus
            self.presentedText = presentedText
            self.runtime = runtime
            self.promptHash = promptHash
            self.detectedLanguage = detectedLanguage
        }

        var datasetSegment: DatasetSegment {
            DatasetSegment(
                rawWhisper: rawWhisper,
                aiEdited: aiEdited,
                aiStatus: aiStatus,
                runtime: runtime,
                promptHash: promptHash
            )
        }
    }

    public let id: UUID
    public let targetPID: pid_t?
    public private(set) var segments: [Segment]
    public var recognitionIssues: Set<String>

    public init(id: UUID = UUID(), targetPID: pid_t?) {
        self.id = id
        self.targetPID = targetPID
        self.segments = []
        self.recognitionIssues = []
    }

    public mutating func append(_ segment: Segment) {
        guard !segments.contains(where: { $0.sessionID == segment.sessionID }) else { return }
        segments.append(segment)
    }

    public var rawWhisper: String {
        segments.map(\.rawWhisper)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var datasetSegments: [DatasetSegment]? {
        segments.count > 1 ? segments.map(\.datasetSegment) : nil
    }

    var aggregateAiEdited: String? {
        segments.count == 1 ? segments[0].aiEdited : nil
    }

    var aggregateAiStatus: String? {
        guard let first = segments.first?.aiStatus,
              segments.allSatisfy({ $0.aiStatus == first }) else { return nil }
        return first
    }

    var aggregateRuntime: RuntimeDescriptor {
        segments.first?.runtime ?? .unavailable
    }

    var aggregatePromptHash: String? {
        guard let first = segments.first?.promptHash,
              segments.allSatisfy({ $0.promptHash == first }) else { return nil }
        return first
    }

    var lastDetectedLanguage: String? {
        segments.reversed().compactMap(\.detectedLanguage).first
    }
}
