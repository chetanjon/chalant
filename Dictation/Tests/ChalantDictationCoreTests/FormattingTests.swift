import XCTest
@testable import ChalantDictationCore

/// Track 2 of "Instant, then tidied in place" (spec 2026-08-17): spoken lists
/// become lists, and the guard knows formatting is not a fidelity error.
final class FormattingTests: XCTestCase {

    // MARK: - Spotting a spoken list

    func testOrdinalEnumerationLooksLikeAList() {
        XCTAssertTrue(CleanupPrompt.looksLikeList(
            "so three things first we move the review second we ship the draft third we tell Priya"))
        XCTAssertTrue(CleanupPrompt.looksLikeList(
            "number one call amma number two pick up the parcel number three send the notes"))
        XCTAssertTrue(CleanupPrompt.looksLikeList(
            "bullet point move the review bullet point ship the draft bullet point tell Priya"))
    }

    func testTwoItemsAreProseNotAList() {
        XCTAssertFalse(CleanupPrompt.looksLikeList("first we move the review and second we ship the draft"))
    }

    func testProseWithNumbersIsNotAList() {
        XCTAssertFalse(CleanupPrompt.looksLikeList(
            "the invoice was paid on the twelfth not the twentieth so we shouldn't be getting a reminder"))
        XCTAssertFalse(CleanupPrompt.looksLikeList("remind me to call amma at six and pick up the parcel at seven"))
    }

    // MARK: - Lists stay whole

    /// Chunking at ~40 words would split a spoken list across chunks and format
    /// them differently. A list under the whole-list ceiling goes as one piece.
    func testAShortListIsOneChunk() {
        let list = "okay so three things. first we move the review to thursday because Priya is away. "
            + "second we ship the draft on friday whatever happens. third we tell the client on monday morning "
            + "and ask for the invoice to be paid by the end of the month."
        XCTAssertGreaterThan(list.split(whereSeparator: \.isWhitespace).count, CleanupPrompt.chunkTargetWords)
        XCTAssertEqual(CleanupPrompt.chunks(list).count, 1)
    }

    func testAVeryLongListStillChunks() {
        let item = "first we move the review to thursday because Priya is away and the deck is not ready anyway. "
        let long = String(repeating: item, count: 8)
        XCTAssertGreaterThan(CleanupPrompt.chunks(long).count, 1)
    }

    // MARK: - The guard and formatting

    func testGuardAcceptsABulletedList() {
        let raw = "first move the review to thursday second ship the draft friday third tell Priya monday"
        let cleaned = "- Move the review to Thursday.\n- Ship the draft Friday.\n- Tell Priya Monday."
        XCTAssertEqual(FidelityGuard.check(raw: raw, cleaned: cleaned), .ok)
    }

    func testGuardAcceptsANumberedListWithoutInventingNumbers() {
        let raw = "number one call amma number two pick up the parcel number three send the notes"
        let cleaned = "1. Call Amma.\n2. Pick up the parcel.\n3. Send the notes."
        XCTAssertEqual(FidelityGuard.check(raw: raw, cleaned: cleaned), .ok)
    }

    func testGuardStillCatchesAReplacedListItem() {
        let raw = "first move the review to thursday second ship the draft friday third tell Priya monday"
        let cleaned = "- Buy milk.\n- Walk the dog.\n- Call the bank."
        if case .ok = FidelityGuard.check(raw: raw, cleaned: cleaned) {
            XCTFail("a wholesale replacement dressed as a list must not pass")
        }
    }

    func testGuardStillCatchesANumberThatWasNotSaid() {
        let raw = "first move the review second ship the draft third tell Priya"
        let cleaned = "1. Move the review to room 4.\n2. Ship the draft.\n3. Tell Priya."
        if case .ok = FidelityGuard.check(raw: raw, cleaned: cleaned) {
            XCTFail("a digit that is not a list marker is still an invented number")
        }
    }

    // MARK: - The prompt says so

    func testInstructionsAskForListsAndParagraphs() {
        XCTAssertTrue(CleanupPrompt.instructions.contains("list"))
        XCTAssertTrue(CleanupPrompt.instructions.contains("new paragraph"))
        // The small model follows examples where it ignores rules: probed
        // 2026-08-17, rules alone left "first... second... third" as prose and
        // kept "number one" in the bullets; with these three examples all four
        // probe cases came back exactly right.
        XCTAssertTrue(CleanupPrompt.instructions.contains("- Move the review."))
        XCTAssertTrue(CleanupPrompt.instructions.contains("1. Call Amma."))
    }

    /// The model marks a line break the markdown way ("Call Amma.  "); those
    /// spaces must not be pasted.
    func testUnwrapDropsTrailingSpacesOnEveryLine() {
        XCTAssertEqual(CleanupPrompt.unwrap("1. Call Amma.  \n2. Send the notes.  "), "1. Call Amma.\n2. Send the notes.")
    }
}

/// Track 3, "clean while you talk": chunks that are closed while the speaker is
/// still talking can be tidied early, so at release only the tail waits.
final class PretidyChunkingTests: XCTestCase {

    private let sentence = "we should move the review to thursday because Priya is not back until wednesday. "

    /// Greedy fill from the front means adding sentences at the end never moves
    /// an earlier boundary, which is what makes a chunk tidied mid-hold reusable
    /// at release.
    func testEarlierChunksAreStableAsTextGrows() {
        let short = String(repeating: sentence, count: 6)
        let long = short + String(repeating: sentence, count: 4)
        let closed = CleanupPrompt.closedChunks(short)
        let later = CleanupPrompt.chunks(long)
        XCTAssertFalse(closed.isEmpty)
        XCTAssertEqual(Array(later.prefix(closed.count)), closed)
    }

    /// The last chunk is still growing; it is never closed.
    func testTheLastChunkIsNeverClosed() {
        let text = String(repeating: sentence, count: 6)
        let all = CleanupPrompt.chunks(text)
        XCTAssertEqual(CleanupPrompt.closedChunks(text), Array(all.dropLast()))
        XCTAssertEqual(CleanupPrompt.closedChunks("one short sentence."), [])
    }
}
