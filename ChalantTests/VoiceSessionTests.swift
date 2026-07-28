import XCTest
@testable import Chalant

/// The two crashes of the month, replayed as ordinary tests.
///
/// Neither of these could be written before. Both decisions lived inside
/// `VoiceController` next to `AVAudioEngine` and a real microphone, so
/// reaching them meant a person holding the notch with the right timing
/// and the right permission state. That is why they shipped.
@MainActor
final class VoiceSessionTests: XCTestCase {

    // MARK: The crash: a grant that arrives for a session nobody wants

    func testAGrantArrivingAfterTheHoldEndedIsRefused() {
        // Press and hold on a fresh install. The permission dialog goes
        // up and no capture has started yet.
        var session = VoiceSession()
        let (held, _) = session.begin()
        XCTAssertTrue(session.stillWanted(held))

        // The user lets go while the dialog is still on screen.
        session.end()

        // They click Allow. This is the moment that used to walk all the
        // way into startCapture and leave the microphone live with
        // nobody listening, until the next hold installed a second tap
        // on the same bus and the app died.
        XCTAssertFalse(session.stillWanted(held))
    }

    func testAGrantIsRefusedAfterACancelAndAfterAReplacement() {
        var cancelled = VoiceSession()
        let (a, _) = cancelled.begin()
        cancelled.cancel()
        XCTAssertFalse(cancelled.stillWanted(a))

        // Starting a second session must also strand the first one's
        // pending grant, not just ending one.
        var replaced = VoiceSession()
        let (first, _) = replaced.begin()
        let (second, _) = replaced.begin()
        XCTAssertFalse(replaced.stillWanted(first))
        XCTAssertTrue(replaced.stillWanted(second))
    }

    func testAGrantForTheLiveSessionIsStillHonoured() {
        // The guard must not be so eager that it refuses the ordinary
        // case, which is the whole feature.
        var session = VoiceSession()
        let (live, _) = session.begin()
        XCTAssertTrue(session.stillWanted(live))
        // A device hop rebuilds the capture chain inside the same
        // session, so the number must not move underneath it.
        session.tapRemoved()
        session.tapInstalled()
        XCTAssertTrue(session.stillWanted(live))
    }

    // MARK: The deafness: a finalize abandoned by the next session

    func testStartingASessionMidFinalizeReportsTheAbandonment() {
        // Tap to talk, tap to run: a finalize is now outstanding and
        // somebody is waiting on its completion.
        var session = VoiceSession()
        session.begin()
        session.end()
        XCTAssertTrue(session.awaitingFinalize)

        // A third tap inside the 1.2 second window starts a new session
        // and drops that completion on the floor. Whoever was waiting
        // has to be told, because the completion was the only thing that
        // would ever have released them; unreleased, the island refused
        // every later question in silence until relaunch.
        let (_, abandoned) = session.begin()
        XCTAssertTrue(abandoned)
        XCTAssertFalse(session.awaitingFinalize)
    }

    func testAnOrdinarySessionReportsNoAbandonment() {
        var session = VoiceSession()
        XCTAssertFalse(session.begin().abandonedFinalize)
        session.end()
        XCTAssertTrue(session.claimFinalize())
        // Delivered cleanly, so the next session abandons nothing.
        XCTAssertFalse(session.begin().abandonedFinalize)
    }

    func testAFinalizeIsClaimedExactlyOnce() {
        // The 1.2 second timeout and the recognizer's own callback race
        // each other, and both call deliver. Running a completion twice
        // is a second answer to a question asked once.
        var session = VoiceSession()
        session.begin()
        session.end()
        XCTAssertTrue(session.claimFinalize())
        XCTAssertFalse(session.claimFinalize())
        XCTAssertFalse(session.claimFinalize())
    }

    func testNothingCanBeClaimedWithoutAFinalize() {
        var session = VoiceSession()
        XCTAssertFalse(session.claimFinalize())
        session.begin()
        // Still holding: there is no transcript to hand anybody yet.
        XCTAssertFalse(session.claimFinalize())
        session.cancel()
        XCTAssertFalse(session.claimFinalize())
    }

    // MARK: The invariant behind the uncatchable exception

    func testTapOwnershipTracksInstallAndRemoval() {
        // Installing a second tap on an occupied bus raises an
        // Objective-C exception, which Swift cannot catch: the app does
        // not fail there, it ends.
        var session = VoiceSession()
        XCTAssertFalse(session.ownsTap)
        session.begin()
        session.tapInstalled()
        XCTAssertTrue(session.ownsTap)
        session.tapRemoved()
        XCTAssertFalse(session.ownsTap)
    }

    // MARK: The sequences that actually happened

    func testTheFullCrashSequenceEndsWithNothingWanted() {
        // Fresh install, first ever hold, released while the dialog is
        // up, then Allow, then a second hold.
        var session = VoiceSession()
        let (firstHold, _) = session.begin()
        session.end()
        XCTAssertFalse(session.stillWanted(firstHold), "the late grant must stand down")

        let (secondHold, abandoned) = session.begin()
        XCTAssertTrue(abandoned, "the first hold's finalize was still outstanding")
        XCTAssertTrue(session.stillWanted(secondHold))
        XCTAssertFalse(session.stillWanted(firstHold))
    }

    func testTheDeafnessSequenceLeavesNoOutstandingFinalize() {
        // Tap, tap, tap inside the window, then click away.
        var session = VoiceSession()
        session.begin()
        session.end()
        let (_, abandoned) = session.begin()
        XCTAssertTrue(abandoned)
        session.cancel()
        // Nothing is owed to anybody, and nothing is pending that could
        // quietly hold the island shut.
        XCTAssertFalse(session.awaitingFinalize)
        XCTAssertEqual(session.phase, .idle)
    }

    func testGenerationsNeverRepeatAcrossAnyMixOfTransitions() {
        // A repeated number would let a stale grant look current again.
        var session = VoiceSession()
        var seen: Set<Int> = [session.generation]
        for step in 0..<200 {
            let next: Int
            switch step % 3 {
            case 0: next = session.begin().generation
            case 1: next = session.end()
            default: next = session.cancel()
            }
            XCTAssertFalse(seen.contains(next), "generation \(next) came round again")
            seen.insert(next)
        }
    }
}
