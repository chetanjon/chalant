import Foundation

/// The words this user says that the engine has never heard of.
///
/// **Empty by default, and that is the honest state of the feature.** There is
/// no term store yet and no editor, so today this is populated by hand:
///
/// ```
/// defaults write com.cj.chalant dictationTerms -array Chalant Kizu Aatram
/// ```
///
/// M5's correction learner is what fills it properly, by watching what the user
/// fixes rather than asking them to type it. That is the whole differentiator:
/// every competitor makes you type your aliases by hand, and each one is a
/// mistake you already suffered, noticed, diagnosed and then went into settings
/// to record.
///
/// **Canonical spelling matters and is easy to get wrong.** Whatever is stored
/// here is what gets inserted into the user's document, so `Chalant` and
/// `PostHog` must be spelled the way they should appear. The eval scorer
/// lowercases before comparing, which means a lowercase list scores identically
/// and quietly inserts `"ship chalant to the kizu group"`. The metric cannot see
/// that failure; only reading the output can.
enum Vocabulary {

    static let key = "dictationTerms"

    /// Part 0 §0.13, and it is a locked constant rather than an API limit:
    /// published curves agree that biasing gains peak near 100 terms and
    /// degrade beyond it, with one documented case of overall WER going 2.42 to
    /// 5.99 when a list grew from 100 to 500. **A bigger dictionary is a bigger
    /// false-positive surface, not a bigger safety net.** Terms that are not in
    /// the audio are distractors.
    static let activeLimit = 100

    static func terms(in defaults: UserDefaults = .standard) -> [String] {
        let stored = defaults.array(forKey: key) as? [String] ?? []
        var seen = Set<String>()
        var out: [String] = []
        for term in stored {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
            if out.count == activeLimit { break }
        }
        return out
    }
}
