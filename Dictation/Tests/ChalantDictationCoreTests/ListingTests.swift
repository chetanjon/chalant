import XCTest
@testable import ChalantDictationCore

/// Spoken lists become lists without waiting for the model ("refined at
/// once", spec 2026-08-17 late). Only explicit cues, three or more, and only
/// the shapes the founder actually dictates; anything less ships as prose and
/// the model can still make a list of it later.
final class ListingTests: XCTestCase {

    func testOrdinalCuesBecomeBullets() {
        let raw = "okay so three things first we move the review to thursday second we ship the draft on friday third we tell Priya on monday"
        XCTAssertEqual(
            Listing.format(raw),
            "Okay so three things:\n- We move the review to thursday\n- We ship the draft on friday\n- We tell Priya on monday")
    }

    func testNumberCuesBecomeANumberedList() {
        let raw = "number one call amma number two pick up the parcel number three send the notes"
        XCTAssertEqual(Listing.format(raw), "1. Call amma\n2. Pick up the parcel\n3. Send the notes")
    }

    func testBulletPointCuesBecomeBullets() {
        let raw = "bullet point fix the login bug bullet point update the pricing page bullet point email the beta list"
        XCTAssertEqual(Listing.format(raw), "- Fix the login bug\n- Update the pricing page\n- Email the beta list")
    }

    /// Punctuation the engine put between items is not carried onto the
    /// lines; a lead-in keeps its own words and gets a colon.
    func testEnginePunctuationAroundCuesIsCleaned() {
        let raw = "Three things. First, move the review. Second, ship the draft. Third, tell Priya."
        XCTAssertEqual(Listing.format(raw), "Three things:\n- Move the review.\n- Ship the draft.\n- Tell Priya.")
    }

    func testTwoItemsStayProse() {
        let raw = "first we move the review and second we ship the draft"
        XCTAssertEqual(Listing.format(raw), raw)
    }

    func testProseWithOrdinalsInItStaysProse() {
        let raw = "the first draft was fine but the second one is better and third parties agree"
        // "first" "second" "third" all appear, but as adjectives mid-sentence,
        // and the items they would start make no sense; the shape test below
        // is what keeps this prose.
        XCTAssertEqual(Listing.format(raw), raw)
    }

    func testEmptyItemsMeanNoList() {
        XCTAssertEqual(Listing.format("first second third"), "first second third")
    }
}
