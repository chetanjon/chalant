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
///
/// # Measured on the propernoun corpus, 2026-08-15: 8 repairs, 0 corruptions.
///
/// **An earlier version of this note said the opposite and it is worth knowing
/// why.** Before the `propernoun` set existed, this was measured as net harmful
/// and "not tunable". That was a true reading of a corpus containing **2
/// proper-noun errors in 225 words**. It was not a fact about the matcher. With
/// 30 utterances of the user's actual vocabulary the picture inverted, and the
/// lesson generalises: a layer cannot be judged on data that does not contain
/// the thing it exists to fix.
///
/// Across all 90 utterances, at the constants below:
///
/// ```
/// Kisu       -> Kizu           Challant   -> Chalant
/// Kisi       -> Kizu           Pribar     -> Prybar
/// versal     -> Vercel         Etram      -> Aatram
/// itrum      -> Aatram         Jonalagata -> Jonnalagadda
/// ```
///
/// **The one loss that survived every similarity threshold, and how it died.**
/// `"Never merge that branch without a review"` became `"...without a ravi"`.
/// `review` and `ravi` both reduce to `RF` under Double Metaphone, so they sit
/// at 1.00 similarity and no threshold on sound can ever separate them. Length
/// separates them: 33% apart, where every true repair above is within 17%. See
/// `withinLength`.
///
/// **Confidence's real job, also measured: telling you which words are wrong.**
/// AUC 0.796 on the propernoun set against the directive's 0.70 bar, which
/// answers Phase 0's open calibration question. Good enough to gate on, not good
/// enough to decide with, exactly as Part 1 §1 insisted before anyone measured
/// it. CTC rescoring remains the destination; this is a defensible waypoint.
///
/// **The vocabulary must carry canonical spelling.** `score.py` lowercases
/// before comparing, so a lowercase term list scores identically and inserts
/// `"ship chalant to the kizu group"` into the user's document. The metric
/// cannot see that failure. See `corpus/terms-canonical.txt`.
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
        //
        // **A floor among floors, never an override.** It used to `return`
        // here, which meant a short word could be held to a LOWER bar than a
        // long one the moment the provisional floor rose above 0.80. That is
        // backwards, and it went unnoticed because the sweep passes an explicit
        // similarity and never exercised this branch.
        let short = wordLength <= 4 ? 0.80 : 0

        // **The premium, and why it is here.** Those tuned numbers are
        // FluidAudio's, and they were tuned for a system where CTC rescoring
        // makes the final call. We do not have that layer yet; confidence is
        // standing in for it, and it is weaker evidence. A weaker decision
        // demands a stricter filter ahead of it.
        //
        // **Note what this means today: at 0.90 the provisional floor dominates
        // the tuned curve entirely, so the size-aware band above is currently
        // inert.** That is not an accident and not dead code to delete. It is
        // the correct band for a system whose decision is acoustic, and it
        // becomes live again the moment CTC rescoring replaces the floor.
        return max(tuned, provisionalFloor, short)
    }

    /// The stricter bar that stands in for an acoustic decision layer.
    /// Temporary by design; see `threshold(forVocabularySize:wordLength:)`.
    ///
    /// **SWEPT AND SET ON EVIDENCE, 2026-08-15.** Was 0.65, marked UNTUNED
    /// pending exactly this measurement. Swept 0.65 to 0.90 against confidence
    /// 0.30 to 0.60 over all 90 corpus utterances, counting wins (a wrong word
    /// became right) against losses (a right word became wrong):
    ///
    /// | similarity | wins | losses |
    /// |---|---|---|
    /// | 0.70 | 12 | 5 |
    /// | 0.80 | 10 | 2 |
    /// | **0.85 / 0.90** | **8** | **0** |
    ///
    /// 0.90 rather than 0.85 because the two measure identically and the last
    /// observed loss is at 0.80, so this stands a full step clear of the cliff
    /// rather than balancing on its edge.
    public static let provisionalFloor = 0.90

    /// Above this, the engine was sure enough that nothing may overrule it.
    ///
    /// **SWEPT AND SET ON EVIDENCE, 2026-08-15.** Was 0.5. At 0.90 similarity,
    /// over all 90 corpus utterances: 0.40 gives 1 win, 0.50 gives 4, and 0.60
    /// gives 8, with zero losses at every one of them. Raised to the top of
    /// that safe range.
    ///
    /// **It cannot go much higher, and the reason is the interesting one.**
    /// Proper-noun errors are CONFIDENT errors: on the propernoun set the
    /// engine's wrong words average 0.757 against 0.909 for its right ones, and
    /// it hears `Chalan` for `Chalant` at 0.87 because `Chalan` is a perfectly
    /// plausible sound. Confidence separates right from wrong well enough to
    /// measure (AUC 0.796) and nowhere near well enough to be the only gate.
    /// That is why the length guard exists and why CTC rescoring is still the
    /// destination.
    public static let confidenceFloor = 0.6

    /// Resolve one heard word against the active vocabulary.
    ///
    /// - Parameters:
    ///   - heard: the word as transcribed, punctuation already stripped.
    ///   - confidence: the engine's own, or nil when it did not say. **Nil is
    ///     unknown, never zero** (spec §31.5): a word with no evidence attached
    ///     is not a word we may overwrite.
    ///   - terms: the active list. §0.13 caps this at 100 after phonetic dedup.
    public static func resolve(
        heard: String, confidence: Double?, terms: [String],
        confidenceFloor: Double = TermMatcher.confidenceFloor,
        similarityFloor: Double? = nil
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

        let floor = similarityFloor
            ?? threshold(forVocabularySize: terms.count, wordLength: word.count)
        var best: (term: String, score: Double)?
        var refusedOnLength = false
        for term in terms {
            let score = PhoneticKey.similarity(word, term)
            guard score >= floor else { continue }
            guard withinLength(word, term) else { refusedOnLength = true; continue }
            if score > (best?.score ?? 0) { best = (term, score) }
        }

        guard let best else {
            return .keep(
                refusedOnLength
                    ? "sounded close but the length is too different"
                    : "nothing sounded close enough")
        }
        return .use(
            best.term,
            "heard with confidence \(String(format: "%.2f", confidence)), "
                + "sounds like \(best.term) at \(String(format: "%.2f", best.score))")
    }

    /// The most two words may differ in length and still be the same word
    /// misheard.
    ///
    /// **This exists because similarity cannot do it.** Measured on the
    /// propernoun corpus 2026-08-15: `review` and `ravi` both reduce to `RF`
    /// under Double Metaphone, so they sit at 1.00 and no similarity threshold
    /// separates them. `review` -> `ravi` was the last remaining loss at the
    /// best setting, and it is the worst kind, a correct ordinary word rewritten
    /// into a name.
    ///
    /// Length is the axis that does separate them. `review` (6) against `ravi`
    /// (4) is a 33% difference; every true repair on the same corpus differed by
    /// at most 17%. A ratio rather than an absolute, because two characters
    /// apart is nothing across long words and everything across short ones.
    public static let lengthTolerance = 0.25

    public static func withinLength(_ heard: String, _ term: String) -> Bool {
        let a = heard.count, b = term.count
        guard a > 0, b > 0 else { return false }
        return Double(abs(a - b)) / Double(max(a, b)) <= lengthTolerance
    }

    /// Words the filler stage is about to delete, and which must therefore
    /// never be turned into a name first.
    ///
    /// **This guard exists because of where the pass sits.** It runs on tokens,
    /// ahead of `Fillers`, because tokens are the only place confidence still
    /// exists. But a filler arrives exactly as an unsure two-letter word, which
    /// is the profile of a live substitution candidate. Without this, "uh"
    /// competes for the vocabulary a moment before it would have been removed.
    private static let notCandidates: Set<String> = [
        "uh", "um", "erm", "uhh", "umm", "hmm", "mmm",
    ]

    /// Walk one utterance, resolving each word against the active vocabulary.
    ///
    /// **Substitution is strictly one word for one word.** That keeps this pass
    /// safe to run ahead of the deterministic string stages, which delete
    /// tokens and would otherwise need their positions re-aligned, and it keeps
    /// Part 1 §2 trivially true: a vocabulary pass may change what a word says
    /// and may never change how many words there are.
    ///
    /// **The known gap, stated rather than hidden:** a term the engine split
    /// across two words (`PostHog` heard as `post hog`) cannot be repaired here,
    /// because no single token is wrong. Multi-token span matching is a separate
    /// piece of work; 4 of the 9 catalogued vocabulary failures need it.
    public static func resolving(
        tokens: [Token], terms: [String],
        confidenceFloor: Double = TermMatcher.confidenceFloor,
        similarityFloor: Double? = nil
    ) -> [Token] {
        guard !terms.isEmpty else { return tokens }

        return tokens.map { token in
            let (prefix, core, suffix) = split(token.text)
            guard !core.isEmpty, !notCandidates.contains(core.lowercased()) else { return token }
            // A word carrying a digit is a number, and numbers belong to the
            // fidelity guard rather than to a phonetic matcher.
            guard !core.contains(where: \.isNumber) else { return token }

            let decision = resolve(
                heard: core, confidence: token.confidence, terms: terms,
                confidenceFloor: confidenceFloor, similarityFloor: similarityFloor)
            guard let replacement = decision.replacement else { return token }

            // The engine's punctuation is the speaker's, not the term's, so it
            // stays exactly where it was.
            return Token(
                text: prefix + replacement + suffix,
                confidence: token.confidence,
                range: token.range)
        }
    }

    /// Peel punctuation off both ends, leaving the word itself in the middle.
    private static func split(_ text: String) -> (String, String, String) {
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "'" }
        guard let first = text.firstIndex(where: isWord),
            let last = text.lastIndex(where: isWord)
        else { return (text, "", "") }
        return (
            String(text[text.startIndex..<first]),
            String(text[first...last]),
            String(text[text.index(after: last)...])
        )
    }
}
