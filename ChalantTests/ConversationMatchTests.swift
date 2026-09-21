import XCTest
@testable import Chalant

/// Which conversation a reply belongs in.
///
/// The card used to aim at a phone number out of Contacts and push every
/// reply through iMessage. Measured on the founder's Mac, 2026-09-20:
///
/// | threads | service |
/// |---|---|
/// | 84 | SMS |
/// | 44 | iMessage |
/// | 7 | RCS |
///
/// **Two thirds of their conversations are not iMessage.** Forcing the
/// iMessage account asks Messages to send through an account the other
/// person may not have, AppleScript reports no error either way, and the
/// card would say "Sent" over a message that never arrived. So a reply is
/// aimed at the THREAD the message came from, which knows its own service.
///
/// Every handle in that measurement mapped to exactly one thread, so the
/// matching below is unambiguous in practice; it still refuses rather than
/// guesses when it is not.
final class ConversationMatchTests: XCTestCase {
    private func thread(
        _ name: String, _ handle: String, service: String = "SMS", group: Bool = false
    ) -> MessageCourier.Conversation {
        MessageCourier.Conversation(
            id: group ? "any;+;\(handle)" : "any;-;\(handle)",
            service: service, name: name, handle: handle, isGroup: group)
    }

    /// The banner says "Ashwitha" and so does the participant list, which
    /// is how the thread is found without asking Contacts anything.
    func testTheBannerNameFindsTheThread() {
        let all = [thread("Ashwitha", "+14843648774", service: "iMessage"),
                   thread("Instinct", "+16509247968", service: "iMessage")]
        guard case .one(let found) = MessageCourier.conversation(named: "Ashwitha", in: all) else {
            return XCTFail("the name Messages shows is the name on the banner")
        }
        XCTAssertEqual(found.handle, "+14843648774")
        XCTAssertEqual(found.service, "iMessage")
    }

    /// The thing the whole change exists for: an SMS thread stays SMS.
    func testAnSMSThreadIsAnsweredAsSMS() {
        let all = [thread("Mum", "+16023997172", service: "SMS")]
        guard case .one(let found) = MessageCourier.conversation(named: "Mum", in: all) else {
            return XCTFail()
        }
        XCTAssertEqual(found.service, "SMS")
        XCTAssertEqual(found.id, "any;-;+16023997172")
    }

    /// Nobody has named this sender, so the banner shows their number,
    /// formatted. The thread stores it unformatted.
    func testANumberMatchesHoweverItIsWritten() {
        let all = [thread("+1 (520) 337-1998", "+15203371998")]
        guard case .one = MessageCourier.conversation(named: "+1 (520) 337-1998", in: all) else {
            return XCTFail("a formatted number must find its own thread")
        }
        guard case .one = MessageCourier.conversation(named: "5203371998", in: all) else {
            return XCTFail("and so must a bare one")
        }
    }

    func testAddressesAreComparedByTheirDigits() {
        XCTAssertEqual(
            MessageCourier.addressKey("+1 (555) 010-0142"),
            MessageCourier.addressKey("+15550100142"))
        XCTAssertEqual(
            MessageCourier.addressKey("Topgolf@RBM.GOOG"),
            MessageCourier.addressKey("topgolf@rbm.goog"))
        XCTAssertNotEqual(
            MessageCourier.addressKey("+15550100142"),
            MessageCourier.addressKey("+15550100143"))
    }

    /// A short code: too few digits to be a phone number, so it is
    /// compared whole rather than by its last ten.
    func testAShortCodeIsItsOwnAddress() {
        let all = [thread("53849", "53849"), thread("86753", "86753")]
        guard case .one(let found) = MessageCourier.conversation(named: "53849", in: all) else {
            return XCTFail()
        }
        XCTAssertEqual(found.handle, "53849")
    }

    /// A group message's banner names the person who wrote, not the room.
    /// Answering them alone would be a private reply to something said in
    /// front of other people.
    func testAGroupIsNeverAMatch() {
        let all = [thread("Family", "6d7c1aeb", group: true)]
        XCTAssertEqual(MessageCourier.conversation(named: "Family", in: all), .none)
    }

    func testTwoThreadsWithOneNameAreRefused() {
        let all = [thread("Sam", "+15550100142"), thread("Sam", "+15550100143")]
        XCTAssertEqual(MessageCourier.conversation(named: "Sam", in: all), .several)
    }

    func testAStrangerHasNoThread() {
        let all = [thread("Ashwitha", "+14843648774")]
        XCTAssertEqual(MessageCourier.conversation(named: "Priya", in: all), .none)
    }

    /// The Contacts fallback: Messages showed a name its participant list
    /// does not use, so Contacts gave an address to look the thread up by.
    func testTheFallbackFindsAThreadByAddress() {
        let all = [thread("Ashwitha", "+14843648774", service: "iMessage")]
        guard case .one(let found) =
                MessageCourier.conversation(handle: "+1 (484) 364-8774", in: all) else {
            return XCTFail("Contacts' formatting must not hide the thread")
        }
        XCTAssertEqual(found.service, "iMessage")
    }

    /// They are in Contacts, but they wrote from somewhere else. Replying
    /// to the number on their card would go somewhere they are not
    /// reading, so nothing is aimed anywhere.
    func testAContactWithNoThreadHereIsRefused() {
        let all = [thread("Ashwitha", "+14843648774")]
        XCTAssertEqual(
            MessageCourier.conversation(handle: "+15559999999", in: all), .none)
    }

    /// The id says which kind of thread it is, and the founder's Mac
    /// writes both forms.
    func testAGroupIsRecognisedByItsId() {
        let group = MessageCourier.Conversation(
            id: "any;+;180431062c2442a29b1d656a8c32f54d", service: "iMessage",
            name: "", handle: "", isGroup: true)
        let oneToOne = thread("Ashwitha", "+14843648774")
        XCTAssertTrue(group.id.contains(";+;"))
        XCTAssertTrue(oneToOne.id.contains(";-;"))
    }
}
