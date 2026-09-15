import Testing

@testable import ChalantDictationCore

/// Carrying per-word confidence across a rewritten sentence.
///
/// **Needed because inverse text normalisation works on sentences and the
/// vocabulary layer works on words.** "one hundred and twenty dollars" becomes
/// "$120": five words into one, so the decoder's per-word scores no longer line
/// up with anything. Throwing them away silences the vocabulary layer, which is
/// the 2026-08-15 bug in a new coat. Keeping them by position attaches a
/// number's score to whatever word landed in that slot, which is worse.
@Suite("TokenRealignment")
struct TokenRealignmentTests {

    private func token(_ text: String, _ confidence: Double? = nil) -> Token {
        Token(text: text, confidence: confidence)
    }

    @Test("an untouched sentence keeps every confidence")
    func untouchedKeepsEverything() {
        let original = [token("Ship", 0.9), token("Chalant", 0.4), token("today", 0.99)]
        let out = TokenRealignment.carryingConfidence(from: original, onto: "Ship Chalant today")
        #expect(out.map(\.text) == ["Ship", "Chalant", "today"])
        #expect(out.map(\.confidence) == [0.9, 0.4, 0.99])
    }

    /// The case the whole type exists for. The words that survived keep their
    /// scores; the rewritten span arrives unjudged.
    @Test("a collapsed number arrives unjudged and its neighbours do not")
    func collapsedNumbersLoseTheirScores() {
        let original = [
            token("The", 0.99), token("invoice", 0.98), token("came", 0.97), token("to", 0.99),
            token("one", 0.8), token("hundred", 0.7), token("and", 0.9), token("twenty", 0.6),
            token("dollars", 0.85),
        ]
        let out = TokenRealignment.carryingConfidence(
            from: original, onto: "The invoice came to $120")
        #expect(out.map(\.text) == ["The", "invoice", "came", "to", "$120"])
        #expect(out.prefix(4).map(\.confidence) == [0.99, 0.98, 0.97, 0.99])
        #expect(out.last?.confidence == nil, "a word the normaliser wrote is not one to second-guess")
    }

    /// Nil is unknown, never zero and never one. `TermMatcher` reads nil as
    /// "no evidence to act on" and refuses to substitute, which is the
    /// conservative answer and the right one here.
    @Test("a substituted word arrives unjudged")
    func substitutionLosesTheScore() {
        let original = [token("version", 0.9), token("one", 0.5), token("point", 0.5), token("four", 0.5)]
        let out = TokenRealignment.carryingConfidence(from: original, onto: "version 1.4")
        #expect(out.map(\.text) == ["version", "1.4"])
        #expect(out[0].confidence == 0.9)
        #expect(out[1].confidence == nil)
    }

    @Test("a rewrite that only drops words keeps the rest")
    func deletionKeepsTheRest() {
        let original = [token("um", 0.3), token("ship", 0.9), token("it", 0.95)]
        let out = TokenRealignment.carryingConfidence(from: original, onto: "ship it")
        #expect(out.map(\.text) == ["ship", "it"])
        #expect(out.map(\.confidence) == [0.9, 0.95])
    }

    @Test("nothing in, nothing out")
    func emptyCases() {
        #expect(TokenRealignment.carryingConfidence(from: [], onto: "").isEmpty)
        #expect(TokenRealignment.carryingConfidence(from: [token("a", 1)], onto: "").isEmpty)
        let fresh = TokenRealignment.carryingConfidence(from: [], onto: "brand new words")
        #expect(fresh.map(\.text) == ["brand", "new", "words"])
        #expect(fresh.allSatisfy { $0.confidence == nil })
    }

    /// Whatever else happens, the rewritten text is what lands: this may not
    /// quietly restore a word the normaliser removed.
    @Test("the output is always the rewritten words, in order")
    func outputIsTheRewrite() {
        let original = [token("three", 0.5), token("fifteen", 0.5)]
        let out = TokenRealignment.carryingConfidence(from: original, onto: "03:15")
        #expect(out.map(\.text).joined(separator: " ") == "03:15")
    }
}
