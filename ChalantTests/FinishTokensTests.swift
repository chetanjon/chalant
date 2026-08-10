import SwiftUI
import XCTest

@testable import Chalant

/// The premium-finish tokens (spec 2026-08-10). Pinned so a future
/// cleanup cannot quietly drift the approved look.
@MainActor
final class FinishTokensTests: XCTestCase {
    func testTheFinishTokensExistAtTheirApprovedValues() {
        XCTAssertEqual(Theme.Space.zone, 26)
        XCTAssertEqual(Theme.Radius.artwork, 14)
        XCTAssertEqual(Theme.Island.radiusExpanded, 40)
        // Fonts are opaque; existence is the assertion. A wrong size
        // shows up in the screenshot proof, a deleted token here.
        _ = Theme.Fonts.headline
        _ = Theme.Fonts.subhead
        _ = Theme.Fonts.timeMono
        _ = Theme.Fonts.iconThin(.m)
    }

    func testRemainingTimeReadsAsMinusMinutesSeconds() {
        XCTAssertEqual(MusicRow.remainingClock(elapsed: 1358, duration: 1660), "-5:02")
        XCTAssertEqual(MusicRow.remainingClock(elapsed: 0, duration: 61), "-1:01")
    }

    func testRemainingTimeNeverGoesPositiveOrBreaksOnLiveStreams() {
        // Elapsed past the duration (a seek race) clamps to -0:00.
        XCTAssertEqual(MusicRow.remainingClock(elapsed: 200, duration: 100), "-0:00")
        // A live stream reports no duration; the clock stays honest.
        XCTAssertEqual(MusicRow.remainingClock(elapsed: 100, duration: 0), "-0:00")
    }

    func testRemainingTimeGrowsHoursOnlyWhenNeeded() {
        XCTAssertEqual(MusicRow.remainingClock(elapsed: 0, duration: 3723), "-1:02:03")
    }

    func testScrubMathMapsTheBarToTheTrackAndClampsTheEnds() {
        XCTAssertEqual(ScrubBar.position(atX: 150, width: 300, duration: 200), 100)
        XCTAssertEqual(ScrubBar.position(atX: -20, width: 300, duration: 200), 0)
        XCTAssertEqual(ScrubBar.position(atX: 900, width: 300, duration: 200), 200)
        XCTAssertEqual(ScrubBar.position(atX: 10, width: 0, duration: 200), 0)
    }
}
