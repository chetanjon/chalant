import Testing

@testable import ChalantDictationCore

/// Pieces into words, with the confidence intact.
///
/// **Every case here is a real line from the founder's Set E**, decoded by
/// Parakeet TDT v3 on this Mac on 2026-09-14 and copied out of the probe's
/// output rather than invented. That matters for one reason in particular:
/// the engine's own `buildWordTimings(from:)` discards confidence, so if this
/// file were written from imagination it would be easy to write a test that
/// passes over a signal that is not there.
@Suite("SubwordAssembly")
struct SubwordAssemblyTests {

    private func piece(_ text: String, _ confidence: Double? = nil) -> SubwordAssembly.Piece {
        SubwordAssembly.Piece(text: text, confidence: confidence)
    }

    @Test("a leading space opens a word, and the pieces join without it")
    func wordsJoin() {
        // E02: " A sk" -> "Ask"
        let tokens = SubwordAssembly.tokens(from: [piece(" A"), piece("sk"), piece(" At"), piece("ram")])
        #expect(tokens.map(\.text) == ["Ask", "Atram"])
    }

    @Test("the SentencePiece marker opens a word too")
    func markerOpensAWord() {
        let tokens = SubwordAssembly.tokens(from: [piece("\u{2581}Ship"), piece("\u{2581}it")])
        #expect(tokens.map(\.text) == ["Ship", "it"])
    }

    /// The whole point. `TokenAssembly` exists because this signal was once
    /// deleted one line before the layer that needs it; FluidAudio's own
    /// helper deletes it again.
    @Test("confidence survives, which is what TermMatcher waits for")
    func confidenceSurvives() {
        let tokens = SubwordAssembly.tokens(from: [piece(" ch", 0.575), piece("al", 0.871), piece("an", 0.711)])
        #expect(tokens.count == 1)
        #expect(tokens[0].text == "chalan")
        #expect(tokens[0].confidence != nil)
    }

    @Test("minimum is the least sure piece and maximum the surest")
    func aggregationPicksEnds() {
        let pieces = [piece(" ch", 0.575), piece("al", 0.871), piece("an", 0.711)]
        #expect(SubwordAssembly.tokens(from: pieces, aggregation: .minimum)[0].confidence == 0.575)
        #expect(SubwordAssembly.tokens(from: pieces, aggregation: .maximum)[0].confidence == 0.871)
        let mean = SubwordAssembly.tokens(from: pieces, aggregation: .mean)[0].confidence ?? 0
        #expect(abs(mean - 0.719) < 0.001)
    }

    /// The reason the aggregation is a parameter rather than a decision.
    /// `Kizu` is right and `chalan` is wrong, and under `minimum` the right
    /// one scores lower than the wrong one. Neither rule is obviously
    /// correct, so the corpus picks.
    @Test("a correct name can be less sure than a wrong one")
    func theHardCase() {
        let kizu = [piece(" K", 0.527), piece("iz", 0.895), piece("u", 0.937)]
        let chalan = [piece(" ch", 0.575), piece("al", 0.871), piece("an", 0.711)]
        let kizuMin = SubwordAssembly.tokens(from: kizu, aggregation: .minimum)[0].confidence ?? 1
        let chalanMin = SubwordAssembly.tokens(from: chalan, aggregation: .minimum)[0].confidence ?? 1
        #expect(kizuMin < chalanMin)
    }

    @Test("punctuation with no leading space rides on the word before it")
    func punctuationRides() {
        // E01's tail: " tod ay ." -> "today."
        let tokens = SubwordAssembly.tokens(from: [piece(" tod", 0.999), piece("ay", 1.0), piece(".", 0.693)])
        #expect(tokens.map(\.text) == ["today."])
    }

    @Test("no pieces is no words, not an empty word")
    func emptyIsEmpty() {
        #expect(SubwordAssembly.tokens(from: []).isEmpty)
        #expect(SubwordAssembly.tokens(from: [piece(" "), piece("")]).isEmpty)
    }

    @Test("a piece with no confidence leaves the word unjudged rather than sure")
    func missingConfidenceIsNil() {
        let tokens = SubwordAssembly.tokens(from: [piece(" hello"), piece(" world")])
        #expect(tokens.map(\.confidence) == [nil, nil])
    }

    /// Nil is unknown, never zero, and never one. A word with only some
    /// pieces scored is judged on what there is rather than on a guess.
    @Test("a partly scored word is judged on the pieces that were scored")
    func partialConfidence() {
        let tokens = SubwordAssembly.tokens(from: [piece(" G", 0.953), piece("ang"), piece("ot", 0.717)])
        #expect(tokens[0].confidence == 0.717)
    }

    @Test("a piece carrying two words becomes two words")
    func innerSpaceSplits() {
        let tokens = SubwordAssembly.tokens(from: [piece(" friction lens", 0.9)])
        #expect(tokens.map(\.text) == ["friction", "lens"])
    }

    @Test("times order the words and a reversed range is refused")
    func timesOrderWords() {
        let good = SubwordAssembly.tokens(from: [
            SubwordAssembly.Piece(text: " one", confidence: 1, start: 0.2, end: 0.5)
        ])
        #expect(good[0].range == 0.2...0.5)
        let reversed = SubwordAssembly.tokens(from: [
            SubwordAssembly.Piece(text: " one", confidence: 1, start: 0.9, end: 0.1)
        ])
        #expect(reversed[0].range == nil)
    }

    /// The first piece opens a word whether or not it carries a marker: a
    /// decoder that drops the leading space on the very first token must not
    /// cost the sentence its first word.
    @Test("the first piece opens a word without needing a marker")
    func firstPieceOpens() {
        let tokens = SubwordAssembly.tokens(from: [piece("Hello", 0.9), piece(" there", 0.9)])
        #expect(tokens.map(\.text) == ["Hello", "there"])
    }
}
