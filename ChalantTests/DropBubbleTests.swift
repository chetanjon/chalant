import XCTest

@testable import Chalant

/// Where the drop tray sits: hanging just under the collapsed island, at the
/// top of the screen, never in the middle of it.
///
/// It used to sit a fifth of the way down the screen (1.12.0), because a
/// drag dwelling within a few points of the top edge fires Mission
/// Control's reveal and that cannot be disabled for file drags. The founder
/// (2026-08-18): "there is a box popping up in the middle of the screen, it's
/// a bit distracting for this window; move it to the top." A tray whose top
/// edge is 55pt from the screen's top is still nowhere near the reveal's few
/// points, and it reads as the island's own mouth. The clearance between the
/// tallest collapsed island (38 + 3 + 4 while hovering) and the tray is a
/// fixed gap, so it no longer depends on the display's height at all.
@MainActor
final class DropBubbleTests: XCTestCase {
    private let tallestCollapsed: CGFloat = 38 + 3 + 4

    func testTheTrayHangsJustUnderTheIslandOnAnyDisplay() {
        for height in [956.0, 1440.0, 800.0] as [CGFloat] {
            let top = NotchWindowController.dockTopFromScreenTop(collapsedHeight: tallestCollapsed)
            XCTAssertEqual(top, 55, accuracy: 0.001, "screen \(height)")
            XCTAssertEqual(
                NotchWindowController.dropClearance(screenHeight: height, collapsedHeight: tallestCollapsed),
                NotchWindowController.dockGapBelowIsland, accuracy: 0.001)
        }
    }

    func testTheTrayNeverTouchesTheIsland() {
        // A taller island pushes the tray down by the same amount; the gap
        // is constant, so `isDropTargeted` on the island can never steal the
        // tray's drags.
        let base = NotchWindowController.dockTopFromScreenTop(collapsedHeight: 45)
        let taller = NotchWindowController.dockTopFromScreenTop(collapsedHeight: 65)
        XCTAssertEqual(taller - base, 20, accuracy: 0.001)
        XCTAssertGreaterThan(NotchWindowController.dockGapBelowIsland, 0)
    }

    func testTheTrayStaysWellClearOfTheTopEdge() {
        // Mission Control's drag reveal fires within a few points of the
        // edge; the tray's own top is an order of magnitude further away, and
        // its centre, where a drop lands, further still.
        let top = NotchWindowController.dockTopFromScreenTop(collapsedHeight: tallestCollapsed)
        XCTAssertGreaterThan(top, 40)
        XCTAssertGreaterThan(top + NotchWindowController.dockSize.height / 2, 80)
    }

    func testTheTrayIsShortSoItCoversLittle() {
        XCTAssertLessThanOrEqual(NotchWindowController.dockSize.height, 70)
        XCTAssertLessThanOrEqual(NotchWindowController.dockSize.width, 340)
    }
}
