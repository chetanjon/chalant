import AVFoundation

/// Ambience with two engines: brown/white/pink are synthesized in real
/// time (a source node, click-free gain ramps); rain and cafe are real
/// field recordings, looped with faded edges. Everything fades —
/// nothing clicks, nothing jumps.
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

    // Real recordings for rain / fire / cafe
    private var player: AVAudioPlayer?
    private var playerColor: NoiseColor?
    private let baseFileLevel: Float = 0.4
    private let baseSynthLevel: Float = 0.35

    /// User volume 0...1; 0.7 reproduces the original fixed levels.
    private var userVolume: Float = 0.7
    private var fileLevel: Float { baseFileLevel / 0.7 * userVolume }
    private var synthLevel: Float { baseSynthLevel / 0.7 * userVolume }

    func setVolume(_ volume: Float) {
        userVolume = max(0, min(1, volume))
        player?.setVolume(fileLevel, fadeDuration: 0.1)
        engine.mainMixerNode.outputVolume = synthLevel
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

    func start(_ color: NoiseColor) {
        current = color
        isRunning = true
        if Self.fileURL(for: color) != nil {
            targetGain = 0
            startFile(color)
        } else {
            stopFile(fade: 0.4)
            if source == nil { setupSynth() }
            engine.mainMixerNode.outputVolume = synthLevel
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
            // Synth -> synth: duck, swap, rise — a hard spectrum change
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
        player?.setVolume(0, fadeDuration: 0.5)
    }

    func resume() {
        if Self.fileURL(for: current) != nil {
            if player == nil {
                startFile(current)
            } else {
                player?.setVolume(fileLevel, fadeDuration: 0.6)
            }
        } else {
            targetGain = 1
        }
    }

    func stop() {
        targetGain = 0
        isRunning = false
        stopFile(fade: 0.4)
        // Let the synth fade finish before the engine goes down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isRunning else { return }
            self.engine.stop()
        }
    }

    // MARK: Real recordings

    private func startFile(_ color: NoiseColor) {
        if playerColor == color, let player {
            if !player.isPlaying { player.play() }
            player.setVolume(fileLevel, fadeDuration: 0.6)
            return
        }
        stopFile(fade: 0.4)
        guard let url = Self.fileURL(for: color),
              let fresh = try? AVAudioPlayer(contentsOf: url)
        else { return }
        fresh.numberOfLoops = -1
        fresh.volume = 0
        fresh.play()
        fresh.setVolume(fileLevel, fadeDuration: 0.8)
        player = fresh
        playerColor = color
    }

    private func stopFile(fade: TimeInterval) {
        guard let old = player else { return }
        old.setVolume(0, fadeDuration: fade)
        DispatchQueue.main.asyncAfter(deadline: .now() + fade + 0.1) {
            old.stop()
        }
        player = nil
        playerColor = nil
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
        // ~50ms exponential ramp at 48k — click-free starts, stops,
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
        return max(-1, min(1, value)) * gain
    }
}
