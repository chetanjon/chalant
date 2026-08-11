import XCTest

@testable import Chalant

/// Pins the sensing half of the pill's fullscreen yield: which window
/// lists read as "a fullscreen app owns this display". The wiring
/// (poll cadence, face flag, the hide itself) is judged by eye; the
/// classification is the part that can rot silently.
final class FullscreenSensorTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    private func window(
        _ bounds: CGRect, layer: Int = 0, pid: pid_t = 999, alpha: Double = 1
    ) -> [String: Any] {
        [
            kCGWindowLayer as String: layer,
            kCGWindowOwnerPID as String: pid,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary,
        ]
    }

    func testAWindowCoveringTheDisplayExactlyIsFullscreen() {
        XCTAssertTrue(FullscreenSensor.hasFullscreenWindow(
            in: [window(display)], displayBounds: display, excludingPID: 1
        ))
    }

    func testAMaximizedWindowShortOfTheMenuBarIsNot() {
        // An ordinary maximized window never covers the menu bar's
        // strip; only a fullscreen Space does.
        let maximized = CGRect(x: 0, y: 25, width: 2560, height: 1415)
        XCTAssertFalse(FullscreenSensor.hasFullscreenWindow(
            in: [window(maximized)], displayBounds: display, excludingPID: 1
        ))
    }

    func testARoundingHairOfSlackStillCounts() {
        let hair = CGRect(x: 0.5, y: 0, width: 2559.5, height: 1440)
        XCTAssertTrue(FullscreenSensor.hasFullscreenWindow(
            in: [window(hair)], displayBounds: display, excludingPID: 1
        ))
    }

    func testOurOwnWindowsNeverCount() {
        XCTAssertFalse(FullscreenSensor.hasFullscreenWindow(
            in: [window(display, pid: 42)], displayBounds: display, excludingPID: 42
        ))
    }

    func testNonNormalLayersAndInvisibleWindowsNeverCount() {
        XCTAssertFalse(FullscreenSensor.hasFullscreenWindow(
            in: [window(display, layer: 25)], displayBounds: display, excludingPID: 1
        ), "a status-bar-level window is chrome, not an app's fullscreen")
        XCTAssertFalse(FullscreenSensor.hasFullscreenWindow(
            in: [window(display, alpha: 0)], displayBounds: display, excludingPID: 1
        ), "an invisible window covers nothing the eye cares about")
    }

    func testAnotherDisplaysFullscreenLeavesThisOneAlone() {
        let other = CGRect(x: 2560, y: 0, width: 1512, height: 982)
        XCTAssertFalse(FullscreenSensor.hasFullscreenWindow(
            in: [window(other)], displayBounds: display, excludingPID: 1
        ))
        XCTAssertTrue(FullscreenSensor.hasFullscreenWindow(
            in: [window(other)], displayBounds: other, excludingPID: 1
        ))
    }

    func testAnEmptyScreenIsNobodysFullscreen() {
        XCTAssertFalse(FullscreenSensor.hasFullscreenWindow(
            in: [], displayBounds: display, excludingPID: 1
        ))
    }

    func testASplitViewTileCountsBecauseItsChromeSitsUnderThePill() {
        // Split view is a fullscreen Space too: each tile runs the full
        // height to the very top, and the pill straddles the divider.
        let leftTile = CGRect(x: 0, y: 0, width: 1280, height: 1440)
        XCTAssertTrue(FullscreenSensor.hasFullscreenWindow(
            in: [window(leftTile)], displayBounds: display, excludingPID: 1
        ))
    }

    func testANarrowEdgePanelNeverCounts() {
        // Full height at an edge, but nothing of it is under the pill's
        // home at top centre.
        let sidebar = CGRect(x: 0, y: 0, width: 400, height: 1440)
        XCTAssertFalse(FullscreenSensor.hasFullscreenWindow(
            in: [window(sidebar)], displayBounds: display, excludingPID: 1
        ))
    }
}
