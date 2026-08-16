import XCTest
@testable import Chalant

@MainActor
final class DictationStripTests: XCTestCase {

    // MARK: - Level formulas (spec, "Motion")

    func testRimAtSilenceIsTheRestingRim() {
        let rim = DictationStripLevel.rim(0)
        XCTAssertEqual(rim.radius, 2, accuracy: 0.001)
        XCTAssertEqual(rim.opacity, 0.10, accuracy: 0.001)
    }

    func testRimAtFullReachesTheMaxima() {
        let rim = DictationStripLevel.rim(1)
        XCTAssertEqual(rim.radius, 24, accuracy: 0.001)
        XCTAssertEqual(rim.opacity, 0.65, accuracy: 0.001)
    }

    func testPoolIsInvisibleAtSilenceAndCappedAtFull() {
        XCTAssertEqual(DictationStripLevel.pool(0), 0, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.pool(1), 0.22, accuracy: 0.001)
    }

    func testDotGrowsFromSixToTwelve() {
        XCTAssertEqual(DictationStripLevel.dot(0).diameter, 6, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.dot(1).diameter, 12, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.dot(0).glow, 4, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.dot(1).glow, 18, accuracy: 0.001)
    }

    /// The audio engine reports raw peak, which can exceed 1 on a hot mic
    /// and be negative on a broken one. The formulas must never be fed
    /// either.
    func testLevelIsClampedBeforeUse() {
        XCTAssertEqual(DictationStripLevel.clamp(-0.5), 0)
        XCTAssertEqual(DictationStripLevel.clamp(3.0), 1)
        XCTAssertEqual(DictationStripLevel.clamp(0.4), 0.4, accuracy: 0.0001)
        XCTAssertEqual(DictationStripLevel.rim(3.0).radius, 24, accuracy: 0.001)
    }

    /// The headroom, without which the strip barely moves during speech: a
    /// built-in mic's raw peak rarely passes 0.3, and 0.3 has to look like a
    /// voice, not like silence.
    func testNormalizeGivesABuiltInMicItsHeadroom() {
        XCTAssertEqual(DictationStripLevel.normalize(peak: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(DictationStripLevel.normalize(peak: 0.3), 0.96, accuracy: 0.0001)
        XCTAssertEqual(DictationStripLevel.normalize(peak: 1.0), 1, accuracy: 0.0001)
        // A broken mic can report a negative sample; the strip shows silence,
        // never a rim that lights up from below zero.
        XCTAssertEqual(DictationStripLevel.normalize(peak: -0.2), 0, accuracy: 0.0001)
    }

    // MARK: - Which display (spec, "Which display")

    private let a: CGDirectDisplayID = 1, b: CGDirectDisplayID = 2, c: CGDirectDisplayID = 3

    func testTheTargetAppsDisplayWinsOverEverything() {
        let picked = DictationDisplay.resolve(
            target: a, pointerOn: b, main: c, any: c, isOff: { _ in false })
        XCTAssertEqual(picked, a)
    }

    func testFallsBackToThePointerThenMainThenAny() {
        XCTAssertEqual(DictationDisplay.resolve(target: nil, pointerOn: b, main: c, any: a, isOff: { _ in false }), b)
        XCTAssertEqual(DictationDisplay.resolve(target: nil, pointerOn: nil, main: c, any: a, isOff: { _ in false }), c)
        XCTAssertEqual(DictationDisplay.resolve(target: nil, pointerOn: nil, main: nil, any: a, isOff: { _ in false }), a)
        XCTAssertNil(DictationDisplay.resolve(target: nil, pointerOn: nil, main: nil, any: nil, isOff: { _ in false }))
    }

    /// A screen the user has set to "Off" gets no island, so the strip must
    /// go to the next fallback rather than nowhere.
    func testSkipsADisplayWhoseIslandIsOff() {
        let picked = DictationDisplay.resolve(
            target: a, pointerOn: b, main: c, any: c, isOff: { $0 == a })
        XCTAssertEqual(picked, b)
    }

    func testEveryDisplayOffMeansNowhere() {
        XCTAssertNil(DictationDisplay.resolve(target: a, pointerOn: b, main: c, any: c, isOff: { _ in true }))
    }

    // MARK: - .dictating is an owned expansion, like .listening

    func testDictatingRendersOnlyOnItsOwnerDisplay() {
        XCTAssertEqual(NotchViewModel.state(.dictating, expandedOn: a, face: a), .dictating)
        XCTAssertEqual(NotchViewModel.state(.dictating, expandedOn: a, face: b), .collapsed)
        XCTAssertEqual(NotchViewModel.state(.dictating, expandedOn: nil, face: a), .collapsed)
    }

    // MARK: - The hold, on a real view model

    func testBeginDictatingFromCollapsedOpensTheStripOnItsDisplay() {
        let model = NotchViewModel()
        model.beginDictating(into: "TextEdit", mic: "MacBook Pro Microphone", on: a)
        XCTAssertEqual(model.state, .dictating)
        XCTAssertEqual(model.expandedDisplayID, a)
        XCTAssertEqual(model.dictationInfo?.appName, "TextEdit")
        XCTAssertEqual(model.dictationInfo?.micName, "MacBook Pro Microphone")
        XCTAssertEqual(model.dictationLevel, 0)
    }

    func testEndDictatingPutsEverythingBack() {
        let model = NotchViewModel()
        model.beginDictating(into: "TextEdit", mic: nil, on: a)
        model.updateDictating(level: 0.7, mic: "AirPods")
        XCTAssertEqual(model.dictationLevel, 0.7, accuracy: 0.0001)
        XCTAssertEqual(model.dictationInfo?.micName, "AirPods")

        model.endDictating()
        XCTAssertEqual(model.state, .collapsed)
        XCTAssertNil(model.dictationInfo)
        XCTAssertEqual(model.dictationLevel, 0)
        XCTAssertNil(model.expandedDisplayID)
    }

    /// The meter timer can fire once more after the key came up. Nothing it
    /// says may reopen anything.
    func testUpdateDictatingIsANoOpOutsideTheHold() {
        let model = NotchViewModel()
        model.updateDictating(level: 0.9, mic: "AirPods")
        XCTAssertEqual(model.dictationLevel, 0)
        XCTAssertNil(model.dictationInfo)
        XCTAssertEqual(model.state, .collapsed)
    }

    /// I1: refusing an island that was already open reproduced the complaint
    /// the strip exists to answer. An agent finishes, the island opens by
    /// itself, the founder holds the key and used to see nothing at all.
    func testBeginDictatingTakesOverAnOpenIsland() {
        let model = NotchViewModel()
        model.state = .expanded
        model.beginDictating(into: "Slack", mic: nil, on: a)
        XCTAssertEqual(model.state, .dictating)
        XCTAssertEqual(model.expandedDisplayID, a)
        XCTAssertEqual(model.dictationInfo?.appName, "Slack")
    }

    /// The one state it must still refuse: a live voice session owns the ear,
    /// and taking it over would leave `VoiceController` recognizing behind a
    /// strip that says dictation.
    func testBeginDictatingRefusesOverALiveVoiceSession() {
        let model = NotchViewModel()
        model.state = .listening
        model.beginDictating(into: "Slack", mic: nil, on: a)
        XCTAssertEqual(model.state, .listening)
        XCTAssertNil(model.dictationInfo)
    }

    /// C3: the mic button and the `.talk` shortcut both land here, and
    /// "anything that is not listening means start" used to send a live hold
    /// into `voice.begin()`. Two recognizers at once is the doubled-text
    /// failure the sibling state exists to prevent.
    func testTalkIsRefusedWhileAHoldIsLive() {
        let model = NotchViewModel()
        model.beginDictating(into: "TextEdit", mic: nil, on: a)
        model.toggleListening()
        XCTAssertEqual(model.state, .dictating)
        XCTAssertNotNil(model.dictationInfo)
    }

    func testALiveMicIsEitherKind() {
        let model = NotchViewModel()
        XCTAssertFalse(model.micIsLive)
        model.state = .listening
        XCTAssertTrue(model.micIsLive)
        model.state = .dictating
        XCTAssertTrue(model.micIsLive)
        model.state = .expanded
        XCTAssertFalse(model.micIsLive)
    }

    /// C2, the one that matters. Every site that could expand over a hold now
    /// refuses, because an expansion mid-hold makes the key-up a no-op:
    /// `endDictating` guards on the state, so `restoreTheRoom()` never runs
    /// and the music stays paused with nothing left to start it again.
    ///
    /// A drop is the one of those sites reachable without the window
    /// controller. It writes a clip only if the guard has regressed, which is
    /// also the case where this test fails.
    func testADropMidHoldCannotExpandOverTheStrip() {
        let model = NotchViewModel()
        model.beginDictating(into: "TextEdit", mic: nil, on: a)
        model.receiveDrop([.text("dictation strip guard probe")])
        XCTAssertEqual(model.state, .dictating)

        // And the key-up still finds a hold to end, which is the whole point:
        // the room goes back the way it came.
        model.endDictating()
        XCTAssertEqual(model.state, .collapsed)
        XCTAssertNil(model.dictationInfo)
        XCTAssertEqual(model.dictationLevel, 0)
        XCTAssertNil(model.expandedDisplayID)
    }
}
