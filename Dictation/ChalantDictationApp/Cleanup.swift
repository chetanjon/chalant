import Foundation

/// Whether the on-device model tidies what you dictated.
///
/// **Off by default since 2026-08-17.** It was on by default from 2026-08-14
/// (the founder's decision, taken twice: cleaned output like Wispr, "because
/// people can just talk whatever they want"). Then, on the first evening they
/// dictated with a strip that lights up and says "sent", they felt the wait:
/// "the text is coming after two, three seconds." Measured on their own six
/// dictations that hour: 1.1 to 1.9 s for anything the model touched, 0.1 s
/// for anything it skipped, and prewarming the per-utterance session during
/// the hold measured no better (fresh 0.88 s median, prewarmed 1.03 s). Nothing
/// left to shave, so the choice was speed or tidy, and they chose "instant, as
/// I said it". The switch stays for anyone who wants tidy back.
///
/// **A switch at all, against law 6's "defaults over switches", for the same
/// reason `CorpusCapture` gets one: this is not a feature that is simply
/// better.** Measured 2026-08-16 on 42 real utterances, it costs ~1s at p50 and
/// 2.1s at p95, does nothing to half of real speech, and removes roughly half
/// the fillers in the rest. Trading a second of someone's time for a tidier
/// sentence is a trade they are entitled to decline, and dictation without it
/// is 0.05-0.23s end to end.
///
/// The alternative to a switch was routing: clean only the utterances that
/// needed it. **Measured and rejected** (AUC 0.602, a coin flip), because
/// confidence measures whether the engine HEARD right while cleanup fixes what
/// the speaker SAID.
enum Cleanup {
    static let enabledKey = "dictationCleanup"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? false
    }

    static func setEnabled(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: enabledKey)
    }
}
