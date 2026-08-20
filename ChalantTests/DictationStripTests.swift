import SwiftUI
import XCTest
@testable import Chalant

@MainActor
final class DictationStripTests: XCTestCase {

    // MARK: - The motion (Slipstream, round ten, 2026-08-20)

    private let tick: TimeInterval = 1.0 / 30

    /// Quick to answer, quick to settle. Three meter ticks of voice (100 ms)
    /// lift the level essentially all the way; three ticks of silence settle
    /// it fast but never as fast as the attack. The old fixed ~300 ms release
    /// read as "a goddess listening, slowly" (founder, 2026-08-20).
    func testVoiceRisesFasterThanItSettles() {
        var voice = DictationStripLevel.Voice()
        for _ in 0..<3 { voice.step(raw: 1, dt: tick) }
        XCTAssertGreaterThan(voice.level, 0.95)
        let peak = voice.level
        for _ in 0..<3 { voice.step(raw: 0, dt: tick) }
        XCTAssertEqual(voice.level, 0.58, accuracy: 0.03)
        XCTAssertLessThan(peak - voice.level, peak, "the settle must be slower than the attack")
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
        XCTAssertEqual(voice.pulse, 0)
        XCTAssertEqual(voice.pace, 0)
    }

    /// The beat is a counter, not a state: resetting it to a value a
    /// previous hold already used would suppress the next hold's first
    /// glint.
    func testResetKeepsTheBeatCounter() {
        var voice = DictationStripLevel.Voice()
        voice.step(raw: 1, dt: tick)
        let beats = voice.beat
        XCTAssertGreaterThan(beats, 0)
        voice.reset()
        XCTAssertEqual(voice.beat, beats)
    }

    // MARK: - The pulse: the strip answers syllables, not just volume

    /// The first tick of a word is a full pulse and a beat; the pulse is
    /// gone in about a tenth of a second even while the voice stays loud.
    func testASyllableFiresThePulseOnItsFirstTick() {
        var voice = DictationStripLevel.Voice()
        voice.step(raw: 1, dt: tick)
        XCTAssertEqual(voice.pulse, 1, accuracy: 0.001)
        XCTAssertEqual(voice.beat, 1)
        for _ in 0..<3 { voice.step(raw: 1, dt: tick) }
        XCTAssertLessThan(voice.pulse, 0.1)
        // A held loud vowel is one syllable, not thirty: the refractory
        // keeps meter jitter from re-firing the beat.
        XCTAssertEqual(voice.beat, 1)
    }

    // MARK: - The pace: the strip moves in the speaker's gear

    /// Two ticks of voice then a gap, repeated. Five syllables a second is a
    /// quick talker and drives the gear up; one a second is unhurried and
    /// leaves it down; and the gear eases back between phrases.
    func testQuickSyllablesRaiseThePaceAndSlowOnesDoNot() {
        var quick = DictationStripLevel.Voice()
        for _ in 0..<10 {
            for _ in 0..<2 { quick.step(raw: 1, dt: tick) }
            for _ in 0..<4 { quick.step(raw: 0, dt: tick) }
        }
        XCTAssertGreaterThan(quick.pace, 0.6)

        var slow = DictationStripLevel.Voice()
        for _ in 0..<6 {
            for _ in 0..<2 { slow.step(raw: 1, dt: tick) }
            for _ in 0..<28 { slow.step(raw: 0, dt: tick) }
        }
        XCTAssertLessThan(slow.pace, 0.15)

        let peak = quick.pace
        for _ in 0..<90 { quick.step(raw: 0, dt: tick) }
        XCTAssertLessThan(quick.pace, peak - 0.5, "the gear eases back down between phrases")
    }

    /// A quick talker gets a quicker settle: the release constant follows
    /// the gear, and the glints follow it too.
    func testTheGearTightensTheSettleAndTheGlints() {
        XCTAssertEqual(DictationStripLevel.glintDuration(pace: 0), 0.18, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.glintDuration(pace: 1), 0.09, accuracy: 0.001)
        XCTAssertGreaterThan(
            DictationStripLevel.Voice.releaseFloor + DictationStripLevel.Voice.releaseSpan,
            DictationStripLevel.Voice.releaseFloor
        )
    }

    // MARK: - The edge (Slipstream: near dark at rest, vivid on the voice)

    func testSlipAtSilenceIsNearDark() {
        let s = DictationStripLevel.slip(level: 0, pulse: 0)
        XCTAssertEqual(s.glowWidth, 1.6, accuracy: 0.001)
        XCTAssertEqual(s.glowBlur, 4, accuracy: 0.001)
        XCTAssertEqual(s.glowOpacity, 0.04, accuracy: 0.001)
        XCTAssertEqual(s.coreWidth, 1.0, accuracy: 0.001)
        XCTAssertEqual(s.coreBlur, 2, accuracy: 0.001)
        XCTAssertEqual(s.coreOpacity, 0.12, accuracy: 0.001)
    }

    func testSlipAtFullVoiceIsVivid() {
        let s = DictationStripLevel.slip(level: 1, pulse: 0)
        XCTAssertEqual(s.glowWidth, 2.8, accuracy: 0.001)
        XCTAssertEqual(s.glowBlur, 11, accuracy: 0.001)
        XCTAssertEqual(s.glowOpacity, 0.52, accuracy: 0.001)
        XCTAssertEqual(s.coreWidth, 1.4, accuracy: 0.001)
        XCTAssertEqual(s.coreBlur, 6, accuracy: 0.001)
        XCTAssertEqual(s.coreOpacity, 0.97, accuracy: 0.001)
    }

    /// Feeling fast comes from contrast: speaking must change the strip by
    /// nearly an order of magnitude, where the old halo rested at half
    /// strength and barely moved.
    func testSpeakingMeansSomething() {
        let rest = DictationStripLevel.slip(level: 0, pulse: 0)
        let full = DictationStripLevel.slip(level: 1, pulse: 0)
        XCTAssertGreaterThan(full.coreOpacity / rest.coreOpacity, 8)
        XCTAssertGreaterThan(full.glowOpacity / rest.glowOpacity, 8)
    }

    /// The pulse ticks the whole lit edge brighter at once, and the sum is
    /// clamped so a shout on a syllable cannot blow past full.
    func testThePulseTicksTheEdgeBrighter() {
        let quiet = DictationStripLevel.slip(level: 0.5, pulse: 0)
        let struck = DictationStripLevel.slip(level: 0.5, pulse: 1)
        XCTAssertEqual(struck.coreOpacity - quiet.coreOpacity, 0.45, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.slip(level: 1, pulse: 1).coreOpacity, 1, accuracy: 0.001)
    }

    // MARK: - The pool and the lean

    func testThePoolKicksWiderWithTheVoiceAndHarderInGear() {
        let rest = DictationStripLevel.pool(level: 0, pace: 0)
        XCTAssertEqual(rest.opacity, 0.04, accuracy: 0.001)
        XCTAssertEqual(rest.stretch, 1.7, accuracy: 0.001)
        let talking = DictationStripLevel.pool(level: 1, pace: 0)
        XCTAssertEqual(talking.stretch, 3.3, accuracy: 0.001)
        let quick = DictationStripLevel.pool(level: 1, pace: 1)
        XCTAssertEqual(quick.stretch, 4.1, accuracy: 0.001)
        XCTAssertEqual(quick.opacity, 0.34, accuracy: 0.001)
    }

    /// The lean is a hair, never a lurch: at most 3.5% even at full voice in
    /// the highest gear, and exactly 1 in silence.
    func testTheLeanIsAHairNeverALurch() {
        XCTAssertEqual(DictationStripLevel.lean(level: 0, pace: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(DictationStripLevel.lean(level: 1, pace: 0), 1.015, accuracy: 0.0001)
        XCTAssertEqual(DictationStripLevel.lean(level: 1, pace: 1), 1.035, accuracy: 0.0001)
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
        XCTAssertEqual(DictationStripLevel.slip(level: 3.0, pulse: 0).glowBlur, 11, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.slip(level: -1, pulse: 0).glowBlur, 4, accuracy: 0.001)
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

    // MARK: - Tidy is on by default, off the path the user feels

    /// The tidy pass runs after the insert and swaps in place (spec
    /// 2026-08-17, "Instant, then tidied in place"), so it no longer costs the
    /// user a second, and it is on unless switched off. Uses its own suite:
    /// the test host is the real app, so `.standard` here is the founder's
    /// preferences.
    func testTidyIsOnUnlessSwitchedOff() {
        let suite = UserDefaults(suiteName: "chalant.tests.\(UUID().uuidString)")!
        XCTAssertTrue(Cleanup.isEnabled(in: suite))
        Cleanup.setEnabled(false, in: suite)
        XCTAssertFalse(Cleanup.isEnabled(in: suite))
    }

    // MARK: - The strip is sized and shaped for speed (Slipstream)

    /// 320 wide everywhere; lower and tauter than the 1.17 pill. A pill
    /// display (reserve 8) gets 32 (was 41), a notch display (reserve 32)
    /// gets 56 (was 65). The corners are machined, just over a third of the
    /// height, never the soft full pill.
    func testStripIsLowAndTaut() {
        let pill = DictationStripLevel.stripSize(topReserve: Theme.Space.m)
        XCTAssertEqual(pill.width, 320, accuracy: 0.001)
        XCTAssertEqual(pill.height, 32, accuracy: 0.001)
        let notch = DictationStripLevel.stripSize(topReserve: 32)
        XCTAssertEqual(notch.width, 320, accuracy: 0.001)
        XCTAssertEqual(notch.height, 56, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.cornerRadius(height: 32), 11.52, accuracy: 0.001)
        XCTAssertLessThan(DictationStripLevel.cornerRadius(height: 32), 16, "machined, not a full pill")
    }

    // MARK: - The light's layers are wired to the numbers

    /// The light lives on Core Animation layers (see `DictationStripLight`),
    /// so what can go silently wrong is the wiring: a level that never
    /// reaches a layer, a pool that never kicks, or a spread mask that clips
    /// the spill square. Read the layers back after an apply.
    func testLightLayersFollowTheLevel() {
        let host = DictationStripLight.LightHostView(frame: CGRect(x: 0, y: 0, width: 320, height: 32))
        let shape = IslandShape(eave: 0, bottomRadius: 11.52, belly: 0, topRadius: 11.52)
        let size = CGSize(width: 320, height: 32)
        host.apply(shape: shape, accent: .white, level: 1, fill: 1, pulse: 0, pace: 0, beat: 0, size: size)
        let full = DictationStripLevel.slip(level: 1, pulse: 0)
        let (glow, core) = (host.strokeLayers[0], host.strokeLayers[1])
        XCTAssertEqual(glow.lineWidth, full.glowWidth, accuracy: 0.001)
        XCTAssertEqual(glow.shadowRadius, full.glowBlur, accuracy: 0.001)
        XCTAssertEqual(Double(glow.opacity), full.glowOpacity, accuracy: 0.001)
        XCTAssertEqual(core.lineWidth, full.coreWidth, accuracy: 0.001)
        XCTAssertEqual(Double(core.opacity), full.coreOpacity, accuracy: 0.001)
        XCTAssertNotNil(glow.path, "paths must be laid out from the strip's frame")
        let pool = DictationStripLevel.pool(level: 1, pace: 0)
        XCTAssertEqual(Double(host.poolLayer.opacity), pool.opacity, accuracy: 0.001)
        XCTAssertEqual(host.poolLayer.transform.m11, pool.stretch, accuracy: 0.001)
        XCTAssertNotNil(host.poolLayer.superlayer?.mask, "the pool must be clipped inside the glass")

        host.apply(shape: shape, accent: .white, level: 0, fill: 0, pulse: 0, pace: 0, beat: 0, size: size)
        let rest = DictationStripLevel.slip(level: 0, pulse: 0)
        XCTAssertEqual(Double(glow.opacity), rest.glowOpacity, accuracy: 0.001)
        XCTAssertEqual(Double(core.opacity), rest.coreOpacity, accuracy: 0.001)
    }

    /// A beat is a syllable: when the counter moves, a pair of glints races
    /// the top edge. The first apply must NOT fire (mounting mid-hold would
    /// replay a stale beat); the next beat must.
    func testABeatFiresTheGlints() {
        let host = DictationStripLight.LightHostView(frame: CGRect(x: 0, y: 0, width: 320, height: 32))
        let shape = IslandShape(eave: 0, bottomRadius: 11.52, belly: 0, topRadius: 11.52)
        let size = CGSize(width: 320, height: 32)
        host.apply(shape: shape, accent: .white, level: 0.5, fill: 0.5, pulse: 1, pace: 0, beat: 3, size: size)
        XCTAssertFalse(host.glints.contains { $0.animation(forKey: "race") != nil })
        host.apply(shape: shape, accent: .white, level: 0.5, fill: 0.5, pulse: 1, pace: 0, beat: 4, size: size)
        XCTAssertTrue(host.glints.contains { $0.animation(forKey: "race") != nil })
        XCTAssertEqual(host.glints.count, 4, "two per side, so a quick talker's glints can overlap")
    }

    /// The spread mask is wider than the strip by the spill on each side, so
    /// its stops are in mask coordinates: at fill 0 the lit half-width is
    /// 0.18 of the strip, at fill 1 it is 0.60, and the mask never clips the
    /// spill square (frame reaches past the strip on every side).
    func testSpreadMaskCoversTheSpillAndFollowsFill() {
        let host = DictationStripLight.LightHostView(frame: CGRect(x: 0, y: 0, width: 320, height: 32))
        let shape = IslandShape(eave: 0, bottomRadius: 11.52, belly: 0, topRadius: 11.52)
        let size = CGSize(width: 320, height: 32)
        host.apply(shape: shape, accent: .white, level: 0, fill: 0, pulse: 0, pace: 0, beat: 0, size: size)
        let spill = DictationStripLight.LightHostView.spill
        XCTAssertEqual(host.spreadMask.frame.minX, -spill, accuracy: 0.001)
        XCTAssertEqual(host.spreadMask.frame.width, 320 + spill * 2, accuracy: 0.001)
        let maskWidth = 320 + spill * 2
        let atRest = host.spreadMask.locations!.map { CGFloat(truncating: $0) }
        XCTAssertEqual(atRest[1], 0.5 - 0.18 * 320 / maskWidth, accuracy: 0.001)
        host.apply(shape: shape, accent: .white, level: 0, fill: 1, pulse: 0, pace: 0, beat: 0, size: size)
        let full = host.spreadMask.locations!.map { CGFloat(truncating: $0) }
        XCTAssertEqual(full[3], 0.5 + 0.60 * 320 / maskWidth, accuracy: 0.001)
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
