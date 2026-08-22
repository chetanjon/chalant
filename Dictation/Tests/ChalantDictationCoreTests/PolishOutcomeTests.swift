import XCTest

@testable import ChalantDictationCore

/// The truth table behind `refinedAtOnce`, pinned because the first
/// version of the flag lied for two days: an unavailable model and a
/// run where every chunk failed both returned the input unchanged, and
/// the caller counted any non-nil reply as "refined at once"
/// (2026-08-21, campaign phase 0).
final class PolishOutcomeTests: XCTestCase {
    private func outcome(
        _ result: PolishOutcome.Result, chunks: Int = 1, failed: Int = 0
    ) -> PolishOutcome {
        PolishOutcome(
            result: result, text: result == .landed ? "cleaned" : nil,
            chunks: chunks, warmChunks: 0, failedChunks: failed,
            coldStart: false, secondsSinceLastPolish: nil)
    }

    func testTheRowsModelFieldsFollowTheOutcome() {
        let landed = PolishOutcome(
            result: .landed, text: "cleaned", chunks: 1, warmChunks: 0, failedChunks: 0,
            coldStart: false, secondsSinceLastPolish: nil, chunkReasons: ["landed"])
        XCTAssertEqual(landed.modelText, "cleaned")
        XCTAssertEqual(landed.modelReason, "landed")

        // Every chunk shipped as dictated: the text is the input again, so
        // the row gets null and the rule that fired, not "landed".
        let rejected = PolishOutcome(
            result: .landed, text: "as dictated", chunks: 1, warmChunks: 0, failedChunks: 1,
            coldStart: false, secondsSinceLastPolish: nil, chunkReasons: ["rejected:didNotStutter"])
        XCTAssertNil(rejected.modelText)
        XCTAssertEqual(rejected.modelReason, "rejected:didNotStutter")

        XCTAssertEqual(outcome(.belowMinimum).modelReason, "gated")
        XCTAssertEqual(outcome(.budgetExpiredInner).modelReason, "budgetExpired:inner")
        XCTAssertEqual(outcome(.modelUnavailable).modelReason, "skipped:unavailable")
        XCTAssertEqual(outcome(.empty).modelReason, "skipped:empty")
        XCTAssertNil(outcome(.belowMinimum).modelText)
    }

    func testLandedWithNoFailedChunksIsRefined() {
        XCTAssertTrue(outcome(.landed, chunks: 2, failed: 0).refinedAtOnce)
    }

    func testLandedWithSomeFailedChunksStillCountsAsRefined() {
        // One bad piece costs a sentence, not the paragraph: the rest
        // of the utterance did get the model.
        XCTAssertTrue(outcome(.landed, chunks: 3, failed: 2).refinedAtOnce)
    }

    func testLandedWhereEveryChunkFailedIsNotRefined() {
        // The whole reply is the input re-joined; nothing was cleaned.
        XCTAssertFalse(outcome(.landed, chunks: 2, failed: 2).refinedAtOnce)
    }

    func testUnavailableModelIsNotRefined() {
        XCTAssertFalse(outcome(.modelUnavailable).refinedAtOnce)
    }

    func testBelowMinimumIsNotRefined() {
        XCTAssertFalse(outcome(.belowMinimum).refinedAtOnce)
    }

    func testInnerBudgetMissIsNotRefined() {
        XCTAssertFalse(outcome(.budgetExpiredInner).refinedAtOnce)
    }

    func testEmptyIsNotRefined() {
        XCTAssertFalse(outcome(.empty).refinedAtOnce)
    }

    func testZeroChunksIsNeverRefined() {
        XCTAssertFalse(outcome(.landed, chunks: 0, failed: 0).refinedAtOnce)
    }
}
