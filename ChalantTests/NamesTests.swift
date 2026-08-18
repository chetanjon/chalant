import XCTest
@testable import Chalant

/// The names both ears know: the typed list's edges and the Contacts filter.
/// Every default check uses its own suite, because `.standard` in this host is
/// the founder's real preferences (see `BetterHearingTests`).
@MainActor
final class NamesTests: XCTestCase {

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "chalant.tests.\(UUID().uuidString)")!
    }

    func testATypedNameIsKeptAsTypedOnce() {
        let d = suite()
        XCTAssertTrue(Vocabulary.add("Kizu", in: d))
        XCTAssertFalse(Vocabulary.add("kizu", in: d), "the same name in another case is the same name")
        XCTAssertFalse(Vocabulary.add("   ", in: d))
        XCTAssertTrue(Vocabulary.add(" Gangothri ", in: d))
        XCTAssertEqual(Vocabulary.terms(in: d), ["Kizu", "Gangothri"])
    }

    func testForgettingATypedNameRemovesItWhateverTheCase() {
        let d = suite()
        Vocabulary.add("Aatram", in: d)
        Vocabulary.add("Priya", in: d)
        Vocabulary.remove("aatram", in: d)
        XCTAssertEqual(Vocabulary.terms(in: d), ["Priya"])
        Vocabulary.remove("Priya", in: d)
        XCTAssertEqual(Vocabulary.terms(in: d), [])
        XCTAssertNil(d.object(forKey: Vocabulary.key), "an empty list is no list, so the hand path still reads as unset")
    }

    /// The pool keeps names and drops what is not one: ordinary words (both
    /// ears already hear those), initials, numbers, and repeats.
    func testContactPiecesAreFilteredToNamesWorthKnowing() {
        let usable = ContactNames.usable([
            "Priya", "Gangothri", "Jonnalagadda", "Rose", "Mark", "the", "J", "8800",
            "priya", "O'Brien", "Jean-Luc", "Dr.", "🙂", "Supabase",
        ])
        XCTAssertTrue(usable.contains("Priya"))
        XCTAssertTrue(usable.contains("Gangothri"))
        XCTAssertTrue(usable.contains("Jonnalagadda"))
        XCTAssertTrue(usable.contains("O'Brien"))
        XCTAssertTrue(usable.contains("Jean-Luc"))
        XCTAssertFalse(usable.contains("Rose"), "an English word is not a name to teach")
        XCTAssertFalse(usable.contains("Mark"))
        XCTAssertFalse(usable.contains("the"))
        XCTAssertFalse(usable.contains("J"), "an initial is one letter")
        XCTAssertFalse(usable.contains("8800"))
        XCTAssertFalse(usable.contains("🙂"))
        XCTAssertEqual(usable.filter { $0.lowercased() == "priya" }.count, 1)
        XCTAssertEqual(usable, usable.sorted { $0.lowercased() < $1.lowercased() }, "the pool is sorted so it is the same list in any enumeration order")
    }
}
