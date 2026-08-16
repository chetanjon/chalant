import Foundation

/// Decides whether a word the engine heard should be replaced by one it knows.
///
/// **This type exists to say no.** `PhoneticKey` collides on ordinary English:
/// `cat`, `cut` and `kite` all reduce to `KT`. A matcher built on similarity
/// alone would replace "cat" with "cut" the moment "cut" was in the vocabulary,
/// which is the failure the whole category is hated for. Part 1 §1 is explicit:
///
/// > Similarity is candidate *generation* only; the decision compares acoustic
/// > scores for candidate vs. original. **Never substitute on text resemblance
/// > alone.**
///
/// The eventual decision layer is CTC rescoring through FluidAudio, comparing
/// acoustic scores for candidate and original. That is not built. Until it is,
/// this uses the strongest acoustic evidence the engine already hands us: the
/// per-run confidence measured on 2026-08-15 as present on **100% of finalized
/// runs** and absent from every volatile one, ranging 0.01 to 0.998.
///
/// So the rule is: **a confident word is never touched.** Substitution needs
/// the engine to have been unsure, and a candidate that sounds close. Both, or
/// nothing happens.
public enum TermMatcher {

    public struct Decision: Equatable, Sendable {
        /// What to use instead, or nil to leave the word exactly as heard.
        public let replacement: String?
        /// Why, in words. Every refusal carries a reason, because a matcher
        /// that silently declines is undiagnosable; the same lesson the
        /// push-to-talk state machine learned the hard way.
        public let reason: String

        public static func keep(_ reason: String) -> Decision {
            Decision(replacement: nil, reason: reason)
        }
        public static func use(_ term: String, _ reason: String) -> Decision {
            Decision(replacement: term, reason: reason)
        }
    }

    /// The similarity a candidate must clear, by how many terms are competing.
    ///
    /// **Part 0 §0.13, and the numbers are FluidAudio's, tuned on named
    /// benchmarks rather than invented here.** At 670 terms with a 0.55 floor,
    /// FDA-extended produced 33 false positives; raising to 0.60 cut that to 8
    /// at the cost of a single true positive. Terms that are *not* in the audio
    /// are distractors, and a bigger dictionary is a bigger false-positive
    /// surface, not a bigger safety net.
    public static func threshold(forVocabularySize n: Int, wordLength: Int = 99) -> Double {
        let tuned: Double
        switch n {
        case ...10: tuned = 0.50
        case 11...100: tuned = 0.55
        default: tuned = 0.60
        }

        // Part 5 §3, and the figure Yap arrived at independently: a short word
        // has few sounds to disagree about, so a given similarity means much
        // less. `shortWordSimilarity 0.80`, `shortWordMaxLength 4`.
        if wordLength <= 4 { return max(tuned, 0.80) }

        // **The premium, and why it is here.** Those tuned numbers are
        // FluidAudio's, and they were tuned for a system where CTC rescoring
        // makes the final call. We do not have that layer yet; confidence is
        // standing in for it, and it is weaker evidence. A weaker decision
        // demands a stricter filter ahead of it.
        //
        // Measured 2026-08-15 on the founder's own errors: every true match sat
        // at 0.75 or 1.00 (`Chatan`/`Chetan` 1.00, `Shalan`/`Chalant` 0.75) and
        // every false one at exactly 0.50 (`Monday`/`Chalant`,
        // `database`/`Supabase`, `deadline`/`Chetan`). The gap is real and this
        // sits inside it.
        //
        // UNTUNED, and marked so on purpose. It comes back down to the numbers
        // above when CTC lands, and until then it is swept on `--split dev`
        // like everything else rather than defended as a constant.
        return max(tuned, provisionalFloor)
    }

    /// The stricter bar that stands in for an acoustic decision layer.
    /// Temporary by design; see `threshold(forVocabularySize:wordLength:)`.
    public static let provisionalFloor = 0.65

    /// Above this, the engine was sure enough that nothing may overrule it.
    ///
    /// Deliberately not tuned: it is a starting point to sweep on `--split dev`
    /// once the corpus can score it, exactly as Part 0 §0.13 did for the
    /// thresholds above. Calling it tuned before it is measured would be the
    /// "optimizing before measuring" that Part 1 §3 bans.
    public static let confidenceFloor = 0.5

    /// Resolve one heard word against the active vocabulary.
    ///
    /// - Parameters:
    ///   - heard: the word as transcribed, punctuation already stripped.
    ///   - confidence: the engine's own, or nil when it did not say. **Nil is
    ///     unknown, never zero** (spec §31.5): a word with no evidence attached
    ///     is not a word we may overwrite.
    ///   - terms: the active list. §0.13 caps this at 100 after phonetic dedup.
    public static func resolve(
        heard: String, confidence: Double?, terms: [String]
    ) -> Decision {
        let word = heard.trimmingCharacters(in: .punctuationCharacters)
        guard !word.isEmpty else { return .keep("nothing to resolve") }
        guard !terms.isEmpty else { return .keep("no vocabulary") }

        // §0.14's rejection guard: a word that is already one of ours is
        // already right. This is what stops "Chetan" being "corrected" into
        // some other term that happens to sound near it.
        if terms.contains(where: { $0.compare(word, options: .caseInsensitive) == .orderedSame }) {
            return .keep("already a known term")
        }

        // Part 1 §1. Without acoustic evidence there is no decision to make,
        // only a guess, and a guess here rewrites words the user got right.
        guard let confidence else {
            return .keep("no confidence attached, so no evidence to act on")
        }
        guard confidence < confidenceFloor else {
            return .keep("engine was confident (\(String(format: "%.2f", confidence)))")
        }

        let floor = threshold(forVocabularySize: terms.count, wordLength: word.count)
        var best: (term: String, score: Double)?
        for term in terms {
            let score = PhoneticKey.similarity(word, term)
            if score >= floor, score > (best?.score ?? 0) { best = (term, score) }
        }

        guard let best else { return .keep("nothing sounded close enough") }
        return .use(
            best.term,
            "heard with confidence \(String(format: "%.2f", confidence)), "
                + "sounds like \(best.term) at \(String(format: "%.2f", best.score))")
    }
}
