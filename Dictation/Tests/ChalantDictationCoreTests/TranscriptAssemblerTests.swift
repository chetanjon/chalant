import Testing

@testable import ChalantDictationCore

/// Part 1 §3 names this the first banned pattern and Part 2 §6 calls it the
/// single most common streaming-ASR bug: volatile results REPLACE the previous
/// volatile span, finalized results APPEND and are immutable. Treating a
/// volatile result as final produces duplicated text.
///
/// Part 2 §6 asks specifically for a unit test driving a scripted event
/// sequence, so that is what this is.
@Suite("TranscriptAssembler")
struct TranscriptAssemblerTests {
    private func tokens(_ words: String) -> [Token] {
        words.split(separator: " ").map { Token(text: String($0)) }
    }

    @Test("a fresh assembler has nothing to say")
    func empty() {
        let a = TranscriptAssembler()
        #expect(a.finalizedText == "")
        #expect(a.displayText == "")
    }

    @Test("volatile results replace rather than accumulate")
    func volatileReplaces() {
        var a = TranscriptAssembler()
        a.apply(.volatile(tokens("hello")))
        a.apply(.volatile(tokens("hello there")))
        a.apply(.volatile(tokens("hello there friend")))
        // Three events, one span. Accumulating would give "hello hello there
        // hello there friend".
        #expect(a.displayText == "hello there friend")
        // Nothing is committed until it finalizes.
        #expect(a.finalizedText == "")
    }

    @Test("finalized results append and clear the volatile span")
    func finalizedAppends() {
        var a = TranscriptAssembler()
        a.apply(.volatile(tokens("hello")))
        a.apply(.finalized(tokens("hello there")))
        #expect(a.finalizedText == "hello there")
        // The volatile span that preceded it must not survive and be shown twice.
        #expect(a.displayText == "hello there")
    }

    /// The scripted sequence the plan names: the exact interleaving that
    /// produces the classic duplication bug when volatile is mistaken for final.
    @Test("the duplication trap: volatile, volatile, finalized, volatile, finalized")
    func duplicationTrap() {
        var a = TranscriptAssembler()
        a.apply(.volatile(tokens("hello")))
        a.apply(.volatile(tokens("hello there")))
        a.apply(.finalized(tokens("hello there")))
        a.apply(.volatile(tokens("how")))
        a.apply(.finalized(tokens("how are you")))

        #expect(a.finalizedText == "hello there how are you")
        #expect(a.displayText == "hello there how are you")
    }

    @Test("a trailing volatile span is never silently dropped")
    func trailingVolatileSurvives() {
        // Part 1 §2: never lose the user's text. If a session ends with an
        // un-finalized span (an error path), it still has to be recoverable,
        // even though Part 0 §0.5 says insertion fires on finalized only.
        var a = TranscriptAssembler()
        a.apply(.finalized(tokens("send it")))
        a.apply(.volatile(tokens("on Tuesday")))

        #expect(a.finalizedText == "send it")
        #expect(a.displayText == "send it on Tuesday")
        #expect(a.hasUncommittedSpan)
    }

    @Test("an empty finalized event does not invent whitespace")
    func emptyFinalized() {
        var a = TranscriptAssembler()
        a.apply(.finalized(tokens("hello")))
        a.apply(.finalized([]))
        #expect(a.finalizedText == "hello")
    }

    @Test("reset returns it to birth for the next utterance")
    func reset() {
        var a = TranscriptAssembler()
        a.apply(.finalized(tokens("first utterance")))
        a.apply(.volatile(tokens("leftover")))
        a.reset()
        #expect(a.finalizedText == "")
        #expect(a.displayText == "")
        #expect(!a.hasUncommittedSpan)
    }
}
