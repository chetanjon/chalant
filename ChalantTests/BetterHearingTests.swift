import XCTest
@testable import Chalant

/// The second ear's pure edges. The model itself is not loaded here: it is a
/// 606 MB download the tests must never trigger, and the founder's real
/// preferences are `.standard` in this host, so every default check uses its
/// own suite.
@MainActor
final class BetterHearingTests: XCTestCase {

    func testOffUnlessSwitchedOn() {
        let suite = UserDefaults(suiteName: "chalant.tests.\(UUID().uuidString)")!
        XCTAssertFalse(BetterHearing.isEnabled(in: suite))
        BetterHearing.setEnabled(true, in: suite)
        XCTAssertTrue(BetterHearing.isEnabled(in: suite))
    }

    /// Whisper on a starved microphone invents sentences; a hearing far from
    /// the landed text's length is that, not a better ear.
    func testAHearingMustBeTheSameOrderOfLengthAsWhatLanded() {
        let landed = "Send the Chalant build to Kizu and tell Aiden it is ready."
        XCTAssertTrue(BetterHearing.plausible(hearing: "Send the Chalant build to Kizu and tell Aidan it is ready.", against: landed))
        XCTAssertTrue(BetterHearing.plausible(hearing: "Send the build to Kizu, tell Aidan.", against: landed))
        XCTAssertFalse(BetterHearing.plausible(hearing: "Baddie wannabe.", against: landed))
        XCTAssertFalse(BetterHearing.plausible(hearing: String(repeating: "and the show is not back until Wednesday ", count: 6), against: landed))
        XCTAssertFalse(BetterHearing.plausible(hearing: "", against: landed))
    }

    /// The plain-text passes the tokens path also runs: punctuation runs,
    /// doubled words, fillers.
    func testDeterministicPassesApplyToAHearing() {
        XCTAssertEqual(
            BetterHearing.deterministic("um so I think we should um move the the review"),
            "so I think we should move the review")
    }

    func testTheModelLivesInApplicationSupportNotDocuments() {
        XCTAssertTrue(BetterHearing.modelsFolder.path.contains("Application Support/Chalant/Models"))
        XCTAssertFalse(BetterHearing.modelsFolder.path.contains("/Documents/"))
    }
}
