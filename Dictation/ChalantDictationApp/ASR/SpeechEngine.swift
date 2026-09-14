import AVFoundation
import ChalantDictationCore
import Foundation

/// What `DictationController` actually needs from a speech engine.
///
/// **Core's `Protocols/Transcriber.swift` is not this seam, and the
/// difference is why "swap the engine" was never as cheap as it looked.**
/// That protocol declares three members and has one conformer, and its
/// `results` stream has never been read by anything in the app: the
/// controller holds `AppleTranscriber` concretely and calls nine methods, six
/// of which the protocol does not declare, including `drainAndFeed(from:)`,
/// which couples the engine to `AudioRing` directly. Conforming a new engine
/// to `Transcriber` alone would have compiled and changed nothing.
///
/// So this is the seam that is actually wired, named after what it is.
/// Core's `Transcriber` stays where it is: `BiasTerm` rides on it and the
/// offline tools speak it.
///
/// **Ungated on purpose.** Only `AppleTranscriber` needs macOS 26. Keeping
/// the seam itself below that line is what would one day let dictation run at
/// Chalant's own macOS 15 floor on an engine that does not need 26. That is
/// not this change; `DictationController` is 26-gated throughout and
/// untangling it is its own piece of work.
protocol SpeechEngine: Actor {

    /// For the corpus row and the log. Never the user's words.
    nonisolated var engineName: String { get }

    /// The confidence below which `TermMatcher` may consider substituting a
    /// word.
    ///
    /// **Per engine, because the number describes the engine and not the
    /// matcher.** `TermMatcher.confidenceFloor` is 0.6 because that is where
    /// Apple's own distribution separates: its wrong words average 0.757 and
    /// its right ones 0.909, AUC 0.796 on the propernoun set. Another model's
    /// softmax is a different scale, and carrying Apple's number across to it
    /// unmeasured would be exactly the unvalidated transfer this project
    /// keeps a corpus to prevent. `TermMatcher.resolving` and
    /// `applyingEarCorrections` already take the floor as a parameter, so
    /// this costs Core nothing.
    nonisolated var confidenceFloor: Double { get }

    /// Whether this engine can be told names before it listens.
    ///
    /// Three different answers, all measured or read from source rather than
    /// assumed: Apple's `SpeechTranscriber` accepts `contextualStrings` and
    /// silently ignores them (Part 0 §0.1, CONFIRMED twice); FluidAudio's
    /// batch `AsrManager` has no biasing API at all at 0.15.7, and its CTC
    /// rescoring path costs a second model; WhisperKit reads a previous-text
    /// prompt, which is worth ~10 word-error points on the names set and
    /// about 0.05 s a name.
    nonisolated var usesHints: Bool { get }

    /// Bring the engine up against the microphone's format. Called at
    /// key-down, off the critical path where it can be.
    func prepare(locale: Locale, format: AVAudioFormat?) async

    /// Start an utterance. `hints` is empty unless `usesHints`.
    func begin(locale: Locale, hints: [String]) async throws

    /// Move everything waiting in the ring into the engine. Returns how many
    /// buffers moved, so a silent engine can be told from an idle one.
    ///
    /// The ring travels rather than its buffers: `AVAudioPCMBuffer` is not
    /// `Sendable`, and draining inside the engine's own isolation is what
    /// keeps it from crossing a boundary (Part 1 §3).
    @discardableResult func drainAndFeed(from ring: AudioRing) -> Int

    /// Everything heard so far, committed plus provisional.
    ///
    /// **Empty on a batch engine, and that is not a defect.** Only
    /// "clean while you talk" reads this, only in `live` cleanup mode, and a
    /// batch engine has nothing to say until the audio ends. It degrades to
    /// doing nothing rather than to doing something wrong.
    var liveTokens: [Token] { get }

    /// Tee the raw microphone buffers to a file for the corpus. Nil turns it
    /// off again.
    func setCapture(to url: URL?)

    /// Close the corpus file so the samples are on disk before anything reads
    /// the row that names them.
    func endCapture()

    /// Finalize and hand back the transcript.
    func end() async throws -> Transcript

    /// Whether to keep a 16 kHz mono copy of the utterance's audio.
    ///
    /// Asked at key-down, before the engine goes live, and never judged on
    /// readiness: gating this on whether a consumer was loaded yet is what
    /// silently lost a night of second hearings on 2026-08-20 (74 utterances,
    /// 5 hearings engaged). An engine that needs the copy for itself keeps it
    /// regardless of what it is told.
    func setKeepsSamples(_ on: Bool)

    /// The utterance's audio as 16 kHz mono, for whatever has to hear it
    /// again: a second engine, or the fallback when this one could not.
    func utteranceSamples() -> [Float]

    /// Let the audio go. Called on every path out of an utterance, so the
    /// samples live exactly as long as a failure might still need them.
    func releaseSamples()
}
