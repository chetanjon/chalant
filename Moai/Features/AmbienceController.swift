import SwiftUI

extension NoiseEngine.NoiseColor {
    /// What the chips offer. White noise is out of the lineup (kept
    /// in the engine so old settings don't break).
    static var chipChoices: [NoiseEngine.NoiseColor] {
        [.brown, .pink, .rain, .fire, .cafe]
    }

    var displayName: String {
        switch self {
        case .brown: return "Brown"
        case .white: return "White"
        case .pink: return "Pink"
        case .rain: return "Rain"
        case .fire: return "Fire"
        case .cafe: return "Café"
        }
    }

    var symbol: String {
        switch self {
        case .brown: return "water.waves"
        case .white: return "waveform"
        case .pink: return "waveform.path"
        case .rain: return "cloud.rain.fill"
        case .fire: return "flame.fill"
        case .cafe: return "cup.and.saucer.fill"
        }
    }
}

/// The one owner of ambient sound. The chips row, focus sessions, and
/// voice commands all speak to this, so "what's playing" has exactly
/// one answer, and the collapsed island can show it.
@MainActor
final class AmbienceController: ObservableObject {
    /// The soundscape currently sounding (nil = silence). Pauses
    /// during focus breaks keep this set, the sound comes back.
    @Published private(set) var active: NoiseEngine.NoiseColor?

    @Published var volume: Double = 0.7 {
        didSet { engine.setVolume(Float(volume)) }
    }

    let engine = NoiseEngine()

    /// Chip behavior: tap to play, tap the playing one to stop.
    func toggle(_ color: NoiseEngine.NoiseColor) {
        if active == color {
            stop()
        } else {
            play(color)
        }
    }

    func play(_ color: NoiseEngine.NoiseColor) {
        active = color
        engine.start(color)
    }

    func stop() {
        active = nil
        engine.stop()
    }

    /// Soft pause (focus breaks): sound fades out, `active` stays.
    func pause() {
        engine.pause()
    }

    func resume() {
        guard active != nil else { return }
        engine.resume()
    }
}
