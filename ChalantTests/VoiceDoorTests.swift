import XCTest

@testable import Chalant

/// The bug 1.12.3 shipped: a voice feature with no door anybody could
/// see. Reported by the first outside download, who read the welcome
/// tour's "Tap the mic", found no mic anywhere in the app, and said
/// Chalant had no voice dictation.
@MainActor
final class VoiceDoorTests: XCTestCase {

    /// The test that would have caught it. A fresh install binds no
    /// hotkey (`HotKeyCenter` registers no defaults anywhere), so unless
    /// something visible draws a mic the only way in is a 0.32s
    /// press-and-hold on the island that nothing on screen mentions.
    func testAFreshInstallHasAVoiceControlYouCanSee() {
        XCTAssertTrue(VoiceDoor.hasVisibleControl(hotkeyBound: false, dictationAvailable: false))
    }

    /// Why it went unnoticed: the app still had a mic the whole time, in
    /// the one surface the dark-ship hides. A control behind a hidden
    /// feature is not a door, and must never be counted as one.
    func testTheDarkShippedSessionMicIsNotADoor() {
        XCTAssertEqual(
            VoiceDoor.shipped(hotkeyBound: false, dictationAvailable: false).contains(.sessionCardMic),
            FeatureFlags.sessionsVisible)
    }

    /// A hotkey is a door only once it is bound, and it is invisible
    /// either way: a key nobody set is not how a new user finds voice.
    func testAnUnboundHotkeyIsNoDoorAndABoundOneIsStillInvisible() {
        XCTAssertFalse(VoiceDoor.shipped(hotkeyBound: false, dictationAvailable: false).contains(.talkHotkey))
        XCTAssertTrue(VoiceDoor.shipped(hotkeyBound: true, dictationAvailable: false).contains(.talkHotkey))
        XCTAssertFalse(VoiceDoor.talkHotkey.isVisibleControl)
        XCTAssertFalse(VoiceDoor.holdTheIsland.isVisibleControl)
    }

    /// Holding the island always works and is never enough on its own:
    /// it is the gesture the tour has to name when nothing is drawn.
    func testHoldingTheIslandIsAlwaysADoor() {
        XCTAssertTrue(VoiceDoor.shipped(hotkeyBound: false, dictationAvailable: false).contains(.holdTheIsland))
    }

    /// The mic is only half a door if what it opens strands you. The
    /// listening surface is the same one the hold uses, and it told
    /// everybody to release something they were never holding.
    func testAClickedSessionIsNotToldToReleaseAnything() {
        XCTAssertEqual(VoiceDoor.finishHint(held: true), "RELEASE TO RUN")
        XCTAssertEqual(VoiceDoor.finishHint(held: false), "TAP TO RUN")
    }

    /// The half of the bug that misled the user rather than merely
    /// hiding from them: the tour may not promise a mic the build does
    /// not draw. Copy and control move together or this fails.
    func testTheTourNeverPromisesAMicThatIsNotDrawn() {
        let promisesMic = VoiceDoor.welcomeLine.localizedCaseInsensitiveContains("mic")
        XCTAssertEqual(promisesMic, VoiceDoor.hasVisibleControl(hotkeyBound: false, dictationAvailable: false))
    }

    // MARK: - Dictation, added by the merge

    /// Dictation is a door only where the engine exists. `SpeechTranscriber`
    /// is macOS 26 with no backport, so below that the hold does nothing and
    /// counting it would be the same lie as counting a mic nobody draws.
    func testDictationIsADoorOnlyWhereTheEngineExists() {
        XCTAssertFalse(
            VoiceDoor.shipped(hotkeyBound: false, dictationAvailable: false).contains(.dictationHold))
        XCTAssertTrue(
            VoiceDoor.shipped(hotkeyBound: false, dictationAvailable: true).contains(.dictationHold))
    }

    /// 1.12.3's exact shape, guarded ahead of time. Dictation is a hold with
    /// nothing drawn, so it must add exactly one door, that door must be
    /// invisible, and it must not change the answer to "can a new user see a
    /// way in". If someone later makes dictation count as a visible control,
    /// this fails, which is the entire point of the file.
    func testDictationAddsOneInvisibleDoorAndCannotRescueAMicLessBuild() {
        let without = VoiceDoor.shipped(hotkeyBound: false, dictationAvailable: false)
        let with = VoiceDoor.shipped(hotkeyBound: false, dictationAvailable: true)

        XCTAssertEqual(with.subtracting(without), [.dictationHold])
        XCTAssertFalse(VoiceDoor.dictationHold.isVisibleControl)
        XCTAssertEqual(
            VoiceDoor.hasVisibleControl(hotkeyBound: false, dictationAvailable: true),
            VoiceDoor.hasVisibleControl(hotkeyBound: false, dictationAvailable: false),
            "dictation must never change whether a new user can see how to start")
    }

    /// A gesture nothing mentions is not a door a person can find: that is
    /// how the last one was lost. A build that can dictate owes the user a
    /// sentence, and that sentence has to name the actual key.
    func testDictationEitherShipsWithInstructionsOrDoesNotShip() {
        XCTAssertNil(VoiceDoor.dictationLine(available: false))

        let line = VoiceDoor.dictationLine(available: true)
        XCTAssertNotNil(line)
        XCTAssertTrue(
            line?.localizedCaseInsensitiveContains("option") == true,
            "copy that does not name the key is not instructions")
    }
}
