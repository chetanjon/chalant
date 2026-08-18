import ChalantDictationCore
import Foundation

/// The names both ears know, gathered in one place so the two never disagree
/// about whose vocabulary this is.
///
/// Three sources, in the order they are trusted:
///
/// 1. **Typed by hand** (`Vocabulary`, "Add a name" in Settings): the user's
///    own spelling, so it goes first and as written.
/// 2. **Learned** (`LearnedTerms`): what they fixed after Chalant wrote for
///    them, once trusted by the ledger's rules.
/// 3. **Contacts** (`ContactNames`): the wide pool, read only when macOS
///    already allows it. A contact reaches an ear only when it sounds like
///    something in the utterance (`NameHints`), so the size of the address
///    book never decides which names get in.
///
/// The first two are the standing list and travel every time. Both ears call
/// here with what the first ear heard; each gets its own cap.
enum Names {

    /// The standing names, in trust order, each spelling once.
    static func standing() async -> [String] {
        let typed = Vocabulary.terms()
        let learned = await LearnedTerms.shared.terms()
        var seen = Set<String>()
        return (typed + learned).filter { seen.insert($0.lowercased()).inserted }
    }

    /// The names the second ear reads before it listens: the standing list,
    /// then the contacts that sound like something in what was heard, capped
    /// at `NameHints.promptLimit` because a longer prompt made it slower and
    /// worse on Set E.
    static func forHearing(heard: String) async -> [String] {
        NameHints.select(
            heard: heard,
            always: await standing(),
            pool: await ContactNames.shared.pool())
    }

    /// The sound-alikes the matching pass may draw on. At most `Vocabulary.activeLimit`
    /// (§0.13's locked cap), and at most `matchingCandidateLimit` of them from
    /// Contacts, so the names the user gave or taught always keep their slots.
    static func forMatching(heard: String) async -> [String] {
        NameHints.select(
            heard: heard,
            always: await standing(),
            pool: await ContactNames.shared.pool(),
            limit: Vocabulary.activeLimit,
            candidateLimit: matchingCandidateLimit)
    }

    /// Forty of a hundred: enough for any one sentence's sound-alikes, and
    /// sixty slots that no address book can take from the standing list.
    static let matchingCandidateLimit = 40
}
