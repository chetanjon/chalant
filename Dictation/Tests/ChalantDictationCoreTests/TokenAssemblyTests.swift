import Testing

@testable import ChalantDictationCore

/// The engine hands us attributed runs, not words. This is the seam where one
/// becomes the other, and it is pure so it can be tested without a microphone.
///
/// **Every case here is shaped by a real measurement in
/// `verification/PHASE0_SDK_TRUTH.md`:** confidence is present on 100% of
/// finalized runs and 0% of volatile ones, values run 0.011 to 0.998, and time
/// ranges are present on both but measure alignment rather than pauses.
@Suite("TokenAssembly")
struct TokenAssemblyTests {

    private func run(
        _ text: String, _ confidence: Double? = nil,
        _ start: Double? = nil, _ end: Double? = nil
    ) -> TokenAssembly.Run {
        TokenAssembly.Run(text: text, confidence: confidence, start: start, end: end)
    }

    // MARK: - The ordinary shape

    @Test("one run per word keeps every word and its own confidence")
    func onePerWord() {
        let tokens = TokenAssembly.tokens(from: [
            run("Ship ", 0.91), run("Chalant ", 0.32), run("today", 0.88),
        ])
        #expect(tokens.map(\.text) == ["Ship", "Chalant", "today"])
        #expect(tokens.map(\.confidence) == [0.91, 0.32, 0.88])
    }

    @Test("a run holding several words gives each of them that run's confidence")
    func manyWordsOneRun() {
        let tokens = TokenAssembly.tokens(from: [run("ship it today", 0.44)])
        #expect(tokens.map(\.text) == ["ship", "it", "today"])
        #expect(tokens.allSatisfy { $0.confidence == 0.44 })
    }

    /// The whole point of the change. Before it, every token was
    /// `Token(text:)` with confidence nil, and `TermMatcher` reads nil as
    /// "no evidence" and refuses to act. Silence in, silence out.
    @Test("confidence actually arrives, which is what TermMatcher waits for")
    func confidenceSurvives() {
        let tokens = TokenAssembly.tokens(from: [run("Chatan", 0.21)])
        #expect(tokens.first?.confidence == 0.21)
        #expect(tokens.first?.confidence != nil)
    }

    // MARK: - Words that straddle a run boundary

    /// Runs are attribute spans, not word spans. Nothing in the API promises a
    /// run ends on a space, and a word split across two runs must come back as
    /// ONE word or the text itself is wrong.
    @Test("a word split across two runs is rejoined, not torn in half")
    func straddlingWord() {
        let tokens = TokenAssembly.tokens(from: [run("Fricti", 0.4), run("onLens ", 0.6)])
        #expect(tokens.map(\.text) == ["FrictionLens"])
    }

    /// **Conservative on purpose.** Confidence gates substitution: a word is
    /// only replaceable when the engine was UNSURE. Taking the maximum over a
    /// split word makes it look surer, so fewer words are eligible. This type
    /// exists downstream to say no, and an ambiguous merge resolves toward no.
    @Test("a split word takes the HIGHER confidence, so it is harder to overwrite")
    func mergeTakesMaxConfidence() {
        let tokens = TokenAssembly.tokens(from: [run("Fricti", 0.2), run("onLens", 0.9)])
        #expect(tokens.first?.confidence == 0.9)
    }

    @Test("a split word spans from the first run's start to the last run's end")
    func mergeUnionsTheRange() {
        let tokens = TokenAssembly.tokens(from: [
            run("Fricti", 0.2, 1.0, 1.4), run("onLens", 0.9, 1.4, 1.9),
        ])
        #expect(tokens.first?.range?.lowerBound == 1.0)
        #expect(tokens.first?.range?.upperBound == 1.9)
    }

    @Test("a run that starts with whitespace begins a new word")
    func whitespaceStartsAWord() {
        let tokens = TokenAssembly.tokens(from: [run("Ship", 0.9), run(" Chalant", 0.3)])
        #expect(tokens.map(\.text) == ["Ship", "Chalant"])
        #expect(tokens.map(\.confidence) == [0.9, 0.3])
    }

    @Test("merging a word with no confidence anywhere leaves it unknown")
    func mergeOfUnknowns() {
        let tokens = TokenAssembly.tokens(from: [run("Fricti"), run("onLens")])
        #expect(tokens.map(\.text) == ["FrictionLens"])
        // Nil is UNKNOWN, never zero (spec §31.5). A word with no evidence is
        // not a word anyone may overwrite.
        #expect(tokens.first?.confidence == nil)
    }

    @Test("one known half is enough to give the merged word a confidence")
    func mergeOfOneKnownHalf() {
        let tokens = TokenAssembly.tokens(from: [run("Fricti", 0.3), run("onLens")])
        #expect(tokens.first?.confidence == 0.3)
    }

    // MARK: - Timings

    @Test("a time range rides along per word")
    func timings() {
        let tokens = TokenAssembly.tokens(from: [run("Ship ", 0.9, 0.0, 0.5), run("it", 0.8, 0.5, 0.8)])
        #expect(tokens[0].range == 0.0...0.5)
        #expect(tokens[1].range == 0.5...0.8)
    }

    /// Part 0 §0.4, measured again in Phase 0: 32 of 32 inter-word gaps are
    /// EXACTLY zero, across audible silence. Words that share a boundary are
    /// normal, not a bug, and assembly must not try to be clever about it.
    @Test("touching ranges are passed through, never read as a pause")
    func contiguousRangesAreNormal() {
        let tokens = TokenAssembly.tokens(from: [run("one ", 0.9, 0.0, 0.4), run("two", 0.9, 0.4, 0.8)])
        #expect(tokens[0].range?.upperBound == tokens[1].range?.lowerBound)
    }

    /// A malformed range would trap `ClosedRange` at runtime, and a crash in
    /// the transcription path costs the user their words.
    @Test("an inverted or absent range is dropped rather than trusted")
    func refusesBadRanges() {
        #expect(TokenAssembly.tokens(from: [run("word", 0.5, 2.0, 1.0)]).first?.range == nil)
        #expect(TokenAssembly.tokens(from: [run("word", 0.5, nil, 1.0)]).first?.range == nil)
        #expect(TokenAssembly.tokens(from: [run("word", 0.5, 1.0, nil)]).first?.range == nil)
    }

    @Test("a zero-length range is kept, because the engine really does emit them")
    func keepsZeroLengthRanges() {
        #expect(TokenAssembly.tokens(from: [run("word", 0.5, 1.0, 1.0)]).first?.range == 1.0...1.0)
    }

    // MARK: - Nothing, and near-nothing

    @Test("no runs is no tokens")
    func empty() {
        #expect(TokenAssembly.tokens(from: []).isEmpty)
    }

    @Test("whitespace-only runs produce nothing rather than empty words")
    func whitespaceOnly() {
        #expect(TokenAssembly.tokens(from: [run("   "), run("\n")]).isEmpty)
    }

    @Test("runs of pure whitespace between words do not create empty tokens")
    func whitespaceBetween() {
        let tokens = TokenAssembly.tokens(from: [run("Ship"), run("   "), run("it")])
        #expect(tokens.map(\.text) == ["Ship", "it"])
    }

    @Test("newlines and tabs split words the same way a space does")
    func allWhitespaceSplits() {
        let tokens = TokenAssembly.tokens(from: [run("Ship\nit\tnow", 0.7)])
        #expect(tokens.map(\.text) == ["Ship", "it", "now"])
    }

    // MARK: - The invariant that outranks all of the above

    /// Part 1 §2: never lose the user's text. Whatever the run structure, the
    /// words that come out must be the words that went in.
    @Test("no arrangement of runs may lose a word")
    func neverLosesAWord() {
        let sentence = "Email Sarah about it not Sara and tell Aidan the deadline is the 21st"
        let words = sentence.split(separator: " ").map(String.init)

        // Every split point, including mid-word ones.
        for cut in 1..<sentence.count {
            let idx = sentence.index(sentence.startIndex, offsetBy: cut)
            let runs = [
                run(String(sentence[sentence.startIndex..<idx]), 0.5),
                run(String(sentence[idx...]), 0.5),
            ]
            #expect(TokenAssembly.tokens(from: runs).map(\.text) == words)
        }
    }
}
