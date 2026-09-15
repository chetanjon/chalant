import XCTest

@testable import Chalant

/// The light between letting go and the words arriving.
///
/// **There was nothing here before.** `surface.hide()` was called at key-up,
/// before draining, finalization, cleanup and insertion, so everything
/// expensive happened in the dark and `restAfterDictation` enforced 1.4 s of
/// quiet on top of it. That was invisible while the gap was 0.4 s at p50 on
/// Apple's engine. It is not reliably that small any more.
@MainActor
final class DictationPhaseTests: XCTestCase {

    private func model() -> NotchViewModel { NotchViewModel() }

    func testAHoldStartsListening() {
        let m = model()
        m.beginDictating(into: "TextEdit", mic: "Built-in", on: nil)
        XCTAssertEqual(m.state, .dictating)
        XCTAssertEqual(m.dictationPhase, .listening)
    }

    /// The key came up. Still `.dictating`, because the session is not over:
    /// the words are not anywhere yet.
    func testReleaseGoesToWorkingWithoutEndingTheSession() {
        let m = model()
        m.beginDictating(into: "TextEdit", mic: nil, on: nil)
        m.finishDictationListening()
        XCTAssertEqual(m.state, .dictating)
        XCTAssertEqual(m.dictationPhase, .working)
    }

    /// **The room stays quiet while it works.** Restoring the music at key-up
    /// would announce a finish that has not happened, and the words can still
    /// fail to land after it.
    func testTheMeterStopsButTheSessionDoesNot() {
        let m = model()
        m.beginDictating(into: "TextEdit", mic: nil, on: nil)
        m.updateDictating(level: 0.8, mic: nil)
        XCTAssertGreaterThan(m.dictationLevel, 0)
        m.finishDictationListening()
        XCTAssertEqual(m.dictationLevel, 0, "a closed microphone has no level to show")
        XCTAssertEqual(m.dictationPhase, .working)
    }

    /// A meter tick arriving after release must not put the light back to
    /// listening: the pump and the meter timer are separate, and one can
    /// outlive the other by a frame.
    func testALateMeterTickDoesNotUndoTheWorkingPhase() {
        let m = model()
        m.beginDictating(into: "TextEdit", mic: nil, on: nil)
        m.finishDictationListening()
        m.updateDictating(level: 0.9, mic: nil)
        XCTAssertEqual(m.dictationPhase, .working)
    }

    func testEndingResetsThePhaseForTheNextHold() {
        let m = model()
        m.beginDictating(into: "TextEdit", mic: nil, on: nil)
        m.finishDictationListening()
        m.endDictating()
        XCTAssertEqual(m.state, .collapsed)
        XCTAssertEqual(m.dictationPhase, .listening)

        m.beginDictating(into: "Slack", mic: nil, on: nil)
        XCTAssertEqual(m.dictationPhase, .listening)
    }

    /// Nothing outside a live session may move the phase, for the same reason
    /// `updateDictating` and `endDictating` already guard: a stray call would
    /// strand the island.
    func testTheresNoPhaseToFinishWhenNothingIsDictating() {
        let m = model()
        m.finishDictationListening()
        XCTAssertEqual(m.dictationPhase, .listening)
        XCTAssertNotEqual(m.state, .dictating)
    }
}

/// The recovery glance, and whether anyone can see it.
///
/// **The gap this closes.** The island is hidden by role for a "just
/// dictation" user, hidden for 1.4 s after every dictation, and hidden by
/// auto-hide, and all three exceptions were written for `glanceToast` alone.
/// A recovery appears in exactly that window, on exactly the path where the
/// user's words did not land, so a Copy and a Retry nobody can see is worse
/// than no affordance at all.
@MainActor
final class DictationRecoveryTests: XCTestCase {

    func testARecoveryCountsAsSomethingWorthShowing() {
        // The role rule the view reads. A recovery has to pass the same gate a
        // toast does.
        XCTAssertTrue(
            ChalantRole.islandHidden(
                collapsed: true, toastShowing: false, sentLightShowing: false,
                somethingWantsYou: false))
        XCTAssertFalse(
            ChalantRole.islandHidden(
                collapsed: true, toastShowing: true, sentLightShowing: false,
                somethingWantsYou: false))
    }

    func testARecoveryIsOfferedAndCleared() {
        let m = NotchViewModel()
        XCTAssertNil(m.dictationRecovery)
        m.offerRecovery(
            NotchViewModel.Recovery(text: "hello there", reason: "Couldn't type there", retry: nil))
        XCTAssertEqual(m.dictationRecovery?.text, "hello there")
        m.clearRecovery()
        XCTAssertNil(m.dictationRecovery)
    }

    /// Latest wins, like the toast. Two failures in a row must not queue.
    func testASecondRecoveryReplacesTheFirst() {
        let m = NotchViewModel()
        m.offerRecovery(NotchViewModel.Recovery(text: "first", reason: "one", retry: nil))
        m.offerRecovery(NotchViewModel.Recovery(text: "second", reason: "two", retry: nil))
        XCTAssertEqual(m.dictationRecovery?.text, "second")
    }

    /// A retry is offered only where there is something to retry into, which
    /// is what the secure-input path relies on: while a password field holds
    /// the keyboard, a second paste fails the same way.
    func testARecoveryCanCarryNoRetry() {
        let m = NotchViewModel()
        m.offerRecovery(
            NotchViewModel.Recovery(text: "secret", reason: "A password field", retry: nil))
        XCTAssertNil(m.dictationRecovery?.retry)
    }

    /// Copy takes it back to the clipboard and dismisses, because the user has
    /// now done the thing the glance was asking about.
    func testCopyingClearsTheGlance() {
        let m = NotchViewModel()
        m.offerRecovery(NotchViewModel.Recovery(text: "words", reason: "nowhere", retry: nil))
        m.copyRecoveredText()
        XCTAssertNil(m.dictationRecovery)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "words")
    }
}
