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

/// The prefix-restart rule (2026-08-22, ruling 4): a run of at least two
/// tokens said twice in one sentence, the second within four tokens of the
/// first run's end, continuing differently: the later run stays.
struct RestatementPrefixTests {
    @Test("a restarted run keeps its later copy")
    func prefixRestart() {
        #expect(Restatement.collapsing("Lupin, Priya, and Sarah, Priya, and Aidan on the Versal deploy.") == "Lupin, Priya, and Aidan on the Versal deploy.")
        #expect(Restatement.collapsing("I can't make it. I, okay, I can't make it on Friday.") == "I can't make it on Friday.")
        #expect(Restatement.collapsing("My email, my email is Chetan at Gmail.") == "My email is Chetan at Gmail.")
        // The first run did not end its sentence ("hang on." did), so this
        // is two sentences to the rule and ships as said: "hang on" is not
        // a marker. Repair still fixes its value pair.
        #expect(Restatement.collapsing("API, the API key ends in, hang on. The API key ends in 472, not 427.") == "API, the API key ends in, hang on. The API key ends in 472, not 427.")
        #expect(Restatement.collapsing("So the build is 153, no, the build is 135.") == "So the build is 135.")
    }

    @Test("a single repeated token is not a run, and exact repeats keep the first copy")
    func prefixLimits() {
        #expect(Restatement.collapsing("Tell Sarah Sarah is late.") == "Tell Sarah Sarah is late.")
        #expect(Restatement.collapsing("Yes. Yes.") == "Yes. Yes.")
        #expect(Restatement.collapsing("We need the data. We need the data.") == "We need the data.")
        #expect(Restatement.collapsing("Day by day it gets better, and day by day we ship.") == "Day by day it gets better, and day by day we ship.")
        #expect(Restatement.collapsing("First we ship. Then we tell everyone. Then we rest.") == "First we ship. Then we tell everyone. Then we rest.")
        #expect(Restatement.collapsing("I need to go to the bank. I should visit the bank today.") == "I need to go to the bank. I should visit the bank today.")
    }
}
