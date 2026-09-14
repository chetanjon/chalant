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
