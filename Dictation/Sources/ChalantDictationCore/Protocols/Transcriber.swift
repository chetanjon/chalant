import Foundation

/// The ASR seam. Part 2 §1 makes Apple's `SpeechAnalyzer` the default and
/// FluidAudio's Parakeet an opt-in second engine (M8), so both live behind
/// this and neither leaks into `Core`.
///
/// Part 0 §0.6 also requires a file-based batch fallback behind this same
/// seam, because a macOS 26.3 repro shows the streaming `start(inputSequence:)`
/// path failing with `nilError` while the file path works.
public protocol Transcriber: Sendable {
    /// `bias` is honoured differently per path and that is M2's deciding
    /// experiment (Part 0 §0.1): native `contextualStrings` on
    /// `DictationTranscriber`, or post-ASR rescoring on `SpeechTranscriber`.
    func begin(locale: Locale, bias: [BiasTerm]) async throws

    /// Volatile events replace, finalized events append. See `TranscriptEvent`.
    var results: AsyncStream<TranscriptEvent> { get }

    func end() async throws -> Transcript
}
