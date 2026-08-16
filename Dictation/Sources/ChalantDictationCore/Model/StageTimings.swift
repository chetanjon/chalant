import Foundation

/// Per-stage durations for one utterance.
///
/// Part 0 §0.5 demoted the latency budget from a spec constant to an empirical
/// gate: measured finalization on real hardware runs ~1.45s warm, ~2.2s cold,
/// so no public latency claim is made until this struct has numbers in it from
/// the target Mac. The claim that is safe without measurement is CONSISTENCY,
/// meaning no network variance, not a millisecond figure.
///
/// Part 1 §3 also bans optimising before measuring: no performance change
/// lands without a before and after from here or the corpus.
public struct StageTimings: Sendable, Hashable {
    /// Hotkey down to the engine accepting audio.
    public var engineStart: TimeInterval?
    /// End of speech to the finalized transcript. The number that decides
    /// whether "faster than cloud" is claimable at all.
    public var finalization: TimeInterval?
    /// The deterministic text pipeline (disfluency, punctuation, ITN).
    public var textPipeline: TimeInterval?
    /// The optional Foundation Models pass, when the user asked for it.
    public var polish: TimeInterval?
    /// Handing the text to the target app.
    public var insertion: TimeInterval?

    public init(
        engineStart: TimeInterval? = nil,
        finalization: TimeInterval? = nil,
        textPipeline: TimeInterval? = nil,
        polish: TimeInterval? = nil,
        insertion: TimeInterval? = nil
    ) {
        self.engineStart = engineStart
        self.finalization = finalization
        self.textPipeline = textPipeline
        self.polish = polish
        self.insertion = insertion
    }

    /// What the user actually waits through: key release to text on screen.
    /// This is the p95 figure M2 has to record.
    public var keyReleaseToVisible: TimeInterval? {
        let parts = [finalization, textPipeline, polish, insertion].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}
