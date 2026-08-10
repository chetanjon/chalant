import SwiftUI
import XCTest

@testable import Chalant

/// Round 2 of the premium finish: the pour. These tests pin the shape's
/// animatable surface so a corner can never again snap while the rest
/// of the island glides (the pill's top radius did exactly that).
@MainActor
final class MotionPourTests: XCTestCase {
    func testEveryShapeParameterRidesTheAnimation() {
        var shape = IslandShape(eave: 12, bottomRadius: 16, belly: 0)
        shape.topRadius = 16
        shape.tipRadius = 5
        var data = shape.animatableData
        data.first.first = 22          // eave
        data.first.second = 40         // bottomRadius
        data.second.first.first = 0    // belly
        data.second.first.second = 30  // topRadius
        data.second.second = 8         // tipRadius
        shape.animatableData = data
        XCTAssertEqual(shape.eave, 22)
        XCTAssertEqual(shape.bottomRadius, 40)
        XCTAssertEqual(shape.belly, 0)
        XCTAssertEqual(shape.topRadius, 30)
        XCTAssertEqual(shape.tipRadius, 8)
    }

    func testACrashIsMarkedSeenWithoutForgettingItThisSession() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "chalant.crashSeenAt")
        let date = Date(timeIntervalSince1970: 1_754_500_000)
        CrashWatch.markSeen(date)
        XCTAssertEqual(
            defaults.object(forKey: "chalant.crashSeenAt") as? Date, date)
        defaults.removeObject(forKey: "chalant.crashSeenAt")
    }
}
