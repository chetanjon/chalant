import Testing

@testable import ChalantDictationCore

/// The key's own state machine, and the wedge it exists to make impossible.
///
/// Measured on 2026-08-12, on the founder's machine, after the app had been up
/// three hours: pressing left Option produced `keyDown entered` and
/// `keyUp entered, listening=true` and then nothing at all, forever. The app
/// was deaf until relaunch. Which guard fired names the state exactly: the
/// press was refused because a session was already believed live, and the
/// release was refused because the transcriber was already gone.
///
/// `keyDown` marked itself listening LAST, after ~183ms of async setup
/// (permission, format, prepare, begin), so a release landing inside that
/// window found `isListening` still false, was dropped, and left the app
/// listening with the key already up. Nothing could clear it.
///
/// This type holds the decision and nothing else, so the race is a test rather
/// than a three-hour reproduction on real hardware.
@Suite("PushToTalk")
struct PushToTalkTests {

    @Test("the ordinary hold: press, setup, talk, release")
    func ordinaryHold() {
        var key = PushToTalk()
        #expect(key.press() == .begin)
        #expect(key.ready() == .capture)
        #expect(key.state == .listening)
        #expect(key.release() == .finish)
        #expect(key.state == .idle)
    }

    /// THE BUG. A release arriving while the session is still being set up
    /// used to be dropped on the floor, and setup then completed into a
    /// listening state nobody could leave.
    @Test("a release during setup is remembered, not dropped")
    func releaseDuringSetupIsRemembered() {
        var key = PushToTalk()
        #expect(key.press() == .begin)

        // The finger comes up 100ms in, while prepare/begin are still running.
        #expect(key.release() == .waitForSetup)

        // Setup finishes. The old code went live here and stayed live.
        #expect(key.ready() == .abandon)
        #expect(key.state == .idle)
    }

    /// The consequence that actually cost the day: after the race, every later
    /// press was refused. Whatever else this type does, it must never end a
    /// sequence somewhere a fresh press cannot begin.
    @Test("the app can never be left permanently deaf")
    func neverPermanentlyDeaf() {
        var key = PushToTalk()
        _ = key.press()
        _ = key.release()
        _ = key.ready()

        // The very next press has to work. This is the assertion that would
        // have caught it.
        #expect(key.press() == .begin)
        #expect(key.ready() == .capture)
        #expect(key.release() == .finish)
        #expect(key.state == .idle)
    }

    /// Setup can fail on its own (no microphone grant, assets not ready, the
    /// transcriber refusing to begin). Every one of those must land back at
    /// idle rather than half-armed.
    @Test("a failed setup returns to idle, not to limbo")
    func failedSetupReturnsToIdle() {
        var key = PushToTalk()
        _ = key.press()
        key.setupFailed()
        #expect(key.state == .idle)
        #expect(key.press() == .begin)
    }

    @Test("a failed setup after the key was already released also lands at idle")
    func failedSetupAfterReleaseReturnsToIdle() {
        var key = PushToTalk()
        _ = key.press()
        _ = key.release()
        key.setupFailed()
        #expect(key.state == .idle)
        #expect(key.press() == .begin)
    }

    /// Key repeat and stuck modifiers both send a second down without an up.
    @Test("a second press while live is refused, and says why")
    func secondPressIsRefusedOutLoud() {
        var key = PushToTalk()
        _ = key.press()
        _ = key.ready()

        let decision = key.press()
        #expect(decision.isIgnored)
        #expect(decision.reason?.isEmpty == false)
        // Refusing must not disturb a live session.
        #expect(key.state == .listening)
    }

    @Test("a release with nothing running is refused, and says why")
    func strayReleaseIsRefusedOutLoud() {
        var key = PushToTalk()
        let decision = key.release()
        #expect(decision.isIgnored)
        #expect(decision.reason?.isEmpty == false)
        #expect(key.state == .idle)
    }

    /// Silence is the half of this bug that made it undiagnosable: the app
    /// refused every key for three hours and never once said so. No refusal
    /// may be silent.
    @Test("every refusal carries a reason")
    func everyRefusalCarriesAReason() {
        var live = PushToTalk()
        _ = live.press()
        _ = live.ready()

        var arming = PushToTalk()
        _ = arming.press()

        var stray = PushToTalk()
        let refusals = [
            stray.release(),
            live.press(),
            arming.press(),
        ]
        for refusal in refusals {
            #expect(refusal.isIgnored)
            #expect(refusal.reason?.isEmpty == false)
        }
    }

    /// A second release while the first is still being honoured is not an
    /// error worth acting on twice: finishing twice would finalize a
    /// transcriber that is already gone, which is the other half of the state
    /// the founder's app was found in.
    @Test("a release is honoured once")
    func releaseIsHonouredOnce() {
        var key = PushToTalk()
        _ = key.press()
        _ = key.ready()
        #expect(key.release() == .finish)
        #expect(key.release().isIgnored)
    }
}

/// A hold that turned out to be a shortcut.
///
/// **This is the case `Option+←` needed and never had.** Left Option is a
/// real modifier: moving by word, deleting a word and typing an accented
/// character are all a left-Option press followed by another key, and before
/// 1.42.0 every one of them was the start of a dictation as far as this state
/// machine could tell.
@Suite("PushToTalk cancellation")
struct PushToTalkCancellationTests {

    @Test("another key while arming stands the session down without capturing")
    func cancelWhileArming() {
        var key = PushToTalk()
        #expect(key.press() == .begin)
        guard case .cancel = key.otherKeyPressed() else {
            Issue.record("arming should cancel")
            return
        }
        #expect(key.state == .idle)
        // And setup finishing afterwards must not go live behind the user.
        #expect(key.ready().isIgnored)
        #expect(key.state == .idle)
    }

    @Test("another key while listening cancels, and nothing is transcribed")
    func cancelWhileListening() {
        var key = PushToTalk()
        #expect(key.press() == .begin)
        #expect(key.ready() == .capture)
        guard case .cancel = key.otherKeyPressed() else {
            Issue.record("listening should cancel")
            return
        }
        #expect(key.state == .idle)
        // The release that follows is expected, not a refusal worth an error.
        #expect(key.release() == .ignored(PushToTalk.cancelledReason))
    }

    /// The overwhelming majority of keystrokes. Every key of the day arrives
    /// here with nothing held, and it must cost nothing and say nothing.
    @Test("a key with no hold in flight is ignored")
    func idleIgnoresEverything() {
        var key = PushToTalk()
        #expect(key.otherKeyPressed().isIgnored)
        #expect(key.state == .idle)
        #expect(key.wasCancelled == false)
    }

    /// A cancelled hold must not poison the next one.
    @Test("the next press works normally after a cancellation")
    func theNextPressIsClean() {
        var key = PushToTalk()
        _ = key.press()
        _ = key.otherKeyPressed()
        #expect(key.press() == .begin)
        #expect(key.wasCancelled == false)
        #expect(key.ready() == .capture)
        #expect(key.release() == .finish)
    }

    /// Only one release is excused. A second one is a real refusal again.
    @Test("only the release that follows a cancellation is excused")
    func onlyOneReleaseIsExcused() {
        var key = PushToTalk()
        _ = key.press()
        _ = key.ready()
        _ = key.otherKeyPressed()
        #expect(key.release() == .ignored(PushToTalk.cancelledReason))
        #expect(key.release() == .ignored("nothing was listening"))
    }

    /// A cancel is not a finish: it must never be the decision that
    /// transcribes, because the audio it holds is somebody using a shortcut.
    @Test("cancelling is never finishing")
    func cancelIsNotFinish() {
        var key = PushToTalk()
        _ = key.press()
        _ = key.ready()
        let decision = key.otherKeyPressed()
        #expect(decision != .finish)
        #expect(decision != .abandon)
    }
}
