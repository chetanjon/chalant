import XCTest
@testable import Chalant

final class DictationStripTests: XCTestCase {

    // MARK: - Level formulas (spec, "Motion")

    func testRimAtSilenceIsTheRestingRim() {
        let rim = DictationStripLevel.rim(0)
        XCTAssertEqual(rim.radius, 2, accuracy: 0.001)
        XCTAssertEqual(rim.opacity, 0.10, accuracy: 0.001)
    }

    func testRimAtFullReachesTheMaxima() {
        let rim = DictationStripLevel.rim(1)
        XCTAssertEqual(rim.radius, 24, accuracy: 0.001)
        XCTAssertEqual(rim.opacity, 0.65, accuracy: 0.001)
    }

    func testPoolIsInvisibleAtSilenceAndCappedAtFull() {
        XCTAssertEqual(DictationStripLevel.pool(0), 0, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.pool(1), 0.22, accuracy: 0.001)
    }

    func testDotGrowsFromSixToTwelve() {
        XCTAssertEqual(DictationStripLevel.dot(0).diameter, 6, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.dot(1).diameter, 12, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.dot(0).glow, 4, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.dot(1).glow, 18, accuracy: 0.001)
    }

    /// The audio engine reports raw peak, which can exceed 1 on a hot mic
    /// and be negative on a broken one. The formulas must never be fed
    /// either.
    func testLevelIsClampedBeforeUse() {
        XCTAssertEqual(DictationStripLevel.clamp(-0.5), 0)
        XCTAssertEqual(DictationStripLevel.clamp(3.0), 1)
        XCTAssertEqual(DictationStripLevel.clamp(0.4), 0.4, accuracy: 0.0001)
        XCTAssertEqual(DictationStripLevel.rim(3.0).radius, 24, accuracy: 0.001)
    }
}
