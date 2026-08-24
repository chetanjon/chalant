import XCTest

@testable import Chalant

/// The cleanup model has three positions since 2026-08-22: off, shadow (it
/// runs after the words land and is only ever read back from the corpus
/// row), live (it runs before the words land and can change them). Shadow
/// is the default. Each test uses its own defaults suite: the test host is
/// the real app, so `.standard` is the founder's preferences.
final class CleanupModeTests: XCTestCase {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "chalant.tests.cleanup.\(UUID().uuidString)")!
    }

    func testTheDefaultIsShadow() {
        XCTAssertEqual(Cleanup.mode(in: suite()), .shadow)
    }

    func testAModeSetIsAModeRead() {
        let defaults = suite()
        Cleanup.setMode(.live, in: defaults)
        XCTAssertEqual(Cleanup.mode(in: defaults), .live)
        Cleanup.setMode(.off, in: defaults)
        XCTAssertEqual(Cleanup.mode(in: defaults), .off)
    }

    func testTheOldSwitchMigrates() {
        // 1.14.0 to 1.26.0 stored a Bool under "dictationCleanup". Off stays
        // off; on (the old default) becomes shadow, the new default, because
        // the founder took the model off the path on purpose.
        let off = suite()
        off.set(false, forKey: Cleanup.enabledKey)
        XCTAssertEqual(Cleanup.mode(in: off), .off)
        let on = suite()
        on.set(true, forKey: Cleanup.enabledKey)
        XCTAssertEqual(Cleanup.mode(in: on), .shadow)
    }

    func testAnExplicitModeOutranksTheOldSwitch() {
        let defaults = suite()
        defaults.set(false, forKey: Cleanup.enabledKey)
        Cleanup.setMode(.live, in: defaults)
        XCTAssertEqual(Cleanup.mode(in: defaults), .live)
    }

    func testAnUnknownStoredValueFallsBackToShadow() {
        let defaults = suite()
        defaults.set("sideways", forKey: Cleanup.modeKey)
        XCTAssertEqual(Cleanup.mode(in: defaults), .shadow)
    }
}
