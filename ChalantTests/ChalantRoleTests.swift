import XCTest
@testable import Chalant

/// One app, two faces (founder, 2026-08-20): the role and the hidden-island
/// rule it drives. Uses its own defaults suite: the test host is the real
/// app, so `.standard` here is the founder's preferences.
@MainActor
final class ChalantRoleTests: XCTestCase {

    func testTheDefaultIsBothAndTheChoicePersists() {
        let suite = UserDefaults(suiteName: "chalant.tests.\(UUID().uuidString)")!
        XCTAssertEqual(ChalantRole.current(in: suite), .both)
        ChalantRole.set(.dictation, in: suite)
        XCTAssertEqual(ChalantRole.current(in: suite), .dictation)
        // Garbage in the key falls back to the whole app, never a crash and
        // never a hidden island nobody chose.
        suite.set("islandd", forKey: ChalantRole.defaultsKey)
        XCTAssertEqual(ChalantRole.current(in: suite), .both)
    }

    /// Hidden is the rule; dictation's own moments and genuine notices are
    /// the exceptions. The pointer is deliberately not one.
    func testDictationOnlyHidesEverythingButItsOwnMoments() {
        // At rest with nothing to say: hidden.
        XCTAssertTrue(ChalantRole.islandHidden(
            collapsed: true, toastShowing: false, sentLightShowing: false, somethingWantsYou: false))
        // The strip is up (not collapsed): shown.
        XCTAssertFalse(ChalantRole.islandHidden(
            collapsed: false, toastShowing: false, sentLightShowing: false, somethingWantsYou: false))
        // The nowhere-to-type rescue speaks through the glance: shown.
        XCTAssertFalse(ChalantRole.islandHidden(
            collapsed: true, toastShowing: true, sentLightShowing: false, somethingWantsYou: false))
        // The sent light is finishing after a release: shown.
        XCTAssertFalse(ChalantRole.islandHidden(
            collapsed: true, toastShowing: false, sentLightShowing: true, somethingWantsYou: false))
        // An update or crash notice still reaches a dictation-only user.
        XCTAssertFalse(ChalantRole.islandHidden(
            collapsed: true, toastShowing: false, sentLightShowing: false, somethingWantsYou: true))
    }
}
