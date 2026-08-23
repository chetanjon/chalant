import Testing

@testable import ChalantDictationCore

/// The repair-marker grammar, as ruled on 2026-08-22 (prompt 7). Inputs
/// are the Apple transcriber's own renderings of the Set F recordings.
struct RepairTests {
    @Test("VALUE: the later value of the same shape stays")
    func valuePairs() {
        #expect(Repair.repairing("Send the invoice on Tuesday, no Wednesday, and copy Sarah.") == "Send the invoice on Wednesday, and copy Sarah.")
        #expect(Repair.repairing("Send it to Priya, sorry, Sarah, before the stand up.") == "Send it to Sarah, before the stand up.")
        #expect(Repair.repairing("The bill number is 153. No wait, 135.") == "The bill number is 135.")
        #expect(Repair.repairing("The invoice came to $120 sorry $1200.") == "The invoice came to $1200.")
        #expect(Repair.repairing("The number is 50. Sorry, 40, not 14.") == "The number is 40, not 14.")
        #expect(Repair.repairing("The stand-up moves to 930. No, 1015 tomorrow.") == "The stand-up moves to 1015 tomorrow.")
        #expect(Repair.repairing("The room is 410, rather 412, not 420.") == "The room is 412, not 420.")
        // A two-word echo ("a month") is outside the grammar: ships as said.
        #expect(Repair.repairing("It costs 999 a month. Make that 1999 a month.") == "It costs 999 a month. Make that 1999 a month.")
    }

    @Test("VALUE: the echo rule, a word before or after the value")
    func valueEcho() {
        #expect(Repair.repairing("The deadline is the 20th. Sorry, the 21st. Not the 12th.") == "The deadline is the 21st. Not the 12th.")
        #expect(Repair.repairing("I can't make it on Thursday. No, on Friday.") == "I can't make it on Friday.")
        #expect(Repair.repairing("Revoke her access, sorry, his access, not hers.") == "Revoke his access, not hers.")
    }

    @Test("VALUE: a chain resolves left to right")
    func valueChain() {
        #expect(Repair.repairing("Move the meeting to Monday, no Tuesday, actually, make that Thursday.") == "Move the meeting to Thursday.")
    }

    @Test("VALUE: fillers are transparent and go with the cut")
    func valueThroughFillers() {
        #expect(Repair.repairing("Send it on Tuesday, um, no, Wednesday.") == "Send it on Wednesday.")
        #expect(Repair.repairing("The build is, um, 153, no, uh, 135.") == "The build is, um, 135.")
    }

    @Test("wait alone fires only as VALUE with punctuation on both sides")
    func waitAlone() {
        #expect(Repair.repairing("Set the timeout to 3, wait, 2.5 seconds.") == "Set the timeout to 2.5 seconds.")
        #expect(Repair.repairing("Set the time out to 3 wait. 2.5 seconds.") == "Set the time out to 3 wait. 2.5 seconds.")
        #expect(Repair.repairing("Do not wait for Aidan.") == "Do not wait for Aidan.")
        // With punctuation on both sides it is VALUE, and "ask" is the echo.
        #expect(Repair.repairing("Ask Chetan, wait, ask Aidan.") == "Ask Aidan.")
    }

    @Test("PHRASE: a restart that repeats the clause's opening")
    func phrase() {
        #expect(Repair.repairing("Ask Chetan? No, ask Aidan to review the uh, vessel config.") == "Ask Aidan to review the uh, vessel config.")
        #expect(Repair.repairing("Email Journa, Journa Lagada. No, email Chetan about the release.") == "Email Chetan about the release.")
        #expect(Repair.repairing("Ship version 125. No, wait. Ship 126 to the Kizo group. Not the Chalant one.") == "Ship 126 to the Kizo group. Not the Chalant one.")
        #expect(Repair.repairing("Tell Sarah, I mean, tell Sara, that the demo moved.") == "Tell Sara, that the demo moved.")
        #expect(Repair.repairing("Delete the production database, no, no. Delete the staging database. Never the production one.") == "Delete the staging database. Never the production one.")
        // A restart behind a discourse opener is not a PHRASE ("So" opens
        // the clause); Restatement's prefix rule takes it downstream.
        #expect(Repair.repairing("So the build is 153, no, the build is 135.") == "So the build is 153, no, the build is 135.")
        #expect(Repair.repairing("We are raising the price next month. Actually, no, we are not raising the price next month.") == "We are not raising the price next month.")
    }

    @Test("CLAUSE: scratch that drops the clause before it")
    func clause() {
        #expect(Repair.repairing("The deploy to production, scratch that, the deploy to staging finished at 315, not 350.") == "The deploy to staging finished at 315, not 350.")
        #expect(Repair.repairing("Cancel the subscription today. Scratch that. Keep the subscription and cancel the trial.") == "Keep the subscription and cancel the trial.")
    }

    @Test("a marker with only one side never fires")
    func oneSided() {
        for text in [
            "No, I don't think so.", "Sorry, I missed that.", "We actually shipped it on Monday.",
            "Send 15, no more.", "There is no time.", "No, we are not raising the price.",
            "I mean it.", "Like, I mean, we should ship it.", "Monday, no 15.",
            "Force push to mine. No, do not force push. Open a PR.",
            "Deployed to production, wait. No, do not deploy it until Sarah signs off.",
            "Bing Atram about the icons. I mean Gango 3 about the icons.",
            "Well, no, that is fine.", "It was good, actually.", "Rather than wait, ship it.",
        ] {
            #expect(Repair.repairing(text) == text, "touched: \(text)")
        }
    }
}
