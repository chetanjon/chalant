import XCTest
@testable import Notes

final class ChecklistTests: XCTestCase {
    func testToggleSwapsMarkers() {
        XCTAssertEqual(Checklist.toggle("□ milk"), "■ milk")
        XCTAssertEqual(Checklist.toggle("■ milk"), "□ milk")
        XCTAssertEqual(Checklist.toggle("milk"), "milk")
    }

    func testLineRangeExcludesTerminator() {
        let text = "Title\n□ milk\neggs"
        XCTAssertEqual(Checklist.lineRange(in: text, at: 0), NSRange(location: 0, length: 5))
        XCTAssertEqual(Checklist.lineRange(in: text, at: 7), NSRange(location: 6, length: 6))
        XCTAssertEqual(Checklist.line(in: text, at: 15), "eggs")
        // A cursor past the end clamps to the last line.
        XCTAssertEqual(Checklist.line(in: text, at: 99), "eggs")
    }

    func testToolbarButtonPrefixesAndStrips() {
        let plain = "Title\nmilk"
        let made = Checklist.toggleItem(in: plain, at: 8)
        XCTAssertEqual(made, Checklist.Edit(text: "Title\n□ milk", cursor: 10))
        let back = Checklist.toggleItem(in: made.text, at: made.cursor)
        XCTAssertEqual(back, Checklist.Edit(text: plain, cursor: 8))
    }

    func testStrippingKeepsCursorOnTheLine() {
        // Cursor right after the marker goes to the line start, not before it.
        let edit = Checklist.toggleItem(in: "a\n□ b", at: 3)
        XCTAssertEqual(edit, Checklist.Edit(text: "a\nb", cursor: 2))
    }

    func testTapOnMarkerToggles() {
        let text = "Title\n□ milk"
        XCTAssertTrue(Checklist.isOnMarker(in: text, at: 6))
        XCTAssertTrue(Checklist.isOnMarker(in: text, at: 7))
        XCTAssertFalse(Checklist.isOnMarker(in: text, at: 8))
        XCTAssertFalse(Checklist.isOnMarker(in: text, at: 0))
        XCTAssertEqual(Checklist.toggleDone(in: text, at: 6).text, "Title\n■ milk")
        XCTAssertEqual(Checklist.toggleDone(in: text, at: 2).text, text)
    }

    func testReturnContinuesTheList() {
        let text = "Title\n□ milk"
        let edit = Checklist.handleReturn(in: text, selection: NSRange(location: 12, length: 0))
        XCTAssertEqual(edit, Checklist.Edit(text: "Title\n□ milk\n□ ", cursor: 15))
    }

    func testReturnInTheMiddleSplitsTheItem() {
        let edit = Checklist.handleReturn(in: "□ milk", selection: NSRange(location: 4, length: 0))
        XCTAssertEqual(edit, Checklist.Edit(text: "□ mi\n□ lk", cursor: 7))
    }

    func testReturnOnEmptyItemEndsTheList() {
        let text = "Title\n□ milk\n□ "
        let edit = Checklist.handleReturn(in: text, selection: NSRange(location: 15, length: 0))
        XCTAssertEqual(edit, Checklist.Edit(text: "Title\n□ milk\n", cursor: 13))
    }

    func testReturnOnPlainLineIsLeftToTheTextView() {
        XCTAssertNil(Checklist.handleReturn(in: "Title\nmilk", selection: NSRange(location: 10, length: 0)))
    }

    func testReturnWithSelectionReplacesIt() {
        let edit = Checklist.handleReturn(in: "□ milk and eggs", selection: NSRange(location: 6, length: 9))
        XCTAssertEqual(edit, Checklist.Edit(text: "□ milk\n□ ", cursor: 9))
    }
}
