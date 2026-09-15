import XCTest
@testable import Chalant

/// The card's behaviour, with nobody's phone involved.
///
/// The rules under test are the three the feature was agreed on: a
/// moment rather than an inbox, nothing sent without a second press,
/// and never a guess about who.
@MainActor
final class MessageReplyTests: XCTestCase {
    /// A courier that records instead of texting.
    private final class Fake {
        var staged: (recipient: String, body: String)?
        var confirmed = 0
        var dropped = 0
        /// What `stage` answers, and whether it took.
        var stageAnswer = "To Sam: “hello”. Say send, or anything else to drop it."
        var stageTakes = true
        /// What `confirm` answers, and whether the message went.
        var confirmAnswer = "Sent."
        var confirmClears = true

        var courier: MessageReply.Courier {
            MessageReply.Courier(
                stage: { [self] recipient, body in
                    staged = stageTakes ? (recipient, body) : nil
                    return stageAnswer
                },
                isStaged: { [self] in staged != nil },
                confirm: { [self] in
                    confirmed += 1
                    if confirmClears { staged = nil }
                    return confirmAnswer
                },
                drop: { [self] in
                    dropped += 1
                    staged = nil
                }
            )
        }
    }

    private let sam = MessageWatch.Sighting(
        sender: "Sam", body: "are you coming", seen: Date()
    )
    private let ravi = MessageWatch.Sighting(
        sender: "Ravi", body: "call me", seen: Date()
    )

    func testAMessageShowsAndWaits() {
        let reply = MessageReply(courier: Fake().courier)
        reply.show(sam, onFade: {})
        XCTAssertTrue(reply.isShowing)
        XCTAssertEqual(reply.stage, .waiting)
        XCTAssertEqual(reply.sighting?.sender, "Sam")
    }

    /// Newest wins: the founder chose a moment, not a stack.
    func testANewerMessageReplacesTheOlderOne() {
        let fake = Fake()
        let reply = MessageReply(courier: fake.courier)
        reply.show(sam, onFade: {})
        reply.show(ravi, onFade: {})
        XCTAssertEqual(reply.sighting?.sender, "Ravi")
        XCTAssertEqual(reply.stage, .waiting)
        // Anything staged for the first one must never survive into
        // the second: that is how a reply reaches the wrong person.
        XCTAssertGreaterThan(fake.dropped, 0)
    }

    func testHeardWordsAreStagedAndReadBackButNotSent() async {
        let fake = Fake()
        let reply = MessageReply(courier: fake.courier)
        reply.show(sam, onFade: {})
        await reply.heard("on my way")

        XCTAssertEqual(reply.stage, .drafted("on my way"))
        XCTAssertEqual(fake.staged?.recipient, "Sam")
        XCTAssertEqual(fake.staged?.body, "on my way")
        XCTAssertEqual(fake.confirmed, 0, "staging must never send")
    }

    func testSilenceStagesNothing() async {
        let fake = Fake()
        let reply = MessageReply(courier: fake.courier)
        reply.show(sam, onFade: {})
        await reply.heard("   ")
        XCTAssertEqual(reply.stage, .waiting)
        XCTAssertNil(fake.staged)
    }

    /// Contacts could not place the sender, or placed several of them.
    /// The card says so in the courier's own words and sends nothing.
    func testAnUnresolvableSenderIsRefusedNotGuessed() async {
        let fake = Fake()
        fake.stageTakes = false
        fake.stageAnswer = "Which one? Sam Ali · Sam Torres. Say text and the fuller name."
        let reply = MessageReply(courier: fake.courier)
        reply.show(sam, onFade: {})
        await reply.heard("on my way")

        XCTAssertEqual(
            reply.stage,
            .refused("Which one? Sam Ali · Sam Torres. Say text and the fuller name.")
        )
        let sent = await reply.send()
        XCTAssertFalse(sent)
        XCTAssertEqual(fake.confirmed, 0)
    }

    func testNothingSendsWithoutADraft() async {
        let fake = Fake()
        let reply = MessageReply(courier: fake.courier)
        reply.show(sam, onFade: {})
        let sent = await reply.send()
        XCTAssertFalse(sent)
        XCTAssertEqual(fake.confirmed, 0)
    }

    func testTheSecondPressSends() async {
        let fake = Fake()
        let reply = MessageReply(courier: fake.courier)
        reply.show(sam, onFade: {})
        await reply.heard("on my way")
        let sent = await reply.send()

        XCTAssertTrue(sent)
        XCTAssertEqual(fake.confirmed, 1)
        XCTAssertEqual(reply.stage, .sent)
    }

    /// Messages held it back, a grant dialog most often. The words
    /// stay staged and the card says why rather than claiming it went.
    func testASendThatDidNotGoIsNotReportedAsSent() async {
        let fake = Fake()
        fake.confirmClears = false
        fake.confirmAnswer = "macOS is asking to let Chalant use Messages. Click Allow, then say send."
        let reply = MessageReply(courier: fake.courier)
        reply.show(sam, onFade: {})
        await reply.heard("on my way")
        let sent = await reply.send()

        XCTAssertFalse(sent)
        XCTAssertEqual(
            reply.stage,
            .refused("macOS is asking to let Chalant use Messages. Click Allow, then say send.")
        )
    }

    func testDismissingClearsTheCardAndTheStagedWords() async {
        let fake = Fake()
        let reply = MessageReply(courier: fake.courier)
        reply.show(sam, onFade: {})
        await reply.heard("on my way")
        reply.dismiss()

        XCTAssertFalse(reply.isShowing)
        XCTAssertNil(reply.sighting)
        XCTAssertEqual(reply.stage, .waiting)
        XCTAssertNil(fake.staged)
    }

    /// Unattended, the card goes on its own. This is the whole
    /// "moment, not an inbox" rule, with the clock shortened.
    func testAnUnattendedCardFadesOnItsOwn() async throws {
        let reply = MessageReply(courier: Fake().courier, life: 0.05)
        var faded = false
        reply.show(sam) { faded = true }
        try await Task.sleep(for: .seconds(0.3))

        XCTAssertFalse(reply.isShowing)
        XCTAssertTrue(faded)
    }

    /// The bug this exists to stop: the card fading while somebody is
    /// mid-sentence, which takes the landing spot away with it and
    /// leaves the words with nowhere to go.
    func testACardBeingTalkedIntoDoesNotFade() async throws {
        let reply = MessageReply(courier: Fake().courier, life: 0.05)
        var faded = false
        reply.show(sam) { faded = true }
        reply.holdOpen()
        try await Task.sleep(for: .seconds(0.3))

        XCTAssertTrue(reply.isShowing)
        XCTAssertFalse(faded)
    }

    /// The card is a moment, so it has a life. Half a minute is long
    /// enough to read and decide without becoming an unread count.
    func testTheCardsLifeIsHalfAMinute() {
        XCTAssertEqual(MessageReply.life, 30)
    }
}

/// When a message may take the island at all.
///
/// Written as plain values against the static rule, the way every
/// other island rule is tested: building a `NotchViewModel` starts a
/// server, a scanner and an EventKit prompt.
@MainActor
final class MessageMayShowTests: XCTestCase {
    func testAnIslandUserGetsTheCard() {
        XCTAssertTrue(
            NotchViewModel.messageMayShow(
                role: .island, micIsLive: false, expanded: false, midInteraction: false
            )
        )
        XCTAssertTrue(
            NotchViewModel.messageMayShow(
                role: .both, micIsLive: false, expanded: false, midInteraction: false
            )
        )
    }

    /// Dictation-only Chalant has no island, so it has nothing to pop.
    func testDictationOnlyNeverGetsACard() {
        XCTAssertFalse(
            NotchViewModel.messageMayShow(
                role: .dictation, micIsLive: false, expanded: false, midInteraction: false
            )
        )
    }

    /// The one that matters most: a text arriving mid-sentence must
    /// not touch the island, or the hold ducks the room forever.
    func testAMessageDuringAHoldIsNotShown() {
        XCTAssertFalse(
            NotchViewModel.messageMayShow(
                role: .island, micIsLive: true, expanded: false, midInteraction: false
            )
        )
    }

    /// The tour owns the same landing spot, and its exit would clear
    /// the card's. A first run is also the worst moment to be texted.
    func testTheWelcomeTourIsNeverInterrupted() {
        XCTAssertFalse(
            NotchViewModel.messageMayShow(
                role: .island, micIsLive: false, expanded: true,
                midInteraction: false, welcomeIsUp: true
            )
        )
    }

    func testAnOpenIslandInUseIsNotHijacked() {
        XCTAssertFalse(
            NotchViewModel.messageMayShow(
                role: .island, micIsLive: false, expanded: true, midInteraction: true
            )
        )
        XCTAssertTrue(
            NotchViewModel.messageMayShow(
                role: .island, micIsLive: false, expanded: true, midInteraction: false
            )
        )
    }
}
