import Testing

@testable import ChalantDictationCore

/// `TermMatcher.resolve` judges one word. This is the pass that walks an
/// utterance, and almost everything in it is about what the pass must NOT do.
@Suite("TermMatcher pass")
struct TermMatcherPassTests {

    static let terms = ["Chetan", "Chalant", "PostHog", "Supabase", "Aidan", "Sarah", "Sara"]

    private func token(_ text: String, _ confidence: Double?) -> Token {
        Token(text: text, confidence: confidence)
    }

    private func text(_ tokens: [Token]) -> String {
        tokens.map(\.text).joined(separator: " ")
    }

    // MARK: - Doing the job

    @Test("an unsure word that sounds like a term becomes the term")
    func substitutes() {
        let out = TermMatcher.resolving(
            tokens: [token("Chatan", 0.21)], terms: Self.terms)
        #expect(text(out) == "Chetan")
    }

    /// The word carries the engine's own punctuation. Replacing the word must
    /// not eat it: `resolve` strips punctuation to compare, and a naive pass
    /// writes the bare term back and silently deletes the comma.
    @Test("punctuation on the word survives the substitution")
    func keepsPunctuation() {
        let out = TermMatcher.resolving(
            tokens: [token("Chatan,", 0.21), token("(Chatan)", 0.21), token("Chatan.", 0.21)],
            terms: Self.terms)
        #expect(text(out) == "Chetan, (Chetan) Chetan.")
    }

    @Test("the term's own capitalisation wins, which is the whole point")
    func termCasingWins() {
        let out = TermMatcher.resolving(tokens: [token("chatan", 0.21)], terms: Self.terms)
        #expect(text(out) == "Chetan")
    }

    @Test("confidence and timing ride through a substitution unchanged")
    func preservesSignals() {
        let input = [Token(text: "Chatan", confidence: 0.21, range: 1.0...1.5)]
        let out = TermMatcher.resolving(tokens: input, terms: Self.terms)
        #expect(out.first?.confidence == 0.21)
        #expect(out.first?.range == 1.0...1.5)
    }

    // MARK: - Refusing the job, which is most of it

    @Test("a confident word is never touched, however much it sounds like a term")
    func confidentWordsSurvive() {
        let out = TermMatcher.resolving(tokens: [token("Chatan", 0.95)], terms: Self.terms)
        #expect(text(out) == "Chatan")
    }

    @Test("a word with no confidence is left alone: nil is unknown, not zero")
    func unknownConfidenceSurvives() {
        let out = TermMatcher.resolving(tokens: [token("Chatan", nil)], terms: Self.terms)
        #expect(text(out) == "Chatan")
    }

    @Test("an empty vocabulary changes nothing at all")
    func emptyVocabulary() {
        let input = [token("Chatan", 0.1), token("anything", 0.1)]
        #expect(TermMatcher.resolving(tokens: input, terms: []) == input)
    }

    /// The failure the category is hated for. `PhoneticKey` collides on
    /// ordinary English, so an unsure ordinary word sitting next to a
    /// similar-sounding term is the exact case that must not fire.
    @Test("ordinary unsure English is not rewritten into someone's name")
    func ordinaryWordsSurvive() {
        let ordinary = ["Monday", "database", "deadline", "the", "meeting", "production"]
        let input = ordinary.map { token($0, 0.2) }
        #expect(TermMatcher.resolving(tokens: input, terms: Self.terms) == input)
    }

    /// **The ordering guard.** This pass runs before `Fillers`, on tokens,
    /// because that is where confidence still exists. Fillers arrive unsure and
    /// are two letters long, so without this they are live candidates for
    /// substitution and "uh" could become a name a moment before the filler
    /// stage would have deleted it.
    @Test("a filler is never resolved into a term, because it is about to be deleted")
    func fillersAreNotCandidates() {
        let input = [token("uh", 0.1), token("um", 0.1), token("hmm", 0.1), token("erm", 0.1)]
        #expect(TermMatcher.resolving(tokens: input, terms: Self.terms) == input)
    }

    @Test("a word already in the vocabulary is never corrected into another one")
    func knownTermsSurvive() {
        // Sarah and Sara both exist and sound alike. Neither may become the
        // other; the locked set caught exactly this collapse.
        let input = [token("Sara", 0.2), token("Sarah", 0.2)]
        #expect(TermMatcher.resolving(tokens: input, terms: Self.terms) == input)
    }

    @Test("punctuation-only tokens are left where they are")
    func punctuationOnly() {
        let input = [token(",", 0.1), token(".", 0.1)]
        #expect(TermMatcher.resolving(tokens: input, terms: Self.terms) == input)
    }

    @Test("numbers are never resolved into words")
    func numbersSurvive() {
        let input = [token("153", 0.2), token("21st", 0.2), token("3:15", 0.2)]
        #expect(TermMatcher.resolving(tokens: input, terms: Self.terms) == input)
    }

    @Test("an empty utterance stays empty")
    func empty() {
        #expect(TermMatcher.resolving(tokens: [], terms: Self.terms).isEmpty)
    }

    // MARK: - The length guard

    /// **The case that forced this, measured on the propernoun corpus
    /// 2026-08-15.** `review` and `ravi` both reduce to `RF` under Double
    /// Metaphone, so they sit at 1.00 similarity and NO similarity threshold
    /// can separate them. It was the only loss left at the best setting, and it
    /// is the worst kind: a correct ordinary word rewritten into a name.
    ///
    /// Length is the axis that does separate them. `review` is 6 letters and
    /// `ravi` is 4, a 33% difference, while every true repair on the same
    /// corpus differed by at most 17%: `Challant`/`chalant`, `versal`/`vercel`,
    /// `Etram`/`aatram`, `Jonalagata`/`jonnalagadda`, `Kisu`/`kizu`.
    @Test("a term too different in length is refused however identical it sounds")
    func lengthGuard() {
        let decision = TermMatcher.resolve(heard: "review", confidence: 0.47, terms: ["Ravi"])
        #expect(decision.replacement == nil)
        #expect(decision.reason.contains("length"))
    }

    @Test("the real repairs all sit inside the length guard")
    func lengthGuardKeepsTheWins() {
        let cases = [
            ("Challant", "Chalant"), ("versal", "Vercel"), ("Etram", "Aatram"),
            ("itrum", "Aatram"), ("Jonalagata", "Jonnalagadda"), ("Kisu", "Kizu"),
            ("Pribar", "Prybar"),
        ]
        for (heard, term) in cases {
            let decision = TermMatcher.resolve(
                heard: heard, confidence: 0.5, terms: [term], confidenceFloor: 0.6)
            #expect(decision.replacement == term, "\(heard) should still reach \(term)")
        }
    }

    /// The guard is a ratio rather than an absolute, or it would be meaningless
    /// at both ends: two characters apart is nothing across long words and
    /// everything across short ones.
    @Test("the guard scales with the length of the words")
    func guardIsProportional() {
        // 2 apart on short words is a third of them, and refused.
        #expect(TermMatcher.withinLength("abcd", "abcdef") == false)
        // 2 apart on long words is a small fraction, and allowed.
        #expect(TermMatcher.withinLength("abcdefghijkl", "abcdefghij") == true)
    }

    /// Part 1 §2. A vocabulary pass may change what a word says; it may never
    /// change how many words there are.
    @Test("the word count is identical before and after, always")
    func neverChangesLength() {
        let input = [
            token("Email", 0.9), token("Chatan", 0.2), token("about", 0.4),
            token("uh", 0.1), token("Shalan", 0.3), token("today.", 0.8),
        ]
        #expect(TermMatcher.resolving(tokens: input, terms: Self.terms).count == input.count)
    }
}
