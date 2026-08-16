import Testing

@testable import ChalantDictationCore

/// The guard, tested harder than the win.
///
/// A vocabulary layer that fixes names is worth little; one that quietly
/// rewrites words the user said correctly is worth less than nothing, and is
/// the exact complaint the whole category attracts.
@Suite("TermMatcher")
struct TermMatcherTests {

    static let vocabulary = [
        "Chalant", "Chetan", "Jonnalagadda", "Kizu", "Aatram",
        "SpeechAnalyzer", "PostHog", "Supabase",
    ]

    // MARK: - The wins

    /// His own name, misheard in the locked set, with the engine unsure.
    @Test("an uncertain word that sounds like a known term is replaced")
    func fixesTheNames() {
        let d = TermMatcher.resolve(heard: "Chatan", confidence: 0.21, terms: Self.vocabulary)
        #expect(d.replacement == "Chetan")
    }

    /// **This case USED to pass and now deliberately does not, and the reason
    /// is the whole trade the 2026-08-15 sweep bought.**
    ///
    /// `Shalan` sits at 0.75 similarity to `Chalant`, and the similarity floor
    /// moved from 0.65 to 0.90 because that is where losses reached zero across
    /// all 90 corpus utterances. At 0.75 the matcher scored 12 wins against 5
    /// losses; at 0.90, 8 wins against 0. Five words the user got right, being
    /// silently rewritten, is not worth four extra repairs.
    ///
    /// **So this records a known miss, not a bug.** `Challant` -> `Chalant`
    /// still works, because the engine's usual error on this word is much
    /// closer than `Shalan`. If CTC rescoring lands and the floor comes down,
    /// this is the case to check first.
    @Test("a distant mishearing is now refused, and that is the trade")
    func distantMishearingsAreRefused() {
        let d = TermMatcher.resolve(heard: "Shalan", confidence: 0.18, terms: Self.vocabulary)
        #expect(d.replacement == nil)

        // The one that actually shows up in the corpus still lands.
        #expect(
            TermMatcher.resolve(heard: "Challant", confidence: 0.56, terms: Self.vocabulary)
                .replacement == "Chalant")
    }

    // MARK: - The guard, which matters more

    /// The case that makes similarity alone unusable. `cat` and `cut` share a
    /// phonetic key exactly as `Chatan` and `Chetan` do. The only thing that
    /// separates them is that the engine was sure about one of them.
    @Test("a confident word is never touched, however close it sounds")
    func neverOverrulesAConfidentEngine() {
        let d = TermMatcher.resolve(heard: "Chatan", confidence: 0.97, terms: Self.vocabulary)
        #expect(d.replacement == nil)
        #expect(d.reason.contains("confident"))
    }

    /// Nil is unknown, not zero (spec §31.5). Volatile runs carry no
    /// confidence, and a word with no evidence attached is not one we may
    /// overwrite.
    @Test("no confidence means no evidence, so nothing happens")
    func refusesWithoutEvidence() {
        #expect(
            TermMatcher.resolve(heard: "Chatan", confidence: nil, terms: Self.vocabulary)
                .replacement == nil)
    }

    /// §0.14's rejection guard: a word that is already one of ours is already
    /// right, and must never be "corrected" into a neighbour.
    @Test("a word that is already a known term is left alone")
    func rejectionGuard() {
        let d = TermMatcher.resolve(heard: "Chetan", confidence: 0.05, terms: Self.vocabulary)
        #expect(d.replacement == nil)
        #expect(d.reason.contains("already"))
    }

    /// Ordinary speech, even when the engine was unsure, must not be dragged
    /// toward the vocabulary just because something is vaguely near.
    @Test("ordinary words are not pulled into the dictionary")
    func leavesOrdinarySpeechAlone() {
        for word in ["production", "Monday", "database", "attendees", "deadline"] {
            let d = TermMatcher.resolve(heard: word, confidence: 0.2, terms: Self.vocabulary)
            #expect(d.replacement == nil, "\(word) became \(d.replacement ?? "-")")
        }
    }

    @Test("an empty vocabulary can never change anything")
    func doesNothingWithNoTerms() {
        #expect(TermMatcher.resolve(heard: "Chatan", confidence: 0.1, terms: []).replacement == nil)
    }

    // MARK: - Thresholds

    /// Part 0 §0.13: a bigger dictionary is a bigger false-positive surface,
    /// so the bar rises with it rather than staying put. That curve is
    /// FluidAudio's, tuned for a system where CTC makes the decision.
    ///
    /// While confidence is standing in for CTC, the provisional floor dominates
    /// the small-vocabulary end. **When CTC lands, deleting `provisionalFloor`
    /// should make this test fail**, which is how the temporary thing announces
    /// that it is no longer needed.
    @Test("the bar rises with the vocabulary, under a floor that is temporary")
    func thresholdScalesWithSize() {
        let small = TermMatcher.threshold(forVocabularySize: 5)
        let medium = TermMatcher.threshold(forVocabularySize: 50)
        let large = TermMatcher.threshold(forVocabularySize: 670)

        #expect(small <= medium)
        #expect(medium <= large)
        #expect(small == TermMatcher.provisionalFloor)
        #expect(large >= 0.60, "the tuned curve still shows through at the top")
    }

    /// Part 5 §3: a short word has few sounds to disagree about, so the same
    /// similarity means much less. `shortWordMaxLength 4`, `shortWordSimilarity 0.80`.
    ///
    /// **The rule is a floor among floors, never an override, and it used to be
    /// an override.** It returned 0.80 outright for short words, which meant
    /// that the moment the provisional floor rose above 0.80 a short word was
    /// held to a LOWER bar than a long one. Exactly backwards, and invisible to
    /// the threshold sweep, which passes an explicit similarity and never
    /// reaches this branch.
    @Test("a short word is never held to a lower bar than a long one")
    func shortWordsAreHarder() {
        let short = TermMatcher.threshold(forVocabularySize: 5, wordLength: 3)
        let long = TermMatcher.threshold(forVocabularySize: 5, wordLength: 9)
        #expect(short >= long)
        #expect(short >= 0.80)
    }

    /// Every decision explains itself, including the refusals. A matcher that
    /// silently declines is undiagnosable.
    @Test("every decision carries a reason")
    func alwaysExplainsItself() {
        for confidence in [nil, 0.1, 0.9] as [Double?] {
            let d = TermMatcher.resolve(heard: "Chatan", confidence: confidence, terms: Self.vocabulary)
            #expect(!d.reason.isEmpty)
        }
    }
}
