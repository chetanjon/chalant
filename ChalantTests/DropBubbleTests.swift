import XCTest

@testable import Chalant

/// Pins the one number nobody had measured about the mid-screen drop
/// bubble: how much daylight sits between the bottom of the collapsed
/// island and the top of the bubble.
///
/// It matters because both live inside the island panel's 1000x720
/// frame. A drag over the panel's transparent regions falls through to
/// whatever is behind, so the bubble catches drops fine; but a bubble
/// drawn far enough up to touch the VISIBLE island would light
/// `isDropTargeted`, and the bubble hides itself on purpose when that
/// happens so the island can take the drop. The symptom would be a
/// bubble that blinks out exactly as the drag arrives.
///
/// Raising `dockDropFromTop` or growing `dockSize.height` both eat
/// this clearance, which is why the arithmetic is pinned rather than
/// judged by eye.
@MainActor
final class DropBubbleTests: XCTestCase {
    /// A collapsed island is `configured height + 3`, plus 4 more
    /// while hovering (`NotchViewModel.collapsedFrame`). 38 is the
    /// shipped default, so this is the tallest it gets.
    private let tallestCollapsed: CGFloat = 38 + 3 + 4

    func testClearsTheIslandOnBothDisplaysOfTheBuildMachine() {
        // Measured 2026-08-12 with CGWindowList + NSScreen.
        let external = NotchWindowController.dropClearance(
            screenHeight: 1440, collapsedHeight: tallestCollapsed
        )
        let builtIn = NotchWindowController.dropClearance(
            screenHeight: 956, collapsedHeight: tallestCollapsed
        )
        XCTAssertEqual(external, 173, accuracy: 0.5)
        XCTAssertEqual(builtIn, 76.2, accuracy: 0.5)
    }

    func testTheBuiltInIsTheTighterOfTheTwoAndStillHasRoom() {
        // The percentage is of screen height, so the SHORT display is
        // the one that runs out first, not the large external.
        let builtIn = NotchWindowController.dropClearance(
            screenHeight: 956, collapsedHeight: tallestCollapsed
        )
        XCTAssertGreaterThan(builtIn, 60, "the tighter display lost its margin")
    }

    func testItOnlyCollidesBelowAScreenNoMacHas() {
        // height * 0.20 - 70 - 45 == 0  =>  height == 575
        XCTAssertEqual(
            NotchWindowController.dropClearance(
                screenHeight: 575, collapsedHeight: tallestCollapsed
            ),
            0, accuracy: 0.5
        )
        XCTAssertLessThan(
            NotchWindowController.dropClearance(
                screenHeight: 500, collapsedHeight: tallestCollapsed
            ),
            0
        )
        // The shortest display Apple ships is far above that.
        XCTAssertGreaterThan(
            NotchWindowController.dropClearance(
                screenHeight: 800, collapsedHeight: tallestCollapsed
            ),
            0
        )
    }

    func testATallerIslandEatsTheClearancePointForPoint() {
        let base = NotchWindowController.dropClearance(
            screenHeight: 956, collapsedHeight: 45
        )
        let taller = NotchWindowController.dropClearance(
            screenHeight: 956, collapsedHeight: 65
        )
        XCTAssertEqual(base - taller, 20, accuracy: 0.01)
    }
}
