import CoreGraphics
import Foundation

/// What the voice drives on the dictation strip, from one number.
///
/// **The strip is the meter, and it moves in the speaker's own gear.** There
/// are no bars, no dot, no waveform: the island's outline carries a thin core
/// of white and one tight glow, near dark in silence and vivid on the voice,
/// with a low pool of accent light inside the glass and glints racing the top
/// edge on every syllable. The whole surface takes its tempo from how fast
/// the words land, not just how loud they are ("Slipstream", the founder's
/// pick on round ten, 2026-08-20; supersedes the round-three "Halo" values).
/// Pinned here as formulas rather than scattered in the view, so nobody
/// retunes one layer and not the others, and so a test can hold the resting
/// and full values the founder approved.
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
    /// in unscaled, the light barely lifts off its resting values and the
    /// strip fails the one job it has: showing that the ear is alive. 3.2 is
    /// the headroom the deleted `ListeningPanel` applied to this same signal,
    /// for this same reason, and it puts an ordinary speaking voice near the
    /// top of the range. (The voice-command surface's `min(1, rms * 18)` is a
    /// different number because it scales RMS, not peak.)
    static func normalize(peak: CGFloat) -> CGFloat {
        clamp(peak * 3.2)
    }

    // MARK: - Motion

    /// The numbers the view draws from, stepped once per meter tick.
    ///
    /// `level` is the voice, smoothed so the light is quick to answer and
    /// quick to settle: one 30 Hz tick of voice is already ~87% of the way up,
    /// and it falls on a settle that tightens with the speaker's pace (the
    /// fixed ~300 ms release read as "a goddess listening, slowly" to the
    /// founder, 2026-08-20).
    ///
    /// `fill` is how much of the sentence has been said: it grows while the
    /// voice is up, eases back during a pause, and is what spreads the lit
    /// edge from the centre outward. Talking is rewarded; stopping is not
    /// punished, only let go of.
    ///
    /// `pulse` is the syllable: 1 the tick a word lands, gone in about a
    /// tenth of a second. It is what makes the strip answer speech rather
    /// than volume.
    ///
    /// `pace` is the speaker's gear, 0 unhurried to 1 quick, read from how
    /// often syllables land. A fast talker gets faster glints, a quicker
    /// settle, and a harder kick; a slow talker gets composure. It eases
    /// back down between phrases rather than snapping.
    ///
    /// `beat` counts syllable onsets; the view fires a glint when it changes.
    ///
    /// `sway` is the pool's life: a phase that never stops advancing while
    /// the strip listens, slow in a pause, quick under voice. The speaker
    /// must always see something alive ("there should be something alive
    /// like moving so the speaker knows its listening", the founder,
    /// 2026-08-20); the pool moving IN PLACE is that life, and it keeps the
    /// rule that nothing crosses the strip except a syllable's glint.
    struct Voice: Equatable {
        private(set) var level: CGFloat = 0
        private(set) var fill: CGFloat = 0
        private(set) var pulse: CGFloat = 0
        private(set) var pace: CGFloat = 0
        private(set) var beat: Int = 0
        private(set) var sway: CGFloat = 0
        private var sinceOnset: TimeInterval = .infinity

        /// Below this the meter is reading a pause, not a voice.
        static let pauseFloor: CGFloat = 0.05
        static let attack: CGFloat = 26
        /// The settle, by gear: releaseFloor at an unhurried pace, up to
        /// releaseFloor + releaseSpan when the words come quickly.
        static let releaseFloor: CGFloat = 5
        static let releaseSpan: CGFloat = 4.5
        static let fillRate: CGFloat = 0.65
        static let pauseGiveback: CGFloat = 0.12
        /// A syllable is the smoothed level jumping this much in one tick.
        /// Real speech dips far less cleanly than a synthetic voice, and at
        /// 0.05 whole phrases passed without a beat, which the founder read
        /// as "very little happening" (2026-08-20).
        static let onsetJump: CGFloat = 0.035
        /// ...no sooner than this after the last one (a loud vowel jitters
        /// the meter tick to tick; a human does not produce 20 syllables/s).
        static let onsetRefractory: TimeInterval = 0.10
        /// How the gap between syllables maps to the gear: 1.2/s and slower
        /// is unhurried (0), 4.5/s and faster is quick (1).
        static let paceFloorRate: CGFloat = 1.2
        static let paceSpanRate: CGFloat = 3.3
        /// Each onset carries the gear half way to what the new gap says...
        static let paceGain: CGFloat = 0.5
        /// ...and it eases back down between phrases rather than snapping.
        static let paceDecay: CGFloat = 0.25
        /// The pulse dies in about a tenth of a second, faster in a higher
        /// gear.
        static let pulseDecay: CGFloat = 10
        static let pulseDecayPaceSpan: CGFloat = 8
        /// How fast the pool's life advances, in radians per second: a
        /// gentle ~3 s cycle in a pause, under a second at full voice in a
        /// high gear.
        static let swayFloor: CGFloat = 2.2
        static let swayVoiceSpan: CGFloat = 5.0
        static let swayPaceSpan: CGFloat = 2.0

        mutating func step(raw: CGFloat, dt: TimeInterval) {
            let target = clamp(raw)
            let dt = CGFloat(max(0, dt))
            let k = target > level ? Self.attack : (Self.releaseFloor + pace * Self.releaseSpan)
            let before = level
            level += (target - level) * min(1, dt * k)
            sway += dt * (Self.swayFloor + level * Self.swayVoiceSpan + pace * Self.swayPaceSpan)

            pulse = max(0, pulse - dt * (Self.pulseDecay + pace * Self.pulseDecayPaceSpan))
            pace = max(0, pace - dt * Self.paceDecay)
            sinceOnset += TimeInterval(dt)
            if level - before > Self.onsetJump, sinceOnset > Self.onsetRefractory {
                beat &+= 1
                pulse = 1
                if sinceOnset.isFinite {
                    let rate = 1 / CGFloat(max(0.08, sinceOnset))
                    let heard = clamp((rate - Self.paceFloorRate) / Self.paceSpanRate)
                    pace += (heard - pace) * Self.paceGain
                }
                sinceOnset = 0
            }

            if target < Self.pauseFloor {
                fill = max(0, fill - dt * Self.pauseGiveback)
            } else {
                fill = min(1, fill + level * dt * Self.fillRate)
            }
        }

        mutating func reset() {
            level = 0
            fill = 0
            pulse = 0
            pace = 0
            sway = 0
            sinceOnset = .infinity
            // beat is left alone: it is a counter, not a state, and resetting
            // it to a value a previous hold already used would suppress the
            // first glint of the next hold.
        }
    }

    // MARK: - The edge

    /// The two strokes of the island's outline: one tight accent glow and a
    /// thin white core. Near dark at rest so speaking means something;
    /// brightness carries the voice, width hardly moves. The pulse rides on
    /// top: every syllable ticks the whole lit edge brighter for a tenth of
    /// a second, everywhere at once, so nothing is ever on its way.
    struct Slip: Equatable {
        var glowWidth: CGFloat
        var glowBlur: CGFloat
        var glowOpacity: Double
        var coreWidth: CGFloat
        var coreBlur: CGFloat
        var coreOpacity: Double
    }

    static func slip(level: CGFloat, pulse: CGFloat) -> Slip {
        let l = clamp(level)
        let p = clamp(pulse)
        // The voiced end sits well above the mockup's numbers on purpose:
        // what read vivid on a canvas read quiet on real CA layers at the
        // real 260 × 28 ("when im talking there is very little happening",
        // the founder, 2026-08-20). Rest stays near dark; only the voiced
        // terms grew.
        return Slip(
            glowWidth: 1.6 + l * 2.0,
            glowBlur: 5 + l * 11,
            glowOpacity: min(1, 0.05 + Double(l) * 0.70 + Double(p) * 0.25),
            coreWidth: 1.0 + l * 0.6,
            coreBlur: 2 + l * 6,
            coreOpacity: min(1, 0.12 + Double(l) * 0.85 + Double(p) * 0.45)
        )
    }

    /// How far from the centre the lit edge reaches, per side.
    ///
    /// **Opens fast, then grows a little (2026-09-03).** It used to start at
    /// the middle third (0.18) and crawl to the ends over a whole sentence,
    /// and on the thin edge the founder felt that crawl as slow. Now it opens
    /// to most of its width the instant you speak and only edges wider as the
    /// sentence goes on, so the motion is a quick bloom rather than a slow
    /// stretch.
    static func spread(fill: CGFloat) -> CGFloat {
        0.40 + clamp(fill) * 0.18
    }

    // MARK: - The pool

    /// The one light inside the glass: a dim pool of accent resting at the
    /// floor, kicking wider with the voice and harder in a higher gear. The
    /// same language as the island's music blob, never a shape.
    struct Pool: Equatable {
        /// Radius as a fraction of the strip's height.
        var radius: CGFloat
        /// Horizontal stretch of that radius.
        var stretch: CGFloat
        var opacity: Double
    }

    /// The pulse kicks the pool too: every syllable, the light inside the
    /// glass answers along with the edge, so talking is visibly answered
    /// even between level swings.
    static func pool(level: CGFloat, pulse: CGFloat, pace: CGFloat) -> Pool {
        let l = clamp(level)
        return Pool(
            radius: 0.50 + l * 0.85,
            stretch: 1.7 + (1.6 + clamp(pace) * 0.8) * l,
            opacity: min(1, Double(0.05 + l * 0.46 + clamp(pulse) * 0.12))
        )
    }

    /// The pool's life, read off the sway phase: where the light's heart
    /// drifts (points off centre, wider under voice) and how its radius
    /// wobbles. Two blobs breathe against each other (the second runs
    /// counter-phase at `counterDrift` of the first) so it reads as living
    /// liquid, never a metronome.
    static func poolSway(phase: CGFloat, level: CGFloat) -> (drift: CGFloat, wobble: CGFloat) {
        let amp = 6 + 14 * clamp(level)
        return (sin(phase) * amp, 1 + 0.08 * sin(phase * 1.7 + 1.1))
    }
    static let counterDrift: CGFloat = -0.7
    static let counterScale: CGFloat = 0.6

    // MARK: - The glints

    /// A syllable strikes a pair of glints that race the top edge outward
    /// from the centre and are gone before the next word lands: 0.18 s in an
    /// unhurried gear, half that when the words come quickly.
    static func glintDuration(pace: CGFloat) -> TimeInterval {
        TimeInterval(0.18 - clamp(pace) * 0.09)
    }
    /// The streak's tail, width, and how far below the top edge it rides.
    /// Thicker and longer than the first cut: at 1.6 pt the glints were
    /// nearly invisible in peripheral vision, and they are half of what
    /// says "it hears you".
    static let glintLength: CGFloat = 58
    static let glintWidth: CGFloat = 2.0
    static let glintInset: CGFloat = 1.5

    // MARK: - Size and shape

    /// The strip is ONE small shape on every display: 260 × 28, floating.
    /// It no longer wraps a MacBook's notch: at this width the wrap read as
    /// the notch swelling ("it looks weird cause its covering the notch",
    /// the founder, 2026-08-20), so on a notch display the strip floats
    /// `notchGap` beneath the hardware instead, and a pill display floats it
    /// under the screen top the way the resting pill floats. Smaller and
    /// premium was the same day's earlier word; 1.23.1 shipped at 320 × 32
    /// and still read big.
    /// The polish, ruled from the founder's mockup 2026-08-27. The lit
    /// edge keeps a white HEART narrower than the accent glow: the heart's
    /// share of the lit window, so the stretch melts into the accent at
    /// its ends. The glass carries one fine hairline on its outline and a
    /// breath of light along its top; both still, neither follows the
    /// voice: nothing on this strip travels except on a syllable.
    static let coreWindow: CGFloat = 0.72
    static let edgeHairline: Double = 0.08
    static let sheenLight: Double = 0.12
    /// The strip floats off the wallpaper: the body's soft under-shadow
    /// while dictating.
    static let floatShadowOpacity: Double = 0.5
    static let floatShadowRadius: CGFloat = 12
    static let floatShadowDrop: CGFloat = 7
    /// How deep the dictating glass tints: a hair darker than the veiled
    /// island, so the strip reads as a solid object over any wallpaper.
    static let glassDepth: Double = 0.45

    // MARK: - The edge (2026-09-03)

    /// **The strip stops being an object.** The founder, on the shipped
    /// pill: "that thing that's popping, which shows that I'm talking, I
    /// don't like that", and when asked what was wrong they named three
    /// things at once: where it sits, its shape and size, and how it moves.
    /// Not that it appears. So the answer that fixes all three is to stop
    /// drawing a thing at all: light gathers along the very top edge of the
    /// screen, brightest at the middle, reaching further out as the sentence
    /// goes on. Nothing floats, nothing has a size to be wrong, and it
    /// behaves the same on a notch Mac, a pill Mac and an external monitor,
    /// which no floating shape ever did.
    /// Thicker than the first cut's 3 pt: the founder saw it and said "it
    /// looks good, but it's not visible" (2026-09-03). A hairline reads as
    /// premium and reads as nothing; a 5 pt band you can actually find.
    static let edgeLineHeight: CGFloat = 5
    /// The light that falls from the line onto the wallpaper below it. Tall
    /// enough that the glow fades fully to nothing within it, with room to
    /// spare below, so the frame never clips a lit region into a flat line.
    static let edgeBloomHeight: CGFloat = 52
    static var edgeHeight: CGFloat { edgeLineHeight + edgeBloomHeight }

    /// Brightness at the middle of the swell. **The floor is the fix
    /// (2026-09-03):** it was 0.14, near invisible at rest, so a held key
    /// with a quiet room looked like nothing was happening. Raised so the
    /// light is unmistakably present the instant you hold the key, and still
    /// brightens hard on the voice.
    static func edgePeak(level: CGFloat) -> Double {
        0.45 + Double(clamp(level)) * 0.53
    }

    /// The shoulders, as a share of the peak. Low on purpose: the swell has
    /// to melt into the dark rather than end at a visible stop.
    static let edgeShoulderShare: Double = 0.16
    /// How much of the peak the bloom under the line carries. Raised with the
    /// floor so the glow under the line is visible, not just the line.
    static let edgeBloomShare: Double = 0.22

    static let stripWidth: CGFloat = 260
    static let stripHeight: CGFloat = 28
    static var stripSize: CGSize { CGSize(width: stripWidth, height: stripHeight) }
    /// One line of `Fonts.micro` (11 pt semibold).
    static let stripRow: CGFloat = 13
    /// Air above and below the row. Tighter than the island's usual
    /// clearances on purpose: the slim strip is the shape of the speed.
    static let stripTopAir: CGFloat = 3
    static let stripBottomAir: CGFloat = 4
    /// The air between the hardware notch and the floating strip.
    static let notchGap: CGFloat = 4

    /// Machined corners, not the soft full pill: just over a third of the
    /// height, which is what makes the slim strip read as built for speed.
    static func cornerRadius(height: CGFloat) -> CGFloat {
        height * 0.36
    }

    /// Once you are talking, the app's name steps back to almost nothing:
    /// it matters in the first second (where will the words land), then it
    /// is noise. The threshold is on fill so a single syllable does not
    /// flicker it.
    static let nameFadesAtFill: CGFloat = 0.04
    static let nameFadedOpacity: Double = 0.12
    static let nameFadeDuration: TimeInterval = 0.6

    // MARK: - The goodbye

    /// Letting go: the light gathers into a point at the strip's centre for
    /// the first `sentGather` of the phase, then the point shoots up into
    /// the notch with a short trail. 0.3 s in total; endings are fast here
    /// too.
    static let sentDuration: TimeInterval = 0.3
    static let sentGather: CGFloat = 0.3
    static let sentDiameter: CGFloat = 14
    static let sentOvershoot: CGFloat = 14
    static let sentTrail: CGFloat = 22
}
