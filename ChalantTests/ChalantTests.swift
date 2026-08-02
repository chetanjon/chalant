import EventKit
import XCTest
@testable import Chalant

/// Locks the behaviors that were each paid for with a live debugging
/// session. Every case here is a regression that actually happened or
/// a rule a round was built on; none are decoration.
@MainActor
final class ChalantTests: XCTestCase {

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

    func testReadbackFormsChalantrNaturalAsks() {
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

    // MARK: Playing signal ships quiet (R128)

    func testPlayingSignalDefaultsQuiet() {
        // The rim is the signal (R75); a permanent animation must be
        // chosen, not shipped. Both @AppStorage sites read this
        // constant, so this also pins them together.
        XCTAssertEqual(MusicController.playingSignalDefault, "quiet")
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

    // MARK: Review-caught regressions (R140)

    func testSessionQuestionNeverStartsASession() {
        // "how much time left on the timer" once fell past the exact
        // readback set into the timer creator and RESTARTED it.
        XCTAssertTrue(ActionEngine.isSessionQuestion("how much time left on the timer"))
        XCTAssertTrue(ActionEngine.isSessionQuestion("how long on the timer"))
        XCTAssertTrue(ActionEngine.isSessionQuestion("what's on the stopwatch"))
        XCTAssertTrue(ActionEngine.isSessionQuestion("is the timer still going"))
        // Commands to START are not questions.
        XCTAssertFalse(ActionEngine.isSessionQuestion("timer 10"))
        XCTAssertFalse(ActionEngine.isSessionQuestion("set a timer for 5"))
        XCTAssertFalse(ActionEngine.isSessionQuestion("start a focus"))
    }

    func testVolumeTargetBeatsDirectionWord() {
        // "volume up to 80" means 80, not one step up.
        XCTAssertEqual(ActionEngine.volumeIntent("volume up to 80"), .set(80))
        XCTAssertEqual(ActionEngine.volumeIntent("turn the volume up to 30"), .set(30))
        // Bare direction still steps.
        XCTAssertEqual(ActionEngine.volumeIntent("volume up"), .up)
        XCTAssertEqual(ActionEngine.volumeIntent("turn the volume down"), .down)
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

    // MARK: Catching what Swift cannot catch

    func testAudioGuardTurnsARaisedExceptionIntoAThrow() {
        // If the shim does not work, this test does not fail. It takes
        // the whole runner down with it, which is exactly what the app
        // did on a second tap.
        do {
            try AudioGuard.attempt("deliberate raise") {
                NSException(
                    name: .invalidArgumentException,
                    reason: "required condition is false: nullptr == Tap()",
                    userInfo: nil
                ).raise()
            }
            XCTFail("the raise should have arrived as a throw")
        } catch let failure as AudioGuard.Failure {
            XCTAssertEqual(failure.name, NSExceptionName.invalidArgumentException.rawValue)
            XCTAssertEqual(failure.reason, "required condition is false: nullptr == Tap()")
            // The site is carried too, so a log names the call and not
            // just the symptom.
            XCTAssertEqual(failure.during, "deliberate raise")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testAudioGuardLetsOrdinaryWorkThrough() {
        var ran = false
        XCTAssertNoThrow(try AudioGuard.attempt("ordinary") { ran = true })
        XCTAssertTrue(ran)
        XCTAssertTrue(AudioGuard.succeeds("ordinary") { })
        XCTAssertFalse(AudioGuard.succeeds("raises") {
            NSException(name: .genericException, reason: "no", userInfo: nil).raise()
        })
    }

    // MARK: Reading why the last run died

    func testCrashReasonNamesASwiftTrapOutright() {
        // Taken from the real report this app produced: the trap message
        // is written into the frame symbols, and it is the whole
        // diagnosis on its own.
        let report = """
        {"app_name":"Chalant","timestamp":"2026-07-28 01:15:44.00 +0530"}
        {"termination":{"indicator":"Trace\\/BPT trap: 5"},"threads":[{"frames":[
        {"symbol":"Swift runtime failure: Can't take a prefix of negative length from a collection"},
        {"symbol":"specialized static ActivityServer.parse(_:)"}]}]}
        """
        XCTAssertEqual(
            CrashWatch.reason(inReportText: report),
            "Swift runtime failure: Can't take a prefix of negative length from a collection")
    }

    func testCrashReasonFallsBackThroughExceptionThenSignal() {
        // An Objective-C exception, the AVAudioEngine family, carries a
        // reason of its own instead of a trap message.
        let objc = #"{"exception":{"type":"EXC_CRASH","reason":"required condition is false: nullptr == Tap()"}}"#
        XCTAssertEqual(
            CrashWatch.reason(inReportText: objc),
            "required condition is false: nullptr == Tap()")
        // With neither, the signal is still worth naming.
        let bare = #"{"termination":{"indicator":"Namespace SIGNAL, Code 11"}}"#
        XCTAssertEqual(CrashWatch.reason(inReportText: bare), "Ended on Namespace SIGNAL, Code 11.")
    }

    func testCrashReasonNeverThrowsOnRubbish() {
        // This runs at launch over files written by a process that was
        // dying. Whatever it finds, it must hand back a line and never
        // become the second crash.
        for rubbish in ["", "not json at all", "{", String(repeating: "\u{0}", count: 64),
                        #"{"reason":""}"#, #"{"indicator":"}"#,
                        "Fatal error: ", String(repeating: "x", count: 100_000)] {
            let reason = CrashWatch.reason(inReportText: rubbish)
            XCTAssertFalse(reason.isEmpty)
            // Nothing may hand back a screenful for a pill to render.
            XCTAssertLessThan(reason.count, 400)
        }
    }

    // MARK: Sessions measure time, not ticks

    /// These timers live on the main run loop, so the run loop has to
    /// actually turn for them to fire. Task.sleep frees the main actor
    /// but promises nothing about running it, which makes any assertion
    /// after one a coin toss.
    private func letTheClockRun(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testCountdownReadsTheWallClockNotTheTickCount() {
        // Counting one second per fired tick meant a Mac that slept
        // owed nothing for the time it was away: a 25 minute session
        // across a closed lid came back with 25 minutes still to run.
        let countdown = CountdownController()
        countdown.start(minutes: 1)
        XCTAssertEqual(countdown.remaining, 60)
        XCTAssertTrue(countdown.isActive)
        letTheClockRun(1.2)
        XCTAssertLessThan(countdown.remaining, 60)
        XCTAssertGreaterThan(countdown.remaining, 55)
        countdown.stop()
        XCTAssertFalse(countdown.isActive)
        XCTAssertEqual(countdown.remaining, 0)
    }

    func testCountdownDisplayStillFormatsFromTheDerivedReading() {
        let countdown = CountdownController()
        countdown.start(minutes: 25)
        XCTAssertEqual(countdown.display, "25:00")
        XCTAssertEqual(countdown.progress, 0, accuracy: 0.01)
        countdown.stop()
    }

    func testFocusPauseHoldsTheReadingAndResumeCarriesItOn() {
        let focus = FocusController(ambience: AmbienceController())
        focus.start(work: 1)
        XCTAssertEqual(focus.remaining, 60)
        letTheClockRun(1.2)
        let beforePause = focus.remaining
        XCTAssertLessThan(beforePause, 60)

        focus.togglePause()
        // Paused, the wall clock keeps moving and the reading must not.
        letTheClockRun(1.2)
        XCTAssertEqual(focus.remaining, beforePause)

        focus.togglePause()
        // Resumed, it owes the time since resuming and not the pause.
        letTheClockRun(1.2)
        XCTAssertLessThan(focus.remaining, beforePause)
        XCTAssertGreaterThan(focus.remaining, beforePause - 5)
        focus.stop()
    }

    // MARK: What the voice trail is allowed to remember

    func testVoiceLogHoldsBackTheWordsOfAMessage() {
        // The trail never emptied, so every message dictated since
        // install was sitting verbatim in a plist.
        let (heard, outcome) = NotchViewModel.redactedForLog(
            heard: "text mom the wifi password is hunter2",
            outcome: "To Mom (+15551234567): \u{201C}the wifi password is hunter2\u{201D}."
                + " Say send, or anything else to drop it."
        )
        XCTAssertFalse(heard.contains("hunter2"))
        XCTAssertFalse(outcome.contains("hunter2"))
        // Who it was for survives: that is what a staging bug looks like.
        XCTAssertTrue(heard.hasPrefix("text mom"))
        XCTAssertTrue(outcome.hasPrefix("To Mom (+15551234567)"))
        XCTAssertTrue(heard.contains("words held back"))
    }

    func testVoiceLogRedactsEveryTextingForm() {
        for utterance in ["text sam: meet me at the bank",
                          "tell amma i am on my way",
                          "message dad the code is 4417",
                          "imessage priya the door key is under the mat"] {
            let (heard, _) = NotchViewModel.redactedForLog(heard: utterance, outcome: "")
            XCTAssertTrue(heard.contains("words held back"), utterance)
            for secret in ["bank", "way", "4417", "mat"] where utterance.contains(secret) {
                XCTAssertFalse(heard.contains(secret), "\(utterance) leaked \(secret)")
            }
        }
    }

    func testVoiceLogLeavesOrdinaryVerbsWhole() {
        // Redacting everything would gut the trail, which is the first
        // thing read on any voice report.
        let (heard, outcome) = NotchViewModel.redactedForLog(
            heard: "timer 5", outcome: "Timer on. 5 minutes, counting in the notch.")
        XCTAssertEqual(heard, "timer 5")
        XCTAssertEqual(outcome, "Timer on. 5 minutes, counting in the notch.")
        // "tell me a joke" is a question, not a message.
        let (joke, _) = NotchViewModel.redactedForLog(heard: "tell me a joke", outcome: "")
        XCTAssertEqual(joke, "tell me a joke")
    }

    func testTheVoiceTrailNeverCarriesAnAgentMessagesBody() {
        // A message to a session is the same class of thing as one to a
        // person: the trail keeps where it went and how long it was,
        // never the words themselves (EC-13). Unlike redactedForLog
        // above, the body is never assembled at all, not stripped out
        // after the fact.
        let (heard, outcome) = NotchViewModel.agentMessageLogLine(
            title: "chalant", text: "the secret thing"
        )
        XCTAssertFalse(heard.contains("secret"))
        XCTAssertFalse(heard.contains("thing"))
        XCTAssertFalse(outcome.contains("secret"))
        XCTAssertFalse(outcome.contains("thing"))
        XCTAssertTrue(heard.contains("chalant"))
        XCTAssertTrue(outcome.contains("3 word"))
    }

    // MARK: Giving up on an await (the island's ceiling)

    func testTimeboxedGivesUpOnWorkThatNeverAnswers() async {
        // The screen read and the message send both reach another
        // process and both wedged there holding the island open and
        // deaf. A ceiling that quietly failed to fire would put that
        // back without anyone noticing.
        let started = Date()
        let answer = await timeboxed(0.2) {
            // Stands in for a continuation nobody will resume: the
            // sleeper outlives the ceiling and lands in nobody's hands.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return "too late"
        }
        XCTAssertNil(answer)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testTimeboxedKeepsAnAnswerThatArrivesInTime() async {
        let answer = await timeboxed(5) { "read 12 lines" }
        XCTAssertEqual(answer, "read 12 lines")
    }

    func testTimeboxedAnswersOnlyOnce() async {
        // Both racers reach the same continuation; resuming it twice
        // is a crash, not a wrong answer.
        for _ in 0..<50 {
            _ = await timeboxed(0.01) { "fast" }
        }
    }

    // MARK: Number parsing (every one of these becomes seconds)

    func testFirstNumberClampsBeyondAnyRealSession() {
        // "timer 200000000000000000" reached `minutes * 60`, which
        // overflowed Int64 and trapped. The ceiling is the fix; the
        // digits still read as a number so the verb still runs.
        XCTAssertEqual(ActionEngine.firstNumber(in: "timer 200000000000000000"), 100_000)
        XCTAssertEqual(ActionEngine.firstNumber(in: "focus \(Int.max)"), 100_000)
        // Clamped values must still survive the multiply every caller does.
        let clamped = ActionEngine.firstNumber(in: "push standup by 999999999999 hours")!
        XCTAssertLessThan(clamped * 3600, Int.max)
    }

    func testFirstNumberLeavesOrdinaryAsksAlone() {
        XCTAssertEqual(ActionEngine.firstNumber(in: "timer 5"), 5)
        XCTAssertEqual(ActionEngine.firstNumber(in: "focus 25 minutes"), 25)
        XCTAssertEqual(ActionEngine.firstNumber(in: "push standup by 30 minutes"), 30)
        XCTAssertNil(ActionEngine.firstNumber(in: "start a focus"))
        // Volume's own 0...100 gate still rejects a clamped number,
        // so a huge value keeps falling through to the direction words.
        XCTAssertEqual(ActionEngine.volumeIntent("volume up to 999999999999999999"), .up)
    }

    // MARK: The open door's request parser (any local process reaches it)

    private func rawRequest(_ headers: String, body: String = "") -> Data {
        Data("\(headers)\r\n\r\n\(body)".utf8)
    }

    func testParseRefusesNegativeContentLength() {
        // "Content-Length: -1" parsed as a number, passed a guard
        // written for non-negative lengths, and trapped inside
        // Data.prefix. One line of nc took the whole app down.
        XCTAssertNil(ActivityServer.parse(
            rawRequest("POST /activity HTTP/1.1\r\nContent-Length: -1")))
        XCTAssertNil(ActivityServer.parse(
            rawRequest("POST /activity HTTP/1.1\r\nContent-Length: -999999")))
    }

    func testParseRefusesContentLengthBeyondTheReadCap() {
        // A length no body could ever satisfy is refused outright
        // rather than waited on until the connection deadline.
        XCTAssertNil(ActivityServer.parse(rawRequest(
            "POST /activity HTTP/1.1\r\nContent-Length: \(ActivityServer.maxBody + 1)")))
    }

    func testParseStillAcceptsOrdinaryRequests() {
        // The guard must not cost the good case: absent, empty, zero,
        // and real lengths all still parse.
        let body = #"{"title":"build"}"#
        let request = ActivityServer.parse(rawRequest(
            "POST /activity HTTP/1.1\r\nContent-Length: \(body.utf8.count)", body: body))
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/activity")
        XCTAssertEqual(request?.body, Data(body.utf8))
        XCTAssertFalse(request?.fromBrowser ?? true)

        XCTAssertEqual(ActivityServer.parse(rawRequest("GET /activities HTTP/1.1"))?.path,
                       "/activities")
        XCTAssertEqual(ActivityServer.parse(
            rawRequest("GET /activities HTTP/1.1\r\nContent-Length:"))?.body, Data())
        XCTAssertEqual(ActivityServer.parse(
            rawRequest("GET /activities HTTP/1.1\r\nContent-Length: 0"))?.body, Data())
    }

    func testActivityStringsAreCapped() {
        // Up to half a megabyte could arrive as one unbroken line for
        // SwiftUI to lay out inside a pill. Rows were bounded at eight
        // and expired on a timer; the strings themselves were not.
        let huge = String(repeating: "a", count: 400_000)
        let capped = ActivityServer.capped(title: huge, detail: huge, id: huge)
        XCTAssertEqual(capped.title.count, ActivityServer.maxTitle)
        XCTAssertEqual(capped.detail?.count, ActivityServer.maxDetail)
        XCTAssertEqual(capped.id.count, ActivityServer.maxID)
    }

    func testActivityIdFallsBackToTitleWithoutSmugglingLength() {
        // An absent id becomes the title, which is allowed to be wider
        // than an id: the fallback must not carry that extra width in.
        let long = String(repeating: "b", count: 400)
        XCTAssertEqual(
            ActivityServer.capped(title: long, detail: nil, id: nil).id.count,
            ActivityServer.maxID)
        XCTAssertEqual(
            ActivityServer.capped(title: long, detail: nil, id: "").id.count,
            ActivityServer.maxID)
    }

    func testActivityCappingLeavesOrdinaryPillsAlone() {
        let capped = ActivityServer.capped(
            title: "build", detail: "42 tests green", id: "ci")
        XCTAssertEqual(capped.title, "build")
        XCTAssertEqual(capped.detail, "42 tests green")
        XCTAssertEqual(capped.id, "ci")
        XCTAssertNil(ActivityServer.capped(title: "x", detail: nil, id: "y").detail)
    }

    func testTokenComparisonIsExactAndLengthSafe() {
        let real = "s3cret-token-value"
        XCTAssertTrue(ActivityServer.tokenMatches(real, real))
        XCTAssertFalse(ActivityServer.tokenMatches("", real))
        XCTAssertFalse(ActivityServer.tokenMatches("s3cret-token-valuX", real))
        // A prefix must not pass, which a length-blind loop would allow.
        XCTAssertFalse(ActivityServer.tokenMatches("s3cret", real))
        XCTAssertFalse(ActivityServer.tokenMatches(real + "x", real))
        // An empty expected token must never open the door.
        XCTAssertFalse(ActivityServer.tokenMatches("", ""))
        XCTAssertFalse(ActivityServer.tokenMatches("anything", ""))
    }

    func testParseReadsTheTokenHeaderCaseInsensitively() {
        XCTAssertEqual(
            ActivityServer.parse(rawRequest(
                "GET /activities HTTP/1.1\r\nX-Chalant-Token: abc123"))?.offeredToken,
            "abc123")
        XCTAssertEqual(
            ActivityServer.parse(rawRequest(
                "GET /activities HTTP/1.1\r\nx-chalant-token:   abc123  "))?.offeredToken,
            "abc123")
        // Absent header reads as empty, which never matches.
        XCTAssertEqual(
            ActivityServer.parse(rawRequest("GET /activities HTTP/1.1"))?.offeredToken, "")
    }

    func testParseStillFlagsBrowserRequests() {
        // The cross-origin guard rides on this flag; the length fix
        // must not disturb it.
        XCTAssertTrue(ActivityServer.parse(
            rawRequest("POST /activity HTTP/1.1\r\nOrigin: https://evil.example"))?
            .fromBrowser ?? false)
        XCTAssertTrue(ActivityServer.parse(
            rawRequest("POST /activity HTTP/1.1\r\nSec-Fetch-Mode: cors"))?
            .fromBrowser ?? false)
    }
}
