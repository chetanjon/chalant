import AVFoundation
import ChalantDictationCore
import Foundation
import os

/// One utterance through Parakeet, behind the `SpeechEngine` seam.
///
/// Thin on purpose: the model, its download and its lifetime belong to
/// `ParakeetEngine.shared`, which outlives any one hold. This type owns the
/// audio of a single utterance and the decode at the end of it.
///
/// **What it does not do, and the reasons are read from FluidAudio's source
/// at the pinned tag rather than from its documentation:**
///
/// - **No live text.** `AsrManager` is batch. `liveTokens` is empty, so
///   "clean while you talk" simply does not run here. It degrades to doing
///   nothing rather than to doing something wrong.
/// - **No chunking of our own.** Above 240,000 samples the library splits the
///   audio itself, with 2 s overlaps and its own seam reconciliation, and
///   documents those figures as derived from the encoder window and not
///   runtime-configurable. Hand-rolling overlap here would fight it.
/// - **No vocabulary hints.** The batch API has no biasing, hotword or
///   prompt parameter at 0.15.7. Its CTC rescoring path does, at the cost of
///   a second 97.5 MB model and roughly a quarter of the throughput; that is
///   a measured decision for another day and is recorded in the EVAL-LOG
///   rather than guessed at here. Names are repaired after the fact, by the
///   passes that have always done it.
@available(macOS 26, *)
actor ParakeetTranscriber: SpeechEngine {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "asr")

    nonisolated let engineName = "parakeet"

    /// **Swept, not assumed, and the first guess was wrong.**
    ///
    /// This shipped provisionally at 0.45 on the reasoning that 0.6 is a fact
    /// about Apple's distribution and another model's softmax is another
    /// scale. True as far as it went, and it left the vocabulary layer almost
    /// switched off. `tools/floorsweep` over the 30 `propernoun` rows, using
    /// this engine's own tokens and the founder's real term list:
    ///
    /// ```
    /// confidence   wins  losses      (similarity 0.65 to 0.75, shield on)
    ///       0.30      0       0      does nothing
    ///       0.40      1       0
    ///       0.50      5       0
    ///       0.60      8       0      <- here
    /// ```
    ///
    /// Zero losses at every cell, so the risk this floor exists to manage
    /// does not appear on this corpus; what a low floor costs is repairs.
    /// Apple sweeps identically on the same rows (10 wins, 0 losses at 0.60),
    /// which is the useful part: the two engines want the same number for
    /// different reasons, so `TermMatcher.confidenceFloor` is shared again
    /// rather than forked.
    ///
    /// Still the narrow reading of a narrow set: 30 rows, one speaker, and
    /// losses are what would change this, so re-sweep before moving it.
    nonisolated var confidenceFloor: Double { TermMatcher.confidenceFloor }

    /// How a word's confidence is read off its pieces. Swept, not chosen; see
    /// `SubwordAssembly.Aggregation`.
    static let aggregation: SubwordAssembly.Aggregation = .minimum

    nonisolated let usesHints = false

    private var tee = UtteranceTee()
    private var capture = RawCapture()
    private var locale = Locale(identifier: "en-US")

    // MARK: - SpeechEngine

    /// Nothing to warm: the model is loaded once by `ParakeetEngine` and
    /// stays loaded, and a fresh decoder state costs nothing. The format is
    /// the tee's problem and it works it out per buffer.
    func prepare(locale: Locale, format: AVAudioFormat?) async {
        self.locale = locale
    }

    func begin(locale: Locale, hints: [String]) async throws {
        self.locale = locale
        tee.reset()
    }

    @discardableResult
    func drainAndFeed(from ring: AudioRing) -> Int {
        var moved = 0
        while let item = ring.read() {
            capture.write(item.buffer)
            tee.append(item.buffer)
            moved += 1
        }
        return moved
    }

    /// Empty, always. A batch engine has nothing to say until the audio ends.
    var liveTokens: [Token] { [] }

    func setCapture(to url: URL?) { capture.begin(writingTo: url) }

    func endCapture() { capture.end() }

    /// Always keeps them: they are this engine's only input.
    func setKeepsSamples(_ on: Bool) {}

    func utteranceSamples() -> [Float] { tee.samples }

    func releaseSamples() { tee.reset() }

    func end() async throws -> Transcript {
        guard tee.hasEnoughForRecognition else {
            // Not a failure and never a fallback: too little audio is
            // silence, and the caller says so in those words.
            Self.log.info("too little audio to recognise (\(self.tee.seconds, privacy: .public)s)")
            return Transcript(tokens: [], locale: locale.identifier)
        }
        if tee.truncated {
            Self.log.error("the utterance was longer than the cap; the tail was not heard")
        }
        let hearing = try await ParakeetEngine.shared.hear(tee.samples, aggregation: Self.aggregation)
        return Transcript(tokens: hearing.tokens, locale: locale.identifier)
    }
}
