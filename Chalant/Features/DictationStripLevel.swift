import CoreGraphics
import Foundation

/// What the voice drives on the dictation strip, from one number.
///
/// **The strip is the meter, and the strip's edge is the light.** There are
/// no bars, no dot, no pool: the island's own outline glows in the accent,
/// wider and brighter as you speak, and the lit stretch of edge spreads from
/// the centre toward the ends the longer you talk. Pinned here as formulas
/// rather than scattered in the view, so nobody retunes one layer and not
/// the others, and so a test can hold the resting and full values the
/// founder approved on the round-three mockup (2026-08-17, "Halo").
enum DictationStripLevel {

    /// Raw peak from the audio engine can exceed 1 on a hot mic and be
    /// negative on a broken one. Every formula clamps first.
    static func clamp(_ level: CGFloat) -> CGFloat {
        min(1, max(0, level))
    }

    /// The raw microphone peak, turned into the 0...1 everything below is
    /// drawn for.
    ///
    /// `AudioRing.peak` is a linear max |sample| over one buffer, and a
    /// built-in mic rarely passes 0.3 while somebody is talking normally. Fed
    /// in unscaled, the halo barely lifts off its resting values and the strip
    /// fails the one job it has: showing that the ear is alive. 3.2 is the
    /// headroom the deleted `ListeningPanel` applied to this same signal, for
    /// this same reason, and it puts an ordinary speaking voice near the top of
    /// the range. (The voice-command surface's `min(1, rms * 18)` is a
    /// different number because it scales RMS, not peak.)
    static func normalize(peak: CGFloat) -> CGFloat {
        clamp(peak * 3.2)
    }

    // MARK: - Motion

    /// The two numbers the view draws from, stepped once per meter tick.
    ///
    /// `level` is the voice, smoothed so the light is quick to answer and slow
    /// to let go: it rises on a ~70 ms attack and falls on a ~300 ms release,
    /// which is what makes the strip feel attentive rather than jittery.
    ///
    /// `fill` is how much of the sentence has been said: it grows while the
    /// voice is up, eases back during a pause, and is what spreads the lit
    /// edge from the centre outward. Talking is rewarded; stopping is not
    /// punished, only let go of, slowly.
    struct Voice: Equatable {
        private(set) var level: CGFloat = 0
        private(set) var fill: CGFloat = 0

        /// Below this the meter is reading a pause, not a voice.
        static let pauseFloor: CGFloat = 0.05
        static let attack: CGFloat = 14
        static let release: CGFloat = 3.2
        static let fillRate: CGFloat = 0.42
        static let pauseGiveback: CGFloat = 0.12

        mutating func step(raw: CGFloat, dt: TimeInterval) {
            let target = clamp(raw)
            let dt = CGFloat(max(0, dt))
            let k = target > level ? Self.attack : Self.release
            level += (target - level) * min(1, dt * k)
            if target < Self.pauseFloor {
                fill = max(0, fill - dt * Self.pauseGiveback)
            } else {
                fill = min(1, fill + level * dt * Self.fillRate)
            }
        }

        mutating func reset() {
            level = 0
            fill = 0
        }
    }

    // MARK: - The halo

    /// The three strokes of the island's outline that make the halo, all read
    /// off the smoothed level. Outer glow spills both ways; the core is the
    /// thin white edge; the inner bleed is clipped to the inside.
    struct Halo: Equatable {
        var outerWidth: CGFloat
        var outerBlur: CGFloat
        var outerOpacity: Double
        var coreWidth: CGFloat
        var coreOpacity: Double
        var coreShadow: CGFloat
        var innerBlur: CGFloat
        var innerOpacity: Double
    }

    static func halo(_ level: CGFloat) -> Halo {
        let l = clamp(level)
        let d = Double(l)
        return Halo(
            outerWidth: 1.5 + l * 3.0,
            outerBlur: 12 + l * 30,
            outerOpacity: 0.45 + d * 0.50,
            coreWidth: 1.0 + l * 1.2,
            coreOpacity: 0.50 + d * 0.50,
            coreShadow: 3 + l * 8,
            innerBlur: 8 + l * 30,
            innerOpacity: 0.10 + d * 0.25
        )
    }

    /// How far from the strip's centre the lit edge reaches, as a fraction of
    /// the strip's width on each side: about the middle third at the start of a
    /// hold, the whole edge after a full sentence.
    static func spread(fill: CGFloat) -> CGFloat {
        0.18 + clamp(fill) * 0.42
    }

    /// The breath the halo takes at rest while ambient motion is on: the low
    /// end of its opacity swing (the high end is 1) and half a cycle.
    static let breathFloor: Double = 0.85
    static let breathHalfCycle: TimeInterval = 2.1

    /// The "sent" light on release: how long the point takes to rise from the
    /// strip's centre into the notch, and its size.
    static let sentDuration: TimeInterval = 0.45
    static let sentDiameter: CGFloat = 28
}
