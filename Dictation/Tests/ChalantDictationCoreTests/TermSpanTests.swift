import Testing

@testable import ChalantDictationCore

/// The pass that puts a name back together after the engine broke it in half.
///
/// **Why this cannot reuse the single-word gate.** That gate fires only when
/// the engine was UNSURE, and a split name is the opposite: measured on the
/// propernoun corpus, `friction` and `lens` both came back at **0.98**, `Speech`
/// at 0.92, `analyzer` at 0.94. The engine is right about every word and wrong
/// only about the boundary between them, so there is no uncertainty to detect.
///
/// The evidence has to come from the match instead. A run of words matching a
/// vocabulary term by sound is a far stronger coincidence than a single short
/// word doing so, which is why this can demand near-exactness where the
/// single-word pass could not.
@Suite("TermMatcher spans")
struct TermSpanTests {

    static let terms = [
        "FrictionLens", "SpeechAnalyzer", "SFSpeechRecognizer", "FluidAudio",
        "CoreML", "Superwhisper", "TextInjector", "PostHog", "Chalant", "appcast",
    ]

    private func tokens(_ text: String, _ confidence: Double? = 0.95) -> [Token] {
        text.split(separator: " ").map { Token(text: String($0), confidence: confidence) }
    }

    private func text(_ tokens: [Token]) -> String {
        tokens.map(\.text).joined(separator: " ")
    }

    private func joined(_ input: String) -> String {
        text(TermMatcher.joiningSpans(tokens: tokens(input), terms: Self.terms))
    }

    // MARK: - Doing the job

    @Test("two words the engine split are put back together")
    func joinsTwo() {
        #expect(joined("friction lens") == "FrictionLens")
        #expect(joined("app cast") == "appcast")
        #expect(joined("post hog") == "PostHog")
    }

    @Test("three words are joined too, which SFSpeechRecognizer needs")
    func joinsThree() {
        #expect(joined("SF speech recognizer") == "SFSpeechRecognizer")
    }

    /// The whole reason this pass exists on its own: high confidence must not
    /// stop it, because a split name is made of confidently-heard real words.
    @Test("a confidently heard split is still joined")
    func confidenceDoesNotBlockIt() {
        #expect(joined("friction lens") == "FrictionLens")
        let sure = TermMatcher.joiningSpans(
            tokens: tokens("friction lens", 0.99), terms: Self.terms)
        #expect(text(sure) == "FrictionLens")
    }

    @Test("the rest of the sentence is untouched and in order")
    func leavesTheSentenceAlone() {
        #expect(
            joined("Ask Aatram whether friction lens is ready")
                == "Ask Aatram whether FrictionLens is ready")
    }

    @Test("punctuation at either end of the span survives")
    func keepsPunctuation() {
        #expect(joined("using friction lens, today") == "using FrictionLens, today")
        #expect(joined("we shipped app cast.") == "we shipped appcast.")
    }

    @Test("two separate names in one sentence are both joined")
    func joinsTwice() {
        #expect(
            joined("speech analyzer beats core ML") == "SpeechAnalyzer beats CoreML")
    }

    @Test("the longest match wins, so a 3-word name is not eaten by a 2-word one")
    func prefersTheLongerSpan() {
        // "speech recognizer" must not be taken while "SF speech recognizer"
        // is available.
        #expect(joined("SF speech recognizer") == "SFSpeechRecognizer")
    }

    // MARK: - Refusing the job

    @Test("ordinary English is not swept into a name")
    func ordinaryPhrasesSurvive() {
        for phrase in [
            "the meeting moved", "do not deploy this", "send it on Monday",
            "never merge that branch", "reply to Aidan and", "I ran five miles",
        ] {
            #expect(joined(phrase) == phrase, "\(phrase) must survive untouched")
        }
    }

    @Test("an empty vocabulary changes nothing")
    func emptyVocabulary() {
        let input = tokens("friction lens")
        #expect(TermMatcher.joiningSpans(tokens: input, terms: []) == input)
    }

    @Test("a span whose length is far off the term is refused")
    func lengthGuardApplies() {
        // "core" alone is not "CoreML", and a run must not stretch to reach.
        #expect(joined("core") == "core")
    }

    @Test("a single word is never joined by this pass, that is the other one's job")
    func doesNotTouchSingleWords() {
        #expect(joined("Challant") == "Challant")
    }

    // MARK: - The stopword guard, and the two failures that forced it

    /// **Both of these shipped in the first version and were caught by the
    /// corpus, not by the tests above.** Part 5 §3 already named the mechanism
    /// (`stopwordSpanSimilarity 0.85`, *"protects `and` from becoming
    /// `Andre`"*) and it was not used.
    ///
    /// `it on` and `Aidan` reduce to the SAME phonetic key and sit 20% apart in
    /// length, so neither the similarity floor nor the length guard can see
    /// anything wrong. Only the fact that `it` and `on` are function words
    /// separates them.
    @Test("two function words are never swept into a name")
    func stopwordsAreNeverJoined() {
        let terms = ["Aidan", "Chalant"]
        let sentence = "I can't make it on Thursday."
        let out = TermMatcher.joiningSpans(tokens: tokens(sentence), terms: terms)
        #expect(text(out) == sentence)
    }

    /// The second failure, and a worse one: the name came out RIGHT and the
    /// sentence lost a word. `Chalan to` matched `Chalant` closely enough that
    /// the `to` was absorbed, turning "Ship Chalan to the Kizu group" into
    /// "Ship Chalant the Kizu group". Part 1 §2: never lose the user's text.
    @Test("a span may not swallow a following function word to reach a term")
    func doesNotAbsorbATrailingStopword() {
        let out = TermMatcher.joiningSpans(
            tokens: tokens("Ship Chalan to the Kizu group"), terms: ["Chalant"])
        #expect(text(out).contains("to the Kizu"))
    }

    @Test("the real joins all survive the stopword guard")
    func stopwordGuardKeepsTheWins() {
        #expect(joined("friction lens") == "FrictionLens")
        #expect(joined("app cast") == "appcast")
        #expect(joined("text injector") == "TextInjector")
        #expect(joined("speech analyzer") == "SpeechAnalyzer")
        #expect(joined("core ML") == "CoreML")
        #expect(joined("super whisper") == "Superwhisper")
        #expect(joined("SF speech recognizer") == "SFSpeechRecognizer")
    }

    @Test("nothing in, nothing out")
    func empty() {
        #expect(TermMatcher.joiningSpans(tokens: [], terms: Self.terms).isEmpty)
    }

    // MARK: - What the joined token carries

    /// **The minimum, deliberately, and this differs from `TokenAssembly`.**
    /// There a word was split by ATTRIBUTE runs and the pieces were always one
    /// word, so the higher confidence was the honest reading. Here the pieces
    /// are genuinely separate words, and a span is only as certain as its least
    /// certain part. Risk routing reads this and should not be told a shaky
    /// span was solid.
    @Test("a joined span carries the confidence of its weakest word")
    func carriesMinimumConfidence() {
        let input = [
            Token(text: "friction", confidence: 0.98, range: 1.0...1.4),
            Token(text: "lens", confidence: 0.54, range: 1.4...1.9),
        ]
        let out = TermMatcher.joiningSpans(tokens: input, terms: Self.terms)
        #expect(out.count == 1)
        #expect(out.first?.confidence == 0.54)
        #expect(out.first?.range == 1.0...1.9)
    }

    /// This pass is the one place a word count may drop, and it drops only by
    /// joining. Part 1 §2 is about never losing the user's TEXT, and two words
    /// becoming the one word they were always meant to be loses nothing.
    @Test("joining is the only way the word count may fall")
    func onlyShrinksByJoining() {
        let input = tokens("Ask Aatram whether friction lens is ready")
        let out = TermMatcher.joiningSpans(tokens: input, terms: Self.terms)
        #expect(out.count == input.count - 1)
    }
}
