import Testing
@testable import CNSSession

@Suite("Session audio backlog")
struct SessionAudioBacklogTests {
    @Test("Accepted chunks receive monotonic indices and exact pending accounting")
    func monotonicAdmission() throws {
        let backlog = SessionAudioBacklog(maxSamples: 10)

        let first = try #require(backlog.admit(
            audio: [1, 2, 3, 4],
            isFinal: false,
            sessionID: 7,
            capturedUptime: 1,
            enqueuedUptime: 2
        ).acceptedChunk)
        let secondAdmission = backlog.admit(
            audio: [5, 6, 7, 8, 9, 10],
            isFinal: false,
            sessionID: 7,
            capturedUptime: 3,
            enqueuedUptime: 4
        )
        let second = try #require(secondAdmission.acceptedChunk)

        #expect(first.index == 0)
        #expect(second.index == 1)
        #expect(first.capturedUptime == 1)
        #expect(first.enqueuedUptime == 2)
        #expect(secondAdmission.stopBoundary?.index == 2)
        #expect(secondAdmission.stopBoundary?.rejectedSamples == 0)
        #expect(backlog.snapshot.pendingSamples == 10)
        #expect(backlog.snapshot.pendingChunks == 2)
        #expect(backlog.snapshot.nextIndex == 3)

        backlog.didProcess(first)
        #expect(backlog.snapshot.pendingSamples == 6)
        #expect(backlog.snapshot.pendingChunks == 1)
    }

    @Test("Overflow rejects the whole chunk and closes admission")
    func oversizedChunkIsExplicit() throws {
        let backlog = SessionAudioBacklog(maxSamples: 10, startingIndex: 4)

        let overflow = try #require(backlog.admit(
            audio: [Float](repeating: 0.2, count: 11),
            isFinal: false,
            sessionID: 9,
            capturedUptime: 1,
            enqueuedUptime: 1
        ).overflow)

        #expect(overflow.index == 4)
        #expect(overflow.rejectedSamples == 11)
        #expect(overflow.pendingSamples == 0)
        #expect(backlog.snapshot.pendingSamples == 0)
        #expect(backlog.snapshot.nextIndex == 5)
        #expect(backlog.admit(
            audio: [1],
            isFinal: false,
            sessionID: 9,
            capturedUptime: 2,
            enqueuedUptime: 2
        ).isClosed)
    }
}

private extension SessionAudioAdmission {
    var acceptedChunk: SessionChunk? {
        if case let .accepted(chunk, _) = self { return chunk }
        return nil
    }

    var stopBoundary: SessionAudioLimit? {
        if case let .accepted(_, boundary) = self { return boundary }
        return nil
    }

    var overflow: SessionAudioLimit? {
        if case let .overflow(value) = self { return value }
        return nil
    }

    var isClosed: Bool {
        if case .closed = self { return true }
        return false
    }
}
