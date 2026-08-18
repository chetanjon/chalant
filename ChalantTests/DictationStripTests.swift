import SwiftUI
import XCTest
@testable import Chalant

@MainActor
final class DictationStripTests: XCTestCase {

    // MARK: - The halo (spec 2026-08-17, "The halo" and "Motion")

    private let tick: TimeInterval = 1.0 / 30

    /// Rule 2: quick to answer, slow to let go. Three meter ticks of voice
    /// (100 ms) lift the level essentially all the way; three ticks of
    /// silence give back only a fraction of it. The attack used to sit at
    /// ~85% after three ticks and the founder felt it as lag (1.17.0).
    func testVoiceRisesFasterThanItFalls() {
        var voice = DictationStripLevel.Voice()
        for _ in 0..<3 { voice.step(raw: 1, dt: tick) }
        XCTAssertGreaterThan(voice.level, 0.95)
        let peak = voice.level
        for _ in 0..<3 { voice.step(raw: 0, dt: tick) }
        XCTAssertEqual(voice.level, 0.71, accuracy: 0.03)
        XCTAssertLessThan(peak - voice.level, peak, "release must be slower than attack")
    }

    /// One tick of voice is already most of the way up: the light must answer
    /// on the first frame it can, not ramp.
    func testVoiceAnswersOnTheFirstTick() {
        var voice = DictationStripLevel.Voice()
        voice.step(raw: 1, dt: tick)
        XCTAssertGreaterThan(voice.level, 0.8)
    }

    /// Rule 3: the longer you talk, the more it fills. A second of talking
    /// lights over half the edge; a few seconds fills it.
    func testFillGrowsWhileTalking() {
        var voice = DictationStripLevel.Voice()
        for _ in 0..<30 { voice.step(raw: 1, dt: tick) }
        XCTAssertGreaterThan(voice.fill, 0.55)
        XCTAssertLessThan(voice.fill, 0.72)
        for _ in 0..<120 { voice.step(raw: 1, dt: tick) }
        XCTAssertEqual(voice.fill, 1, accuracy: 0.0001)
    }

    /// A two-second pause gives back about a quarter of the edge, and never
    /// more than there was.
    func testFillEasesBackInAPause() {
        var voice = DictationStripLevel.Voice()
        for _ in 0..<150 { voice.step(raw: 1, dt: tick) }
        for _ in 0..<60 { voice.step(raw: 0, dt: tick) }
        XCTAssertEqual(voice.fill, 0.76, accuracy: 0.02)
        for _ in 0..<600 { voice.step(raw: 0, dt: tick) }
        XCTAssertEqual(voice.fill, 0, accuracy: 0.0001)
    }

    func testVoiceResetsToSilence() {
        var voice = DictationStripLevel.Voice()
        for _ in 0..<60 { voice.step(raw: 1, dt: tick) }
        voice.reset()
        XCTAssertEqual(voice.level, 0)
        XCTAssertEqual(voice.fill, 0)
    }

    func testHaloAtSilenceIsTheRestingHalo() {
        let h = DictationStripLevel.halo(0)
        XCTAssertEqual(h.outerWidth, 3, accuracy: 0.001)
        XCTAssertEqual(h.outerBlur, 10, accuracy: 0.001)
        XCTAssertEqual(h.outerOpacity, 0.55, accuracy: 0.001)
        XCTAssertEqual(h.bloomWidth, 8, accuracy: 0.001)
        XCTAssertEqual(h.bloomBlur, 22, accuracy: 0.001)
        XCTAssertEqual(h.bloomOpacity, 0.25, accuracy: 0.001)
        XCTAssertEqual(h.coreWidth, 1.0, accuracy: 0.001)
        XCTAssertEqual(h.coreOpacity, 0.55, accuracy: 0.001)
        XCTAssertEqual(h.coreShadow, 4, accuracy: 0.001)
        XCTAssertEqual(h.innerWidth, 8, accuracy: 0.001)
        XCTAssertEqual(h.innerBlur, 8, accuracy: 0.001)
        XCTAssertEqual(h.innerOpacity, 0.14, accuracy: 0.001)
    }

    func testHaloAtFullVoiceReachesTheMaxima() {
        let h = DictationStripLevel.halo(1)
        XCTAssertEqual(h.outerWidth, 8, accuracy: 0.001)
        XCTAssertEqual(h.outerBlur, 34, accuracy: 0.001)
        XCTAssertEqual(h.outerOpacity, 1.0, accuracy: 0.001)
        XCTAssertEqual(h.bloomWidth, 18, accuracy: 0.001)
        XCTAssertEqual(h.bloomBlur, 52, accuracy: 0.001)
        XCTAssertEqual(h.bloomOpacity, 0.70, accuracy: 0.001)
        XCTAssertEqual(h.coreWidth, 2.4, accuracy: 0.001)
        XCTAssertEqual(h.coreOpacity, 1.0, accuracy: 0.001)
        XCTAssertEqual(h.coreShadow, 14, accuracy: 0.001)
        XCTAssertEqual(h.innerBlur, 32, accuracy: 0.001)
        XCTAssertEqual(h.innerOpacity, 0.50, accuracy: 0.001)
    }

    /// The lit portion of the edge: about the middle third at the start of a
    /// hold, the whole edge after a full sentence.
    func testSpreadRunsFromAThirdToEverything() {
        XCTAssertEqual(DictationStripLevel.spread(fill: 0), 0.18, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.spread(fill: 1), 0.60, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.spread(fill: 2), 0.60, accuracy: 0.001)
    }

    /// The audio engine reports raw peak, which can exceed 1 on a hot mic
    /// and be negative on a broken one. The formulas must never be fed
    /// either.
    func testLevelIsClampedBeforeUse() {
        XCTAssertEqual(DictationStripLevel.clamp(-0.5), 0)
        XCTAssertEqual(DictationStripLevel.clamp(3.0), 1)
        XCTAssertEqual(DictationStripLevel.clamp(0.4), 0.4, accuracy: 0.0001)
        XCTAssertEqual(DictationStripLevel.halo(3.0).outerBlur, 34, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.halo(-1).outerBlur, 10, accuracy: 0.001)
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

    // MARK: - The strip is sized to what it holds (round four, "too big")

    /// 320 wide everywhere; only as tall as the screen's notch needs above one
    /// row of `Fonts.micro`. A pill display (reserve 8) gets 41, a notch
    /// display (reserve 32) gets 65. The old fixed 520 × 68 was mostly empty
    /// black on the founder's external monitor.
    func testStripIsSizedToItsRow() {
        let pill = DictationStripLevel.stripSize(topReserve: Theme.Space.m)
        XCTAssertEqual(pill.width, 320, accuracy: 0.001)
        XCTAssertEqual(pill.height, 41, accuracy: 0.001)
        let notch = DictationStripLevel.stripSize(topReserve: 32)
        XCTAssertEqual(notch.width, 320, accuracy: 0.001)
        XCTAssertEqual(notch.height, 65, accuracy: 0.001)
    }

    // MARK: - The halo layers are wired to the numbers

    /// The light lives on Core Animation layers now (see `DictationHalo`), so
    /// what can go silently wrong is the wiring: a level that never reaches a
    /// layer, or a spread mask that clips the spill square. Read the layers
    /// back after an apply.
    func testHaloLayersFollowTheLevel() {
        let host = DictationHalo.HaloHostView(frame: CGRect(x: 0, y: 0, width: 520, height: 68))
        let shape = IslandShape(eave: 0, bottomRadius: 40, belly: 0, topRadius: 40)
        host.apply(shape: shape, accent: .white, level: 1, fill: 1, size: CGSize(width: 520, height: 68))
        let full = DictationStripLevel.halo(1)
        let (bloom, outer, inner, core) = (host.strokeLayers[0], host.strokeLayers[1], host.strokeLayers[2], host.strokeLayers[3])
        XCTAssertEqual(bloom.shadowRadius, full.bloomBlur, accuracy: 0.001)
        XCTAssertEqual(Double(bloom.shadowOpacity), full.bloomOpacity, accuracy: 0.001)
        XCTAssertEqual(outer.lineWidth, full.outerWidth, accuracy: 0.001)
        XCTAssertEqual(outer.shadowRadius, full.outerBlur, accuracy: 0.001)
        XCTAssertEqual(inner.shadowRadius, full.innerBlur, accuracy: 0.001)
        XCTAssertNotNil(inner.mask, "the inner bleed must be clipped to the inside")
        XCTAssertEqual(core.lineWidth, full.coreWidth, accuracy: 0.001)
        XCTAssertEqual(Double(core.opacity), full.coreOpacity, accuracy: 0.001)
        XCTAssertNotNil(bloom.path, "paths must be laid out from the strip's frame")

        host.apply(shape: shape, accent: .white, level: 0, fill: 0, size: CGSize(width: 520, height: 68))
        let rest = DictationStripLevel.halo(0)
        XCTAssertEqual(outer.shadowRadius, rest.outerBlur, accuracy: 0.001)
        XCTAssertEqual(Double(core.opacity), rest.coreOpacity, accuracy: 0.001)
    }

    /// The spread mask is wider than the strip by the spill on each side, so
    /// its stops are in mask coordinates: at fill 0 the lit half-width is
    /// 0.18 of the strip, at fill 1 it is 0.60, and the mask never clips the
    /// spill square (frame reaches past the strip on every side).
    func testSpreadMaskCoversTheSpillAndFollowsFill() {
        let host = DictationHalo.HaloHostView(frame: CGRect(x: 0, y: 0, width: 520, height: 68))
        let shape = IslandShape(eave: 0, bottomRadius: 40, belly: 0, topRadius: 40)
        host.apply(shape: shape, accent: .white, level: 0, fill: 0, size: CGSize(width: 520, height: 68))
        let spill = DictationHalo.HaloHostView.spill
        XCTAssertEqual(host.spreadMask.frame.minX, -spill, accuracy: 0.001)
        XCTAssertEqual(host.spreadMask.frame.width, 520 + spill * 2, accuracy: 0.001)
        let maskWidth = 520 + spill * 2
        let atRest = host.spreadMask.locations!.map { CGFloat(truncating: $0) }
        XCTAssertEqual(atRest[1], 0.5 - 0.18 * 520 / maskWidth, accuracy: 0.001)
        host.apply(shape: shape, accent: .white, level: 0, fill: 1, size: CGSize(width: 520, height: 68))
        let full = host.spreadMask.locations!.map { CGFloat(truncating: $0) }
        XCTAssertEqual(full[3], 0.5 + 0.60 * 520 / maskWidth, accuracy: 0.001)
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
        for _ in 0..<30 { model.updateDictating(level: 0.7, mic: "AirPods") }
        // The published level is the smoothed voice, so it lands near the
        // raw value rather than on it, and a second of it starts the fill.
        XCTAssertEqual(model.dictationLevel, 0.7, accuracy: 0.05)
        XCTAssertGreaterThan(model.dictationFill, 0.1)
        XCTAssertEqual(model.dictationInfo?.micName, "AirPods")

        model.endDictating()
        XCTAssertEqual(model.state, .collapsed)
        XCTAssertNil(model.dictationInfo)
        XCTAssertEqual(model.dictationLevel, 0)
        XCTAssertEqual(model.dictationFill, 0)
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
