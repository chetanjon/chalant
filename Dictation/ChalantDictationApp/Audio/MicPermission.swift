import AVFoundation
import os

/// Asks for the microphone, explicitly.
///
/// Starting an `AVAudioEngine` with an input tap does **not** reliably raise
/// the system prompt for a background `LSUIElement` app: the engine starts,
/// reports a healthy sample rate, and then delivers silence forever, which
/// looks exactly like a broken audio pipeline. The ask has to be explicit.
///
/// Part 2 §5 wants permissions requested lazily and one at a time, never at
/// launch, so this fires on the first key-down rather than on startup.
enum MicPermission {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "audio")

    enum Outcome: Sendable {
        case granted
        case denied
        /// The user has not answered the prompt yet.
        case pending
    }

    static var current: Outcome {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .pending
        default: return .denied
        }
    }

    /// Returns once the answer is known. Safe to call repeatedly: macOS
    /// prompts only while the answer is undetermined and answers silently
    /// forever after.
    static func ensure() async -> Outcome {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            log.info("microphone request answered: \(granted, privacy: .public)")
            return granted ? .granted : .denied
        default:
            return .denied
        }
    }
}
