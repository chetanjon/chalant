import Testing

@testable import ChalantDictationCore

/// The founder's 3 AM sentence, and every way this rule could damage one.
@Suite("Breaks")
struct BreaksTests {

    @Test("the 3 AM sentence gets its full stops")
    func theFounderSentence() {
        let spoken = "Okay, I was sitting in the living room alone, working on Chalant, "
            + "and everybody was sleeping, and it was all calm and serene right now, "
            + "because it's 3 AM today, and today there is a festival."
        let written = "Okay, I was sitting in the living room alone, working on Chalant. "
            + "And everybody was sleeping. And it was all calm and serene right now, "
            + "because it's 3 AM today. And today there is a festival."
        #expect(Breaks.sentencing(spoken) == written)
    }

    /// **The comma was never the point (2026-09-03).** A claims test caught
    /// the rule doing nothing to "I opened a laptop this morning and the
    /// update was already there and everybody said it would take weeks and
    /// it was done overnight and now I just want to use it": read in one
    /// breath, the transcriber wrote no commas, and the rule only knew how
    /// to convert ", and". The pause comma was evidence of a break, not the
    /// break itself, so a long sentence now breaks on the coordinator plus
    /// a clause opener whether or not a comma marks it.
    @Test("a run-on with no commas at all still gets its full stops")
    func breaksWithoutCommas() {
        let spoken = "I opened a laptop this morning and the update was already there "
            + "and everybody said it would take weeks and it was done overnight "
            + "and now I just want to use it."
        let written = "I opened a laptop this morning and the update was already there. "
            + "And everybody said it would take weeks. And it was done overnight. "
            + "And now I just want to use it."
        #expect(Breaks.sentencing(spoken) == written)
    }

    /// The comma version keeps working, unchanged.
    @Test("a comma before the coordinator still breaks the same way")
    func commaVersionUnchanged() {
        let spoken = "I opened a laptop this morning, and the update was already there, "
            + "and everybody said it would take weeks, and it was done overnight."
        let out = Breaks.sentencing(spoken)
        #expect(out.contains("there. And everybody"))
        #expect(out.contains("weeks. And it was"))
        // "the update" is not a clause opener, so that joint keeps its comma.
        #expect(out.contains("this morning, and the update"))
    }

    @Test("a short sentence keeps its spoken rhythm whole")
    func shortSentencesUntouched() {
        let s = "Send the invoice on Friday, and copy the accountant on it."
        #expect(Breaks.sentencing(s) == s)
        #expect(Breaks.sentencing("Yeah, and I had chicken curry today.") == "Yeah, and I had chicken curry today.")
    }

    /// **Changed deliberately on 2026-09-03, and this is the trade.** With
    /// the comma no longer required, "and it went on" DOES break, because
    /// "it" opens a clause and the sentence is long. That reads correctly
    /// ("...calm and serene and quiet. And it went on like that..."). What
    /// must never break is a coordinator joining two ADJECTIVES or nouns,
    /// and that still cannot: "serene" and "quiet" are not clause openers,
    /// so the openers list, not the comma, is what protects them.
    @Test("a coordinator between adjectives is still never a sentence end")
    func bareAndIsNeverTouched() {
        let s = "The long room was all calm and serene and quiet and it went on like that "
            + "for a very long while without a single pause anywhere in it at all."
        let out = Breaks.sentencing(s)
        #expect(!out.contains("serene. And"))
        #expect(!out.contains("calm. And"))
        #expect(out.contains("quiet. And it went on"), "a clause opener after 18 words does break now")
    }

    /// From the corpus dry-run: both damaged rows opened subordinate, the
    /// condition waiting for its main clause. Such sentences never break.
    @Test("a sentence that opens subordinate is left whole")
    func subordinateOpeningsAreLeftWhole() {
        let s = "While holding on to the option button for a long time, and I speak for a "
            + "longer paragraph, and it registers the words a bit wrong sometimes there."
        #expect(Breaks.sentencing(s) == s)
        let t = "But, if we're going off on a tangent and explaining something, and we don't "
            + "want to be interrupted in our thoughts, I think it's doing a pretty good job."
        #expect(Breaks.sentencing(t) == t)
        // A "Because" answer stays whole for the same reason.
        let u = "Because we want the user to talk like very normal and relaxed, and it will "
            + "get what he's saying every single time without any fuss at all."
        #expect(Breaks.sentencing(u) == u)
    }

    @Test("subordinate joints keep their comma")
    func becauseSurvives() {
        let s = "I stayed in the living room for the whole evening working quietly on the app, "
            + "because it was calm, because everybody was sleeping, and it felt like the right time."
        let out = Breaks.sentencing(s)
        #expect(out.contains(", because it was calm"))
        #expect(out.contains(", because everybody was sleeping"))
        #expect(out.hasSuffix(". And it felt like the right time."))
    }

    @Test("an opener must follow, or the comma stands")
    func noOpenerNoBreak() {
        let s = "We packed the car in the morning with all the bags and the food and water, "
            + "and drove out to the lake before anybody else was even awake that day."
        // ", and drove" has no subject after the coordinator: not a new clause.
        #expect(Breaks.sentencing(s) == s)
    }

    @Test("a sentence the speaker finished is several short ones, and stays")
    func finishedSentencesNeverQualify() {
        let s = "I looked at the resume. It was long, and it was vague, and it needed numbers. We fixed it."
        // The middle sentence is 12 words: under the ceiling, untouched.
        #expect(Breaks.sentencing(s) == s)
    }
}
