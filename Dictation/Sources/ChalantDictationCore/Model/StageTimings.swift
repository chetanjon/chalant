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
    /// Hotkey down to the microphone proving it can hear.
    ///
    /// Distinct from `engineStart`: the engine can be up while the input
    /// delivers digital silence, which is what a hardware-muted headset and a
    /// closed lid both do, and `confirmHearing` is what tells them apart.
    public var recordingReady: TimeInterval?
    /// End of speech to the finalized transcript. The number that decides
    /// whether "faster than cloud" is claimable at all.
    public var finalization: TimeInterval?
    /// The deterministic text pipeline (disfluency, punctuation, ITN).
    public var textPipeline: TimeInterval?
    /// The optional Foundation Models pass, when the user asked for it.
    public var polish: TimeInterval?
    /// Handing the text to the target app: the ⌘V going out.
    ///
    /// **Dispatch, not arrival.** Named `insertion` since M0 and summed into a
    /// figure called `keyReleaseToVisible`, which was a claim the measurement
    /// could not support: `SystemEventsPaste.run()` returns whether the
    /// AppleScript raised, and the text may have landed anywhere or nowhere.
    public var insertion: TimeInterval?

    /// Key release to the text being confirmed on screen, and nil unless it
    /// really was.
    ///
    /// Set only where `LandingCheck` came back `.confirmed`, which means the
    /// focused field answered before and after and had grown. Most apps people
    /// dictate into never answer, so this is nil most of the time, and that is
    /// the honest shape: a number that is present only when it means something
    /// beats a number that is always present and sometimes a guess.
    public var visibleConfirmed: TimeInterval?

    public init(
        engineStart: TimeInterval? = nil,
        recordingReady: TimeInterval? = nil,
        finalization: TimeInterval? = nil,
        textPipeline: TimeInterval? = nil,
        polish: TimeInterval? = nil,
        insertion: TimeInterval? = nil,
        visibleConfirmed: TimeInterval? = nil
    ) {
        self.engineStart = engineStart
        self.recordingReady = recordingReady
        self.finalization = finalization
        self.textPipeline = textPipeline
        self.polish = polish
        self.insertion = insertion
        self.visibleConfirmed = visibleConfirmed
    }

    /// Key release to the paste going out.
    ///
    /// **Renamed from `keyReleaseToVisible` on 2026-09-14, because that is
    /// not what it measures.** The last term is the time to dispatch a ⌘V,
    /// which is not the time for text to appear: the app may be slow, may
    /// paste somewhere else, or may drop the keystroke entirely, and Part 0
    /// §0.3 has said so since the ladder was designed. It is still the right
    /// number to steer speed work by, under a name that cannot be quoted as
    /// something it is not. `visibleConfirmed` is the one that may.
    public var keyReleaseToInsertDispatch: TimeInterval? {
        let parts = [finalization, textPipeline, polish, insertion].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}
