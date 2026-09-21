import XCTest
@testable import Chalant

/// The card's behaviour, with nobody's phone involved.
///
/// Every test here is one of the founder's rules or one of the failures
/// the 2026-09-19 audit found in the first build: a reply that could be
/// dictated and then never sent, "Sent." shown for a message that never
/// left, a draft thrown away by the next text, spoken-command wording on
/// a card that cannot hear.
@MainActor
final class MessageReplyTests: XCTestCase {
    /// A courier that records instead of texting.
    private final class Fake {
        /// An ordinary SMS thread, which is what most of them are.
        static let thread = MessageCourier.Conversation(
            id: "any;-;+15550100", service: "SMS",
            name: "Sam Ali", handle: "+15550100", isGroup: false)

        var aim: MessageReply.Recipient = .known(name: "Sam Ali", thread: Fake.thread)
        var outcome: MessageCourier.SendOutcome = .sent(name: "Sam Ali")
        var sends: [(thread: MessageCourier.Conversation, name: String, body: String)] = []

        var courier: MessageReply.Courier {
            MessageReply.Courier(
                aim: { [self] _ in aim },
                send: { [self] thread, name, body in
                    sends.append((thread, name, body))
                    return outcome
                }
            )
        }
    }

    private let sam = MessageWatch.Sighting(
        sender: "Sam", body: "are you coming", seen: Date(timeIntervalSince1970: 1)
    )
    private let ravi = MessageWatch.Sighting(
        sender: "Ravi", body: "call me", seen: Date(timeIntervalSince1970: 2)
    )

    /// Show a card and let Contacts answer.
    private func shown(
        _ fake: Fake, _ sighting: MessageWatch.Sighting? = nil,
        life: TimeInterval = 30, patience: TimeInterval = 8
    ) async -> MessageReply {
        let reply = MessageReply(courier: fake.courier, life: life, hearingPatience: patience)
        reply.show(sighting ?? sam, onFade: {})
        await settle()
        return reply
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// Wait for something to become true, rather than sleeping a fixed
    /// time and hoping. A machine under load (a release runs the suite
    /// beside a build) stretched these tests past a fixed margin and
    /// failed one, which is exactly how a timing test ruins a release.
    @discardableResult
    private func eventually(
        _ what: String, within seconds: TimeInterval = 5,
        _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("never became true: \(what)", file: file, line: line)
        return false
    }

    /// And the opposite: hold something steady for long enough that a
    /// fade which was going to fire would have fired. Kept generous, and
    /// measured against the card's own clock rather than the wall.
    private func stays(
        _ what: String, for seconds: TimeInterval = 0.6, _ condition: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard condition() else {
                return XCTFail("stopped being true: \(what)", file: file, line: line)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Who, settled before anybody speaks

    func testTheRecipientIsSettledOnArrival() async {
        let reply = await shown(Fake())
        XCTAssertEqual(reply.recipient, .known(name: "Sam Ali", thread: Fake.thread))
    }

    /// Two Sams: the card refuses up front, in words that mention a
    /// button and never a spoken command.
    func testAnAmbiguousSenderIsRefusedBeforeAnyoneTalks() async {
        let fake = Fake()
        fake.aim = MessageReply.Courier.several("Sam")
        let reply = await shown(fake)

        guard case .cannotReply(let why) = reply.recipient else {
            return XCTFail("two Sams must never be resolved")
        }
        XCTAssertTrue(why.contains("won't guess"))
        XCTAssertFalse(reply.canSend)
        reply.draft = "on my way"
        XCTAssertFalse(reply.canSend, "words do not make an unknown recipient known")
        let sent = await reply.send()
        XCTAssertFalse(sent)
        XCTAssertTrue(fake.sends.isEmpty)
    }

    func testAStrangerIsRefusedNotGuessed() async {
        let fake = Fake()
        fake.aim = MessageReply.recipient(for: .none, sender: "Sam")
        let reply = await shown(fake)
        guard case .cannotReply = reply.recipient else { return XCTFail() }
        reply.talkPressed()
        XCTAssertEqual(reply.phase, .idle, "the mic does nothing when no reply can go")
    }

    /// The first build put the courier's voice-path strings on the card
    /// verbatim. A card has buttons; nobody can "say" anything to it.
    func testNoCardCopyTellsAnyoneToSpeakACommand() {
        let resolutions: [MessageCourier.Resolution] = [
            .none, .denied, .unasked, .failed, .many(["A", "B"]),
        ]
        let outcomes: [MessageCourier.SendOutcome] = [
            .nothingStaged, .stale, .wakingUp, .askingPermission,
            .blocked, .notSignedIn, .failed("boom"),
        ]
        var lines: [String] = outcomes.map(MessageReply.explain)
        for resolution in resolutions {
            if case .cannotReply(let why) = MessageReply.recipient(for: resolution, sender: "Sam") {
                lines.append(why)
            }
        }
        if case .cannotReply(let why) = MessageReply.Courier.several("Sam") { lines.append(why) }
        for line in lines {
            XCTAssertFalse(line.lowercased().contains("say "), line)
            XCTAssertFalse(line.contains("\u{2014}"), "no em dashes: \(line)")
            XCTAssertFalse(line.isEmpty)
        }
    }

    // MARK: One field, filled by talking or typing

    func testHeardWordsLandInTheFieldAndNothingIsSent() async {
        let fake = Fake()
        let reply = await shown(fake)
        reply.talkPressed()
        XCTAssertEqual(reply.phase, .listening)
        reply.talkReleased(held: true)
        XCTAssertEqual(reply.phase, .hearing)
        reply.heard("on my way", for: sam)

        XCTAssertEqual(reply.draft, "on my way")
        XCTAssertEqual(reply.phase, .idle)
        XCTAssertTrue(fake.sends.isEmpty, "hearing must never send")
    }

    /// Typed a few words, then talked: the first part is not lost.
    func testTalkingAddsToWhatWasTyped() async {
        let reply = await shown(Fake())
        reply.draft = "yes,"
        reply.talkPressed()
        reply.talkReleased(held: true)
        reply.heard("see you at six", for: sam)
        XCTAssertEqual(reply.draft, "yes, see you at six")
    }

    /// A click is not a hold. It starts nothing and says why, instead
    /// of silently doing nothing the way the first build did.
    func testAClickOnTheMicExplainsItself() async {
        let reply = await shown(Fake())
        reply.talkPressed()
        reply.talkReleased(held: false)
        XCTAssertEqual(reply.phase, .idle)
        XCTAssertNotNil(reply.hint)
    }

    /// Silence produces no words at all. The card must not wait for
    /// them for ever.
    func testHearingGivesUpRatherThanHangingForEver() async {
        let reply = await shown(Fake(), patience: 0.05)
        reply.talkPressed()
        reply.talkReleased(held: true)
        await eventually("the card stops waiting for words") { reply.phase == .idle }
        XCTAssertNotNil(reply.hint)
    }

    /// The reply was spoken to Sam. Ravi's message is on the card when
    /// the words come back. They are dropped: a sentence meant for one
    /// person never lands under another's name.
    func testWordsSpokenToOnePersonNeverLandOnAnother() async {
        let fake = Fake()
        let reply = await shown(fake)
        reply.talkPressed()
        reply.talkReleased(held: true)
        reply.show(ravi, onFade: {})
        await settle()
        reply.heard("love you too", for: sam)

        XCTAssertEqual(reply.sighting?.sender, "Ravi")
        XCTAssertEqual(reply.draft, "")
    }

    // MARK: Sending, and telling the truth about it

    func testSendGoesToTheResolvedPersonWithExactlyTheFieldsWords() async {
        let fake = Fake()
        let reply = await shown(fake)
        reply.draft = "  on my way  "
        let sent = await reply.send()

        XCTAssertTrue(sent)
        XCTAssertEqual(fake.sends.count, 1)
        XCTAssertEqual(fake.sends.first?.name, "Sam Ali")
        XCTAssertEqual(fake.sends.first?.thread, Fake.thread)
        XCTAssertEqual(fake.sends.first?.body, "on my way")
        XCTAssertEqual(reply.phase, .sent(name: "Sam Ali"))
    }

    func testAnEmptyFieldSendsNothing() async {
        let fake = Fake()
        let reply = await shown(fake)
        reply.draft = "   "
        XCTAssertFalse(reply.canSend)
        let sent = await reply.send()
        XCTAssertFalse(sent)
        XCTAssertTrue(fake.sends.isEmpty)
    }

    /// The bug that shipped to the branch: a stale message cleared the
    /// courier's stage exactly the way a delivered one does, and the
    /// card called that "Sent.". Nothing but `.sent` is sent.
    func testOnlyARealSendIsEverCalledSent() async {
        let failures: [MessageCourier.SendOutcome] = [
            .nothingStaged, .stale, .wakingUp, .askingPermission,
            .blocked, .notSignedIn, .failed("boom"),
        ]
        for outcome in failures {
            let fake = Fake()
            fake.outcome = outcome
            let reply = await shown(fake)
            reply.draft = "on my way"
            let sent = await reply.send()

            XCTAssertFalse(sent, "\(outcome)")
            guard case .failed = reply.phase else {
                return XCTFail("\(outcome) was reported as \(reply.phase)")
            }
        }
    }

    /// The first send ever almost always meets a macOS dialog. Nobody
    /// should have to say the sentence again because of it.
    func testAFailedSendKeepsTheWordsAndCanBeRetried() async {
        let fake = Fake()
        fake.outcome = .askingPermission
        let reply = await shown(fake)
        reply.draft = "on my way"
        _ = await reply.send()

        XCTAssertEqual(reply.draft, "on my way")
        XCTAssertTrue(reply.canSend)

        fake.outcome = .sent(name: "Sam Ali")
        let sent = await reply.send()
        XCTAssertTrue(sent)
        XCTAssertEqual(fake.sends.count, 2)
    }

    // MARK: A moment, not an inbox, and never mid-sentence

    func testAnUntouchedCardFadesOnItsOwn() async {
        let reply = MessageReply(courier: Fake().courier, life: 0.05)
        var faded = false
        reply.show(sam) { faded = true }
        await eventually("an unattended card goes") { !reply.isShowing }
        XCTAssertTrue(faded)
    }

    /// Reading it with the pointer on it is not ignoring it.
    func testACardUnderThePointerDoesNotFade() async {
        let reply = MessageReply(courier: Fake().courier, life: 0.05)
        reply.show(sam, onFade: {})
        reply.hover(true)
        await stays("a card under the pointer") { reply.isShowing }

        // And the clock starts again once the pointer leaves.
        reply.hover(false)
        await eventually("it goes once the pointer leaves") { !reply.isShowing }
    }

    /// Words in the field are a reply in progress. It stays.
    func testACardWithWordsInItNeverFades() async {
        let reply = MessageReply(courier: Fake().courier, life: 0.05)
        reply.show(sam, onFade: {})
        reply.touch()
        reply.draft = "on my"
        await stays("a card with words in it") { reply.isShowing }
    }

    /// One stray click must not pin a card open for ever: a touched card
    /// that then sits empty and idle for a whole life is unattended
    /// again. Left up, it blocked every later message as "mid-reply".
    func testATouchedButAbandonedCardStillGoes() async {
        let reply = MessageReply(courier: Fake().courier, life: 0.05)
        reply.show(sam, onFade: {})
        reply.touch()
        XCTAssertTrue(reply.isMidReply, "clicked into: the next keystroke is this conversation's")
        await eventually("a touched but empty card is unattended again") { !reply.isShowing }
    }

    /// Messages closed: looking is not worth launching it for, but the
    /// reply still works. Contacts says who, and the thread is found at
    /// send time, by which point sending has launched Messages.
    func testWithMessagesClosedTheThreadIsFoundAtSendTime() async {
        let fake = Fake()
        let later = MessageCourier.deferred(name: "Sam Ali", handle: "+15550100")
        fake.aim = .known(name: "Sam Ali", thread: later)
        let reply = await shown(fake)

        reply.draft = "on my way"
        XCTAssertTrue(reply.canSend, "a closed Messages must not disable the reply")
        let sent = await reply.send()
        XCTAssertTrue(sent)
        XCTAssertEqual(fake.sends.first?.thread.id, "", "no thread known yet")
        XCTAssertEqual(fake.sends.first?.thread.handle, "+15550100", "but the address is")
    }

    /// An empty id means "not looked up yet", never "send it nowhere".
    func testADeferredThreadCarriesNoIdAndNoService() {
        let later = MessageCourier.deferred(name: "Sam", handle: "+15550100")
        XCTAssertTrue(later.id.isEmpty)
        XCTAssertTrue(later.service.isEmpty)
        XCTAssertFalse(later.isGroup)
    }

    /// A shape nobody has measured, a group thread most likely. Every
    /// one-to-one message seen so far carried exactly two lines.
    func testAnUnmeasuredBannerShapeIsNeverRepliedTo() async {
        let fake = Fake()
        var group = MessageWatch.Sighting(sender: "Sam", body: "Ravi: dinner?", seen: Date())
        group.lineCount = 3
        let reply = await shown(fake, group)

        guard case .cannotReply = reply.recipient else {
            return XCTFail("a three line banner must not resolve to one person")
        }
        reply.draft = "yes"
        XCTAssertFalse(reply.canSend)
    }

    /// The controller refused the hold. The card says so instead of
    /// "Got it" over a microphone that was never open.
    func testARefusedHoldSaysSoInsteadOfPretending() async {
        let reply = await shown(Fake())
        reply.talkPressed()
        reply.talkRefused()
        XCTAssertEqual(reply.phase, .idle)
        XCTAssertEqual(reply.hint, "Dictation isn't ready yet. Type your reply for now.")
    }

    /// Messages took a moment. By the time it answered, Ravi's message
    /// had taken the card. "Sent to Sam" must not appear under Ravi.
    func testASendResultNeverLandsOnADifferentCard() async {
        let fake = Fake()
        let swap = SwapOnSend(aim: fake.courier.aim, replacement: ravi)
        let reply = MessageReply(courier: swap.courier)
        swap.subject = reply
        reply.show(sam, onFade: {})
        await settle()
        reply.draft = "on my way"
        _ = await reply.send()

        XCTAssertEqual(reply.sighting?.sender, "Ravi")
        XCTAssertEqual(reply.phase, .idle, "Ravi's card must not read Sent to Sam")
        XCTAssertEqual(reply.draft, "", "and Sam's words must not sit under Ravi's name")
    }

    /// A courier whose send replaces the card mid-flight, the way a
    /// second text arriving during a slow send does.
    private final class SwapOnSend {
        let aim: (String) async -> MessageReply.Recipient
        let replacement: MessageWatch.Sighting
        weak var subject: MessageReply?
        init(aim: @escaping (String) async -> MessageReply.Recipient,
             replacement: MessageWatch.Sighting) {
            self.aim = aim
            self.replacement = replacement
        }
        @MainActor var courier: MessageReply.Courier {
            MessageReply.Courier(aim: aim, send: { [self] _, _, _ in
                await MainActor.run { subject?.show(replacement, onFade: {}) }
                return .sent(name: "Sam Ali")
            })
        }
    }

    /// What decides whether a newer message may take the card.
    func testMidReplyIsAnythingWithWordsOrAMicInIt() async {
        let reply = await shown(Fake())
        XCTAssertFalse(reply.isMidReply, "an unanswered card can be replaced")

        reply.draft = "on my"
        XCTAssertTrue(reply.isMidReply, "typed words are a reply in progress")

        reply.draft = ""
        reply.talkPressed()
        XCTAssertTrue(reply.isMidReply, "so is a held mic")
        reply.talkReleased(held: true)
        XCTAssertTrue(reply.isMidReply, "and words on their way back")
    }

    func testDismissingClearsEverything() async {
        let reply = await shown(Fake())
        reply.draft = "on my way"
        reply.dismiss()

        XCTAssertFalse(reply.isShowing)
        XCTAssertEqual(reply.draft, "")
        XCTAssertEqual(reply.phase, .idle)
        XCTAssertFalse(reply.engaged)
    }

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

    /// Somebody is answering the last message. A newer one must not
    /// take the card: their words would be thrown away, or left under
    /// the wrong name.
    func testANewMessageNeverReplacesAReplyInProgress() {
        XCTAssertEqual(
            NotchViewModel.messageBlockReason(
                role: .island, micIsLive: false, expanded: true,
                midInteraction: true, cardMidReply: true
            ), "mid-reply"
        )
    }

    /// The first build counted its own unanswered card as "the island
    /// is busy", so the second text of a burst never showed and newest
    /// wins was dead code.
    func testAnUnansweredCardIsReplacedByANewerMessage() {
        XCTAssertNil(
            NotchViewModel.messageBlockReason(
                role: .island, micIsLive: false, expanded: true,
                midInteraction: true, showingIdleCard: true
            )
        )
    }

    /// Every refusal names itself, so a log can answer "it saw my
    /// message, why did nothing appear".
    func testEveryRefusalSaysWhich() {
        XCTAssertEqual(
            NotchViewModel.messageBlockReason(
                role: .dictation, micIsLive: false, expanded: false, midInteraction: false
            ), "dictation-only"
        )
        XCTAssertEqual(
            NotchViewModel.messageBlockReason(
                role: .island, micIsLive: true, expanded: false, midInteraction: false
            ), "mid-hold"
        )
        XCTAssertEqual(
            NotchViewModel.messageBlockReason(
                role: .island, micIsLive: false, expanded: true,
                midInteraction: false, welcomeIsUp: true
            ), "welcome-tour"
        )
        XCTAssertEqual(
            NotchViewModel.messageBlockReason(
                role: .island, micIsLive: false, expanded: true, midInteraction: true
            ), "island-in-use"
        )
        XCTAssertNil(
            NotchViewModel.messageBlockReason(
                role: .both, micIsLive: false, expanded: false, midInteraction: false
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
