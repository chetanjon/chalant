import XCTest

@testable import Chalant

/// The switch that decides whether hold-to-dictate exists on this machine.
///
/// Every case here runs against its own defaults suite. Touching
/// `UserDefaults.standard` from a test edits the settings of the app the
/// developer is actually running.
@MainActor
final class DictationTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "com.cj.chalant.tests.dictation"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    /// Off until asked for. Starting dictation installs an event tap, and that
    /// is what raises the Input Monitoring and Accessibility prompts, so a
    /// default of on would ambush everyone who merely updated Chalant.
    func testDictationIsOffUntilSomebodyAsksForIt() {
        XCTAssertFalse(Dictation.isEnabled(in: defaults))
        XCTAssertFalse(Dictation.isOpen(in: defaults))
    }

    func testTheSwitchPersists() {
        Dictation.setEnabled(true, in: defaults)
        XCTAssertTrue(Dictation.isEnabled(in: defaults))

        Dictation.setEnabled(false, in: defaults)
        XCTAssertFalse(Dictation.isEnabled(in: defaults))
    }

    /// Two conditions, both required. The OS has to have the engine and the
    /// user has to have said yes; either one missing means there is no door,
    /// and `isOpen` is the only thing allowed to answer that question.
    func testOpenNeedsBothTheEngineAndConsent() {
        Dictation.setEnabled(true, in: defaults)
        XCTAssertEqual(Dictation.isOpen(in: defaults), Dictation.isSupported)

        Dictation.setEnabled(false, in: defaults)
        XCTAssertFalse(
            Dictation.isOpen(in: defaults),
            "consent withdrawn has to close the door even where the engine exists")
    }

    /// The join that matters: what `Dictation` decides is what `VoiceDoor` is
    /// told. If these two ever disagree, the app has a door its own registry
    /// does not know about, which is precisely the 1.12.3 failure.
    func testTheDoorRegistryAgreesWithTheSwitch() {
        Dictation.setEnabled(false, in: defaults)
        XCTAssertFalse(
            VoiceDoor.shipped(hotkeyBound: false, dictationAvailable: Dictation.isOpen(in: defaults))
                .contains(.dictationHold))

        Dictation.setEnabled(true, in: defaults)
        XCTAssertEqual(
            VoiceDoor.shipped(hotkeyBound: false, dictationAvailable: Dictation.isOpen(in: defaults))
                .contains(.dictationHold),
            Dictation.isSupported)
    }

    /// A switched-off machine must not be running anything, and asking it to
    /// start must stay silent rather than throw or half-build a stack.
    func testStartingWhileSwitchedOffDoesNothing() {
        Dictation.setEnabled(false, in: defaults)

        let dictation = Dictation()
        dictation.start(defaults: defaults)

        XCTAssertFalse(dictation.isRunning)
        XCTAssertFalse(dictation.tapInstalled)
    }

    /// Stop is safe on something that never started. The standalone build
    /// wedged once by leaving a tap alive with nothing able to clear it, so
    /// the teardown path is exercised even in the trivial case.
    func testStoppingSomethingThatNeverStartedIsSafe() {
        let dictation = Dictation()
        dictation.stop()
        XCTAssertFalse(dictation.isRunning)
    }
}
