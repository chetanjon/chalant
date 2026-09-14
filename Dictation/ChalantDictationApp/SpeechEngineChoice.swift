import Foundation

/// Which ear hears you.
///
/// **One recognizer runs per dictation, and that is the change 1.42.0 is
/// about.** From 1.40.0 to 1.41.0 two ran on every utterance and their
/// answers were reconciled before the words landed. It bought real
/// corrections and it cost the whole wait: the only measurement of it is two
/// rows at 3.48 s and 3.11 s from key-release to words, against a p50 of
/// 0.40 s on the build before. Nearly half of those waits bought nothing at
/// all, because the two ears wrote identical words on 45% of rows and nothing
/// tells you which half beforehand.
///
/// So the second ear becomes a choice rather than a passenger, and the choice
/// is honest about what each one is.
enum SpeechEngineChoice: String, CaseIterable, Sendable {
    /// Apple's `SpeechTranscriber`. Always available on macOS 26, nothing to
    /// download, per-word confidence the vocabulary layer is tuned against.
    case apple
    /// Parakeet TDT v3 through FluidAudio. 470 MB once, then the fastest of
    /// the three by an order of magnitude.
    case parakeet
    /// Whisper large-v3-turbo through WhisperKit. 606 MB once. The only one
    /// that can be told names before it listens.
    case whisper

    static let key = "dictationEngine"

    /// **The shipped default, and it is a measurement rather than a
    /// preference.**
    ///
    /// `Dictation/CLAUDE.md` §0.12 ruled on this engine before it existed:
    /// Parakeet's closest public lineage scores roughly twice the word error
    /// of Whisper on Indian-accented English, and "if Parakeet underperforms
    /// the Apple default on the corpus, cut its engine role". The founder's
    /// answer when asked was that the shipped default should follow the
    /// measurement, so this constant moves when `tools/engineprobe` says so
    /// and not before. The EVAL-LOG entry beside the change carries the
    /// numbers that moved it.
    static let shipped: SpeechEngineChoice = .parakeet

    /// The old switch, read only to migrate. On since 1.34.0, it meant "run
    /// Whisper as a second ear"; from 1.42.0 there is no second ear, so the
    /// engine somebody deliberately downloaded and turned on becomes their
    /// engine. Reinterpreting their choice as "you probably wanted the new
    /// thing" would be the app changing a setting on their behalf.
    ///
    /// Never written back, following `Cleanup.mode(in:)`: the old key is
    /// consulted on every read until they choose for themselves, and
    /// `object(forKey:) as? Bool` is what tells "explicitly on" from "never
    /// touched".
    static let legacyBetterHearingKey = "dictationBetterHearing"

    static func current(in defaults: UserDefaults = .standard) -> SpeechEngineChoice {
        if let raw = defaults.string(forKey: key), let choice = SpeechEngineChoice(rawValue: raw) {
            return choice
        }
        if let hadSecondEar = defaults.object(forKey: legacyBetterHearingKey) as? Bool, hadSecondEar {
            return .whisper
        }
        return shipped
    }

    static func set(_ choice: SpeechEngineChoice, in defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: key)
    }

    /// What the picker shows.
    var label: String {
        switch self {
        case .apple: return "Apple"
        case .parakeet: return "Parakeet"
        case .whisper: return "Whisper"
        }
    }

    /// Whether choosing this costs a download.
    var needsAModel: Bool { self != .apple }
}
