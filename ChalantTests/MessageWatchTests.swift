import XCTest
@testable import Chalant

/// Reading an incoming message off its notification banner.
///
/// The screen is not involved in any of this: ``MessageWatch.Banner``
/// is the flattened tree, so every rule can be pinned without waiting
/// for somebody to text the machine.
///
/// The shape below is measured, not guessed. On macOS 26, 2026-09-15,
/// a live banner read back as: window described `Notification Center`,
/// one element described `Script Editor, Alpha Sender, First body`,
/// and two static texts, the title then the body. The identifiers are
/// generic layout names (`widgets-overlay-view`, `title`, `body`) plus
/// the notification's own UUID, and **the posting app is not among
/// them**, which is why the description is what gets tested.
@MainActor
final class MessageWatchTests: XCTestCase {
    /// A banner as the tree hands it over: the app names itself in a
    /// description of the form `App, title, body`.
    private func banner(
        texts: [String], app: String? = "Messages"
    ) -> MessageWatch.Banner {
        var descriptions = ["Notification Center"]
        if let app {
            descriptions.append(([app] + texts).joined(separator: ", "))
        }
        return MessageWatch.Banner(
            texts: texts,
            identifiers: ["widgets-overlay-view", "title", "body"],
            descriptions: descriptions
        )
    }

    func testSenderIsTheFirstLineAndTheMessageIsTheRest() {
        let seen = MessageWatch.sighting(
            from: banner(texts: ["Mum", "are you coming for dinner"])
        )
        XCTAssertEqual(seen?.sender, "Mum")
        XCTAssertEqual(seen?.body, "are you coming for dinner")
    }

    /// A banner can break a long message across several texts. All of
    /// it is the message; only the first line is who.
    func testRemainingLinesJoinIntoOneMessage() {
        let seen = MessageWatch.sighting(
            from: banner(texts: ["Ravi", "running late", "start without me"])
        )
        XCTAssertEqual(seen?.sender, "Ravi")
        XCTAssertEqual(seen?.body, "running late start without me")
    }

    /// Previews hidden: the banner says somebody wrote, never what.
    /// There is nothing to reply to, so there is no card.
    func testABannerWithNoMessageIsNotASighting() {
        XCTAssertNil(MessageWatch.sighting(from: banner(texts: ["Mum"])))
        XCTAssertNil(MessageWatch.sighting(from: banner(texts: [])))
    }

    func testBlankLinesDoNotCountAsAMessage() {
        XCTAssertNil(
            MessageWatch.sighting(from: banner(texts: ["Mum", "   ", "\n"]))
        )
    }

    /// The whole point of the app check: a calendar alert and a build
    /// finishing must never open a reply box aimed at a person.
    func testOnlyMessagesBannersCount() {
        let calendar = banner(texts: ["Standup", "in 10 minutes"], app: "Calendar")
        XCTAssertFalse(MessageWatch.isMessages(calendar))
        XCTAssertNil(MessageWatch.sighting(from: calendar))
    }

    func testABannerThatNamesNoAppIsNotTrusted() {
        let anonymous = banner(texts: ["Someone", "hello"], app: nil)
        XCTAssertFalse(MessageWatch.isMessages(anonymous))
        XCTAssertNil(MessageWatch.sighting(from: anonymous))
    }

    /// The trap a plain substring search would fall into: somebody
    /// writing the word Messages in a calendar invite.
    func testTheAppNameIsMatchedAsAFieldNotASubstring() {
        let sneaky = banner(
            texts: ["Standup", "Messages, everyone"], app: "Calendar"
        )
        XCTAssertFalse(MessageWatch.isMessages(sneaky))
    }

    /// A German Mac calls it Nachrichten, and the banner says so. The
    /// name is asked of the system rather than hard-coded, so this has
    /// to hold for whatever name comes back.
    func testTheAppNameIsWhateverThisMacCallsIt() {
        let german = MessageWatch.Banner(
            texts: ["Mum", "hallo"],
            identifiers: [],
            descriptions: ["Nachrichten, Mum, hallo"]
        )
        XCTAssertTrue(MessageWatch.isMessages(german, appName: "Nachrichten"))
        XCTAssertFalse(MessageWatch.isMessages(german, appName: "Messages"))
    }

    /// Whatever this Mac is set to, the name has to be a real one:
    /// an empty marker would match every banner on the machine.
    func testTheResolvedAppNameIsNeverEmpty() {
        XCTAssertFalse(MessageWatch.messagesAppName.isEmpty)
        XCTAssertFalse(MessageWatch.messagesAppName.hasSuffix(".app"))
    }

    func testTheSightingCarriesWhenItWasSeen() {
        let when = Date(timeIntervalSince1970: 1_000)
        let seen = MessageWatch.sighting(
            from: banner(texts: ["Sam", "hello"]), now: when
        )
        XCTAssertEqual(seen?.seen, when)
    }
}
