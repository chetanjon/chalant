import XCTest
@testable import Chalant

/// Who a name means, decided without an address book.
///
/// Two callers, two standards. A SPOKEN name takes the first tier with
/// anybody in it, because the person chose the name and hears a read-back
/// before anything goes. A name READ OFF A BANNER was chosen by nobody and
/// the recipient is never read back, so it must mean exactly one contact
/// or it means no one (review, 2026-09-19: the card had been resolving
/// banner titles with the voice path's fuzzy tiers).
final class MessageCourierDecideTests: XCTestCase {
    private func person(_ id: String, _ name: String, handle: String? = "+15550100") -> MessageCourier.Person {
        MessageCourier.Person(id: id, name: name, handle: handle)
    }

    func testSpokenTakesTheFirstTierWithAnyoneInIt() {
        let answer = MessageCourier.decide(
            nick: [person("1", "Sam")], given: [person("2", "Sam Torres")],
            full: [], prefix: [], strict: false
        )
        XCTAssertEqual(answer, .one(name: "Sam", handle: "+15550100"))
    }

    /// The same two people, read off a banner: either could have written.
    func testStrictRefusesWhenTwoContactsCouldBeTheSender() {
        let answer = MessageCourier.decide(
            nick: [person("1", "Sam")], given: [person("2", "Sam Torres")],
            full: [], prefix: [], strict: true
        )
        XCTAssertEqual(answer, .many(["Sam", "Sam Torres"]))
    }

    /// "Sam" is not "Samantha". A prefix is a guess, and spoken aloud the
    /// read-back catches it; on a banner nothing would.
    func testStrictNeverMatchesAPrefix() {
        let prefixOnly = MessageCourier.decide(
            nick: [], given: [], full: [], prefix: [person("3", "Samantha Jones")],
            strict: true
        )
        XCTAssertEqual(prefixOnly, .none)

        let spoken = MessageCourier.decide(
            nick: [], given: [], full: [], prefix: [person("3", "Samantha Jones")],
            strict: false
        )
        XCTAssertEqual(spoken, .one(name: "Samantha Jones", handle: "+15550100"))
    }

    func testStrictAcceptsExactlyOne() {
        let answer = MessageCourier.decide(
            nick: [], given: [], full: [person("4", "Sam Ali")], prefix: [], strict: true
        )
        XCTAssertEqual(answer, .one(name: "Sam Ali", handle: "+15550100"))
    }

    /// One contact matching on two fields is still one contact.
    func testStrictCountsAContactOnceHoweverManyFieldsMatch() {
        let sam = person("5", "Sam")
        let answer = MessageCourier.decide(
            nick: [sam], given: [sam], full: [], prefix: [], strict: true
        )
        XCTAssertEqual(answer, .one(name: "Sam", handle: "+15550100"))
    }

    func testSomeoneWithNoNumberOrAddressCannotBeReached() {
        let answer = MessageCourier.decide(
            nick: [], given: [], full: [person("6", "Sam Ali", handle: nil)],
            prefix: [], strict: true
        )
        XCTAssertEqual(answer, .none)
    }
}
