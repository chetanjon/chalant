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

/// What ambience needs from a sound source, and nothing beyond it.
///
/// A protocol for one reason. The focus/ambience coupling rules are
/// about which object calls which method, and a real `NoiseEngine`
/// drags a real audio device into proving them. A machine with no
/// output, which is every CI runner, cannot start one: it reports the
/// failure through `onSilence`, and `active` is cleared on a later
/// main-actor hop. That raced `testAFocusSessionLeavesTheUsersOwnNoise`
/// into failing with no code changing at all, red at 0ea7534 and green
/// at 6910efa with a docs-only commit between them (2026-08-02).
///
/// The seam is the fix. Whether audio hardware exists is a fact about
/// the machine, and it was being allowed to decide a question about
/// this app's own wiring.
protocol AmbienceSource: AnyObject {
    var onSilence: ((String) -> Void)? { get set }
    func start(_ color: NoiseEngine.NoiseColor)
    func stop()
    func pause()
    func resume()
    func setVolume(_ volume: Float)
}

extension NoiseEngine: AmbienceSource {}

/// The one owner of ambient sound. The chips row, focus sessions, and
/// voice commands all speak to this, so "what's playing" has exactly
/// one answer, and the collapsed island can show it.
@MainActor
final class AmbienceController: ObservableObject {
    /// The soundscape currently sounding (nil = silence). Pauses
    /// during focus breaks keep this set, the sound comes back.
    @Published private(set) var active: NoiseEngine.NoiseColor?

    /// Why the last ask made no sound, held until the next one. A lit
    /// chip over silence is a lie the user cannot debug.
    @Published private(set) var failure: String?

    @Published var volume: Double = 0.7 {
        didSet { engine.setVolume(Float(volume)) }
    }

    let engine: AmbienceSource

    /// Defaults to a real engine, so every caller in the app is
    /// unchanged and only a test ever passes anything else.
    init(engine: AmbienceSource = NoiseEngine()) {
        self.engine = engine
        engine.onSilence = { [weak self] reason in
            Task { @MainActor in
                guard let self else { return }
                self.active = nil
                self.failure = reason
            }
        }
    }

    /// Chip behavior: tap to play, tap the playing one to stop.
    func toggle(_ color: NoiseEngine.NoiseColor) {
        if active == color {
            stop()
        } else {
            play(color)
        }
    }

    func play(_ color: NoiseEngine.NoiseColor) {
        failure = nil
        active = color
        engine.start(color)
    }

    func stop() {
        failure = nil
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
