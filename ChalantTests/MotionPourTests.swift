import SwiftUI
import XCTest

@testable import Chalant

/// Round 2 of the premium finish: the pour. These tests pin the shape's
/// animatable surface so a corner can never again snap while the rest
/// of the island glides (the pill's top radius did exactly that).
@MainActor
final class MotionPourTests: XCTestCase {
    func testEveryShapeParameterRidesTheAnimation() {
        var shape = IslandShape(eave: 12, bottomRadius: 16, belly: 0)
        shape.topRadius = 16
        shape.tipRadius = 5
        var data = shape.animatableData
        data.first.first = 22          // eave
        data.first.second = 40         // bottomRadius
        data.second.first.first = 0    // belly
        data.second.first.second = 30  // topRadius
        data.second.second = 8         // tipRadius
        shape.animatableData = data
        XCTAssertEqual(shape.eave, 22)
        XCTAssertEqual(shape.bottomRadius, 40)
        XCTAssertEqual(shape.belly, 0)
        XCTAssertEqual(shape.topRadius, 30)
        XCTAssertEqual(shape.tipRadius, 8)
    }

    func testACrashIsMarkedSeenWithoutForgettingItThisSession() {
        // Its own domain on purpose: this bundle runs inside the app,
        // so `standard` here is the founder's real preferences, and a
        // test that cleared this key re-armed the crash banner on
        // their machine every time the suite ran.
        let suite = "chalant.tests.crashseen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let date = Date(timeIntervalSince1970: 1_754_500_000)
        CrashWatch.markSeen(date, in: defaults)
        XCTAssertEqual(defaults.object(forKey: "chalant.crashSeenAt") as? Date, date)
        defaults.removePersistentDomain(forName: suite)
    }

    func testAFreshSeekHoldsTheBarAtItsTarget() {
        let now = Date()
        XCTAssertEqual(
            MusicRow.displayPosition(live: 84, pending: (target: 140, at: now), now: now),
            140)
    }

    func testTheSeekReleasesOnceThePlayerCatchesUp() {
        let now = Date()
        XCTAssertEqual(
            MusicRow.displayPosition(
                live: 139.2, pending: (target: 140, at: now), now: now),
            139.2, "within two seconds of the target, the live clock rules again")
    }

    func testTheSeekNeverHoldsLongerThanThreeSeconds() {
        let then = Date(timeIntervalSinceNow: -3.5)
        XCTAssertEqual(
            MusicRow.displayPosition(live: 84, pending: (target: 140, at: then), now: Date()),
            84, "a player that never catches up gets the truth back after 3s")
    }

    /// The day's two sources ship ON, because the welcome tour asks for
    /// both permissions and macOS asks again: a third, silent gate only
    /// hid the feature those grants were for. An explicit false is
    /// still honoured forever.
    func testTheDaysSourcesAreOnUntilSomebodyTurnsThemOff() {
        let suite = "chalant.tests.day.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        XCTAssertTrue(EventKitService.showsCalendar(in: defaults), "unset means on")
        XCTAssertTrue(EventKitService.showsReminders(in: defaults), "unset means on")

        defaults.set(false, forKey: "showCalendar")
        defaults.set(false, forKey: "showReminders")
        XCTAssertFalse(EventKitService.showsCalendar(in: defaults))
        XCTAssertFalse(EventKitService.showsReminders(in: defaults))

        defaults.set(true, forKey: "showCalendar")
        XCTAssertTrue(EventKitService.showsCalendar(in: defaults))
        defaults.removePersistentDomain(forName: suite)
    }

    /// The Displays sliders do not start at zero (inner padding runs
    /// 8...36, and kin), which the volume call sites never exercised.
    func testThinSliderMathHandlesARangeThatDoesNotStartAtZero() {
        XCTAssertEqual(ThinSlider.value(atX: 0, width: 180, in: 8...36), 8)
        XCTAssertEqual(ThinSlider.value(atX: 90, width: 180, in: 8...36), 22)
        XCTAssertEqual(ThinSlider.value(atX: 180, width: 180, in: 8...36), 36)
        XCTAssertEqual(ThinSlider.value(atX: -40, width: 180, in: 8...36), 8)
    }

    func testThinSliderMathMapsAndClampsAcrossItsRange() {
        XCTAssertEqual(ThinSlider.value(atX: 42, width: 84, in: 0...100), 50)
        XCTAssertEqual(ThinSlider.value(atX: -5, width: 84, in: 0...100), 0)
        XCTAssertEqual(ThinSlider.value(atX: 200, width: 84, in: 0...1), 1)
        XCTAssertEqual(ThinSlider.value(atX: 10, width: 0, in: 0...1), 0)
    }

    /// The finish reached the settings window (round 4): the group
    /// label is the island's own quiet mono voice, and the card draws
    /// no box. Pinned because a boxed card is the one thing that made
    /// the window read as a different app than the island.
    func testTheSettingsFinishTokensExist() {
        XCTAssertEqual(Theme.Space.settingsRow, 13)
        XCTAssertEqual(Theme.Space.settingsGroup, 30)
        _ = Theme.Fonts.groupLabel
    }
}
