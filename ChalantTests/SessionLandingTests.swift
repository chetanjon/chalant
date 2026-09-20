import XCTest
@testable import Chalant

/// Whose words are these.
///
/// Chalant's whole job is typing what you say into the app in front of
/// you. The island's message card borrows that machinery to fill its own
/// reply field, and the only thing separating "my reply appears in the
/// card" from "my private reply is typed into Slack" is this bookkeeping.
/// It has been wrong twice (2026-09-19, both found by review):
///
/// 1. The card borrowed the welcome tour's GLOBAL landing, which every
///    hold lands in. A plain hold of the dictation key went to the card.
/// 2. Landings moved to the press that opened them, but `keyDown` bumped
///    the session id BEFORE asking whether the press was accepted. Press
///    the dictation key out of habit while the card holds the microphone,
///    and that refused press still moved the id: the running hold then
///    finalized under an id its landing was not filed under, and the
///    reply was typed into the front app.
///
/// So the rules below are tested as rules, not trusted as comments.
@available(macOS 26, *)
final class SessionLandingTests: XCTestCase {
    /// The answer that must be impossible: words with an owner ending up
    /// anywhere other than with that owner.
    func testAHoldWithNoLandingIsNobodysAndGetsTyped() {
        var landings = DictationController.Landings()
        landings.began(session: 1, landing: nil)
        XCTAssertFalse(landings.owes(1), "a plain hold types into the front app, as it always has")
    }

    func testAHoldWithALandingDeliversToIt() {
        var landings = DictationController.Landings()
        var heard: String?
        landings.began(session: 1, landing: { heard = $0 })

        XCTAssertTrue(landings.owes(1))
        landings.take(1)?("on my way")
        XCTAssertEqual(heard, "on my way")
    }

    /// The second bug, as a rule: an accepted press files its landing
    /// under the session it opened, and a hold is finalized under the
    /// session it began with. Nothing in between may move either.
    func testALandingStaysWithTheSessionThatOpenedIt() {
        var landings = DictationController.Landings()
        var heard: String?
        landings.began(session: 7, landing: { heard = $0 })

        // A refused press does not call began() at all now, so session 7
        // is still the live one when its words come back.
        XCTAssertTrue(landings.owes(7))
        landings.take(7)?("dinner at eight")
        XCTAssertEqual(heard, "dinner at eight")
    }

    /// The property everything rests on. Two more presses can land while
    /// a slow finalize is still running, and the closure for that hold is
    /// let go of. Its words must be DROPPED, never handed to the typing
    /// path, because they were spoken to a reply card and not to the app
    /// in front.
    func testWordsStillOwedAreDroppedRatherThanTypedOnceTheClosureIsGone() {
        var landings = DictationController.Landings()
        landings.began(session: 1, landing: { _ in })
        landings.began(session: 2, landing: nil)
        landings.began(session: 3, landing: nil)

        XCTAssertTrue(landings.owes(1), "session 1 still belongs to whoever asked")
        XCTAssertNil(landings.take(1), "its closure is gone, so there is nobody to deliver to")
        // The controller reads those two together: owed and undeliverable
        // means drop. Undeliverable alone would have meant type.
    }

    /// The two halves are kept for different lengths of time, deliberately.
    /// A closure is worth holding only while its hold could still be
    /// finalizing; ownership is worth holding for longer, because it is
    /// what stops a late arrival being typed somewhere private.
    func testOwnershipOutlivesTheClosure() {
        var landings = DictationController.Landings()
        landings.began(session: 1, landing: { _ in })
        landings.began(session: 2, landing: { _ in })
        landings.began(session: 3, landing: nil)

        XCTAssertTrue(landings.owes(2), "session 2 may still be finalizing, and is deliverable")
        XCTAssertTrue(landings.owes(1), "session 1 still belongs to whoever asked")
        XCTAssertNil(landings.take(1), "but it is no longer deliverable, so its words are dropped")
        XCTAssertFalse(landings.owes(3), "a plain hold owes nobody and gets typed")
    }

    /// Ownership is remembered, not hoarded.
    func testOwnershipIsForgottenEventually() {
        var landings = DictationController.Landings()
        landings.began(session: 1, landing: { _ in })
        for session in 2...12 { landings.began(session: session, landing: { _ in }) }
        XCTAssertFalse(landings.owes(1))
        XCTAssertTrue(landings.owes(12))
    }

    /// A card hold followed by an ordinary hold: the card's words go to
    /// the card, and the ordinary hold's words go where they always go.
    func testACardHoldThenAPlainHoldDoNotCrossOver() {
        var landings = DictationController.Landings()
        var cardHeard: String?
        landings.began(session: 1, landing: { cardHeard = $0 })
        landings.take(1)?("tell her I'm on my way")
        XCTAssertEqual(cardHeard, "tell her I'm on my way")

        landings.began(session: 2, landing: nil)
        XCTAssertFalse(landings.owes(2), "the next hold types into the editor")
    }
}
