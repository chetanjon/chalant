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
}
