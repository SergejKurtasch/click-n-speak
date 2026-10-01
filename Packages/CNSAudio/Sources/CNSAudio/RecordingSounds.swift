import AudioToolbox
import Foundation

/// Short system sounds marking the start and end of recording, matching
/// `play_sound()` in `utils.py` (which shells out to `afplay`). Uses
/// AudioServices instead of a subprocess: no process spawn per hotkey press,
/// and no AppKit dependency in the audio layer.
///
/// Playback is asynchronous — the recorder pauses briefly after the start sound
/// so the beep does not end up inside the recording (same as the Python 0.2 s
/// sleep before opening the stream).
public enum RecordingSounds {
    public static let startPath = "/System/Library/Sounds/Tink.aiff"
    public static let stopPath = "/System/Library/Sounds/Pop.aiff"

    /// Pause after the start sound before the input stream opens, so the beep
    /// is not captured. Mirrors `time.sleep(0.2)` in `recorder.start`.
    public static let startSoundLeadTime: TimeInterval = 0.2

    private static let cache = SoundCache()

    public static func playStart() { play(startPath) }
    public static func playStop() { play(stopPath) }

    private static func play(_ path: String) {
        guard let id = cache.soundID(for: path) else { return }
        AudioServicesPlaySystemSound(id)
    }
}

/// Registers each sound file once; `AudioServicesCreateSystemSoundID` is not
/// free, and these two sounds play on every recording.
private final class SoundCache: @unchecked Sendable {
    // @unchecked Sendable: guarded by `lock`; only two entries, only ever added.
    private var ids: [String: SystemSoundID] = [:]
    private let lock = NSLock()

    func soundID(for path: String) -> SystemSoundID? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = ids[path] { return existing }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var id: SystemSoundID = 0
        let url = URL(fileURLWithPath: path) as CFURL
        guard AudioServicesCreateSystemSoundID(url, &id) == kAudioServicesNoError else { return nil }
        ids[path] = id
        return id
    }
}
