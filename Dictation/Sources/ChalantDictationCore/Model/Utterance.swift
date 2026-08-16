import Foundation

/// One word from the engine, with what little the engine will tell us about it.
///
/// `range` is deliberately NOT a silence signal. Part 0 §0.4: finalized
/// one-word ranges can be contiguous across real silence, so timings order
/// words and never measure gaps. Pause features come from VAD over the audio
/// we already own.
public struct Token: Sendable, Hashable {
    public let text: String
    /// Engine confidence where the engine reports one.
    public let confidence: Double?
    /// Segment alignment only. See the note above before using this.
    public let range: ClosedRange<TimeInterval>?

    public init(text: String, confidence: Double? = nil, range: ClosedRange<TimeInterval>? = nil) {
        self.text = text
        self.confidence = confidence
        self.range = range
    }
}

/// The streaming contract, modelled explicitly because getting it wrong is the
/// single most common streaming-ASR bug (Part 1 §3, Part 2 §6).
///
/// A `.volatile` event REPLACES the previous volatile span. A `.finalized`
/// event APPENDS and is immutable. Treating volatile as final is the classic
/// duplication bug, and it gets a unit test driving a scripted sequence.
public enum TranscriptEvent: Sendable, Hashable {
    case volatile([Token])
    case finalized([Token])
}

/// The finished result of one dictation.
public struct Transcript: Sendable, Hashable {
    public let tokens: [Token]
    /// Locale actually used, after `supportedLocale(equivalentTo:)`
    /// canonicalisation (Part 0 §0.6).
    public let locale: String
    public let timings: StageTimings

    public init(tokens: [Token], locale: String, timings: StageTimings = .init()) {
        self.tokens = tokens
        self.locale = locale
        self.timings = timings
    }

    /// The raw text, before any pipeline stage touches it. The invariant in
    /// Part 1 §2 is that this is always recoverable: every failure path
    /// returns the input unchanged.
    public var rawText: String {
        tokens.map(\.text).joined(separator: " ")
    }
}

/// A recorded dictation. Part 2 §7: this table does triple duty as recovery
/// history, latency telemetry, and eval corpus, so it exists from the first
/// milestone that produces text rather than being retrofitted.
public struct Utterance: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    /// What the engine produced, before the text pipeline.
    public let raw: String
    /// What was actually inserted, after the pipeline. Equal to `raw` whenever
    /// a stage failed, by the never-lose-text invariant.
    public let final: String
    /// Bundle identifier of the app the text was aimed at.
    public let targetBundleID: String?
    public let timings: StageTimings

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        raw: String,
        final: String,
        targetBundleID: String? = nil,
        timings: StageTimings = .init()
    ) {
        self.id = id
        self.startedAt = startedAt
        self.raw = raw
        self.final = final
        self.targetBundleID = targetBundleID
        self.timings = timings
    }
}
