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

    /// The transcriber writes "..." wherever the speaker trails off or
    /// pauses, and the founder does not want it on the page (2026-08-23,
    /// "when I am not talking, it was putting dots"): a pause is not
    /// punctuation the speaker chose. Before a capitalised word or at the
    /// end it settles to a full stop; before a lowercase word, a comma.
    @Test("the pause dots settle into punctuation the speaker could have meant")
    func ellipsesSettle() {
        #expect(Guardrail.settlingEllipses("It's working now because my keyboard...") == "It's working now because my keyboard.")
        #expect(Guardrail.settlingEllipses("I have a dream that one day... Thota people will be respected") == "I have a dream that one day. Thota people will be respected")
        #expect(Guardrail.settlingEllipses("I be like... updated one so that I can...") == "I be like, updated one so that I can.")
        #expect(Guardrail.settlingEllipses("You... Malvak, character is the name") == "You. Malvak, character is the name")
        // A capitalised word after the dots reads as a restart, wherever
        // the capital came from: the full stop is right either way.
        #expect(Guardrail.settlingEllipses("Send it Tuesday… Wednesday works too") == "Send it Tuesday. Wednesday works too")
    }

    @Test("real punctuation and clean text pass through the dots rule untouched")
    func ellipsesLeaveCleanTextAlone() {
        for text in [
            "Send 15, not 50.", "The file is at /Users/chetan/projects.", "It costs $9.99 a month.",
            "Version 1.26 shipped.", "Wait. What?", "",
        ] {
            #expect(Guardrail.settlingEllipses(text) == text, "touched: \(text)")
        }
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
