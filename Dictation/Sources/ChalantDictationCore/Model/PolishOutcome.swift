/// What one release-time cleanup attempt actually did, in numbers the
/// corpus can keep.
///
/// This exists because the first `refinedAtOnce` flag lied: `polish`
/// returns the input unchanged when the model is unavailable and when
/// every chunk fails or is guard-rejected, and the caller counted any
/// non-empty reply as "refined at once". The campaign's headline metric
/// (2026-08-21) has to be derivable from facts, so the polisher now
/// reports the facts and the flag is a pure function of them, pinned by
/// `PolishOutcomeTests`.
public struct PolishOutcome: Sendable, Equatable {
    public enum Result: String, Sendable {
        /// The model answered inside the budget. `text` carries the
        /// reply; whether anything was CLEANED is `refinedAtOnce`.
        case landed
        /// The polisher's own per-chunk deadline expired.
        case budgetExpiredInner
        case modelUnavailable
        /// Under the 40-character line; the model does nothing useful
        /// there and is not asked.
        case belowMinimum
        case empty
    }

    public var result: Result
    /// The tidied text, only when `.landed`. Every other result keeps
    /// the caller's own text, which is the standing contract: a failure
    /// ships what would have shipped anyway.
    public var text: String?
    public var chunks: Int
    /// Chunks already tidied (or in flight) from the hold's tidy-ahead
    /// when the release arrived: the pretidy hit count.
    public var warmChunks: Int
    /// Chunks that shipped as dictated because the model call failed or
    /// the fidelity guard rejected the reply.
    public var failedChunks: Int
    /// No model reply had ever completed when this utterance began:
    /// the cold-start population the speed campaign hunts.
    public var coldStart: Bool
    /// Seconds since the last completed model reply, nil when never.
    public var secondsSinceLastPolish: Double?

    public init(
        result: Result, text: String?, chunks: Int, warmChunks: Int,
        failedChunks: Int, coldStart: Bool, secondsSinceLastPolish: Double?
    ) {
        self.result = result
        self.text = text
        self.chunks = chunks
        self.warmChunks = warmChunks
        self.failedChunks = failedChunks
        self.coldStart = coldStart
        self.secondsSinceLastPolish = secondsSinceLastPolish
    }

    /// The honest flag: the model landed inside the budget AND at least
    /// one chunk actually came back from it rather than shipping as
    /// dictated.
    public var refinedAtOnce: Bool {
        result == .landed && chunks > 0 && failedChunks < chunks
    }
}
