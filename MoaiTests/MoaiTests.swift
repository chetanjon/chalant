import EventKit
import XCTest
@testable import Moai

/// Locks the behaviors that were each paid for with a live debugging
/// session. Every case here is a regression that actually happened or
/// a rule a round was built on; none are decoration.
@MainActor
final class MoaiTests: XCTestCase {

    // MARK: Version comparison (the update nudge)

    func testIsNewerComparesNumerically() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1", than: "1.0.99"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.81", than: "1.0.81"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0"))
    }

    // MARK: Sanitizing (dictation's punctuation vs exact-match verbs)

    func testSanitizedStripsTrailingPunctuation() {
        XCTAssertEqual(ActionEngine.sanitized("What's next."), "What's next")
        XCTAssertEqual(ActionEngine.sanitized("stop focus!?"), "stop focus")
    }

    func testSanitizedKeepsMeridiemDots() {
        // "6 p.m." must survive as a time, not lose its meaning to
        // the trailing-punctuation strip (R57-era fix).
        XCTAssertEqual(
            ActionEngine.sanitized("remind me at 6 p.m."),
            "remind me at 6 pm"
        )
    }

    func testSanitizedCollapsesDoubleSpaces() {
        XCTAssertEqual(ActionEngine.sanitized("note:  two   spaces"), "note: two spaces")
    }

    // MARK: Pleasantries (manners never defeat the verb underneath)

    func testPleasantriesPeelFromBothEnds() {
        XCTAssertEqual(
            ActionEngine.strippedOfPleasantries("hey can you remind me to walk please"),
            "remind me to walk"
        )
        XCTAssertEqual(
            ActionEngine.strippedOfPleasantries("okay so note: an idea thanks"),
            "note: an idea"
        )
    }

    // MARK: Literal handles (texting recipients that skip Contacts)

    func testLiteralHandleNormalizesPhones() {
        // Formatting never travels (R106): plus keeps its plus, the
        // rest becomes digits.
        XCTAssertEqual(
            MessageCourier.literalHandle("+1 (630) 545-8630"),
            "+16305458630"
        )
        XCTAssertEqual(MessageCourier.literalHandle("630-545-8630"), "6305458630")
    }

    func testLiteralHandleRejectsShortNumbersAndWords() {
        XCTAssertNil(MessageCourier.literalHandle("123"))
        XCTAssertNil(MessageCourier.literalHandle("mom"))
    }

    func testLiteralHandleAcceptsEmails() {
        XCTAssertEqual(
            MessageCourier.literalHandle("a@b.com"),
            "a@b.com"
        )
    }

    // MARK: Meeting links (what "join" recognizes)

    func testMeetingURLFoundInLocationAndSubdomains() {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.location = "Room 4 · https://us02web.zoom.us/j/123456789"
        XCTAssertEqual(
            DayEvent.meetingURL(in: event)?.host,
            "us02web.zoom.us"
        )
    }

    func testMeetingURLIgnoresOrdinaryLinks() {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.notes = "Agenda: https://example.com/doc and nothing else"
        XCTAssertNil(DayEvent.meetingURL(in: event))
    }

    // MARK: Paraphrase rescue (the small model's wrappings)

    func testRescueFindsCommandInsideParaphrase() {
        XCTAssertEqual(
            AIService.rescueParaphrase("change screen mode to light"),
            "light mode"
        )
        XCTAssertEqual(
            AIService.rescueParaphrase("turn on the dark mode for me"),
            "dark mode"
        )
    }

    func testRescueNeverInventsJoinFromChatter() {
        // R113: a reply merely containing "join" must not become the
        // join action; it opened meetings unasked.
        XCTAssertEqual(
            AIService.rescueParaphrase("you can join tables with a key"),
            "you can join tables with a key"
        )
    }

    func testRescueLeavesPrefixedCommandsVerbatim() {
        XCTAssertEqual(AIService.rescueParaphrase("join"), "join")
        XCTAssertEqual(
            AIService.rescueParaphrase("read my screen"),
            "read my screen"
        )
        XCTAssertEqual(
            AIService.rescueParaphrase("note: buy rice"),
            "note: buy rice"
        )
    }

    // MARK: Stopwatch grammar (stop holds, reset lets go)

    func testStopwatchHoldsOnPauseAndClearsOnReset() {
        let watch = StopwatchController()
        XCTAssertFalse(watch.isActive)

        watch.start()
        XCTAssertTrue(watch.isActive)
        XCTAssertTrue(watch.isRunning)

        watch.pause()
        XCTAssertTrue(watch.isActive, "a held reading stays on screen")
        XCTAssertFalse(watch.isRunning)

        watch.start()
        XCTAssertTrue(watch.isRunning, "start rolls on from a hold")

        watch.reset()
        XCTAssertFalse(watch.isActive)
        XCTAssertEqual(watch.elapsed, 0)
        watch.reset()
    }

    func testStopwatchDisplayFormats() {
        let watch = StopwatchController()
        XCTAssertEqual(watch.display, "0:00")
    }

    // MARK: Countdown display

    func testCountdownDisplayFormats() {
        let timer = CountdownController()
        timer.remaining = 125
        XCTAssertEqual(timer.display, "2:05")
        timer.remaining = 65 * 60 + 3
        XCTAssertEqual(timer.display, "65:03")
    }

    // MARK: Send consent (the outward-message gate, R105's wound)

    func testSendVerdictFiresOnAnyUnnegatedSend() {
        XCTAssertEqual(ActionEngine.sendVerdict("send"), .fire)
        XCTAssertEqual(ActionEngine.sendVerdict("yes, send it"), .fire)
        XCTAssertEqual(ActionEngine.sendVerdict("okay send that."), .fire)
    }

    func testSendVerdictNeverFiresOnBareYesOrNegation() {
        XCTAssertEqual(ActionEngine.sendVerdict("yes"), .dropSilently)
        XCTAssertEqual(ActionEngine.sendVerdict("don't send"), .refuseAloud)
        XCTAssertEqual(ActionEngine.sendVerdict("do not send"), .refuseAloud)
        XCTAssertEqual(ActionEngine.sendVerdict("no, send it anyway"), .dropSilently)
    }

    func testSendVerdictRefusesAloudAndPassesQuietly() {
        XCTAssertEqual(ActionEngine.sendVerdict("cancel"), .refuseAloud)
        XCTAssertEqual(ActionEngine.sendVerdict("never mind"), .refuseAloud)
        XCTAssertEqual(ActionEngine.sendVerdict("what's next"), .dropSilently)
    }

    // MARK: Courier staging (the split rules that broke twice)

    private func stubResolver(
        knowing book: [String: (String, String)]
    ) -> (String) async -> MessageCourier.Resolution {
        { name in
            if let hit = book[name.lowercased()] {
                return .one(name: hit.0, handle: hit.1)
            }
            return MessageCourier.Resolution.none
        }
    }

    func testStagingCommaInBodySurvivesViaTokenWalk() async {
        // R105: "text mom running late, see you soon" once died on
        // its own comma; the front-split fails and the walk wins.
        let courier = MessageCourier()
        let resolve = stubResolver(knowing: ["mom": ("Mom", "+15551234567")])
        _ = await courier.stage(
            freeform: "mom I'm running late, see you soon", using: resolve
        )
        XCTAssertEqual(courier.pending?.name, "Mom")
        XCTAssertEqual(courier.pending?.body, "I'm running late, see you soon")
    }

    func testStagingExplicitColonSplits() async {
        let courier = MessageCourier()
        let resolve = stubResolver(knowing: ["john smith": ("John Smith", "j@x.com")])
        _ = await courier.stage(
            freeform: "john smith: running late", using: resolve
        )
        XCTAssertEqual(courier.pending?.name, "John Smith")
        XCTAssertEqual(courier.pending?.body, "running late")
    }

    func testStagingLongestNameWinsOverShort() async {
        // "mary jane meet me" must reach Mary Jane, not Mary with a
        // strange message.
        let courier = MessageCourier()
        let resolve = stubResolver(knowing: [
            "mary": ("Mary", "1@x.com"),
            "mary jane": ("Mary Jane", "2@x.com"),
        ])
        _ = await courier.stage(freeform: "mary jane meet me", using: resolve)
        XCTAssertEqual(courier.pending?.name, "Mary Jane")
        XCTAssertEqual(courier.pending?.body, "meet me")
    }

    func testStagingWholeUtteranceNameAsksForWords() async {
        // R105: "text mary jane" once texted the surname to Mary.
        let courier = MessageCourier()
        let resolve = stubResolver(knowing: ["mary jane": ("Mary Jane", "2@x.com")])
        let answer = await courier.stage(freeform: "mary jane", using: resolve)
        XCTAssertNil(courier.pending)
        XCTAssertTrue(answer.hasPrefix("Text Mary Jane what?"), answer)
    }

    func testStagingMultiTokenPhoneRun() async {
        // R106: a pasted "+1 (630) 545 8630" arrives as several
        // tokens and must travel as one normalized handle.
        let courier = MessageCourier()
        let resolve = stubResolver(knowing: [:])
        _ = await courier.stage(
            freeform: "+1 (630) 545 8630 formatting test", using: resolve
        )
        XCTAssertEqual(courier.pending?.handle, "+16305458630")
        XCTAssertEqual(courier.pending?.body, "formatting test")
    }

    func testStagingUnknownNameAnswersHonestly() async {
        let courier = MessageCourier()
        let resolve = stubResolver(knowing: [:])
        let answer = await courier.stage(freeform: "zork hello there", using: resolve)
        XCTAssertNil(courier.pending)
        XCTAssertTrue(answer.hasPrefix("No one called"), answer)
    }

    // MARK: Session stops carry their articles (R123)

    func testSessionStopsAcceptArticles() {
        // "cancel the timer" once fell to the calendar branch and
        // answered "No event today matching 'the timer'" over a
        // live timer (dogfood-caught).
        XCTAssertTrue(ActionEngine.timerStopForms.contains("cancel the timer"))
        XCTAssertTrue(ActionEngine.timerStopForms.contains("stop my timer"))
        XCTAssertTrue(ActionEngine.timerStopForms.contains("turn off the timer"))
        XCTAssertTrue(ActionEngine.focusStopForms.contains("cancel the focus"))
        XCTAssertTrue(ActionEngine.stopwatchResetForms.contains("cancel the stopwatch"))
        // Bare "cancel" belongs to the running-things chain, not here.
        XCTAssertFalse(ActionEngine.timerStopForms.contains("cancel"))
    }

    // MARK: State readback (the island answers for itself, R123)

    func testReadbackFormsCoverNaturalAsks() {
        XCTAssertTrue(ActionEngine.nowPlayingForms.contains("whats playing"))
        XCTAssertTrue(ActionEngine.nowPlayingForms.contains("what song is this"))
        XCTAssertTrue(ActionEngine.timeLeftForms.contains("how much time left"))
        XCTAssertTrue(ActionEngine.timeLeftForms.contains("how long on the timer"))
        // "what's on" stays the agenda's; never a music ask.
        XCTAssertFalse(ActionEngine.nowPlayingForms.contains("what's on"))
    }

    func testNowPlayingLineFormats() {
        XCTAssertEqual(
            ActionEngine.nowPlayingLine(
                track: "Midnight City", artist: "M83",
                source: "Spotify", playing: true),
            "Midnight City · M83, in Spotify."
        )
        XCTAssertEqual(
            ActionEngine.nowPlayingLine(
                track: "Midnight City", artist: "", source: "", playing: false),
            "Paused: Midnight City."
        )
    }

    func testTimeLeftLineNamesEveryRunningSession() {
        XCTAssertEqual(
            ActionEngine.timeLeftLine(timer: "4:59", focus: nil, stopwatch: nil),
            "4:59 on the timer."
        )
        XCTAssertEqual(
            ActionEngine.timeLeftLine(timer: "4:59", focus: "24:10", stopwatch: "0:08"),
            "4:59 on the timer · 24:10 left in the focus · 0:08 on the stopwatch."
        )
        XCTAssertEqual(
            ActionEngine.timeLeftLine(timer: nil, focus: nil, stopwatch: nil),
            "No timer running."
        )
    }

    // MARK: Volume intent (word-bounded, deliberate, R123)

    func testVolumeIntentParsesDirectionsAndLevels() {
        XCTAssertEqual(ActionEngine.volumeIntent("turn the volume down a bit"), .down)
        XCTAssertEqual(ActionEngine.volumeIntent("volume up"), .up)
        XCTAssertEqual(ActionEngine.volumeIntent("louder"), .up)
        XCTAssertEqual(ActionEngine.volumeIntent("quieter"), .down)
        XCTAssertEqual(ActionEngine.volumeIntent("turn it down"), .down)
        XCTAssertEqual(ActionEngine.volumeIntent("volume 30"), .set(30))
        XCTAssertEqual(ActionEngine.volumeIntent("set the volume to 70"), .set(70))
        XCTAssertEqual(ActionEngine.volumeIntent("what's the volume"), .read)
    }

    func testVolumeIntentStaysDeliberate() {
        // "update" contains "up"; word bounds must hold.
        XCTAssertNil(ActionEngine.volumeIntent("update my podcast"))
        // Ambience keeps "quiet" for itself.
        XCTAssertNil(ActionEngine.volumeIntent("quiet"))
        // Math stays with the model: no set-word, no bare-number grab.
        XCTAssertNil(ActionEngine.volumeIntent("the volume of a cube is 3"))
        // Chatter that merely mentions loudness stays freeform.
        XCTAssertNil(ActionEngine.volumeIntent("this cafe is too loud for calls"))
    }

    // MARK: Transport articles and the tell doorway (R124)

    func testTransportFormsCarryArticles() {
        // "pause the music" once took a multi-second model round-trip
        // to become "pause" (dogfood-caught).
        XCTAssertTrue(ActionEngine.pauseForms.contains("pause the music"))
        XCTAssertTrue(ActionEngine.pauseForms.contains("stop the music"))
        XCTAssertTrue(ActionEngine.playForms.contains("play the music"))
        XCTAssertTrue(ActionEngine.skipForms.contains("skip this song"))
        XCTAssertTrue(ActionEngine.previousForms.contains("previous track"))
        // Ambience keeps its own stop verb.
        XCTAssertFalse(ActionEngine.pauseForms.contains("stop noise"))
    }

    func testTextingPrefixTellGuard() {
        // "tell amma i am on my way" is how people say it; "tell me"
        // stays a question, and the space keeps "tell melissa" a
        // recipient.
        XCTAssertEqual(ActionEngine.textingPrefix(of: "tell amma i am on my way"), "tell ")
        XCTAssertEqual(ActionEngine.textingPrefix(of: "tell melissa the plan"), "tell ")
        XCTAssertNil(ActionEngine.textingPrefix(of: "tell me a joke"))
        XCTAssertNil(ActionEngine.textingPrefix(of: "tell me"))
        XCTAssertNil(ActionEngine.textingPrefix(of: "telling stories"))
        XCTAssertEqual(ActionEngine.textingPrefix(of: "text mom hi"), "text ")
    }
}
