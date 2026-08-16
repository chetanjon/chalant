import Testing

@testable import ChalantDictationCore

/// The three real stutters from the 2026-08-15 baseline, plus every way this
/// rule could do damage if it were any less careful.
@Suite("Disfluency")
struct DisfluencyTests {

    @Test("the three stutters the baseline actually produced")
    func fixesWhatWasMeasured() {
        #expect(
            Disfluency.collapsingRepetitions("The the ABI key ends in 472.")
                == "The ABI key ends in 472.")
        #expect(
            Disfluency.collapsingRepetitions("The the deadline is the 21st, not the 12th.")
                == "The deadline is the 21st, not the 12th.")
        #expect(
            Disfluency.collapsingRepetitions("Reply to reply to Aidan and do not copy anyone else.")
                == "Reply to Aidan and do not copy anyone else.")
    }

    /// The first occurrence survives, so a sentence keeps its capital.
    @Test("capitalisation of the surviving word is the sentence's own")
    func keepsTheFirstNotTheSecond() {
        #expect(Disfluency.collapsingRepetitions("The the cat") == "The cat")
    }

    /// Part 0 §0.16: anything ambiguous ships verbatim. These are correct
    /// English and a rule that "fixes" them has introduced an error.
    @Test("legitimate English doublings are never touched")
    func leavesRealDoublingsAlone() {
        for text in [
            "He had had enough of it.",
            "I know that that is true.",
        ] {
            #expect(Disfluency.collapsingRepetitions(text) == text)
        }
    }

    /// A repeated number is the fidelity guard's territory, not this rule's.
    /// Losing a digit is exactly the class that must never be silently altered.
    @Test("repeated numbers survive")
    func neverCollapsesDigits() {
        #expect(Disfluency.collapsingRepetitions("15 15 Main Street") == "15 15 Main Street")
        #expect(Disfluency.collapsingRepetitions("Send 50 50 now") == "Send 50 50 now")
    }

    /// Punctuation between two identical phrases is a boundary the speaker
    /// made, and usually means they meant both.
    @Test("a comma between repeats means they were deliberate")
    func respectsPunctuationBoundaries() {
        let text = "Go, go now."
        #expect(Disfluency.collapsingRepetitions(text) == text)
    }

    @Test("three in a row collapse to one")
    func collapsesLongerRuns() {
        #expect(Disfluency.collapsingRepetitions("the the the cat") == "the cat")
    }

    @Test("ordinary sentences come back byte for byte")
    func leavesCleanTextAlone() {
        for text in [
            "Hello, this is Chetan testing dictation.",
            "Do not deploy this to production until Monday.",
            "Email Sarah about it, not Sara.",
            "",
            "one",
        ] {
            #expect(Disfluency.collapsingRepetitions(text) == text)
        }
    }
}
