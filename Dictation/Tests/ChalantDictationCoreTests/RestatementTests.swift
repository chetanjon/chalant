import Testing

@testable import ChalantDictationCore

/// The founder's own test, 2026-08-20: say the same thing twice, get it
/// once. Narrow by design: exact restatements only, three words or more.
@Suite("Restatement")
struct RestatementTests {

    @Test("a sentence said twice lands once, first copy keeps its place")
    func collapsesExactRepeats() {
        #expect(
            Restatement.collapsing("I need to go to the bank today. I need to go to the bank today.")
                == "I need to go to the bank today.")
        #expect(
            Restatement.collapsing("Ship it tonight. The tests are green. Ship it tonight.")
                == "Ship it tonight. The tests are green.")
    }

    @Test("case and punctuation do not hide a restatement")
    func matchesAcrossCaseAndPunctuation() {
        #expect(
            Restatement.collapsing("Send the draft to Priya. send the draft to Priya!")
                == "Send the draft to Priya.")
    }

    /// A rephrasing is the model's judgment call, never this pass's.
    @Test("a rephrasing is not a restatement")
    func keepsRephrasings() {
        let text = "I need to go to the bank. I should visit the bank today."
        #expect(Restatement.collapsing(text) == text)
    }

    @Test("short sentences are emphasis and stay")
    func keepsShortRepeats() {
        for text in ["Yes. Yes.", "No, no. No, no.", "Do it. Do it."] {
            #expect(Restatement.collapsing(text) == text)
        }
    }

    @Test("a repeat with no sentence break is left alone")
    func needsSentenceBoundaries() {
        let runOn = "I need to go to the bank I need to go to the bank"
        #expect(Restatement.collapsing(runOn) == runOn)
    }

    @Test("clean text comes back byte for byte")
    func leavesCleanTextAlone() {
        for text in [
            "Hello, this is Chetan testing dictation.",
            "First we ship. Then we tell everyone. Then we rest.",
            "",
        ] {
            #expect(Restatement.collapsing(text) == text)
        }
    }
}
