import Foundation

/// Removes what the speaker did not mean to say twice.
///
/// **Part 0 §0.16 sets the bar and it is deliberately high:** rules delete only
/// high-confidence patterns, and *"anything ambiguous ships verbatim."*
/// Mis-deleting a meaning-bearing token is the documented failure mode of this
/// whole stage, and it is worse than leaving a stutter in.
///
/// **Measured 2026-08-15**, on the founder's own baseline. Three of thirty
/// English utterances came back with an exact repetition and nothing else
/// wrong:
///
/// ```
/// The the ABI key ends in 472.
/// The the deadline is the 21st, not the 12th.
/// Reply to reply to Aidan and do not copy anyone else.
/// ```
///
/// Two are a doubled word, one is a doubled phrase. That is the entire pattern
/// this type handles, and it handles nothing else on purpose.
public enum Disfluency {

    /// Doublings that are ordinary English and must survive untouched.
    ///
    /// "He had had enough" and "I know that that is true" are both correct.
    /// A rule that collapses them is not cleaning up, it is introducing an
    /// error into text the speaker got right.
    private static let legitimateDoublings: Set<String> = ["had", "that"]

    /// The longest repeated phrase worth collapsing. Beyond three tokens a
    /// repetition is far more likely to be deliberate, and the cost of being
    /// wrong grows with the span.
    private static let maxPhrase = 3

    /// Collapse an immediately repeated token or short phrase.
    ///
    /// Case-insensitive, because a stutter usually starts a sentence and the
    /// engine capitalises the first one ("The the"). The FIRST occurrence is
    /// what survives, so the capitalisation the sentence needs is preserved.
    ///
    /// Punctuation rides along with its token, so "Reply to, reply to" is not
    /// treated as a repetition of "Reply to". That is intentional: a comma
    /// between them usually means the speaker meant both.
    public static func collapsingRepetitions(_ text: String) -> String {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count > 1 else { return text }

        // Longest phrase first: "reply to reply to" must collapse as a pair,
        // not leave "to" behind after a single-token pass.
        for span in stride(from: maxPhrase, through: 1, by: -1) {
            var i = 0
            while i + 2 * span <= tokens.count {
                let a = tokens[i..<(i + span)]
                let b = tokens[(i + span)..<(i + 2 * span)]
                if matches(a, b) {
                    tokens.removeSubrange((i + span)..<(i + 2 * span))
                    continue   // re-test at i: three in a row collapses to one
                }
                i += 1
            }
        }
        return tokens.joined(separator: " ")
    }

    private static func matches(_ a: ArraySlice<String>, _ b: ArraySlice<String>) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            let lx = x.lowercased(), ly = y.lowercased()
            // A token carrying punctuation is a boundary the speaker made.
            if x.contains(where: { $0.isPunctuation }) { return false }
            guard lx == ly, !lx.isEmpty else { return false }
            if legitimateDoublings.contains(lx) { return false }
            // Never collapse on something with no letters: numbers repeat for
            // real reasons ("15 15 Main Street") and a lost digit is the exact
            // class the fidelity guard exists to protect.
            guard lx.contains(where: { $0.isLetter }) else { return false }
        }
        return true
    }
}
