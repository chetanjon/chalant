import Testing

@testable import ChalantDictationCore

/// The rewrite pass: prompt shape, and the looser guard that lets words move
/// but never a number, negation or name.
@Suite("Rewrite")
struct RewritePromptTests {

    @Test("the rewrite framing wraps the transcript in the shared markers")
    func framingWrapsInMarkers() {
        let out = RewritePrompt.framing("hello there")
        #expect(out.contains(CleanupPrompt.openMarker))
        #expect(out.contains(CleanupPrompt.closeMarker))
        #expect(out.contains("hello there"))
    }

    @Test("a reworded rewrite passes where cleanup's guard would reject it")
    func rewordingIsAllowed() {
        // A genuine reflow: merged, reordered, new connective words. The
        // strict guard would fail this on content overlap and new tokens;
        // the rewrite guard passes it because nothing factual moved.
        let raw = "so i was thinking and you know we should ship it and it is good and i love it"
        let rewritten = "I was thinking we should ship it. It is good, and I love it."
        #expect(FidelityGuard.checkRewrite(raw: raw, rewritten: rewritten) == .ok)
    }

    @Test("a changed number is still refused")
    func numbersStillGuarded() {
        let raw = "send 320 dollars to the account"
        let bad = "Send 32 dollars to the account."
        #expect(FidelityGuard.checkRewrite(raw: raw, rewritten: bad) != .ok)
    }

    @Test("a dropped negation is still refused, the worst case")
    func negationsStillGuarded() {
        let raw = "do not deploy this to production tonight please"
        let bad = "Deploy this to production tonight."
        #expect(FidelityGuard.checkRewrite(raw: raw, rewritten: bad) != .ok)
    }

    @Test("a dropped name is still refused")
    func namesStillGuarded() {
        let raw = "give the report to Priya before the meeting"
        let bad = "Give the report before the meeting."
        #expect(FidelityGuard.checkRewrite(raw: raw, rewritten: bad) != .ok)
    }

    @Test("an empty reply is refused")
    func emptyRefused() {
        #expect(FidelityGuard.checkRewrite(raw: "something real", rewritten: "  ") != .ok)
    }
}
