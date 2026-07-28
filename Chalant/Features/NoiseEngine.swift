import AVFoundation
import os

/// Ambience with two engines: brown/white/pink are synthesized in real
/// time (a source node, click-free gain ramps); rain, fire and cafe are
/// field recordings looped through a voicing chain, time-pitch plus EQ,
/// so each one sits the way the real thing does: rain soft and sparse,
/// a cafe murmuring at the far side of the room, a fire that rumbles in
/// the hearth instead of hissing. Everything fades, nothing clicks.
final class NoiseEngine {
    enum NoiseColor: String, CaseIterable {
        case brown
        case white
        case pink
        case rain
        case fire
        case cafe
    }

    /// A sound was asked for and none could be made. Without this the
    /// failures below were swallowed whole while the caller had already
    /// lit the chip: it sat there playing, silently, forever, with
    /// nothing to tell the user which layer gave up.
    var onSilence: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var current: NoiseColor = .brown { didSet { publishControls() } }

    // Recording chain: player -> time-pitch -> EQ -> mixer.
    private var filePlayer: AVAudioPlayerNode?
    private var timePitch: AVAudioUnitTimePitch?
    private var fileEQ: AVAudioUnitEQ?
    private var buffers: [NoiseColor: AVAudioPCMBuffer] = [:]
    private var playerColor: NoiseColor?
    private var currentTrim: Float = 1
    private var fadeTimer: Timer?

    private let baseFileLevel: Float = 0.4
    private let baseSynthLevel: Float = 0.35

    /// User volume 0...1; 0.7 reproduces the original fixed levels.
    private var userVolume: Float = 0.7
    private var fileLevel: Float { baseFileLevel / 0.7 * userVolume }
    private var synthLevel: Float { baseSynthLevel / 0.7 * userVolume }
    /// Read on the render thread; the mixer stays at unity so it can't
    /// scale the recording chain along with the synth.
    private var synthVol: Float = 0.35 { didSet { publishControls() } }

    func setVolume(_ volume: Float) {
        userVolume = max(0, min(1, volume))
        synthVol = synthLevel
        if playerColor != nil {
            fadePlayer(to: fileLevel * currentTrim, duration: 0.1)
        }
    }

    // Smoothed synth gain, advanced on the render thread.
    private var gain: Float = 0
    private var targetGain: Float = 0 { didSet { publishControls() } }

    /// What the render thread needs from the main actor, handed across
    /// as one snapshot instead of three properties read live.
    ///
    /// The three were plain vars that main wrote while the audio thread
    /// read them mid-buffer. Nothing tore audibly, but nothing promised
    /// not to either: this class is neither @MainActor nor Sendable and
    /// the project builds at Swift 5.9, so the compiler had no opinion.
    private struct Controls {
        var target: Float = 0
        var color: NoiseColor = .brown
        var volume: Float = 0.35
    }

    private var controlLock = os_unfair_lock_s()
    private var publishedControls = Controls()
    /// The render thread's own copy. Read and written there and nowhere
    /// else, so it needs no guarding of its own.
    private var renderControls = Controls()

    private func publishControls() {
        os_unfair_lock_lock(&controlLock)
        publishedControls = Controls(target: targetGain, color: current, volume: synthVol)
        os_unfair_lock_unlock(&controlLock)
    }

    /// Take the newest controls if the lock happens to be free, and
    /// otherwise carry on with last buffer's. A render callback that
    /// waits on a lock held by the main thread is a dropout, and one
    /// more buffer at the previous volume is a perfectly good answer.
    private func refreshRenderControls() {
        if os_unfair_lock_trylock(&controlLock) {
            renderControls = publishedControls
            os_unfair_lock_unlock(&controlLock)
        }
    }

    // Filter state
    private var brownLast: Float = 0
    // Refined Kellet pink (seven poles): the old economy filter left
    // the top octave hissing, which read as harsh (user, 2026-07-23).
    private var pinkB0: Float = 0
    private var pinkB1: Float = 0
    private var pinkB2: Float = 0
    private var pinkB3: Float = 0
    private var pinkB4: Float = 0
    private var pinkB5: Float = 0
    private var pinkB6: Float = 0
    private var whiteLast: Float = 0
    // A gentle two-pole smoothing lowpass on the two synth colors that
    // sounded harsh; brown lands warm (1.4 kHz), pink keeps more mid
    // (2.4 kHz). Cascaded one-poles, so no resonance. Coefficients
    // and make-up gains derived to hold the old loudness (RMS) while
    // shedding ~15-23 dB of the top two octaves.
    private var smoothA: Float = 0
    private var smoothB: Float = 0
    private static let brownAlpha: Float = 0.16745
    private static let brownGain: Float = 1.0772
    private static let pinkAlpha: Float = 0.26960
    private static let pinkGain: Float = 0.1384

    private(set) var isRunning = false

    private static func fileURL(for color: NoiseColor) -> URL? {
        switch color {
        case .rain: return Bundle.main.url(forResource: "rain", withExtension: "m4a")
        case .fire: return Bundle.main.url(forResource: "fire", withExtension: "m4a")
        case .cafe: return Bundle.main.url(forResource: "cafe", withExtension: "m4a")
        default: return nil
        }
    }

    /// Every recording is converted to this one format at load and the
    /// chain is wired once, never rewired. The recordings ship in three
    /// different formats (rain 48k stereo, fire 48k mono, cafe 44.1k
    /// stereo); scheduling one through a chain wired for another played
    /// silence, and rewiring a running engine raced the UI.
    private static let chainFormat = AVAudioFormat(
        standardFormatWithSampleRate: 48000, channels: 2
    )!

    /// Loop at most this much of a recording. The six-minute files
    /// cost 138 MB each as float PCM; two minutes loops just as well.
    private static let maxLoopSeconds: Double = 120

    // MARK: Voicings

    /// How each recording is seated. Rate below 1 spaces the events
    /// out (droplets, chatter); pitch in cents warms them; the EQ
    /// bands shape distance; trim balances loudness between sounds.
    private struct Voicing {
        var rate: Float
        var pitch: Float
        var trim: Float
        /// (filter, frequency, gain dB, bandwidth octaves)
        var bands: [(AVAudioUnitEQFilterType, Float, Float, Float)]
    }

    private static func voicing(for color: NoiseColor) -> Voicing {
        switch color {
        case .rain:
            // Slower and darker: fewer droplets, none of them sharp.
            return Voicing(
                rate: 0.9, pitch: -250, trim: 0.9,
                bands: [
                    (.highShelf, 2000, -9, 1),
                    (.lowPass, 5500, 0, 0.7),
                    (.parametric, 350, 2, 1.2),
                ]
            )
        case .cafe:
            // The far corner of a small cafe, not the middle of a
            // crowd: slowed, softened highs, a little room warmth.
            return Voicing(
                rate: 0.78, pitch: -80, trim: 0.8,
                bands: [
                    (.lowPass, 3000, 0, 0.8),
                    (.highShelf, 1500, -7, 1),
                    (.lowShelf, 250, 2.5, 1),
                ]
            )
        case .fire:
            // A hearth heard from the sofa: the lows are cut, not
            // boosted (the old +6.5dB shelf boomed), the crackle sits
            // forward, the hiss stays shaved.
            return Voicing(
                rate: 1.0, pitch: -60, trim: 0.9,
                bands: [
                    (.lowShelf, 200, -8, 1),
                    (.parametric, 2400, 2, 1.5),
                    (.highShelf, 6000, -4, 1),
                ]
            )
        default:
            return Voicing(rate: 1, pitch: 0, trim: 1, bands: [])
        }
    }

    // MARK: Transport

    func start(_ color: NoiseColor) {
        current = color
        isRunning = true
        if Self.fileURL(for: color) != nil {
            targetGain = 0
            startFile(color)
        } else {
            stopFile(fade: 0.4)
            if source == nil { setupSynth() }
            synthVol = synthLevel
            engine.mainMixerNode.outputVolume = 1
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    isRunning = false
                    onSilence?("the audio engine wouldn't start")
                    return
                }
            }
            targetGain = 1
        }
    }

    func set(_ color: NoiseColor) {
        guard isRunning else {
            current = color
            return
        }
        guard color != current else { return }
        if Self.fileURL(for: color) != nil {
            start(color)
        } else if Self.fileURL(for: current) != nil {
            // Recording -> synth
            current = color
            start(color)
        } else {
            // Synth -> synth: duck, swap, rise, a hard spectrum change
            // sounds like a glitch.
            targetGain = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, self.isRunning else { return }
                self.current = color
                self.targetGain = 1
            }
        }
    }

    func pause() {
        targetGain = 0
        fadePlayer(to: 0, duration: 0.5)
    }

    func resume() {
        if Self.fileURL(for: current) != nil {
            if playerColor == current {
                fadePlayer(to: fileLevel * currentTrim, duration: 0.6)
            } else {
                startFile(current)
            }
        } else {
            targetGain = 1
        }
    }

    func stop() {
        targetGain = 0
        isRunning = false
        stopFile(fade: 0.4)
        // Let the fades finish before the engine goes down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.isRunning else { return }
            self.engine.stop()
        }
    }

    // MARK: Recording chain

    private func buildFileChain() {
        guard filePlayer == nil else { return }
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        // connect raises rather than returns when it cannot make a
        // graph out of what it is given, so a format the hardware will
        // not take ends the process rather than the sound. Guarded, the
        // chain is simply not built and the chip says so.
        let wired = AudioGuard.succeeds("build the ambience chain") {
            engine.attach(player)
            engine.attach(pitch)
            engine.attach(eq)
            // Wired once, at the one format every buffer is converted to.
            engine.connect(player, to: pitch, format: Self.chainFormat)
            engine.connect(pitch, to: eq, format: Self.chainFormat)
            engine.connect(eq, to: engine.mainMixerNode, format: Self.chainFormat)
        }
        guard wired else {
            isRunning = false
            onSilence?("the sound chain wouldn't build")
            return
        }
        filePlayer = player
        timePitch = pitch
        fileEQ = eq
    }

    /// Decode and convert off the main thread; the completion runs on
    /// main. Decoding six minutes of AAC at click time froze the click.
    private func loadBuffer(
        _ color: NoiseColor,
        completion: @escaping (AVAudioPCMBuffer?) -> Void
    ) {
        if let cached = buffers[color] {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let buffer = Self.decodeBuffer(color)
            DispatchQueue.main.async {
                guard let self else { return }
                if let buffer { self.buffers[color] = buffer }
                completion(buffer)
            }
        }
    }

    private static func decodeBuffer(_ color: NoiseColor) -> AVAudioPCMBuffer? {
        guard let url = fileURL(for: color),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let sourceFormat = file.processingFormat
        let frames = AVAudioFrameCount(min(
            file.length,
            AVAudioFramePosition(maxLoopSeconds * sourceFormat.sampleRate)
        ))
        guard let raw = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames),
              (try? file.read(into: raw, frameCount: frames)) != nil,
              raw.frameLength > 0
        else { return nil }
        if sourceFormat == chainFormat { return raw }
        guard let converter = AVAudioConverter(from: sourceFormat, to: chainFormat) else {
            return nil
        }
        let capacity = AVAudioFrameCount(
            (Double(raw.frameLength) * chainFormat.sampleRate / sourceFormat.sampleRate)
                .rounded(.up)
        ) + 1024
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: chainFormat, frameCapacity: capacity
        ) else { return nil }
        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return raw
        }
        guard conversionError == nil, status != .error, converted.frameLength > 0 else {
            return nil
        }
        return converted
    }

    private func startFile(_ color: NoiseColor) {
        if playerColor == color, let player = filePlayer {
            if !player.isPlaying { player.play() }
            fadePlayer(to: fileLevel * currentTrim, duration: 0.6)
            return
        }
        loadBuffer(color) { [weak self] buffer in
            guard let self else { return }
            // The user may have moved on while the file decoded. That
            // is not a failure, so it is checked before one is called.
            guard self.isRunning, self.current == color else { return }
            guard let buffer else {
                self.isRunning = false
                self.onSilence?("that sound wouldn't load")
                return
            }
            self.buildFileChain()
            guard let player = self.filePlayer,
                  let pitch = self.timePitch,
                  let eq = self.fileEQ else { return }

            let voice = Self.voicing(for: color)
            pitch.rate = voice.rate
            pitch.pitch = voice.pitch
            for (index, band) in eq.bands.enumerated() {
                if index < voice.bands.count {
                    let (type, frequency, gainDB, width) = voice.bands[index]
                    band.filterType = type
                    band.frequency = frequency
                    band.gain = gainDB
                    band.bandwidth = width
                    band.bypass = false
                } else {
                    band.bypass = true
                }
            }
            self.currentTrim = voice.trim

            self.engine.mainMixerNode.outputVolume = 1
            if !self.engine.isRunning {
                do {
                    try self.engine.start()
                } catch {
                    self.isRunning = false
                    self.onSilence?("the audio engine wouldn't start")
                    return
                }
            }

            // scheduleBuffer raises when the buffer's format does not
            // match the chain it was wired for, which is exactly the
            // mismatch these three recordings ship with.
            let scheduled = AudioGuard.succeeds("schedule the loop") {
                player.stop()
                player.scheduleBuffer(buffer, at: nil, options: .loops)
                player.volume = 0
                player.play()
            }
            guard scheduled else {
                self.isRunning = false
                self.onSilence?("that sound wouldn't play")
                return
            }
            self.fadePlayer(to: self.fileLevel * voice.trim, duration: 0.8)
            self.playerColor = color
        }
    }

    private func stopFile(fade: TimeInterval) {
        guard playerColor != nil else { return }
        fadePlayer(to: 0, duration: fade) { [weak self] in
            self?.filePlayer?.stop()
        }
        playerColor = nil
    }

    /// AVAudioPlayerNode has no fade of its own; a light 30Hz ramp
    /// keeps starts and stops click-free like the synth path.
    private func fadePlayer(
        to target: Float,
        duration: TimeInterval,
        completion: (() -> Void)? = nil
    ) {
        guard let player = filePlayer else { return }
        fadeTimer?.invalidate()
        guard duration > 0.01 else {
            player.volume = target
            completion?()
            return
        }
        let start = player.volume
        let begin = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { timer in
            let progress = Float(min(1, Date().timeIntervalSince(begin) / duration))
            player.volume = start + (target - start) * progress
            if progress >= 1 {
                timer.invalidate()
                completion?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    // MARK: Synthesis

    private func setupSynth() {
        // unowned(unsafe), not weak: the node is owned by the engine,
        // which is owned by this object, so it cannot outlive us. A
        // weak capture takes the runtime's side-table lock once per
        // buffer, on the audio thread, which is the one place that must
        // never wait on a lock the rest of the app can hold.
        let node = AVAudioSourceNode { [unowned(unsafe) self] _, _, frameCount, audioBufferList -> OSStatus in
            self.refreshRenderControls()
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let sample = self.nextSample()
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let pointer = data.assumingMemoryBound(to: Float.self)
                    pointer[frame] = sample
                }
            }
            return noErr
        }
        let attached = AudioGuard.succeeds("attach the synth") {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: nil)
        }
        guard attached else {
            isRunning = false
            onSilence?("the synth wouldn't attach")
            return
        }
        source = node
    }

    private func nextSample() -> Float {
        // ~50ms exponential ramp at 48k, click-free starts, stops,
        // pauses, and color changes.
        let target = renderControls.target
        gain += (target - gain) * 0.0004
        if target == 0, gain < 0.0005 { return 0 }

        let white = Float.random(in: -1...1)
        let value: Float
        switch renderControls.color {
        case .white:
            // Softened: raw full-band white is piercing.
            whiteLast += 0.45 * (white - whiteLast)
            value = whiteLast * 0.8
        case .pink:
            // Refined Kellet pink, then the smoothing lowpass.
            pinkB0 = 0.99886 * pinkB0 + white * 0.0555179
            pinkB1 = 0.99332 * pinkB1 + white * 0.0750759
            pinkB2 = 0.96900 * pinkB2 + white * 0.1538520
            pinkB3 = 0.86650 * pinkB3 + white * 0.3104856
            pinkB4 = 0.55000 * pinkB4 + white * 0.5329522
            pinkB5 = -0.7616 * pinkB5 - white * 0.0168980
            let pink = pinkB0 + pinkB1 + pinkB2 + pinkB3
                + pinkB4 + pinkB5 + pinkB6 + white * 0.5362
            pinkB6 = white * 0.115926
            value = smoothed(pink, alpha: Self.pinkAlpha) * Self.pinkGain
        case .brown:
            brownLast = (brownLast + 0.02 * white) / 1.02
            value = smoothedBrown(brownLast * 3.2)
        case .rain, .fire, .cafe:
            value = 0
        }
        return max(-1, min(1, value)) * gain * renderControls.volume
    }

    /// The shared two-pole smoothing lowpass, cascaded one-poles.
    private func smoothed(_ input: Float, alpha: Float) -> Float {
        smoothA += alpha * (input - smoothA)
        smoothB += alpha * (smoothA - smoothB)
        return smoothB
    }

    private func smoothedBrown(_ input: Float) -> Float {
        smoothed(input, alpha: Self.brownAlpha) * Self.brownGain
    }
}
