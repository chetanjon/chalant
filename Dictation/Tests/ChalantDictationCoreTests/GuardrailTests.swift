import Testing

@testable import ChalantDictationCore

/// The real utterance that caused this, spoken in Telugu with the engine pinned
/// to en-US: seven mush words and forty-one commas, pasted straight into the
/// founder's editor.
@Suite("Guardrail")
struct GuardrailTests {

    static let observed =
        "Renik, Nisalu, Cheppali, Krutik, niki, Nisal, Chepp, ,, ,, ,, ,, ,, ,, ,, , ,, ,, ,, , , , , , , , , , , , , ,"

    @Test("the comma run goes and every word stays")
    func trimsTheRunKeepsTheWords() {
        let out = Guardrail.trimmingPunctuationRun(Self.observed)
        #expect(out.hasPrefix("Renik, Nisalu, Cheppali"))
        #expect(out.hasSuffix("Chepp,"))
        // Part 1 §2: a guardrail may never cost a word.
        for word in ["Renik,", "Nisalu,", "Cheppali,", "Krutik,", "niki,", "Nisal,", "Chepp,"] {
            #expect(out.contains(word))
        }
    }

    @Test("ordinary sentences are returned byte for byte")
    func leavesRealTextAlone() {
        for text in [
            "Hello, this is Chetan testing dictation.",
            "Do not deploy this to production until Monday.",
            "What do I do exactly?",
            "Send 15, not 50.",
        ] {
            #expect(Guardrail.trimmingPunctuationRun(text) == text)
        }
    }

    /// A guardrail that eats real punctuation is worse than the bug it fixes.
    @Test("a single trailing mark is punctuation, not a run")
    func keepsOneTrailingMark() {
        #expect(Guardrail.trimmingPunctuationRun("Are you coming ?") == "Are you coming ?")
        #expect(Guardrail.trimmingPunctuationRun("Stop .") == "Stop .")
    }

    @Test("a sentence that truly ends keeps its full stop")
    func keepsTheTerminalMarkAfterARun() {
        let out = Guardrail.trimmingPunctuationRun("It is done . , , , ,")
        #expect(out == "It is done .")
    }

    @Test("empty and whitespace survive untouched")
    func handlesNothing() {
        #expect(Guardrail.trimmingPunctuationRun("") == "")
        #expect(Guardrail.trimmingPunctuationRun("   ") == "   ")
    }

    @Test("noise is reported, speech is not")
    func spotsDegenerateOutput() {
        #expect(Guardrail.looksDegenerate(Self.observed))
        #expect(!Guardrail.looksDegenerate("Hello, this is Chetan testing dictation."))
        // Short utterances are never judged: "OK." must not read as noise.
        #expect(!Guardrail.looksDegenerate(", , ,"))
    }
}
