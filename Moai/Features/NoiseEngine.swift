import AVFoundation

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

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var current: NoiseColor = .brown

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
    private var synthVol: Float = 0.35

    func setVolume(_ volume: Float) {
        userVolume = max(0, min(1, volume))
        synthVol = synthLevel
        if playerColor != nil {
            fadePlayer(to: fileLevel * currentTrim, duration: 0.1)
        }
    }

    // Smoothed synth gain, advanced on the render thread.
    private var gain: Float = 0
    private var targetGain: Float = 0

    // Filter state
    private var brownLast: Float = 0
    private var pink0: Float = 0
    private var pink1: Float = 0
    private var pink2: Float = 0
    private var whiteLast: Float = 0

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
                try? engine.start()
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
        engine.attach(player)
        engine.attach(pitch)
        engine.attach(eq)
        // Wired once, at the one format every buffer is converted to.
        engine.connect(player, to: pitch, format: Self.chainFormat)
        engine.connect(pitch, to: eq, format: Self.chainFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: Self.chainFormat)
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
            guard let self, let buffer else { return }
            // The user may have moved on while the file decoded.
            guard self.isRunning, self.current == color else { return }
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
                try? self.engine.start()
            }

            player.stop()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.volume = 0
            player.play()
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
        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
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
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nil)
        source = node
    }

    private func nextSample() -> Float {
        // ~50ms exponential ramp at 48k, click-free starts, stops,
        // pauses, and color changes.
        gain += (targetGain - gain) * 0.0004
        if targetGain == 0, gain < 0.0005 { return 0 }

        let white = Float.random(in: -1...1)
        let value: Float
        switch current {
        case .white:
            // Softened: raw full-band white is piercing.
            whiteLast += 0.45 * (white - whiteLast)
            value = whiteLast * 0.8
        case .pink:
            // Kellet economy pink filter
            pink0 = 0.99765 * pink0 + white * 0.0990460
            pink1 = 0.96300 * pink1 + white * 0.2965164
            pink2 = 0.57000 * pink2 + white * 1.0526913
            value = (pink0 + pink1 + pink2 + white * 0.1848) * 0.12
        case .brown:
            brownLast = (brownLast + 0.02 * white) / 1.02
            value = brownLast * 3.2
        case .rain, .fire, .cafe:
            value = 0
        }
        return max(-1, min(1, value)) * gain * synthVol
    }
}
