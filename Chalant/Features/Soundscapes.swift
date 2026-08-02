import Foundation

/// One sound, making itself. A soundscape fills two channel buffers on
/// demand and knows nothing about AVAudioEngine, which is the whole
/// point: the suite can render one into a plain array with no audio
/// hardware and measure what it actually produced.
///
/// Everything in here runs on the render thread. Nothing allocates,
/// nothing locks, nothing calls into the system: buffers, voice pools
/// and generator state are all built before the first sample.
protocol Soundscape: AnyObject {
    /// Fill `frames` samples of each channel. Values sit inside -1...1
    /// before the engine applies its own ramp and the user's volume.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int)
}

extension Soundscape {
    /// Render straight into two arrays with no audio device anywhere in
    /// sight. This is what lets the suite assert things about a sound
    /// that are otherwise left to opinion (level, tilt, stereo width,
    /// whether events actually fire), and what renders the audition
    /// files the user listens to before any of it ships.
    ///
    /// Blocks, not one long call, so it exercises the same path the
    /// render callback takes.
    func renderOffline(
        seconds: Double,
        sampleRate: Double = 48000,
        blockFrames: Int = 512
    ) -> (left: [Float], right: [Float]) {
        let total = Int(seconds * sampleRate)
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                guard let leftBase = leftBuffer.baseAddress,
                      let rightBase = rightBuffer.baseAddress else { return }
                var offset = 0
                while offset < total {
                    let frames = min(blockFrames, total - offset)
                    render(left: leftBase + offset, right: rightBase + offset, frames: frames)
                    offset += frames
                }
            }
        }
        return (left, right)
    }
}

/// Seeded xorshift, one per generator. The system RNG was fine when a
/// single sample needed one number, but the textures below want tens of
/// thousands per second and the render thread must never gamble on a
/// syscall. Seeding also means a test can render the same ten seconds
/// twice and compare them.
struct Rng {
    private var state: UInt64

    init(seed: UInt64) {
        // Zero is a fixed point of xorshift, so it is never allowed.
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// 0..<1
    mutating func uniform() -> Float {
        Float(next() >> 40) * (1.0 / 16777216.0)
    }

    /// -1...1
    mutating func bipolar() -> Float {
        uniform() * 2 - 1
    }

    mutating func range(_ low: Float, _ high: Float) -> Float {
        low + (high - low) * uniform()
    }
}

/// A one-pole lowpass, the building block everything here shares.
/// Cascade two for a gentler slope with no resonance to ring.
struct OnePole {
    private var value: Float = 0
    var alpha: Float

    init(cutoff: Float, sampleRate: Float) {
        alpha = OnePole.alpha(cutoff: cutoff, sampleRate: sampleRate)
    }

    static func alpha(cutoff: Float, sampleRate: Float) -> Float {
        1 - expf(-2 * .pi * cutoff / sampleRate)
    }

    mutating func low(_ input: Float) -> Float {
        value += alpha * (input - value)
        return value
    }

    /// What the lowpass threw away.
    mutating func high(_ input: Float) -> Float {
        input - low(input)
    }
}

// MARK: The three colors

/// The synthesized colors, one generator per channel so they stop
/// collapsing to a point between the listener's ears. They were
/// computed once per frame and written identically to both channels,
/// which is exactly what "thin" sounds like (user, 2026-08-02).
///
/// The filter tunings are NOT touched. They were set by ear in an
/// earlier round after the user asked for warmth, and warmth is not
/// what they complained about.
final class ColorNoise: Soundscape {
    enum Color {
        case brown
        case pink
        case white
    }

    /// One channel's worth of state. Two of these, seeded differently,
    /// are what make the stereo real rather than a widener smeared over
    /// a mono source.
    private struct Channel {
        var rng: Rng
        var brownLast: Float = 0
        var white: Float = 0
        var pink = [Float](repeating: 0, count: 7)
        var smoothA: Float = 0
        var smoothB: Float = 0

        mutating func smoothed(_ input: Float, alpha: Float) -> Float {
            smoothA += alpha * (input - smoothA)
            smoothB += alpha * (smoothA - smoothB)
            return smoothB
        }

        mutating func next(_ color: Color) -> Float {
            let white = rng.bipolar()
            switch color {
            case .white:
                // Softened: raw full-band white is piercing.
                self.white += 0.45 * (white - self.white)
                return self.white * 0.8
            case .pink:
                // Refined Kellet pink (seven poles), then the smoothing
                // lowpass. The economy filter left the top octave
                // hissing, which read as harsh.
                pink[0] = 0.99886 * pink[0] + white * 0.0555179
                pink[1] = 0.99332 * pink[1] + white * 0.0750759
                pink[2] = 0.96900 * pink[2] + white * 0.1538520
                pink[3] = 0.86650 * pink[3] + white * 0.3104856
                pink[4] = 0.55000 * pink[4] + white * 0.5329522
                pink[5] = -0.7616 * pink[5] - white * 0.0168980
                let value = pink[0] + pink[1] + pink[2] + pink[3]
                    + pink[4] + pink[5] + pink[6] + white * 0.5362
                pink[6] = white * 0.115926
                return smoothed(value, alpha: ColorNoise.pinkAlpha) * ColorNoise.pinkGain
            case .brown:
                brownLast = (brownLast + 0.02 * white) / 1.02
                return smoothed(brownLast * 3.2, alpha: ColorNoise.brownAlpha)
                    * ColorNoise.brownGain
            }
        }
    }

    // Brown lands warm (1.4 kHz), pink keeps more mid (2.4 kHz).
    // Make-up gains hold the loudness the old filters had. Pink's is
    // 3 percent under its old 0.1384: measured over two minutes it
    // touched 1.017 and got clamped, and a clamp is a click. Inaudible
    // as a level change, and it is the only tuning number here that
    // moved at all.
    private static let brownAlpha: Float = 0.16745
    private static let brownGain: Float = 1.0772
    private static let pinkAlpha: Float = 0.26960
    private static let pinkGain: Float = 0.1343

    private let color: Color
    private var left: Channel
    private var right: Channel

    init(_ color: Color, seed: UInt64 = 0x5EED) {
        self.color = color
        left = Channel(rng: Rng(seed: seed))
        right = Channel(rng: Rng(seed: seed &* 6364136223846793005 &+ 1))
    }

    func render(
        left leftOut: UnsafeMutablePointer<Float>,
        right rightOut: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        for frame in 0..<frames {
            leftOut[frame] = left.next(color)
            rightOut[frame] = right.next(color)
        }
    }
}

// MARK: Events

/// A struck resonator: one impulse in, a decaying tone out. Droplets
/// and crackles are both this, at different frequencies and decays, so
/// there is one piece of DSP to get right instead of two.
///
/// y[n] = a*y[n-1] - r^2*y[n-2], excited by seeding y[n-1]. The decay
/// falls out of the pole radius, so no envelope has to be multiplied in
/// per sample.
private struct Voice {
    var y1: Float = 0
    var y2: Float = 0
    var a: Float = 0
    var r2: Float = 0
    var gain: Float = 0
    var remaining: Int = 0
    /// Frames still to wait before this voice speaks. An event reaches
    /// the far ear later than the near one, and that delay is what
    /// makes a struck event sound like it is somewhere in a room
    /// instead of inside the listener's head.
    var delay: Int = 0

    var isActive: Bool { remaining > 0 }

    mutating func strike(
        frequency: Float,
        decaySeconds: Float,
        amplitude: Float,
        gain: Float,
        delayFrames: Int,
        sampleRate: Float
    ) {
        let w = 2 * Float.pi * frequency / sampleRate
        let r = expf(-1 / (decaySeconds * sampleRate))
        a = 2 * r * cosf(w)
        r2 = r * r
        // Seeding y1 with the amplitude directly is a trap: this
        // resonator's impulse response peaks at amplitude/sin(w), so a
        // 320 Hz pop came out twenty four times louder than asked and
        // the whole scape clipped. Pre-scaling by sin(w) makes the
        // number mean what it says at every frequency.
        y1 = amplitude * sinf(w)
        y2 = 0
        self.gain = gain
        delay = delayFrames
        // Four time constants is inaudible; stopping there frees the
        // voice for the next event instead of grinding out silence.
        remaining = Int(decaySeconds * 4 * sampleRate) + delayFrames
    }

    mutating func next() -> Float {
        guard remaining > 0 else { return 0 }
        remaining -= 1
        if delay > 0 {
            delay -= 1
            return 0
        }
        let y = a * y1 - r2 * y2
        y2 = y1
        y1 = y
        return y * gain
    }
}

/// A fixed pool of struck voices feeding ONE channel. Fixed because the
/// render thread does not allocate: when every voice is busy the next
/// event is dropped, which is inaudible in a texture built of hundreds.
///
/// One pool per channel rather than one pool panned across both. Panning
/// a single voice writes the same waveform to both ears, which measured
/// at 0.73 correlation on fire: loud, but narrow. Two pools let the same
/// event arrive at each ear with its own level and its own delay.
private struct VoicePool {
    private var voices: [Voice]
    private let sampleRate: Float

    init(size: Int, sampleRate: Float) {
        voices = [Voice](repeating: Voice(), count: size)
        self.sampleRate = sampleRate
    }

    mutating func strike(
        frequency: Float,
        decaySeconds: Float,
        amplitude: Float,
        gain: Float,
        delayFrames: Int
    ) {
        for index in voices.indices where !voices[index].isActive {
            voices[index].strike(
                frequency: frequency,
                decaySeconds: decaySeconds,
                amplitude: amplitude,
                gain: gain,
                delayFrames: delayFrames,
                sampleRate: sampleRate
            )
            return
        }
    }

    mutating func next() -> Float {
        var sum: Float = 0
        for index in voices.indices where voices[index].isActive {
            sum += voices[index].next()
        }
        return sum
    }
}

/// Where an event sits in the field, as the two ears receive it.
/// `pan` 0 is hard left, 1 hard right; the gains are equal-power so an
/// event crossing the field holds its loudness, and the far ear waits
/// up to about two thirds of a millisecond, which is roughly a head.
private struct Placement {
    var leftGain: Float
    var rightGain: Float
    var leftDelay: Int
    var rightDelay: Int

    init(pan: Float, sampleRate: Float) {
        let angle = pan * Float.pi / 2
        leftGain = cosf(angle)
        rightGain = sinf(angle)
        let maximum = Int(0.0007 * sampleRate)
        let offset = Int(abs(pan - 0.5) * 2 * Float(maximum))
        leftDelay = pan > 0.5 ? offset : 0
        rightDelay = pan > 0.5 ? 0 : offset
    }
}

/// A level that wanders slowly, so a bed of noise breathes instead of
/// sitting perfectly still. A static bed is the thing the ear identifies
/// as synthetic within about two seconds.
private struct Drift {
    private var value: Float
    private var target: Float
    private var step: Float = 0
    private var remaining: Int = 0
    private let low: Float
    private let high: Float
    private let minSeconds: Float
    private let maxSeconds: Float
    private let sampleRate: Float

    init(low: Float, high: Float, minSeconds: Float, maxSeconds: Float, sampleRate: Float) {
        value = (low + high) / 2
        target = value
        self.low = low
        self.high = high
        self.minSeconds = minSeconds
        self.maxSeconds = maxSeconds
        self.sampleRate = sampleRate
    }

    mutating func next(_ rng: inout Rng) -> Float {
        if remaining <= 0 {
            target = rng.range(low, high)
            let seconds = rng.range(minSeconds, maxSeconds)
            remaining = Int(seconds * sampleRate)
            step = (target - value) / Float(remaining)
        }
        remaining -= 1
        value += step
        return value
    }
}

// MARK: Rain

/// Rain heard from inside: a broadband bed with the sharpness taken off
/// it, and droplets scattered over the top. It never repeats, because
/// nothing here is a recording of anything.
///
/// The character is the one the recording was being tortured into: soft
/// and sparse, no droplet ever sharp. The difference is that the top end
/// is shelved by not generating it, rather than cliffed at 5.5 kHz after
/// the fact, which is where the mud came from.
final class RainScape: Soundscape {
    private struct Bed {
        var rng: Rng
        var lowA: OnePole
        var lowB: OnePole
        var rumble: OnePole
        var drift: Drift

        mutating func next() -> Float {
            let white = rng.bipolar()
            // Two poles down from 3.2 kHz: hiss without the sizzle.
            let shaped = lowB.low(lowA.low(white))
            // And the rumble taken out, so it reads as rain and not wind.
            let body = shaped - rumble.low(shaped)
            return body * drift.next(&rng)
        }
    }

    private static let sampleRate: Float = 48000
    private var left: Bed
    private var right: Bed
    private var leftVoices: VoicePool
    private var rightVoices: VoicePool
    private var eventRng: Rng
    /// Droplets per second across the whole field. Low on purpose: this
    /// is rain outside a window, not rain on a tin roof.
    private static let dropletsPerSecond: Float = 26
    private static let level: Float = 1.42

    init(seed: UInt64 = 0x8A17) {
        func bed(_ seed: UInt64) -> Bed {
            Bed(
                rng: Rng(seed: seed),
                lowA: OnePole(cutoff: 3200, sampleRate: RainScape.sampleRate),
                lowB: OnePole(cutoff: 3200, sampleRate: RainScape.sampleRate),
                rumble: OnePole(cutoff: 180, sampleRate: RainScape.sampleRate),
                drift: Drift(
                    low: 0.72, high: 1.0,
                    minSeconds: 3, maxSeconds: 9,
                    sampleRate: RainScape.sampleRate
                )
            )
        }
        left = bed(seed)
        right = bed(seed &* 6364136223846793005 &+ 1)
        leftVoices = VoicePool(size: 40, sampleRate: RainScape.sampleRate)
        rightVoices = VoicePool(size: 40, sampleRate: RainScape.sampleRate)
        eventRng = Rng(seed: seed &+ 0xD1CE)
    }

    func render(
        left leftOut: UnsafeMutablePointer<Float>,
        right rightOut: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        let probability = RainScape.dropletsPerSecond / RainScape.sampleRate
        for frame in 0..<frames {
            if eventRng.uniform() < probability {
                // Damping and pitch vary together: the far droplets are
                // both duller and shorter, which is what distance does.
                let bright = eventRng.uniform()
                let frequency = eventRng.range(820, 2900)
                let decay = eventRng.range(0.015, 0.06)
                let amplitude = eventRng.range(0.05, 0.15) * (0.5 + 0.5 * bright)
                let place = Placement(pan: eventRng.uniform(), sampleRate: RainScape.sampleRate)
                leftVoices.strike(
                    frequency: frequency, decaySeconds: decay, amplitude: amplitude,
                    gain: place.leftGain, delayFrames: place.leftDelay
                )
                rightVoices.strike(
                    frequency: frequency, decaySeconds: decay, amplitude: amplitude,
                    gain: place.rightGain, delayFrames: place.rightDelay
                )
            }
            // Level matched by measurement to the synthesized colors, so
            // the volume slider means the same thing on every chip.
            leftOut[frame] = (left.next() * 0.85 + leftVoices.next()) * RainScape.level
            rightOut[frame] = (right.next() * 0.85 + rightVoices.next()) * RainScape.level
        }
    }
}

// MARK: Fire

/// A hearth heard from the sofa: a rumble that breathes, crackles that
/// arrive in flurries the way real fires crackle, and the occasional pop
/// with some body to it.
///
/// The old recording needed an 8 dB shelf cut to stop it booming. Here
/// the low end is simply not generated that loud in the first place.
final class FireScape: Soundscape {
    private struct Bed {
        var rng: Rng
        var brown: Float = 0
        var lowA: OnePole
        var lowB: OnePole
        var breath: OnePole
        var breathHigh: OnePole
        var drift: Drift

        mutating func next() -> Float {
            let white = rng.bipolar()
            brown = (brown + 0.02 * white) / 1.02
            // The rumble, kept under the crackle rather than over it.
            let rumble = lowB.low(lowA.low(brown * 3.2))
            // A thin band of air above it so the bed is not just bass.
            let air = breathHigh.high(breath.low(white)) * 0.12
            return (rumble * 0.95 + air * 1.3) * drift.next(&rng)
        }
    }

    private static let sampleRate: Float = 48000
    private var left: Bed
    private var right: Bed
    private var leftVoices: VoicePool
    private var rightVoices: VoicePool
    private var eventRng: Rng
    /// Crackles left in the current flurry, and how far apart they fall.
    private var flurryRemaining = 0
    private var flurryGap = 0
    private static let level: Float = 1.45

    init(seed: UInt64 = 0xF14E) {
        func bed(_ seed: UInt64) -> Bed {
            Bed(
                rng: Rng(seed: seed),
                lowA: OnePole(cutoff: 220, sampleRate: FireScape.sampleRate),
                lowB: OnePole(cutoff: 220, sampleRate: FireScape.sampleRate),
                breath: OnePole(cutoff: 2600, sampleRate: FireScape.sampleRate),
                breathHigh: OnePole(cutoff: 700, sampleRate: FireScape.sampleRate),
                drift: Drift(
                    low: 0.6, high: 1.0,
                    minSeconds: 2, maxSeconds: 7,
                    sampleRate: FireScape.sampleRate
                )
            )
        }
        left = bed(seed)
        right = bed(seed &* 6364136223846793005 &+ 1)
        leftVoices = VoicePool(size: 32, sampleRate: FireScape.sampleRate)
        rightVoices = VoicePool(size: 32, sampleRate: FireScape.sampleRate)
        eventRng = Rng(seed: seed &+ 0xC4A0)
    }

    func render(
        left leftOut: UnsafeMutablePointer<Float>,
        right rightOut: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        // A flurry starts about every second and a half.
        let flurryProbability: Float = 0.7 / FireScape.sampleRate
        for frame in 0..<frames {
            if flurryRemaining > 0 {
                flurryGap -= 1
                if flurryGap <= 0 {
                    flurryRemaining -= 1
                    flurryGap = Int(eventRng.range(0.012, 0.09) * FireScape.sampleRate)
                    strikeCrackle()
                }
            } else if eventRng.uniform() < flurryProbability {
                flurryRemaining = Int(eventRng.range(2, 9))
                flurryGap = 0
            }
            // Level matched by measurement to the synthesized colors.
            leftOut[frame] = (left.next() + leftVoices.next()) * FireScape.level
            rightOut[frame] = (right.next() + rightVoices.next()) * FireScape.level
        }
    }

    private func strikeCrackle() {
        // One in nine is a pop: lower, longer, and with some weight.
        let pop = eventRng.uniform() < 0.11
        let frequency = pop ? eventRng.range(320, 900) : eventRng.range(1500, 4200)
        let decay = pop ? eventRng.range(0.03, 0.08) : eventRng.range(0.003, 0.016)
        let amplitude = pop ? eventRng.range(0.12, 0.30) : eventRng.range(0.06, 0.22)
        let pan = pop ? eventRng.range(0.2, 0.8) : eventRng.uniform()
        let place = Placement(pan: pan, sampleRate: FireScape.sampleRate)
        leftVoices.strike(
            frequency: frequency, decaySeconds: decay, amplitude: amplitude,
            gain: place.leftGain, delayFrames: place.leftDelay
        )
        rightVoices.strike(
            frequency: frequency, decaySeconds: decay, amplitude: amplitude,
            gain: place.rightGain, delayFrames: place.rightDelay
        )
    }
}
