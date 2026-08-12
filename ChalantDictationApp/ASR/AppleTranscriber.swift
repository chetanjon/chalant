import AVFoundation
import ChalantDictationCore
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
actor AppleTranscriber: Transcriber {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "asr")

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var eventContinuation: AsyncStream<TranscriptEvent>.Continuation?
    private var relayTask: Task<Void, Never>?
    private var assembler = TranscriptAssembler()
    private var canonicalLocale: Locale = .init(identifier: "en-US")

    private var eventStream: AsyncStream<TranscriptEvent>?

    nonisolated let id = UUID()

    /// Warm the analyzer before the user speaks.
    ///
    /// Part 0 §0.5 measured finalization at ~2.2s without preheat against
    /// ~1.45s with `prepareToAnalyze()`, so this is called at hotkey-down
    /// rather than lazily.
    func prepare(locale: Locale, format: AVAudioFormat?) async {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
        canonicalLocale = supported
        let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [module])
        self.transcriber = module
        self.analyzer = analyzer
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            Self.log.error("prepareToAnalyze failed: \(error.localizedDescription, privacy: .public)")
        }
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
    @discardableResult
    func drainAndFeed(from ring: AudioRing) -> Int {
        var moved = 0
        while let item = ring.read() {
            inputContinuation?.yield(AnalyzerInput(buffer: item.buffer))
            moved += 1
        }
        return moved
    }

    // MARK: - Internals

    private func publish(_ event: TranscriptEvent) {
        assembler.apply(event)
        eventContinuation?.yield(event)
    }

    /// Part 1 §2: transcripts never enter logs, so nothing here is logged.
    private static func tokens(from text: AttributedString) -> [Token] {
        String(text.characters)
            .split(separator: " ")
            .map { Token(text: String($0)) }
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
