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
    @Test("ah is noise too")
    func ahIsNoise() {
        // Measured 2026-08-22 (EVAL-LOG "what does the model buy"): the one
        // filler the model removed that this pass had not, D-R2-a's "ah,".
        // The pause comma in front of it dies with it, the standing rule.
        #expect(Fillers.removing("Ravi, Ki Cheppu, meeting, postpone, ah, Ennani.") == "Ravi, Ki Cheppu, meeting, postpone Ennani.")
        #expect(Fillers.removing("Ah, send it Monday") == "Send it Monday")
    }

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

    /// The transcriber puts a comma at every pause, so a filler usually sits
    /// between two of them. The filler's own comma always left with it; the
    /// OPENING comma used to stay, and "because, you know, the music" came
    /// back "because, the music" all over the founder's real corpus
    /// (2026-08-20, "chalant is using a lot of commas"). The pause comma dies
    /// with its filler; a full stop is never touched.
    @Test("the pause comma dies with its filler")
    func dropsThePauseComma() {
        #expect(
            Fillers.removing("the mixing was bad because, you know, the music was loud")
                == "the mixing was bad because the music was loud")
        #expect(
            Fillers.removing("it is pretty good at, you know, um, parsing my gaps")
                == "it is pretty good at parsing my gaps")
        #expect(Fillers.removing("Yes, um, that's right") == "Yes that's right")
        #expect(Fillers.removing("It landed. Um, next one") == "It landed. Next one")
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
    /// **The run-on the founder felt, 2026-08-27** (cap-20260827-131438):
    /// "on the top, like, we need" lost the filler AND both commas, welding
    /// two clauses into "on the top we need". When the word after the filler
    /// opens a new clause, one comma has to survive the removal. When it
    /// does not, both commas still die: the 2026-08-20 ruling ("because,
    /// you know, the" comes back "because the") is unchanged.
    @Test("a filler between two clauses leaves one comma behind")
    func keepsTheBoundaryComma() {
        #expect(
            Fillers.removing("as I'm talking on the top, like, we need to improve the design.")
                == "as I'm talking on the top, we need to improve the design.")
        #expect(
            Fillers.removing("we should go, um, I think we should stay")
                == "we should go, I think we should stay")
        // Not a clause boundary: both commas still die with the filler.
        #expect(
            Fillers.removing("I just want, you know, to make the UI changes")
                == "I just want to make the UI changes")
        #expect(Fillers.removing("because, you know, the music") == "because the music")
    }

}
