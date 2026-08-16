import Testing

@testable import ChalantDictationCore

/// Every case here is a real sentence the founder dictated on 2026-08-15, or a
/// way this rule could damage one.
@Suite("Fillers")
struct FillersTests {

    @Test("uh and um are never real words")
    func removesNoise() {
        #expect(Fillers.removing("we are doing uh the local one") == "we are doing the local one")
        #expect(Fillers.removing("There is um so much to do") == "There is so much to do")
    }

    /// The rule the data settled: `like` is a filler only when a comma follows
    /// it. Two of these four are real words and removing them breaks the
    /// sentence.
    @Test("like is a filler only when a comma follows it")
    func knowsWhichLikeIsWhich() {
        // real words, must survive
        #expect(
            Fillers.removing("if the user said something like a name")
                == "if the user said something like a name")
        #expect(
            Fillers.removing("storing database, like post hog or 11 labs")
                == "storing database, like post hog or 11 labs")
        // fillers
        #expect(Fillers.removing("we are doing like, the local one") == "we are doing the local one")
        #expect(Fillers.removing("Like, it's not there yet") == "It's not there yet")
    }

    /// Removed only when the speaker's own punctuation shows it was an aside.
    @Test("you know goes when it is bracketed by commas")
    func removesBracketedAsides() {
        #expect(
            Fillers.removing("Like, you know, use some third party")
                == "Use some third party")
        #expect(
            Fillers.removing("You know, there is so much to do")
                == "There is so much to do")
    }

    /// The case this deliberately misses, and the reason it does. Catching
    /// "you know" without a closing comma would also catch this, and turn a
    /// question into nonsense.
    @Test("a question is not an aside")
    func neverBreaksARealQuestion() {
        #expect(Fillers.removing("Do you know, Sarah?") == "Do you know, Sarah?")
        #expect(Fillers.removing("I don't know what you know") == "I don't know what you know")
    }

    @Test("the sentence keeps its capital when the first word is taken")
    func recapitalises() {
        #expect(Fillers.removing("Uh, we should ship it") == "We should ship it")
    }

    @Test("clean sentences come back byte for byte")
    func leavesCleanTextAlone() {
        for text in [
            "Hello, this is Chetan testing dictation.",
            "Do not deploy this to production until Monday.",
            "I like this one.",
            "",
        ] {
            #expect(Fillers.removing(text) == text)
        }
    }

    /// Fillers must never take a real word with them, and must never leave a
    /// stranded comma where one used to sit.
    @Test("no stranded punctuation is left behind")
    func leavesNoDebris() {
        let out = Fillers.removing("See, we are doing like, uh, the completely local one")
        #expect(!out.contains(", ,"))
        #expect(!out.hasPrefix(","))
        #expect(out.contains("completely local one"))
        #expect(out.contains("See,"))
    }
}
