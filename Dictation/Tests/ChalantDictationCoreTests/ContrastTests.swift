import Testing

@testable import ChalantDictationCore

/// The comma before a contrastive "not": "153 not 135" is "153, not 135".
/// Measured 2026-08-22 ("what does the model buy"): C14 was the one row
/// on Set C the model moved closer to the truth, and the edit was this
/// comma. Deterministic now, and narrow on purpose: it fires only between
/// two value-shaped tokens (a number, a number word, a capitalised word, a
/// possessive pronoun, optionally behind "the", "a" or "an"), so ordinary
/// negation ("I do not", "I'm not sure", "not really") is never touched.
struct ContrastTests {
    @Test("a number against a number")
    func numbers() {
        #expect(Contrast.commaBeforeNot("The bill number is 153 not 135.") == "The bill number is 153, not 135.")
        #expect(Contrast.commaBeforeNot("Send 15 not 50") == "Send 15, not 50")
        #expect(Contrast.commaBeforeNot("The meeting moved to 3:15 not 3:50.") == "The meeting moved to 3:15, not 3:50.")
        #expect(Contrast.commaBeforeNot("It costs $9.99 not $99.") == "It costs $9.99, not $99.")
        #expect(Contrast.commaBeforeNot("The deadline is the 21st not the 12th.") == "The deadline is the 21st, not the 12th.")
        #expect(Contrast.commaBeforeNot("Send fifteen not fifty.") == "Send fifteen, not fifty.")
    }

    @Test("a name against a name, and a name against a pronoun")
    func names() {
        #expect(Contrast.commaBeforeNot("Email Sarah about it not Sara.") == "Email Sarah about it not Sara.")
        #expect(Contrast.commaBeforeNot("Ship it to Kizu not Chalant.") == "Ship it to Kizu, not Chalant.")
        #expect(Contrast.commaBeforeNot("Ask Sarah not hers.") == "Ask Sarah, not hers.")
        #expect(Contrast.commaBeforeNot("It is Monday not Tuesday.") == "It is Monday, not Tuesday.")
    }

    @Test("a comma already there is left alone")
    func alreadyPunctuated() {
        #expect(Contrast.commaBeforeNot("Send 15, not 50.") == "Send 15, not 50.")
        #expect(Contrast.commaBeforeNot("The deadline is the 21st, not the 12th.") == "The deadline is the 21st, not the 12th.")
    }

    @Test("ordinary negation is never touched")
    func negation() {
        for text in [
            "I do not like it.", "I'm not sure about Monday.", "Do not deploy this to production until Monday.",
            "It's not 50 degrees.", "We are not raising the price.", "Keep the old version, do not overwrite it.",
            "Not Monday.", "I can not make it Thursday.", "Never merge that branch without a review.",
            "I think not Monday but Tuesday.", "is it not 153", "whether or not 15 works",
            "The count was 15 not counting Sarah.", "Revoke his access not hers.",
        ] {
            #expect(Contrast.commaBeforeNot(text) == text, "touched: \(text)")
        }
    }
}
