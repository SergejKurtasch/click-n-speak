import CNSAudio
import CNSUI
import Foundation

/// The popup surface the session drives. `PreviewPanel` conforms; tests use a
/// recording double, which is why this exists at all.
@MainActor
public protocol PopupPresenting: AnyObject {
    var isShowingInteractive: Bool { get }
    func show(title: String)
    func updateStatus(_ title: String)
    func updateText(_ text: String)
    func appendText(_ text: String)
    func hide(delay: TimeInterval)
    func showInteractive(
        text: String,
        title: String,
        toasts: DictionaryToasts,
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onAddToDictionary: ((String) -> AddTermResult)?
    )
}

extension PreviewPanel: PopupPresenting {}

/// Microphone capture. `AudioRecorder` conforms.
public protocol AudioCapturing: Sendable {
    var isRecording: Bool { get }
    func start(callbacks: AudioRecorder.Callbacks) async throws
    func stop()
}

extension AudioRecorder: AudioCapturing {}

/// Getting confirmed text into the app the user dictated from: restore focus,
/// then insert. Implemented by `SystemTextDelivery`.
@MainActor
public protocol TextDelivering {
    /// - Returns: whether the text actually made it into the target app.
    func deliver(_ text: String, to pid: pid_t?) async -> Bool
}

/// Where the frontmost application's pid comes from. Injected so tests can
/// pretend another app was in front.
@MainActor
public protocol FrontmostAppProviding: Sendable {
    func frontmostPid() -> pid_t?
}
