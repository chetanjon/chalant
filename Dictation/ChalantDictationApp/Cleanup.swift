import Foundation

/// Where the on-device model stands relative to the words you dictated.
///
/// Three positions since 2026-08-22, and the default is SHADOW:
///
/// - `off`: the model never runs.
/// - `shadow`: the words land as said, at once. Afterwards the model runs
///   once over the same text and its reply goes into the corpus row (the
///   output, the reason, the time it took) and nowhere else: never inserted,
///   never swapped in, never shown. The row is how the model is judged.
/// - `live`: the path as it shipped from 1.19.0 to 1.26.0: the model runs
///   while you hold the key and the release waits up to 0.65 s for its
///   reply; if it is ready and the guard passes, the tidied text lands.
///
/// Why shadow is the default: measured on 2026-08-22 over 90 scripted rows
/// (EVAL-LOG "WHAT DOES THE MODEL BUY?"), the model recovered 4 corrections
/// of 310 and added 1, every edit it made was a comma, a case change or one
/// deleted word, and it cost a median 0.6 s per call with 28% of calls over
/// the budget. That is not worth a wait on the path the user feels, and the
/// decision to put it back can only be taken from rows where it ran and was
/// read: shadow produces exactly those rows at no cost to the user.
///
/// History of the switch this replaced: on by default from 2026-08-14 (the
/// founder, twice: cleaned output like Wispr, "because people can just talk
/// whatever they want"), then instant-then-tidied-in-place (2026-08-17), then
/// land-once with a 0.65 s wait (2026-08-19). Routing (clean only what needs
/// it) was measured and rejected: confidence measures whether the engine
/// HEARD right while cleanup fixes what the speaker SAID (AUC 0.602).
enum Cleanup {
    enum Mode: String, CaseIterable {
        case off
        case shadow
        case live
    }

    static let modeKey = "dictationCleanupMode"
    /// The Bool switch of 1.14.0 to 1.26.0, read only to migrate: a switch
    /// turned off stays off; on, or never touched, becomes shadow.
    static let enabledKey = "dictationCleanup"

    static func mode(in defaults: UserDefaults = .standard) -> Mode {
        if let raw = defaults.string(forKey: modeKey), let mode = Mode(rawValue: raw) {
            return mode
        }
        if let old = defaults.object(forKey: enabledKey) as? Bool, old == false {
            return .off
        }
        return .shadow
    }

    static func setMode(_ mode: Mode, in defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }
}
