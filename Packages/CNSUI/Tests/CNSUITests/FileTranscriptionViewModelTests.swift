import Foundation
import Testing
import SwiftUI
import CNSCore
import CNSTranscription
@testable import CNSUI

@Suite("FileTranscriptionViewModel")
@MainActor
struct FileTranscriptionViewModelTests {
    private let i18n: I18n

    init() {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("locales").path) {
                self.i18n = I18n.load("en", localesDirectory: directory.appendingPathComponent("locales"))
                return
            }
            directory = directory.deletingLastPathComponent()
        }
        fatalError("Could not locate repository locales")
    }

    @Test("Start clears refinement states")
    func startClearsState() {
        let sut = FileTranscriptionViewModel(i18n: i18n, onTranscribe: { _, _, _ in FileTranscriptionResult(text: "", status: .success) }, onCancel: {})
        sut.start(URL(fileURLWithPath: "/tmp/foo.wav"))
        let id = sut.jobID!
        
        // Mock some previous state
        sut.receiveResult(FileTranscriptionResult(text: "foo", status: .success, refinement: .applied), jobID: id)
        #expect(sut.refinementOutcome == .applied)
        #expect(sut.refinementMessage == i18n.t("dialog.refinement_applied"))
        
        sut.start(URL(fileURLWithPath: "/tmp/bar.wav"))
        
        #expect(sut.refinementOutcome == .notRequested)
        #expect(sut.refinementMessage == nil)
    }

    @Test("Outcomes are correctly localized")
    func localization() {
        let sut = FileTranscriptionViewModel(i18n: i18n, onTranscribe: { _, _, _ in FileTranscriptionResult(text: "", status: .success) }, onCancel: {})
        
        let cases: [(FileRefinementOutcome, String)] = [
            (.applied, "dialog.refinement_applied"),
            (.unchanged, "dialog.refinement_unchanged"),
            (.unavailable, "dialog.refinement_unavailable"),
            (.skipped, "dialog.refinement_skipped"),
            (.timedOut, "dialog.refinement_timeout"),
            (.failed, "dialog.refinement_failed"),
            (.notRun, "dialog.refinement_not_run")
        ]
        
        for (outcome, key) in cases {
            sut.start(URL(fileURLWithPath: "/tmp/foo.wav"))
            let id = sut.jobID!
            sut.receiveResult(FileTranscriptionResult(text: "foo", status: .success, refinement: outcome), jobID: id)
            #expect(sut.refinementMessage == i18n.t(key))
        }
    }

    @Test("STT Failure suppresses notRun message")
    func sttFailureNotRun() {
        let sut = FileTranscriptionViewModel(i18n: i18n, onTranscribe: { _, _, _ in FileTranscriptionResult(text: "", status: .success) }, onCancel: {})
        sut.start(URL(fileURLWithPath: "/tmp/foo.wav"))
        let id = sut.jobID!
        sut.receiveResult(FileTranscriptionResult(text: "", status: .cancelled, refinement: .notRun), jobID: id)
        #expect(sut.refinementMessage == nil)
    }

    @Test("Editor availability state")
    func editorAvailability() {
        let sut = FileTranscriptionViewModel(i18n: i18n, onTranscribe: { _, _, _ in FileTranscriptionResult(text: "", status: .success) }, onCancel: {})
        
        sut.updateEditorAvailability(isActive: false, isPreparing: true)
        #expect(sut.isEditorAvailable == false)
        #expect(sut.editorUnavailableReason == i18n.t("dialog.editor_preparing_reason"))
        
        sut.updateEditorAvailability(isActive: false, isPreparing: false)
        #expect(sut.isEditorAvailable == false)
        #expect(sut.editorUnavailableReason == i18n.t("dialog.editor_disabled_reason"))
        
        sut.updateEditorAvailability(isActive: true, isPreparing: false)
        #expect(sut.isEditorAvailable == true)
        #expect(sut.editorUnavailableReason == nil)
    }
}
