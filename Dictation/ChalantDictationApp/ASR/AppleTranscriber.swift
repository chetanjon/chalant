import AVFoundation
import ChalantDictationCore
import CoreMedia
import Foundation
import Speech
import os

/// Apple's on-device ASR behind the `Transcriber` seam.
///
/// **Module choice is provisional.** Part 0 §0.1 reports, CONFIRMED by two
/// independent research passes, that `AnalysisContext.contextualStrings` does
/// not bias `SpeechTranscriber` at all: the API accepts the strings and
/// silently ignores them on this module, and only `DictationTranscriber`
/// honours them. Which module wins is an empirical question settled by the
/// smoke test that runs immediately after M0. M0 uses `SpeechTranscriber`
/// because M0 applies no bias, so the difference cannot bite yet, and the seam
/// makes the swap cheap when the experiment answers.
///
/// Gated to macOS 26 by the merge. `SpeechAnalyzer`, `SpeechTranscriber` and
/// `AnalyzerInput` have no backport, and Chalant's floor is macOS 15. The
/// `Transcriber` protocol it conforms to lives in Core and stays ungated, so a
/// future engine could serve older systems through the same seam.
@available(macOS 26, *)
actor AppleTranscriber: Transcriber {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "asr")

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var eventContinuation: AsyncStream<TranscriptEvent>.Continuation?
    private var relayTask: Task<Void, Never>?
    private var assembler = TranscriptAssembler()
    private var canonicalLocale: Locale = .init(identifier: "en-US")
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private var eventStream: AsyncStream<TranscriptEvent>?

    /// Optional corpus capture. Writes the RAW microphone buffers, before the
    /// conversion into the analyzer's format, so a captured utterance can be
    /// replayed through any engine or locale later rather than only this one.
    ///
    /// Created lazily on the first buffer because that is the first moment the
    /// microphone's real format is known. Safe here and nowhere else: this
    /// actor drains the ring, so the file write is off the real-time audio
    /// thread that Part 1 §2 forbids doing any work on.
    private var captureURL: URL?
    private var captureFile: AVAudioFile?

    nonisolated let id = UUID()

    /// Warm the analyzer before the user speaks.
    ///
    /// Part 0 §0.5 measured finalization at ~2.2s without preheat against
    /// ~1.45s with `prepareToAnalyze()`, so this is called at hotkey-down
    /// rather than lazily.
    func prepare(locale: Locale, format micFormat: AVAudioFormat?) async {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
        canonicalLocale = supported
        // **Not a preset, and the reason is measured.** Phase 0 read the
        // presets' real contents: `.progressiveTranscription` is
        // `reporting: [fastResults, volatileResults]`, `attributes: []`. No
        // attributes at all, so the shipping app had no confidence, no timings
        // and no alternatives, and no preset combines volatile with both. The
        // explicit initialiser is the only way to ask for all three.
        //
        // `.fastResults` is kept deliberately: it is what the old preset used,
        // and the 0.149s finalization measured on 2026-08-15 was measured with
        // it. Dropping it would be an unmeasured change to a launch claim.
        let module = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .alternativeTranscriptions, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        let analyzer = SpeechAnalyzer(modules: [module])
        self.transcriber = module
        self.analyzer = analyzer

        // The analyzer does not accept whatever the microphone happens to
        // produce. Feeding it a raw 48kHz tap buffer traps inside
        // `AnalyzerInput.init(buffer:)` with EXC_BREAKPOINT, which reads as a
        // crash in our own code rather than a format mismatch. Ask the
        // framework what it wants and convert into that.
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module],
            considering: micFormat
        )
        self.analyzerFormat = analyzerFormat

        if let micFormat, let analyzerFormat, micFormat != analyzerFormat {
            // One converter per session: sample-rate conversion is stateful,
            // and a fresh one per buffer would click at every boundary.
            converter = AVAudioConverter(from: micFormat, to: analyzerFormat)
        } else {
            converter = nil
        }

        do {
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
        } catch {
            Self.log.error("prepareToAnalyze failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Convert one tap buffer into the analyzer's format.
    ///
    /// Returns nil rather than trapping when conversion fails: Part 1 §2 says
    /// never lose the user's text, and dropping one buffer with a logged
    /// reason beats taking the process down mid-utterance.
    private func converted(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let analyzerFormat else { return nil }
        guard let converter else { return buffer }

        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        if let error {
            Self.log.error("audio conversion failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }

    // MARK: - Transcriber

    func begin(locale: Locale, bias: [BiasTerm]) async throws {
        assembler.reset()

        if analyzer == nil {
            await prepare(locale: locale, format: nil)
        }
        guard let analyzer, let transcriber else { throw TranscriberError.notPrepared }

        // M0 applies no bias. When M2 settles the module question this is
        // where the terms attach, and Part 0 §0.13 caps the active list at
        // 100 after phonetic dedup.
        _ = bias

        let (inputs, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputCont

        let (events, eventCont) = AsyncStream<TranscriptEvent>.makeStream()
        self.eventContinuation = eventCont
        self.eventStream = events

        // Relay engine results onto our own seam, preserving the
        // volatile/finalized distinction that `TranscriptAssembler` depends on.
        relayTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let tokens = Self.tokens(from: result.text)
                    let event: TranscriptEvent = result.isFinal ? .finalized(tokens) : .volatile(tokens)
                    await self?.publish(event)
                }
            } catch {
                Self.log.error("result stream ended: \(error.localizedDescription, privacy: .public)")
            }
        }

        try await analyzer.start(inputSequence: inputs)
    }

    nonisolated var results: AsyncStream<TranscriptEvent> {
        // The stream is created in `begin`; callers await it there first.
        AsyncStream { continuation in
            Task { [weak self] in
                guard let stream = await self?.eventStream else { continuation.finish(); return }
                for await event in stream { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    func end() async throws -> Transcript {
        inputContinuation?.finish()
        inputContinuation = nil

        // Flush whatever is still in flight rather than dropping it. Part 1
        // §2: never lose the user's text.
        try await analyzer?.finalizeAndFinishThroughEndOfInput()

        relayTask?.cancel()
        relayTask = nil
        eventContinuation?.finish()
        eventContinuation = nil

        let tokens = assembler.finalized + assembler.uncommitted
        return Transcript(tokens: tokens, locale: canonicalLocale.identifier)
    }

    /// Drain the ring and feed everything in it to the analyzer.
    ///
    /// The draining happens here, inside this actor, precisely so the
    /// non-`Sendable` `AVAudioPCMBuffer` never crosses an isolation boundary.
    /// The ring travels between actors instead; the buffers do not.
    ///
    /// Returns how many buffers moved, so the caller can tell a silent engine
    /// from an idle one.
    /// Tee this utterance's audio to `url`. Nil turns capture off again.
    func setCapture(to url: URL?) {
        captureFile = nil
        captureURL = url
    }

    /// Close the capture file so the samples are on disk before anyone reads it.
    func endCapture() {
        captureFile = nil
        captureURL = nil
    }

    @discardableResult
    func drainAndFeed(from ring: AudioRing) -> Int {
        var moved = 0
        while let item = ring.read() {
            if let url = captureURL {
                if captureFile == nil {
                    captureFile = try? AVAudioFile(
                        forWriting: url, settings: item.buffer.format.settings)
                }
                // Best effort by design: losing a corpus buffer must never cost
                // the user their words, so this never throws outward.
                try? captureFile?.write(from: item.buffer)
            }
            guard let ready = converted(item.buffer) else { continue }
            inputContinuation?.yield(AnalyzerInput(buffer: ready))
            moved += 1
        }
        return moved
    }

    // MARK: - Internals

    /// What the user should see right now: everything committed plus the
    /// provisional span, exactly once.
    var liveText: String { assembler.displayText }

    /// The tokens the engine has committed so far, mid-utterance. Finals arrive
    /// over distinct, non-overlapping ranges and never change afterwards, which
    /// is what lets "clean while you talk" tidy them before the key comes up.
    var finalizedTokens: [Token] { assembler.finalized }

    private func publish(_ event: TranscriptEvent) {
        assembler.apply(event)
        eventContinuation?.yield(event)
    }

    /// Part 1 §2: transcripts never enter logs, so nothing here is logged.
    ///
    /// This function used to be `String(text.characters).split(separator: " ")`,
    /// which threw away every attribute the engine had attached. The decision
    /// of how runs become words is pure and lives in `TokenAssembly` with its
    /// own tests; all that happens here is the translation out of the SDK's
    /// types, so that Core keeps importing only Foundation.
    private static func tokens(from text: AttributedString) -> [Token] {
        TokenAssembly.tokens(
            from: text.runs.map { run in
                let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
                return TokenAssembly.Run(
                    text: String(text[run.range].characters),
                    confidence: run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self],
                    start: range.map { CMTimeGetSeconds($0.start) },
                    end: range.map { CMTimeGetSeconds($0.end) })
            })
    }
}

enum TranscriberError: Error, LocalizedError {
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .notPrepared: return "The speech engine was not ready."
        }
    }
}
