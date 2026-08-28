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
        /// The wait could not be won: more than one piece was missing, or
        /// the one missing piece was too long for the window
        /// (`CleanupPrompt.worthWaiting`). The words landed at once with
        /// ZERO wait; the pieces still run and land in the cache for the
        /// record. Born 2026-08-27, the founder's "as fast as possible".
        case notWorthTheWait
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
    /// One entry per chunk the model was asked about, in order: "landed",
    /// "rejected:<rule>" (the `FidelityGuard` check that fired) or
    /// "failed:<error>". The corpus row keeps these verbatim so a rejected
    /// real dictation says which rule rejected it (2026-08-21, Task 3).
    public var chunkReasons: [String]
    /// The model's reply per chunk after unwrapping, INCLUDING replies the
    /// guard rejected (empty when the call itself failed). Never written to
    /// the corpus row (a rejected reply is null there, by the founder's
    /// ruling); kept so the offline measurement can show a rejected reply
    /// beside its source and judge the guard (2026-08-22).
    public var chunkReplies: [String]

    public init(
        result: Result, text: String?, chunks: Int, warmChunks: Int,
        failedChunks: Int, coldStart: Bool, secondsSinceLastPolish: Double?,
        chunkReasons: [String] = [], chunkReplies: [String] = []
    ) {
        self.result = result
        self.text = text
        self.chunks = chunks
        self.warmChunks = warmChunks
        self.failedChunks = failedChunks
        self.coldStart = coldStart
        self.secondsSinceLastPolish = secondsSinceLastPolish
        self.chunkReasons = chunkReasons
        self.chunkReplies = chunkReplies
    }

    /// The honest flag: the model landed inside the budget AND at least
    /// one chunk actually came back from it rather than shipping as
    /// dictated.
    public var refinedAtOnce: Bool {
        result == .landed && chunks > 0 && failedChunks < chunks
    }

    /// The model's text for the corpus row: only when some chunk actually
    /// came back from it. When every chunk shipped as dictated the joined
    /// text is the input again, and the row must say so with a reason
    /// rather than pass the input off as a reply.
    public var modelText: String? {
        result == .landed && chunks > 0 && failedChunks < chunks ? text : nil
    }

    /// The corpus row's `modelReason` for this outcome: "landed", "gated",
    /// "skipped:<why>", "budgetExpired:inner", or, when every chunk shipped
    /// as dictated, the first chunk's own reason ("rejected:<rule>",
    /// "failed:<error>"). The caller adds "budgetExpired:caller" itself,
    /// because that outcome never arrives.
    public var modelReason: String {
        switch result {
        case .landed:
            return modelText != nil ? "landed" : (chunkReasons.first ?? "rejected:unknown")
        case .budgetExpiredInner: return "budgetExpired:inner"
        case .notWorthTheWait: return "skipped:notWorthTheWait"
        case .modelUnavailable: return "skipped:unavailable"
        case .belowMinimum: return "gated"
        case .empty: return "skipped:empty"
        }
    }
}
