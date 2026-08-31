import AppKit
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
    }

    /// The row that answers when you look (2026-08-28): the throttle and
    /// the staleness words, pure and pinned.
    func testTheUpdateRowChecksWhenLookedAtAndSpeaksPlainly() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UpdateChecker.shouldCheck(onOpenAt: now, lastChecked: nil))
        XCTAssertFalse(UpdateChecker.shouldCheck(onOpenAt: now, lastChecked: now.addingTimeInterval(-60)))
        XCTAssertTrue(UpdateChecker.shouldCheck(onOpenAt: now, lastChecked: now.addingTimeInterval(-121)))
        XCTAssertEqual(UpdateChecker.ago(nil, now: now), "not yet")
        XCTAssertEqual(UpdateChecker.ago(now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(UpdateChecker.ago(now.addingTimeInterval(-300), now: now), "5 min ago")
        XCTAssertEqual(UpdateChecker.ago(now.addingTimeInterval(-7200), now: now), "2 h ago")
        XCTAssertEqual(UpdateChecker.ago(now.addingTimeInterval(-200_000), now: now), "2 d ago")
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
        // A timing test has no business starting an audio engine.
        let focus = FocusController(ambience: AmbienceController(engine: RecordingAmbienceSource()))
        focus.start(work: 1)
        XCTAssertEqual(focus.remaining, 60)
        // Past the second tick, not the first. The reading is
        // `ceil(timeIntervalSinceNow)`, so a timer that fires a
        // hair early at the one second mark computes ceil(59.0001)
        // and reads 60, which is correct behaviour and an unstable
        // assertion: this test failed on exactly that boundary
        // (2026-08-06, "60 is not less than 60"). Two ticks of margin
        // costs a second and can only fail if the clock is wrong.
        letTheClockRun(2.2)
        let beforePause = focus.remaining
        XCTAssertLessThan(beforePause, 60)

        focus.togglePause()
        // Paused, the wall clock keeps moving and the reading must not.
        letTheClockRun(1.2)
        XCTAssertEqual(focus.remaining, beforePause)

        focus.togglePause()
        // Resumed, it owes the time since resuming and not the pause.
        letTheClockRun(2.2)
        XCTAssertLessThan(focus.remaining, beforePause)
        XCTAssertGreaterThan(focus.remaining, beforePause - 5)
        focus.stop()
    }

    func testFocusSessionEndsAfterOneBout() {
        // A phase that runs to zero ends the session. It used to roll
        // into the break, then the next round, forever; a user who
        // stepped away came back to a machine still grinding rounds
        // (user, 2026-07-31).
        // A timing test has no business starting an audio engine.
        let focus = FocusController(ambience: AmbienceController(engine: RecordingAmbienceSource()))
        var banked: Int?
        focus.onWorkPhaseComplete = { banked = $0 }
        focus.start(work: 25)
        focus.expirePhaseNow()
        XCTAssertFalse(focus.isActive, "a finished work phase must end the session, not start a break")
        XCTAssertEqual(banked, 25)

        // Skip is the user's own hand; it still walks phases mid-session.
        var breakEnded = false
        focus.onBreakComplete = { _ in breakEnded = true }
        focus.start(work: 25)
        focus.skip()
        XCTAssertTrue(focus.isActive)
        XCTAssertEqual(focus.phase, .rest)

        // And a break that runs out ends the session the same way.
        focus.expirePhaseNow()
        XCTAssertFalse(focus.isActive)
        XCTAssertTrue(breakEnded)
        focus.stop()
    }

    func testAFocusSessionMakesNoSoundOfItsOwn() {
        // Starting a session switched on brown noise by itself (user,
        // 2026-08-02: "we dont want that"). Sound is the user's to
        // start, never the timer's.
        let source = RecordingAmbienceSource()
        let ambience = AmbienceController(engine: source)
        let focus = FocusController(ambience: ambience)
        focus.start(work: 25)
        XCTAssertNil(ambience.active, "a focus session must not turn ambient noise on")
        focus.skip()
        XCTAssertNil(ambience.active, "a break must not turn ambient noise on either")
        focus.stop()
        XCTAssertNil(ambience.active)
        XCTAssertEqual(source.calls, ["setVolume"],
                       "construction hands the engine its remembered volume; the session itself asked for nothing")
    }

    func testAFocusSessionLeavesTheUsersOwnNoiseAlone() {
        // The other half of the same coupling: the session used to
        // pause the sound on a break and stop it at the end, so noise
        // the user had started for themselves died with the timer.
        //
        // Held against a source that records rather than a real engine.
        // The rule is about which object calls which method, and a
        // machine with no audio output was previously able to answer it
        // for us: the engine failed to start, said so through
        // `onSilence`, and cleared `active` mid-test. Red at 0ea7534,
        // green at 6910efa, a docs-only commit between them.
        let source = RecordingAmbienceSource()
        let ambience = AmbienceController(engine: source)
        let focus = FocusController(ambience: ambience)

        ambience.play(.brown)
        focus.start(work: 25)
        XCTAssertEqual(ambience.active, .brown)
        focus.skip()
        XCTAssertEqual(ambience.active, .brown, "a break must not silence the user's noise")
        focus.stop()
        XCTAssertEqual(ambience.active, .brown, "ending a session must not stop the user's noise")

        // The stronger form of the same claim, and the one that says it
        // without going through any state at all: the timer started,
        // broke, and ended without ever reaching for the sound.
        XCTAssertEqual(source.calls, ["setVolume", "start(brown)"],
                       "construction's volume handoff, the user's own play, and nothing the timer did")
        ambience.stop()
    }

    func testAmbienceVolumeIsRememberedAcrossLaunches() {
        // Every other user-facing dial persists; the ambience volume
        // used to reset to 0.7 every morning. Scratch suite per the
        // repo law: a test never touches `.standard`.
        let suite = "chalant.tests.ambience.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let first = AmbienceController(engine: RecordingAmbienceSource(), defaults: defaults)
        XCTAssertEqual(first.volume, 0.7, "nothing saved means the old default")
        first.volume = 0.25

        let source = RecordingAmbienceSource()
        let second = AmbienceController(engine: source, defaults: defaults)
        XCTAssertEqual(second.volume, 0.25, "a relaunch keeps the level")
        XCTAssertEqual(source.calls, ["setVolume"],
                       "the remembered level reaches the engine at construction")
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: The bars' choreography (now sampled for the render server)

    func testTheDanceKeyframesFollowTheLiveMath() {
        // The keyframe loop must be the same sine stack the
        // reduced-motion fallback and the old timeline drew, sampled
        // at 15 a second over the 47s loop, floored at the bar's own
        // width so a quiet moment stays a dot rather than a sliver.
        let track = NowPlayingBars.keyframeHeights(index: 1, maxHeight: 7)
        XCTAssertEqual(track.count, 705, "47 seconds at 15 samples a second")
        XCTAssertEqual(
            track[0],
            max(NowPlayingBars.barWidth,
                NowPlayingBars.liveHeight(t: 0, index: 1, maxHeight: 7))
        )
        XCTAssertTrue(track.allSatisfy { $0 >= NowPlayingBars.barWidth && $0 <= 7 })
        XCTAssertTrue(Set(track.map { Int($0 * 100) }).count > 50,
                      "a dance, not a flat line")
        XCTAssertNotEqual(
            NowPlayingBars.keyframeHeights(index: 0, maxHeight: 7)[10], track[10],
            "each bar carries its own phase"
        )
    }

    func testASourceThatCannotMakeASoundPutsTheChipOut() async {
        // The behaviour that used to decide the test above, written
        // down as a test of its own rather than left as folklore. It is
        // correct and it is asynchronous, and both of those are the
        // reason it must never again be something another test can trip
        // over by accident.
        let source = RecordingAmbienceSource()
        let ambience = AmbienceController(engine: source)
        ambience.play(.brown)
        XCTAssertEqual(ambience.active, .brown)

        source.onSilence?("the audio engine wouldn't start")

        // The hop the failure takes on its way to the main actor.
        // Bounded, so a change that stops it arriving fails here rather
        // than hanging.
        var spins = 0
        while ambience.active != nil, spins < 1_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertNil(ambience.active, "a chip lit over silence is a lie")
        XCTAssertEqual(ambience.failure, "the audio engine wouldn't start")
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

    // MARK: The second name the door answers to (Claude Code's HTTP hooks)

    func testBearerTokenIsAcceptedAlongsideTheOriginalHeader() {
        // Claude Code's `type: "http"` hooks can only send
        // `Authorization: Bearer <token>`, so the door has to answer to
        // both names or the whole hook path is unreachable.
        XCTAssertEqual(
            ActivityServer.parse(rawRequest(
                "GET /health HTTP/1.1\r\nAuthorization: Bearer abc123"))?.offeredToken,
            "abc123")
        XCTAssertEqual(
            ActivityServer.parse(rawRequest(
                "GET /health HTTP/1.1\r\nX-Chalant-Token: abc123"))?.offeredToken,
            "abc123")
        // Case is Claude Code's to choose, not this app's.
        XCTAssertEqual(
            ActivityServer.parse(rawRequest(
                "GET /health HTTP/1.1\r\nauthorization: bearer abc123"))?.offeredToken,
            "abc123")
    }

    func testOnlyBearerCountsAndAMalformedHeaderIsNoToken() {
        // Anything that is not a Bearer reads as no token at all rather
        // than as its own tail: `Basic YWJj` must never be offered up as
        // if it were the secret, and an empty or truncated header must
        // not trap the way Content-Length once did.
        for header in [
            "Authorization: Basic YWJjMTIz",
            "Authorization: Bearer",
            "Authorization: Bearer ",
            "Authorization:",
            "Authorization",
        ] {
            XCTAssertEqual(
                ActivityServer.parse(rawRequest("GET /health HTTP/1.1\r\n\(header)"))?
                    .offeredToken,
                "", "\(header) should offer no token")
        }
    }

    func testAnEmptyOfferNeverMatchesTheRealToken() {
        // The 401 depends on this: a request with no token at all must
        // fail the comparison, not pass it by being equally empty.
        let real = ActivityServer.loadOrCreateToken()
        XCTAssertFalse(ActivityServer.tokenMatches("", real))
        XCTAssertFalse(ActivityServer.tokenMatches("", ""))
    }

    func testPortFallbackTriesTheKnownPortFirstThenNeighbours() {
        // 4242 is the port every hook and script already installed on
        // this machine knows, so it stays first. The rest exist so a
        // taken port leaves the island reachable rather than silently
        // deaf.
        let candidates = ActivityServer.portCandidates(from: 4242)
        XCTAssertEqual(candidates.first, 4242)
        XCTAssertEqual(candidates.count, 11)
        XCTAssertEqual(Set(candidates).count, candidates.count)
        XCTAssertEqual(candidates.last, 4252)
    }

    func testPortFallbackCannotOverflow() {
        // UInt16(next) traps past 65535, and the preferred port is a
        // user default anybody can set.
        let candidates = ActivityServer.portCandidates(from: UInt16.max - 2)
        XCTAssertEqual(candidates, [UInt16.max - 2, UInt16.max - 1, UInt16.max])
    }

    func testServerConfigAndTokenSitTogetherUnderTheAppsOwnFolder() {
        XCTAssertEqual(ActivityServer.configURL.lastPathComponent, "server.json")
        XCTAssertEqual(ActivityServer.tokenURL.lastPathComponent, "api-token")
        XCTAssertEqual(
            ActivityServer.configURL.deletingLastPathComponent(),
            ActivityServer.tokenURL.deletingLastPathComponent())
        XCTAssertEqual(
            ActivityServer.support.lastPathComponent, "Chalant")
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

    // MARK: Clipboard durable history (backlog C, 2026-08-02)

    /// A scratch directory per test, never the real Application
    /// Support folder: a persistence test must not be able to touch
    /// an actual install's clip history.
    private func clipboardScratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("chalant-clip-test-\(UUID().uuidString)", isDirectory: true)
    }

    func testClearAllLeavesPinnedClipsStanding() {
        // "Pin or shelf what should stay" is a promise the empty state
        // makes out loud, and a bulk clear is exactly where it would
        // quietly break.
        let dir = clipboardScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ClipboardStore(clipsDirectory: dir)
        store.addText("keep me")
        store.addText("history one")
        store.addText("history two")
        guard let toPin = store.clips.first(where: { $0.text == "keep me" }) else {
            return XCTFail("the clip to pin was never stored")
        }
        store.togglePin(toPin)
        XCTAssertEqual(store.clips.count, 3)
        XCTAssertTrue(store.hasUnpinned)

        store.clearUnpinned()

        XCTAssertEqual(store.clips.map(\.text), ["keep me"])
        XCTAssertTrue(store.clips.allSatisfy(\.pinned))
        // Nothing left to clear, so the control has nothing to offer
        // and the view stops drawing it.
        XCTAssertFalse(store.hasUnpinned)
    }

    func testClearAllSurvivesARelaunch() {
        // Clearing has to reach the index on disk, not just the array:
        // a clear that only emptied memory would come back on launch.
        let dir = clipboardScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ClipboardStore(clipsDirectory: dir)
        store.addText("pinned")
        store.addText("gone")
        if let toPin = store.clips.first(where: { $0.text == "pinned" }) {
            store.togglePin(toPin)
        }
        store.clearUnpinned()

        let reloaded = ClipboardStore(clipsDirectory: dir)
        XCTAssertEqual(reloaded.clips.map(\.text), ["pinned"])
    }

    func testClearAllOnAllPinnedHistoryRemovesNothing() {
        let dir = clipboardScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ClipboardStore(clipsDirectory: dir)
        store.addText("one")
        store.addText("two")
        store.clips.forEach { store.togglePin($0) }
        XCTAssertFalse(store.hasUnpinned)

        store.clearUnpinned()

        XCTAssertEqual(store.clips.count, 2)
    }

    func testClipHistoryPersistsAcrossRelaunchIncludingUnpinnedClips() {
        let dir = clipboardScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ClipboardStore(clipsDirectory: dir)
        store.addText("first")
        store.addText("second")
        // Pin the older one: a pinned clip and a plain-history clip
        // both have to survive the round trip.
        if let toPin = store.clips.last {
            store.togglePin(toPin)
        }
        let before = store.clips

        // A fresh instance stands in for a relaunch: nothing here can
        // come from the in-memory copy above.
        let reloaded = ClipboardStore(clipsDirectory: dir)
        XCTAssertEqual(reloaded.clips.map(\.text), before.map(\.text))
        XCTAssertEqual(reloaded.clips.map(\.pinned), before.map(\.pinned))
    }

    func testClipHistoryIsNeverCappedByCount() {
        // "so I dont lose anything that I copied": the old 30-clip
        // cap silently dropped history. Disk is the only limit now.
        let dir = clipboardScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ClipboardStore(clipsDirectory: dir)
        for index in 0..<50 {
            store.addText("clip \(index)")
        }
        XCTAssertEqual(store.clips.count, 50)
    }

    func testClipboardRefusesConcealedAndTransientPasteboardContent() {
        // A password manager's clip must never reach disk.
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        XCTAssertTrue(ClipboardStore.isSensitive([concealed]))
        XCTAssertTrue(ClipboardStore.isSensitive([transient]))
        XCTAssertTrue(ClipboardStore.isSensitive([.string, concealed]))
        XCTAssertFalse(ClipboardStore.isSensitive([.string]))
    }

    /// A scratch pasteboard for one test, so the suite neither touches
    /// nor depends on the machine's real clipboard.
    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("chalant-clip-test-\(UUID().uuidString)"))
    }

    func testCopyBackIsNotArchivedAsANewClip() {
        // Pressing Copy on a row writes the pasteboard, and the poller
        // must treat that write as already seen: archiving it again
        // put the same content back at the top as a brand-new clip.
        // An older row makes the honest arrangement, because a copy-back
        // of the newest row was already masked by the repeat guard.
        let dir = clipboardScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(clipsDirectory: dir, pasteboard: board)
        store.addText("older")
        store.addText("newest")

        guard let older = store.clips.last else { return XCTFail("no clips") }
        store.copyBack(older)
        store.poll()

        XCTAssertEqual(store.clips.count, 2)
        // The write itself still happened; only the archiving didn't.
        XCTAssertEqual(board.string(forType: .string), "older")
    }

    func testCopyBackOfAScreenshotDoesNotMintASecondRow() {
        // The reported shape: images have no consecutive-repeat guard,
        // so every copy-back minted a fresh row and a fresh PNG.
        let dir = clipboardScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(clipsDirectory: dir, pasteboard: board)
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        XCTAssertTrue(store.addImage(image))

        guard let row = store.clips.first else { return XCTFail("no clips") }
        store.copyBack(row)
        store.poll()

        XCTAssertEqual(store.clips.count, 1)
    }

    func testRescuePasteboardItemCarriesNoTransientMarkAndPasteItemsDo() {
        // Mid-insert pastes are marked transient so no clipboard
        // history archives our mechanics. Words handed back for
        // keeping must NOT carry the mark, or the one place a person
        // looks for them skips them.
        let marker = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let kept = PasteboardGuard.item(for: "spoken", transient: false)
        let masked = PasteboardGuard.item(for: "mid-insert", transient: true)
        XCTAssertFalse(kept.types.contains(marker))
        XCTAssertTrue(masked.types.contains(marker))
        XCTAssertEqual(kept.string(forType: .string), "spoken")
    }

    func testRescuedWordsLandInClipHistoryAndMaskedWritesDoNot() {
        // The founder's case (2026-08-20 17:36): dictated at a bare
        // window, words left on the clipboard, and the Clipboard tab
        // never showed them. A rescue write is a keeper: the pane
        // archives it like any real copy. A masked write still isn't.
        let dir = clipboardScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(clipsDirectory: dir, pasteboard: board)

        board.clearContents()
        board.writeObjects([PasteboardGuard.item(for: "what I spoke", transient: false)])
        store.poll()
        XCTAssertEqual(store.clips.first?.text, "what I spoke")

        board.clearContents()
        board.writeObjects([PasteboardGuard.item(for: "swap mechanics", transient: true)])
        store.poll()
        XCTAssertEqual(store.clips.count, 1)
    }

    func testPollStillHearsAForeignCopyAfterACopyBack() {
        // Suppression covers exactly one write, ours: the next copy
        // from anywhere else must land as usual.
        let dir = clipboardScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(clipsDirectory: dir, pasteboard: board)
        store.addText("mine")
        guard let mine = store.clips.first else { return XCTFail("no clips") }
        store.copyBack(mine)
        store.poll()

        board.clearContents()
        board.setString("someone else's copy", forType: .string)
        store.poll()

        XCTAssertEqual(store.clips.first?.text, "someone else's copy")
        XCTAssertEqual(store.clips.count, 2)
    }

    // MARK: Calendar permission state (a grant should never need a relaunch)

    func testPermissionDecisionMapsFullAccessToGranted() {
        XCTAssertEqual(EventKitService.decision(for: .fullAccess), .granted)
    }

    func testPermissionDecisionMapsNotDeterminedToAsk() {
        // Still worth a "ask again" button: the system will prompt.
        XCTAssertEqual(EventKitService.decision(for: .notDetermined), .ask)
    }

    func testPermissionDecisionMapsDeniedAndRestrictedToDenied() {
        // Neither ever re-prompts; only System Settings can change these.
        XCTAssertEqual(EventKitService.decision(for: .denied), .denied)
        XCTAssertEqual(EventKitService.decision(for: .restricted), .denied)
    }

    // MARK: Glass clarity contrast floor (no dial reaches true zero)

    func testGlassClarityNeverReachesZeroAtAnyClarity() {
        // "clear" is the risky end of the dial; unrecognized values
        // fall through the same `default` branch as "balanced".
        for clarity in ["veiled", "balanced", "clear", "unrecognized"] {
            XCTAssertGreaterThan(Theme.glassTint(for: clarity), 0)
            XCTAssertGreaterThan(Theme.glassSmoke(for: clarity), 0)
        }
    }

    // MARK: The sounds themselves

    /// The soundscapes render with no audio device, which is what lets
    /// the suite hold a floor under qualities that are otherwise pure
    /// opinion. Thresholds here are not guesses: every one was measured
    /// off the real generators first, then set with room to move.

    private func scapes() -> [(String, Soundscape)] {
        [
            ("brown", ColorNoise(.brown)),
            ("pink", ColorNoise(.pink)),
            ("white", ColorNoise(.white)),
            ("rain", RainScape()),
            ("fire", FireScape()),
        ]
    }

    private func rms(_ samples: [Float]) -> Float {
        sqrtf(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }

    /// Pearson correlation between the channels. Near zero means the
    /// two sides were generated independently; near one means the sound
    /// is mono wearing a stereo coat.
    private func correlation(_ left: [Float], _ right: [Float]) -> Float {
        let meanLeft = left.reduce(0, +) / Float(left.count)
        let meanRight = right.reduce(0, +) / Float(right.count)
        var covariance: Float = 0
        var varianceLeft: Float = 0
        var varianceRight: Float = 0
        for index in left.indices {
            let a = left[index] - meanLeft
            let b = right[index] - meanRight
            covariance += a * b
            varianceLeft += a * a
            varianceRight += b * b
        }
        return covariance / (sqrtf(varianceLeft) * sqrtf(varianceRight))
    }

    /// Zero crossings per second, a cheap and stable stand-in for
    /// brightness: it needs no FFT and it orders the colors correctly.
    private func crossingsPerSecond(_ samples: [Float], seconds: Double) -> Double {
        var crossings = 0
        for index in 1..<samples.count where (samples[index] < 0) != (samples[index - 1] < 0) {
            crossings += 1
        }
        return Double(crossings) / seconds
    }

    private func windowLevels(_ samples: [Float], frames: Int) -> [Float] {
        var levels: [Float] = []
        var start = 0
        while start + frames <= samples.count {
            // Summed in place: slicing a copy per window made the suite
            // spend most of its time allocating.
            var sum: Float = 0
            for index in start..<(start + frames) { sum += samples[index] * samples[index] }
            levels.append(sqrtf(sum / Float(frames)))
            start += frames
        }
        return levels
    }

    func testEverySoundscapeIsGenuinelyStereo() {
        // Every color used to be computed once per frame and written to
        // both channels, which measured 1.0 here and sounded like a
        // point between the ears (user, 2026-08-02, "thin and small").
        // Rain and fire failed this at 0.53 and 0.73 on the first pass
        // too, because a panned voice writes the same waveform twice;
        // they now reach each ear with their own gain and their own
        // delay.
        for (name, scape) in scapes() {
            let (left, right) = scape.renderOffline(seconds: 4)
            let value = correlation(left, right)
            XCTAssertLessThan(
                abs(value), 0.2,
                "\(name) is not really stereo, channels correlate at \(value)")
        }
    }

    func testNoSoundscapeClipsOrDrifts() {
        // The engine clamps, so clipping is silent in the code and
        // audible in the room. Fire peaked at 3.68 before the resonator
        // was normalized: seeding it with an amplitude actually asks for
        // amplitude/sin(w), so low pops came out twenty four times loud.
        for (name, scape) in scapes() {
            let (left, right) = scape.renderOffline(seconds: 8)
            let peak = max(
                left.map { abs($0) }.max() ?? 0,
                right.map { abs($0) }.max() ?? 0)
            XCTAssertLessThanOrEqual(peak, 1.0, "\(name) clips at \(peak)")
            let offset = abs(left.reduce(0, +) / Float(left.count))
            XCTAssertLessThan(offset, 0.005, "\(name) carries a DC offset of \(offset)")
        }
    }

    func testTheSoundscapesAreLevelWithEachOther() {
        // One volume slider serves every chip, so a chip that arrives
        // quiet is a chip the user has to go and fix by hand.
        for (name, scape) in scapes() {
            let (left, _) = scape.renderOffline(seconds: 8)
            let level = rms(left)
            XCTAssertGreaterThan(level, 0.12, "\(name) is quiet at \(level)")
            XCTAssertLessThan(level, 0.30, "\(name) is loud at \(level)")
        }
    }

    func testTheColorsKeepTheirOrderFromWarmToBright() {
        // Brown warm, pink in the middle, white bright, and fire darker
        // than rain. This is the assertion that catches a filter tuned
        // by accident.
        func brightness(_ scape: Soundscape) -> Double {
            crossingsPerSecond(scape.renderOffline(seconds: 4).left, seconds: 10)
        }
        let brown = brightness(ColorNoise(.brown))
        let pink = brightness(ColorNoise(.pink))
        let white = brightness(ColorNoise(.white))
        XCTAssertLessThan(brown, pink)
        XCTAssertLessThan(pink, white)
        XCTAssertLessThan(brightness(FireScape()), brightness(RainScape()))
    }

    func testNoSoundscapeEverFallsSilent() {
        // The failure mode of a texture built from scattered events is
        // a hole in it. A tenth of a second of near silence is a hole.
        for (name, scape) in scapes() {
            let (left, _) = scape.renderOffline(seconds: 12)
            let quietest = windowLevels(left, frames: 4800).min() ?? 0
            XCTAssertGreaterThan(
                quietest, 0.04,
                "\(name) drops to \(quietest) for a tenth of a second")
        }
    }

    func testFireActuallyCracklesAndTheColorsDoNot() {
        // Proves the events fire at all. A steady bed sits near 1; fire
        // measured 3.06 and white 1.14, so the gap is the crackle.
        func burstiness(_ scape: Soundscape) -> Float {
            let levels = windowLevels(scape.renderOffline(seconds: 12).left, frames: 480)
                .sorted()
            return levels.last! / levels[levels.count / 2]
        }
        XCTAssertGreaterThan(burstiness(FireScape()), 2.0, "fire is not crackling")
        XCTAssertGreaterThan(burstiness(RainScape()), 1.35, "rain has no droplets in it")
        XCTAssertLessThan(burstiness(ColorNoise(.white)), 1.5)
    }

    func testTheEngineEitherRunsOrSaysWhyNot() {
        // The offline measurements prove the generators; this proves the
        // wiring around them. A lit chip over silence is the one failure
        // the user cannot debug, so the engine owes an answer either
        // way. Volume is zeroed first: a test suite must not make noise.
        for color in NoiseEngine.NoiseColor.allCases {
            let engine = NoiseEngine()
            engine.setVolume(0)
            var reason: String?
            engine.onSilence = { reason = $0 }
            engine.start(color)
            XCTAssertTrue(
                engine.isRunning || reason != nil,
                "\(color.rawValue) neither played nor explained itself")
            engine.stop()
        }
    }

    func testTheSameSeedRendersTheSameAudio() {
        // The generators are seeded rather than reaching for the system
        // RNG, both because the render thread must not gamble on a
        // syscall and because every measurement above would be noise
        // without it.
        let first = RainScape(seed: 99).renderOffline(seconds: 1).left
        let second = RainScape(seed: 99).renderOffline(seconds: 1).left
        XCTAssertEqual(first, second)
        let other = RainScape(seed: 100).renderOffline(seconds: 1).left
        XCTAssertNotEqual(first, other)
    }

    // MARK: Battery panel (duration formatting, and the not-yet-known case)

    private static func battery(
        state: SystemStatsController.Battery.State, minutes: Int?
    ) -> SystemStatsController.Battery {
        SystemStatsController.Battery(
            level: 50, state: state, pluggedIn: state != .discharging, minutesRemaining: minutes)
    }

    func testBatteryTimeLineFormatsAKnownDuration() {
        XCTAssertEqual(
            BatteryPanel.timeLine(for: Self.battery(state: .discharging, minutes: 135)),
            "2h 15m left")
        XCTAssertEqual(
            BatteryPanel.timeLine(for: Self.battery(state: .charging, minutes: 45)),
            "Full in 45 min")
    }

    func testBatteryTimeLineNeverShowsTheStillCalculatingSentinelAsANumber() {
        // macOS reports -1 for a few seconds after any plug or unplug
        // while it works out the real figure; that must never reach
        // the screen as "-1 min" or "0:00".
        XCTAssertEqual(
            BatteryPanel.timeLine(for: Self.battery(state: .discharging, minutes: -1)),
            "Still working out how long that'll last")
        XCTAssertEqual(
            BatteryPanel.timeLine(for: Self.battery(state: .charging, minutes: -1)),
            "Still working out when it'll be full")
    }

    func testBatteryTimeLineIsNilWhenThereIsNoNumberToShow() {
        XCTAssertNil(BatteryPanel.timeLine(for: Self.battery(state: .full, minutes: nil)))
        XCTAssertNil(BatteryPanel.timeLine(for: Self.battery(state: .notCharging, minutes: nil)))
    }

    func testBatteryHealthLineOmitsWhateverIsntActuallyKnown() {
        XCTAssertEqual(
            BatteryPanel.healthLine(.init(cycleCount: 182, condition: "Normal")),
            "182 cycles · Normal")
        XCTAssertEqual(BatteryPanel.healthLine(.init(cycleCount: 1, condition: nil)), "1 cycle")
        XCTAssertNil(BatteryPanel.healthLine(.init(cycleCount: nil, condition: nil)))
    }
}

/// A sound source that always succeeds and never goes silent, which is
/// the one thing a real `NoiseEngine` cannot promise: on a machine with
/// no audio output it fails to start and reports that failure on a
/// later main-actor hop.
///
/// Records what it was asked to do, so the focus/ambience rules can be
/// stated as what they actually are, which is a claim about which
/// object calls which method.
final class RecordingAmbienceSource: AmbienceSource {
    var onSilence: ((String) -> Void)?
    private(set) var calls: [String] = []

    func start(_ color: NoiseEngine.NoiseColor) { calls.append("start(\(color.rawValue))") }
    func stop() { calls.append("stop") }
    func pause() { calls.append("pause") }
    func resume() { calls.append("resume") }
    func setVolume(_ volume: Float) { calls.append("setVolume") }
    /// The stranger's first run: every silent refusal now says why
    /// (2026-08-31). Pure, so the sentences themselves are pinned.
    @available(macOS 26, *)
    func testTheAppSaysWhyItDidNothing() {
        XCTAssertTrue(DictationController.excuse(for: .checking).contains("moment"))
        XCTAssertTrue(DictationController.excuse(for: .downloading(fraction: 0.4)).contains("40%"))
        XCTAssertFalse(DictationController.excuse(for: .downloading(fraction: 0)).contains("%"))
        XCTAssertTrue(DictationController.excuse(for: .unsupported(requested: "en-IE")).contains("en-IE"))
        XCTAssertTrue(DictationController.excuse(for: .failed(reason: "x")).contains("did not load"))
    }

}
