import XCTest

@testable import Chalant

/// Which ear hears you, and what happens to somebody who already had two.
///
/// Every case runs against its own defaults suite. Touching
/// `UserDefaults.standard` from a test edits the settings of the app the
/// developer is actually running.
@MainActor
final class SpeechEngineChoiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "com.cj.chalant.tests.engine"

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

    /// A fresh install gets the shipped default and nothing else decides it.
    func testAFreshInstallGetsTheShippedDefault() {
        XCTAssertEqual(SpeechEngineChoice.current(in: defaults), SpeechEngineChoice.shipped)
    }

    /// The migration. "Better hearing" meant "run Whisper as a second ear",
    /// and from 1.42.0 there is no second ear, so the model they deliberately
    /// downloaded and switched on becomes their recognizer. Reinterpreting
    /// that as "you probably wanted the new thing" would be the app changing
    /// a setting on their behalf.
    func testSomebodyWhoHadTheSecondEarKeepsThatEar() {
        defaults.set(true, forKey: SpeechEngineChoice.legacyBetterHearingKey)
        XCTAssertEqual(SpeechEngineChoice.current(in: defaults), .whisper)
    }

    /// Off is not a choice about the recognizer, it is the absence of one.
    func testTheSwitchTurnedOffMigratesToNothing() {
        defaults.set(false, forKey: SpeechEngineChoice.legacyBetterHearingKey)
        XCTAssertEqual(SpeechEngineChoice.current(in: defaults), SpeechEngineChoice.shipped)
    }

    /// An explicit choice outranks the old switch, in both directions, so
    /// somebody who migrates and then changes their mind stays changed.
    func testAnExplicitChoiceOutranksTheOldSwitch() {
        defaults.set(true, forKey: SpeechEngineChoice.legacyBetterHearingKey)
        SpeechEngineChoice.set(.apple, in: defaults)
        XCTAssertEqual(SpeechEngineChoice.current(in: defaults), .apple)

        SpeechEngineChoice.set(.parakeet, in: defaults)
        XCTAssertEqual(SpeechEngineChoice.current(in: defaults), .parakeet)
    }

    /// A value written by a newer build, or by a hand at the command line,
    /// must not take dictation down. Falls back rather than crashing.
    func testAnUnknownStoredValueFallsBack() {
        defaults.set("cochlea", forKey: SpeechEngineChoice.key)
        XCTAssertEqual(SpeechEngineChoice.current(in: defaults), SpeechEngineChoice.shipped)
    }

    /// The merge's own kill switch is not a recognizer choice and must not
    /// be read as one. It described a path that no longer exists.
    func testTheOldMergeKeyDecidesNothing() {
        defaults.set(false, forKey: "dictationHearingMerge")
        XCTAssertEqual(SpeechEngineChoice.current(in: defaults), SpeechEngineChoice.shipped)
    }

    /// Only Apple is free. The picker's copy leans on this to say what a
    /// choice costs before it is made.
    func testOnlyAppleNeedsNoModel() {
        XCTAssertFalse(SpeechEngineChoice.apple.needsAModel)
        XCTAssertTrue(SpeechEngineChoice.parakeet.needsAModel)
        XCTAssertTrue(SpeechEngineChoice.whisper.needsAModel)
    }

    /// Every case is offered. A recognizer the picker cannot reach is a
    /// recognizer nobody can leave.
    func testEveryEngineIsReachableFromThePicker() {
        XCTAssertEqual(Set(SpeechEngineChoice.allCases.map(\.rawValue)), ["apple", "parakeet", "whisper"])
        XCTAssertTrue(SpeechEngineChoice.allCases.allSatisfy { !$0.label.isEmpty })
    }
}
