import AVFoundation
import ChalantDictationCore
import Foundation
import os

/// Whisper, promoted from second ear to recognizer.
///
/// **It was always doing this job; it just never went first.** From 1.34.0 it
/// listened after Apple and corrected the words afterwards, and from 1.40.0
/// it argued with Apple before they landed. Both shapes are gone. What
/// remains is the model itself, already downloaded on any Mac that had
/// "Better hearing" switched on, and it is the only one of the three that can
/// be told a name before it listens.
///
/// The download, the load, the idle sleep and the wake are all still
/// `BetterHearing`'s, unchanged. This is the seam around them.
///
/// **The one thing it cannot give is per-word confidence.** WhisperKit
/// returns a segment's average log probability and its no-speech and
/// compression scores, which judge the whole hearing rather than each word.
/// So every token arrives with `confidence == nil`, `TermMatcher` reads nil
/// as "no evidence to act on" and refuses to substitute, and the phonetic
/// vocabulary pass is off on this engine. That is not a regression: it is
/// exactly what happened before, where the second ear's text went through
/// `BetterHearing.deterministic` with the vocabulary passes skipped for the
/// same reason. Aliases, span joins and everything the user has taught still
/// apply, because none of those ever looked at confidence.
@available(macOS 26, *)
actor WhisperTranscriber: SpeechEngine {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "asr")

    nonisolated let engineName = "whisper"

    /// Irrelevant here: with no per-word confidence, nothing this gates can
    /// fire. Kept at Apple's value so a future Whisper that does report one
    /// starts from the shared number rather than from an invention.
    nonisolated var confidenceFloor: Double { TermMatcher.confidenceFloor }

    /// Yes, and it is worth about ten word-error points on the names set:
    /// 29.9% with no prompt against 10.0% with the gated one
    /// (`verification/NAMES_2026-08-18.md`). It costs about 0.05 s a name,
    /// which is why `NameHints` chooses them per utterance and caps the list.
    nonisolated let usesHints = true

    private var tee = UtteranceTee()
    private var capture = RawCapture()
    private var locale = Locale(identifier: "en-US")
    private var hints: [String] = []

    func prepare(locale: Locale, format: AVAudioFormat?) async {
        self.locale = locale
    }

    func begin(locale: Locale, hints: [String]) async throws {
        self.locale = locale
        self.hints = hints
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

    /// Empty: Whisper is batch too.
    var liveTokens: [Token] { [] }

    func setCapture(to url: URL?) { capture.begin(writingTo: url) }
    func endCapture() { capture.end() }
    func setKeepsSamples(_ on: Bool) {}
    func utteranceSamples() -> [Float] { tee.samples }
    func releaseSamples() { tee.reset() }

    enum Failure: Error {
        case notReady
        case heardNothing
    }

    func end() async throws -> Transcript {
        guard tee.hasEnoughForRecognition else {
            Self.log.info("too little audio to recognise (\(self.tee.seconds, privacy: .public)s)")
            return Transcript(tokens: [], locale: locale.identifier)
        }
        guard await BetterHearing.shared.isReady else { throw Failure.notReady }
        guard let hearing = await BetterHearing.shared.hearFully(tee.samples, hints: hints) else {
            // Nil here is a decode that produced nothing usable, which is a
            // failure of this engine rather than a silence: the caller may
            // fall back on it.
            throw Failure.heardNothing
        }
        // Whisper's own three quality numbers judge the whole hearing, and
        // Part 0 §0.18 names them as the guard against text fabricated over
        // near-silence. With no second opinion left to check it against, they
        // are the only check there is, so a hearing that fails them is
        // refused rather than typed.
        if HearingMerge.qualityRefusal(hearing.quality, HearingMerge.Constants()) {
            Self.log.error("whisper refused its own hearing on quality; nothing is typed")
            throw Failure.heardNothing
        }
        let tokens = hearing.text.split(whereSeparator: \.isWhitespace).map { Token(text: String($0)) }
        return Transcript(tokens: tokens, locale: locale.identifier)
    }
}
